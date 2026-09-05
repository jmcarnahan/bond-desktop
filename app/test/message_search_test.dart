import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/embed_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

/// A 768-wide vector with a few named axes set — everything else zero.
///
/// Distinct axes make the geometry arithmetic-free: two vectors' cosine
/// distance is whatever the shared components say and nothing else, so a
/// failing assertion below is a failure of the search, never of the fixture's
/// maths.
List<double> axes(Map<int, double> components) {
  final v = List.filled(768, 0.0);
  components.forEach((axis, value) => v[axis] = value);
  return v;
}

/// A fake embedding server that is deterministic in the text it is given.
///
/// It reads a keyword out of whatever it was asked to embed and answers with
/// that keyword's fixed vector, so "these two texts are about the same thing"
/// becomes a fact the test states rather than one a real model has to be
/// trusted for. Both corpora go through here: a document card and the query
/// that should find it are keyed on the same word and get the same vector.
class FakeEmbedServer {
  final List<String> inputs = [];

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient((request) async {
          final input =
              (jsonDecode(request.body) as Map<String, dynamic>)['input']
                  as String;
          inputs.add(input);
          final lower = input.toLowerCase();
          final vector = switch (lower) {
            // Order matters: the first match wins, and no card below contains
            // two of these words.
            _ when lower.contains('invoice') => axes({0: 1.0}),
            // Close to the invoice axis but not on it — a near miss that must
            // still rank above the unrelated one.
            _ when lower.contains('parking') => axes({0: 0.9, 2: 0.4359}),
            _ when lower.contains('launch') => axes({0: 0.5, 1: 0.866}),
            _ => axes({3: 1.0}),
          };
          return http.Response(
            jsonEncode({
              'data': [
                {'embedding': vector}
              ]
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
}

/// A client whose socket never answers.
EmbeddingsClient downServer() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient(
        (_) async => throw http.ClientException('connection refused'),
      ),
    );

/// A client that answers, and not with a vector.
EmbeddingsClient rejectingServer() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );

void main() {
  group('the search cannot run', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    test('an unreachable embedding server is not an empty result', () async {
      final result = await MessageSearch(store, downServer()).search('invoice');

      // The distinction the whole sealed type exists for: an empty list would
      // tell the reader their mail contains nothing about invoices, which is a
      // lie about their mailbox rather than a fact about the machine.
      expect(result, isA<MessageSearchUnavailable>());
      expect(
        (result as MessageSearchUnavailable).reason,
        contains('make embed'),
      );
    });

    test('a server that answers badly is also unavailable — the reader can '
        'do nothing different about it', () async {
      final result =
          await MessageSearch(store, rejectingServer()).search('invoice');

      expect(result, isA<MessageSearchUnavailable>());
      expect((result as MessageSearchUnavailable).reason, isNotEmpty);
    });

    test('the archive still answers with what text can find', () async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'gated',
        'conversation_key': 'c-gated',
        'direction': 'inbound',
        'subject': 'Invoice 4471 is overdue',
        'received_at': '2026-08-29T10:00:00Z',
      });

      final result =
          await MessageSearch(store, downServer()).searchArchive('invoice');

      // The contrast with the test above, and the reason the archive's result
      // type is not the sealed one: a down server narrows this answer, where
      // on Home it replaces it.
      expect([for (final row in result.rows) row.sourceMessageId], ['gated']);
      expect(result.notice, startsWith('Text matches only'));
      expect(result.query, 'invoice');
    });
  });

  group('end to end', () {
    late bool available;
    late BondDatabase db;
    late MessageStore store;
    late FakeEmbedServer server;

    setUpAll(() {
      available = ensureSqliteVecLoaded();
    });

    setUp(() {
      db = vecTestDb();
      store = MessageStore(db);
      server = FakeEmbedServer();
    });

    tearDown(() async => db.close());

    Future<void> seed({
      required String id,
      required String subject,
      String body = 'body text',
      String receivedAt = '2026-08-29T10:00:00Z',
      String from = 'Sarah',
    }) async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': 'conv-$id',
        'direction': 'inbound',
        'subject': subject,
        'from_name': from,
        'from_address': 'sarah@x.com',
        'received_at': receivedAt,
        'body_text': body,
      });
      await store.writeTriage(
        'email',
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: subject,
          needsAction: false,
          actionItems: const [],
        ),
      );
    }

    Future<void> embed(String id) async {
      final row = (await store.getMessageRow('email', id))!;
      final outcome = await embedMessageRow(store, server.client, 'email', row);
      expect(outcome, MessageEmbedOutcome.embedded);
    }

    /// Three messages, one per axis of the fake server's little universe.
    Future<void> seedCorpus() async {
      await seed(id: 'inv', subject: 'Invoice 4471 is overdue');
      await seed(id: 'park', subject: 'Parking permit renewal');
      await seed(id: 'launch', subject: 'Launch date moved to Friday');
      await embed('inv');
      await embed('park');
      await embed('launch');
    }

    List<String> idsOf(MessageSearchResult result) => [
          for (final hit in (result as MessageSearchHits).hits)
            hit.row.sourceMessageId,
        ];

    test('ranks the nearest message first', () async {
      if (!available) return;
      await seedCorpus();

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      expect(idsOf(result), ['inv', 'park', 'launch']);
      final hits = (result as MessageSearchHits).hits;
      // Cosine distance, so smaller is nearer and the list is ascending.
      expect(hits.first.distance, lessThan(hits.last.distance));
      expect(hits.first.distance, closeTo(0, 0.001));
      expect(result.query, 'the invoice');
    });

    test('a hit carries the message row behind it', () async {
      if (!available) return;
      await seedCorpus();

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      final row = (result as MessageSearchHits).hits.first.row;
      expect(row.subject, 'Invoice 4471 is overdue');
      expect(row.fromName, 'Sarah');
      expect(row.fromAddress, 'sarah@x.com');
      expect(row.source, 'email');
      expect(row.receivedAt, '2026-08-29T10:00:00Z');
    });

    test('honours the limit', () async {
      if (!available) return;
      await seedCorpus();

      final result =
          await MessageSearch(store, server.client).search('the invoice', limit: 1);

      expect(idsOf(result), ['inv']);
    });

    test('a query nothing is about finds nothing — and says so as an empty '
        'result, not as unavailable', () async {
      if (!available) return;
      await seed(id: 'inv', subject: 'Invoice 4471 is overdue');
      await embed('inv');

      // The fake server puts an unmatched query on its own axis, orthogonal
      // to everything seeded — the KNN still returns the row, at distance 1.
      final result =
          await MessageSearch(store, server.client).search('something else');

      expect(result, isA<MessageSearchHits>());
      expect(
        (result as MessageSearchHits).hits.first.distance,
        closeTo(1, 0.001),
      );
    });

    group('dropped rows', () {
      Future<void> dropPark() => store.writeSettledProgress(
            'email',
            'park',
            needsYou: false,
            reason: 'not_worthy',
            dropped: true,
          );

      test('are left out by default, even when they rank', () async {
        if (!available) return;
        await seedCorpus();
        await dropPark();

        final result =
            await MessageSearch(store, server.client).search('the invoice');

        // `park` was the second-nearest. The filter runs AFTER the KNN, which
        // is why the over-fetch exists: the page still fills.
        expect(idsOf(result), ['inv', 'launch']);
      });

      test('come back when they are asked for', () async {
        if (!available) return;
        await seedCorpus();
        await dropPark();

        final result = await MessageSearch(store, server.client)
            .search('the invoice', includeDropped: true);

        expect(idsOf(result), ['inv', 'park', 'launch']);
      });
    });

    test('a vector from the clustering corpus never surfaces', () async {
      if (!available) return;
      await seedCorpus();
      // A perfect match on the query axis — and the WRONG corpus. Distances
      // between the two are numbers with no meaning, and a number with no
      // meaning still sorts, so the tag filter is the only thing keeping it
      // off the top of the list.
      await seed(id: 'ghost', subject: 'Invoice ghost');
      await store.upsertMessageVector(
        source: 'email',
        sourceMessageId: 'ghost',
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: 768,
        embeddedHash: 'whatever',
        embedModel: EmbeddingsClient.modelTag,
      );
      await store.indexPendingVectors();

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      expect(idsOf(result), isNot(contains('ghost')));
      expect(idsOf(result), ['inv', 'park', 'launch']);
    });

    test('a durable vector the index never saw is healed by the search itself',
        () async {
      if (!available) return;
      await seed(id: 'inv', subject: 'Invoice 4471 is overdue');
      // Written straight to the durable table, with no index pass after it —
      // the shape a width-change rebuild or a missed extension leaves behind.
      await store.upsertMessageVector(
        source: 'email',
        sourceMessageId: 'inv',
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: 768,
        embeddedHash: 'whatever',
        embedModel: EmbeddingsClient.documentModelTag,
      );

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      // The search backfilled before asking, so the row is simply there.
      expect(idsOf(result), ['inv']);
    });

    test('wipeAll empties the index too — old floats do not survive the wipe',
        () async {
      if (!available) return;
      await seedCorpus();
      Future<int> indexRows() async => (await db
              .customSelect('SELECT COUNT(*) AS n FROM vec_messages')
              .getSingle())
          .data['n'] as int;
      expect(await indexRows(), 3);

      await store.wipeAll();

      // DELETE FROM message_vectors cannot reach inside the virtual table;
      // the rebuild at the end of the wipe is what makes this zero.
      expect(await indexRows(), 0);
    });

    group('the archive searches both ways at once', () {
      /// A message the gate threw out: stored, never embedded, so the index
      /// has no way of knowing it exists.
      Future<void> seedGated() async {
        await seed(id: 'gated', subject: 'Invoice from the newsletter');
        await store.writeSettledProgress(
          'email',
          'gated',
          needsYou: false,
          reason: 'newsletter',
          dropped: true,
        );
      }

      test('meaning ranks first and text fills in behind it', () async {
        if (!available) return;
        await seedCorpus();
        await seedGated();

        final result =
            await MessageSearch(store, server.client).searchArchive('invoice');

        final ids = [for (final row in result.rows) row.sourceMessageId];
        expect(ids.first, 'inv', reason: 'the nearest message is still first');
        // Behind everything the index ranked, because it has no rank of its
        // own — but present, which is the point.
        expect(ids.indexOf('gated'), greaterThan(ids.indexOf('inv')));
        expect(ids, contains('gated'));
        expect(result.notice, isNull, reason: 'both halves ran');
      });

      test('a message both halves find is one row', () async {
        if (!available) return;
        await seedCorpus();

        final result =
            await MessageSearch(store, server.client).searchArchive('invoice');

        // `inv` is the top semantic hit AND a literal text match; the merge
        // keys on the feed key, so it arrives once.
        final keys = {for (final row in result.rows) row.feedKey};
        expect(keys, hasLength(result.rows.length));
        expect(
          [for (final row in result.rows) row.sourceMessageId]
              .where((id) => id == 'inv'),
          hasLength(1),
        );
      });
    });

    test('a wrong-width vector is skipped rather than poisoning the index',
        () async {
      if (!available) return;
      await seedCorpus();
      await seed(id: 'short', subject: 'Invoice truncated');
      await store.upsertMessageVector(
        source: 'email',
        sourceMessageId: 'short',
        embedding: Uint8List(16),
        dims: 4,
        embeddedHash: 'whatever',
        embedModel: EmbeddingsClient.documentModelTag,
      );
      await store.indexPendingVectors();

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      expect(idsOf(result), ['inv', 'park', 'launch']);
    });
  });
}
