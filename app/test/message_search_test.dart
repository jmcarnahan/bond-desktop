import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
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
            // The word that only ever appears inside a document, so a hit on
            // it is a hit on an attachment and on nothing else.
            _ when lower.contains('escalator') => axes({4: 1.0}),
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

    Future<void> seedGated() => store.upsertMessage({
          'source': 'email',
          'source_message_id': 'gated',
          'conversation_key': 'c-gated',
          'direction': 'inbound',
          'subject': 'Invoice 4471 is overdue',
          'received_at': '2026-08-29T10:00:00Z',
        });

    test('an unreachable embedding server narrows the answer rather than '
        'removing it', () async {
      await seedGated();

      final result = await MessageSearch(store, downServer()).search('invoice');

      // A dead embedding server costs the MEANING half and not the answer. An
      // empty list with no sentence on it would tell the reader their mail
      // contains nothing about invoices — a lie about their mailbox, told on
      // the strength of a server being off.
      final hits = result as MessageSearchHits;
      expect([for (final hit in hits.hits) hit.row.sourceMessageId], ['gated']);
      expect(hits.hits.single.matchedBy, MatchedBy.words);
      expect(hits.hits.single.distance, isNull);
      expect(hits.notice, startsWith('Words only'));
      expect(hits.notice, contains('make embed'));
    });

    test('a server that answers badly narrows it the same way — the reader '
        'can do nothing different about either', () async {
      await seedGated();

      final result =
          await MessageSearch(store, rejectingServer()).search('invoice');

      final hits = result as MessageSearchHits;
      expect([for (final hit in hits.hits) hit.row.sourceMessageId], ['gated']);
      expect(hits.notice, isNotNull);
    });

    test('only BOTH passes failing is unavailable', () async {
      await seedGated();
      // The database out from under the text pass, which is the one shape
      // that leaves nothing to show: the embedding server is already down, so
      // neither half can answer and the sealed case earns itself.
      await db.close();

      final result = await MessageSearch(store, downServer()).search('invoice');

      expect(result, isA<MessageSearchUnavailable>());
      expect(
        (result as MessageSearchUnavailable).reason,
        contains('make embed'),
      );
    });

    group('the dropped filter reaches the word pass too', () {
      Future<void> seedDropped() async {
        await seedGated();
        await store.writeSettledProgress(
          'email',
          'gated',
          needsYou: false,
          reason: 'newsletter',
          dropped: true,
        );
      }

      test('a dropped message is out of a home search by default', () async {
        await seedDropped();

        final result =
            await MessageSearch(store, downServer()).search('invoice');

        // The table under the results hides dropped rows, and a search that
        // did not would answer a question the reader is not asking.
        expect((result as MessageSearchHits).hits, isEmpty);
      });

      test('and comes back when the toggle asks for it', () async {
        await seedDropped();

        final result = await MessageSearch(store, downServer())
            .search('invoice', includeDropped: true);

        expect(
          [for (final hit in (result as MessageSearchHits).hits)
            hit.row.sourceMessageId],
          ['gated'],
        );
      });
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
      expect(result.notice, startsWith('Words only'));
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

    test('the message both passes find leads, and one list holds them all',
        () async {
      if (!available) return;
      await seedCorpus();

      final result =
          await MessageSearch(store, server.client).search('the invoice');

      expect(idsOf(result), ['inv', 'park', 'launch']);
      final hits = (result as MessageSearchHits).hits;
      // `inv` is the nearest vector AND the only literal word match, so it
      // scores on both halves where the other two score on one.
      expect(hits.first.matchedBy, MatchedBy.both);
      expect(hits.first.score, greaterThan(hits[1].score));
      expect(hits[1].matchedBy, MatchedBy.meaning);
      // The numbers ride along for a later "why this result".
      expect(hits.first.distance, closeTo(0, 0.001));
      expect(hits.first.bm25, isNotNull);
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
      // to everything seeded, so the KNN still returns the row — at distance
      // 1, which is past the far end of the ramp — and the words match
      // nothing. The floor is the only reason this is empty rather than the
      // whole mailbox.
      final result =
          await MessageSearch(store, server.client).search('something else');

      expect(result, isA<MessageSearchHits>());
      expect((result as MessageSearchHits).hits, isEmpty);
      expect(result.notice, isNull, reason: 'both passes ran');
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
      // Its subject shares no word with the query: this test is about the
      // model tag, and a row the WORDS could legitimately find would prove
      // nothing about it.
      await seed(id: 'ghost', subject: 'Nothing to see here');
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
      /// has no way of knowing it exists. Its subject carries a word no other
      /// message and no axis of the fake server knows about, so finding it is
      /// unambiguously the work of the word pass.
      Future<void> seedGated() async {
        await seed(id: 'gated', subject: 'Escrow paperwork from the newsletter');
        await store.writeSettledProgress(
          'email',
          'gated',
          needsYou: false,
          reason: 'newsletter',
          dropped: true,
        );
      }

      test('a message with no vector at all is found by its words', () async {
        if (!available) return;
        await seedCorpus();
        await seedGated();

        final result =
            await MessageSearch(store, server.client).searchArchive('escrow');

        // Every embedded message sits an axis away from this query, so the
        // ranking half contributes nothing above the floor. "I know I got
        // that email" is answered entirely by the words.
        expect([for (final row in result.rows) row.sourceMessageId], ['gated']);
        expect(result.notice, isNull, reason: 'both halves ran');
      });

      test('a message both halves find is one row', () async {
        if (!available) return;
        await seedCorpus();

        final result =
            await MessageSearch(store, server.client).searchArchive('invoice');

        // `inv` is the top semantic hit AND a literal word match; the fusion
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
      // No shared word with the query, for the ghost's reason above.
      await seed(id: 'short', subject: 'Truncated payload');
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

    group('the word index is not there', () {
      /// The same database, read through a store that was built without the
      /// word half. FTS5 is compiled into every SQLite this suite can open,
      /// so the seam is the only way to reach the state a build without it
      /// would be in.
      MessageStore quiet() => MessageStore(db, keywordSearch: false);

      test('meaning still answers, and the notice says what is missing',
          () async {
        if (!available) return;
        await seedCorpus();

        final result =
            await MessageSearch(quiet(), server.client).search('the invoice');

        final hits = result as MessageSearchHits;
        expect(idsOf(result), ['inv', 'park', 'launch']);
        expect(hits.hits.first.matchedBy, MatchedBy.meaning);
        expect(hits.hits.first.bm25, isNull);
        expect(
          hits.notice,
          'Meaning only — the keyword index could not be built.',
        );
      });

      test('and with the embedding server down as well, there is nothing left '
          'to show', () async {
        if (!available) return;
        await seedCorpus();

        final result =
            await MessageSearch(quiet(), downServer()).search('the invoice');

        // Both passes gone is the one shape that earns the sealed case: the
        // reader is owed an instruction, not an empty list that reads as an
        // answer about their mailbox.
        expect(result, isA<MessageSearchUnavailable>());
        expect(
          (result as MessageSearchUnavailable).reason,
          contains('make embed'),
        );
      });
    });

    group('the documents beside the messages', () {
      /// One attached document with one passage, embedded on [text]'s own
      /// axis through the same fake server the messages went through.
      Future<void> attach(
        String messageId,
        String attachmentId, {
        required String name,
        required String text,
      }) async {
        await store.upsertAttachments('email', messageId, [
          {
            'attachment_id': attachmentId,
            'ordinal': 0,
            'kind': 'file',
            'name': name,
            'content_type': 'application/pdf',
            'size': 240 * 1024,
          },
        ]);
        final ids = await store.replaceChunks('email', messageId, attachmentId, [
          (seq: 0, locator: 'part 1', text: text),
        ]);
        final result = await server.client.embedResult(
          text,
          prefix: EmbeddingsClient.documentPrefix,
        );
        await store.setChunkEmbedding(
          ids.single,
          embedding: encodeEmbedding(result.vector!),
          dims: result.vector!.length,
          embedModel: EmbeddingsClient.documentModelTag,
        );
      }

      test('a phrase inside a spreadsheet finds the file', () async {
        if (!available) return;
        await seedCorpus();
        await attach(
          'inv',
          'a1',
          name: 'Rent Roll.xlsx',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result = await MessageSearch(store, server.client)
            .search('the escalator clause');

        // The word appears in no message, so the message hits are whatever
        // the corpus ranks — the document is the answer, and it arrives on its
        // own list because it is not a message and cannot be drawn as one.
        final documents = (result as MessageSearchHits).documents;
        expect(documents, hasLength(1));
        expect(documents.single.name, 'Rent Roll.xlsx');
        expect(documents.single.locator, 'part 1');
        expect(documents.single.text, contains('escalator'));
        expect(documents.single.distance, closeTo(0, 0.001));
        expect(documents.single.bm25, isNotNull,
            reason: 'the words found the same passage');
        expect(documents.single.ref.messageId, 'inv');
        expect(documents.single.senderName, 'Sarah');
        expect(documents.single.outbound, isFalse);
      });

      test('a digest passage is never a search hit', () async {
        if (!available) return;
        await seedCorpus();
        await store.upsertAttachments('email', 'inv', [
          {
            'attachment_id': 'a1',
            'ordinal': 0,
            'kind': 'file',
            'name': 'Rent Roll.xlsx',
            'content_type': 'application/pdf',
            'size': 240 * 1024,
          },
        ]);
        // The digest sits ON the query's own words, so it is the nearest
        // passage this document has; the document's own words are further off.
        const digest = 'the escalator clause';
        const passage = 'Line 14: escalator of three percent each year.';
        final ids = await store.replaceChunks('email', 'inv', 'a1', const [
          (seq: 0, locator: 'part 1', text: passage),
          (seq: 1, locator: 'digest', text: digest),
        ]);
        for (final (index, text) in [passage, digest].indexed) {
          final result = await server.client.embedResult(
            text,
            prefix: EmbeddingsClient.documentPrefix,
          );
          await store.setChunkEmbedding(
            ids[index],
            embedding: encodeEmbedding(result.vector!),
            dims: result.vector!.length,
            embedModel: EmbeddingsClient.documentModelTag,
          );
        }

        final result = await MessageSearch(store, server.client)
            .search('the escalator clause');

        // A search result promises the document's OWN words. A digest is a
        // model's summary of them, and showing one would put sentences nobody
        // wrote under a file name.
        final documents = (result as MessageSearchHits).documents;
        expect(documents.single.locator, 'part 1');
        expect(documents.single.text, passage);
      });

      test('the message hits are unchanged by the documents beside them',
          () async {
        if (!available) return;
        await seedCorpus();
        await attach(
          'inv',
          'a1',
          name: 'Rent Roll.xlsx',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result =
            await MessageSearch(store, server.client).search('the invoice');

        expect(idsOf(result), ['inv', 'park', 'launch']);
      });

      test('a mailbox with no chunks still answers with an empty documents '
          'list', () async {
        if (!available) return;
        await seedCorpus();

        final result =
            await MessageSearch(store, server.client).search('the invoice');

        // Empty and never null: a search that ran is an answer about the whole
        // mailbox, documents included.
        expect((result as MessageSearchHits).documents, isEmpty);
      });

      test('a passage further off than the floor is not an answer', () async {
        if (!available) return;
        await seedCorpus();
        await attach(
          'inv',
          'a1',
          name: 'Rent Roll.xlsx',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result =
            await MessageSearch(store, server.client).search('the invoice');

        // The passage is an axis away from the query and shares no word with
        // it. Before the floor this list always had six passages in it,
        // whatever they were about.
        expect((result as MessageSearchHits).documents, isEmpty);
      });

      test('the same file attached twice is one answer', () async {
        if (!available) return;
        await seedCorpus();
        // Two `attachments` rows, one document — the shape a PDF forwarded
        // round an office takes. Nothing has fetched the bytes, so the name
        // and the size are the only identity available.
        await attach(
          'inv',
          'a1',
          name: 'Pub crawl.pdf',
          text: 'Line 14: escalator of three percent each year.',
        );
        await attach(
          'park',
          'a1',
          name: 'Pub crawl.pdf',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result = await MessageSearch(store, server.client)
            .search('the escalator clause');

        final documents = (result as MessageSearchHits).documents;
        expect(documents, hasLength(1));
        expect(documents.single.name, 'Pub crawl.pdf');
      });

      test('the archive answers about messages and never about a passage',
          () async {
        if (!available) return;
        await seedCorpus();
        await attach(
          'inv',
          'a1',
          name: 'Rent Roll.xlsx',
          text: 'Line 14: escalator of three percent each year.',
        );

        // The archive answers with feed ROWS — a shape that has no place to
        // put a passage. No message says "escalator", so the document that
        // does is simply not an answer here.
        final archive = await MessageSearch(store, server.client)
            .searchArchive('the escalator clause');

        expect(archive.rows, isEmpty);
        expect(archive.notice, isNull);
      });
    });
  });
}
