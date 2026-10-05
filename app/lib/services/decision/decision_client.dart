/// The decision model's client: render a message's state, have the decision
/// server answer the nine fields over it — and the same for the storyline
/// questions ([DecisionClient.ask]), over texts `storyline_state.dart`
/// rendered.
///
/// The server is one of two KINDS ([DecisionServerKind]), and every caller
/// uses the same public API whichever it is:
///
/// - **encoder-heads**: a stock llama-server serving the fine-tuned encoder
///   as a mean-pooled embedding model (the managed router, `make decide` on
///   :8083, or ModernBERT on the owner's server). It answers
///   `/v1/embeddings` with the raw pooled vector, and the heads that turn the
///   vector into answers run here (`decision_heads.dart`), off this Mac's
///   heads file.
/// - **systemone**: Kev 4B behind jev-prototype's wrapper on the owner's
///   server (contract §3.4). It is asked the questions' plain text
///   (`decision_questions.dart`) over the same rendered state at
///   `<base>/v1/systemone` and answers CALIBRATED probabilities, so nothing
///   is applied here and no file on this Mac is read.
///
/// A managed or hand-started target is always encoder-heads. A target on
/// Your server ([DecisionClient]'s `isYourServer`) is asked `/v1/models`
/// once: an entry carrying a `qhash` is a systemone server, checked against
/// [decisionQhash] and the renderer; anything else is encoder-heads.
///
/// Two encoder wire details were measured in the model's parity spike and are
/// load-bearing:
///
/// - `embd_normalize: -1` on every request. llama-server L2-normalises by
///   default and the heads were trained on the RAW vector; a linear layer
///   with a bias is not scale-invariant, so a normalised vector gives
///   confident wrong answers. A vector whose norm is 1.0 is therefore refused
///   as a format error — the belt against a server that ignored the field.
/// - llama-server REFUSES an input longer than its context (HTTP 500, `input
///   (N tokens) is too large to process`) rather than truncating it, while the
///   model was trained on states truncated at 2048 tokens from the end. So a
///   long state is tokenized, cut to `maxTokens - 2` ids, wrapped in the
///   model's own `[CLS]`/`[SEP]` and sent as a token array, which gives the
///   same vector HF truncation gave.
///
/// Before the first embedding a target gets, `/tokenize` is asked to add the
/// specials to `"a"`, and anything but `[CLS] … [SEP]` is a server of the
/// wrong kind (see `_verifyServer`).
///
/// Unlike `EmbeddingsClient` this THROWS: the triage queue must park when the
/// decision model is down, exactly as it parks for the generating model.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, TlsException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

import '../llm/llm_client.dart';
import '../llm/model_slots.dart'
    show LlmTarget, decideModelDefault, decideUrlDefault, normalizeBoxBaseUrl;
import 'decision_heads.dart';
import 'decision_input.dart';
import 'decision_questions.dart';
import 'decision_state.dart';
import 'storyline_state.dart' show renderStorylinePair;

/// What the decision role's server is. Every [DecisionClient] call answers
/// the same questions whichever it is; only the wire and where the heads run
/// differ.
enum DecisionServerKind {
  /// ModernBERT on llama-server: raw vectors, this Mac's heads file applied
  /// here.
  encoderHeads,

  /// Kev 4B behind the `systemone` wrapper: calibrated answers there, and no
  /// file needed on this Mac.
  systemOne,
}

/// One message's decision, and what produced it.
@immutable
class DecisionResult {
  final DecisionAnswers answers;

  /// The exact text the model read — what the Why panel can show.
  final String state;

  /// The heads file's model name, or the systemone server's.
  final String model;

  /// Wall time of the whole call, rendering included. A result from
  /// [DecisionClient.decideBatch] carries the batch's wall time.
  final int latencyMs;

  /// The state was longer than the model's context and was cut to it.
  final bool truncated;

  /// The encoder's raw pooled vector the heads read ([DecisionHeads.width]
  /// wide, not normalised), or null on a backend that answers probabilities
  /// itself (`systemone`). The owner's Needs You labels keep it, so a press
  /// can recognise near-duplicate mail (`NeedsYouExemplars`).
  final List<double>? vector;

  const DecisionResult({
    required this.answers,
    required this.state,
    required this.model,
    required this.latencyMs,
    this.truncated = false,
    this.vector,
  });

  /// This result with [answers] in place of its own — how the owner's Needs
  /// You answer replaces the model's before the decision is stored.
  DecisionResult withAnswers(DecisionAnswers answers) => DecisionResult(
        answers: answers,
        state: state,
        model: model,
        latencyMs: latencyMs,
        truncated: truncated,
        vector: vector,
      );
}

/// The per-call facts the one [LlmCallRecord] reports, gathered across the
/// one to three HTTP requests a decision can take.
class _CallFacts {
  int? statusCode;

  /// The target is the owner's own server, whose sentences must not tell
  /// anyone to `make decide`: that command starts a server on this Mac.
  final bool yourServer;

  /// The target is this app's own router, which nobody starts by hand: its
  /// sentences point at Settings, Models instead of a command.
  final bool managed;

  _CallFacts({this.yourServer = false, this.managed = false});
}

/// The first sentence of every "the server's vectors are not the decision
/// model's" misconfiguration. No URL and no key: it is shown as it stands.
const String rawEmbeddingsText =
    'The decision server did not answer with raw embeddings from the '
    'decision model. Check its address in Settings, Models.';

/// The identity probe's refusal: the server at [origin] tokenizes, but not
/// as ModernBERT does, so it is some other model — the embedding model on
/// the next port is the one it is most likely to be.
String notDecisionModelText(String origin) =>
    'The server at $origin is not the decision model: its tokenizer is not '
    "ModernBERT's. Check its address in Settings, Models.";

/// A server with no `/tokenize` at [origin]: the identity probe and a long
/// message's truncation both need it, so nothing it answers can be used.
String noTokenizeText(String origin) =>
    'The server at $origin does not offer /tokenize, which the decision '
    'model needs. Check its address in Settings, Models.';

/// A server with no `/v1/embeddings` at [origin]: an encoder-heads decision
/// server answers every question there, so nothing it answers can be used.
String noEmbeddingsText(String origin) =>
    'The server at $origin does not offer /v1/embeddings, which the decision '
    'model needs. Check its address in Settings, Models.';

/// The served GGUF ([file], its name only) is not the model [model] the
/// heads file on this Mac was trained with: heads applied to another
/// encoder's vectors answer confidently and wrongly.
String modelMismatchText(String file, String model) =>
    'The decision model file ($file) does not match its heads file '
    '($model). Install them together.';

/// A systemone server at [origin] trained on another question set: its
/// answers would be to other questions, so none is used.
String systemOneQhashText(String origin, Object? qhash) =>
    'The decision server at $origin answers question set $qhash, not '
    '$decisionQhash, so it is another version of the decision model. Check '
    'its address in Settings, Models.';

/// A systemone server at [origin] that reads another renderer's states: the
/// states this build renders are not the ones it was trained on.
String systemOneRendererText(String origin, Object? renderer) =>
    'The decision server at $origin reads states rendered as $renderer, not '
    '$decisionRendererVersion, so it does not match this build. Check its '
    'address in Settings, Models.';

class DecisionClient {
  /// Overridable at build time (`--dart-define=DECIDE_URL=…`), like
  /// `EMBED_URL`. The FULL endpoint, as every target's `baseUrl` is.
  /// A const alias of `decideUrlDefault` in `model_slots.dart`, where the
  /// prefs compose the hand-servers decision target from it.
  static const String defaultBaseUrl = decideUrlDefault;

