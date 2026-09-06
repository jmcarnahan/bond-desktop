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
  /// server does not.
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

  /// Names the server that did not answer. The old constant said
  /// "run: make model" for BOTH clients, which was wrong for the fast slot
  /// and wronger now that either can point anywhere.
  static String _unreachable(String url) =>
      'The local model server at $url is not reachable — start it, or change '
      'it in Settings → Models';

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

  /// Fires with the tripwire below, so a test can catch a thinking regression.
  void Function()? onReasoningLeak;

  LlmClient({
    String? baseUrl,
    String? model,
    Duration? timeout,
    http.Client? httpClient,
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

  /// Free-text completion. Nothing in this app uses it yet; it is the seam a
  /// draft-reply task lands on.
  Future<String> complete({
    required String system,
    required String user,
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    final message = await _post(
      _body(
        system: system,
        user: user,
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
      ),
      think: think,
      label: 'complete',
    );
    return _content(message);
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
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    final body = _body(
      system: system,
      user: user,
      maxTokens: maxTokens,
      temperature: temperature,
      think: think,
    );
    body['response_format'] = {
      'type': 'json_schema',
      'json_schema': {
        'name': schemaName,
        'strict': true,
        'schema': schema,
      },
    };

    final content = _content(await _post(body, think: think, label: schemaName));
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw LlmFormatException(
        'The local model did not answer with JSON: ${_snippet(content)}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw LlmFormatException(
        'The local model answered with ${decoded.runtimeType}, not a JSON '
        'object: ${_snippet(content)}',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _body({
    required String system,
    required String user,
    required int maxTokens,
    required double temperature,
    required bool think,
  }) =>
      {
        // 'model' is NOT set here — see [_post], which resolves the target
        // once and stamps both the name and the URL from that one answer.
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'max_tokens': maxTokens,
        'temperature': temperature,
        if (!think) 'chat_template_kwargs': {'enable_thinking': false},
      };

  /// POSTs and returns the assistant message object, telling the observer —
  /// when there is one — what every round trip cost and how it ended.
  ///
  /// A thin wrapper on purpose: the single try below is what instruments all
  /// of [_postInner]'s failure paths without touching any of them.
  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body, {
    required bool think,
    required String label,
  }) async {
    // ONE resolution per request. Reading `baseUrl` and `model` separately
    // would let a save between the two stamp a name from the new target onto
    // the old target's URL.
    final target = this.target;
    body['model'] = target.model;

    final observer = _onCall;
    if (observer == null) {
      return (await _postInner(body, think: think, target: target)).message;
    }

    final sw = Stopwatch()..start();
    try {
      final result = await _postInner(body, think: think, target: target);
      observer(LlmCallRecord(
        label: label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'ok',
        model: target.model,
        baseUrl: target.baseUrl,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        serverPromptMs: result.serverPromptMs,
        serverPredictedMs: result.serverPredictedMs,
      ));
      return result.message;
    } on LlmUnavailableException catch (e) {
      observer(LlmCallRecord(
        label: label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'unavailable',
        model: target.model,
        baseUrl: target.baseUrl,
        error: e.message,
      ));
      rethrow;
    } on LlmFormatException catch (e) {
      observer(LlmCallRecord(
        label: label,
        durationMs: sw.elapsedMilliseconds,
        outcome: 'format',
        model: target.model,
        baseUrl: target.baseUrl,
        error: e.message,
      ));
      rethrow;
    } on LlmException catch (e) {
      observer(LlmCallRecord(
        label: label,
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

  Future<
      ({
        Map<String, dynamic> message,
        int? promptTokens,
        int? completionTokens,
        int? serverPromptMs,
        int? serverPredictedMs,
      })> _postInner(
    Map<String, dynamic> body, {
    required bool think,
    required LlmTarget target,
  }) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(target.baseUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException {
      throw LlmUnavailableException(_unreachable(target.baseUrl));
    } on http.ClientException {
      throw LlmUnavailableException(_unreachable(target.baseUrl));
    } on TimeoutException {
      // NOT [LlmUnavailableException]: the server accepted the connection, so
      // this is one request going wrong rather than a server that is down.
      // Counting it against the message is what stops a single pathological
      // email from blocking the queue behind it forever.
      throw LlmException(
        'The local model did not answer within ${timeout.inSeconds} seconds.',
      );
    }

    // A 5xx is the SERVER's condition, not this request's: llama-server
    // answers 503 for every request while its weights load. Counting that
    // against the item would burn the whole backlog's attempts against a
    // server that was seconds from healthy — the drain must park instead,
    // exactly as it does for a refused connection.
    if (response.statusCode >= 500) {
      throw LlmUnavailableException(
        'The local model server is not ready '
        '(HTTP ${response.statusCode}). ${_snippet(_text(response))}',
      );
    }

    if (response.statusCode != 200) {
      throw LlmException(
        'The local model rejected the request (HTTP ${response.statusCode}). '
        '${_snippet(_text(response))}',
        response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(_text(response));
    } on FormatException {
      throw const LlmFormatException(
        'The local model answered with something that is not JSON.',
      );
    }
    if (decoded is! Map) {
      throw const LlmFormatException(
        'The local model answered with an unexpected payload shape.',
      );
    }

    final choices = decoded['choices'];
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    if (message is! Map) {
      throw const LlmFormatException(
        'The local model answered with no message content.',
      );
    }

    // A tripwire, not a failure: the app still works, it just runs at half
    // speed. It fires when a model swap ignores enable_thinking, which is the
    // kind of regression that otherwise shows up only as "triage got slow".
    if (!think) {
      final reasoning = message['reasoning_content'];
      if (reasoning is String && reasoning.trim().isNotEmpty) {
        debugPrint(
          'LlmClient: enable_thinking was ignored — triage will be ~2x slower',
        );
        onReasoningLeak?.call();
      }
    }

    final usage = decoded['usage'];
    // `timings` is llama-server's, not OpenAI's, and its milliseconds arrive
    // as doubles — hence `as num?` before `.toInt()`, the same defensiveness
    // the token counts get. A runtime that sends no such block reads as null
    // rather than zero, because "did not say" and "took no time" have to stay
    // distinguishable to anything averaging these.
    final timings = decoded['timings'];
    return (
      message: Map<String, dynamic>.from(message),
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

  static String _content(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is! String) {
      throw const LlmFormatException(
        'The local model answered with no message content.',
      );
    }
    return content;
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
