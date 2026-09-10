// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/keyword_index.dart';
import 'package:bond_inbox/services/search_fusion.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The word index over the owner's own directories: when it comes into
/// existence, what keeps it in step with the passages it is derived from, and
/// what it costs to ask.
///
/// Nothing here is about ranking — the fusion owns that. This file owns the
/// promise that the index is never a fact about the schema, never stale in a
/// way a sync would not notice, and never answers about a directory the room
/// asking has no link to.
///
/// The one thing this index has that its two siblings do not is a corpus that
/// is re-derived on every sync: a reconcile pass deletes and re-inserts a
/// changed file's passages, and SQLite hands an `INTEGER PRIMARY KEY` the
/// lowest free value, so new words routinely land on the id the old words
/// just vacated. Several tests below are about exactly that.
void main() {
  late BondDatabase db;
  late ContextStore store;

  setUp(() {
    db = testDb();
    store = ContextStore(db);
  });

  tearDown(() async => db.close());

  Future<bool> tableExists(String name) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$name'",
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<int> rowCount(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .data['n'] as int;

  /// A registered directory and one file inside it.
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
      sha256: 'sha-$path-$relPath',
      kind: 'doc',
      claudeChain: const [],
      textChars: 2048,
    );
    return (dirId: dirId, fileId: fileId);
  }

  Future<List<int>> chunk(int fileId, List<String> passages) =>
      store.replaceChunks(fileId, [
        for (final (index, text) in passages.indexed)
          (seq: index, locator: 'lines ${index * 60 + 1}', text: text),
      ]);

  /// What a search for [text] finds inside [dirIds], as passage text.
  Future<List<String>> find(String text, List<String> dirIds) async {
    final query = buildFtsQuery(text)!;
    return [
      for (final hit in await store.keywordChunks(query, dirIds: dirIds))
        hit.text,
    ];
  }

  test('the table does not exist until something searches', () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const ['The escalator clause bites in March.']);

    // A migration that created it would fail every pair in the schema suite:
    // drift's verifier diffs the whole of `sqlite_master`.
    expect(await tableExists(ContextKeywordIndex.table), isFalse);

    expect(await find('escalator', [seed.dirId]), hasLength(1));

    expect(await tableExists(ContextKeywordIndex.table), isTrue);
  });

  test('every stored passage is filed once, and a second pass costs nothing',
      () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const [
      'The escalator clause bites in March.',
      'Renewals are quoted a fortnight late.',
      'The archive is read-only after signing.',
    ]);

    expect(await store.ensureKeywordIndex(), 3);
    expect(await rowCount(ContextKeywordIndex.table), 3);

    // The three-number fence — count, highest id, total characters — is what
    // keeps this off the critical path: every retrieval calls it, and a pass
    // that re-scanned the library each time would make every draft pay for
    // the whole of it.
    expect(await store.ensureKeywordIndex(), 0);
  });

  test('a passage rewritten under the id it kept is noticed', () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const ['The escalator clause bites in March.']);
    expect(await find('escalator', [seed.dirId]), hasLength(1));

    // A re-chunk is a delete and an insert, so the replacement lands on the
    // id its predecessor just vacated — presence alone would see nothing. The
    // replacement text is deliberately a DIFFERENT LENGTH, because the fence
    // compares count, highest id and SUM(chars), and only the third of those
    // can move when a file re-chunks to the same number of passages.
    await chunk(seed.fileId, const ['A flat rent for the whole of the term.']);

    expect(await find('escalator', [seed.dirId]), isEmpty);
    expect(await find('flat rent', [seed.dirId]), hasLength(1));
    expect(await rowCount(ContextKeywordIndex.table), 1);
  });

  test('the path is searchable, not only the words inside the file', () async {
    final seed = await seedFile(relPath: 'analysis/pricing/model.py');
    await chunk(seed.fileId, const ['def compute(rows): return rows * 1.03']);

    // A rel path carries the folder as well as the file name, and someone
    // asking about the pricing model is usually half-remembering where it
    // lives rather than what it says.
    expect(await find('pricing', [seed.dirId]), hasLength(1));
    expect(await find('model', [seed.dirId]), hasLength(1));
  });

  test('a file whose passages are gone leaves no ghost behind', () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const ['The escalator clause bites in March.']);
    expect(await find('escalator', [seed.dirId]), hasLength(1));

    // FTS5 has no foreign key, so deleting the file's rows cannot reach
    // inside the index — the orphan sweep at the end of the backfill is the
    // only thing that stops a search quoting a file that no longer exists.
    await store.deleteFiles([seed.fileId]);

    expect(await find('escalator', [seed.dirId]), isEmpty);
    expect(await rowCount(ContextKeywordIndex.table), 0);
  });

  test('a rebuild refills the table from the passages themselves', () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const ['The escalator clause bites in March.']);
    expect(await store.ensureKeywordIndex(), 1);
    final chars = (await db
            .customSelect('SELECT chars FROM context_chunks')
            .getSingle())
        .data['chars'] as int;

    // The residual the fence accepts, made by hand: a row whose words moved
    // while all three signature numbers stayed put. Nothing short of a
    // rebuild can see it.
    await db.customStatement(
      'DELETE FROM ${ContextKeywordIndex.table} WHERE rowid = 1',
    );
    await db.customStatement(
      'INSERT INTO ${ContextKeywordIndex.table}(rowid, path, body, chars) '
      "VALUES (1, 'docs/notes.md', 'ghostwritten nonsense', ?)",
      [chars],
    );
    expect(await find('ghostwritten', [seed.dirId]), hasLength(1));
    expect(await find('escalator', [seed.dirId]), isEmpty);

    // Reached the way the app reaches it. The vector half of the same call
    // has no sqlite-vec on a plain `testDb` and says so; the word half must
    // rebuild anyway, because one missing extension is not a reason to leave
    // a search reading stale text.
    await store.rebuildIndexes();

    // Dropped and refilled from `context_chunks`, which cost a scan and not
    // one model call — the reason nothing about this index is careful.
    expect(await find('escalator', [seed.dirId]), hasLength(1));
    expect(await find('ghostwritten', [seed.dirId]), isEmpty);
    expect(await rowCount(ContextKeywordIndex.table), 1);
  });

  test('an index built without a database finds nothing and builds nothing',
      () async {
    final seed = await seedFile();
    await chunk(seed.fileId, const ['The escalator clause bites in March.']);

    final disabled = ContextKeywordIndex.disabled();

    // The seam a caller uses to ask what a retrieval says when the words are
    // unavailable: a narrower answer, never a thrown error and never a table.
    expect(await disabled.ensureReady(), isFalse);
    expect(await disabled.backfill(), 0);
    expect(await disabled.match('escalator', limit: 10), isEmpty);
    expect(await tableExists(ContextKeywordIndex.table), isFalse);
  });

  test('a passage in another directory is not an answer', () async {
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
    // The same words in both, so only the scope can tell the two apart.
    await chunk(mine.fileId, const ['The escalator clause bites in March.']);
    await chunk(theirs.fileId, const ['The escalator clause bites in March.']);

    final query = buildFtsQuery('escalator')!;
    final hits = await store.keywordChunks(query, dirIds: [mine.dirId]);

    // A sentence from one client's project quoted into another client's
    // reply is the one failure this path has to be incapable of.
    expect(hits.map((h) => h.dirName), ['atlas']);
    // And asking about no directory at all answers nothing rather than the
    // whole library.
    expect(await store.keywordChunks(query, dirIds: const []), isEmpty);
  });

  test('a larger project cannot crowd the scoped one out of the page',
      () async {
    final mine = await seedFile(relPath: 'docs/rates.md');
    final theirs = await seedFile(
      path: '/Users/pat/projects/beacon',
      displayName: 'beacon',
      relPath: 'docs/rates.md',
    );
    // The in-scope passage is long, so bm25 ranks it BELOW every short one:
    // this is the ordinary shape of the failure, not a contrived one. A
    // person's own long analysis loses on length to a hundred one-line notes
    // in a project they did not ask about.
    await chunk(mine.fileId, [
      'The escalator clause bites in March. '
          '${List.filled(300, 'renewal terms and conditions apply.').join(' ')}',
    ]);
    // More matching passages than one page holds, all of them out of scope.
    await chunk(theirs.fileId, [
      for (var i = 0; i < SearchTuning.keywordFetch + 50; i++) 'Escalator.',
    ]);

    final hits = await store.keywordChunks(
      buildFtsQuery('escalator')!,
      dirIds: [mine.dirId],
    );

    // Scoping after the page rather than inside the query would rank the
    // library, take the best two hundred, and then discard every one of them
    // — a room whose own directory is small would simply stop answering as
    // the library grew.
    expect(hits.map((h) => h.dirName), ['atlas']);
  });
}