  /// The `model` field on the wire. A single-model llama-server ignores it;
  /// the managed router routes on it.
  static const String defaultModel = decideModelDefault;

  /// ModernBERT's `[CLS]` and `[SEP]` ids — what a token-array input must
  /// carry itself, since the server adds no specials to one.
  static const int clsId = 50281, sepId = 50282;

  /// A state longer than this many UTF-16 code units (`String.length`, not
  /// characters) skips the text request and goes straight to the token path.
  /// Measured: nothing this long fitted 2048 tokens, and the pre-check keeps
  /// the refused request off the common path. The body cap counts code
  /// points, so only text outside the BMP (emoji) reaches it; the server's
  /// too-large refusal is the ordinary trigger.
  static const int longStateChars = 6000;

  /// At most this many states per array request. Measured at about 42.6 ms a
  /// message in a 16-input array on the Mac, so a chunk stays far under the
  /// per-request [timeout] however long the backlog handed to [decideBatch].
  static const int batchChunk = 16;

  /// At most this many systemone requests in flight at once. Each carries
  /// one state, so a backlog is many requests, and the wrapper batches what
  /// arrives together on the GPU.
  static const int systemOneInFlight = 8;

  /// The phrase llama-server's refusal of an over-long input carries.
  static const String _tooLargePhrase = 'too large to process';

  /// The targets whose identity probe PASSED, as `'<baseUrl>|<model>'`. Only
  /// a success is kept: a probe that failed is asked again on the next call,
  /// so a server that was down, or an address that was fixed, recovers
  /// without anybody pressing anything.
  final Set<String> _verified = {};

  /// Your server's kind, by `'<baseUrl>|<model>'`, on [_verified]'s rule:
  /// only a success is kept, and it is forgotten whenever the server stops
  /// answering or refuses the key.
  final Map<String, _ServerKind> _kinds = {};

  /// The heads' model each target's served file was checked against, by
  /// [_keyOf], on [_verified]'s rule: only a pass (or a listing that named no
  /// file) is kept, and it is forgotten with the identity probe's pass.
  final Map<String, String> _paired = {};

  /// The GGUF a MANAGED target serves, by name, or null for any other target
  /// (then the server's own `/v1/models` is read). The managed router lists
  /// only its preset ids, so the manifest is what names its file.
  final String? Function(LlmTarget target)? _servedFile;

  final LlmTarget Function() _resolveTarget;
  final DecisionHeads Function() _heads;
  final http.Client _http;
  final void Function(LlmCallRecord record)? _onCall;

  /// Whether a resolved target is the owner's own server, whose kind has to
  /// be asked. A managed or hand-started target is always encoder-heads and
  /// costs no extra request, and so is every target when this is null.
  final bool Function(LlmTarget target)? _isYourServer;

  /// Whether a target on this Mac is the app's own router rather than a
  /// hand-started server, which decides what an unreachable sentence tells
  /// the reader to do. Null answers no: the hand-server words.
  final bool Function()? _isManaged;

  /// Per HTTP request, not per decision. A 395M encoder answers in tens of
  /// milliseconds; this ceiling is for a wedged server.
  final Duration timeout;

  final DateTime Function(DateTime utc)? _toLocal;

  DecisionClient({
    // `this._…` in a named parameter, as `EmbeddingsClient` declares its
    // resolver: callers name them `resolveTarget:` and the rest, and the
    // fields stay private.
    required this._resolveTarget,
    required this._heads,
    http.Client? client,
    this._onCall,
    this.timeout = const Duration(seconds: 15),
    this._toLocal,
    this._isYourServer,
    this._isManaged,
    this._servedFile,
  }) : _http = client ?? http.Client();

  /// Where the next request goes, resolved ONCE per call so its URL, model
  /// and key belong to one target.
  ///
  /// A resolver that throws falls back to the compiled default rather than
  /// failing the call — `EmbeddingsClient.target`'s guard, for its reason: the
  /// resolver reads a container this client does not own, and one torn down
  /// mid-drain must degrade rather than throw from inside the client.
  LlmTarget get target {
    try {
      return _resolveTarget();
    } catch (_) {
      return const LlmTarget(baseUrl: defaultBaseUrl, model: defaultModel);
    }
  }

  /// One message's answers. Throws [DecisionUnavailableException] when the
  /// server is not answering ([DecisionNotInstalledException] when the model
  /// or its heads are not on this Mac, [DecisionMisconfiguredException] when
  /// the heads or the server's answers fail every message alike),
  /// [DecisionUnauthorizedException] when it refused the key, and
  /// [LlmFormatException] only when the server rejected this one request or
  /// a systemone server's answer to it did not validate.
  Future<DecisionResult> decide(DecisionInput input) async {
    final sw = Stopwatch()..start();
    final destination = target;
    return _instrumented(destination, sw, 'decision', (facts) async {
      final backend = await _backendFor(destination, facts);
      return backend.one(renderDecisionState(input, toLocal: _toLocal), sw);
    });
  }

  /// Many messages' answers, in [inputs] order, in as few requests as the
  /// states allow: the short states in array requests of up to [batchChunk],
  /// and each long one on its own token path (a systemone server: one
  /// request per state, [systemOneInFlight] at a time). One [LlmCallRecord]
  /// for the whole batch.
  Future<List<DecisionResult>> decideBatch(List<DecisionInput> inputs) =>
      decideStates([
        for (final input in inputs)
          renderDecisionState(input, toLocal: _toLocal),
      ]);

  /// [decideBatch] over states already rendered — the golden harness's
  /// entry, which renders each item from the packer's parts through
  /// `renderDecisionStateFromParts` (the composer `renderDecisionState`
  /// itself calls), because the golden set carries those parts and not the
  /// raw fields. The app always goes through [decide] or [decideBatch].
  Future<List<DecisionResult>> decideStates(List<String> states) async {
    if (states.isEmpty) return const [];
    final sw = Stopwatch()..start();
    final destination = target;
    return _instrumented(destination, sw, 'decision', (facts) async {
      final backend = await _backendFor(destination, facts);
      return backend.message(states, sw);
    });
  }

  /// The encoder's raw pooled vector for each of [texts], in order, with no
  /// heads applied — the calendar command head's input
  /// (`services/calendar/command/command_heads.dart`), which is a second
  /// head fitted on the same encoder and so must read exactly what the nine
  /// read: [_vectors], the one embed-and-check path — the identity probe,
  /// the heads pairing, `embd_normalize: -1`, the width and norm refusals,
  /// and a long text on the token path.
  ///
  /// Only the encoder-heads kind has a raw vector. Your server of the
  /// systemone kind (Kev) answers questions already calibrated and gives
  /// none, so it is refused with a plain [LlmException] — the server is not
  /// unavailable, and its kind stays learned — which the command classifier
  /// reads as "no head" and leaves the command to the lexicon.
  ///
  /// One [LlmCallRecord] labelled `command_head` for the call, unless
  /// [report] is false: the Day bar's live preview asks on keystrokes, and a
  /// tally with no unit of work of its own would be folded into whatever
  /// activity row is written next. Throws what [decideStates] throws.
  Future<List<List<double>>> embedRaw(
    List<String> texts, {
    bool report = true,
  }) async {
    if (texts.isEmpty) return const [];
    final sw = Stopwatch()..start();
    final destination = target;
    return _instrumented(destination, sw, 'command_head', (facts) async {
      final backend = await _backendFor(destination, facts);
      if (backend is! _EncoderHeadsBackend) {
        throw const LlmException(
          'The decision server answers as Kev, which gives no raw vector for '
          'the command head; the lexicon reads commands alone.',
        );
      }
      final heads = _heads();
      final (vectors, _) = await _vectors(texts, destination, heads, facts);
      return vectors;
    }, report: report);
  }

