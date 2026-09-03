import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:http/http.dart' as http;

/// Why a call to the embedding server produced no vector — the one thing
/// `null` could never say.
///
/// The distinction is not diagnostic, it is a routing decision. A caller that
/// cannot tell "the server is not running" from "the server answered nonsense"
/// has to treat both as permanent, and permanent is wrong for the first one:
/// the thread's clustering is simply not ready yet, and it must be tried
/// again once `make embed` is running.
enum EmbedOutcome {
  /// A vector came back.
  ok,

  /// Nothing answered — refused connection, dropped socket, timeout, or one
  /// of the gateway statuses a proxy in front of the server sends while it is
  /// still coming up. Try again later; nothing is wrong with the text.
  unavailable,

  /// Something answered, and what it said was not a vector — a wrong status,
  /// a body that is not JSON, a payload of the wrong shape. Retrying reproduces
  /// it, so the caller may as well move on.
  rejected,
}

/// One embedding attempt's outcome, for the callers that have to act on the
/// difference. [EmbeddingsClient.embed] is the same thing with the outcome
/// thrown away.
@immutable
class EmbedResult {
  /// The vector, non-null exactly when [outcome] is [EmbedOutcome.ok].
  final List<double>? vector;

  final EmbedOutcome outcome;

  /// The sentence the failure was reported with, or null on success. The same
  /// string the `onFail` callback carries — see [EmbeddingsClient.onFail].
  final String? reason;

  const EmbedResult(this.outcome, {this.vector, this.reason});
}

/// The second local server: a small embedding model behind llama-server's
/// `/v1/embeddings`, started by `make embed`.
///
/// Separate from `LlmClient` in every way that matters. It talks to a
/// different port and a different model, and — the part that shapes this whole
/// class — it NEVER throws. An embedding is an optimisation: a conversation
/// with no vector still renders, still triages, still shows its CTA. So every
/// failure path here returns null and lets the caller carry on, where the same
/// failure in the chat client is a queue-parking event.
///
/// It never throws, but it does now say WHY it failed: [embedResult] carries
/// an [EmbedOutcome], because "the server is not running" and "the server
/// answered nonsense" are the same null and opposite decisions — one is worth
/// queueing a retry for and the other is not.
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
  ///
  /// The shape every caller had before outcomes existed, and still the right
  /// one for a caller that would do the same thing either way.
  Future<List<double>?> embed(String text) async =>
      (await embedResult(text)).vector;

  /// One vector for [text], with why there isn't one when there isn't.
  Future<EmbedResult> embedResult(String text) async {
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
      return _fail('is not reachable — run: make embed', EmbedOutcome.unavailable);
    } on http.ClientException {
      return _fail('is not reachable — run: make embed', EmbedOutcome.unavailable);
    } on TimeoutException {
      return _fail(
        'did not answer within ${_timeout.inSeconds} seconds',
        EmbedOutcome.unavailable,
      );
    }

    if (response.statusCode != 200) {
      return _fail(
        'rejected the request (HTTP ${response.statusCode})',
        // The three gateway statuses are a server that is not there yet, not a
        // server that read the request and said no: llama-server behind a
        // proxy answers 502/503 for the whole of its model load. Everything
        // else — a 400, a 404, a 500 — is about this request and will be the
        // same on the next pass.
        const {502, 503, 504}.contains(response.statusCode)
            ? EmbedOutcome.unavailable
            : EmbedOutcome.rejected,
      );
    }

    final Object? decoded;
    try {
      // utf8 explicitly: llama-server sends application/json with no charset,
      // and http's `body` getter falls back to latin-1.
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      return _fail(
        'answered with something that is not JSON',
        EmbedOutcome.rejected,
      );
    }

    if (decoded is! Map) {
      return _fail('answered with an unexpected payload', EmbedOutcome.rejected);
    }
    final data = decoded['data'];
    final first = data is List && data.isNotEmpty ? data.first : null;
    final embedding = first is Map ? first['embedding'] : null;
    if (embedding is! List || embedding.isEmpty) {
      return _fail('answered with no embedding', EmbedOutcome.rejected);
    }

    final vector = <double>[];
    for (final value in embedding) {
      if (value is! num) {
        return _fail(
          'answered with a non-numeric embedding',
          EmbedOutcome.rejected,
        );
      }
      vector.add(value.toDouble());
    }
    return EmbedResult(EmbedOutcome.ok, vector: vector);
  }

  /// Reports [reason] once, then answers [outcome] forever after. The return
  /// type is what makes `return _fail(...)` read at every call site.
  ///
  /// The dedupe is on the reason alone, and stays that way: one line per
  /// distinct failure however long the backlog is the contract this class was
  /// built around.
  EmbedResult _fail(String reason, EmbedOutcome outcome) {
    if (_reported.add(reason)) {
      debugPrint('EmbeddingsClient: the embedding server $reason');
      onFail?.call(reason);
    }
    return EmbedResult(outcome, reason: reason);
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
