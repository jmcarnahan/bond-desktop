import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;
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

      await stub.client.embed('Launch date | Sarah Chen');

      expect(
        stub.bodies.single['input'],
        '${EmbeddingsClient.clusteringPrefix}Launch date | Sarah Chen',
      );
      // Everything this app embeds is embedded to be clustered. A corpus half
      // written under one prefix is a corpus whose distances mean nothing.
      // The prefix's own text is pinned in embeddings_prefix_test.dart; here
      // only that it is non-empty and leads the input matters.
      expect(EmbeddingsClient.clusteringPrefix, isNotEmpty);
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

  group('decoding as float32', () {
    // The decode before it returned a Float32List: a growable list of boxed
    // doubles, read one by one. Kept here as the oracle the new one must
    // agree with element for element.
    List<double> oldDecode(Uint8List b) {
      final view = ByteData.sublistView(b);
      final count = b.lengthInBytes ~/ 4;
      return [
        for (var i = 0; i < count; i++) view.getFloat32(i * 4, Endian.little),
      ];
    }

    // None of these but 0.0 and -0.0 is exactly a float32, which is the
    // point: the rounding happens in encode, and decode must read back the
    // very float32 the old loop read. 1e-40 is subnormal in float32.
    final values = <double>[
      0.1,
      1 / 3,
      -2.7,
      1e-7,
      3.4e38,
      1e-40,
      0.0,
      -0.0,
      double.nan,
    ];

    test('returns a Float32List the old decode agrees with exactly', () {
      final blob = encodeEmbedding(values);
      final decoded = decodeEmbedding(blob);
      final old = oldDecode(blob);

      expect(decoded, isA<Float32List>());
      expect(decoded.length, values.length);
      for (var i = 0; i < values.length; i++) {
        if (old[i].isNaN) {
          expect(decoded[i].isNaN, isTrue, reason: 'index $i');
          continue;
        }
        expect(decoded[i] == old[i], isTrue, reason: 'index $i');
      }
      // -0.0 == 0.0 in Dart, so the sign is asserted on its own.
      final negZero = values.indexOf(-0.0, values.indexOf(0.0) + 1);
      expect(decoded[negZero].isNegative, isTrue);
      expect(old[negZero].isNegative, isTrue);
    });

    test('equals Float32List.fromList and re-encodes byte for byte', () {
      final finite = values.where((v) => !v.isNaN).toList();
      final blob = encodeEmbedding(finite);
      final decoded = decodeEmbedding(blob);

      final expected = Float32List.fromList(finite);
      for (var i = 0; i < finite.length; i++) {
        expect(decoded[i] == expected[i], isTrue, reason: 'index $i');
      }
      expect(encodeEmbedding(decoded), blob);
    });

    test('an unaligned blob takes the copying path and agrees', () {
      final source = encodeEmbedding(const [0.1, -2.7, 1e-7, 0.5]);
      final bytes = Uint8List(source.length + 1);
      bytes.setRange(1, bytes.length, source);
      final unaligned = Uint8List.sublistView(bytes, 1);
      expect(unaligned.offsetInBytes, 1);

      final decoded = decodeEmbedding(unaligned);
      final expected = List<double>.of(decodeEmbedding(source));

      expect(decoded, isA<Float32List>());
      expect(decoded, expected);
      // A copy, not a view: the source bytes changing afterwards does not
      // reach it.
      bytes.fillRange(1, bytes.length, 0);
      expect(decoded, expected);
    });

    test('a truncated blob decodes the whole floats only', () {
      final blob = encodeEmbedding(const [1.0, 2.0, 3.0]);
      final truncated = Uint8List.fromList([...blob, 9, 9, 9]);

      expect(truncated.length, 4 * 3 + 3);
      expect(decodeEmbedding(truncated), [1.0, 2.0, 3.0]);
    });

    test('a blob that starts part-way into a larger buffer is read from '
        'its own offset, and no further than its own length', () {
      // Junk on both sides of the vector: a view that ignored the blob's
      // offset or its length would read it.
      final floats = encodeEmbedding(values);
      final big = Uint8List(8 + floats.length + 8)
        ..fillRange(0, 8, 0xAB)
        ..setRange(8, 8 + floats.length, floats)
        ..fillRange(8 + floats.length, 16 + floats.length, 0xCD);
      final blob = Uint8List.sublistView(big, 8, 8 + floats.length);
      expect(blob.offsetInBytes, 8);

      final decoded = decodeEmbedding(blob);
      final old = oldDecode(blob);

      expect(decoded, isA<Float32List>());
      expect(decoded.length, values.length);
      for (var i = 0; i < values.length; i++) {
        if (old[i].isNaN) {
          expect(decoded[i].isNaN, isTrue, reason: 'index $i');
          continue;
        }
        expect(decoded[i] == old[i], isTrue, reason: 'index $i');
      }

      // And cut short inside that buffer: fifteen bytes are three floats.
      final short = Uint8List.sublistView(big, 8, 8 + 15);
      final three = decodeEmbedding(short);
      expect(three.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(three[i] == old[i], isTrue, reason: 'index $i');
      }
    });

    test('an empty blob decodes to an empty list', () {
      expect(decodeEmbedding(Uint8List(0)), isEmpty);
    });

    test('an aligned blob is read in place, sharing its bytes', () {
      // The documented consequence, pinned rather than hidden: the result
      // is a view over the blob, so it is read and never written to.
      if (Endian.host != Endian.little) return;
      final blob = encodeEmbedding(const [0.25, 0.5]);
      final decoded = decodeEmbedding(blob) as Float32List;

      // `==`, not `identical`: the VM hands out a fresh ByteBuffer wrapper
      // per `.buffer` read, and its `==` is what compares the bytes behind.
      expect(decoded.buffer == blob.buffer, isTrue);
      // And the aliasing itself: a write to the blob shows through.
      blob.setAll(0, encodeEmbedding(const [0.75]));
      expect(decoded[0], 0.75);
    });

    test('the result is fixed-length', () {
      final decoded = decodeEmbedding(encodeEmbedding(const [0.25, 0.5]));

      expect(() => decoded.add(1.0), throwsUnsupportedError);
    });
  });

  group('cosine over Float32List', () {
    // The typed branch must return the bit-identical double the general
    // loop returns for the same values: same sums, same order.
    Float32List randomVector(math.Random random) => Float32List.fromList([
          for (var i = 0; i < 1024; i++) random.nextDouble() * 2 - 1,
        ]);

    void same(Float32List a, Float32List b) {
      final typed = cosine(a, b);
      final boxed = cosine(List<double>.of(a), List<double>.of(b));
      expect(typed == boxed, isTrue, reason: 'typed $typed, boxed $boxed');
      // A mixed pair takes the general loop and agrees with both.
      expect(cosine(a, List<double>.of(b)) == boxed, isTrue);
      expect(cosine(List<double>.of(a), b) == boxed, isTrue);
    }

    test('random 1024-wide pairs', () {
      final random = math.Random(7);
      for (var n = 0; n < 20; n++) {
        same(randomVector(random), randomVector(random));
      }
    });

    test('identical, opposite, zero and mismatched vectors', () {
      final random = math.Random(7);
      final v = randomVector(random);
      final opposite = Float32List.fromList([for (final x in v) -x]);

      same(v, v);
      same(v, opposite);
      same(v, Float32List(1024));
      same(Float32List(1024), Float32List(1024));
      same(v, Float32List(512));
      same(Float32List(0), Float32List(0));
    });

    test('decoded stored vectors take the typed loop to the same number', () {
      final random = math.Random(7);
      final a = decodeEmbedding(encodeEmbedding(randomVector(random)));
      final b = decodeEmbedding(encodeEmbedding(randomVector(random)));

      expect(a, isA<Float32List>());
      expect(cosine(a, b) == cosine(List<double>.of(a), List<double>.of(b)),
          isTrue);
    });
  });
}