  /// [question]'s calibrated p(yes) for each of [states], in order: texts
  /// already rendered by the question's renderer (`storyline_state.dart`).
  ///
  /// The same transport as [decideStates] — the kind, the identity probe,
  /// the raw vector checks, the too-large truncation, every exception and
  /// park; for a systemone server one request per state carrying this one
  /// question — and one [LlmCallRecord] labelled `decision:<question id>`,
  /// so the activity pane tells a storyline question from a message
  /// decision.
  Future<List<double>> ask(
    StorylineQuestion question,
    List<String> states,
  ) async {
    if (states.isEmpty) return const [];
    final sw = Stopwatch()..start();
    final destination = target;
    return _instrumented(destination, sw, 'decision:${question.id}',
        (facts) async {
      final backend = await _backendFor(destination, facts);
      return backend.yes(question, states);
    });
  }

  /// Throws what a question would throw when the decision model plainly
  /// cannot answer, and asks it nothing: a managed model the router does not
  /// serve, Your server's kind (asked once and cached, as any call asks it),
  /// and for the encoder-heads kind the heads file on this Mac. A server that
  /// is merely down is found by the first real question.
  ///
  /// For a caller about to spend a language-model call on work only the
  /// decision model can finish — the sweep names a cluster before it asks
  /// `member_of` about it — so a parked decision model parks that caller
  /// first. No [LlmCallRecord]: nothing was asked.
  Future<void> ensureReady() async {
    final destination = target;
    if (destination.unavailable case final why?) {
      throw DecisionNotInstalledException(why);
    }
    final facts =
        _CallFacts(yourServer: _yours(destination), managed: _managed());
    try {
      final backend = await _backendFor(destination, facts);
      if (backend is _EncoderHeadsBackend) _heads();
    } on LlmUnavailableException catch (e) {
      // [_instrumented]'s rule: a kind or a probe that failed is asked again.
      if (e is DecisionUnavailableException ||
          e is DecisionUnauthorizedException) {
        _verified.remove(_keyOf(destination));
        _kinds.remove(_keyOf(destination));
        _paired.remove(_keyOf(destination));
      }
      rethrow;
    }
  }

  /// Which model answers this client's questions right now, as a short
  /// string that changes whenever the answers could:
  /// `heads:<model>@<file sha>` for the encoder-heads kind (the heads run
  /// here, so the file names the model), `systemone:<listed name>` for Your
  /// server's Kev wrapper.
  /// Cheap: the heads are cached per file modification and a server's kind
  /// per address. The golden pairs bench prints its backend word. Throws what
  /// [ensureReady] throws.
  Future<String> modelIdentity() async {
    final destination = target;
    if (destination.unavailable case final why?) {
      throw DecisionNotInstalledException(why);
    }
    final facts =
        _CallFacts(yourServer: _yours(destination), managed: _managed());
    if (facts.yourServer) {
      final kind = await _resolveKind(destination, facts);
      if (kind.kind == DecisionServerKind.systemOne) {
        return 'systemone:${kind.model}';
      }
    }
    final heads = _heads();
    return 'heads:${heads.model}@${heads.fingerprint}';
  }

  /// The tag a fresh decision's vector would carry right now
  /// ([DecisionResult.model] on the encoder-heads kind: the heads file's
  /// model), or null when this client would answer with no vector or cannot
  /// say without asking: the target unavailable, the heads file missing or
  /// refused, Your server of the systemone kind, or Your server whose kind
  /// this run has not learned yet. Synchronous and never a request — the
  /// heads are cached per file modification and a server's kind per address.
  ///
  /// Callers read it through [resolvedModelTag]: the owner's Needs You
  /// presses, to tell a stored decision's vector they can compare from one
  /// they cannot (`NeedsYouEdits`; a press that finds null asks the model,
  /// which is harmless), and the needs-you pass.
  String? get modelTag {
    final destination = target;
    if (destination.unavailable != null) return null;
    if (_yours(destination) &&
        _kinds[_keyOf(destination)]?.kind != DecisionServerKind.encoderHeads) {
      return null;
    }
    try {
      return _heads().model;
    } catch (_) {
      return null;
    }
  }

  /// [modelTag], after learning Your server's kind when this run has not:
  /// one listing GET per address, cached as every call caches it. What the
  /// needs-you pass reads (`NeedsYouHandler`), which otherwise never makes a
  /// request and so would read null for every item of the vector backfill
  /// on Your server and copy them all. A kind that cannot be learned (the
  /// server down, the key refused, another question set) answers null,
  /// which owes nothing, so the pass copies as before rather than parking.
  Future<String?> resolvedModelTag() async {
    final destination = target;
    if (destination.unavailable != null) return null;
    if (_yours(destination) && !_kinds.containsKey(_keyOf(destination))) {
      try {
        await _resolveKind(destination, _CallFacts(yourServer: true));
      } on LlmException {
        return null;
      }
    }
    return modelTag;
  }

  /// `same_effort` for each pair of thread texts (`renderStorylineThread`),
  /// in order: the mean of p(yes) over both orders, A-then-B and B-then-A,
  /// which is how the model was trained and how the contract asks it. Both
  /// orders of every pair go out together, batched as [ask] batches.
  Future<List<double>> askPairs(List<(String, String)> pairs) async {
    if (pairs.isEmpty) return const [];
    final p = await ask(StorylineQuestion.sameEffort, [
      for (final (a, b) in pairs) ...[
        renderStorylinePair(a, b),
        renderStorylinePair(b, a),
      ],
    ]);
    return [
      for (var i = 0; i < pairs.length; i++) (p[2 * i] + p[2 * i + 1]) / 2,
    ];
  }

  /// Every state's raw vector, in [states] order, and whether ids had to be
  /// cut to get it: the one embed-and-check path [decideStates] and [ask]
  /// share. The short states go in array requests of up to [batchChunk] and
  /// each long one on its own token path; the identity probe runs once,
  /// before the first array.
  Future<(List<List<double>>, List<bool>)> _vectors(
    List<String> states,
    LlmTarget destination,
    DecisionHeads heads,
    _CallFacts facts,
  ) async {
    await _verifyServer(destination, facts);
    await _checkPairing(destination, heads, facts);
    final vectors = List<List<double>?>.filled(states.length, null);
    final truncated = List<bool>.filled(states.length, false);

    final short = [
      for (var i = 0; i < states.length; i++)
        if (states[i].length <= longStateChars) i,
    ];
    for (var start = 0; start < short.length; start += batchChunk) {
      final chunk = short.sublist(
        start,
        math.min(start + batchChunk, short.length),
      );
      final answered = await _embed(
        destination,
        [for (final i in chunk) states[i]],
        heads,
        facts,
        textRequest: true,
      );
      if (answered == null) {
        // One of them is over the context and the server refused the whole
        // array. Each goes on its own, and only the long one pays for it.
        for (final i in chunk) {
          final (vector, cut) =
              await _vectorFor(states[i], destination, heads, facts);
          vectors[i] = vector;
          truncated[i] = cut;
        }
      } else {
        for (var j = 0; j < chunk.length; j++) {
          vectors[chunk[j]] = answered[j];
        }
      }
    }
    for (var i = 0; i < states.length; i++) {
      if (vectors[i] != null) continue;
      final (vector, cut) =
          await _truncatedVector(states[i], destination, heads, facts);
      vectors[i] = vector;
      truncated[i] = cut;
    }
    return ([for (final v in vectors) v!], truncated);
  }

