/// The decision model's client: render a message's state, embed it, apply the
/// heads.
///
/// The server is a stock llama-server serving the fine-tuned encoder as a
/// mean-pooled embedding model (`make decide` on :8083). It answers
/// `/v1/embeddings` with the raw pooled vector, and the nine heads that turn
/// the vector into answers run here (`decision_heads.dart`). Two wire details
/// were measured in the model's parity spike and are load-bearing:
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
    show LlmTarget, decideModelDefault, decideUrlDefault;
import 'decision_heads.dart';
import 'decision_input.dart';
import 'decision_state.dart';

/// One message's decision, and what produced it.
@immutable
class DecisionResult {
  final DecisionAnswers answers;

  /// The exact text the model read — what the Why panel can show.
  final String state;

  /// The heads file's model name.
  final String model;

  /// Wall time of the whole call, rendering included. A result from
  /// [DecisionClient.decideBatch] carries the batch's wall time.
  final int latencyMs;

  /// The state was longer than the model's context and was cut to it.
  final bool truncated;

  const DecisionResult({
    required this.answers,
    required this.state,
    required this.model,
    required this.latencyMs,
    this.truncated = false,
  });
}

/// The per-call facts the one [LlmCallRecord] reports, gathered across the
/// one to three HTTP requests a decision can take.
class _CallFacts {
  int? statusCode;
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

  /// The phrase llama-server's refusal of an over-long input carries.
  static const String _tooLargePhrase = 'too large to process';

  /// The targets whose identity probe PASSED, as `'<baseUrl>|<model>'`. Only
  /// a success is kept: a probe that failed is asked again on the next call,
  /// so a server that was down, or an address that was fixed, recovers
  /// without anybody pressing anything.
  final Set<String> _verified = {};

  final LlmTarget Function() _resolveTarget;
  final DecisionHeads Function() _heads;
  final http.Client _http;
  final void Function(LlmCallRecord record)? _onCall;

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
  /// [LlmFormatException] only when the server rejected this one request.
  Future<DecisionResult> decide(DecisionInput input) async {
    final sw = Stopwatch()..start();
    final destination = target;
    return _instrumented(destination, sw, (facts) async {
      final heads = _heads();
      await _verifyServer(destination, facts);
      final state = renderDecisionState(input, toLocal: _toLocal);
      final (vector, truncated) =
          await _vectorFor(state, destination, heads, facts);
      return DecisionResult(
        answers: heads.apply(vector),
        state: state,
        model: heads.model,
        latencyMs: sw.elapsedMilliseconds,
        truncated: truncated,
      );
    });
  }

