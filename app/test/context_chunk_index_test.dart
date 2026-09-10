import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// The THIRD vector index, over the owner's own directories, and the two
/// promises that make it different from the two mailbox ones.
///
/// The first is the one it inherits from the attachment index: **a chunk row
/// exists before its vector does.** A file is split the moment it is read and
/// the floats arrive one POST at a time afterwards, so a worklist that did not
/// also ask for `embedding IS NOT NULL` would either file nothing under a
/// rowid or stamp a row that never got filed — and stamping it is the worse
/// one, because the vector then never reaches the index at all. Here that is
/// not a corner case: every reconcile pass re-chunks whatever changed.
///
/// The second is the scope. A registered directory belongs to no message and
/// is reachable only through a LINK the user made, so an empty scope has to
/// answer nothing — a paragraph of one client's notes retrieved into another
/// client's reply is the failure this path must be incapable of.
void main() {
  const tag = EmbeddingsClient.documentModelTag;

  late bool available;
  late BondDatabase db;
  late ContextStore store;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    db = vecTestDb();
    store = ContextStore(db);
  });

  tearDown(() async => db.close());

  /// A registered directory and one file inside it, ready to be chunked.
  Future<({String dirId, int fileId})> seedFile({
    String path = '/Users/pat/projects/atlas',
    String displayName = 'atlas',
    String relPath = 'docs/notes.md',
  }) async {
    final dirId = await store.registerDirectory(
      path: path,
      displayName: displayName,
    );
    final fileId = await store.upsertFile(
      dirId: dirId,
      relPath: relPath,
      size: 2048,
      mtime: '2026-09-04T10:00:00.000Z',
      sha256: 'sha-$relPath',
      kind: 'doc',
      claudeChain: const [],
      textChars: 2048,
    );
    return (dirId: dirId, fileId: fileId);
  }

  /// Writes [texts] as one file's passages and embeds each on [axis].
  Future<List<int>> seedChunks(
    int fileId,
    List<String> texts, {
    required int axis,
  }) async {
    final ids = await store.replaceChunks(fileId, [
      for (var i = 0; i < texts.length; i++)
        (seq: i, locator: 'lines ${i * 60 + 1}–${(i + 1) * 60}', text: texts[i]),
    ]);
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

  Future<bool> indexExists() async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'vec_context_chunks'")
        .get();
    return rows.isNotEmpty;
  }

  Future<int> indexedRows() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM vec_context_chunks')
              .getSingle())
          .data['n'] as int;

  Future<List<Object?>> stamps() async => [
        for (final row in await db
            .customSelect('SELECT indexed_at FROM context_chunks ORDER BY id')
            .get())
          row.data['indexed_at'],
      ];

  group('the lazy table', () {
    test('nothing exists until something asks for it', () async {
      if (!available) return;
      final seed = await seedFile();
      await seedChunks(seed.fileId, const ['The rate card runs to March.'],
          axis: 0);

      // A virtual table created by a migration would fail every pair in
      // drift's `SchemaVerifier` suite, which diffs the whole of
      // `sqlite_master` — so storing passages must not build one.
      expect(await indexExists(), isFalse);

      await store.indexPendingChunks();

      expect(await indexExists(), isTrue);
    });
  });

  group('the backfill', () {
    test('an unembedded passage is not filed and does not wedge the backfill',
        () async {
      if (!available) return;
      final seed = await seedFile();
      final ids = await store.replaceChunks(seed.fileId, const [
        (seq: 0, locator: 'lines 1–60', text: 'The rate card runs to March.'),
        (seq: 1, locator: 'lines 61–120', text: 'Renewals are quoted late.'),
        (seq: 2, locator: 'lines 121–180', text: 'The archive is read-only.'),
      ]);
      // Two have floats. The third is exactly the state a park on the
      // embedding server leaves behind part-way through a directory.
      for (final id in ids.take(2)) {
        await store.setChunkEmbedding(
          id,
          embedding: encodeEmbedding(axes({0: 1.0})),
          dims: 768,
          embedModel: tag,
        );
      }

      // The return is rows ATTEMPTED, and the worklist is the embedded ones.
      expect(await store.indexPendingChunks(), 2);
      expect(await indexedRows(), 2);

      // The third is unstamped, so it is still on the worklist rather than
      // written off — a stamp here would lose its vector forever.
      expect(await stamps(), [isNotNull, isNotNull, isNull]);

      // And the loop is not wedged: the moment the last vector lands, the
      // next pass files it.
      await store.setChunkEmbedding(
        ids.last,
        embedding: encodeEmbedding(axes({1: 1.0})),
        dims: 768,
        embedModel: tag,
      );
      expect(await store.indexPendingChunks(), 1);
      expect(await indexedRows(), 3);
    });

    test('a second pass immediately after files nothing', () async {
      if (!available) return;
      final seed = await seedFile();
      await seedChunks(
        seed.fileId,
        const ['The rate card runs to March.', 'Renewals are quoted late.'],
        axis: 0,
      );

      expect(await store.indexPendingChunks(), 2);
      // The stamp is the whole point of the worklist: a retriever calls this
      // before every read, and a pass that re-filed the corpus each time
      // would make every draft pay for the whole library.
      expect(await store.indexPendingChunks(), 0);
      expect(await indexedRows(), 2);
    });

    test('a passage stored at another width is stamped but not filed',
        () async {
      if (!available) return;
      final seed = await seedFile();
      final ids = await store.replaceChunks(seed.fileId, const [
        (seq: 0, locator: 'lines 1–60', text: 'The rate card runs to March.'),
      ]);
      // Floats from a model of another width — what an embedding slot swapped
      // under a half-indexed library leaves behind.
      await store.setChunkEmbedding(
        ids.single,
        embedding: encodeEmbedding(const [1.0, 0.0, 0.0, 0.0]),
        dims: 4,
        embedModel: tag,
      );

      // Attempted, so it counts; skipped, so nothing reaches the table. The
      // stamp is deliberate — leaving it unstamped would put the bad row at
      // the head of every later page and wedge the loop on it forever.
      expect(await store.indexPendingChunks(), 1);
      expect(await indexedRows(), 0);
      expect(await stamps(), [isNotNull]);
    });
  });

  group('the scoped read', () {
    test('a passage in another directory is not an answer', () async {
      if (!available) return;
      final mine = await seedFile(
        path: '/Users/pat/projects/atlas',
        displayName: 'atlas',
        relPath: 'docs/rates.md',
      );
      final theirs = await seedFile(
        path: '/Users/pat/projects/beacon',
        displayName: 'beacon',
        relPath: 'docs/rates.md',
      );
      // The same words in both, on the same axis, so only the scope can tell
      // the two apart.
      await seedChunks(mine.fileId, const ['The rate card runs to March.'],
          axis: 0);
      await seedChunks(theirs.fileId, const ['The rate card runs to March.'],
          axis: 0);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        dirIds: [mine.dirId],
        k: 5,
      );

      expect(hits!.map((h) => h.dirName), ['atlas']);
      expect(hits.single.relPath, 'docs/rates.md');
      expect(hits.single.distance, closeTo(0, 0.001));
    });

    test('the nearest passage comes first', () async {
      if (!available) return;
      final seed = await seedFile();
      final ids = await store.replaceChunks(seed.fileId, const [
        (seq: 0, locator: 'lines 1–60', text: 'Far from the question.'),
        (seq: 1, locator: 'lines 61–120', text: 'Exactly the question.'),
      ]);
      await store.setChunkEmbedding(
        ids.first,
        embedding: encodeEmbedding(axes({3: 1.0})),
        dims: 768,
        embedModel: tag,
      );
      await store.setChunkEmbedding(
        ids.last,
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: 768,
        embedModel: tag,
      );

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        dirIds: [seed.dirId],
        k: 5,
      );

      // vec0 hands them back in distance order and the store does not
      // re-sort; an answer that put the far passage first would be a caller
      // quoting the wrong paragraph of the right file.
      expect(hits!.map((h) => h.locator), ['lines 61–120', 'lines 1–60']);
      expect(hits.first.distance!, lessThan(hits.last.distance!));
    });

    test('an empty scope is an empty list, never the library', () async {
      if (!available) return;
      final seed = await seedFile();
      await seedChunks(seed.fileId, const ['The rate card runs to March.'],
          axis: 0);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        dirIds: const [],
      );

      // Not null — that sentence is reserved for "the index could not be
      // built" — and not the corpus.
      expect(hits, isEmpty);
      // And the read never happened at all: a caller that could not work out
      // which room it is on must cost nothing, not a lazily built index and a
      // KNN over every project the user owns.
      expect(await indexExists(), isFalse);
    });
  });

  group('re-chunking', () {
    test('the rowids a re-read orphaned are gone after a rebuild', () async {
      if (!available) return;
      final seed = await seedFile();
      await seedChunks(seed.fileId, const ['The rate card runs to March.'],
          axis: 0);
      expect(await store.indexPendingChunks(), 1);
      expect(await indexedRows(), 1);

      // vec0 has no cascade, so emptying a file's passages leaves its rowid
      // filed. The store's answer to that is the hydrating join, which drops
      // an id that matches no row.
      await store.replaceChunks(seed.fileId, const []);

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({0: 1.0})),
        embedModel: tag,
        dirIds: [seed.dirId],
        k: 5,
      );
      expect(hits, isEmpty);
      // Invisible, but still there — and every orphan is a neighbour slot
      // spent on nothing, so a library that re-chunks daily needs the sweep.
      expect(await indexedRows(), 1);

      await store.rebuildIndexes();

      // Rebuilt from `context_chunks`, which now holds none, so the index
      // holds none: back in step with the rows it is derived from.
      expect(await indexedRows(), 0);
    });
  });
}
