import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'database.dart';
import 'vec_index.dart' show VecHit;

/// The nearest-neighbour index over `attachment_chunks` — the passages of
/// documents, searched apart from the messages that carried them.
///
/// A SECOND index rather than more rows in `vec_messages`, and the reason is
/// what each corpus is FOR. `message_vectors` is what people said, and the
/// storyline sweep clusters over it: a fifty-chunk contract dropped into that
/// table would be fifty near-identical neighbours crowding out the threads the
/// clustering is about. This one answers a different question — "which passage
/// of which document says this" — and the two never have to be compared, so
/// they never share a table.
///
/// Derived, disposable, and created lazily at first use, for exactly
/// [MessageVectorIndex]'s reasons — read them there. In short: the durable
/// floats are in `attachment_chunks`, losing this index costs a [rebuild] and
/// no model call, and a virtual table created during a migration would fail
/// every pair in drift's `SchemaVerifier` suite.
class AttachmentChunkIndex {
  /// The embedding width, fixed by the model on `:8081`. Chunks are embedded
  /// under the same prefix and the same tag as message cards, so a second
  /// number here would only be a chance to disagree with the sibling.
  static const int dims = 768;

  /// The vec0 table, cosine because the embeddings are compared by direction
  /// and not by magnitude.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS vec_attachment_chunks USING vec0('
      'embedding float[$dims] distance_metric=cosine)';

  final BondDatabase? _db;

  AttachmentChunkIndex(BondDatabase db) : _db = db;

  /// An index that holds nothing and finds nothing.
  AttachmentChunkIndex.disabled() : _db = null;

  /// One attempt, shared. Concurrent first callers await the same future
  /// rather than racing two `CREATE VIRTUAL TABLE`s down the same connection.
  Future<bool>? _ready;

  /// True when `vec_attachment_chunks` exists on this connection at this
  /// width.
  ///
  /// Memoized, including the false: a connection that was opened before
  /// [ensureSqliteVecLoaded] ran will never grow the extension's functions, so
  /// re-probing it every call would be a fixed cost for a fixed answer.
  Future<bool> ensureReady() => _ready ??= _prepare();

  Future<bool> _prepare() async {
    final db = _db;
    if (db == null) return false;
    if (!ensureSqliteVecLoaded()) {
      debugPrint('vec: native extension unavailable — chunk index off');
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
              "AND name = 'vec_attachment_chunks'")
          .get();
      final sql = existing.isEmpty ? null : existing.single.data['sql'] as String?;
      if (sql != null && !sql.contains('float[$dims]')) {
        // Built at another width. A vec0 table cannot be widened in place, and
        // searching the wrong width returns errors rather than wrong answers,
        // so the cheap correct move is to throw it away.
        debugPrint('vec: chunk index width changed — rebuilding');
        await _recreate();
      } else if (sql == null) {
        await db.customStatement(ddl);
      }
      return true;
    } catch (e) {
      debugPrint('vec: chunk index unavailable on this connection: $e');
      return false;
    }
  }

  /// Drops and recreates the vec0 table, and marks every stored chunk
  /// un-indexed so a later [backfill] refills it.
  ///
  /// Does NOT backfill, and cannot: [_prepare] calls this, and a backfill from
  /// there would await the very `ensureReady` future that is still resolving.
  Future<void> _recreate() async {
    final db = _db!;
    // The shadow tables go with it.
    await db.customStatement('DROP TABLE IF EXISTS vec_attachment_chunks');
    await db.customStatement(ddl);
    await db.customStatement('UPDATE attachment_chunks SET indexed_at = NULL');
  }

  /// Files one embedding under [id] — the `attachment_chunks.id` it came from,
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
        'DELETE FROM vec_attachment_chunks WHERE rowid = ?1',
        [id],
      );
      await db.customInsert(
        'INSERT INTO vec_attachment_chunks(rowid, embedding) VALUES (?1, ?2)',
        variables: [Variable<int>(id), Variable<Uint8List>(embedding)],
      );
    } catch (e) {
      debugPrint('vec: indexing chunk $id failed: $e');
    }
  }

  /// The [k] nearest chunks to [query], closest first.
  ///
  /// `AND k = ?` is not a typo for a LIMIT: in sqlite-vec's KNN form `k` is a
  /// constraint the virtual table reads off the WHERE clause to decide how
  /// many neighbours to compute. A LIMIT instead would make it a full scan.
  ///
  /// [rowidWhere] narrows the search to the chunks matching a predicate over
  /// `attachment_chunks` — `source = ? AND (source_message_id IN (…) OR …)`,
  /// with its values in [rowidArgs] after the query and the k. The scope is
  /// applied INSIDE the KNN, and that is the whole point of it: filtering
  /// afterwards gives the k nearest passages in the CORPUS that happen to be
  /// in scope, which on a small mailbox is regularly none of them, while this
  /// gives the k nearest within the scope. sqlite-vec has accepted
  /// `rowid IN (subquery)` in a KNN query since 0.1.2 and the vendored build
  /// is 0.1.9; without the clause the query is exactly what it always was.
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
            'SELECT rowid, distance FROM vec_attachment_chunks '
            'WHERE embedding MATCH ?1 AND k = ?2'
            '${rowidWhere == null ? '' : ' AND rowid IN '
                '(SELECT id FROM attachment_chunks WHERE $rowidWhere)'}',
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
      debugPrint('vec: chunk knn failed: $e');
      return const [];
    }
  }

  /// Indexes every embedded chunk that has never been indexed, and returns how
  /// many were attempted.
  ///
  /// `embedding IS NOT NULL` is the one line that differs from the sibling,
  /// and it is what makes the two-step write safe: a chunk row is stored the
  /// moment the document is split, and its vector arrives one POST later. An
  /// unembedded row must neither be filed (there is nothing to file) nor
  /// stamped (it would then never be filed) — so it is simply not in the
  /// worklist, and the row the embedder just finished is.
  ///
  /// Pages by id so a large mailbox does not load every embedding at once, and
  /// stamps `indexed_at` on every row it touches — including one whose blob
  /// vec0 refused, because leaving a bad row unstamped would put it at the
  /// head of the next page forever and wedge the loop.
  Future<int> backfill({int batch = 500}) async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var indexed = 0;
    try {
      while (true) {
        final rows = await db
            .customSelect(
              'SELECT id, embedding, dims FROM attachment_chunks '
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
              debugPrint('vec: chunk $id is $width-wide, not $dims — skipped');
            }
            await db.customStatement(
              'UPDATE attachment_chunks SET indexed_at = ?1 WHERE id = ?2',
              [_nowIso(), id],
            );
          }
        });
        indexed += rows.length;
        // A short page is the last page.
        if (rows.length < batch) break;
      }
    } catch (e) {
      debugPrint('vec: chunk backfill stopped after $indexed: $e');
    }
    return indexed;
  }

  /// Throws the index away and builds it again from `attachment_chunks`.
  ///
  /// The self-heal, and it costs zero model calls — every float it needs is
  /// already stored. It is also the only cleanup for the rowids
  /// `MessageStore.replaceChunks` orphans: vec0 has no cascade, so a re-chunked
  /// document leaves its old rowids behind until this runs.
  Future<void> rebuild() async {
    if (!await ensureReady()) return;
    try {
      await _recreate();
    } catch (e) {
      debugPrint('vec: chunk rebuild failed: $e');
      return;
    }
    await backfill();
  }

  /// ISO-8601 UTC text, matching `MessageStore` — every timestamp column in
  /// this database is written and compared as that string.
  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
}
