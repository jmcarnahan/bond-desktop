import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'model_slots.dart';

/// [LlmWire] lives in `model_slots.dart` — a resolved [LlmTarget] carries one,
/// and that file may not import this one. Re-exported so every importer of
/// this file reads the enum where it always did.
export 'model_slots.dart' show LlmWire;

/// The one HTTP call this app makes to the local model.
///
/// llama-server speaks the OpenAI chat-completions shape, so this is a plain
/// POST — no SDK, no tools. One call streams: [completeJsonStreamed] sets
/// `stream: true` and reads the server-sent events back, which is how a draft's
/// words reach the composer while they are being written. Everything else is
/// one request and one response. Two details are load-bearing and measured
/// rather than guessed:
///
/// - `chat_template_kwargs.enable_thinking = false` is what actually stops
///   Qwen from thinking. `reasoning_effort` does not: the model reasons
///   anyway, spends the token budget doing it, and the answer comes back
///   truncated mid-JSON. Suppressing it also halves latency.
/// - the system prompt must be byte-identical call to call. llama-server
///   caches the KV prefix, and a prompt that differs by one character throws
///   that cache away — about two seconds per message. Everything that varies
///   per message, the date anchor included, belongs in the user message.
///
/// Two wires, one client. [LlmWire.openAi] is the app's own and is what every
/// provider constructs; [LlmWire.bedrockConverse] is the second request shape
/// a bakeoff needs, because Anthropic models on Bedrock are served on Converse
/// and nowhere else. A bearer token can ride on EITHER wire — Bedrock's
/// OpenAI-compatible endpoint takes the same body this app already sends and
/// only wants the header.
///
/// Either can arrive two ways: on the CONSTRUCTOR, which is the bench's path
/// (`app/test/fixtures/bench_target.dart`) and fixes them for the life of the
/// client, or on the RESOLVED TARGET, which is the app's since Round E — a
/// user's target spec carries a wire and, through the keychain, a bearer, and
/// [LlmTarget.wire] / [LlmTarget.bearer] win over the constructor's when they
/// are set. Every provider still CONSTRUCTS on the OpenAI wire with no token,
/// so a machine that has added no target behaves exactly as it always did.
/// The token is a request header and nothing else: it never reaches an
/// [LlmCallRecord], an exception message, or a log line.

/// [text] with every endpoint URL replaced by the word `<endpoint>`.
///
/// The one choke point between an exception's sentence and a stored row. The
/// sentences this client throws name the server they could not reach, which
/// is right on a screen and wrong in `activity_events` or a work row: a
/// target's URL is a setting, a stored row outlives the setting, and the
/// activity panel is copied into bug reports. Every [LlmCallRecord.error] and
/// every failure row the two queues write passes through here; the exception
/// itself is untouched, so the composer and the probe still read the full
/// sentence.
String redactEndpoints(String text) =>
    text.replaceAll(_endpointPattern, '<endpoint>');

final RegExp _endpointPattern = RegExp(r"""https?://[^\s'"<>\)\]]+""");

/// A failed call to the local model. [message] is safe to show a user.
class LlmException implements Exception {
  final String message;

  /// The HTTP status when the server answered, null when it did not.
  final int? statusCode;

  const LlmException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

/// The model server is not answering at all — not running, or unreachable.
///
/// Separated from every other failure because it says nothing about the
/// message being sent: the same request will succeed once the server is back,
/// so a caller should come back later rather than count the attempt against
/// the message.
class LlmUnavailableException extends LlmException {
  const LlmUnavailableException(super.message);
}

/// The server answered, and refused the access key: HTTP 401 or 403.
///
/// A subclass of [LlmUnavailableException] on purpose. It says nothing about
/// the message being sent either, so every existing `on
/// LlmUnavailableException` arm catches it and the drains PARK rather than
/// spending one attempt per item against a key that will refuse all of them.
/// The drains tell it apart by type to record the reason `unauthorized`,
/// which is what lets the rail say the key was refused rather than that the
/// box is down. Unlike its parent, coming back later will not help: somebody
/// has to fix the key.
class LlmUnauthorizedException extends LlmUnavailableException {
  const LlmUnauthorizedException(super.message);
}

/// The model answered, but not with the JSON object that was asked for.
class LlmFormatException extends LlmException {
  const LlmFormatException(super.message);
}

/// One call to the local model, as the HTTP layer saw it.
///
/// Lives here rather than beside the activity log because this file may not
/// import upward: the client reports what happened and has no opinion about
/// who is listening.
class LlmCallRecord {
  /// Which task asked — a [completeJson] caller's `schemaName`, or
  /// `'complete'` for free text. The five names in the app today: `triage`,
  /// `extraction`, `draft_reply`, `storyline_membership`, `storyline_name`
  /// (the storyline propose path reuses the naming task's schema, so there is
  /// deliberately no sixth).
  final String label;

  final int durationMs;

  /// llama-server's own token counts, null when the response carried none —
  /// which every failure does.
  final int? promptTokens;
  final int? completionTokens;

  /// llama-server's own `timings` — how long IT spent on the prompt and on
  /// generation. Null when the runtime sends no such block; an MLX-based
  /// server does not, and neither does Bedrock on either wire.
  ///
  /// Kept BESIDE [durationMs] rather than replacing it because the difference
  /// between the two is the answer to a question neither number can settle
  /// alone: wall duration minus server predicted time is the HTTP and
  /// queue-wait overhead, which is exactly the number that moves when a server
  /// batches concurrent requests. A runtime that generates at the same rate
  /// but queues four callers behind each other looks identical on server time
  /// and twice as slow on the wall.
  final int? serverPromptMs;
  final int? serverPredictedMs;

