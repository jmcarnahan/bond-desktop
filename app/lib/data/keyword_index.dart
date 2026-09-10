/// The word indexes — FTS5 tables over the text a person would type at, built
/// lazily, thrown away without ceremony, and never part of the schema.
///
/// Three of them, for the three corpora a search asks about:
/// [MessageKeywordIndex] over `messages`, [ChunkKeywordIndex] over
/// `attachment_chunks`, and [ContextKeywordIndex] over `context_chunks` — the
/// passages of the owner's own registered directories. They are the exact
/// counterpart of `MessageVectorIndex` — same lifecycle, same promises —
/// because they answer the other half of the same question. The vector index
/// knows what a message is ABOUT; these know what it SAYS, which is the only
/// thing that can find a gate-dropped newsletter nobody ever paid an
/// embedding for — or the one file in a project that names a part number.
///
/// Everything here is derived. Losing an index costs one backfill
/// over rows that are already stored and not one model call, which is why
/// nothing is careful about it: a table whose shape has moved is dropped and
/// rebuilt rather than migrated.
///
/// Created LAZILY, at first use, and never by a migration or in `beforeOpen`.
/// That is the same hard rule the vec0 index lives under and for the same
/// reason: drift's `SchemaVerifier` diffs the whole of `sqlite_master` against
/// a snapshot, so a virtual table appearing during a migration step fails
/// every migration pair in the suite. Created here, after the migrations, it
/// is a fact about what this process has done rather than a fact about the
/// schema.
///
/// Everything fails soft. FTS5 is compiled into both SQLite builds this app
/// can link, but "both the ones we checked" is not "every one it will ever
/// meet", so a `CREATE VIRTUAL TABLE` that throws leaves `ensureReady`
/// answering false and every method after it returning empty. A search losing
/// its word pass is a narrower answer; it is never a reason to take a read
/// path down.
library;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'database.dart';

/// One row the words matched: which `rowid` in the underlying table, and how
/// well.
///
/// [bm25] is FTS5's score NEGATED. SQLite's `bm25()` returns a negative
/// number where a better match is more negative — an ordering that is correct
/// and reads backwards everywhere it is used. Flipping the sign once, here at
/// the edge, means every consumer above can hold the ordinary belief that
/// bigger is better.
class KeywordRow {
  final int rowid;
  final double bm25;

  const KeywordRow(this.rowid, this.bm25);

  @override
  String toString() => 'KeywordRow($rowid, $bm25)';
}

/// What both word indexes have in common: the table's lifecycle and the two
/// reads over it.
///
/// Private and shared rather than written twice, because the half that would
/// have been copied is the half that must not drift — an `ensureReady` that
/// memoized on one index and re-probed on the other would be two different
/// failure stories for one feature.
abstract class _FtsIndex {
  final BondDatabase? _db;

  _FtsIndex(this._db, {this.batch = 500});

  /// The virtual table's name. Also its identity: [_prepare] recognises a
  /// table built by an older build by comparing the DDL stored under this name
  /// against [_ddl].
  String get _tableName;

  /// The statement that builds it. Written whole rather than assembled so that
  /// the column-list check in [_prepare] has something honest to compare with.
  String get _ddl;

  /// The `bm25()` weights, one per column of [_ddl] IN ORDER.
  ///
  /// Including the UNINDEXED ones, which is the trap: `bm25()` reads its
  /// weights positionally against every column the table declares, not against
  /// the ones it indexes. A weight list that skipped the unindexed columns
  /// would silently shift every real weight three places left.
  List<double> get _weights;

  Future<bool>? _ready;

  /// True when the table exists on this connection in the shape [_ddl] asks
  /// for.
  ///
  /// Memoized, including the false: a SQLite build without FTS5 will not grow
  /// it, so re-probing every call would be a fixed cost for a fixed answer.
  Future<bool> ensureReady() => _ready ??= _prepare();

