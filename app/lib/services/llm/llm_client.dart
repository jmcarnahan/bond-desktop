import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'model_slots.dart';

/// The one HTTP call this app makes to the local model.
///
/// llama-server speaks the OpenAI chat-completions shape, so this is a plain
/// POST — no SDK, no streaming, no tools. Two details are load-bearing and
/// measured rather than guessed:
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
/// NOTHING in `lib/` sets either: the providers build this client on the
/// OpenAI wire with no token, so routing and the app's failure policy are
/// exactly what they were. The seam exists for the bakeoff
/// (`docs/model-bakeoff.md`, "Bedrock as a target") and for the speed design's
/// opt-in cloud drafts. The token is a request header and nothing else: it
/// never reaches an [LlmCallRecord], an exception message, or a log line.

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

/// The model answered, but not with the JSON object that was asked for.
class LlmFormatException extends LlmException {
  const LlmFormatException(super.message);
}

/// Which request shape a client puts on the wire.
enum LlmWire {
  /// OpenAI chat completions: llama-server, oMLX, and Bedrock's
  /// OpenAI-compatible endpoint. The app's own wire.
  openAi,

  /// AWS Bedrock Converse: the only wire Anthropic models are served on
  /// there. A JSON answer is a forced tool call rather than a
  /// `response_format`.
  bedrockConverse,
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

  /// Sent as `Authorization: Bearer …` on either wire when set, and read
  /// nowhere else in this file. Null for every client the app builds.
  final String? _bearerToken;

  /// Which request shape this client speaks. [LlmWire.openAi] everywhere in
  /// the app; a bench pointed at an Anthropic model on Bedrock passes
  /// [LlmWire.bedrockConverse].
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

  /// Whether this client is talking to somebody else's machine.
  ///
  /// Only the WORDING below turns on it. "start it, or change it in Settings"
  /// is advice about a server on this desk, and a cloud endpoint that answers
  /// 403 is not something the reader can go and launch.
  bool get _remote => _bearerToken != null || wire == LlmWire.bedrockConverse;

  String get _serverNoun =>
      _remote ? 'The model server' : 'The local model server';

  String get _modelNoun => _remote ? 'The model' : 'The local model';