  /// For a Connect that must not write a server of the wrong kind: whether
  /// the server at [url], asked for [model], is the decision model. Its kind
  /// is asked first (`/v1/models`); a systemone server is checked there, and
  /// an encoder-heads server gets the same identity probe [decide] makes
  /// before its first request. A pass here spares that first request both,
  /// and [kindOf] then answers for the address. Null when it is; otherwise
  /// the sentence to show under the form, which carries no key.
  Future<String?> checkServer({
    required String url,
    required String model,
    String? bearer,
  }) async {
    final destination = LlmTarget(
      baseUrl: normalizeBoxBaseUrl(url),
      model: model,
      bearer: bearer,
    );
    try {
      final facts = _CallFacts(yourServer: true);
      final kind = await _resolveKind(destination, facts);
      if (kind.kind == DecisionServerKind.encoderHeads) {
        await _verifyServer(destination, facts);
      }
      return null;
    } on LlmException catch (e) {
      // A refused server has no kind worth showing, whichever step refused.
      _kinds.remove(_keyOf(destination));
      return e.message;
    }
  }

  /// The kind of the server at [url] asked for [model], once a call or a
  /// [checkServer] has found it and while it keeps answering; null before
  /// then. What the Models page says under Your server's form.
  DecisionServerKind? kindOf({required String url, required String model}) =>
      _kinds[_keyOf(LlmTarget(baseUrl: url, model: model))]?.kind;

  /// The ONE cache key [_verified] and [_kinds] share: the normalised
  /// address and the model, so a Connect's check and the stored URL meet.
  static String _keyOf(LlmTarget destination) =>
      '${normalizeBoxBaseUrl(destination.baseUrl)}|${destination.model}';

  /// Asks Your server's kind with one listing GET and fills the cache
  /// [kindOf] reads: what the Models page does when it opens on a server
  /// whose kind this run has not seen yet. Null when the server did not say
  /// (down, the key refused, another question set); nothing is thrown.
  Future<DecisionServerKind?> detectKind({
    required String url,
    required String model,
    String? bearer,
  }) async {
    final destination = LlmTarget(
      baseUrl: normalizeBoxBaseUrl(url),
      model: model,
      bearer: bearer,
    );
    try {
      return (await _resolveKind(destination, _CallFacts(yourServer: true)))
          .kind;
    } on LlmException {
      return null;
    }
  }

  /// Whether [destination] is Your server, by the provider's predicate; no
  /// predicate answers no.
  bool _yours(LlmTarget destination) =>
      _isYourServer?.call(destination) ?? false;