  Future<bool> _prepare() async {
    final db = _db;
    if (db == null) return false;
    try {
      final existing = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [Variable<String>(_tableName)],
          )
          .get();
      final sql = existing.isEmpty ? null : existing.single.data['sql'] as String?;
      if (sql == null) {
        await db.customStatement(_ddl);
      } else if (!_matchesShape(sql)) {
        // Built by a build that indexed different columns. An FTS5 table's
        // column list cannot be altered, and searching the wrong one returns
        // errors rather than wrong answers, so the cheap correct move is to
        // throw it away — every word in it came out of a table that is still
        // there.
        debugPrint('fts: $_tableName has a different shape — rebuilding');
        await _recreate();
      }
      return true;
    } catch (e) {
      debugPrint('fts: $_tableName unavailable on this connection: $e');
      return false;
    }
  }

  /// Whether the stored DDL indexes the same columns this build asks for.
  ///
  /// Compared on the column list rather than byte for byte: SQLite stores the
  /// statement as it was typed, so whitespace and the `IF NOT EXISTS` clause
  /// are noise, and a rebuild triggered by reformatting would be a cost paid
  /// for nothing.
  bool _matchesShape(String sql) {
    final stored = _columnList(sql);
    return stored != null && stored == _columnList(_ddl);
  }

  static String? _columnList(String sql) {
    final open = sql.indexOf('(');
    final close = sql.lastIndexOf(')');
    if (open < 0 || close <= open) return null;
    return sql.substring(open + 1, close).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _recreate() async {
    final db = _db!;
    // The shadow tables (`<name>_data`, `_idx`, `_content`, `_docsize`) go
    // with it.
    await db.customStatement('DROP TABLE IF EXISTS $_tableName');
    await db.customStatement(_ddl);
  }

  /// Throws the index away and builds it again from the rows it is derived
  /// from.
  ///
  /// The self-heal, and it costs nothing but a scan: every word it needs is
  /// already in the database. `wipeAll` calls it for a different reason — a
  /// `DELETE FROM messages` does not reach inside a virtual table, so the
  /// previous mailbox's words would otherwise survive a wipe in the shadow
  /// tables.
  Future<void> rebuild() async {
    if (!await ensureReady()) return;
    try {
      await _recreate();
    } catch (e) {
      debugPrint('fts: $_tableName rebuild failed: $e');
    }
  }

  /// How many rows one pass of a backfill holds at a time.
  ///
  /// `MessageVectorIndex.backfill`'s number, and it is the same trade: a page
  /// caps what is live in memory, and a page that fails has still left the
  /// pages before it filed. A test hands in a small one so three rows can
  /// cross a page boundary.
  final int batch;

  /// Files whatever the index has not seen, and returns how many rows it
  /// wrote.
  Future<int> backfill();

  /// The [limit] best rows for [matchExpression], best first.
  ///
  /// [matchExpression] is FTS5 query syntax and is expected to have been BUILT
  /// — `buildFtsQuery` in `services/search_fusion.dart` quotes every term, so
  /// a person typing `retool -test` searches for two words rather than handing
  /// the parser an exclusion. A malformed expression throws inside SQLite and
  /// comes back as `const []`, which is the same answer as "nothing matched"
  /// on purpose: there is nothing a reader could do differently about either.
  ///
  /// [rowidWhere] is a predicate over `rowid` — `rowid IN (SELECT …)` — added
  /// INSIDE the ranked query, with [rowidArgs] bound after the expression and
  /// before the limit. Scoping here rather than after the fact is the
  /// difference between [limit] best rows the caller may read and [limit]
  /// best rows of which it may read none: a corpus where another directory
  /// holds two hundred better matches would otherwise answer nothing.
  Future<List<KeywordRow>> match(
    String matchExpression, {
    required int limit,
    String? rowidWhere,
    List<Object?> rowidArgs = const [],
  }) async {
    if (!await ensureReady()) return const [];
    final weightList = _weights.join(', ');
    final scope = rowidWhere == null ? '' : ' AND $rowidWhere';
    try {
      final rows = await _db!
          .customSelect(
            'SELECT rowid AS row_id, bm25($_tableName, $weightList) AS score '
            'FROM $_tableName WHERE $_tableName MATCH ?$scope '
            'ORDER BY score LIMIT ?',
            variables: [
              Variable<String>(matchExpression),
              for (final arg in rowidArgs) Variable(arg),
              Variable<int>(limit),
            ],
          )
          .get();
      return [
        for (final row in rows)
          KeywordRow(
            row.data['row_id'] as int,
            -((row.data['score'] as num?)?.toDouble() ?? 0),
          ),
      ];
    } catch (e) {
      debugPrint('fts: $_tableName match failed: $e');
      return const [];
    }
  }

  /// Which of [among] the expression matches.
  ///
  /// The coverage read: asked once per term, it is what lets a caller say
  /// "this row matched two of your three words" — the factor that stops a
  /// passage which matched only the number `12` from scoring like one that
  /// matched the whole question.
  ///
  /// Bounded by [among] rather than asked of the whole table, because the only
  /// answer a caller can use is about the page it already has. A common word
  /// in a large mailbox matches tens of thousands of rows, and reading them all
  /// back — once per term, up to eight times a search — would be a corpus-sized
  /// cost paid to look up two hundred rowids.
  Future<Set<int>> rowidsMatching(
    String matchExpression, {
    required List<int> among,
  }) async {
    if (!await ensureReady()) return const {};
    if (among.isEmpty) return const {};
    try {
      final holes = List.filled(among.length, '?').join(', ');
      final rows = await _db!
          .customSelect(
            'SELECT rowid AS row_id FROM $_tableName '
            'WHERE $_tableName MATCH ? AND rowid IN ($holes)',
            variables: [
              Variable<String>(matchExpression),
              for (final id in among) Variable<int>(id),
            ],
          )
          .get();
      return {for (final row in rows) row.data['row_id'] as int};
    } catch (e) {
      debugPrint('fts: $_tableName coverage failed: $e');
      return const {};
    }
  }
}

