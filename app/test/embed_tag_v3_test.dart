import 'dart:typed_data';

import 'package:bond_inbox/data/attachment_chunk_index.dart';
import 'package:bond_inbox/data/context_chunk_index.dart';
import 'package:bond_inbox/data/conversation_vec_index.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/vec_index.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart'
    show EmbeddingsClient;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/vec_test_db.dart';

/// What a MODEL swap has to be true of, on 2026-09-19 and on the next one.
///
/// Round E Phase 2 moved the whole embedding server from embeddinggemma-300M
/// to Qwen3-Embedding-0.6B. That is two geometry changes at once — a different
/// space AND a different width — and neither of them throws. A vector under an
/// old tag is not an error: it is 768 floats that would answer a cosine
/// question with a plausible number if anything ever compared them, and a
/// `float[768]` vec0 table is a table that silently holds nothing this build
/// can search. Two mechanisms are all that stand between the swap and quietly
/// wrong storylines, and this file is both of them said out loud:
///
/// 1. **The tag.** Every clustering read filters on
///    `EmbeddingsClient.modelTag`, so a row under an older tag is invisible
///    rather than comparable, and `conversationKeysWithEmbedModel` is the one
///    read that can still SEE those rows — because the one-shot re-embed in
///    `sync_service.dart` has to find them to retire them.
/// 2. **The width.** All four vec0 indexes declare `float[dims]`, check the
///    stored declaration on first use, and throw the table away when it
///    disagrees. Losing one costs a rebuild and not a single model call, which
///    is what makes "drop it" the cheap correct move rather than a data loss.
///
/// The one-shot's own behaviour — the slice, the cap, the pref, the order the
/// two retired tags drain in — is pinned in `sync_state_test.dart`, where the
/// sync harness lives. The prefixes and the tag strings themselves are pinned
/// in `embeddings_prefix_test.dart`.
void main() {
  group('the retired tags are invisible to the clustering pool', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = vecTestDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    /// One kept-inbound conversation carrying a vector under [tag].
    Future<void> seed(String key, String tag) async {
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': key,
        'subject': key,
        'state': 'waiting',
        'last_message_at': '2026-09-18T10:00:00Z',
      });
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'kept-$key',
        'conversation_key': key,
        'direction': 'inbound',
        'subject': key,
        'from_name': 'Sarah',
        'from_address': 'sarah@example.com',
        'received_at': '2026-09-18T10:00:00Z',
        'body_text': 'body of $key',
        'triage_status': 'triaged',
      });
      await store.upsertConversationAi(
        'email',
        key,
        embedding: Uint8List.fromList(const [0, 0, 0, 0]),
        embeddedHash: 'h-$key',
        embedModel: tag,
      );
    }

    Future<List<String>> pool(String tag) async => [
          for (final row in await store.conversationsWithEmbeddings(
            embedModel: tag,
          ))
            row['conversation_key'] as String,
        ];

    test('the sweep pool holds the current tag and neither older one',
        () async {
      await seed('v1', EmbeddingsClient.retiredModelTagV1);
      await seed('v2', EmbeddingsClient.retiredModelTag);
      await seed('v3', EmbeddingsClient.modelTag);

      // The whole safety property of a tag bump. Nothing was deleted and
      // nothing threw; the two older rows simply stopped being part of the
      // question.
      expect(await pool(EmbeddingsClient.modelTag), ['v3']);
    });

    test('the one-shot can still see what the pool cannot', () async {
      await seed('v1', EmbeddingsClient.retiredModelTagV1);
      await seed('v2', EmbeddingsClient.retiredModelTag);
      await seed('v3', EmbeddingsClient.modelTag);

      // `conversationKeysWithEmbedModel` is the deliberate exception: a row
      // invisible to every read would also be invisible to the pass that
      // retires it, and the corpus would never refill.
      expect(
        [
          for (final t in await store.conversationKeysWithEmbedModel(
            EmbeddingsClient.retiredModelTagV1,
            cap: 50,
          ))
            t.key,
        ],
        ['v1'],
      );
      expect(
        [
          for (final t in await store.conversationKeysWithEmbedModel(
            EmbeddingsClient.retiredModelTag,
            cap: 50,
          ))
            t.key,
        ],
        ['v2'],
      );
    });

    test('the three tags are three different strings', () {
      // Cheap, and the thing a copy-paste bump gets wrong: two tags spelled
      // the same would make the one-shot requeue every thread in the mailbox
      // forever, since the pass would write back the tag it just read.
      expect(
        {
          EmbeddingsClient.modelTag,
          EmbeddingsClient.retiredModelTag,
          EmbeddingsClient.retiredModelTagV1,
        },
        hasLength(3),
      );
    });
  });

  group('every vec0 index rebuilds when the model width moves', () {
    late BondDatabase db;

    setUp(() => db = vecTestDb());
    tearDown(() async => db.close());

    /// The stored declaration of [table], or null when there is none.
    Future<String?> declaration(String table) async {
      final rows = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [Variable<String>(table)],
          )
          .get();
      return rows.isEmpty ? null : rows.single.data['sql'] as String?;
    }

    /// True when this process has sqlite-vec. Every case below is a no-op
    /// without it, on `vec_index_test.dart`'s rule: the native asset is not
    /// present on every machine the suite runs on, and a skipped geometry
    /// check must not read as a failing one. Asked of the connection rather
    /// than of an index, because an index would CREATE the table this group
    /// needs to declare by hand.
    Future<bool> vecAvailable() async {
      try {
        await db.customSelect('SELECT vec_version() AS v').getSingle();
        return true;
      } catch (_) {
        return false;
      }
    }

    /// Declares [table] at four floats — what an older build, or a hand-rolled
    /// table, leaves behind — then asserts [ensureReady] threw it away and
    /// rebuilt it at the model width.
    Future<void> rebuildsFromFour(
      String table,
      Future<bool> Function() ensureReady,
      int dims,
    ) async {
      await db.customStatement(
        'CREATE VIRTUAL TABLE $table USING vec0('
        'embedding float[4] distance_metric=cosine)',
      );
      expect(await declaration(table), contains('float[4]'));

      expect(await ensureReady(), isTrue);

      expect(await declaration(table), contains('float[$dims]'));
    }

    test('the message index', () async {
      if (!await vecAvailable()) return;
      final index = MessageVectorIndex(db);
      await rebuildsFromFour(
        'vec_messages',
        index.ensureReady,
        MessageVectorIndex.dims,
      );
    });

    test('the clustering index', () async {
      if (!await vecAvailable()) return;
      final index = ConversationVectorIndex(db);
      await rebuildsFromFour(
        'vec_conversations',
        index.ensureReady,
        ConversationVectorIndex.dims,
      );
    });

    test('the attachment chunk index', () async {
      if (!await vecAvailable()) return;
      final index = AttachmentChunkIndex(db);
      await rebuildsFromFour(
        'vec_attachment_chunks',
        index.ensureReady,
        AttachmentChunkIndex.dims,
      );
    });

    test('the context chunk index', () async {
      if (!await vecAvailable()) return;
      final index = ContextChunkIndex(db);
      await rebuildsFromFour(
        'vec_context_chunks',
        index.ensureReady,
        ContextChunkIndex.dims,
      );
    });

    test('all four agree about the width, because one model serves them all',
        () {
      // One embedding server, one `n_embd`. Four constants rather than one
      // because the corpora are free to diverge, and this is the test that
      // says the day they do was a decision. Written as four assertions and
      // not as a set: the analyzer folds four equal consts into one element
      // and calls the literal a mistake.
      expect(MessageVectorIndex.dims, 1024);
      expect(ConversationVectorIndex.dims, MessageVectorIndex.dims);
      expect(AttachmentChunkIndex.dims, MessageVectorIndex.dims);
      expect(ContextChunkIndex.dims, MessageVectorIndex.dims);
    });
  });
}