  /// Names the server that did not answer. The old constant said
  /// "run: make model" for BOTH clients, which was wrong for the fast slot
  /// and wronger now that either can point anywhere.
  String _unreachable(String url) => _remote
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
    final reply = await _post((
      system: system,
      user: user,
      maxTokens: maxTokens,
      temperature: temperature,
      think: think,
      schema: null,
      schemaName: 'complete',
      label: 'complete',
    ));
    final text = reply.text;
    if (text == null) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
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
  }) async {
    final reply = await _post((
      system: system,
      user: user,
      maxTokens: maxTokens,
      temperature: temperature,
      think: think,
      schema: schema,
      schemaName: schemaName,
      label: schemaName,
    ));

    // Decoded inside [_post], on either wire, so a constrained call's reply
    // always arrives here as an object — see [_decoded] for why the decode
    // does not live in this method.
    final json = reply.json;
    if (json == null) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
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
  _Reply _decoded(_Reply reply, _Request request) {
    if (request.schema == null || reply.json != null) return reply;
    return (
      text: reply.text,
      json: _decodeObject(reply.text),
      promptTokens: reply.promptTokens,
      completionTokens: reply.completionTokens,
      serverPromptMs: reply.serverPromptMs,
      serverPredictedMs: reply.serverPredictedMs,
    );
  }

  Map<String, dynamic> _decodeObject(String? content) {
    if (content == null) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw LlmFormatException(
        '$_modelNoun did not answer with JSON: ${_snippet(content)}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw LlmFormatException(
        '$_modelNoun answered with ${decoded.runtimeType}, not a JSON '
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
    switch (wire) {
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
  Future<_Reply> _post(_Request request) async {
    // ONE resolution per request, for both the URL and the model name.
    final target = this.target;
    final body = switch (wire) {
      LlmWire.openAi => _openAiBody(request, target),
      LlmWire.bedrockConverse => _converseBody(request),
    };

    final observer = _onCall;
    if (observer == null) {
      return _decoded(
        await _postInner(body, request: request, target: target),
        request,
      );
    }

    final sw = Stopwatch()..start();
    try {
      final result = _decoded(
        await _postInner(body, request: request, target: target),
        request,
      );
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
      ));
      return result;
    } on LlmUnavailableException catch (e) {
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'unavailable',
        model: target.model,
        baseUrl: target.baseUrl,
        error: e.message,
      ));
      rethrow;
    } on LlmFormatException catch (e) {
      observer(LlmCallRecord(
        label: request.label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'format',
        model: target.model,
        baseUrl: target.baseUrl,
        error: e.message,
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
        error: e.message,
      ));
      rethrow;
    }
  }

  Future<_Reply> _postInner(
    Map<String, dynamic> body, {
    required _Request request,
    required LlmTarget target,
  }) async {
    final url = _endpoint(target);
    final http.Response response;
    try {
      response = await _http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              // The one place the token appears. It is never logged, never
              // recorded, and never put into an exception message.
              if (_bearerToken != null) 'Authorization': 'Bearer $_bearerToken',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException {
      throw LlmUnavailableException(_unreachable(url.toString()));
    } on http.ClientException {
      throw LlmUnavailableException(_unreachable(url.toString()));
    } on TimeoutException {
      // NOT [LlmUnavailableException]: the server accepted the connection, so
      // this is one request going wrong rather than a server that is down.
      // Counting it against the message is what stops a single pathological
      // email from blocking the queue behind it forever.
      throw LlmException(
        '$_modelNoun did not answer within ${timeout.inSeconds} seconds.',
      );
    }

    // A 5xx is the SERVER's condition, not this request's: llama-server
    // answers 503 for every request while its weights load. Counting that
    // against the item would burn the whole backlog's attempts against a
    // server that was seconds from healthy — the drain must park instead,
    // exactly as it does for a refused connection.
    if (response.statusCode >= 500) {
      throw LlmUnavailableException(
        '$_serverNoun is not ready '
        '(HTTP ${response.statusCode}). ${_snippet(_text(response))}',
      );
    }

    // A 429 is the same kind of thing one step further out: Bedrock throttles
    // with `ThrottlingException` and the request would succeed unchanged a few
    // seconds later. So it parks and is retried rather than costing the item,
    // exactly as a 503 does.
    if (response.statusCode == 429) {
      throw LlmUnavailableException(
        '$_serverNoun is throttling requests '
        '(HTTP 429). ${_snippet(_text(response))}',
      );
    }

    if (response.statusCode != 200) {
      throw LlmException(
        '$_modelNoun rejected the request (HTTP ${response.statusCode}). '
        '${_snippet(_text(response))}',
        response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(_text(response));
    } on FormatException {
      throw LlmFormatException(
        '$_modelNoun answered with something that is not JSON.',
      );
    }
    if (decoded is! Map) {
      throw LlmFormatException(
        '$_modelNoun answered with an unexpected payload shape.',
      );
    }

    return switch (wire) {
      LlmWire.openAi => _readOpenAi(decoded, think: request.think),
      LlmWire.bedrockConverse => _readConverse(decoded, request: request),
    };
  }

  /// The OpenAI answer: one choice, one message, and llama-server's own
  /// counters beside it.
  ///
  /// The content is returned as it came — a caller that asked for JSON decodes
  /// it, and a non-string content is that caller's format failure, which is
  /// where it has always been raised.
  _Reply _readOpenAi(Map<Object?, Object?> decoded, {required bool think}) {
    final choices = decoded['choices'];
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    if (message is! Map) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
    }

    // A tripwire, not a failure: the app still works, it just runs at half
    // speed. It fires when a model swap ignores enable_thinking, which is the
    // kind of regression that otherwise shows up only as "triage got slow".
    if (!think) {
      final reasoning = message['reasoning_content'];
      if (reasoning is String && reasoning.trim().isNotEmpty) {
        _noteReasoningLeak();
      }
    }

    final content = message['content'];
    final usage = decoded['usage'];
    // `timings` is llama-server's, not OpenAI's, and its milliseconds arrive
    // as doubles — hence `as num?` before `.toInt()`, the same defensiveness
    // the token counts get. A runtime that sends no such block reads as null
    // rather than zero, because "did not say" and "took no time" have to stay
    // distinguishable to anything averaging these.
    final timings = decoded['timings'];
    return (
      text: content is String ? content : null,
      json: null,
      promptTokens:
          usage is Map ? (usage['prompt_tokens'] as num?)?.toInt() : null,
      completionTokens:
          usage is Map ? (usage['completion_tokens'] as num?)?.toInt() : null,
      serverPromptMs:
          timings is Map ? (timings['prompt_ms'] as num?)?.toInt() : null,
      serverPredictedMs:
          timings is Map ? (timings['predicted_ms'] as num?)?.toInt() : null,
    );
  }

  /// The Converse answer: a list of content blocks, one of which is the one
  /// this request asked for.
  ///
  /// The missing block is raised HERE rather than in the caller, unlike the
  /// OpenAI wire above: a forced tool call that came back as prose is the
  /// service failing the contract, and the observer has to see it as a format
  /// failure rather than as a successful call somebody threw away afterwards.
  _Reply _readConverse(
    Map<Object?, Object?> decoded, {
    required _Request request,
  }) {
    final output = decoded['output'];
    final message = output is Map ? output['message'] : null;
    final blocks = message is Map ? message['content'] : null;
    if (blocks is! List) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
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
        '$_modelNoun answered with no tool call, so it answered with no JSON.',
      );
    }
    // Parity with the other wire, where a constrained answer cut off by
    // `max_tokens` fails `jsonDecode` and is a format failure. Converse
    // assembles the tool input server-side, so a cut-off call can arrive as a
    // well-formed PARTIAL object — and only `stopReason` says so.
    if (request.schema != null && decoded['stopReason'] == 'max_tokens') {
      throw LlmFormatException(
        '$_modelNoun ran out of tokens before finishing the answer '
        '(stopReason max_tokens).',
      );
    }
    if (request.schema == null && text == null) {
      throw LlmFormatException('$_modelNoun answered with no message content.');
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