/// The word index over `messages`, keyed by `messages.rowid`.
///
/// Content-bearing rather than external-content, which is a deliberate trade:
/// external content is the cheaper table, and it needs triggers on `messages`
/// to stay in step — triggers that would have to live in the schema, which is
/// the one place this index is not allowed to be. So it keeps its own copy of
/// four short text columns and re-files them from a watermark instead.
///
/// The watermark is `messages.updated_at`, and it is honest because every
/// writer of a text column stamps it with `_nowIso()`: `upsertMessage`,
/// `updateMessageDetail` and `writeTriage` (which is what makes a summary
/// searchable the moment triage writes one). None of them accepts a stamp from
/// outside, so the column only ever moves forward and a row below the mark is
/// a row already filed — the invariant [backfill] rests on, and the reason it
/// needs no presence check beside the comparison.
///
/// `messages.rowid` is not stable across a `VACUUM`. This app never runs one;
/// if a tool ever does, [rebuild] is the fix.
class MessageKeywordIndex extends _FtsIndex {
  static const String table = 'fts_messages';

  /// The identity columns ride along UNINDEXED so a hit can be turned back
  /// into a message without a join through `rowid` — and `indexed_updated_at`
  /// is the watermark itself, stored where the thing it describes is.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS $table USING fts5('
      'source UNINDEXED, source_message_id UNINDEXED, '
      'indexed_updated_at UNINDEXED, '
      'subject, sender, summary, body, '
      "tokenize='porter unicode61 remove_diacritics 2')";

  MessageKeywordIndex(BondDatabase super.db, {super.batch});

  /// An index that holds nothing and finds nothing — the seam a test uses to
  /// ask what a search says when the words are unavailable.
  ///
  /// Not `const`, for `MessageVectorIndex.disabled`'s reason: the memo above
  /// is a mutable field.
  MessageKeywordIndex.disabled() : super(null);

  @override
  String get _tableName => table;

  @override
  String get _ddl => ddl;

  /// Subject four, sender and summary two, body one. A person searching their
  /// mail is nearly always reaching for a subject line they half remember, and
  /// a body long enough to contain every word once would otherwise out-score
  /// the message actually titled after them.
  ///
  /// Seven numbers for seven columns: the three leading zeroes are the
  /// UNINDEXED identity columns, which can never contribute a term but do
  /// occupy their place in the weight list.
  @override
  List<double> get _weights => const [0, 0, 0, 4.0, 2.0, 2.0, 1.0];

