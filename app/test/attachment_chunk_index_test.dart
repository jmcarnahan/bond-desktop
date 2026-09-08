import 'package:bond_inbox/data/attachment_chunk_index.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// The second vector index, and the one rule that makes it different from the
/// first: **a chunk row exists before its vector does.**
///
/// The message index writes a row and its embedding in one call, so
/// `indexed_at IS NULL` is a complete worklist. Here the passages are stored
/// the moment a document is split and the floats arrive one POST at a time
/// afterwards, so a worklist that did not also ask for `embedding IS NOT NULL`
/// would either file nothing under a rowid or stamp a row that never got
/// filed — and stamping it is the worse one, because the vector then never
/// reaches the index at all.
void main() {
  const tag = EmbeddingsClient.documentModelTag;

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

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String key = 'conv-1',
    int dropped = 0,
    String direction = 'inbound',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'subject': 'Subject of $id',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-09-04T10:00:00.000Z',
      'body_text': 'See attached.',
      'triage_status': 'triaged',
    });
    if (dropped == 1) {
      await store.writeSettledProgress(
        source,
        id,
        needsYou: false,
        reason: 'not_worthy',
        dropped: true,
      );
    }
  }

  Future<void> seedAttachment(
    String messageId,
    String attachmentId, {
    String source = 'email',
    String name = 'Lease.pdf',
  }) async {
    await store.upsertAttachments(source, messageId, [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': 'file',
        'name': name,
        'content_type': 'application/pdf',
        'size': 4096,
      },
    ]);
  }

  /// Writes [texts] as one attachment's passages and embeds each on [axis].
  Future<List<int>> seedChunks(
    String messageId,
    String attachmentId,
    List<String> texts, {
    required int axis,
    String source = 'email',
  }) async {
    final ids = await store.replaceChunks(
      source,
      messageId,
      attachmentId,
      [
        for (var i = 0; i < texts.length; i++)
          (seq: i, locator: 'part ${i + 1}', text: texts[i]),
      ],
    );
    for (final id in ids) {
      await store.setChunkEmbedding(
        id,
        embedding: encodeEmbedding(axes({axis: 1.0})),
        dims: 768,
        embedModel: tag,
      );
    }
    return ids;
  }

  Future<int> indexedRows() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM vec_attachment_chunks')
              .getSingle())
          .data['n'] as int;

  group('the backfill', () {
    test('an unembedded chunk is not filed and does not wedge the backfill',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      final ids = await store.replaceChunks('email', 'm1', 'a1', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays on the fourth.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);
      // Only the first has floats. The second is exactly the state a park on
      // the embedding server leaves behind.
      await store.setChunkEmbedding(
        ids.first,
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: 768,
        embedModel: tag,
      );

      expect(await store.indexPendingChunks(), 1);
      expect(await indexedRows(), 1);
      // Unstamped, so it is still on the worklist rather than written off.
      final stamps = await db
          .customSelect('SELECT indexed_at FROM attachment_chunks ORDER BY id')
          .get();
      expect(stamps.first.data['indexed_at'], isNotNull);
      expect(stamps.last.data['indexed_at'], isNull);

      // And the loop is not wedged: the moment the vector lands, the second
      // pass files it.
      await store.setChunkEmbedding(
        ids.last,
        embedding: encodeEmbedding(axes({1: 1.0})),
        dims: 768,
        embedModel: tag,
      );
      expect(await store.indexPendingChunks(), 1);
      expect(await indexedRows(), 2);
    });

    test('a re-embedded chunk replaces its row rather than adding one',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      final ids = await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);
      await store.indexPendingChunks();

      // vec0 has no UPSERT, so the writer deletes before it inserts.
      await store.setChunkEmbedding(
        ids.single,
        embedding: encodeEmbedding(axes({5: 1.0})),
        dims: 768,
        embedModel: tag,
      );
      expect(await store.indexPendingChunks(), 1);

      expect(await indexedRows(), 1);
      final hits = await store.chunkKnn(
        encodeEmbedding(axes({5: 1.0})),
        embedModel: tag,
        source: 'email',
        messageIds: const ['m1'],
      );
      expect(hits!.single.distance, closeTo(0, 0.001));
    });

    test('an index built at another width is thrown away and refilled',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);
      // An index somebody else built, at a width nothing in this app writes.
      await db.customStatement(
        'CREATE VIRTUAL TABLE vec_attachment_chunks USING vec0('
        'embedding float[4] distance_metric=cosine)',
      );

      // Searching the wrong width returns errors rather than wrong answers, so
      // the cheap correct move is to drop it — and the durable floats are all
      // still in `attachment_chunks`, so nothing is lost but the index.
      final index = AttachmentChunkIndex(db);
      expect(await index.ensureReady(), isTrue);
      expect(await index.backfill(), 1);
      expect(await indexedRows(), 1);
    });
  });

  group('the scoped read', () {
    test('a passage outside the scope is not an answer', () async {
      if (!available) return;
      await seedMessage('mine', key: 'conv-mine');
      await seedMessage('theirs', key: 'conv-theirs');
      await seedAttachment('mine', 'a1');
      await seedAttachment('theirs', 'b1', name: 'Other.pdf');
      await seedChunks('mine', 'a1', ['The rent is 2,400.'], axis: 0);
      await seedChunks('theirs', 'b1', ['The rent is 2,400.'], axis: 0);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        source: 'email',
        messageIds: const ['mine'],
      );

      // A quote from a stranger's contract pasted into a reply is the one
      // failure this path has to be incapable of.
      expect(hits!.map((h) => h.ref.messageId), ['mine']);
    });

    test('a pinned document is in scope even when its message is not',
        () async {
      if (!available) return;
      await seedMessage('older', key: 'conv-older');
      await seedAttachment('older', 'pinned', name: 'Charter.pdf');
      await seedChunks('older', 'pinned', ['The rent is 2,400.'], axis: 0);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        source: 'email',
        attachmentIds: const ['pinned'],
      );

      expect(hits!.single.ref.attachmentId, 'pinned');
      expect(hits.single.locator, 'part 1');
      expect(hits.single.senderName, 'Dana Whitfield');
      expect(hits.single.outbound, isFalse);
    });

    test('both scopes empty is an empty list, never the corpus', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);
      await store.indexPendingChunks();

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        source: 'email',
      );

      expect(hits, isEmpty);
    });

    test('a vector written under another tag is not comparable', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      final ids = await store.replaceChunks('email', 'm1', 'a1', const [
        (seq: 0, locator: '', text: 'The rent is 2,400.'),
      ]);
      await store.setChunkEmbedding(
        ids.single,
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: 768,
        embedModel: 'some-older-model/document',
      );

      // A distance measured against a vector from another model is not a worse
      // answer, it is a number with no meaning — which would still sort.
      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        source: 'email',
        messageIds: const ['m1'],
      );
      expect(hits, isEmpty);
    });
  });

  group('the corpus-wide read', () {
    test('many passages of one document collapse to its nearest one',
        () async {
      if (!available) return;
      await seedMessage('m1', key: 'conv-1');
      await seedMessage('m2', key: 'conv-2');
      await seedAttachment('m1', 'a1', name: 'Lease.pdf');
      await seedAttachment('m2', 'b1', name: 'Quote.pdf');
      // Ten passages on the query's axis, and one document a little further
      // off. Without the collapse the second document never appears.
      await seedChunks(
        'm1',
        'a1',
        [for (var i = 0; i < 10; i++) 'Clause $i of the lease.'],
        axis: 0,
      );
      final other = await store.replaceChunks('email', 'm2', 'b1', const [
        (seq: 0, locator: '', text: 'The quote is good for thirty days.'),
      ]);
      await store.setChunkEmbedding(
        other.single,
        embedding: encodeEmbedding(axes({0: 0.9, 2: 0.4359})),
        dims: 768,
        embedModel: tag,
      );

      final hits = await store.searchAttachmentChunks(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
      );

      expect(hits!.map((h) => h.ref.attachmentId), ['a1', 'b1']);
      // Bang: the vector pass always reports a distance — it is the word
      // pass that has none.
      expect(hits.first.distance, lessThan(hits.last.distance!));
      expect(hits.first.name, 'Lease.pdf');
    });

    test('a gate-dropped message keeps its documents out of the live search',
        () async {
      if (!available) return;
      await seedMessage('m1', dropped: 1);
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);

      expect(
        await store.searchAttachmentChunks(
          encodeEmbedding(axes({0: 1.0})),
          embedModel: tag,
        ),
        isEmpty,
      );
      // The archive asks for the same rows with the gate lifted.
      expect(
        await store.searchAttachmentChunks(
          encodeEmbedding(axes({0: 1.0})),
          embedModel: tag,
          includeDropped: true,
        ),
        hasLength(1),
      );
    });

    test('asking about no sources is an empty answer, not the mailbox',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);

      expect(
        await store.searchAttachmentChunks(
          encodeEmbedding(axes({0: 1.0})),
          embedModel: tag,
          sources: const [],
        ),
        isEmpty,
      );
    });
  });

  group('a scope inside the neighbour search', () {
    test('a rowid scope keeps the neighbours inside it', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      // Five passages on five axes. The query sits on axis 0, so the nearest
      // is `a1`'s first and the ordering runs away from it.
      final ids = await seedChunks(
        'm1',
        'a1',
        const ['One.', 'Two.', 'Three.', 'Four.', 'Five.'],
        axis: 0,
      );
      for (var i = 0; i < ids.length; i++) {
        await store.setChunkEmbedding(
          ids[i],
          embedding: encodeEmbedding(axes({0: 1.0 - i * 0.2, i + 1: 0.2})),
          dims: 768,
          embedModel: tag,
        );
      }
      await store.indexPendingChunks();

      final index = AttachmentChunkIndex(db);
      // Scoped to the two FURTHEST passages. A corpus-wide k of two would
      // answer the first two and then filter them all away; scoped, the k
      // nearest are the k nearest within the scope.
      final hits = await index.knn(
        encodeEmbedding(axes({0: 1.0})),
        k: 2,
        rowidWhere: 'id IN (?, ?)',
        rowidArgs: [ids[3], ids[4]],
      );

      expect(hits.map((h) => h.id), [ids[3], ids[4]]);
    });

    test('an empty scope subquery answers nothing', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);
      await store.indexPendingChunks();

      final index = AttachmentChunkIndex(db);
      final hits = await index.knn(
        encodeEmbedding(axes({0: 1.0})),
        k: 4,
        rowidWhere: "source = ? AND source_message_id IN ('nobody')",
        rowidArgs: const ['email'],
      );

      expect(hits, isEmpty);
    });
  });

  group('re-chunking', () {
    test('the passages a re-read replaced are dropped from the answers',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', ['The rent is 2,400.'], axis: 0);
      await store.indexPendingChunks();

      // vec0 has no cascade, so the old rowid stays filed. It hydrates to no
      // row in the join and is dropped rather than answered with.
      await store.replaceChunks('email', 'm1', 'a1', const [
        (seq: 0, locator: '', text: 'The rent is 2,600 from January.'),
      ]);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        source: 'email',
        messageIds: const ['m1'],
      );
      expect(hits, isEmpty);
    });
  });
}