  /// Milliseconds from the request leaving to the first content delta
  /// arriving. Only a streamed call sets it; null on every other one.
  ///
  /// The number a person actually feels on a draft they asked for: the whole
  /// call can take half a minute, and this is how long the box stayed empty.
  /// Prefill-bound on a local 27B, which is why it is nearly the whole wait
  /// here and a fraction of a second on a GPU target.
  final int? firstTokenMs;

  /// The model name this request actually carried, and the URL it actually
  /// went to — resolved once per call, so a record from before a settings
  /// change reports the server it really used rather than the one now
  /// configured.
  ///
  /// Nullable for the same reason every other field here is: a record built by
  /// something that is not this client should not have to invent them. Every
  /// record [LlmClient] emits sets both.
  final String? model;
  final String? baseUrl;

  /// `ok`, `unavailable`, `error`, or `format`.
  final String outcome;

  final int? statusCode;
  final String? error;

  const LlmCallRecord({
    required this.label,
    required this.durationMs,
    required this.outcome,
    this.promptTokens,
    this.completionTokens,
    this.serverPromptMs,
    this.serverPredictedMs,
    this.firstTokenMs,
    this.model,
    this.baseUrl,
    this.statusCode,
    this.error,
  });
}

/// Sees every HTTP round trip to the model server, success or failure. Must
/// not throw; whatever it does happens on the queues' hot path.
typedef LlmCallObserver = void Function(LlmCallRecord record);

/// One call as the wire-specific body builders read it — what was asked for,
/// before either wire has an opinion about how to say it.
typedef _Request = ({
  String system,
  String user,
  int maxTokens,
  double temperature,
  bool think,
  Map<String, dynamic>? schema,
  String schemaName,
  String label,
});

/// One answer, wire-independent: the free text a completion returned, or the
/// JSON object a constrained one did, plus whatever the server said it cost.
typedef _Reply = ({
  String? text,
  Map<String, dynamic>? json,
  int? promptTokens,
  int? completionTokens,
  int? serverPromptMs,
  int? serverPredictedMs,
  // Only [_postStreamed] ever fills this; the two plain readers pass null.
  int? firstTokenMs,
});

class LlmClient {
  /// Overridable at build time (`--dart-define=LLAMA_URL=…`) for a model
  /// server on another port or another machine.
  ///
  /// Kept as the name every existing caller uses — `bench_target.dart` and
  /// `llm_routing_test.dart` both read these. The values live in
  /// `model_slots.dart` now so the slot defaults there can be const, and a
  /// `const` alias of a const variable is the only shape that avoids a library
  /// cycle between the two files.
  static const String defaultBaseUrl = proseUrlDefault;

  /// The small model that does the bulk work — triage, extraction, storyline
  /// membership. Same wire protocol, its own server: see `make fast`.
  static const String fastBaseUrl = fastUrlDefault;

  /// The model name every request carries, and the reason it is per instance
  /// rather than the one constant it used to be.
  ///
  /// llama-server ignores it — it serves whatever was loaded at launch — but
  /// the OpenAI request schema requires the field, and an MLX-based server
  /// HONOURS it: one runtime can hold several models and picks by this name.
  /// A single constant would make the app unable to say which of them it meant.
  static const String defaultModel = proseModelDefault;

  /// The same, for the bulk-work server — the two may be different models on
  /// different runtimes, so they get separate defines.
  static const String fastModel = fastModelDefault;

  /// The model generates at roughly 12 tokens a second, so a full 512-token
  /// answer can legitimately take most of a minute. This ceiling is here to
  /// catch a wedged server, not a slow one.
  static const Duration _defaultTimeout = Duration(seconds: 120);

  /// The ceiling for the prose server, which is the only client whose worst
  /// legitimate call is long. There are two of those worst cases and 90 has to
  /// clear both.
  ///
  /// The ordinary one is a draft with every input at its cap: thread 3,000 +
  /// attachment excerpts 2,500 + guidance 2,500 + directory passages 3,000 +
  /// style 1,500 + brief 700 + about-me 600 ≈ 14K characters ≈ 3.5K tokens,
  /// which prefills in about 26 s at 135 tok/s; the 768-token answer then
  /// generates in about 43 s at 18 tok/s with speculative decoding. 69
  /// seconds.
  ///
  /// The larger one is a draft whose pack expanded a section: the passages
  /// take their 8,700 ceiling instead of 3,000 and the storyline summary adds
  /// its 600, so ≈ 20K characters ≈ 5K tokens — about 37 s of prefill and the
  /// same 43 s of generation, about 80 s. That is the case the headroom is
  /// for, and it leaves roughly ten seconds of it. 60 would cut BOTH off
  /// mid-sentence; 90 leaves them room and still catches a wedged server a
  /// good half-minute sooner than the old ceiling did.
  ///
  /// [_defaultTimeout] stays 120 for the bulk client, where it costs nothing:
  /// those calls answer in seconds, so the number only ever describes how long
  /// a dead server is waited on.
  static const Duration proseTimeout = Duration(seconds: 90);

