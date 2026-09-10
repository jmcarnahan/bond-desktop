import 'dart:typed_data';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart' show MessageStore;
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/search_fusion.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// The library of registered directories, and the two reads a reply makes
/// against it.
///
/// The promises this file owns, in the order they matter:
///
/// - **Registering is idempotent by PATH.** The id is derived from the path,
///   so picking the same folder twice is the same row — and the second pick
///   must refresh the bookmark and the name without touching the walk, the
///   counts or the switches that passes have already earned.
/// - **A link costs nothing and un-costs nothing.** Register once, link
///   many: unlinking is a row delete and never a re-index.
/// - **An empty scope is answered with nothing, before any read.** A caller
///   that cannot say which room it is on must not be handed the nearest
///   passage in every project the user owns.
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

  Future<int> seedFile(
    String dirId,
    String relPath, {
    String sha = 'sha-1',
    String kind = 'doc',
    List<String> chain = const [],
    int size = 120,
  }) =>
      store.upsertFile(
        dirId: dirId,
        relPath: relPath,
        size: size,
        mtime: '2026-09-09T09:00:00.000Z',
        sha256: sha,
        kind: kind,
        claudeChain: chain,
        textChars: size,
      );

  group('registering', () {
    test('the same path is the same row, twice over', () async {
      final first = await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
      );
      final second = await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'Atlas notes',
      );

      expect(second, first);
      expect(ContextStore.idForPath('/Users/wren/atlas'), first);
      final dirs = await store.directories();
      expect(dirs, hasLength(1));
      // The name IS the second pick's, because renaming is the one thing a
      // re-register legitimately means.
      expect(dirs.single.displayName, 'Atlas notes');
    });

    test('a different path is a different row', () async {
      final atlas = await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
      );
      final ridge = await store.registerDirectory(
        path: '/Users/wren/ridgeline',
        displayName: 'ridgeline',
      );

      expect(ridge, isNot(atlas));
      expect(await store.directories(), hasLength(2));
    });

    test('a re-register keeps the bookmark it is not given', () async {
      final id = await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
        bookmark: Uint8List.fromList([1, 2, 3]),
      );

      // The unsandboxed path hands over null, and null must not erase a grant
      // an earlier sandboxed launch stored — losing it costs the user the
      // open panel again for no reason.
      await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
      );
      expect((await store.directory(id))!.bookmark, [1, 2, 3]);

      await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
        bookmark: Uint8List.fromList([9, 9]),
      );
      expect((await store.directory(id))!.bookmark, [9, 9]);
    });

    test('a re-register keeps everything a pass has earned', () async {
      final id = await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
      );
      await store.setDirectoryOptions(id, digests: false, honorGitignore: true);
      await store.setDirectoryWalked(
        id,
        walkedAt: '2026-09-09T09:00:00.000Z',
        rootHash: 'root-hash',
        filesCount: 42,
        textBytes: 90000,
      );
      await store.setDirectoryBrief(id, briefJson: '{"about":"x"}',
          briefHash: 'bh');

      await store.registerDirectory(
        path: '/Users/wren/atlas',
        displayName: 'atlas',
      );

      final dir = (await store.directory(id))!;
      expect(dir.filesCount, 42);
      expect(dir.textBytes, 90000);
      expect(dir.walkedAt, '2026-09-09T09:00:00.000Z');
      expect(dir.rootHash, 'root-hash');
      expect(dir.briefJson, '{"about":"x"}');
      expect(dir.digests, isFalse);
      expect(dir.honorGitignore, isTrue);
      expect(dir.status, 'ready');
    });

    test('the list is by display name', () async {
      await store.registerDirectory(path: '/a', displayName: 'zephyr');
      await store.registerDirectory(path: '/b', displayName: 'atlas');
      await store.registerDirectory(path: '/c', displayName: 'meridian');

      expect(
        [for (final dir in await store.directories()) dir.displayName],
        ['atlas', 'meridian', 'zephyr'],
      );
    });

    test('status and the error move together', () async {
      final id = await store.registerDirectory(path: '/a', displayName: 'a');

      await store.setDirectoryStatus(id, status: 'unavailable',
          error: 'It could not be opened.');
      expect((await store.directory(id))!.error, 'It could not be opened.');

      // The sentence has to CLEAR when the state does, or the row keeps
      // explaining a failure that is over.
      await store.setDirectoryStatus(id, status: 'reading');
      expect((await store.directory(id))!.error, isNull);
      expect((await store.directory(id))!.status, 'reading');
    });

    test('each switch moves without the other', () async {
      final id = await store.registerDirectory(path: '/a', displayName: 'a');

      await store.setDirectoryOptions(id, digests: false);
      var dir = (await store.directory(id))!;
      expect(dir.digests, isFalse);
      expect(dir.honorGitignore, isFalse);

      await store.setDirectoryOptions(id, honorGitignore: true);
      dir = (await store.directory(id))!;
      expect(dir.digests, isFalse, reason: 'the other switch is untouched');
      expect(dir.honorGitignore, isTrue);
    });

    test('a directory nobody registered reads as null', () async {
      expect(await store.directory('no-such-id'), isNull);
    });
  });

  group('links', () {
    late String atlas;
    late String ridge;

    setUp(() async {
      atlas = await store.registerDirectory(path: '/a', displayName: 'atlas');
      ridge = await store.registerDirectory(path: '/r', displayName: 'ridge');
    });

    test('linking twice is the link', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');

      expect(await store.linkCount(atlas), 1);
      final links = await store.linksFor(atlas);
      expect(links.single.scopeKind, ContextScopeKind.thread);
      expect(links.single.source, 'email');
      expect(links.single.scopeKey, 'conv-1');
    });

    test('the connector is part of the key', () async {
      // Two connectors can hand out the same conversation key, and a link
      // that leaked between them would put one mailbox's project into the
      // other's replies.
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(atlas, ContextScopeKind.thread, 'teams', 'conv-1');

      expect(await store.linkCount(atlas), 2);
      expect(
        await store.dirIdsInScope(source: 'email', conversationKey: 'conv-1'),
        [atlas],
      );
    });

    test('unlinking drops one link and no rows under it', () async {
      final fileId = await seedFile(atlas, 'docs/pricing.md');
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'Q4 rates hold at nine.')],
      );
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');

      await store.unlink(atlas, ContextScopeKind.thread, 'email', 'conv-1');

      expect(await store.linkCount(atlas), 0);
      // The whole reason the index hangs off `dir_id`: mapping and unmapping
      // is instant and costs no re-index.
      expect(await store.filesFor(atlas), hasLength(1));
      expect((await store.chunkCounts(atlas)).chunks, 1);
    });

    test('a thread sees its own links and its storylines', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(ridge, ContextScopeKind.storyline, '', 'story-7');

      final scope = await store.dirIdsInScope(
        source: 'email',
        conversationKey: 'conv-1',
        storylineIds: const ['story-7'],
      );

      expect(scope, unorderedEquals([atlas, ridge]));
    });

    test('a directory linked both ways is named once', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(atlas, ContextScopeKind.storyline, '', 'story-7');

      expect(
        await store.dirIdsInScope(
          source: 'email',
          conversationKey: 'conv-1',
          storylineIds: const ['story-7'],
        ),
        [atlas],
      );
    });

    test('a scope with no key and no storyline is empty', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');

      // Asking about nothing must never be answered with everything.
      expect(
        await store.dirIdsInScope(source: 'email', conversationKey: ''),
        isEmpty,
      );
    });

    test('another thread sees nothing', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');

      expect(
        await store.dirIdsInScope(source: 'email', conversationKey: 'conv-2'),
        isEmpty,
      );
    });

    test('dirIdsLinkedTo answers for exactly one room', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(ridge, ContextScopeKind.storyline, '', 'story-7');

      expect(
        await store.dirIdsLinkedTo(ContextScopeKind.thread, 'email', 'conv-1'),
        [atlas],
      );
      expect(
        await store.dirIdsLinkedTo(ContextScopeKind.storyline, '', 'story-7'),
        [ridge],
      );
    });

    test('unlinkAll keeps every directory', () async {
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      await store.link(ridge, ContextScopeKind.storyline, '', 'story-7');
      final fileId = await seedFile(atlas, 'notes.md');

      // Sign-out: the links point at conversation keys `wipeAll` is about to
      // delete, and the folders are the user's own.
      await store.unlinkAll();

      expect(await store.linkCount(atlas), 0);
      expect(await store.linkCount(ridge), 0);
      expect(await store.directories(), hasLength(2));
      expect(await store.fileById(fileId), isNotNull);
    });
  });

  group('removing a directory', () {
    test('takes its files, words, passages and links with it', () async {
      final atlas = await store.registerDirectory(path: '/a',
          displayName: 'atlas');
      final ridge = await store.registerDirectory(path: '/r',
          displayName: 'ridge');
      final fileId = await seedFile(atlas, 'docs/pricing.md');
      await store.setFileText(fileId, 'Q4 rates hold at nine.');
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'Q4 rates hold at nine.')],
      );
      await store.link(atlas, ContextScopeKind.thread, 'email', 'conv-1');
      final keptFile = await seedFile(ridge, 'docs/other.md');

      await store.removeDirectory(atlas);

      expect(await store.directory(atlas), isNull);
      expect(await store.filesFor(atlas), isEmpty);
      expect(await store.fileText(fileId), isNull);
      expect((await store.chunkCounts(atlas)).chunks, 0);
      expect(await store.linkCount(atlas), 0);
      // The neighbour is untouched, which is the whole reason every delete is
      // scoped by `dir_id` rather than by "everything derived".
      expect(await store.fileById(keptFile), isNotNull);
      expect(await store.directory(ridge), isNotNull);
    });

    test('the queue rows go with it, except one a worker is holding',
        () async {
      final atlas = await store.registerDirectory(path: '/a',
          displayName: 'atlas');
      final ridge = await store.registerDirectory(path: '/r',
          displayName: 'ridge');
      final work = MessageStore(db);
      await work.requeueWork('context_reconcile', 'local', atlas);
      await work.requeueWork('context_brief', 'local', atlas);
      await work.requeueWork('context_digest', 'local', '$atlas|7');
      await work.requeueWork('context_digest', 'local', '$atlas|8');
      await work.requeueWork('context_reconcile', 'local', ridge);
      // The one a drain has already claimed.
      await db.customUpdate(
        "UPDATE work_items SET status = 'processing' WHERE entity_id = ?",
        variables: [Variable('$atlas|8')],
      );

      await store.removeDirectory(atlas);

      // Work naming a directory nobody registered wakes a handler to say
      // `gone`, once per kind and once per file that had a digest owing.
      final rows = await db
          .customSelect('SELECT task_kind, entity_id, status FROM work_items')
          .get();
      // Taking a row out from under a running handler is the one way to
      // make the drain's bookkeeping wrong, and its own `gone` rung is
      // already the right answer for it. The neighbour is untouched.
      expect(
        [for (final row in rows) row.data['entity_id']],
        unorderedEquals(<String>['$atlas|8', ridge]),
      );
      final held = rows.firstWhere(
        (row) => row.data['entity_id'] == '$atlas|8',
      );
      expect(held.data['task_kind'], 'context_digest');
      expect(held.data['status'], 'processing');
    });
  });

  group('files', () {
    late String atlas;

    setUp(() async {
      atlas = await store.registerDirectory(path: '/a', displayName: 'atlas');
    });

    test('an upsert never touches what a model call paid for', () async {
      final id = await seedFile(atlas, 'docs/pricing.md', sha: 'sha-a');
      await store.setFileDigest(id, status: 'done',
          digestJson: '{"purpose":"rates"}');
      await store.setFileDescEmbedding(id, Uint8List.fromList([7, 7, 7, 7]));

      // A pass that re-read the same unchanged bytes must not make the app
      // pay for the digest again — the reset is a separate, visible decision.
      final again = await seedFile(atlas, 'docs/pricing.md', sha: 'sha-b');

      expect(again, id, reason: 'the same (dir, path) is the same row');
      final file = (await store.fileById(id))!;
      expect(file.sha256, 'sha-b');
      expect(file.digestStatus, 'done');
      expect(file.digestJson, '{"purpose":"rates"}');
      expect(file.hasDescEmbedding, isTrue);
    });

    test('resetFileDigest is what a changed file gets', () async {
      final id = await seedFile(atlas, 'docs/pricing.md');
      await store.setFileDigest(id, status: 'done', digestJson: '{"a":1}');

      await store.resetFileDigest(id);

      final file = (await store.fileById(id))!;
      expect(file.digestStatus, 'pending');
      expect(file.digestJson, isNull);
    });

    test('the chain round-trips as a list, root first', () async {
      final id = await seedFile(
        atlas,
        'analysis/pricing/model.py',
        kind: 'code',
        chain: const ['CLAUDE.md', 'analysis/CLAUDE.md'],
      );

      expect((await store.fileById(id))!.claudeChain,
          ['CLAUDE.md', 'analysis/CLAUDE.md']);

      await store.setFileChain(id, const ['CLAUDE.md']);
      expect((await store.fileById(id))!.claudeChain, ['CLAUDE.md']);
    });

    test('filesFor is by path, and fileByPath finds one', () async {
      await seedFile(atlas, 'docs/b.md');
      await seedFile(atlas, 'docs/a.md');
      await seedFile(atlas, 'CLAUDE.md', kind: 'claude_md');

      expect(
        [for (final file in await store.filesFor(atlas)) file.relPath],
        ['CLAUDE.md', 'docs/a.md', 'docs/b.md'],
      );
      expect((await store.fileByPath(atlas, 'docs/a.md'))!.relPath,
          'docs/a.md');
      expect(await store.fileByPath(atlas, 'docs/z.md'), isNull);
    });

    test('filesBySha finds every copy, and never an empty hash', () async {
      await seedFile(atlas, 'a/init.py', sha: 'same', kind: 'code');
      await seedFile(atlas, 'b/init.py', sha: 'same', kind: 'code');
      await seedFile(atlas, 'c/other.py', sha: 'other', kind: 'code');

      expect(await store.filesBySha(atlas, 'same'), hasLength(2));
      // An empty hash is what an unreadable file carries, and matching on it
      // would make every one of them a move of every other.
      expect(await store.filesBySha(atlas, ''), isEmpty);
    });

    test('renaming keeps the id and everything under it', () async {
      final id = await seedFile(atlas, 'docs/old.md');
      await store.setFileText(id, 'Q4 rates hold at nine.');
      await store.replaceChunks(
        id,
        const [(seq: 0, locator: '', text: 'Q4 rates hold at nine.')],
      );

      await store.renameFile(id, 'docs/new.md');

      expect((await store.fileById(id))!.relPath, 'docs/new.md');
      expect(await store.fileText(id), 'Q4 rates hold at nine.');
      expect((await store.chunkCounts(atlas)).chunks, 1);
    });

    test('deleting takes the words and the passages', () async {
      final gone = await seedFile(atlas, 'docs/gone.md');
      final kept = await seedFile(atlas, 'docs/kept.md');
      await store.setFileText(gone, 'anything');
      await store.replaceChunks(
        gone,
        const [(seq: 0, locator: '', text: 'anything')],
      );
      await store.setFileText(kept, 'still here');
      await store.replaceChunks(
        kept,
        const [(seq: 0, locator: '', text: 'still here')],
      );

      await store.deleteFiles([gone]);

      expect(await store.fileById(gone), isNull);
      expect(await store.fileText(gone), isNull);
      expect((await store.chunkCounts(atlas)).chunks, 1);
      expect(await store.fileText(kept), 'still here');
    });

    test('deleting nothing is a no-op with no statement', () async {
      await seedFile(atlas, 'docs/a.md');
      await store.deleteFiles(const []);
      expect(await store.filesFor(atlas), hasLength(1));
    });

    test('text is replaced, and can be cleared', () async {
      final id = await seedFile(atlas, 'docs/a.md');

      await store.setFileText(id, 'first');
      await store.setFileText(id, 'second');
      expect(await store.fileText(id), 'second');

      // A file that stopped being text gets no row at all, rather than a row
      // holding the empty string that a reader would have to special-case.
      await store.clearFileText(id);
      expect(await store.fileText(id), isNull);
    });
  });

  group('the digest worklists', () {
    late String atlas;

    setUp(() async {
      atlas = await store.registerDirectory(path: '/a', displayName: 'atlas');
    });

    test('only files long enough to be worth a call are pending', () async {
      final long = await seedFile(atlas, 'docs/pricing.md',
          sha: 'sha-a', size: 400);
      await seedFile(atlas, 'docs/stub.md', sha: 'sha-b', size: 20);

      final pending = await store.filesPendingDigest(atlas);

      expect([for (final file in pending) file.id], [long]);
    });

    test('a digest that is done or skipped is off the worklist', () async {
      final done = await seedFile(atlas, 'a.md', sha: 'sha-a', size: 400);
      final skipped = await seedFile(atlas, 'b.md', sha: 'sha-b', size: 400);
      final open = await seedFile(atlas, 'c.md', sha: 'sha-c', size: 400);
      await store.setFileDigest(done, status: 'done', digestJson: '{}');
      await store.setFileDigest(skipped, status: 'skipped');

      expect(
        [for (final file in await store.filesPendingDigest(atlas)) file.id],
        [open],
      );
    });

    test('the limit is honoured, freshest edit first', () async {
      for (var i = 0; i < 5; i++) {
        await seedFile(atlas, 'note-$i.md', sha: 'sha-$i', size: 400);
      }
      // The last row written is the most recently updated, so it leads.
      final newest = (await store.fileByPath(atlas, 'note-4.md'))!.id;

      final pending = await store.filesPendingDigest(atlas, limit: 2);

      expect(pending, hasLength(2));
      expect(pending.first.id, newest);
    });

    test('the map reads the rows that actually carry JSON', () async {
      final mapped = await seedFile(atlas, 'a.md', sha: 'sha-a', size: 400);
      await seedFile(atlas, 'b.md', sha: 'sha-b', size: 400);
      await store.setFileDigest(mapped, status: 'done',
          digestJson: '{"purpose":"rates"}');

      expect(
        [for (final file in await store.filesWithDigests(atlas)) file.id],
        [mapped],
      );
    });

    test('the counts pair what is eligible with what is done', () async {
      final done = await seedFile(atlas, 'a.md', sha: 'sha-a', size: 400);
      await seedFile(atlas, 'b.md', sha: 'sha-b', size: 400);
      await seedFile(atlas, 'stub.md', sha: 'sha-c', size: 20);
      await store.setFileDigest(done, status: 'done', digestJson: '{}');

      // The short file is in neither half, so `K of M` counts towards a
      // total it can reach.
      expect(await store.digestCounts(atlas), (eligible: 2, done: 1));
    });

    test('a file nothing will ever digest is in neither half', () async {
      final done = await seedFile(atlas, 'a.md', sha: 'sha-a', size: 400);
      await seedFile(atlas, 'b.md', sha: 'sha-b', size: 400);
      final noWords = await seedFile(atlas, 'empty.md', sha: 'sha-c',
          size: 400);
      final gaveUp = await seedFile(atlas, 'odd.md', sha: 'sha-d', size: 400);
      await store.setFileDigest(done, status: 'done', digestJson: '{}');
      // The handler's two closing verdicts: a row that claimed words the
      // table did not have, and a file the model failed on twice.
      await store.setFileDigest(noWords, status: 'skipped');
      await store.setFileDigest(gaveUp, status: 'error');

      // Nothing is going to work either of them off, and a denominator that
      // counts them is a progress line that stops two short for good.
      expect(await store.digestCounts(atlas), (eligible: 2, done: 1));
    });

    test('a skill with a description and no vector is the embed worklist',
        () async {
      final withDesc = await store.upsertFile(
        dirId: atlas,
        relPath: '.claude/skills/rate-quote/SKILL.md',
        size: 400,
        mtime: '2026-09-09T09:00:00.000Z',
        sha256: 'sha-a',
        kind: 'skill',
        claudeChain: const [],
        description: 'Quote a renewal rate.',
        textChars: 400,
      );
      await store.upsertFile(
        dirId: atlas,
        relPath: '.claude/skills/blank/SKILL.md',
        size: 400,
        mtime: '2026-09-09T09:00:00.000Z',
        sha256: 'sha-b',
        kind: 'skill',
        claudeChain: const [],
        description: '',
        textChars: 400,
      );
      await seedFile(atlas, 'docs/pricing.md', sha: 'sha-c', size: 400);

      expect(
        await store.skillsNeedingDescEmbedding(atlas),
        [(id: withDesc, description: 'Quote a renewal rate.')],
      );

      await store.setFileDescEmbedding(
        withDesc,
        Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(await store.skillsNeedingDescEmbedding(atlas), isEmpty);
    });
  });

  group('passages', () {
    late String atlas;
    late int fileId;

    setUp(() async {
      atlas = await store.registerDirectory(path: '/a', displayName: 'atlas');
      fileId = await seedFile(atlas, 'docs/pricing.md');
    });

    test('replaceChunks numbers them and returns the ids in order', () async {
      final ids = await store.replaceChunks(fileId, const [
        (seq: 0, locator: 'Pricing', text: 'one'),
        (seq: 1, locator: 'Pricing > Q4 rates', text: 'two'),
      ]);

      expect(ids, hasLength(2));
      final counts = await store.chunkCounts(atlas);
      expect(counts.chunks, 2);
      expect(counts.embedded, 0, reason: 'every row is born un-embedded');
    });

    test('replaceChunks replaces rather than appends', () async {
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'old')],
      );
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'new')],
      );

      // Idempotence by construction: the chunker is deterministic, so a retry
      // after a park re-derives exactly this list.
      expect((await store.chunkCounts(atlas)).chunks, 1);
      final pending = await store.unembeddedChunks(fileId);
      expect(pending.single.text, 'new');
    });

    test('appendChunk lands after everything already there', () async {
      await store.replaceChunks(fileId, const [
        (seq: 0, locator: '', text: 'one'),
        (seq: 1, locator: '', text: 'two'),
      ]);

      await store.appendChunk(fileId, locator: 'digest', text: 'the summary');

      final rows = await db
          .customSelect('SELECT seq, locator FROM context_chunks '
              'WHERE file_id = $fileId ORDER BY seq')
          .get();
      expect([for (final row in rows) row.data['seq']], [0, 1, 2]);
      expect(rows.last.data['locator'], 'digest');
    });

    test('an embedded chunk leaves the worklist', () async {
      final ids = await store.replaceChunks(fileId, const [
        (seq: 0, locator: '', text: 'one'),
        (seq: 1, locator: '', text: 'two'),
      ]);

      await store.setChunkEmbedding(
        ids.first,
        embedding: encodeEmbedding(axes({3: 1.0})),
        dims: 768,
        embedModel: tag,
      );

      expect(await store.unembeddedChunks(fileId), hasLength(1));
      expect((await store.chunkCounts(atlas)).embedded, 1);
    });

    test('the directory worklist is every file, oldest first', () async {
      final other = await seedFile(atlas, 'docs/terms.md');
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'one')],
      );
      await store.replaceChunks(
        other,
        const [(seq: 0, locator: '', text: 'two')],
      );

      // The resume worklist: a pass that parked on a dead embedding server
      // left a tail nothing else would ever notice.
      final pending = await store.unembeddedChunksForDir(atlas);
      expect([for (final chunk in pending) chunk.text], ['one', 'two']);
    });

    test('hasChunksInScope is false for an empty list, with no read',
        () async {
      await store.replaceChunks(
        fileId,
        const [(seq: 0, locator: '', text: 'one')],
      );

      expect(await store.hasChunksInScope(const []), isFalse);
      expect(await store.hasChunksInScope([atlas]), isTrue);
      expect(await store.hasChunksInScope(['no-such-dir']), isFalse);
    });
  });

  group('the scoped reads', () {
    late String atlas;
    late String ridge;

    setUp(() async {
      atlas = await store.registerDirectory(path: '/a', displayName: 'atlas');
      ridge = await store.registerDirectory(path: '/r', displayName: 'ridge');
    });

    Future<void> chunk(
      String dirId,
      String relPath,
      String text, {
      required Map<int, double> vector,
      String locator = '',
    }) async {
      final fileId = await seedFile(dirId, relPath, sha: 'sha-$relPath');
      final ids = await store.replaceChunks(
        fileId,
        [(seq: 0, locator: locator, text: text)],
      );
      await store.setChunkEmbedding(
        ids.single,
        embedding: encodeEmbedding(axes(vector)),
        dims: 768,
        embedModel: tag,
      );
    }

    test('an empty scope answers nothing before any read', () async {
      // `const []` and never null: null means "the index is off", which is a
      // different thing a caller reacts to differently.
      expect(
        await store.chunkKnn(
          encodeEmbedding(axes({1: 1.0})),
          embedModel: tag,
          dirIds: const [],
        ),
        isEmpty,
      );
      expect(
        await store.keywordChunks(
          buildFtsQuery('anything')!,
          dirIds: const [],
        ),
        isEmpty,
      );
    });

    test('the nearest passage inside the scope, and never outside it',
        () async {
      // The vec0 index needs the native extension; without it there is no
      // neighbour search to make a claim about.
      if (!available) return;

      await chunk(atlas, 'docs/pricing.md', 'Q4 rates hold at nine.',
          vector: {1: 1.0}, locator: 'Pricing > Q4 rates');
      await chunk(ridge, 'docs/pricing.md', 'Q4 rates hold at nine.',
          vector: {1: 1.0});
      await store.indexPendingChunks();

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({1: 1.0})),
        embedModel: tag,
        dirIds: [atlas],
      );

      // Both directories hold the identical passage. Scoping AFTER the
      // neighbour search would have let the other project's copy take the
      // slot; scoping inside it is what makes this answerable at all.
      expect(hits, hasLength(1));
      expect(hits!.single.dirId, atlas);
      expect(hits.single.dirName, 'atlas');
      expect(hits.single.relPath, 'docs/pricing.md');
      expect(hits.single.locator, 'Pricing > Q4 rates');
      expect(hits.single.distance, isNotNull);
      expect(hits.single.bm25, isNull);
    });

    test('a distance measured under another tag is not an answer', () async {
      // The vec0 index needs the native extension; without it there is no
      // neighbour search to make a claim about.
      if (!available) return;

      await chunk(atlas, 'docs/pricing.md', 'Q4 rates hold at nine.',
          vector: {1: 1.0});
      await db.customStatement(
        "UPDATE context_chunks SET embed_model = 'some-other-model'",
      );
      await store.indexPendingChunks();

      final hits = await store.chunkKnn(
        encodeEmbedding(axes({1: 1.0})),
        embedModel: tag,
        dirIds: [atlas],
      );

      expect(hits, isEmpty);
    });

    test('the words find a passage, with coverage over the terms asked',
        () async {
      await chunk(atlas, 'docs/pricing.md',
          'The renewal quote for Marrowfield is 2,600 a month.',
          vector: {1: 1.0});
      await chunk(atlas, 'docs/terms.md', 'Payment is due on the fourth.',
          vector: {2: 1.0});
      await chunk(ridge, 'docs/pricing.md',
          'The renewal quote for Marrowfield is 2,600 a month.',
          vector: {1: 1.0});

      final hits = await store.keywordChunks(
        buildFtsQuery('renewal quote Marrowfield')!,
        dirIds: [atlas],
      );

      expect(hits, hasLength(1), reason: 'the other project is out of scope');
      expect(hits.single.relPath, 'docs/pricing.md');
      expect(hits.single.bm25, isNotNull);
      expect(hits.single.coverage, 1.0);
      expect(hits.single.distance, isNull);
    });

    test('a passage matching one word of three says so', () async {
      await chunk(atlas, 'docs/terms.md',
          'The renewal is handled by the office.',
          vector: {1: 1.0});

      final hits = await store.keywordChunks(
        buildFtsQuery('renewal quote Marrowfield')!,
        dirIds: [atlas],
      );

      // Coverage is what stops a passage that matched only the number
      // scoring like one that matched the whole question.
      expect(hits.single.coverage, closeTo(1 / 3, 0.001));
    });

    test('the words index searches the path too', () async {
      await chunk(atlas, 'analysis/marrowfield/model.py',
          'def rate(): return 9', vector: {1: 1.0});

      final hits = await store.keywordChunks(
        buildFtsQuery('marrowfield')!,
        dirIds: [atlas],
      );

      expect(hits.single.relPath, 'analysis/marrowfield/model.py');
    });
  });
}