  /// Files every message the watermark has not seen, a page at a time.
  ///
  /// Paged like `MessageVectorIndex.backfill` and for its reason: the FIRST
  /// pass over a mailbox is every message in it, because an empty index has no
  /// mark and `updated_at >= ''` is true of everything — and the bodies being
  /// copied are the largest text this database holds. One page at a time caps
  /// what is live at once, and a pass that dies partway has still made
  /// progress rather than rolling the whole mailbox back to nothing.
  ///
  /// No body text crosses into Dart. The worklist is rowids; the filing is one
  /// `INSERT … SELECT` per page, inside SQLite, where the text already is.
  ///
  /// Paged in WATERMARK order — `(updated_at, rowid)`, keyset style — and not
  /// by rowid alone, because the resume point is `MAX(indexed_updated_at)`.
  /// Pages filed in any other order would leave a pass that stopped early (the
  /// app quit mid-build, a failure on page two) holding a mark ABOVE rows it
  /// never reached, and `>=` below would then exclude them on every later
  /// pass: a mailbox with a permanent hole and nothing to heal it. In this
  /// order every prefix of the work is a valid index, whatever page it ends
  /// on. The cursor carries the rowid beside the stamp because the watermark
  /// row itself is re-filed every pass (see `>=`), so a loop keyed on the
  /// stamp alone would be handed the same page forever.
  ///
  /// [pages] is a test's way of stopping a pass partway; production never
  /// passes it.
  @override
  Future<int> backfill({@visibleForTesting int? pages}) async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var filed = 0;
    try {
      final mark = await db
          .customSelect('SELECT MAX(indexed_updated_at) AS w FROM $_tableName')
          .getSingle();
      // `>=` and not `>`: two messages written in the same microsecond would
      // otherwise leave the second one unfiled forever. Re-filing the
      // watermark row itself costs one delete and one insert on the ordinary
      // search, which is nothing next to being wrong.
      final since = mark.data['w'] as String? ?? '';

      var lastStamp = since;
      var lastRowid = 0;
      var pagesDone = 0;
      while (pages == null || pagesDone < pages) {
        final rows = await db
            .customSelect(
              'SELECT m.rowid AS message_rowid, m.updated_at AS stamp '
              'FROM messages m '
              'WHERE m.updated_at > ? '
              '   OR (m.updated_at = ? AND m.rowid > ?) '
              'ORDER BY m.updated_at, m.rowid LIMIT ?',
              variables: [
                Variable<String>(lastStamp),
                Variable<String>(lastStamp),
                Variable<int>(lastRowid),
                Variable<int>(batch),
              ],
            )
            .get();
        if (rows.isEmpty) break;
        final ids = [for (final row in rows) row.data['message_rowid'] as int];
        lastStamp = rows.last.data['stamp'] as String;
        lastRowid = ids.last;
        pagesDone += 1;
        final holes = List.filled(ids.length, '?').join(', ');

        await db.transaction(() async {
          // FTS5 has no UPSERT, so a re-file is a delete and an insert. The
          // DELETE is a no-op for a rowid that was never filed.
          await db.customStatement(
            'DELETE FROM $_tableName WHERE rowid IN ($holes)',
            ids,
          );
          await db.customStatement(
            'INSERT INTO $_tableName(rowid, source, source_message_id, '
            'indexed_updated_at, subject, sender, summary, body) '
            'SELECT m.rowid, m.source, m.source_message_id, m.updated_at, '
            "COALESCE(m.subject, ''), "
            "COALESCE(m.from_name, '') || ' ' || COALESCE(m.from_address, ''), "
            "COALESCE(m.summary, ''), "
            "COALESCE(NULLIF(m.body_text, ''), m.body_preview, '') "
            'FROM messages m WHERE m.rowid IN ($holes)',
            ids,
          );
        });
        filed += ids.length;
        // A short page is the last page.
        if (ids.length < batch) break;
      }

      // The other direction: a message deleted since the last pass leaves a
      // row here that would hydrate to nothing. The sweep is a scan of both
      // tables, so it is guarded by two counts — outside a wipe, which
      // rebuilds instead, the one thing in this app that deletes a message is
      // the local-echo replacement in `message_store.dart`, so the numbers
      // agree on almost every search and the guard costs a count each.
      final counts = await db
          .customSelect(
            'SELECT (SELECT COUNT(*) FROM $_tableName) AS filed, '
            '(SELECT COUNT(*) FROM messages) AS stored',
          )
          .getSingle();
      if (counts.data['filed'] != counts.data['stored']) {
        await db.customStatement(
          'DELETE FROM $_tableName '
          'WHERE rowid NOT IN (SELECT rowid FROM messages)',
        );
      }
      return filed;
    } catch (e) {
      // What was filed before the failure stays filed, and is reported: a
      // caller that saw progress is looking at an index that made some.
      debugPrint('fts: $_tableName backfill stopped after $filed: $e');
      return filed;
    }
  }
}

