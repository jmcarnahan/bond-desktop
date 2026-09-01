import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _url = 'http://localhost:8081/v1/embeddings';

/// A client whose every call answers with [respond], recording what it was
/// asked.
class Stub {
  final List<Map<String, dynamic>> bodies = [];
  final http.Response Function() respond;

  Stub(this.respond);

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return respond();
        }),
      );
}

http.Response jsonOk(Object body) =>
    http.Response(jsonEncode(body), 200, headers: const {
      // No charset, exactly as llama-server sends it.
      'content-type': 'application/json',
    });

Map<String, dynamic> embeddingBody(List<double> values) => {
      'object': 'list',
      'data': [
        {'object': 'embedding', 'index': 0, 'embedding': values}
      ],
      'model': 'embed',
    };

void main() {
  group('embed', () {
    test('prepends the clustering prefix to the input', () async {
      final stub = Stub(() => jsonOk(embeddingBody(const [0.1, 0.2])));

      await stub.client.embed('Rate lock | Sarah Chen');

      expect(
        stub.bodies.single['input'],
        'task: clustering | query: Rate lock | Sarah Chen',
      );
      // Everything this app embeds is embedded to be clustered. A corpus half
      // written under one prefix is a corpus whose distances mean nothing.
      expect(EmbeddingsClient.clusteringPrefix, 'task: clustering | query: ');
      expect(stub.bodies.single['model'], 'embed');
    });

    test('parses the vector out of the OpenAI response shape', () async {
      final stub = Stub(() => jsonOk(embeddingBody(const [0.5, -0.25, 0])));

      expect(await stub.client.embed('anything'), [0.5, -0.25, 0.0]);
    });

    test('an integer element is read as a double', () async {
      final stub = Stub(() => jsonOk({
            'data': [
              {'embedding': [1, 0, 0]}
            ]
          }));

      expect(await stub.client.embed('anything'), [1.0, 0.0, 0.0]);
    });

    test('a non-200 gives null rather than throwing', () async {
      final stub = Stub(() => http.Response('nope', 503));

      expect(await stub.client.embed('anything'), isNull);
    });

    test('a body that is not JSON gives null', () async {
      final stub = Stub(() => http.Response('<html>oops</html>', 200));

      expect(await stub.client.embed('anything'), isNull);
    });

    test('a JSON body of the wrong shape gives null', () async {
      for (final body in <Object>[
        {'data': []},
        {'data': 'nope'},
        const [1, 2, 3],
        {
          'data': [
            {'embedding': 'nope'}
          ]
        },
        {
          'data': [
            {'embedding': ['not', 'numbers']}
          ]
        },
      ]) {
        final stub = Stub(() => jsonOk(body));
        expect(await stub.client.embed('anything'), isNull, reason: '$body');
      }
    });

    test('a timeout gives null', () async {
      final client = EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((_) async => throw TimeoutException('slow')),
      );

      expect(await client.embed('anything'), isNull);
    });

    test('a server that is not running gives null', () async {
      final client = EmbeddingsClient(
        baseUrl: _url,
        httpClient:
            MockClient((_) async => throw const SocketException('refused')),
      );

      // The whole contract: an embedding is an optimisation, so a missing
      // embed server degrades the app rather than failing anything.
      expect(await client.embed('anything'), isNull);
    });

    test('a client exception gives null', () async {
      final client = EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((_) async => throw http.ClientException('reset')),
      );

      expect(await client.embed('anything'), isNull);
    });
  });

  group('onFail', () {
    test('fires once per distinct reason, however long the backlog', () async {
      final reasons = <String>[];
      var status = 503;
      final client = EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((_) async => http.Response('nope', status)),
        onFail: reasons.add,
      );

      for (var i = 0; i < 5; i++) {
        await client.embed('anything');
      }
      // A second, different failure is worth saying once as well.
      status = 500;
      await client.embed('anything');
      await client.embed('anything');

      // It rides the debugPrint's own dedupe on purpose: an embedding server
      // that is simply not running would otherwise write one activity row per
      // message for the length of a backlog, which reads as a broken app.
      expect(reasons, [
        'rejected the request (HTTP 503)',
        'rejected the request (HTTP 500)',
      ]);
    });

    test('a client with no callback still degrades quietly', () async {
      final client = EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((_) async => http.Response('nope', 503)),
      );

      expect(await client.embed('anything'), isNull);
    });
  });

  group('encoding', () {
    test('round-trips to float32 precision', () {
      final original = [0.5, -0.25, 0.0, 1.0, -1.0, 0.125];

      final decoded = decodeEmbedding(encodeEmbedding(original));

      expect(decoded.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i], closeTo(original[i], 1e-6));
      }
    });

    test('a value with no exact float32 form survives within tolerance', () {
      final decoded = decodeEmbedding(encodeEmbedding(const [0.1, 0.2, 0.3]));

      for (final (i, expected) in const [0.1, 0.2, 0.3].indexed) {
        expect(decoded[i], closeTo(expected, 1e-6));
      }
    });

    test('four bytes per element, little-endian', () {
      expect(encodeEmbedding(const [1.0]), Uint8List.fromList([0, 0, 128, 63]));
      expect(encodeEmbedding(const [0.5, 0.5]).length, 8);
      expect(encodeEmbedding(const []), isEmpty);
    });

    test('a truncated blob drops the partial float rather than throwing', () {
      final bytes = encodeEmbedding(const [1.0, 2.0]);
      final truncated = Uint8List.sublistView(bytes, 0, 6);

      expect(decodeEmbedding(truncated), [1.0]);
    });
  });

  group('cosine', () {
    test('identical vectors are 1', () {
      const v = [0.3, 0.4, 0.5];

      expect(cosine(v, v), closeTo(1.0, 1e-6));
    });

    test('un-normalised vectors still read as identical', () {
      // What the full formula buys over a bare dot product: a vector that
      // arrives un-normalised reads correctly instead of unboundedly.
      expect(cosine(const [1.0, 2.0], const [3.0, 6.0]), closeTo(1.0, 1e-6));
    });

    test('orthogonal vectors are 0', () {
      expect(cosine(const [1.0, 0.0], const [0.0, 1.0]), closeTo(0.0, 1e-6));
    });

    test('opposite vectors are -1', () {
      expect(cosine(const [1.0, 0.0], const [-1.0, 0.0]), closeTo(-1.0, 1e-6));
    });

    test('a zero vector is 0, never NaN', () {
      // A NaN here would poison every sort it reached.
      expect(cosine(const [0.0, 0.0], const [1.0, 1.0]), 0);
      expect(cosine(const [0.0, 0.0], const [0.0, 0.0]), 0);
    });

    test('mismatched lengths and empties are 0', () {
      expect(cosine(const [1.0, 0.0], const [1.0]), 0);
      expect(cosine(const [], const []), 0);
    });
  });
}