  /// Where this client points when nothing resolves for it — the constructor's
  /// arguments, which is what every test that subclasses this passes.
  final String _baseUrl;
  final String _model;

  /// Late binding: consulted at the top of every request rather than at
  /// construction, so a settings change applies to the NEXT call without
  /// rebuilding this client or the provider graph under it. Null in every
  /// test and in every bench — those pass a fixed [baseUrl]/[model] and
  /// behave exactly as before.
  final LlmTarget Function()? _resolveTarget;

  /// Per instance for a plainer reason than [model]: a candidate runtime being
  /// benched may be slower than the ceiling that suits the shipping one, and a
  /// bench that timed out at 120s would report an outage instead of a speed.
  final Duration timeout;

  final http.Client _http;
  final LlmCallObserver? _onCall;

  /// The FALLBACK token: sent as `Authorization: Bearer …` on either wire when
  /// the resolved target names none, and read nowhere else in this file. Null
  /// for every client the app builds — a user's target carries its own, out of
  /// the keychain.
  final String? _bearerToken;

  /// The FALLBACK wire: what this client speaks when the resolved target names
  /// none. [LlmWire.openAi] for every client the app builds; a bench pointed
  /// at an Anthropic model on Bedrock passes [LlmWire.bedrockConverse].
  final LlmWire wire;

  /// Fires with the tripwire below, so a test can catch a thinking regression.
  void Function()? onReasoningLeak;

  LlmClient({
    String? baseUrl,
    String? model,
    Duration? timeout,
    http.Client? httpClient,
    this._bearerToken,
    this.wire = LlmWire.openAi,
    this._onCall,
    this._resolveTarget,
  })  : _baseUrl = baseUrl ?? defaultBaseUrl,
        _model = model ?? defaultModel,
        timeout = timeout ?? _defaultTimeout,
        _http = httpClient ?? http.Client();

  /// Where the next request will go.
  ///
  /// A resolver that throws falls back to the constructed target rather than
  /// failing the call: it reads a Riverpod container it does not own, and a
  /// container torn down mid-drain must degrade to the compiled default, not
  /// turn into an exception on the queue's hot path. Same guard, same reason,
  /// as `embeddingsClientProvider`'s `onFail`.
  LlmTarget get target {
    final resolve = _resolveTarget;
    if (resolve == null) return LlmTarget(baseUrl: _baseUrl, model: _model);
    try {
      return resolve();
    } catch (_) {
      return LlmTarget(baseUrl: _baseUrl, model: _model);
    }
  }

  /// Preserved as readable properties — `llm_routing_test.dart` asserts on
  /// [baseUrl], and the settings screen reads both.
  String get baseUrl => target.baseUrl;
  String get model => target.model;

  /// Which wire THIS request speaks: the resolved target's when it names one,
  /// and the constructor's otherwise. The whole of how a user's target can put
  /// a Converse request out of a client every provider built on the OpenAI
  /// wire.
  LlmWire _wireOf(LlmTarget target) => target.wire ?? wire;

  /// The token THIS request carries, by the same rule. Read here and in
  /// [_headersFor], and nowhere else in this file.
  String? _bearerOf(LlmTarget target) => target.bearer ?? _bearerToken;

  /// Whether this request is going to somebody else's machine.
  ///
  /// Only the WORDING below turns on it. "start it, or change it in Settings"
  /// is advice about a server on this desk, and a cloud endpoint that answers
  /// 403 is not something the reader can go and launch.
  bool _remoteFor(LlmTarget target) =>
      _bearerOf(target) != null || _wireOf(target) == LlmWire.bedrockConverse;

  String _serverNoun(LlmTarget target) =>
      _remoteFor(target) ? 'The model server' : 'The local model server';

  String _modelNoun(LlmTarget target) =>
      _remoteFor(target) ? 'The model' : 'The local model';

  /// Names the server that did not answer. The old constant said
  /// "run: make model" for BOTH clients, which was wrong for the fast slot
  /// and wronger now that either can point anywhere.
  String _unreachable(LlmTarget target, String url) => _remoteFor(target)
      ? 'The model server at $url is not reachable — check the network and '
          'the URL'
      : 'The local model server at $url is not reachable — start it, or change '
          'it in Settings → Models';

  /// Free-text completion. Nothing in this app uses it yet; it is the seam a
  /// draft-reply task lands on.
  Future<String> complete({
    required String system,
    required String user,
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    // ONE resolution per request, taken HERE rather than inside [_post] so
    // this method's own failure message can name the same server the request
    // went to. A second read could describe a target saved since.
    final target = this.target;
    final reply = await _post(
      (
        system: system,
        user: user,
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
        schema: null,
        schemaName: 'complete',
        label: 'complete',
      ),
      target: target,
    );
    final text = reply.text;
    if (text == null) {
      throw LlmFormatException(
        '${_modelNoun(target)} answered with no message content.',
      );
    }
    return text;
  }

  /// A completion constrained to [schema].
  ///
  /// [temperature] defaults to the same low-but-not-zero value free-text
  /// completions use. A task whose answer should be reproducible — extraction,
  /// where the same email must yield the same facts twice — passes 0.
  ///
  /// This llama-server build converts the schema into a grammar and enforces
  /// it, which means a malformed schema fails the request outright with a 400
  /// rather than being ignored — that 400 is always a bug on this side, never
  /// something a retry fixes. It also means the answer's SHAPE is guaranteed
  /// and its SENSE is not: a grammar-valid string can still hold nonsense, so
  /// every caller validates what comes back.
  ///
  /// On [LlmWire.bedrockConverse] the same guarantee comes from a forced tool
  /// call rather than a `response_format`, and the answer arrives as the
  /// object itself — see [_converseBody].
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) =>
      _completeJson(
        system: system,
        user: user,
        schema: schema,
        schemaName: schemaName,
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
      );

