import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'database.dart';
import 'vec_index.dart' show VecHit;

/// The nearest-neighbour index over `context_chunks` — the passages of the
/// owner's own local directories, searched apart from everything the mailbox
/// carried.
///
/// A THIRD index rather than more rows in `vec_attachment_chunks`, for the
/// reason that table gives for not living in `vec_messages`: what each corpus
/// is FOR. Documents came in on a message and are scoped by the thread that
/// carried them; a registered directory is scoped by a LINK the user made,
/// belongs to no message, and is re-read on every sync. Mixing them would
/// mean every scope predicate had to name a column the other half does not
/// have.
///
/// Derived, disposable, and created lazily at first use, for exactly
/// [AttachmentChunkIndex]'s reasons — read them there. In short: the durable
/// floats are in `context_chunks`, losing this index costs a [rebuild] and no
/// model call, and a virtual table created during a migration would fail
/// every pair in drift's `SchemaVerifier` suite.
class ContextChunkIndex {
  /// The embedding width, fixed by the model on `:8081`. Directory passages
  /// are embedded under the same prefix and the same tag as message cards, so
  /// a second number here would only be a chance to disagree with the
  /// siblings.
  static const int dims = 768;

  /// The vec0 table, cosine because the embeddings are compared by direction
  /// and not by magnitude.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS vec_context_chunks USING vec0('
      'embedding float[$dims] distance_metric=cosine)';

  final BondDatabase? _db;

  ContextChunkIndex(BondDatabase db) : _db = db;

  /// An index that holds nothing and finds nothing.
  ContextChunkIndex.disabled() : _db = null;

  /// One attempt, shared. Concurrent first callers await the same future
  /// rather than racing two `CREATE VIRTUAL TABLE`s down the same connection.
  Future<bool>? _ready;

  /// True when `vec_context_chunks` exists on this connection at this width.
  ///
  /// Memoized, including the false: a connection that was opened before
  /// [ensureSqliteVecLoaded] ran will never grow the extension's functions, so
  /// re-probing it every call would be a fixed cost for a fixed answer.
  Future<bool> ensureReady() => _ready ??= _prepare();

