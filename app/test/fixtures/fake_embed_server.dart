import 'dart:convert';

import 'package:bond_inbox/data/vec_index.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The width every fixture vector is built at, which is the width the app's
/// indexes are declared at.
///
/// Read off [MessageVectorIndex.dims] rather than written down, because a
/// fixture at the wrong width is not a failing assertion: the vec0 tables skip
/// a row whose stored `dims` is not theirs, so a stale literal here would turn
/// every search test into a test of an empty index that still passed its
/// "nothing matches" branch. It moved 768 → 1024 with the model on 2026-09-19.
const int embedDims = MessageVectorIndex.dims;

/// A full-width vector with a few named axes set — everything else zero.
///
/// Distinct axes make the geometry arithmetic-free: two vectors' cosine
/// distance is whatever the shared components say and nothing else, so a
/// failing assertion is a failure of the search, never of the fixture's maths.
List<double> axes(Map<int, double> components) {
  final v = List.filled(embedDims, 0.0);
  components.forEach((axis, value) => v[axis] = value);
  return v;
}

/// An embedding server that counts what it was asked and answers
/// deterministically.
///
/// A shared fixture rather than a fourth copy: the attachment handlers and the
/// search both need one, and they need it to agree with itself — a document
/// embedded here has to be findable by a query embedded here, or a test proves
/// nothing about either.
///
/// [vectorFor] is how a test states "these two texts are about the same
/// thing": key both on a word and they get the same vector. The default is a
/// constant vector, which is all a test about COUNTS needs.
class FakeEmbedServer {
  /// Every input, in order. The count is the point of most tests that use one:
  /// "a second pass costs no call" is only observable as a request that was
  /// never sent.
  final List<String> inputs = [];

  /// null → the socket dies (the server is not running).
  /// 500 → the server answers, badly.
  final int? status;

  /// The vector for one input, or null to use the flat default.
  final List<double> Function(String input)? vectorFor;

  FakeEmbedServer({this.status = 200, this.vectorFor});

  int get calls => inputs.length;

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient((request) async {
          final input =
              (jsonDecode(request.body) as Map<String, dynamic>)['input']
                  as String;
          inputs.add(input);
          final code = status;
          if (code == null) {
            // What `http` raises for a connection that went nowhere. The
            // client maps it to `unavailable`, exactly as it does a real
            // SocketException.
            throw http.ClientException('connection refused');
          }
          if (code != 200) return http.Response('nope', code);
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'embedding':
                      vectorFor?.call(input) ?? List.filled(embedDims, 0.1)
                }
              ]
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
}