  /// [completeJson], with the answer's text handed to [onText] as it arrives.
  ///
  /// A separate METHOD rather than an optional parameter on [completeJson],
  /// which is the shape it looks like it should be. The test tree's one
  /// double, `ScriptedLlm` in `test/fixtures/scripted_llm.dart`, overrides
  /// both of these methods with their exact signatures, and a Dart override
  /// must accept every named parameter of the method it overrides — so the
  /// two signatures are frozen together: a parameter added to either is an
  /// edit to the other's override as well, in a fixture that has nothing to
  /// do with streaming and would behave identically afterwards.
  ///
  /// The answer, the failure semantics and the observer's record are the same
  /// as [completeJson]'s in every respect but one: the record carries
  /// [LlmCallRecord.firstTokenMs]. The concatenated content is decoded by the
  /// same decoder at the end, so a stream that ended early is the same format
  /// failure a truncated plain answer is.
  ///
  /// On [LlmWire.bedrockConverse] there is nothing to stream — the JSON answer
  /// is a tool call the service assembles server-side — so [onText] is never
  /// called and the request goes out as one plain POST.
  Future<Map<String, dynamic>> completeJsonStreamed({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
    required void Function(String delta) onText,
  }) =>
      _completeJson(
        system: system,
        user: user,
        schema: schema,
        schemaName: schemaName,
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
        onText: onText,
      );