  Future<bool> _prepare() async {
    final db = _db;
    if (db == null) return false;
    if (!ensureSqliteVecLoaded()) {
      debugPrint('vec: native extension unavailable — context index off');
      return false;
    }
    try {
      // The registration above is process-global and reaches only connections
      // opened AFTER it. Probing the LIVE connection is what turns that
      // ordering mistake into a clean "unavailable" instead of a table that
      // exists but cannot be searched.
      await db.customSelect('SELECT vec_version() AS v').getSingle();

      final existing = await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'table' "
              "AND name = 'vec_context_chunks'")
          .get();
      final sql = existing.isEmpty ? null : existing.single.data['sql'] as String?;
      if (sql != null && !sql.contains('float[$dims]')) {
        // Built at another width. A vec0 table cannot be widened in place, and
        // searching the wrong width returns errors rather than wrong answers,
        // so the cheap correct move is to throw it away.
        debugPrint('vec: context index width changed — rebuilding');
        await _recreate();
      } else if (sql == null) {
        await db.customStatement(ddl);
      }
      return true;
    } catch (e) {
      debugPrint('vec: context index unavailable on this connection: $e');
      return false;
    }
  }

  /// Drops and recreates the vec0 table, and marks every stored passage
  /// un-indexed so a later [backfill] refills it.
  ///
  /// Does NOT backfill, and cannot: [_prepare] calls this, and a backfill from
  /// there would await the very `ensureReady` future that is still resolving.
  Future<void> _recreate() async {
    final db = _db!;
    // The shadow tables go with it.
    await db.customStatement('DROP TABLE IF EXISTS vec_context_chunks');
    await db.customStatement(ddl);
    await db.customStatement('UPDATE context_chunks SET indexed_at = NULL');
  }

  /// Files one embedding under [id] — the `context_chunks.id` it came from,
  /// which is also its `rowid` in the index.
  ///
  /// [embedding] must be exactly `dims * 4` bytes of little-endian float32.
  Future<void> upsert({required int id, required Uint8List embedding}) async {
    if (!await ensureReady()) return;
    await _write(id, embedding);
  }

  /// vec0 has no UPSERT and no `INSERT OR REPLACE`, so a re-embed is a delete
  /// followed by an insert. The DELETE is unconditional — it is a no-op for a
  /// rowid that was never indexed.
  ///
  /// Swallows its own failure: one unusable vector must not take down the page
  /// of good ones around it.
  Future<void> _write(int id, Uint8List embedding) async {
    final db = _db!;
    try {
      await db.customStatement(
        'DELETE FROM vec_context_chunks WHERE rowid = ?1',
        [id],
      );
      await db.customInsert(
        'INSERT INTO vec_context_chunks(rowid, embedding) VALUES (?1, ?2)',
        variables: [Variable<int>(id), Variable<Uint8List>(embedding)],
      );
    } catch (e) {
      debugPrint('vec: indexing context chunk $id failed: $e');
    }
  }

  /// How many rowids one `DELETE … IN (…)` names. SQLite's default variable
  /// ceiling is far higher, but a de-registered project can be tens of
  /// thousands of passages and one statement per page is what every other
  /// bulk write in this app does.
  static const int _removeBatch = 500;

  /// Unfiles [rowids] — the `context_chunks.id`s of passages that have just
  /// been deleted from the durable table.
  ///
  /// vec0 has no cascade and no foreign key, so the caller that deletes the
  /// rows is the only thing that can say so. Leaving them filed is not merely
  /// untidy: SQLite hands a freed `INTEGER PRIMARY KEY` back out when the
  /// deleted rows were the highest in the table — which the chunks of the
  /// file a walk just re-read usually are — so the next passage to take that
  /// id is ranked by its predecessor's vector until the embedder reaches it,
  /// and indefinitely while the embedding server is parked. [rebuild] is the
  /// sweep for an index that has already drifted; this is what keeps it from
  /// drifting.
  ///
  /// A no-op when the index is unavailable, and it swallows its own failure
  /// for [_write]'s reason: a deletion that could not be filed must not take
  /// down the write that prompted it.
  Future<void> remove(List<int> rowids) async {
    if (rowids.isEmpty) return;
    if (!await ensureReady()) return;
    final db = _db!;
    try {
      for (var start = 0; start < rowids.length; start += _removeBatch) {
        final end = start + _removeBatch;
        final batch =
            rowids.sublist(start, end < rowids.length ? end : rowids.length);
        await db.customStatement(
          'DELETE FROM vec_context_chunks WHERE rowid IN '
          '(${List.filled(batch.length, '?').join(', ')})',
          batch,
        );
      }
    } catch (e) {
      debugPrint('vec: unfiling ${rowids.length} context chunks failed: $e');
    }
  }

  /// The [k] nearest passages to [query], closest first.
  ///
  /// `AND k = ?` is not a typo for a LIMIT: in sqlite-vec's KNN form `k` is a
  /// constraint the virtual table reads off the WHERE clause to decide how
  /// many neighbours to compute. A LIMIT instead would make it a full scan.
  ///
  /// [rowidWhere] narrows the search to the passages matching a predicate over
  /// `context_chunks` — `file_id IN (SELECT id FROM context_files WHERE
  /// dir_id IN (…))` — with its values in [rowidArgs] after the query and the
  /// k. The scope is applied INSIDE the KNN, and that is the whole point of
  /// it: filtering afterwards gives the k nearest passages in every
  /// registered directory that happen to be linked here, which on a library
  /// of several projects is regularly none of them, while this gives the k
  /// nearest within the scope.
  Future<List<VecHit>> knn(
    Uint8List query, {
    required int k,
    String? rowidWhere,
    List<Object?> rowidArgs = const [],
  }) async {
    if (!await ensureReady()) return const [];
    try {
      final rows = await _db!
          .customSelect(
            'SELECT rowid, distance FROM vec_context_chunks '
            'WHERE embedding MATCH ?1 AND k = ?2'
            '${rowidWhere == null ? '' : ' AND rowid IN '
                '(SELECT id FROM context_chunks WHERE $rowidWhere)'}',
            variables: [
              Variable<Uint8List>(query),
              Variable<int>(k),
              for (final arg in rowidArgs) Variable(arg),
            ],
          )
          .get();
      // vec0 hands them back in distance order; re-sorting would only be a
      // chance to disagree with it.
      return [
        for (final row in rows)
          VecHit(
            row.data['rowid'] as int,
            (row.data['distance'] as num).toDouble(),
          ),
      ];
    } catch (e) {
      debugPrint('vec: context knn failed: $e');
      return const [];
    }
  }

  /// Indexes every embedded passage that has never been indexed, and returns
  /// how many were attempted.
  ///
  /// `embedding IS NOT NULL` is the one line that differs from the message
  /// index, and it is what makes the two-step write safe: a chunk row is
  /// stored the moment the file is split, and its vector arrives one POST
  /// later. An unembedded row must neither be filed (there is nothing to
  /// file) nor stamped (it would then never be filed) — so it is simply not
  /// in the worklist, and the row the embedder just finished is.
  ///
  /// Pages by id so a large project does not load every embedding at once,
  /// and stamps `indexed_at` on every row it touches — including one whose
  /// blob vec0 refused, because leaving a bad row unstamped would put it at
  /// the head of the next page forever and wedge the loop.
  Future<int> backfill({int batch = 500}) async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var indexed = 0;
    try {
      while (true) {
        final rows = await db
            .customSelect(
              'SELECT id, embedding, dims FROM context_chunks '
              'WHERE indexed_at IS NULL AND embedding IS NOT NULL '
              'ORDER BY id LIMIT ?1',
              variables: [Variable<int>(batch)],
            )
            .get();
        if (rows.isEmpty) break;
        await db.transaction(() async {
          for (final row in rows) {
            final id = row.data['id'] as int;
            final width = row.data['dims'] as int;
            if (width == dims) {
              await _write(id, row.data['embedding'] as Uint8List);
            } else {
              debugPrint(
                'vec: context chunk $id is $width-wide, not $dims — skipped',
              );
            }
            await db.customStatement(
              'UPDATE context_chunks SET indexed_at = ?1 WHERE id = ?2',
              [_nowIso(), id],
            );
          }
        });
        indexed += rows.length;
        // A short page is the last page.
        if (rows.length < batch) break;
      }
    } catch (e) {
      debugPrint('vec: context backfill stopped after $indexed: $e');
    }
    return indexed;
  }

  /// Throws the index away and builds it again from `context_chunks`.
  ///
  /// The self-heal, and it costs zero model calls — every float it needs is
  /// already stored. The routine cleanup is [remove], which the store calls
  /// as it deletes passages; this is the sweep for an index that drifted
  /// anyway — a build where the native extension arrived late, or a delete
  /// whose unfiling failed.
  Future<void> rebuild() async {
    if (!await ensureReady()) return;
    try {
      await _recreate();
    } catch (e) {
      debugPrint('vec: context rebuild failed: $e');
      return;
    }
    await backfill();
  }

  /// ISO-8601 UTC text, matching `MessageStore` — every timestamp column in
  /// this database is written and compared as that string.
  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
}