  /// Whether this Mac's target is the app's own router; a predicate that
  /// throws answers no.
  bool _managed() {
    try {
      return _isManaged?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The backend that answers for [destination]: encoder-heads for a managed
  /// or hand-started target without a request, else whatever [_resolveKind]
  /// finds.
  Future<_DecisionBackend> _backendFor(
    LlmTarget destination,
    _CallFacts facts,
  ) async {
    if (!facts.yourServer) {
      return _EncoderHeadsBackend(this, destination, facts);
    }
    final kind = await _resolveKind(destination, facts);
    return switch (kind.kind) {
      DecisionServerKind.encoderHeads =>
        _EncoderHeadsBackend(this, destination, facts),
      DecisionServerKind.systemOne =>
        _SystemOneBackend(this, destination, facts, kind.model),
    };
  }

  /// Your server's kind, once per target: `GET <base>/v1/models`. A listed
  /// model carrying a `qhash` is a systemone server, refused unless it is
  /// [decisionQhash] over [decisionRendererVersion]. Anything else is
  /// encoder-heads, whose own identity probe then decides whether it is the
  /// decision model: a listing with no `qhash` entry (an empty one included),
  /// and every answer that is not a listing at all — any other 4xx, a 200
  /// that is not a JSON object. Only the server's condition keeps its
  /// mapping: transport, 5xx and 429 park as unavailable, 401/403 as the key.
  Future<_ServerKind> _resolveKind(
    LlmTarget destination,
    _CallFacts facts,
  ) async {
    final key = _keyOf(destination);
    final known = _kinds[key];
    if (known != null) return known;
    final url = systemOneUrlFor(destination.baseUrl, 'models');
    Map<String, Object?>? listing;
    try {
      listing = await _requestJson(url, destination, null, facts,
          listingRequest: true);
    } on _NoListing {
      listing = null;
    }
    final entry =
        listing == null ? null : _systemOneEntry(listing, destination);
    final _ServerKind kind;
    if (entry == null) {
      kind = _ServerKind(
        DecisionServerKind.encoderHeads,
        '',
        listedFile: listing == null ? null : _listedGguf(listing, destination),
      );
    } else {
      final origin = _origin(url);
      if (entry['qhash'] != decisionQhash) {
        throw DecisionMisconfiguredException(
            systemOneQhashText(origin, entry['qhash']));
      }
      if (entry['renderer'] != decisionRendererVersion) {
        throw DecisionMisconfiguredException(
            systemOneRendererText(origin, entry['renderer']));
      }
      final name = entry['name'] ?? entry['id'];
      kind = _ServerKind(
        DecisionServerKind.systemOne,
        name is String && name.isNotEmpty ? name : destination.model,
      );
    }
    _kinds[key] = kind;
    return kind;
  }

  /// The listed model that marks [listing] a systemone server: an entry of
  /// `models` (or the OpenAI-shaped `data`) carrying `qhash`, the one named
  /// [destination]'s model first. Null when none carries one.
  static Map<Object?, Object?>? _systemOneEntry(
    Map<String, Object?> listing,
    LlmTarget destination,
  ) {
    final marked = [
      for (final list in [listing['models'], listing['data']])
        if (list is List)
          for (final entry in list)
            if (entry is Map && entry.containsKey('qhash')) entry,
    ];
    if (marked.isEmpty) return null;
    for (final entry in marked) {
      if (entry['name'] == destination.model ||
          entry['id'] == destination.model) {
        return entry;
      }
    }
    // None under the stored name: the wrapper serves one model, whatever it
    // was renamed to, so the first marked entry is that model. Its qhash and
    // renderer are still checked, and its own name is what answers record.
    return marked.first;
  }

  /// One `POST <base>/v1/systemone` for one rendered [state] and
  /// [questions], asked in the plain framing (the instructions verbatim,
  /// null criteria in canonical option order), and each question's checked
  /// probabilities. Calibrated there: nothing is applied here.
  ///
  /// The FULL state goes out, uncut: the wrapper owns Kev's context limit,
  /// and a state it refuses (a 413 or 422) is that one message's format
  /// failure, not a park.
  Future<Map<String, Map<String, double>>> _systemOne(
    LlmTarget destination,
    String state,
    List<SystemOneQuestion> questions,
    _CallFacts facts,
  ) async {
    final decoded = await _requestJson(
      systemOneUrlFor(destination.baseUrl, 'systemone'),
      destination,
      {
        'state': state,
        'questions': {
          for (final q in questions)
            q.id: {
              'type': 'choice',
              'instructions': q.instructions,
              'criteria': {for (final o in q.options) o: null},
            },
        },
      },
      facts,
      systemOneRequest: true,
    );
    return _checkedAnswers(decoded, questions);
  }

  /// [decoded]'s probabilities for every one of [questions], or a
  /// [DecisionMisconfiguredException] saying what is wrong: an asked id
  /// missing, an option set that is not the question's, a value outside
  /// [0, 1], or a set that does not sum to 1 within 1e-3. A wrapper that
  /// answers one state this way answers them all this way, so the role parks
  /// rather than failing every message in turn.
  static Map<String, Map<String, double>> _checkedAnswers(
    Map<String, Object?> decoded,
    List<SystemOneQuestion> questions,
  ) {
    Never refuse(String why) => throw DecisionMisconfiguredException(
        'The decision server answered $why. Check its address in Settings, '
        'Models.');
    final answers = decoded['answers'];
    if (answers is! Map) refuse('with no answers');
    final out = <String, Map<String, double>>{};
    for (final q in questions) {
      final answer = answers[q.id];
      final probabilities = answer is Map ? answer['probabilities'] : null;
      if (probabilities is! Map) refuse('no probabilities for ${q.id}');
      if (probabilities.length != q.options.length ||
          !q.options.every(probabilities.containsKey)) {
        refuse('${q.id} with options other than ${q.options.join(', ')}');
      }
      final ps = <String, double>{};
      var sum = 0.0;
      for (final option in q.options) {
        final p = probabilities[option];
        if (p is! num || !p.isFinite || p < 0 || p > 1) {
          refuse('${q.id} with a probability outside 0 to 1');
        }
        ps[option] = p.toDouble();
        sum += p;
      }
      if ((sum - 1).abs() > 1e-3) {
        refuse('${q.id} with probabilities that do not sum to 1');
      }
      out[q.id] = ps;
    }
    return out;
  }

  /// [each] for every index below [count], [systemOneInFlight] at a time,
  /// the results in index order. The first failure stops new requests and
  /// is rethrown once the ones in flight finish.
  static Future<List<T>> _pooled<T>(
    int count,
    Future<T> Function(int i) each,
  ) async {
    final out = List<T?>.filled(count, null);
    var next = 0;
    var failed = false;
    Future<void> worker() async {
      while (!failed && next < count) {
        final i = next++;
        try {
          out[i] = await each(i);
        } catch (_) {
          failed = true;
          rethrow;
        }
      }
    }

    await Future.wait([
      for (var w = 0; w < math.min(systemOneInFlight, count); w++) worker(),
    ]);
    return [for (final v in out) v as T];
  }

  /// The identity probe, once per target: `/tokenize` with the specials
  /// added must answer ModernBERT's `[CLS] … [SEP]`. The vector checks below
  /// cannot tell the decision model from the embedding model — both answer
  /// 1024 raw numbers, and llama-server echoes the request's `model` back —
  /// but the tokenizers differ, and a message decided on the wrong model's
  /// vectors can be learned-gated into Dropped with no error anywhere.
  Future<void> _verifyServer(LlmTarget destination, _CallFacts facts) async {
    final key = _keyOf(destination);
    if (_verified.contains(key)) return;
    final url = tokenizeUrlFor(destination.baseUrl);
    final decoded = await _postJson(
      url,
      destination,
      {'model': destination.model, 'content': 'a', 'add_special': true},
      facts,
      tokenizeRequest: true,
    );
    final tokens = decoded['tokens'];
    if (tokens is! List ||
        tokens.isEmpty ||
        tokens.first != clsId ||
        tokens.last != sepId) {
      throw DecisionMisconfiguredException(notDecisionModelText(_origin(url)));
    }
    _verified.add(key);
  }

  /// The heads↔GGUF pairing, once per target and heads model: the name of
  /// the file the server serves must BE the heads' `model` plus at most a
  /// quant and the extension ([servesHeadsModel]: `bond-decide-mbl-v3` in
  /// `bond-decide-mbl-v3-f16.gguf`, never in `bond-decide-mbl-v3-cont2-f16.gguf`,
  /// another fine-tune whose name merely starts the same). The identity
  /// probe cannot see this — every ModernBERT tokenizes alike — and heads
  /// applied to another fine-tune's vectors answer confidently and wrongly,
  /// so a mismatch is a [DecisionModelMismatchException] and parks.
  ///
  /// The file comes from [_servedFile] for a managed target (the manifest),
  /// from the listing [_resolveKind] already read for Your server, and from
  /// one `GET <base>/v1/models` for a hand-started server. A listing that
  /// names no `.gguf` and no `bond-decide-…` served name (none at all, or
  /// only a bare alias) is skipped rather than refused, and the skip is kept
  /// like a pass.
  Future<void> _checkPairing(
    LlmTarget destination,
    DecisionHeads heads,
    _CallFacts facts,
  ) async {
    final key = _keyOf(destination);
    if (_paired[key] == heads.model) return;
    String? file = _servedFile?.call(destination);
    if (file == null) {
      if (facts.yourServer) {
        file = _kinds[key]?.listedFile;
      } else {
        try {
          final listing = await _requestJson(
            systemOneUrlFor(destination.baseUrl, 'models'),
            destination,
            null,
            facts,
            listingRequest: true,
          );
          file = _listedGguf(listing, destination);
        } on _NoListing {
          file = null;
        }
      }
    }
    if (file != null &&
        heads.model.isNotEmpty &&
        !servesHeadsModel(file, heads.model)) {
      throw DecisionModelMismatchException(
          modelMismatchText(file, heads.model));
    }
    _paired[key] = heads.model;
  }

  /// Whether [file], a served GGUF's last path segment or a `bond-decide-…`
  /// served name, is [model]'s: [model] itself, then at most one quant
  /// segment (`-f16`, `-bf16`, `-f32`, `-q8_0`, …) and `.gguf`. A plain
  /// substring or prefix match would let a sibling run such as
  /// `<model>-cont2-f16.gguf` pass heads it was not trained with.
  static bool servesHeadsModel(String file, String model) {
    if (!file.startsWith(model)) return false;
    return RegExp(r'^(-(f16|bf16|f32|q\d[a-z0-9_]*))?(\.gguf)?$',
            caseSensitive: false)
        .hasMatch(file.substring(model.length));
  }

  /// The GGUF file name [listing] names for [destination], or null. The entry
  /// named [destination]'s model is read first, else a list's lone entry; its
  /// `model`, `id` and `name` are llama-server's (the path it was started
  /// with, unless an alias replaced it), and only one ending `.gguf` or a
  /// served name starting `bond-decide-` counts, reduced to its last path
  /// segment so no folder reaches a sentence.
  static String? _listedGguf(
    Map<String, Object?> listing,
    LlmTarget destination,
  ) {
    final entries = [
      for (final list in [listing['data'], listing['models']])
        if (list is List)
          for (final entry in list)
            if (entry is Map) entry,
    ];
    final named = [
      for (final entry in entries)
        if (entry['id'] == destination.model ||
            entry['name'] == destination.model)
          entry,
    ];
    // llama-server lists its one model twice, once in each list, so a lone
    // entry is judged per list.
    final candidates = named.isNotEmpty
        ? named
        : [
            for (final list in [listing['data'], listing['models']])
              if (list is List && list.length == 1 && list.single is Map)
                list.single as Map<Object?, Object?>,
          ];
    for (final entry in candidates) {
      for (final field in ['model', 'id', 'name']) {
        final value = entry[field];
        if (value is! String) continue;
        final base = value.split(RegExp(r'[/\\]')).last;
        if (base.toLowerCase().endsWith('.gguf')) return base;
        // A served name the box gives the model (`bond-decide-mbl-v3`),
        // which names it as well as a file would. A bare `bond-decide`
        // names no model and is skipped.
        if (base.startsWith('bond-decide-')) return base;
      }
    }
    return null;
  }

  /// [state]'s vector, and whether ids had to be cut to get one.
  Future<(List<double>, bool)> _vectorFor(
    String state,
    LlmTarget destination,
    DecisionHeads heads,
    _CallFacts facts,
  ) async {
    if (state.length <= longStateChars) {
      final answered =
          await _embed(destination, [state], heads, facts, textRequest: true);
      // Null is the server's too-large refusal: not a failure, a signal to
      // take the token path. The text is never retried as text.
      if (answered != null) return (answered.single, false);
    }
    return _truncatedVector(state, destination, heads, facts);
  }

  /// The token path: tokenize without specials, keep the first
  /// `maxTokens - 2` ids, wrap them in `[CLS]`/`[SEP]`, embed the ids. The
  /// flag says whether any id was actually cut: a state long by characters
  /// can still fit, and then it read exactly what the text path would have.
  Future<(List<double>, bool)> _truncatedVector(
    String state,
    LlmTarget destination,
    DecisionHeads heads,
    _CallFacts facts,
  ) async {
    final url = tokenizeUrlFor(destination.baseUrl);
    final decoded = await _postJson(
      url,
      destination,
      {'content': state, 'add_special': false, 'model': destination.model},
      facts,
      tokenizeRequest: true,
    );
    final tokens = decoded['tokens'];
    if (tokens is! List || tokens.any((t) => t is! int)) {
      throw const DecisionMisconfiguredException(
        'The decision server did not answer /tokenize with a token list. '
        'Check that its address serves the decision model.',
      );
    }
    final room = heads.maxTokens - 2;
    final ids = [clsId, ...tokens.cast<int>().take(room), sepId];
    final answered =
        await _embed(destination, [ids], heads, facts, textRequest: false);
    // Only a text request answers null; kept as a guard for the type.
    return (answered!.single, tokens.length > room);
  }

  /// One `/v1/embeddings` request for [inputs] — texts, or one id list — and
  /// its vectors in input order.
  ///
  /// Null when [textRequest] and the server refused the input as longer than
  /// its context. The same refusal of an ID request is a format error: the
  /// ids were already cut to fit, so the server's context is not the model's.
  Future<List<List<double>>?> _embed(
    LlmTarget destination,
    List<Object> inputs,
    DecisionHeads heads,
    _CallFacts facts, {
    required bool textRequest,
  }) async {
    final url = _parse(destination.baseUrl);
    final Map<String, Object?> decoded;
    try {
      decoded = await _postJson(
        url,
        destination,
        {
          'model': destination.model,
          // A lone text goes as a string, the shape the parity spike measured;
          // an id list goes as a flat int array, which is one input, not many.
          'input': inputs.length == 1 ? inputs.single : inputs,
          'embd_normalize': -1,
        },
        facts,
        tooLargeIsSignal: true,
        embeddingsRequest: true,
      );
    } on _TooLarge {
      if (textRequest) return null;
      throw DecisionMisconfiguredException(
        'The decision server refused even a truncated message as too long. '
        'It must run with a context of ${heads.maxTokens} tokens.',
      );
    }

    final data = decoded['data'];
    if (data is! List || data.length != inputs.length) {
      throw DecisionMisconfiguredException(
        '$rawEmbeddingsText It answered with '
        '${data is List ? data.length : 'no'} vectors for ${inputs.length} '
        'inputs.',
      );
    }
    final vectors = List<List<double>?>.filled(inputs.length, null);
    for (var position = 0; position < data.length; position++) {
      final item = data[position];
      if (item is! Map) {
        throw const DecisionMisconfiguredException(rawEmbeddingsText);
      }
      // Ordered by `index` where the server says one — the OpenAI shape does
      // not promise array order — and by position where it does not.
      final index = item['index'];
      final slot = index is int ? index : position;
      if (slot < 0 || slot >= inputs.length || vectors[slot] != null) {
        throw const DecisionMisconfiguredException(
          '$rawEmbeddingsText It answered with a bad vector index.',
        );
      }
      vectors[slot] = _checkedVector(item['embedding'], heads, url);
    }
    return [for (final v in vectors) v!];
  }

  /// [raw] as a vector the heads can read, or a misconfiguration saying why
  /// not. Every one of these is the SERVER, not the message: a server that
  /// answers one message this way answers them all this way, so they park.
  List<double> _checkedVector(Object? raw, DecisionHeads heads, Uri url) {
    if (raw is! List || raw.any((v) => v is! num)) {
      throw const DecisionMisconfiguredException(
        '$rawEmbeddingsText It answered with no flat vector.',
      );
    }
    if (raw.length != heads.hidden) {
      throw DecisionMisconfiguredException(
        '$rawEmbeddingsText It answered with a vector of ${raw.length} '
        'numbers, not ${heads.hidden}.',
      );
    }
    final vector = [for (final v in raw) (v as num).toDouble()];
    var sumSquares = 0.0;
    for (final v in vector) {
      sumSquares += v * v;
    }
    if ((math.sqrt(sumSquares) - 1.0).abs() <= 1e-3) {
      throw const DecisionMisconfiguredException(
        '$rawEmbeddingsText It normalised them, and the heads read only raw '
        'vectors.',
      );
    }
    return vector;
  }

  /// POSTs [body] and returns the decoded JSON object, mapping every failure
  /// to the exception the callers above promise.
  Future<Map<String, Object?>> _postJson(
    Uri url,
    LlmTarget destination,
    Map<String, Object?> body,
    _CallFacts facts, {
    bool tooLargeIsSignal = false,
    bool tokenizeRequest = false,
    bool embeddingsRequest = false,
  }) =>
      _requestJson(
        url,
        destination,
        body,
        facts,
        tooLargeIsSignal: tooLargeIsSignal,
        tokenizeRequest: tokenizeRequest,
        embeddingsRequest: embeddingsRequest,
      );

  /// [_postJson], or a GET when [body] is null. A [listingRequest] (the
  /// kind's `/v1/models`) that is answered with anything but a JSON object —
  /// a 4xx other than 401/403 and 429, or a 200 that does not parse —
  /// throws [_NoListing]: a server with no listing is not a systemone server,
  /// and the encoder-heads identity probe decides what it is. A
  /// [systemOneRequest] answered 404 or 405 is a server with no systemone
  /// endpoint, and an [embeddingsRequest] (the encoder's `/v1/embeddings`)
  /// one with no embeddings endpoint: both park as misconfigured.
  Future<Map<String, Object?>> _requestJson(
    Uri url,
    LlmTarget destination,
    Map<String, Object?>? body,
    _CallFacts facts, {
    bool tooLargeIsSignal = false,
    bool tokenizeRequest = false,
    bool listingRequest = false,
    bool systemOneRequest = false,
    bool embeddingsRequest = false,
  }) async {
    // A managed decision model the router is not serving (not installed):
    // refused before any request, so the pass parks on its own reason.
    if (destination.unavailable case final why?) {
      throw DecisionNotInstalledException(why);
    }
    final bearer = destination.bearer;
    // Refused before anything is sent, on `LlmClient`'s rule.
    if (bearer != null && bearer.isNotEmpty && !isUsableAccessKey(bearer)) {
      throw const DecisionUnauthorizedException(accessKeyCharsText);
    }
    final http.Response response;
    try {
      final auth = {
        if (bearer != null && bearer.isNotEmpty)
          'Authorization': 'Bearer $bearer',
      };
      response = await (body == null
              ? _http.get(url, headers: {'Accept': 'application/json', ...auth})
              : _http.post(
                  url,
                  headers: {'Content-Type': 'application/json', ...auth},
                  body: jsonEncode(body),
                ))
          .timeout(timeout);
    } on SocketException {
      throw DecisionUnavailableException(_unreachable(url, facts));
    } on http.ClientException {
      throw DecisionUnavailableException(_unreachable(url, facts));
    } on TlsException {
      // A handshake that failed (HandshakeException is a subclass) is a
      // server that cannot be reached safely, not a bad request: it parks.
      throw DecisionUnavailableException(_unreachable(url, facts));
    } on TimeoutException {
      throw DecisionUnavailableException(
        'The decision model at $url did not answer within '
        '${timeout.inSeconds} seconds.${_advice(facts)}',
      );
    } on FormatException {
      // Raised while the request is built: a header dart:io refuses, which
      // here can only be the key. The sentence never includes it.
      throw const DecisionUnauthorizedException(accessKeyCharsText);
    } on ArgumentError {
      throw const DecisionUnauthorizedException(accessKeyCharsText);
    }
    facts.statusCode = response.statusCode;
    // utf8 explicitly: llama-server sends application/json with no charset,
    // and http's `body` getter falls back to latin-1.
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);

    if (response.statusCode != 200) {
      if (tooLargeIsSignal &&
          response.statusCode == 500 &&
          text.contains(_tooLargePhrase)) {
        throw const _TooLarge();
      }
      // A server, or a proxy in front of one, with no `/tokenize` at all:
      // every message would need it for the probe, so it is the server's
      // fault and parks, rather than a 4xx charged to one message.
      if (tokenizeRequest &&
          (response.statusCode == 404 || response.statusCode == 405)) {
        throw DecisionMisconfiguredException(noTokenizeText(_origin(url)));
      }
      // The same for the embeddings route: an address re-pointed at a
      // server with no `/v1/embeddings` fails every message alike.
      if (embeddingsRequest &&
          (response.statusCode == 404 || response.statusCode == 405)) {
        throw DecisionMisconfiguredException(noEmbeddingsText(_origin(url)));
      }
      final status = response.statusCode;
      if (listingRequest &&
          status >= 400 &&
          status < 500 &&
          status != 401 &&
          status != 403 &&
          status != 429) {
        throw const _NoListing();
      }
      // The wrapper's route is gone, or the address was re-pointed at
      // something that has none: the server, not this message, so it parks.
      if (systemOneRequest && (status == 404 || status == 405)) {
        throw DecisionMisconfiguredException(
          'The decision server at ${_origin(url)} does not offer '
          '/v1/systemone. Check its address in Settings, Models.',
        );
      }
      _throwForStatus(url, status, text, bearer, facts);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      if (listingRequest) throw const _NoListing();
      throw const DecisionMisconfiguredException(
        'The decision server answered with something that is not JSON. Check '
        'its address in Settings, Models.',
      );
    }
    if (decoded is! Map) {
      if (listingRequest) throw const _NoListing();
      throw const DecisionMisconfiguredException(
        'The decision server answered with something that is not a JSON '
        'object. Check its address in Settings, Models.',
      );
    }
    return decoded.cast<String, Object?>();
  }

  /// The one status mapping. A 5xx and a 429 are the SERVER's condition — it
  /// is loading, or busy — so they park; a 401/403 is the key, which parks
  /// under its own reason; any other 4xx is this request (the one decision
  /// fault that stays a per-message [LlmFormatException]).
  Never _throwForStatus(
    Uri url,
    int status,
    String body,
    String? bearer,
    _CallFacts facts,
  ) {
    final snippet = _snippet(body, bearer);
    if (status == 401 || status == 403) {
      throw DecisionUnauthorizedException(
        'The decision model at $url refused the access key (HTTP $status). '
        'Check it in Settings, Models.',
      );
    }
    if (status == 429 || status >= 500) {
      throw DecisionUnavailableException(
        'The decision model at $url is not ready (HTTP '
        '$status).${_advice(facts)} $snippet',
      );
    }
    throw LlmFormatException(
      'The decision model at $url rejected the request (HTTP $status). '
      '$snippet',
    );
  }

  /// Scheme, host and any port [url] spells: where a sentence says the
  /// server is, without the path. Built by hand because `Uri.origin` throws
  /// on a scheme other than http or https.
  static String _origin(Uri url) =>
      '${url.scheme}://${url.host}${url.hasPort ? ':${url.port}' : ''}';

  String _unreachable(Uri url, _CallFacts facts) =>
      'The decision model at $url is not answering.${_advice(facts)}';

  /// What fixes a server on this Mac, as a sentence after a space: Settings
  /// for the app's own router, which nobody starts by hand; `make decide`
  /// for a hand-started server (a `BOND_DEV_HAND_SERVERS` build); nothing
  /// for Your server, which neither starts.
  static String _advice(_CallFacts facts) => facts.yourServer
      ? ''
      : facts.managed
          ? " Bond's model server is starting or stopped. See Settings, Models."
          : ' Run: make decide.';

  /// The start of a server's error body, for the sentence. With the key
  /// blanked out, in case a proxy ever echoes a header back.
  static String _snippet(String body, String? bearer) {
    var text = body.trim();
    if (bearer != null && bearer.isNotEmpty) {
      text = text.replaceAll(bearer, '<key>');
    }
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static Uri _parse(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw const DecisionMisconfiguredException(
        'The decision model address is not a URL. Check it in Settings, '
        'Models.',
      );
    }
    return parsed;
  }

  /// The `/tokenize` endpoint beside [embeddingsUrl]: its trailing
  /// `/v1/embeddings` (or `/embeddings`) replaced, scheme, host and any path
  /// prefix kept — so a box serving under `/decide/` tokenizes there too.
  static Uri tokenizeUrlFor(String embeddingsUrl) {
    final url = _parse(embeddingsUrl);
    final path = url.path;
    final String prefix;
    if (path.endsWith('/v1/embeddings')) {
      prefix = path.substring(0, path.length - '/v1/embeddings'.length);
    } else if (path.endsWith('/embeddings')) {
      prefix = path.substring(0, path.length - '/embeddings'.length);
    } else {
      throw const DecisionMisconfiguredException(
        'The decision model address does not end in /v1/embeddings, so there '
        'is no tokenize endpoint beside it. Check it in Settings, Models.',
      );
    }
    return _beside(url, '$prefix/tokenize');
  }

  /// A systemone server's `[endpoint]` (`models` or `systemone`) beside
  /// [url]: its path up to (not including) the last `/v1/` segment, then
  /// `/v1/<endpoint>` — [tokenizeUrlFor]'s derivation, so a box serving
  /// under `/decide/` is asked there too. A bare `…/embeddings` address
  /// keeps the prefix before it, as [tokenizeUrlFor] does.
  static Uri systemOneUrlFor(String url, String endpoint) {
    final parsed = _parse(url);
    final path = parsed.path;
    final at = path.lastIndexOf('/v1/');
    final String prefix;
    if (at >= 0) {
      prefix = path.substring(0, at);
    } else if (path.endsWith('/embeddings')) {
      prefix = path.substring(0, path.length - '/embeddings'.length);
    } else {
      throw const DecisionMisconfiguredException(
        'The decision model address has no /v1/ in it to find the server '
        'beside. Check it in Settings, Models.',
      );
    }
    return _beside(parsed, '$prefix/v1/$endpoint');
  }

  /// [url]'s scheme, user info, host and port with [path] and nothing else.
  /// Built afresh rather than `replace`d: `replace` keeps a query it is
  /// handed null for, and none of these endpoints takes one.
  static Uri _beside(Uri url, String path) => Uri(
        scheme: url.scheme,
        userInfo: url.userInfo,
        host: url.host,
        port: url.hasPort ? url.port : null,
        path: path,
      );

  /// Runs [body] and tells the observer about it exactly once, however many
  /// requests it made. The outcomes are `LlmClient._post`'s: an unauthorized
  /// key is `unavailable`, because it is a subclass and parks the same way.
  /// [label] names the record (`decision`, or `command_head` for
  /// [embedRaw]); [report] false tells nobody, and changes nothing else.
  Future<T> _instrumented<T>(
    LlmTarget destination,
    Stopwatch sw,
    String label,
    Future<T> Function(_CallFacts facts) body, {
    bool report = true,
  }) async {
    final facts =
        _CallFacts(yourServer: _yours(destination), managed: _managed());
    void tell(String outcome, String? error) {
      if (report) _report(destination, sw, facts, label, outcome, error);
    }

    try {
      final result = await body(facts);
      tell('ok', null);
      return result;
    } on LlmUnavailableException catch (e) {
      // A server that went away, refused the key or answered wrongly may not
      // be the server that passed the probe when it answers again (a restart
      // can put another model behind the same address), so its pass is
      // forgotten and the next call asks /tokenize again.
      // The same holds for its kind: a restart can put Kev where ModernBERT
      // was. [DecisionMisconfiguredException] is a
      // [DecisionUnavailableException], so a server answering as the wrong
      // thing (a re-pointed route, a Kev still warming up behind a proxy) is
      // asked afresh on the next call as well.
      if (e is DecisionUnavailableException ||
          e is DecisionUnauthorizedException) {
        _verified.remove(_keyOf(destination));
        _kinds.remove(_keyOf(destination));
        _paired.remove(_keyOf(destination));
      }
      tell('unavailable', e.message);
      rethrow;
    } on LlmFormatException catch (e) {
      tell('format', e.message);
      rethrow;
    } on LlmException catch (e) {
      tell('error', e.message);
      rethrow;
    } catch (e) {
      tell('error', '$e');
      rethrow;
    }
  }

  void _report(
    LlmTarget destination,
    Stopwatch sw,
    _CallFacts facts,
    String label,
    String outcome,
    String? error,
  ) {
    final observer = _onCall;
    if (observer == null) return;
    // The observer is on the drain's hot path and must not be able to turn a
    // decision into a failure.
    try {
      observer(LlmCallRecord(
        label: label,
        durationMs: sw.elapsedMilliseconds,
        outcome: outcome,
        model: destination.model,
        baseUrl: destination.baseUrl,
        statusCode: facts.statusCode,
        error: error == null ? null : redactEndpoints(error),
      ));
    } catch (_) {}
  }
}

/// The server's refusal of an over-long input, caught where the request was
/// made and never seen outside this file.
class _TooLarge implements Exception {
  const _TooLarge();
}

/// A kind's `/v1/models` answered 404 or 405: the server lists nothing, so it
/// is not a systemone server. Caught in [DecisionClient._resolveKind] and
/// never seen outside this file.
class _NoListing implements Exception {
  const _NoListing();
}

/// A resolved kind, and for a systemone server the model name it listed,
/// which is what its answers record.
class _ServerKind {
  final DecisionServerKind kind;
  final String model;

