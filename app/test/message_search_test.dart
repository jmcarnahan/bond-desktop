import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/services/embed_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:bond_inbox/services/search_fusion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart' show embedDims;
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';
import 'fixtures/vec_test_db.dart';

/// A full-width vector with a few named axes set — everything else zero.
///
/// Distinct axes make the geometry arithmetic-free: two vectors' cosine
/// distance is whatever the shared components say and nothing else, so a
/// failing assertion below is a failure of the search, never of the fixture's
/// maths.
List<double> axes(Map<int, double> components) {
  final v = List.filled(embedDims, 0.0);
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

    // Plain connections opened before anything in this file registers
    // sqlite-vec (the 'end to end' group's setUpAll does, process-wide):
    // the index's functions are not on them.
    group('the people search without the index', () {
      Future<List<RelatedConversation>?> fromDana(Uint8List? query) =>
          store.conversationsFromSenders(
            queryEmbedding: query,
            embedModel: EmbeddingsClient.documentModelTag,
            addresses: const {'dana@fabrikam.com'},
            names: const {'Dana Lopez'},
            sinceIso: '2026-08-01T00:00:00Z',
          );

      setUp(() => store.upsertMessage({
            'source': 'email',
            'source_message_id': 'm-dana',
            'conversation_key': 'c-dana',
            'direction': 'inbound',
            'subject': 'Fabrikam renewal',
            'from_name': 'Dana Lopez',
            'from_address': 'dana@fabrikam.com',
            'received_at': '2026-08-29T10:00:00Z',
          }));

      test('ranked has nothing to rank with: null, the third answer',
          () async {
        expect(await fromDana(encodeEmbedding(List.filled(embedDims, 0.1))),
            isNull);
      });

      test('unranked needs no index and still answers', () async {
        final hits = (await fromDana(null))!;
        expect([for (final h in hits) (h.conversationKey, h.messageId)],
            [('c-dana', 'm-dana')]);
      });
    });
  });

  group('messagesBetween', () {
    late BondDatabase db;
    late MessageStore store;
    final now = DateTime.now().toUtc();
    String ago(Duration d) => MessageStore.isoStamp(now.subtract(d));

    setUp(() {
      db = testDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    Future<void> chat(String id, Duration age,
        {String key = 't-1', String source = 'teams'}) async {
      await store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Falcon room',
        'from_name': 'Dana',
        'from_address': 'teams:dana',
        'received_at': ago(age),
        'body_text': 'Message $id',
      });
    }

    test('inclusive at both ends, oldest first, one source and one '
        'conversation, no attachments', () async {
      await chat('before', const Duration(hours: 10));
      await chat('from', const Duration(hours: 8));
      await chat('mid-b', const Duration(hours: 6));
      await chat('mid-a', const Duration(hours: 7));
      await chat('to', const Duration(hours: 4));
      await chat('after', const Duration(hours: 2));
      // The same key in another source, and another chat, inside the window.
      await chat('mail', const Duration(hours: 6), source: 'email');
      await chat('other', const Duration(hours: 6), key: 't-2');
      await store.upsertAttachments('teams', 'mid-a', [
        {
          'attachment_id': 'a-1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'plan.pdf',
          'content_type': 'application/pdf',
          'size': 4096,
        },
      ]);

      final between = await store.messagesBetween('teams', 't-1',
          fromIso: ago(const Duration(hours: 8)),
          toIso: ago(const Duration(hours: 4)));
      expect([for (final m in between) m.id], ['from', 'mid-a', 'mid-b', 'to']);
      expect(between.every((m) => m.attachments.isEmpty), isTrue,
          reason: 'loadThread is the read that draws attachments');
      // The thread read does hydrate it, so the fixture is real.
      final whole = await store.loadThread('t-1', sources: const ['teams']);
      expect(whole.firstWhere((m) => m.id == 'mid-a').attachments,
          hasLength(1));
    });

    test('a message with no received_at is placed by when it was stored, '
        'the stamp its progress row carries', () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'unstamped',
        'conversation_key': 't-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'from_address': 'teams:dana',
        'received_at': null,
        'body_text': 'No stamp of its own.',
      });
      final between = await store.messagesBetween('teams', 't-1',
          fromIso: ago(const Duration(hours: 1)),
          toIso: MessageStore.isoStamp(now.add(const Duration(hours: 1))));
      expect([for (final m in between) m.id], ['unstamped']);
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
      String source = 'email',
    }) async {
      await store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': 'conv-$id',
        'direction': 'inbound',
        'subject': subject,
        'from_name': from,
        'from_address': 'sarah@x.com',
        'received_at': receivedAt,
        'body_text': body,
      });
      await writeTriaged(
        store,
        source,
        id,
        status: 'triaged',
        urgency: 'normal',
        category: 'work',
        summary: subject,
        needsAction: false,
        actionItems: const [],
      );
    }

    Future<void> embed(String id, {String source = 'email'}) async {
      final row = (await store.getMessageRow(source, id))!;
      final outcome = await embedMessageRow(store, server.client, source, row);
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

    test('sources narrows both corpora — what the in: facet rides on', () async {
      if (!available) return;
      await seed(id: 'inv', subject: 'Invoice 4471 is overdue');
      await seed(
        id: 'chat-inv',
        subject: 'Invoice 4471, in chat',
        source: 'teams',
      );
      await embed('inv');
      await embed('chat-inv', source: 'teams');

      final both =
          await MessageSearch(store, server.client).search('the invoice');
      expect(idsOf(both), containsAll(['inv', 'chat-inv']));

      // Narrowed in SQL rather than over the hits: the index's budget must be
      // spent on the connector the reader asked about.
      final chats = await MessageSearch(store, server.client)
          .search('the invoice', sources: const ['teams']);
      expect(idsOf(chats), ['chat-inv']);

      final mail = await MessageSearch(store, server.client)
          .search('the invoice', sources: const ['email']);
      expect(idsOf(mail), ['inv']);
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

    group('relatedConversations', () {
      final now = DateTime.now().toUtc();
      String ago(Duration d) => MessageStore.isoStamp(now.subtract(d));

      /// One embedded inbound message in conversation [key].
      Future<void> message(String id, String key, String subject,
          {Duration age = const Duration(hours: 2),
          String source = 'email'}) async {
        await store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': key,
          'direction': 'inbound',
          'subject': subject,
          'from_name': 'Dana',
          'from_address': 'dana@fabrikam.com',
          'received_at': ago(age),
          'body_text': subject,
        });
        await writeTriaged(store, source, id,
            status: 'triaged',
            urgency: 'normal',
            category: 'work',
            summary: subject,
            needsAction: false,
            actionItems: const []);
        await embed(id, source: source);
      }

      Future<List<RelatedConversation>?> related({
        double floor = 0.6,
        int limit = 12,
        Duration window = const Duration(days: 30),
      }) async {
        // The invoice axis: cosine 1 to an invoice, 0.9 to parking, 0.5 to
        // a launch, 0 to anything else.
        final q = (await server.client.embedResult('invoice',
                prefix: EmbeddingsClient.searchQueryPrefix))
            .vector!;
        return store.relatedConversations(
          encodeEmbedding(q),
          embedModel: EmbeddingsClient.documentModelTag,
          sinceIso: ago(window),
          floor: floor,
          limit: limit,
        );
      }

      test('one entry per conversation, scored by its best message, '
          'nearest first; a Teams chat is one too', () async {
        if (!available) return;
        await message('inv-1', 'c-inv', 'Invoice 4471 is overdue');
        // A second, farther message in the same conversation: it adds no
        // entry, and the conversation keeps the 1.0 of its best.
        await message('park-in-inv', 'c-inv', 'Parking for the audit call');
        await message('park', 'c-park', 'Parking permit renewal',
            source: 'teams');

        final hits = (await related())!;
        expect([for (final h in hits) (h.source, h.conversationKey)],
            [('email', 'c-inv'), ('teams', 'c-park')]);
        expect(hits.first.cosine, closeTo(1.0, 0.001));
        expect(hits[1].cosine, closeTo(0.9, 0.001));
      });

      test('each entry names its best message and that message\'s stamp',
          () async {
        if (!available) return;
        await message('park-in-inv', 'c-inv', 'Parking for the audit call',
            age: const Duration(hours: 1));
        await message('inv-1', 'c-inv', 'Invoice 4471 is overdue',
            age: const Duration(hours: 5));
        await message('park', 'c-park', 'Parking permit renewal',
            age: const Duration(hours: 3), source: 'teams');

        final hits = (await related())!;
        expect(
            [for (final h in hits) (h.conversationKey, h.messageId, h.receivedAt)],
            [
              // The older message is the nearer one, so it is the entry's,
              // not the conversation's newest.
              ('c-inv', 'inv-1', ago(const Duration(hours: 5))),
              ('c-park', 'park', ago(const Duration(hours: 3))),
            ]);
      });

      test('a dropped message is not a hit, and its conversation falls back '
          'to its next best', () async {
        if (!available) return;
        await message('inv-1', 'c-inv', 'Invoice 4471 is overdue');
        await message('park-in-inv', 'c-inv', 'Parking for the audit call');
        await message('inv-gone', 'c-gone', 'Invoice 4470 is overdue');
        for (final id in ['inv-1', 'inv-gone']) {
          await store.writeSettledProgress('email', id,
              needsYou: false, reason: 'not_worthy', dropped: true);
        }

        final hits = (await related())!;
        expect([for (final h in hits) (h.conversationKey, h.messageId)],
            [('c-inv', 'park-in-inv')]);
        expect(hits.single.cosine, closeTo(0.9, 0.001));
      });

      test('one busy chat with more than a hundred near messages does not '
          'crowd out a second conversation', () async {
        if (!available) return;
        // 120 messages in one chat, every one on the query's axis: nearer
        // than anything else. A read that kept the nearest hundred messages
        // would see this chat alone.
        for (var i = 0; i < 120; i++) {
          final id = 'busy-$i';
          await store.upsertMessage({
            'source': 'teams',
            'source_message_id': id,
            'conversation_key': 't-busy',
            'direction': 'inbound',
            'subject': 'Invoice chatter',
            'from_name': 'Dana',
            'from_address': 'teams:dana',
            'received_at': ago(Duration(minutes: 10 + i)),
            'body_text': 'Invoice chatter $i',
          });
          await store.upsertMessageVector(
            source: 'teams',
            sourceMessageId: id,
            embedding: encodeEmbedding(axes({0: 1.0})),
            dims: embedDims,
            embeddedHash: 'h-$id',
            embedModel: EmbeddingsClient.documentModelTag,
          );
        }
        await message('park', 'c-park', 'Parking permit renewal');

        final hits = (await related())!;
        expect([for (final h in hits) (h.source, h.conversationKey)],
            [('teams', 't-busy'), ('email', 'c-park')]);
        expect(hits[1].cosine, closeTo(0.9, 0.001));
      });

      test('stops at the floor, and at the limit', () async {
        if (!available) return;
        await message('inv', 'c-inv', 'Invoice 4471 is overdue');
        await message('park', 'c-park', 'Parking permit renewal');
        await message('launch', 'c-launch', 'Launch date moved to Friday');

        final atSixty = (await related())!;
        expect([for (final h in atSixty) h.conversationKey],
            ['c-inv', 'c-park'],
            reason: 'the launch sits at 0.5, under the floor');
        final atFortyFive = (await related(floor: 0.45))!;
        expect([for (final h in atFortyFive) h.conversationKey],
            ['c-inv', 'c-park', 'c-launch']);
        final one = (await related(floor: 0.45, limit: 1))!;
        expect([for (final h in one) h.conversationKey], ['c-inv']);
      });

      test('respects sinceIso', () async {
        if (!available) return;
        await message('inv-old', 'c-old', 'Invoice 4470 is overdue',
            age: const Duration(days: 40));
        await message('park', 'c-park', 'Parking permit renewal');

        final hits = (await related())!;
        expect([for (final h in hits) h.conversationKey], ['c-park']);
      });
    });

    group('conversationsFromSenders', () {
      final now = DateTime.now().toUtc();
      String ago(Duration d) => MessageStore.isoStamp(now.subtract(d));

      /// One message [id] in conversation [key], written by [name] at
      /// [address]: a mail by default, a Teams message with [source]
      /// `teams`. With [vector] it is embedded on those axes under the
      /// search's model tag; without it, not embedded at all.
      Future<void> said(
        String id,
        String key, {
        String source = 'email',
        String name = 'Dana Lopez',
        String address = 'dana@fabrikam.com',
        Duration age = const Duration(hours: 2),
        bool outbound = false,
        Map<int, double>? vector,
      }) async {
        await store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': key,
          'direction': outbound ? 'outbound' : 'inbound',
          'subject': 'Thread $key',
          'from_name': name,
          'from_address': address,
          'received_at': ago(age),
          'body_text': 'Message $id.',
        });
        if (vector != null) {
          await store.upsertMessageVector(
            source: source,
            sourceMessageId: id,
            embedding: encodeEmbedding(axes(vector)),
            dims: embedDims,
            embeddedHash: 'h-$id',
            embedModel: EmbeddingsClient.documentModelTag,
          );
        }
      }

      /// Dana by her address and her name; the query on axis 0, so a
      /// message's cosine is its axis-0 component.
      Future<List<RelatedConversation>?> fromSenders({
        bool ranked = true,
        Set<String> addresses = const {'dana@fabrikam.com'},
        Set<String> names = const {'Dana Lopez'},
        Duration window = const Duration(days: 21),
        int limit = 12,
      }) =>
          store.conversationsFromSenders(
            queryEmbedding: ranked ? encodeEmbedding(axes({0: 1.0})) : null,
            embedModel: EmbeddingsClient.documentModelTag,
            addresses: addresses,
            names: names,
            sinceIso: ago(window),
            limit: limit,
          );

      List<String> keysOf(List<RelatedConversation>? hits) =>
          [for (final h in hits!) h.conversationKey];

      test('ranked: one entry per conversation, scored by THEIR nearest '
          'message, nearest first; a Teams chat matched by name is one too',
          () async {
        if (!available) return;
        await said('inv-1', 'c-inv',
            age: const Duration(hours: 5), vector: {0: 1.0});
        // Newer, farther, same conversation: it adds no entry and does not
        // stand for it.
        await said('park-in-inv', 'c-inv',
            age: const Duration(hours: 1), vector: {0: 0.9, 2: 0.4359});
        await said('park', 'c-park',
            age: const Duration(hours: 3), vector: {0: 0.9, 2: 0.4359});
        await said('chat-1', 't-dana',
            source: 'teams',
            address: 'teams:dana-id',
            age: const Duration(hours: 4),
            vector: {0: 0.5, 1: 0.866});

        final hits = (await fromSenders())!;
        expect([for (final h in hits) (h.source, h.conversationKey)], [
          ('email', 'c-inv'),
          ('email', 'c-park'),
          ('teams', 't-dana'),
        ]);
        expect(hits[0].cosine, closeTo(1.0, 0.001));
        expect(hits[1].cosine, closeTo(0.9, 0.001));
        expect(hits[2].cosine, closeTo(0.5, 0.001));
        expect((hits[0].messageId, hits[0].receivedAt),
            ('inv-1', ago(const Duration(hours: 5))));
        expect((hits[2].messageId, hits[2].receivedAt),
            ('chat-1', ago(const Duration(hours: 4))));
      });

      test("ranked: a stranger's message is never found, even as the "
          'nearest in the mailbox; an outbound one never is', () async {
        if (!available) return;
        await said('stranger', 'c-stranger',
            name: 'Sam Ortiz', address: 'sam@contoso.com', vector: {0: 1.0});
        await said('stranger-chat', 't-stranger',
            source: 'teams',
            name: 'Sam Ortiz',
            address: 'teams:sam-id',
            vector: {0: 1.0});
        // Sent under Dana's address, but outbound: not something she wrote.
        await said('sent', 'c-sent', outbound: true, vector: {0: 1.0});
        await said('park', 'c-park', vector: {0: 0.9, 2: 0.4359});

        expect(keysOf(await fromSenders()), ['c-park']);
        expect(keysOf(await fromSenders(ranked: false)), ['c-park']);
      });

      test('a mail is matched by address only, a Teams message by name only',
          () async {
        if (!available) return;
        // Dana's name on another address's mail: not hers.
        await said('namesake', 'c-namesake',
            address: 'other@northwind.com', vector: {0: 1.0});
        // A chat message under an id passed among the addresses, from a
        // name that is not given: not hers either.
        await said('by-id', 't-by-id',
            source: 'teams',
            name: 'D. L.',
            address: 'teams:dana-id',
            vector: {0: 1.0});
        // The controls: her mail by address, her chat message by name.
        await said('mail', 'c-mail', vector: {0: 0.9, 2: 0.4359});
        await said('chat', 't-chat',
            source: 'teams',
            address: 'teams:dana-id',
            vector: {0: 0.5, 1: 0.866});

        for (final ranked in [true, false]) {
          final hits = await fromSenders(
              ranked: ranked,
              addresses: const {'dana@fabrikam.com', 'teams:dana-id'});
          expect(keysOf(hits).toSet(), {'c-mail', 't-chat'},
              reason: 'ranked: $ranked');
        }
      });

      test('ASCII letters match in either case on both sides; a name with a '
          'non-ASCII capital matches itself', () async {
        if (!available) return;
        await said('lower', 'c-lower');
        await said('upper', 'c-upper',
            address: ' Dana@FABRIKAM.com ', age: const Duration(hours: 3));
        await said('chat', 't-dana',
            source: 'teams',
            address: 'teams:dana-id',
            age: const Duration(hours: 4));
        await said('elodie', 't-elodie',
            source: 'teams',
            name: 'Élodie Martin',
            address: 'teams:elodie-id',
            age: const Duration(hours: 5));

        final hits = await fromSenders(
          ranked: false,
          addresses: const {'Dana@Fabrikam.com'},
          names: const {'dana LOPEZ', 'Élodie Martin'},
        );
        expect(keysOf(hits), ['c-lower', 'c-upper', 't-dana', 't-elodie']);
      });

      test('sinceIso is honoured in both modes, and a dropped message is '
          'never found', () async {
        if (!available) return;
        await said('old', 'c-old',
            age: const Duration(days: 30), vector: {0: 1.0});
        await said('gone', 'c-gone', vector: {0: 1.0});
        await store.writeSettledProgress('email', 'gone',
            needsYou: false, reason: 'not_worthy', dropped: true);
        await said('park', 'c-park', vector: {0: 0.9, 2: 0.4359});

        expect(keysOf(await fromSenders()), ['c-park']);
        expect(keysOf(await fromSenders(ranked: false)), ['c-park']);
        // The window is the only thing keeping the old one out.
        expect(keysOf(await fromSenders(window: const Duration(days: 40))),
            ['c-old', 'c-park']);
      });

      test('ranked: a message with no vector is not scored, and a vector '
          'under another tag or width is not scored and fails nothing',
          () async {
        if (!available) return;
        await said('bare', 'c-bare', age: const Duration(hours: 1));
        await said('ghost', 'c-ghost', age: const Duration(hours: 3));
        await store.upsertMessageVector(
          source: 'email',
          sourceMessageId: 'ghost',
          embedding: encodeEmbedding(axes({0: 1.0})),
          dims: embedDims,
          embeddedHash: 'h-ghost',
          embedModel: EmbeddingsClient.modelTag,
        );
        await said('short', 'c-short', age: const Duration(hours: 4));
        await store.upsertMessageVector(
          source: 'email',
          sourceMessageId: 'short',
          embedding: Uint8List(16),
          dims: 4,
          embeddedHash: 'h-short',
          embedModel: EmbeddingsClient.documentModelTag,
        );
        await said('park', 'c-park',
            age: const Duration(hours: 5), vector: {0: 0.9, 2: 0.4359});

        expect(keysOf(await fromSenders()), ['c-park']);
        expect(keysOf(await fromSenders(ranked: false)),
            ['c-bare', 'c-ghost', 'c-short', 'c-park']);
      });

      test('unranked: their newest message stands for each conversation, '
          'newest first, at cosine 0', () async {
        if (!available) return;
        await said('a-old', 'c-a', age: const Duration(hours: 5));
        await said('a-new', 'c-a', age: const Duration(hours: 1));
        await said('b', 'c-b', age: const Duration(hours: 3));
        // Somebody else's newer message in c-b does not stand for it.
        await said('b-sam', 'c-b',
            name: 'Sam Ortiz',
            address: 'sam@contoso.com',
            age: const Duration(minutes: 30));

        final hits = (await fromSenders(ranked: false))!;
        expect(
            [for (final h in hits) (h.conversationKey, h.messageId, h.receivedAt)],
            [
              ('c-a', 'a-new', ago(const Duration(hours: 1))),
              ('c-b', 'b', ago(const Duration(hours: 3))),
            ]);
        expect(hits.every((h) => h.cosine == 0.0), isTrue);
      });

      test('one busy chat is one conversation and cannot crowd the others '
          'out of the limit', () async {
        if (!available) return;
        for (var i = 0; i < 15; i++) {
          await said('busy-$i', 't-busy',
              source: 'teams',
              address: 'teams:dana-id',
              age: Duration(minutes: 10 + i),
              vector: {0: 1.0});
        }
        await said('park', 'c-park',
            age: const Duration(hours: 1), vector: {0: 0.9, 2: 0.4359});
        await said('launch', 'c-launch',
            age: const Duration(hours: 2), vector: {0: 0.5, 1: 0.866});

        expect(keysOf(await fromSenders(limit: 2)), ['t-busy', 'c-park']);
        expect(keysOf(await fromSenders(ranked: false, limit: 2)),
            ['t-busy', 'c-park']);
      });

      test('no addresses and no names: nothing, in both modes', () async {
        if (!available) return;
        await said('park', 'c-park', vector: {0: 0.9, 2: 0.4359});
        for (final ranked in [true, false]) {
          expect(
              await fromSenders(
                  ranked: ranked, addresses: const {}, names: const {' '}),
              isEmpty,
              reason: 'ranked: $ranked');
        }
      });
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
        dims: embedDims,
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
        dims: embedDims,
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

    group('the directories beside the messages', () {
      late ContextStore context;

      setUp(() => context = ContextStore(db));

      /// One file of one registered directory, with one passage embedded on
      /// [text]'s own axis through the same fake server.
      Future<int> file(
        String dirId,
        String relPath, {
        required String text,
        String locator = 'Notes',
      }) async {
        final fileId = await context.upsertFile(
          dirId: dirId,
          relPath: relPath,
          size: text.length,
          mtime: '2026-09-09T09:00:00.000Z',
          sha256: 'sha-$relPath',
          kind: 'doc',
          claudeChain: const [],
          textChars: text.length,
        );
        final ids = await context.replaceChunks(
          fileId,
          [(seq: 0, locator: locator, text: text)],
        );
        final result = await server.client.embedResult(
          text,
          prefix: EmbeddingsClient.documentPrefix,
        );
        await context.setChunkEmbedding(
          ids.single,
          embedding: encodeEmbedding(result.vector!),
          dims: result.vector!.length,
          embedModel: EmbeddingsClient.documentModelTag,
        );
        await context.indexPendingChunks();
        return fileId;
      }

      Future<String> atlas() =>
          context.registerDirectory(path: '/w/atlas', displayName: 'atlas');

      test('a passage of the owner\'s own project is a third list', () async {
        if (!available) return;
        await seedCorpus();
        final dirId = await atlas();
        await file(
          dirId,
          'docs/rates.md',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result = await MessageSearch(store, server.client,
                context: context)
            .search('the escalator clause');

        final directories = (result as MessageSearchHits).directories;
        expect(directories, hasLength(1));
        expect(directories.single.dirName, 'atlas');
        expect(directories.single.relPath, 'docs/rates.md');
        expect(directories.single.locator, 'Notes');
        expect(directories.single.distance, closeTo(0, 0.001));
        expect(directories.single.bm25, isNotNull,
            reason: 'the words found the same passage');
        // No message in this corpus says the word, so the project IS the
        // answer — which is the case the third list exists for.
        expect(result.documents, isEmpty);
      });

      test('a digest passage is never a search hit', () async {
        if (!available) return;
        await seedCorpus();
        final dirId = await atlas();
        // The digest sits ON the query's words, so it is the nearest passage
        // in the project; the file's own words are further off.
        await file(
          dirId,
          'analysis/model.py',
          text: 'the escalator clause',
          locator: 'digest',
        );
        await file(
          dirId,
          'docs/rates.md',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result = await MessageSearch(store, server.client,
                context: context)
            .search('the escalator clause');

        // A search result promises the file's OWN words, the rule the
        // attachment search keeps. A reply is the one place a digest is
        // quoted.
        final directories = (result as MessageSearchHits).directories;
        expect(
          [for (final hit in directories) hit.locator],
          ['Notes'],
        );
      });

      test('a search built with no library answers an empty list', () async {
        if (!available) return;
        await seedCorpus();
        final dirId = await atlas();
        await file(
          dirId,
          'docs/rates.md',
          text: 'Line 14: escalator of three percent each year.',
        );

        // The corpus is indexed and the search was not given a door to it —
        // every caller that predates the third list gets the two it had.
        final result = await MessageSearch(store, server.client)
            .search('the escalator clause');

        expect((result as MessageSearchHits).directories, isEmpty);
      });

      test('an index that throws costs the third list and nothing else',
          () async {
        if (!available) return;
        await seedCorpus();
        // A registered directory, so both broken reads are actually reached.
        final dirId = await atlas();
        await file(
          dirId,
          'docs/rates.md',
          text: 'Line 14: escalator of three percent each year.',
        );

        final result = await MessageSearch(
          store,
          server.client,
          context: _ThrowingContextStore(db),
        ).search('the invoice');

        // A directory index that cannot be read must never make a search of
        // the MAILBOX report itself unavailable.
        expect(idsOf(result), ['inv', 'park', 'launch']);
        expect((result as MessageSearchHits).directories, isEmpty);
        expect(result.notice, isNull);
      });
    });
  });
}

/// A library whose two reads are both broken. The search above it must still
/// answer about the mailbox.
class _ThrowingContextStore extends ContextStore {
  _ThrowingContextStore(super.db);

  @override
  Future<List<ContextChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required List<String> dirIds,
    List<int>? fileIds,
    int k = 12,
    bool excludeDigests = false,
  }) =>
      throw StateError('the index is on fire');

  @override
  Future<List<ContextChunkHit>> keywordChunks(
    FtsQuery query, {
    required List<String> dirIds,
    int limit = SearchTuning.keywordFetch,
    bool excludeDigests = false,
  }) =>
      throw StateError('the word index is on fire');
}
