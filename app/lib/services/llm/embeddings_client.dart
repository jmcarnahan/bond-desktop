import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// The second local server: a small embedding model behind llama-server's
/// `/v1/embeddings`, started by `make embed`.
///
/// Separate from `LlmClient` in every way that matters. It talks to a
/// different port and a different model, and — the part that shapes this whole
/// class — it NEVER throws. An embedding is an optimisation: a conversation
/// with no vector still renders, still triages, still shows its CTA. So every
/// failure path here returns null and lets the caller carry on, where the same
/// failure in the chat client is a queue-parking event.
class EmbeddingsClient {
  /// Overridable at build time (`--dart-define=EMBED_URL=…`).
  static const String defaultBaseUrl = String.fromEnvironment(
    'EMBED_URL',
    defaultValue: 'http://localhost:8081/v1/embeddings',
  );

  /// EmbeddingGemma is prompt-conditioned: the same text embedded under
  /// different task prefixes lands in different places. Everything this app
  /// embeds is being embedded to be CLUSTERED against other conversations, so
  /// the prefix is fixed here rather than passed in — a mixed corpus, half
  /// written under one prefix and half under another, is a corpus whose
  /// distances mean nothing.
  static const String clusteringPrefix = 'task: clustering | query: ';

  /// Stored beside every vector. Two vectors are only comparable when this
  /// matches, so a model swap is detectable rather than silently poisonous.
  static const String modelTag = 'embeddinggemma-300M/clustering';

  /// A 300M model on Metal answers in well under a second. This ceiling is for
  /// a wedged server, not a slow one.
  static const Duration _timeout = Duration(seconds: 30);

  final String baseUrl;
  final http.Client _http;

  /// Failures already reported. Without it, a server that is simply not
  /// running would print one line per message for the length of a backlog.
  final Set<String> _reported = {};

  /// Told about each DISTINCT failure once, alongside the debugPrint — in the
  /// app, the activity log. It rides the same dedupe on purpose: this client's
  /// whole contract is that a missing embedding server costs nothing, and a
  /// row per message would make the panel read as though the app were broken.
  final void Function(String reason)? onFail;

  EmbeddingsClient({
    String? baseUrl,
    http.Client? httpClient,
    this.onFail,
  })  : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = httpClient ?? http.Client();

  /// One vector for [text], or null if anything at all went wrong.
  Future<List<double>?> embed(String text) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(baseUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'input': '$clusteringPrefix$text',
              // llama-server ignores the name — it serves what was loaded —
              // but the OpenAI request schema requires the field.
              'model': 'embed',
            }),
          )
          .timeout(_timeout);
    } on SocketException {
      return _fail('is not reachable — run: make embed');
    } on http.ClientException {
      return _fail('is not reachable — run: make embed');
    } on TimeoutException {
      return _fail('did not answer within ${_timeout.inSeconds} seconds');
    }

    if (response.statusCode != 200) {
      return _fail('rejected the request (HTTP ${response.statusCode})');
    }

    final Object? decoded;
    try {
      // utf8 explicitly: llama-server sends application/json with no charset,
      // and http's `body` getter falls back to latin-1.
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      return _fail('answered with something that is not JSON');
    }

    if (decoded is! Map) return _fail('answered with an unexpected payload');
    final data = decoded['data'];
    final first = data is List && data.isNotEmpty ? data.first : null;
    final embedding = first is Map ? first['embedding'] : null;
    if (embedding is! List || embedding.isEmpty) {
      return _fail('answered with no embedding');
    }

    final vector = <double>[];
    for (final value in embedding) {
      if (value is! num) return _fail('answered with a non-numeric embedding');
      vector.add(value.toDouble());
    }
    return vector;
  }

  /// Reports [reason] once, then returns null forever after. Always null: the
  /// return type is what makes `return _fail(...)` read at every call site.
  Null _fail(String reason) {
    if (_reported.add(reason)) {
      debugPrint('EmbeddingsClient: the embedding server $reason');
      onFail?.call(reason);
    }
    return null;
  }
}

/// [v] as float32 little-endian bytes, the form a BLOB column holds.
///
/// float32 rather than float64 halves the database for a precision loss far
/// below anything a cosine comparison can see — the model's own weights are
/// quantised well past this.
Uint8List encodeEmbedding(List<double> v) {
  final bytes = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    bytes.setFloat32(i * 4, v[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// The inverse of [encodeEmbedding]. A trailing partial float — a truncated
/// blob — is dropped rather than throwing.
List<double> decodeEmbedding(Uint8List b) {
  final view = ByteData.sublistView(b);
  final count = b.lengthInBytes ~/ 4;
  return [
    for (var i = 0; i < count; i++) view.getFloat32(i * 4, Endian.little),
  ];
}

/// Cosine similarity, in full rather than as a bare dot product.
///
/// This server returns L2-normalised vectors, which makes the dot product
/// alone correct — today. Dividing by the norms costs one pass and means a
/// vector that arrives un-normalised (a different model, a different server
/// build) reads as a wrong-but-bounded similarity instead of an unbounded
/// number that silently outranks everything.
///
/// Mismatched lengths and zero vectors both give 0: no similarity, rather than
/// a NaN that poisons every sort it touches.
double cosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}
