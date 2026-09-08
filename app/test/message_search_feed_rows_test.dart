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

/// What a search HANDS BACK, as against how it ranks.
///
/// Two questions that happen to share a door: the row a hit carries is the
/// same row the home feed renders, joins and all, and the connector filter
/// narrows both passes rather than the list afterwards. `message_search_test`
/// owns the geometry; this file owns the shape of the answer.
///
/// Its little embedding server is its own on purpose. The one next door is
/// built to make a ranking arithmetic-free and would be read as this file's
/// fixture the moment it were shared — nothing here cares which vector comes
/// back, only that one does.

/// A server that answers every text with the same 768-wide vector, so every
/// message is exactly as near the query as every other one.
EmbeddingsClient flatServer() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((_) async {
        final vector = List.filled(768, 0.0)..[0] = 1.0;
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

/// A client whose socket never answers, which leaves the text pass alone on
/// the field.
EmbeddingsClient downServer() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient(
        (_) async => throw http.ClientException('connection refused'),
      ),
    );

void main() {
  group('a hit carries the feed row', () {
    late bool available;
    late BondDatabase db;
    late MessageStore store;

    setUpAll(() {
      available = ensureSqliteVecLoaded();
    });

    setUp(() {
      db = vecTestDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    Future<void> seed(String id, String subject) async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': 'conv-$id',
        'direction': 'inbound',
        'subject': subject,
        'from_name': 'Sarah',
        'from_address': 'sarah@x.com',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'body text',
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
      final row = (await store.getMessageRow('email', id))!;
      final outcome = await embedMessageRow(store, flatServer(), 'email', row);
      expect(outcome, MessageEmbedOutcome.embedded);
    }

    test('a hit carries the reasons the feed reads, over the same joins',
        () async {
      if (!available) return;
      await seed('inv', 'Invoice 4471 is overdue');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Acme renewal',
        status: 'active',
        createdBy: 'auto',
      );
      // The thread's membership only — the progress row's own pointer is
      // never stamped here, so this also pins the fallback on the one reader
      // that spells its own FROM.
      await store.addStorylineMember(
        'sl-1',
        'email',
        'conv-inv',
        addedBy: 'auto',
        evidence: 'Same invoice thread',
      );

      final result =
          await MessageSearch(store, flatServer()).search('the invoice');

      final row = (result as MessageSearchHits).hits.first.row;
      expect(row.storylineId, 'sl-1');
      expect(row.storylineTitle, 'Acme renewal');
      expect(row.storylineEvidence, 'Same invoice thread');
      expect(row.storylineAddedBy, 'auto');
      expect(row.updatedAt, isNotEmpty);
      expect(row.workOpen, false);
    });
  });

  group('the connector filter', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    Future<void> seed(String source, String id) => store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': 'conv-$id',
          'direction': 'inbound',
          'subject': 'Invoice 4471 is overdue',
          'received_at': '2026-08-29T10:00:00Z',
        });

    /// The ids the word pass found, with the server down so the ranking pass
    /// contributes nothing and every row on screen came through the filter
    /// under test.
    Future<List<String>> wordIds(List<String>? sources) async {
      final search = MessageSearch(store, downServer());
      final result = sources == null
          ? await search.search('invoice')
          : await search.search('invoice', sources: sources);
      return [
        for (final hit in (result as MessageSearchHits).hits)
          hit.row.sourceMessageId,
      ];
    }

    test('sources narrows the keyword pass', () async {
      await seed('email', 'mail-1');
      await seed('teams', 'chat-1');

      expect(await wordIds(const ['teams']), ['chat-1']);
      expect(await wordIds(const ['email']), ['mail-1']);
      // The default is every connector, which is what makes the facet an
      // opt-in narrowing rather than something a caller has to remember.
      expect(
        (await wordIds(null))..sort(),
        ['chat-1', 'mail-1'],
      );
    });
  });

  group('an index that cannot be read', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = testDb();
      store = _ThrowingIndexStore(db);
    });

    tearDown(() async => db.close());

    test('narrows the search rather than ending it', () async {
      // The index lives in a native extension over its own connection, so a
      // read of it can fail outright rather than answer null. The word pass
      // needs nothing but the database, and it still has the answer.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'mail-1',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'Invoice 4471 is overdue',
        'received_at': '2026-08-29T10:00:00Z',
      });

      final result =
          await MessageSearch(store, flatServer()).search('invoice');

      final hits = result as MessageSearchHits;
      expect(
        [for (final hit in hits.hits) hit.row.sourceMessageId],
        ['mail-1'],
      );
      expect(hits.hits.single.matchedBy, MatchedBy.words);
      expect(hits.notice,
          'Words only — the semantic index could not be read.');
    });
  });
}

/// A store whose nearest-neighbour read fails the way a missing native
/// extension makes it fail: it throws, rather than answering null.
class _ThrowingIndexStore extends MessageStore {
  _ThrowingIndexStore(super.db);

  @override
  Future<List<SemanticHit>?> semanticSearch(
    Uint8List queryEmbedding, {
    required String embedModel,
    int limit = 50,
    bool includeDropped = false,
    String? sinceIso,
    List<String> sources = const ['email', 'teams'],
  }) async =>
      throw StateError('vec0 is not loaded');
}