class ChunkKeywordIndex extends _FtsIndex {
  static const String table = 'fts_attachment_chunks';

  /// `chars` rides along UNINDEXED as a SIGNATURE column rather than something
  /// anyone searches: summed on both sides it is the third of the three
  /// numbers [backfill] compares before it does any work, and the only one of
  /// them that notices a passage whose text changed under an id it kept.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS $table USING fts5('
      'name, body, chars UNINDEXED, '
      "tokenize='porter unicode61 remove_diacritics 2')";

  ChunkKeywordIndex(BondDatabase super.db);

  ChunkKeywordIndex.disabled() : super(null);

  @override
  String get _tableName => table;

  @override
  String get _ddl => ddl;

  /// The file name counts double. Someone searching for words they remember
  /// seeing in a spreadsheet is usually also half-remembering what it was
  /// called, and a name is a handful of tokens against a passage's hundreds.
  ///
  /// Three numbers for three columns: the trailing zero is `chars`, which is
  /// UNINDEXED and can never contribute a term but does occupy its place in a
  /// weight list `bm25()` reads positionally.
  @override
  List<double> get _weights => const [2.0, 1.0, 0];

  /// Files every passage whose text the index does not already hold.
  ///
  /// By comparing TEXT and not by presence, which is the trap this index lives
  /// with: `replaceChunks` deletes a document's passages and inserts new ones,
  /// and SQLite hands an `INTEGER PRIMARY KEY` the lowest free value, so a
  /// replacement routinely lands on the id its predecessor just vacated.
  ///
  /// The comparison is a LEFT JOIN and a string inequality over every stored
  /// passage, and it runs on every search, so it is fenced behind three cheap
  /// numbers: how many passages there are, the highest id, and the total
  /// character count. All three agreeing is as close to "nothing has changed"
  /// as this table can be asked without reading it.
  ///
  /// The residual that fence accepts: a re-chunk that lands on exactly the
  /// same ids with exactly the same total length and different words is not
  /// noticed until something else about the table moves. It costs a stale
  /// passage in one search result rather than a wrong answer anywhere durable,
  /// and [rebuild] is the fix.
  @override
  Future<int> backfill() async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var filed = 0;
    try {
      final signature = await db.customSelect('''
SELECT (SELECT COUNT(*) FROM attachment_chunks) AS src_n,
       (SELECT COALESCE(MAX(id), 0) FROM attachment_chunks) AS src_mx,
       (SELECT COALESCE(SUM(chars), 0) FROM attachment_chunks) AS src_ch,
       (SELECT COUNT(*) FROM $_tableName) AS ix_n,
       (SELECT COALESCE(MAX(rowid), 0) FROM $_tableName) AS ix_mx,
       (SELECT COALESCE(SUM(chars), 0) FROM $_tableName) AS ix_ch
''').getSingle();
      // Read as numbers on both sides: an FTS5 content column has no affinity,
      // so what comes back out of the index is whatever shape went in.
      int number(String key) => (signature.data[key] as num?)?.toInt() ?? 0;
      if (number('src_n') == number('ix_n') &&
          number('src_mx') == number('ix_mx') &&
          number('src_ch') == number('ix_ch')) {
        return 0;
      }

      var last = 0;
      while (true) {
        final rows = await db
            .customSelect(
              '''
SELECT c.id AS chunk_id
FROM attachment_chunks c
LEFT JOIN attachments a ON a.source = c.source
  AND a.source_message_id = c.source_message_id
  AND a.attachment_id = c.attachment_id
LEFT JOIN $_tableName f ON f.rowid = c.id
WHERE c.id > ?
  AND (f.rowid IS NULL OR f.body <> c.chunk_text
       OR f.name <> COALESCE(a.name, ''))
ORDER BY c.id LIMIT ?
''',
              variables: [
                Variable<int>(last),
                Variable<int>(batch),
              ],
            )
            .get();
        if (rows.isEmpty) break;
        final ids = [for (final row in rows) row.data['chunk_id'] as int];
        last = ids.last;
        final holes = List.filled(ids.length, '?').join(', ');

        await db.transaction(() async {
          // FTS5 has no UPSERT, and the row may be an id-reuse collision
          // rather than a new passage, so the delete is not optional.
          await db.customStatement(
            'DELETE FROM $_tableName WHERE rowid IN ($holes)',
            ids,
          );
          await db.customStatement(
            'INSERT INTO $_tableName(rowid, name, body, chars) '
            "SELECT c.id, COALESCE(a.name, ''), c.chunk_text, c.chars "
            'FROM attachment_chunks c '
            'LEFT JOIN attachments a ON a.source = c.source '
            '  AND a.source_message_id = c.source_message_id '
            '  AND a.attachment_id = c.attachment_id '
            'WHERE c.id IN ($holes)',
            ids,
          );
        });
        filed += ids.length;
        // A short page is the last page.
        if (ids.length < batch) break;
      }

      // `replaceChunks` is a delete and an insert, so a re-chunked document
      // can leave its old passages here — and sweeping them is what stops a
      // search quoting a version of a file that no longer exists. Guarded by
      // the two counts for the message index's reason: the sweep is a scan,
      // and the tables agree on almost every pass.
      final counts = await db
          .customSelect(
            'SELECT (SELECT COUNT(*) FROM $_tableName) AS filed, '
            '(SELECT COUNT(*) FROM attachment_chunks) AS stored',
          )
          .getSingle();
      if (counts.data['filed'] != counts.data['stored']) {
        await db.customStatement(
          'DELETE FROM $_tableName '
          'WHERE rowid NOT IN (SELECT id FROM attachment_chunks)',
        );
      }
      return filed;
    } catch (e) {
      debugPrint('fts: $_tableName backfill stopped after $filed: $e');
      return filed;
    }
  }
}

