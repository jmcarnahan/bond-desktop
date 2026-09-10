import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/keyword_index.dart' show ContextKeywordIndex;
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/context/context_reconcile_handler.dart';
import 'package:bond_inbox/services/context/directory_access.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/search_fusion.dart' show buildFtsQuery;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// An activity log that keeps what a handler told it instead of storing it.
///
/// The status and the notes are most of what this file asserts — "a second
/// pass within a minute costs nothing" is only observable as a `skipped` and
/// a reason, and "a rename cost no embedding" as a count that did not move.
class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};
  String? status;

  @override
  void note(Map<String, Object?> facts) => notes.addAll(facts);

  @override
  void noteStatus(String value) => status = value;
}

/// A store whose passage write fails, standing in for every way the middle
/// of a reconcile can throw — a locked database, a disk that filled, an
/// extractor that met a shape nobody planned for.
class _FailingStore extends ContextStore {
  _FailingStore(super.db);

  @override
  Future<List<int>> replaceChunks(
    int fileId,
    List<({int seq, String locator, String text})> chunks,
  ) async =>
      throw StateError('the passage write failed');
}

void main() {
  late bool available;
  late Directory root;
  late BondDatabase db;
  late ContextStore store;
  late FakeEmbedServer server;
  late _Recorder log;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('bond_ctx_');
    db = vecTestDb();
    store = ContextStore(db);
    server = FakeEmbedServer();
    log = _Recorder();
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String relPath, String contents) {
    final file = File('${root.path}/$relPath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  ContextReconcileHandler handlerWith({
    FakeEmbedServer? embeddings,
    DirectoryAccess access = const PlainDirectoryAccess(),
  }) =>
      ContextReconcileHandler(
        store,
        (embeddings ?? server).client,
        access,
        activityLog: log,
      );

  Future<String> register({String? path}) => store.registerDirectory(
        path: path ?? root.path,
        displayName: 'atlas',
      );

  Future<void> run(String dirId, {bool force = false}) =>
      handlerWith().run({
        'task_kind': 'context_reconcile',
        'source': 'local',
        'entity_id': dirId,
        if (force) 'payload_json': '{"force":true}',
      });

  Future<List<int>> chunkIdsOf(String dirId, String relPath) async {
    final file = await store.fileByPath(dirId, relPath);
    if (file == null) return const [];
    final rows = await db
        .customSelect('SELECT id FROM context_chunks WHERE file_id = ? '
            'ORDER BY seq', variables: [Variable(file.id)])
        .get();
    return [for (final row in rows) row.data['id'] as int];
  }

  group('the first pass', () {
    test('reads the folder, chunks it, embeds it and says ready', () async {
      write('CLAUDE.md', '# Atlas\n\nReplies here stay short.\n');
      write('docs/pricing.md',
          '# Pricing\n\nThe Marrowfield renewal is 2,600 a month.\n');
      write('src/model.py', 'def rate():\n    return 2600\n');
      final id = await register();

      await run(id);

      final dir = (await store.directory(id))!;
      expect(dir.status, 'ready');
      expect(dir.error, isNull);
      expect(dir.filesCount, 3);
      expect(dir.walkedAt, isNotNull);
      expect(dir.rootHash, isNotNull);

      final files = await store.filesFor(id);
      expect([for (final file in files) file.relPath],
          ['CLAUDE.md', 'docs/pricing.md', 'src/model.py']);
      expect(files.first.kind, 'claude_md');
      expect(files.last.kind, 'code');

      final counts = await store.chunkCounts(id);
      expect(counts.chunks, 3);
      expect(counts.embedded, 3, reason: 'one POST per passage');
      expect(server.calls, 3);
      expect(log.notes['changed'], 3);
      expect(log.status, isNull, reason: 'a pass that worked is not skipped');
    });

    test('a file with no words keeps its row and gains no passages',
        () async {
      write('notes.md', 'Something to read.');
      write('art/logo.png', 'not really a png');
      final id = await register();

      await run(id);

      // The row is what the panel lists; the passages are what a reply
      // quotes, and a PNG has none.
      expect(await store.filesFor(id), hasLength(2));
      final image = (await store.fileByPath(id, 'art/logo.png'))!;
      expect(image.textChars, 0);
      expect(await store.fileText(image.id), isNull);
      expect((await store.chunkCounts(id)).chunks, 1);
    });

    test('a file a cap cut is marked truncated on its row', () async {
      write(
        'data/rows.csv',
        ['month,churn', for (var i = 0; i < 60; i++) '2031-$i,4.1'].join('\n'),
      );
      write('notes.md', 'Something to read.');
      final id = await register();

      await run(id);

      // The extractor kept the header and forty rows. A row that said `ok`
      // would let a digest, and then a reply, present that fragment as the
      // whole file.
      expect((await store.fileByPath(id, 'data/rows.csv'))!.status,
          'truncated');
      expect((await store.fileByPath(id, 'notes.md'))!.status, 'ok');
    });

    test('a nested CLAUDE.md gives the files below it a two-entry chain',
        () async {
      write('CLAUDE.md', '# Atlas\n\nHouse rules.\n');
      write('analysis/CLAUDE.md', '# Analysis\n\nCite the notebook.\n');
      write('analysis/pricing/model.py', 'def rate():\n    return 9\n');
      final id = await register();

      await run(id);

      final model = (await store.fileByPath(id, 'analysis/pricing/model.py'))!;
      expect(model.claudeChain, ['CLAUDE.md', 'analysis/CLAUDE.md']);
      // Root first, and a file never governs itself.
      final nested = (await store.fileByPath(id, 'analysis/CLAUDE.md'))!;
      expect(nested.claudeChain, ['CLAUDE.md']);
      final rootNotes = (await store.fileByPath(id, 'CLAUDE.md'))!;
      expect(rootNotes.claudeChain, isEmpty);
    });
  });

  group('the freshness rung', () {
    test('a second pass inside a minute is skipped', () async {
      write('notes.md', 'Something to read.');
      final id = await register();
      await run(id);
      final calls = server.calls;

      log = _Recorder();
      await run(id);

      // The enqueue happens on every sync and a Re-read now lands beside
      // one; without this rung a hurried minute walks the folder three times.
      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'fresh');
      expect(server.calls, calls);
    });

    test('a forced pass walks anyway', () async {
      write('notes.md', 'Something to read.');
      final id = await register();
      await run(id);

      write('notes.md', 'Something else entirely to read about.');
      log = _Recorder();
      await run(id, force: true);

      expect(log.status, isNull);
      expect(log.notes['changed'], 1);
    });

    test('a directory that has never been walked is not fresh', () async {
      write('notes.md', 'Something to read.');
      final id = await register();

      await run(id);

      expect(log.status, isNull);
      expect((await store.directory(id))!.status, 'ready');
    });
  });

  group('the diff', () {
    test('an edit re-chunks only the file that moved', () async {
      write('a.md', '# A\n\nThe first note.\n');
      write('b.md', '# B\n\nThe second note.\n');
      final id = await register();
      await run(id);
      final untouched = await chunkIdsOf(id, 'b.md');
      final callsBefore = server.calls;

      write('a.md', '# A\n\nThe first note, rewritten with new words.\n');
      log = _Recorder();
      await run(id, force: true);

      expect(log.notes['changed'], 1);
      // The other file's passages keep their ids, which is the observable
      // form of "it was not re-read": a re-chunk is a delete and an insert.
      expect(await chunkIdsOf(id, 'b.md'), untouched);
      expect(server.calls, callsBefore + 1, reason: 'one new passage only');
    });

    test('a file whose stat moved but whose bytes did not costs no embed',
        () async {
      write('a.md', '# A\n\nThe first note.\n');
      final id = await register();
      await run(id);
      final callsBefore = server.calls;
      final chunks = await chunkIdsOf(id, 'a.md');

      // A checkout rewrites the file identically. The hash is paid; nothing
      // after it is.
      File('${root.path}/a.md').setLastModifiedSync(
        DateTime.now().add(const Duration(minutes: 5)),
      );
      log = _Recorder();
      await run(id, force: true);

      expect(log.notes['changed'], 0);
      expect(server.calls, callsBefore);
      expect(await chunkIdsOf(id, 'a.md'), chunks);
    });

    test('a rename keeps the passages and pays no embedding', () async {
      write('docs/old.md', '# Pricing\n\nThe renewal is 2,600 a month.\n');
      final id = await register();
      await run(id);
      final before = await chunkIdsOf(id, 'docs/old.md');
      final callsBefore = server.calls;
      expect(before, isNotEmpty);

      File('${root.path}/docs/old.md')
          .renameSync('${root.path}/docs/new.md');
      log = _Recorder();
      await run(id, force: true);

      // The whole payoff of hashing: a project reorganised on a Tuesday
      // costs nothing.
      expect(log.notes['renamed'], 1);
      expect(await store.fileByPath(id, 'docs/old.md'), isNull);
      expect(await chunkIdsOf(id, 'docs/new.md'), before);
      expect(server.calls, callsBefore);
    });

    test('a deleted file loses its row, its words and its passages',
        () async {
      write('a.md', '# A\n\nThe first note.\n');
      write('b.md', '# B\n\nThe second note.\n');
      final id = await register();
      await run(id);
      final gone = (await store.fileByPath(id, 'a.md'))!;

      File('${root.path}/a.md').deleteSync();
      log = _Recorder();
      await run(id, force: true);

      expect(log.notes['removed'], 1);
      expect(await store.fileByPath(id, 'a.md'), isNull);
      expect(await store.fileText(gone.id), isNull);
      expect((await store.chunkCounts(id)).chunks, 1);
    });

    test('a CLAUDE.md appearing re-chains files the pass never read',
        () async {
      write('analysis/model.py', 'def rate():\n    return 9\n');
      final id = await register();
      await run(id);
      expect((await store.fileByPath(id, 'analysis/model.py'))!.claudeChain,
          isEmpty);

      write('CLAUDE.md', '# Atlas\n\nHouse rules.\n');
      log = _Recorder();
      await run(id, force: true);

      // The Python file did not change, so nothing re-read it — and its
      // standing notes moved anyway, which is the point.
      expect(log.notes['changed'], 1, reason: 'only the CLAUDE.md is new');
      expect((await store.fileByPath(id, 'analysis/model.py'))!.claudeChain,
          ['CLAUDE.md']);
      expect(log.notes['rechained'], 1);
    });
  });

  group('the servers', () {
    test('an unavailable embedding server parks and keeps the words',
        () async {
      write('docs/pricing.md',
          '# Pricing\n\nThe Marrowfield renewal is 2,600 a month.\n');
      final id = await register();
      final dead = FakeEmbedServer(status: null);

      await expectLater(
        handlerWith(embeddings: dead).run({
          'task_kind': 'context_reconcile',
          'source': 'local',
          'entity_id': id,
        }),
        throwsA(isA<LlmUnavailableException>()),
      );

      // Everything read this pass survives, and the walk is STAMPED — so the
      // next pass finds nothing changed, skips every read and pays only for
      // the tail.
      final file = (await store.fileByPath(id, 'docs/pricing.md'))!;
      expect(await store.fileText(file.id), contains('Marrowfield'));
      final counts = await store.chunkCounts(id);
      expect(counts.chunks, 1);
      expect(counts.embedded, 0);
      expect((await store.directory(id))!.walkedAt, isNotNull);
    });

    test('the next pass pays only the embedding tail', () async {
      write('docs/pricing.md',
          '# Pricing\n\nThe Marrowfield renewal is 2,600 a month.\n');
      final id = await register();
      final dead = FakeEmbedServer(status: null);
      await handlerWith(embeddings: dead)
          .run({'entity_id': id, 'source': 'local'}).catchError((_) {});

      log = _Recorder();
      await run(id, force: true);

      expect(log.notes['changed'], 0, reason: 'nothing on disk moved');
      expect(log.notes['embedded'], 1);
      expect((await store.chunkCounts(id)).embedded, 1);
    });

    test('a rejected embedding leaves a NULL vector and carries on',
        () async {
      write('a.md', '# A\n\nThe first note.\n');
      write('b.md', '# B\n\nThe second note.\n');
      final id = await register();
      final refusing = FakeEmbedServer(status: 500);

      await handlerWith(embeddings: refusing)
          .run({'entity_id': id, 'source': 'local'});

      // The server read the request and said no, so the next attempt reads
      // the same no. Nothing parks and both files are still indexed.
      expect((await store.directory(id))!.status, 'ready');
      final counts = await store.chunkCounts(id);
      expect(counts.chunks, 2);
      expect(counts.embedded, 0);
    });

    test('a write that throws leaves an error on the row, not reading',
        () async {
      write('docs/pricing.md',
          '# Pricing\n\nThe Marrowfield renewal is 2,600 a month.\n');
      final failing = _FailingStore(db);
      final id = await failing.registerDirectory(
        path: root.path,
        displayName: 'atlas',
      );

      await expectLater(
        ContextReconcileHandler(
          failing,
          server.client,
          const PlainDirectoryAccess(),
          activityLog: log,
        ).run({
          'task_kind': 'context_reconcile',
          'source': 'local',
          'entity_id': id,
        }),
        throwsA(isA<StateError>()),
      );

      // `reading` is written before the walk and only a completed walk
      // clears it, so anything that throws in between would leave the
      // Settings row saying `reading…` for the life of the install — after
      // the worker had spent both attempts and given up. The throw still
      // travels, so the work row records the failure too.
      final dir = (await store.directory(id))!;
      expect(dir.status, 'error');
      expect(dir.error, contains('Reading this folder failed'));
    });
  });

  group('the ladder', () {
    test('a directory nobody registered is skipped as gone', () async {
      await run('no-such-directory');

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'gone');
    });

    test('a path that vanished is unavailable, with a sentence', () async {
      write('notes.md', 'Something to read.');
      final id = await register();
      await run(id);

      root.deleteSync(recursive: true);
      log = _Recorder();
      await run(id, force: true);

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'unavailable');
      final dir = (await store.directory(id))!;
      expect(dir.status, 'unavailable');
      expect(dir.error, contains('could not be opened'));
      // The index is KEPT: the folder may come back, and throwing it away
      // would make a reconnected disk cost a full re-read.
      expect(await store.filesFor(id), hasLength(1));
    });

    test('a bookmark that resolves elsewhere is where the walk reads',
        () async {
      final elsewhere = Directory.systemTemp.createTempSync('bond_ctx_alt_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      File('${elsewhere.path}/moved.md')
          .writeAsStringSync('# Moved\n\nStill here.\n');

      final id = await store.registerDirectory(
        path: '/Users/wren/gone-for-good',
        displayName: 'atlas',
        bookmark: Uint8List.fromList([1, 2, 3]),
      );

      await ContextReconcileHandler(
        store,
        server.client,
        _FixedAccess(elsewhere.path),
        activityLog: log,
      ).run({'entity_id': id, 'source': 'local'});

      // The stored path is stale — the sandbox's whole reason for bookmarks.
      expect((await store.directory(id))!.status, 'ready');
      expect(await store.fileByPath(id, 'moved.md'), isNotNull);
    });
  });

  group('the indexes', () {
    test('a passage is searchable by words and by vector afterwards',
        () async {
      if (!available) return;
      write('docs/pricing.md',
          '# Pricing\n\nThe Marrowfield renewal is 2,600 a month.\n');
      final id = await register();

      await run(id);

      // Both derived indexes are backfilled by the pass itself, so the first
      // reply after a sync does not pay for building them.
      expect(await store.hasChunksInScope([id]), isTrue);
      expect(await store.keywordIndexReady(), isTrue);
      final rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM fts_context_chunks')
          .getSingle();
      expect(rows.data['n'], 1);
      final vec = await db
          .customSelect('SELECT COUNT(*) AS n FROM vec_context_chunks')
          .getSingle();
      expect(vec.data['n'], 1);
    });

    test('a rename re-files the passages under the new path', () async {
      write('docs/escalator.md',
          '# Pricing\n\nThe renewal is 2,600 a month.\n');
      final id = await register();
      await run(id);

      File('${root.path}/docs/escalator.md')
          .renameSync('${root.path}/docs/marrowfield.md');
      await run(id, force: true);

      // A rename keeps the passage rows, so the word index's fence — count,
      // highest id, summed characters — never moves and its own path check
      // is never reached. Without the invalidation the passage stays filed
      // under a path that is not there any more, and the file becomes
      // unfindable by the name it now has.
      final hits = await store.keywordChunks(
        buildFtsQuery('marrowfield')!,
        dirIds: [id],
      );
      expect([for (final hit in hits) hit.relPath], ['docs/marrowfield.md']);

      final rows = await db
          .customSelect('SELECT path FROM ${ContextKeywordIndex.table}')
          .get();
      // The old path is gone from the indexed `path` column. It survives
      // inside `body`, in the passage's own header line written at chunk
      // time, and that is accepted: re-chunking would cost the embeddings a
      // rename exists to save, and the renderer strips that line and cites
      // `rel_path` off the file row.
      expect(
        [for (final row in rows) row.data['path']],
        ['docs/marrowfield.md'],
      );
    });
  });
}

/// A seam that always resolves to one known folder — the sandboxed build's
/// answer, without a Runner.
class _FixedAccess implements DirectoryAccess {
  final String resolvesTo;

  const _FixedAccess(this.resolvesTo);

  @override
  Future<Uint8List?> bookmark(String path) async => null;

  @override
  Future<String?> resolve(Uint8List bookmark) async => resolvesTo;
}