  /// For an encoder-heads server, the GGUF its listing named, or null when
  /// it named none: what the heads pairing reads without asking again.
  final String? listedFile;

  const _ServerKind(this.kind, this.model, {this.listedFile});
}

/// What answers one call's questions: the message fields over message
/// states, a storyline question's p(yes) over its rendered states. One per
/// call, bound to the call's target and facts.
abstract class _DecisionBackend {
  /// One message state's answers.
  Future<DecisionResult> one(String state, Stopwatch sw);

  /// Many message states' answers, in order.
  Future<List<DecisionResult>> message(List<String> states, Stopwatch sw);

  /// [question]'s calibrated p(yes) for each of [states], in order.
  Future<List<double>> yes(StorylineQuestion question, List<String> states);
}

/// ModernBERT on llama-server: the raw vectors, the identity probe, the
/// too-large truncation and this Mac's heads — the path every call took
/// before there was a second kind, unchanged.
class _EncoderHeadsBackend implements _DecisionBackend {
  final DecisionClient _client;
  final LlmTarget _destination;
  final _CallFacts _facts;

  _EncoderHeadsBackend(this._client, this._destination, this._facts);

  @override
  Future<DecisionResult> one(String state, Stopwatch sw) async {
    final heads = _client._heads();
    await _client._verifyServer(_destination, _facts);
    await _client._checkPairing(_destination, heads, _facts);
    final (vector, truncated) =
        await _client._vectorFor(state, _destination, heads, _facts);
    return DecisionResult(
      answers: heads.apply(vector),
      state: state,
      model: heads.model,
      latencyMs: sw.elapsedMilliseconds,
      truncated: truncated,
      vector: vector,
    );
  }