/// The word index over `context_chunks` — the passages of the owner's own
/// registered directories, keyed by `context_chunks.id`.
///
/// The third corpus, and the one where words matter most. A project holds
/// part numbers, config keys, function names and file paths — exactly the
/// tokens an embedding flattens and a word index finds exactly. The vector
/// half of the same retrieval is [ContextChunkIndex].
class ContextKeywordIndex extends _FtsIndex {
  static const String table = 'fts_context_chunks';

  /// `path` rather than the sibling's `name`, and it is the same bet with a
  /// better hand: a rel path carries the folder as well as the file, so a
  /// query mentioning `pricing` reaches `docs/pricing.md` through its name
  /// and `analysis/pricing/model.py` through its folder.
  ///
  /// `chars` rides along UNINDEXED as a SIGNATURE column rather than
  /// something anyone searches: summed on both sides it is the third of the
  /// three numbers [backfill] compares before it does any work, and the only
  /// one of them that notices a passage whose text changed under an id it
  /// kept — which is every edit to a file that re-chunked to the same count.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS $table USING fts5('
      'path, body, chars UNINDEXED, '
      "tokenize='porter unicode61 remove_diacritics 2')";

  ContextKeywordIndex(BondDatabase super.db);

  ContextKeywordIndex.disabled() : super(null);

  @override
  String get _tableName => table;

  @override
  String get _ddl => ddl;

  /// The path counts double, on [ChunkKeywordIndex]'s reasoning: someone
  /// asking about the pricing analysis is usually also half-remembering where
  /// it lives, and a path is a handful of tokens against a passage's
  /// hundreds.
  ///
  /// Three numbers for three columns: the trailing zero is `chars`, which is
  /// UNINDEXED and can never contribute a term but does occupy its place in a
  /// weight list `bm25()` reads positionally.
  @override
  List<double> get _weights => const [2.0, 1.0, 0];