  /// The one body behind [completeJson] and [completeJsonStreamed]: the same
  /// request record, the same post, the same decode. [onText] null is the
  /// plain call.
  Future<Map<String, dynamic>> _completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    required String schemaName,
    required int maxTokens,
    required double temperature,
    required bool think,
    void Function(String delta)? onText,
  }) async {
    // ONE resolution per request — see [complete].
    final target = this.target;
    final reply = await _post(
      (
        system: system,
        user: user,
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
        schema: schema,
        schemaName: schemaName,
        label: schemaName,
      ),
      target: target,
      onText: onText,
    );

    // Decoded inside [_post], on either wire, so a constrained call's reply
    // always arrives here as an object — see [_decoded] for why the decode
    // does not live in this method.
    final json = reply.json;
    if (json == null) {
      throw LlmFormatException(
        '${_modelNoun(target)} answered with no message content.',
      );
    }
    return json;
  }

  /// [reply] with its JSON decoded when [request] was a constrained call and
  /// the wire handed back text (the OpenAI wire; Converse returns the tool
  /// call's object already parsed).
  ///
  /// This runs INSIDE [_post]'s instrumented try rather than in [completeJson]
  /// because the observer fires from that try. When the decode lived in
  /// [completeJson], an answer that was not JSON — a model that overran its
  /// token budget mid-object, say — was recorded as `ok` by the observer and
  /// then thrown as a format failure one frame up, so a bench could print
  /// `failures: 0` over a run that had lost an item to exactly that. The
  /// golden storyline replay caught it on 2026-09-15: one unfiled item, zero
  /// recorded failures. A call whose answer cannot be used is a failed call,
  /// and the record has to say so.
  _Reply _decoded(_Reply reply, _Request request, LlmTarget target) {
    if (request.schema == null || reply.json != null) return reply;
    return (
      text: reply.text,
      json: _decodeObject(reply.text, target),
      promptTokens: reply.promptTokens,
      completionTokens: reply.completionTokens,
      serverPromptMs: reply.serverPromptMs,
      serverPredictedMs: reply.serverPredictedMs,
      firstTokenMs: reply.firstTokenMs,
    );
  }

  Map<String, dynamic> _decodeObject(String? content, LlmTarget target) {
    final noun = _modelNoun(target);
    if (content == null) {
      throw LlmFormatException('$noun answered with no message content.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw LlmFormatException(
        '$noun did not answer with JSON: ${_snippet(content)}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw LlmFormatException(
        '$noun answered with ${decoded.runtimeType}, not a JSON '
        'object: ${_snippet(content)}',
      );
    }
    return decoded;
  }

  /// The app's own wire, unchanged: `model` is stamped by [_post]'s single
  /// target resolution, and a constrained call carries the strict
  /// `json_schema` envelope llama-server turns into a grammar.
  Map<String, dynamic> _openAiBody(_Request request, LlmTarget target) => {
        // ONE resolution per request, passed in rather than read again here:
        // reading `baseUrl` and `model` separately would let a save between
        // the two stamp a name from the new target onto the old target's URL.
        'model': target.model,
        'messages': [
          {'role': 'system', 'content': request.system},
          {'role': 'user', 'content': request.user},
        ],
        'max_tokens': request.maxTokens,
        'temperature': request.temperature,
        if (!request.think)
          'chat_template_kwargs': {'enable_thinking': false},
        if (request.schema != null)
          'response_format': {
            'type': 'json_schema',
            'json_schema': {
              'name': request.schemaName,
              'strict': true,
              'schema': request.schema,
            },
          },
      };

  /// The Converse body, and everything it deliberately leaves out.
  ///
  /// No `model` — the id is in the URL. No `chat_template_kwargs` — that is a
  /// llama-server template knob and Bedrock rejects unknown fields. No
  /// `strict` — a tool's `inputSchema` is enforced by the service, and the
  /// flag has no place to sit. And no `temperature`: Haiku 4.5 accepts one,
  /// Claude 5 answers HTTP 400 `temperature is deprecated for this model`, and
  /// one wire cannot behave two ways — so a Converse row samples at the
  /// model's default and says so in its banner.
  Map<String, dynamic> _converseBody(_Request request) => {
        'system': [
          {'text': request.system},
        ],
        'messages': [
          {
            'role': 'user',
            'content': [
              {'text': request.user},
            ],
          },
        ],
        'inferenceConfig': {'maxTokens': request.maxTokens},
        if (request.schema != null)
          'toolConfig': {
            'tools': [
              {
                'toolSpec': {
                  'name': request.schemaName,
                  'description': 'Answer in this shape.',
                  'inputSchema': {'json': request.schema},
                },
              },
            ],
            // Forced, not offered: an unconstrained model that answered in
            // prose would be the format failure `response_format` exists to
            // make impossible on the other wire.
            'toolChoice': {
              'tool': {'name': request.schemaName},
            },
          },
      };

  /// Where this request goes.
  ///
  /// The OpenAI wire posts to the configured URL as it stands. Converse
  /// addresses the model in the PATH, so the base URL is a host and the id —
  /// `…-v1:0` and all — is percent-encoded into it.
  Uri _endpoint(LlmTarget target) {
    switch (_wireOf(target)) {
      case LlmWire.openAi:
        return Uri.parse(target.baseUrl);
      case LlmWire.bedrockConverse:
        final base = target.baseUrl.endsWith('/')
            ? target.baseUrl.substring(0, target.baseUrl.length - 1)
            : target.baseUrl;
        return Uri.parse(
          '$base/model/${Uri.encodeComponent(target.model)}/converse',
        );
    }
  }

  /// POSTs and returns the answer, telling the observer — when there is one —
  /// what every round trip cost and how it ended.
  ///
  /// A thin wrapper on purpose: the single try below is what instruments all
  /// of [_postInner]'s failure paths without touching any of them.
  ///
  /// [onText] picks the streamed path, and only on the OpenAI wire: a Converse
  /// request that asked to stream degrades to one plain call rather than
  /// failing, because the wire has nothing to stream and the caller's answer
  /// is the same either way.
  Future<_Reply> _post(
    _Request request, {
    required LlmTarget target,
    void Function(String)? onText,
  }) async {
    // The wire is the RESOLVED target's where it names one — so a user's
    // Converse target puts a Converse body out of a client every provider
    // built on the OpenAI wire.
    final body = switch (_wireOf(target)) {
      LlmWire.openAi => _openAiBody(request, target),
      LlmWire.bedrockConverse => _converseBody(request),
    };
    final streamed = onText != null && _wireOf(target) == LlmWire.openAi;
    // One closure so the instrumented try below stays a single try over either
    // path, exactly as it was over the only path there used to be.
    Future<_Reply> send() => streamed
        ? _postStreamed(body, request: request, target: target, onText: onText)
        : _postInner(body, request: request, target: target);

    final observer = _onCall;
    if (observer == null) {
      return _decoded(await send(), request, target);
    }

    final sw = Stopwatch()..start();
    try {
      final result = _decoded(await send(), request, target);
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'ok',
        model: target.model,
        baseUrl: target.baseUrl,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        serverPromptMs: result.serverPromptMs,
        serverPredictedMs: result.serverPredictedMs,
        firstTokenMs: result.firstTokenMs,
      ));
      return result;
    } on LlmUnavailableException catch (e) {
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'unavailable',
        model: target.model,
        baseUrl: target.baseUrl,
        error: redactEndpoints(e.message),
      ));
      rethrow;
    } on LlmFormatException catch (e) {
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'format',
        model: target.model,
        baseUrl: target.baseUrl,
        error: redactEndpoints(e.message),
      ));
      rethrow;
    } on LlmException catch (e) {
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'error',
        model: target.model,
        baseUrl: target.baseUrl,
        statusCode: e.statusCode,
        error: redactEndpoints(e.message),
      ));
      rethrow;
    }
  }

  /// What every request carries, plain or streamed.
  ///
  /// The one place the token appears — the resolved target's when it carries
  /// one, the constructor's otherwise. It is never logged, never recorded, and
  /// never put into an exception message.
  Map<String, String> _headersFor(LlmTarget target) {
    final bearer = _bearerOf(target);
    return {
      'Content-Type': 'application/json',
      if (bearer != null) 'Authorization': 'Bearer $bearer',
    };
  }

  /// NOT [LlmUnavailableException]: the server accepted the connection, so
  /// this is one request going wrong rather than a server that is down.
  /// Counting it against the message is what stops a single pathological
  /// email from blocking the queue behind it forever.
  /// The three ways a request fails before the server has answered, mapped
  /// ONCE for both paths: no socket and a client-side abort are the server
  /// being unreachable, and the ceiling is the timeout the observer counts.
  Future<T> _guardTransport<T>(
    Uri url,
    LlmTarget target,
    Future<T> Function() send,
  ) async {
    try {
      return await send();
    } on SocketException {
      throw LlmUnavailableException(_unreachable(target, url.toString()));
    } on http.ClientException {
      throw LlmUnavailableException(_unreachable(target, url.toString()));
    } on TimeoutException {
      throw _timeoutException(target);
    }
  }

  LlmException _timeoutException(LlmTarget target) => LlmException(
        '${_modelNoun(target)} did not answer within ${timeout.inSeconds} '
        'seconds.',
      );

  /// The one status mapping, read by the plain path and the streamed one.
  /// Never returns — every status that reaches it is a failure.
  Never _throwForStatus(LlmTarget target, int statusCode, String bodyText) {
    // A 5xx is the SERVER's condition, not this request's: llama-server
    // answers 503 for every request while its weights load. Counting that
    // against the item would burn the whole backlog's attempts against a
    // server that was seconds from healthy — the drain must park instead,
    // exactly as it does for a refused connection.
    if (statusCode >= 500) {
      throw LlmUnavailableException(
        '${_serverNoun(target)} is not ready (HTTP $statusCode). '
        '${_snippet(bodyText)}',
      );
    }

    // A 401 or a 403 is the server refusing the key, and it will refuse every
    // other item in the backlog for exactly the same reason. Parking costs one
    // attempt and stops; the plain `LlmException` this used to throw cost one
    // attempt PER ITEM and filled the activity log with the same error. The
    // sentence names the URL, which `redactEndpoints` takes back out of any
    // row it is written into, and never the key.
    if (statusCode == 401 || statusCode == 403) {
      throw LlmUnauthorizedException(
        'The model server at ${_endpoint(target)} refused the access key. '
        'Check it in Settings, Models.',
      );
    }

    // A 429 is the same kind of thing one step further out: Bedrock throttles
    // with `ThrottlingException` and the request would succeed unchanged a few
    // seconds later. So it parks and is retried rather than costing the item,
    // exactly as a 503 does.
    if (statusCode == 429) {
      throw LlmUnavailableException(
        '${_serverNoun(target)} is throttling requests '
        '(HTTP 429). ${_snippet(bodyText)}',
      );
    }

    throw LlmException(
      '${_modelNoun(target)} rejected the request (HTTP $statusCode). '
      '${_snippet(bodyText)}',
      statusCode,
    );
  }

  Future<_Reply> _postInner(
    Map<String, dynamic> body, {
    required _Request request,
    required LlmTarget target,
  }) async {
    final url = _endpoint(target);
    final response = await _guardTransport(
      url,
      target,
      () => _http
          .post(url, headers: _headersFor(target), body: jsonEncode(body))
          .timeout(timeout),
    );

    if (response.statusCode != 200) {
      _throwForStatus(target, response.statusCode, _text(response));
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(_text(response));
    } on FormatException {
      throw LlmFormatException(
        '${_modelNoun(target)} answered with something that is not JSON.',
      );
    }
    if (decoded is! Map) {
      throw LlmFormatException(
        '${_modelNoun(target)} answered with an unexpected payload shape.',
      );
    }

    return switch (_wireOf(target)) {
      LlmWire.openAi =>
        _readOpenAi(decoded, target: target, think: request.think),
      LlmWire.bedrockConverse =>
        _readConverse(decoded, target: target, request: request),
    };
  }

  /// The same request with `stream: true`, read event by event.
  ///
  /// Everything this returns is what [_postInner] would have returned: the
  /// concatenated content as [_Reply.text], the server's own counters, and the
  /// same exceptions from the same helpers — so [_decoded] decodes it the same
  /// way, the observer records it the same way, and a stream that ended early
  /// is the same [LlmFormatException] a truncated plain answer is. The only
  /// thing that is new is [_Reply.firstTokenMs] and the deltas handed to
  /// [onText] on the way.
  ///
  /// The shape on the wire (llama.cpp b10621, probed rather than assumed; vLLM
  /// the same minus `timings`): `data: {…"choices":[{"delta":{"content":"…"}}]}`
  /// per token group, then a chunk with `"choices":[]` carrying `usage` and
  /// `timings`, then `data: [DONE]`. Blank lines separate events.
  Future<_Reply> _postStreamed(
    Map<String, dynamic> body, {
    required _Request request,
    required LlmTarget target,
    required void Function(String delta) onText,
  }) async {
    final url = _endpoint(target);
    final sw = Stopwatch()..start();

    final streamRequest = http.Request('POST', url)
      ..headers.addAll(_headersFor(target))
      ..body = jsonEncode({
        ...body,
        'stream': true,
        // Without this the final chunk carries no `usage` and the call
        // cannot be given a tokens-per-second number at all — which is half
        // of what every bench table is.
        'stream_options': {'include_usage': true},
      });
    final response = await _guardTransport(
      url,
      target,
      () => _http.send(streamRequest).timeout(timeout),
    );

    // What is left of the client's ceiling now the headers are in. Computed
    // ONCE here and spent by whichever read follows — the error body or the
    // answer — because the plain path's `.timeout` covers the whole round
    // trip, and a streamed call given a fresh ceiling per stage would be
    // waited on for a multiple of the number the setting says.
    final spent = sw.elapsed;
    final remaining = spent >= timeout ? Duration.zero : timeout - spent;

    if (response.statusCode != 200) {
      // Bounded like everything else: a server that answers 500 and then holds
      // the body open is the same wedged server the ceiling exists for, and
      // reading it unbounded would hang on the error path alone.
      final List<int> body;
      try {
        body = await response.stream.toBytes().timeout(remaining);
      } on TimeoutException {
        throw _timeoutException(target);
      }
      _throwForStatus(
        target,
        response.statusCode,
        utf8.decode(body, allowMalformed: true),
      );
    }

    final buffer = StringBuffer();
    int? firstTokenMs;
    int? promptTokens;
    int? completionTokens;
    int? serverPromptMs;
    int? serverPredictedMs;
    var reasoningNoted = false;

    // Answers true when the line ENDED the answer. `[DONE]` is the server
    // saying there is nothing more, and waiting for the socket to close after
    // it is waiting on a proxy's keep-alive for an answer already in hand.
    bool readLine(String line) {
      if (!line.startsWith('data:')) return false;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') return true;
      if (payload.isEmpty) return false;
      final Object? chunk;
      try {
        chunk = jsonDecode(payload);
      } on FormatException {
        // A tolerant reader beats a whole draft lost to one bad line. This
        // server never sends one; a proxy in front of it might.
        return false;
      }
      if (chunk is! Map) return false;

      // llama-server reports a mid-stream failure as an `error` object on a
      // chunk rather than as a status — the request was already 200 by then.
      if (chunk['error'] != null) {
        throw LlmException(
          '${_modelNoun(target)} failed mid-stream: ${_snippet(payload)}',
        );
      }

      // Read off whichever chunk carries them: llama.cpp puts both on the
      // choices-less final chunk, vLLM sends usage there and no timings.
      final usage = _usageOf(chunk['usage']);
      promptTokens = usage.prompt ?? promptTokens;
      completionTokens = usage.completion ?? completionTokens;
      final timings = _timingsOf(chunk['timings']);
      serverPromptMs = timings.promptMs ?? serverPromptMs;
      serverPredictedMs = timings.predictedMs ?? serverPredictedMs;

      final choices = chunk['choices'];
      if (choices is! List || choices.isEmpty) return false;
      final delta = choices.first is Map
          ? (choices.first as Map)['delta']
          : null;
      if (delta is! Map) return false;

      // Tripped once per call, not once per token: a thinking model would
      // otherwise fire the tripwire hundreds of times on one answer.
      final reasoning = delta['reasoning_content'];
      if (!reasoningNoted &&
          reasoning is String &&
          reasoning.trim().isNotEmpty) {
        reasoningNoted = true;
        _checkReasoningLeak(reasoning, think: request.think);
      }

      final content = delta['content'];
      if (content is! String || content.isEmpty) return false;
      firstTokenMs ??= sw.elapsedMilliseconds;
      buffer.write(content);
      try {
        onText(content);
      } catch (e) {
        // The observer must never break the observed — [EventBus]'s rule, one
        // layer down. A listener that threw costs its own preview, not the
        // draft.
        debugPrint('LlmClient: onText threw: $e');
      }
      return false;
    }

    // The WHOLE read runs under the client's timeout, not just the headers: a
    // server that answered and then stalled mid-answer is exactly the wedged
    // case the ceiling exists to catch, and an unguarded `await for` would
    // wait on it forever.
    final done = Completer<void>();
    final subscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        try {
          // `[DONE]` is the end of the answer, and the read ends with it —
          // the cancel in the `finally` below releases the socket rather than
          // waiting for a server or a proxy to close it.
          if (readLine(line) && !done.isCompleted) done.complete();
        } catch (e) {
          if (!done.isCompleted) done.completeError(e);
        }
      },
      onError: (Object e) {
        if (done.isCompleted) return;
        done.completeError(
          e is SocketException || e is http.ClientException
              ? LlmUnavailableException(_unreachable(target, url.toString()))
              : e,
        );
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );

    try {
      await done.future.timeout(remaining);
    } on TimeoutException {
      throw _timeoutException(target);
    } finally {
      // Every exit, not just the timeout: the `[DONE]` that ended the answer,
      // an error mid-stream, and the ceiling all leave a live subscription
      // behind otherwise — a socket reading into a future nobody is waiting
      // on any more.
      unawaited(subscription.cancel());
    }

    return (
      text: buffer.isEmpty ? null : buffer.toString(),
      json: null,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      serverPromptMs: serverPromptMs,
      serverPredictedMs: serverPredictedMs,
      firstTokenMs: firstTokenMs,
    );
  }

  /// The OpenAI answer: one choice, one message, and llama-server's own
  /// counters beside it.
  ///
  /// The content is returned as it came — a caller that asked for JSON decodes
  /// it, and a non-string content is that caller's format failure, which is
  /// where it has always been raised.
  _Reply _readOpenAi(
    Map<Object?, Object?> decoded, {
    required LlmTarget target,
    required bool think,
  }) {
    final choices = decoded['choices'];
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    if (message is! Map) {
      throw LlmFormatException(
        '${_modelNoun(target)} answered with no message content.',
      );
    }

    _checkReasoningLeak(message['reasoning_content'], think: think);

    final content = message['content'];
    final usage = _usageOf(decoded['usage']);
    final timings = _timingsOf(decoded['timings']);
    return (
      text: content is String ? content : null,
      json: null,
      promptTokens: usage.prompt,
      completionTokens: usage.completion,
      serverPromptMs: timings.promptMs,
      serverPredictedMs: timings.predictedMs,
      firstTokenMs: null,
    );
  }

  /// A tripwire, not a failure: the app still works, it just runs at half
  /// speed. It fires when a model swap ignores enable_thinking, which is the
  /// kind of regression that otherwise shows up only as "triage got slow".
  ///
  /// Read off the message on a plain answer and off a delta on a streamed one
  /// — the same field either way, which is why it is one check.
  void _checkReasoningLeak(Object? reasoning, {required bool think}) {
    if (think) return;
    if (reasoning is String && reasoning.trim().isNotEmpty) {
      _noteReasoningLeak();
    }
  }

  /// The token counts off an OpenAI `usage` block, wherever it arrived — in
  /// the body of a plain answer, or on whichever streamed chunk carried it.
  static ({int? prompt, int? completion}) _usageOf(Object? usage) => (
        prompt: usage is Map ? (usage['prompt_tokens'] as num?)?.toInt() : null,
        completion:
            usage is Map ? (usage['completion_tokens'] as num?)?.toInt() : null,
      );

  /// `timings` is llama-server's, not OpenAI's, and its milliseconds arrive as
  /// doubles — hence `as num?` before `.toInt()`, the same defensiveness the
  /// token counts get. A runtime that sends no such block reads as null rather
  /// than zero, because "did not say" and "took no time" have to stay
  /// distinguishable to anything averaging these.
  static ({int? promptMs, int? predictedMs}) _timingsOf(Object? timings) => (
        promptMs:
            timings is Map ? (timings['prompt_ms'] as num?)?.toInt() : null,
        predictedMs:
            timings is Map ? (timings['predicted_ms'] as num?)?.toInt() : null,
      );

  /// The Converse answer: a list of content blocks, one of which is the one
  /// this request asked for.
  ///
  /// The missing block is raised HERE rather than in the caller, unlike the
  /// OpenAI wire above: a forced tool call that came back as prose is the
  /// service failing the contract, and the observer has to see it as a format
  /// failure rather than as a successful call somebody threw away afterwards.
  _Reply _readConverse(
    Map<Object?, Object?> decoded, {
    required LlmTarget target,
    required _Request request,
  }) {
    final noun = _modelNoun(target);
    final output = decoded['output'];
    final message = output is Map ? output['message'] : null;
    final blocks = message is Map ? message['content'] : null;
    if (blocks is! List) {
      throw LlmFormatException('$noun answered with no message content.');
    }

    // Every text block, joined: Converse may split one assistant turn across
    // several, and a draft read from the first alone would be silently cut
    // short — scored as a poor draft rather than seen as a truncated one.
    final texts = <String>[];
    Map<String, dynamic>? json;
    var reasoned = false;
    for (final block in blocks) {
      if (block is! Map) continue;
      final blockText = block['text'];
      if (blockText is String) texts.add(blockText);
      final toolUse = block['toolUse'];
      final input = toolUse is Map ? toolUse['input'] : null;
      if (json == null && input is Map) {
        json = Map<String, dynamic>.from(input);
      }
      if (block['reasoningContent'] != null) reasoned = true;
    }
    final text = texts.isEmpty ? null : texts.join();

    // The same tripwire the other wire has, on the block a thinking model adds.
    if (!request.think && reasoned) _noteReasoningLeak();

    if (request.schema != null && json == null) {
      throw LlmFormatException(
        '$noun answered with no tool call, so it answered with no JSON.',
      );
    }
    // Parity with the other wire, where a constrained answer cut off by
    // `max_tokens` fails `jsonDecode` and is a format failure. Converse
    // assembles the tool input server-side, so a cut-off call can arrive as a
    // well-formed PARTIAL object — and only `stopReason` says so.
    if (request.schema != null && decoded['stopReason'] == 'max_tokens') {
      throw LlmFormatException(
        '$noun ran out of tokens before finishing the answer '
        '(stopReason max_tokens).',
      );
    }
    if (request.schema == null && text == null) {
      throw LlmFormatException('$noun answered with no message content.');
    }

    final usage = decoded['usage'];
    // Both server clocks stay null on this wire, deliberately. Converse
    // reports `metrics.latencyMs`, which is the whole request's latency and
    // not a generation time — and `TaskMetrics.timingSource` reads a
    // non-null `serverPredictedMs` as "this table's rate came from the
    // server's own clock". Mapping one into the other would have a Bedrock row
    // claim a generation rate nobody measured, so these rows are wall-clock.
    return (
      text: text,
      json: json,
      promptTokens:
          usage is Map ? (usage['inputTokens'] as num?)?.toInt() : null,
      completionTokens:
          usage is Map ? (usage['outputTokens'] as num?)?.toInt() : null,
      serverPromptMs: null,
      serverPredictedMs: null,
      firstTokenMs: null,
    );
  }

  void _noteReasoningLeak() {
    debugPrint(
      'LlmClient: enable_thinking was ignored — triage will be ~2x slower',
    );
    onReasoningLeak?.call();
  }

  /// llama-server sends `application/json` with no charset, which makes
  /// `http`'s `body` getter fall back to latin-1 and mangle anything
  /// non-ASCII the model echoed back out of an email.
  static String _text(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  static String _snippet(String text) {
    final trimmed = text.trim();
    return trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
  }
}