  @override
  Future<List<DecisionResult>> message(
    List<String> states,
    Stopwatch sw,
  ) async {
    final heads = _client._heads();
    final (vectors, truncated) =
        await _client._vectors(states, _destination, heads, _facts);
    return [
      for (var i = 0; i < states.length; i++)
        DecisionResult(
          answers: heads.apply(vectors[i]),
          state: states[i],
          model: heads.model,
          latencyMs: sw.elapsedMilliseconds,
          truncated: truncated[i],
          vector: vectors[i],
        ),
    ];
  }

  @override
  Future<List<double>> yes(
    StorylineQuestion question,
    List<String> states,
  ) async {
    final heads = _client._heads();
    final (vectors, _) =
        await _client._vectors(states, _destination, heads, _facts);
    return [for (final v in vectors) heads.pYes(question, v)];
  }
}

/// Kev 4B behind the systemone wrapper: one request per state, the nine
/// message questions together or one storyline question alone, answers
/// already calibrated. It never reads the heads, so a Mac with no heads
/// file can use it.
class _SystemOneBackend implements _DecisionBackend {
  final DecisionClient _client;
  final LlmTarget _destination;
  final _CallFacts _facts;

  /// The wrapper's own model name, from its listing.
  final String _model;

  _SystemOneBackend(
    this._client,
    this._destination,
    this._facts,
    this._model,
  );