  /// Many messages' answers, in [inputs] order, in as few requests as the
  /// states allow: the short states in array requests of up to [batchChunk],
  /// and each long one on its own token path. One [LlmCallRecord] for the
  /// whole batch.
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
    return _instrumented(destination, sw, (facts) async {
      final heads = _heads();
      // Once per batch, before the first array goes.
      await _verifyServer(destination, facts);
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

      return [
        for (var i = 0; i < states.length; i++)
          DecisionResult(
            answers: heads.apply(vectors[i]!),
            state: states[i],
            model: heads.model,
            latencyMs: sw.elapsedMilliseconds,
            truncated: truncated[i],
          ),
      ];
    });
  }

  /// The encoder's raw pooled vector for each of [texts], in order, with no
  /// heads applied — the calendar command head's input
  /// (`services/calendar/command/command_heads.dart`), which is a second
  /// head fitted on the same encoder and so must read exactly what the nine
  /// read: the same identity probe, `embd_normalize: -1`, the same width and
  /// norm refusals, and a long text on the token path.
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
    return _instrumented(destination, sw, label: 'command_head', report: report,
        (facts) async {
      final heads = _heads();
      await _verifyServer(destination, facts);
      return [
        for (final text in texts)
          (await _vectorFor(text, destination, heads, facts)).$1,
      ];
    });
  }

  /// For a Connect that must not write a server of the wrong kind: whether
  /// the server at [url], asked for [model], is the decision model. The same
  /// identity probe [decide] makes before its first request, and a pass here
  /// spares that first request the probe. Null when it is; otherwise the
  /// sentence to show under the form, which carries no key.
  Future<String?> checkServer({
    required String url,
    required String model,
    String? bearer,
  }) async {
    try {
      await _verifyServer(
        LlmTarget(baseUrl: url, model: model, bearer: bearer),
        _CallFacts(),
      );
      return null;
    } on LlmException catch (e) {
      return e.message;
    }
  }

  /// The identity probe, once per target: `/tokenize` with the specials
  /// added must answer ModernBERT's `[CLS] … [SEP]`. The vector checks below
  /// cannot tell the decision model from the embedding model — both answer
  /// 1024 raw numbers, and llama-server echoes the request's `model` back —
  /// but the tokenizers differ, and a message decided on the wrong model's
  /// vectors can be learned-gated into Dropped with no error anywhere.
  Future<void> _verifyServer(LlmTarget destination, _CallFacts facts) async {
    final key = '${destination.baseUrl}|${destination.model}';
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
      response = await _http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              if (bearer != null && bearer.isNotEmpty)
                'Authorization': 'Bearer $bearer',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException {
      throw DecisionUnavailableException(_unreachable(url));
    } on http.ClientException {
      throw DecisionUnavailableException(_unreachable(url));
    } on TlsException {
      // A handshake that failed (HandshakeException is a subclass) is a
      // server that cannot be reached safely, not a bad request: it parks.
      throw DecisionUnavailableException(_unreachable(url));
    } on TimeoutException {
      throw DecisionUnavailableException(
        'The decision model at $url did not answer within '
        '${timeout.inSeconds} seconds — run: make decide',
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
      _throwForStatus(url, response.statusCode, text, bearer);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const DecisionMisconfiguredException(
        'The decision server answered with something that is not JSON. Check '
        'its address in Settings, Models.',
      );
    }
    if (decoded is! Map) {
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
  Never _throwForStatus(Uri url, int status, String body, String? bearer) {
    final snippet = _snippet(body, bearer);
    if (status == 401 || status == 403) {
      throw DecisionUnauthorizedException(
        'The decision model at $url refused the access key (HTTP $status). '
        'Check it in Settings, Models.',
      );
    }
    if (status == 429 || status >= 500) {
      throw DecisionUnavailableException(
        'The decision model at $url is not ready (HTTP $status) — run: make '
        'decide. $snippet',
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

  String _unreachable(Uri url) =>
      'The decision model at $url is not answering — run: make decide';

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
    // Built afresh rather than `replace`d: `replace` keeps a query it is
    // handed null for, and the tokenize endpoint takes none.
    return Uri(
      scheme: url.scheme,
      userInfo: url.userInfo,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: '$prefix/tokenize',
    );
  }

  /// Runs [body] and tells the observer about it exactly once, however many
  /// requests it made. The outcomes are `LlmClient._post`'s: an unauthorized
  /// key is `unavailable`, because it is a subclass and parks the same way.
  /// [label] names the record (`decision`, or `command_head` for
  /// [embedRaw]); [report] false tells nobody, and changes nothing else.
  Future<T> _instrumented<T>(
    LlmTarget destination,
    Stopwatch sw,
    Future<T> Function(_CallFacts facts) body, {
    String label = 'decision',
    bool report = true,
  }) async {
    final facts = _CallFacts();
    void tell(String outcome, String? error) {
      if (report) _report(destination, sw, facts, outcome, error, label);
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
      if (e is DecisionUnavailableException ||
          e is DecisionUnauthorizedException) {
        _verified.remove('${destination.baseUrl}|${destination.model}');
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
    String outcome,
    String? error,
    String label,
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
