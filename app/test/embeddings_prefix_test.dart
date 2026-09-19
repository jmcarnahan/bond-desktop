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
      expect(
        EmbeddingsClient.clusteringPrefix,
        'Instruct: Group email threads that belong to the same project, '
        'event or topic. Query: ',
      );
      expect(EmbeddingsClient.modelTag, 'Qwen3-Embedding-0.6B/clustering-v3');
    });

    test('the clustering prefix is 86 characters and ends in a space', () {
      // The two things a shell, a make variable or a `--dart-define` can eat
      // without anyone noticing. `make golden-vector` prints this LENGTH for
      // exactly that reason, and the bench's rows were measured at 86.
      expect(EmbeddingsClient.clusteringPrefix, hasLength(86));
      expect(EmbeddingsClient.clusteringPrefix, endsWith(' '));
      // A period where Qwen's documented instruction form has a newline: a
      // make variable cannot carry one, so the period is what was measured.
      expect(EmbeddingsClient.clusteringPrefix, isNot(contains('\n')));
    });

    test('the two retired tags are the ones the model swaps orphaned', () {
      // `-v3` is 2026-09-19, when the whole vector moved to
      // Qwen3-Embedding-0.6B; `-v2` is 2026-09-18, when the people left the
      // clustering card. Both old strings are pinned because
      // `retiredClusteringTags` reads them and the one-shots write the
      // current one. A vector under either is in a different space, and under
      // the v2 and v1 tags in a different WIDTH as well.
      expect(
        EmbeddingsClient.retiredModelTag,
        'embeddinggemma-300M/clustering-v2',
      );
      expect(
        EmbeddingsClient.retiredModelTagV1,
        'embeddinggemma-300M/clustering',
      );
      expect(
        {
          EmbeddingsClient.retiredModelTag,
          EmbeddingsClient.retiredModelTagV1,
        },
        isNot(contains(EmbeddingsClient.modelTag)),
      );
    });

    test('the document pair is exactly what every stored message vector was '
        'written under', () {
      // Empty, and empty is the contract rather than an unfilled slot: Qwen
      // instructs the query alone and embeds a document as itself.
      expect(EmbeddingsClient.documentPrefix, '');
      expect(
        EmbeddingsClient.documentModelTag,
        'Qwen3-Embedding-0.6B/document',
      );
    });

    test('a query is embedded as a question, not as a document', () {
      // Searching with the document prefix returns plausible-looking noise —
      // the model is trained on the query/document PAIR, not on either alone.
      expect(
        EmbeddingsClient.searchQueryPrefix,
        'Instruct: Given a search query, retrieve the messages and documents '
        'that answer it. Query: ',
      );
      expect(EmbeddingsClient.searchQueryPrefix, endsWith(' '));
      expect(
        EmbeddingsClient.searchQueryPrefix,
        isNot(EmbeddingsClient.documentPrefix),
      );
    });

    test('the clustering and document corpora are never the same space', () {
      // One server, one model, two prefixes: the ONLY thing keeping a
      // conversation vector out of a search result is that these four strings
      // differ pairwise.
      expect(
        EmbeddingsClient.clusteringPrefix,
        isNot(EmbeddingsClient.documentPrefix),
      );
      expect(
        EmbeddingsClient.clusteringPrefix,
        isNot(EmbeddingsClient.searchQueryPrefix),
      );
      expect(
        EmbeddingsClient.modelTag,
        isNot(EmbeddingsClient.documentModelTag),
      );
    });
  });

  group('request bodies', () {
    test('the default call is byte-identical to what it always sent', () async {
      final recorder = BodyRecorder();

      await recorder.client.embedResult('hello');

      expect(
        recorder.bodies.single,
        '{"input":"Instruct: Group email threads that belong to the same '
        'project, event or topic. Query: hello","model":"embed"}',
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
        '{"input":"Instruct: Group email threads that belong to the same '
        'project, event or topic. Query: hello","model":"embed"}',
      );
      expect(explicit.bodies.single, byDefault.bodies.single);
    });

    test('a document goes out bare', () async {
      // The empty document prefix, stated as the bytes on the wire: Qwen
      // embeds a document as itself, so anything at all in front of the card
      // would move every stored passage away from the queries trained to find
      // it.
      final recorder = BodyRecorder();

      await recorder.client
          .embedResult('hello', prefix: EmbeddingsClient.documentPrefix);

      expect(recorder.bodies.single, '{"input":"hello","model":"embed"}');
    });

    test('the search prefix goes out verbatim', () async {
      final recorder = BodyRecorder();

      await recorder.client
          .embedResult('hello', prefix: EmbeddingsClient.searchQueryPrefix);

      expect(
        recorder.bodies.single,
        '{"input":"Instruct: Given a search query, retrieve the messages and '
        'documents that answer it. Query: hello","model":"embed"}',
      );
    });
  });
}