  Future<DecisionAnswers> _answers(String state) async =>
      DecisionAnswers.fromProbabilities(await _client._systemOne(
        _destination,
        state,
        systemOneMessageQuestions,
        _facts,
      ));

  @override
  Future<DecisionResult> one(String state, Stopwatch sw) async {
    final answers = await _answers(state);
    return DecisionResult(
      answers: answers,
      state: state,
      model: _model,
      latencyMs: sw.elapsedMilliseconds,
    );
  }

  @override
  Future<List<DecisionResult>> message(
    List<String> states,
    Stopwatch sw,
  ) async {
    final answers =
        await DecisionClient._pooled(states.length, (i) => _answers(states[i]));
    return [
      for (var i = 0; i < states.length; i++)
        DecisionResult(
          answers: answers[i],
          state: states[i],
          model: _model,
          latencyMs: sw.elapsedMilliseconds,
        ),
    ];
  }

  @override
  Future<List<double>> yes(
    StorylineQuestion question,
    List<String> states,
  ) {
    final asked = [
      SystemOneQuestion(
        question.id,
        question.instructions,
        StorylineQuestion.options,
      ),
    ];
    return DecisionClient._pooled(states.length, (i) async {
      final answers =
          await _client._systemOne(_destination, states[i], asked, _facts);
      return answers[question.id]!['yes']!;
    });
  }
}