  /// Files every passage whose text the index does not already hold.
  ///
  /// By comparing TEXT and not by presence, for the trap [ChunkKeywordIndex]
  /// names: `replaceChunks` deletes a file's passages and inserts new ones,
  /// and SQLite hands an `INTEGER PRIMARY KEY` the lowest free value, so a
  /// replacement routinely lands on the id its predecessor just vacated. Here
  /// that is not a corner case but the ordinary path — a reconcile pass
  /// re-chunks every file that changed, on every sync.
  ///
  /// The comparison is a LEFT JOIN and a string inequality over every stored
  /// passage, and it runs on every search, so it is fenced behind three cheap
  /// numbers: how many passages there are, the highest id, and the total
  /// character count. All three agreeing is as close to "nothing has changed"
  /// as this table can be asked without reading it.
  ///
  /// The residual that fence accepts: a re-chunk that lands on exactly the
  /// same ids with exactly the same total length and different words is not
  /// noticed until something else about the table moves. It costs a stale
  /// passage in one search result rather than a wrong answer anywhere
  /// durable, and [rebuild] is the fix.
  @override
  Future<int> backfill() async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var filed = 0;
    try {
      final signature = await db.customSelect('''
SELECT (SELECT COUNT(*) FROM context_chunks) AS src_n,
       (SELECT COALESCE(MAX(id), 0) FROM context_chunks) AS src_mx,
       (SELECT COALESCE(SUM(chars), 0) FROM context_chunks) AS src_ch,
       (SELECT COUNT(*) FROM $_tableName) AS ix_n,
       (SELECT COALESCE(MAX(rowid), 0) FROM $_tableName) AS ix_mx,
       (SELECT COALESCE(SUM(chars), 0) FROM $_tableName) AS ix_ch
''').getSingle();
      // Read as numbers on both sides: an FTS5 content column has no affinity,
      // so what comes back out of the index is whatever shape went in.
      int number(String key) => (signature.data[key] as num?)?.toInt() ?? 0;
      if (number('src_n') == number('ix_n') &&
          number('src_mx') == number('ix_mx') &&
          number('src_ch') == number('ix_ch')) {
        return 0;
      }

      var last = 0;
      while (true) {
        final rows = await db
            .customSelect(
              '''
SELECT c.id AS chunk_id
FROM context_chunks c
LEFT JOIN context_files fi ON fi.id = c.file_id
LEFT JOIN $_tableName f ON f.rowid = c.id
WHERE c.id > ?
  AND (f.rowid IS NULL OR f.body <> c.chunk_text
       OR f.path <> COALESCE(fi.rel_path, ''))
ORDER BY c.id LIMIT ?
''',
              variables: [
                Variable<int>(last),
                Variable<int>(batch),
              ],
            )
            .get();
        if (rows.isEmpty) break;
        final ids = [for (final row in rows) row.data['chunk_id'] as int];
        last = ids.last;
        final holes = List.filled(ids.length, '?').join(', ');

        await db.transaction(() async {
          // FTS5 has no UPSERT, and the row may be an id-reuse collision
          // rather than a new passage, so the delete is not optional.
          await db.customStatement(
            'DELETE FROM $_tableName WHERE rowid IN ($holes)',
            ids,
          );
          await db.customStatement(
            'INSERT INTO $_tableName(rowid, path, body, chars) '
            "SELECT c.id, COALESCE(fi.rel_path, ''), c.chunk_text, c.chars "
            'FROM context_chunks c '
            'LEFT JOIN context_files fi ON fi.id = c.file_id '
            'WHERE c.id IN ($holes)',
            ids,
          );
        });
        filed += ids.length;
        // A short page is the last page.
        if (ids.length < batch) break;
      }

      // A re-chunk and a de-registered directory both delete passages, so a
      // row can outlive what it describes — and sweeping those is what stops
      // a search quoting a version of a file that no longer exists. Guarded
      // by the two counts for the message index's reason: the sweep is a
      // scan, and the tables agree on almost every pass.
      final counts = await db
          .customSelect(
            'SELECT (SELECT COUNT(*) FROM $_tableName) AS filed, '
            '(SELECT COUNT(*) FROM context_chunks) AS stored',
          )
          .getSingle();
      if (counts.data['filed'] != counts.data['stored']) {
        await db.customStatement(
          'DELETE FROM $_tableName '
          'WHERE rowid NOT IN (SELECT id FROM context_chunks)',
        );
      }
      return filed;
    } catch (e) {
      debugPrint('fts: $_tableName backfill stopped after $filed: $e');
      return filed;
    }
  }
}
