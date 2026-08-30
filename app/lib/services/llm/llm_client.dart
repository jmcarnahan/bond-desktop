import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

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

class LlmClient {
  /// Overridable at build time (`--dart-define=LLAMA_URL=…`) for a model
  /// server on another port or another machine.
  static const String defaultBaseUrl = String.fromEnvironment(
    'LLAMA_URL',
    defaultValue: 'http://localhost:8080/v1/chat/completions',
  );

  /// llama-server ignores the model name — it serves whatever was loaded at
  /// launch — but the OpenAI request schema requires the field.
  static const String _model = 'qwen3.8';

  /// The model generates at roughly 12 tokens a second, so a full 512-token
  /// answer can legitimately take most of a minute. This ceiling is here to
  /// catch a wedged server, not a slow one.
  static const Duration _timeout = Duration(seconds: 120);

  static const String _unreachable =
      'The local model server is not reachable — run: make model';

  final String baseUrl;
  final http.Client _http;

  LlmClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = httpClient ?? http.Client();

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
    );
    return _content(message);
  }

  /// A completion constrained to [schema].
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
    bool think = false,
  }) async {
    final body = _body(
      system: system,
      user: user,
      maxTokens: maxTokens,
      temperature: 0.2,
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

    final content = _content(await _post(body, think: think));
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
        'model': _model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'max_tokens': maxTokens,
        'temperature': temperature,
        if (!think) 'chat_template_kwargs': {'enable_thinking': false},
      };

  /// POSTs and returns the assistant message object.
  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body, {
    required bool think,
  }) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(baseUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on SocketException {
      throw const LlmUnavailableException(_unreachable);
    } on http.ClientException {
      throw const LlmUnavailableException(_unreachable);
    } on TimeoutException {
      // NOT [LlmUnavailableException]: the server accepted the connection, so
      // this is one request going wrong rather than a server that is down.
      // Counting it against the message is what stops a single pathological
      // email from blocking the queue behind it forever.
      throw LlmException(
        'The local model did not answer within ${_timeout.inSeconds} seconds.',
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
      }
    }

    return Map<String, dynamic>.from(message);
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
