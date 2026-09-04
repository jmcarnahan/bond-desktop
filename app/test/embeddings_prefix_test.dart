import 'dart:convert';

import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The prefixes, pinned as REQUEST BYTES rather than as behaviour.
///
/// Every stored vector was produced by a request body this file spells out. A
/// change to any of these strings — a stray space, a reordered key, a default
/// that stops defaulting — puts new vectors somewhere else in the model's
/// space while the old ones stay where they were, and nothing anywhere throws:
/// storylines simply stop growing and search simply stops finding. The tests
/// below are the only thing that says so out loud.

const String _url = 'http://localhost:8081/v1/embeddings';

/// Records the exact body of every request, byte for byte.
class BodyRecorder {
  final List<String> bodies = [];

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: _url,
        httpClient: MockClient((request) async {
          bodies.add(request.body);
          return http.Response(
            jsonEncode({
              'data': [
                {'embedding': const [0.1, 0.2]}
              ]
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
}

void main() {
  group('the constants themselves', () {
    test('the clustering pair is exactly what every stored conversation '
        'vector was written under', () {
      expect(EmbeddingsClient.clusteringPrefix, 'task: clustering | query: ');
      expect(EmbeddingsClient.modelTag, 'embeddinggemma-300M/clustering');
    });

    test('the document pair is exactly what every stored message vector was '
        'written under', () {
      expect(EmbeddingsClient.documentPrefix, 'title: none | text: ');
      expect(EmbeddingsClient.documentModelTag, 'embeddinggemma-300M/document');
    });

    test('a query is embedded as a question, not as a document', () {
      // Searching with the document prefix returns plausible-looking noise —
      // the model is trained on the query/document PAIR, not on either alone.
      expect(
        EmbeddingsClient.searchQueryPrefix,
        'task: search result | query: ',
      );
      expect(
        EmbeddingsClient.searchQueryPrefix,
        isNot(EmbeddingsClient.documentPrefix),
      );
    });
  });

  group('request bodies', () {
    test('the default call is byte-identical to what it always sent', () async {
      final recorder = BodyRecorder();

      await recorder.client.embedResult('hello');

      expect(
        recorder.bodies.single,
        '{"input":"task: clustering | query: hello","model":"embed"}',
      );
    });

    test('naming the clustering prefix changes not one byte', () async {
      // The invariant the whole default exists for: `_refreshCard` and
      // `StorylineService` pass no prefix, and they must keep producing the
      // request that every conversation vector in the database came from.
      final byDefault = BodyRecorder();
      final explicit = BodyRecorder();

      await byDefault.client.embedResult('hello');
      await explicit.client
          .embedResult('hello', prefix: EmbeddingsClient.clusteringPrefix);

      expect(byDefault.bodies.single, explicit.bodies.single);
    });

    test('embed() defaults the same way embedResult() does', () async {
      final byDefault = BodyRecorder();
      final explicit = BodyRecorder();

      await byDefault.client.embed('hello');
      await explicit.client
          .embed('hello', prefix: EmbeddingsClient.clusteringPrefix);

      expect(
        byDefault.bodies.single,
        '{"input":"task: clustering | query: hello","model":"embed"}',
      );
      expect(explicit.bodies.single, byDefault.bodies.single);
    });

    test('the document prefix goes out verbatim', () async {
      final recorder = BodyRecorder();

      await recorder.client
          .embedResult('hello', prefix: EmbeddingsClient.documentPrefix);

      expect(
        recorder.bodies.single,
        '{"input":"title: none | text: hello","model":"embed"}',
      );
      expect(recorder.bodies.single, contains('title: none | text: hello'));
    });

    test('the search prefix goes out verbatim', () async {
      final recorder = BodyRecorder();

      await recorder.client
          .embedResult('hello', prefix: EmbeddingsClient.searchQueryPrefix);

      expect(
        recorder.bodies.single,
        '{"input":"task: search result | query: hello","model":"embed"}',
      );
      expect(
        recorder.bodies.single,
        contains('task: search result | query: hello'),
      );
    });
  });
}
