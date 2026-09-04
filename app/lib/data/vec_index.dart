import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'database.dart';

/// The nearest-neighbour index over `message_vectors` — derived, disposable,
/// and created only when something actually searches.
///
/// Two tables, two jobs. `message_vectors` is the durable one: it holds the
/// embedding a model was paid for, and it is the source of truth. `vec_messages`
/// is a sqlite-vec `vec0` virtual table holding the same floats in a shape that
/// can answer "what is closest to this?" — an INDEX, in the ordinary sense.
/// Losing it costs a rebuild ([rebuild]) and not one model call, which is why
/// nothing here is careful about it: it is dropped and rebuilt on a width
/// mismatch without asking anyone.
///
/// It is created LAZILY, at first use, and never by a migration or in
/// `beforeOpen`. That is a hard rule rather than a preference: drift's
/// `SchemaVerifier` diffs the whole of `sqlite_master` against a snapshot, so a
/// virtual table appearing during a migration step fails every migration pair
/// in the suite. Creating it here — after the migrations, on demand — keeps it
/// a fact about what this process has done rather than a fact about the schema.
///
/// Everything fails soft. sqlite-vec's native asset may be missing, or the
/// connection may predate the auto-extension registration; in either case
/// [ensureReady] returns false and every method after it no-ops, returns
/// `const []`, or returns 0. Semantic search going quiet is a degraded feature.
/// It is never a reason to take a write path down.
///
/// [MessageVectorIndex.disabled] is the test seam, in the shape
/// `ActivityLog.disabled` and `PipelineProgress.disabled` already have: an
/// index over nothing, so a caller can hold one unconditionally.
class MessageVectorIndex {
  /// The embedding width, fixed by the model on `:8081`
  /// (`embeddinggemma-300M`, `n_embd` 768). It appears once, here, and the DDL
  /// is built from it — a second literal is how the table and the writer
  /// silently disagree.
  static const int dims = 768;

  /// The vec0 table, cosine because the embeddings are compared by direction
  /// and not by magnitude.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS vec_messages USING vec0('
      'embedding float[$dims] distance_metric=cosine)';

  final BondDatabase? _db;

  MessageVectorIndex(BondDatabase db) : _db = db;

  /// An index that holds nothing and finds nothing.
  ///
  /// Not `const`, unlike its siblings in `lib/services/`: the memo below is a
  /// mutable field, and it stays one because the alternative — re-probing the
  /// connection on every call — is a real cost paid to make a test seam
  /// prettier.
  MessageVectorIndex.disabled() : _db = null;

  /// One attempt, shared. Concurrent first callers await the same future
  /// rather than racing two `CREATE VIRTUAL TABLE`s down the same connection.
  Future<bool>? _ready;

  /// True when `vec_messages` exists on this connection at this width.
  ///
  /// Memoized, including the false: a connection that was opened before
  /// [ensureSqliteVecLoaded] ran will never grow the extension's functions, so
  /// re-probing it every call would be a fixed cost for a fixed answer.
  Future<bool> ensureReady() => _ready ??= _prepare();

  Future<bool> _prepare() async {
    final db = _db;
    if (db == null) return false;
    if (!ensureSqliteVecLoaded()) {
      debugPrint('vec: native extension unavailable — index off');
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
              "AND name = 'vec_messages'")
          .get();
      final sql = existing.isEmpty ? null : existing.single.data['sql'] as String?;
      if (sql != null && !sql.contains('float[$dims]')) {
        // Built at another width — by an older build, or by a test that made
        // one by hand. A vec0 table cannot be widened in place, and searching
        // the wrong width returns errors rather than wrong answers, so the
        // cheap correct move is to throw it away.
        debugPrint('vec: index width changed — rebuilding');
        await _recreate();
      } else if (sql == null) {
        await db.customStatement(ddl);
      }
      return true;
    } catch (e) {
      debugPrint('vec: index unavailable on this connection: $e');
      return false;
    }
  }

  /// Drops and recreates the vec0 table, and marks every durable vector
  /// un-indexed so a later [backfill] refills it.
  ///
  /// Does NOT backfill, and cannot: [_prepare] calls this, and a backfill from
  /// there would await the very `ensureReady` future that is still resolving.
  /// The rows are simply left un-indexed for whoever backfills next.
  Future<void> _recreate() async {
    final db = _db!;
    // The shadow tables (`vec_messages_chunks` and friends) go with it.
    await db.customStatement('DROP TABLE IF EXISTS vec_messages');
    await db.customStatement(ddl);
    await db.customStatement('UPDATE message_vectors SET indexed_at = NULL');
  }

  /// Files one embedding under [id] — the `message_vectors.id` it came from,
  /// which is also its `rowid` in the index.
  ///
  /// [embedding] must be exactly `dims * 4` bytes of little-endian float32
  /// (a `Float32List(768).buffer.asUint8List()` on any machine this ships to).
  /// That byte layout is the contract sqlite-vec reads, and it is what every
  /// writer of `message_vectors.embedding` has to store.
  Future<void> upsert({required int id, required Uint8List embedding}) async {
    if (!await ensureReady()) return;
    await _write(id, embedding);
  }

  /// vec0 has no UPSERT and no `INSERT OR REPLACE`, so a re-embed is a delete
  /// followed by an insert. The DELETE is unconditional — it is a no-op for a
  /// rowid that was never indexed.
  ///
  /// Swallows its own failure. The blob is the one thing here that can be
  /// wrong (short, long, or written by something that did not agree about the
  /// width), and one unusable vector must not take down the page of good ones
  /// around it.
  Future<void> _write(int id, Uint8List embedding) async {
    final db = _db!;
    try {
      await db.customStatement('DELETE FROM vec_messages WHERE rowid = ?1', [id]);
      await db.customInsert(
        'INSERT INTO vec_messages(rowid, embedding) VALUES (?1, ?2)',
        variables: [Variable<int>(id), Variable<Uint8List>(embedding)],
      );
    } catch (e) {
      debugPrint('vec: indexing row $id failed: $e');
    }
  }

  /// The [k] nearest rows to [query], closest first.
  ///
  /// `AND k = ?` is not a typo for a LIMIT: in sqlite-vec's KNN form `k` is a
  /// constraint the virtual table reads off the WHERE clause to decide how
  /// many neighbours to compute. A LIMIT instead would make it a full scan.
  ///
  /// [query] carries the same byte contract as [upsert]'s embedding.
  Future<List<VecHit>> knn(Uint8List query, {required int k}) async {
    if (!await ensureReady()) return const [];
    try {
      final rows = await _db!
          .customSelect(
            'SELECT rowid, distance FROM vec_messages '
            'WHERE embedding MATCH ?1 AND k = ?2',
            variables: [Variable<Uint8List>(query), Variable<int>(k)],
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
      debugPrint('vec: knn failed: $e');
      return const [];
    }
  }

  /// Indexes every `message_vectors` row that has never been indexed, and
  /// returns how many were attempted.
  ///
  /// Pages by id so a large mailbox does not load every embedding at once, and
  /// stamps `indexed_at` on every row it touches — including one whose blob
  /// vec0 refused. That is deliberate: leaving a bad row unstamped would put it
  /// at the head of the next page forever and wedge the loop, and a [rebuild]
  /// re-tries the whole table anyway, so nothing is permanently written off.
  Future<int> backfill({int batch = 500}) async {
    if (!await ensureReady()) return 0;
    final db = _db!;
    var indexed = 0;
    try {
      while (true) {
        final rows = await db
            .customSelect(
              'SELECT id, embedding, dims FROM message_vectors '
              'WHERE indexed_at IS NULL ORDER BY id LIMIT ?1',
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
              debugPrint('vec: row $id is $width-wide, not $dims — skipped');
            }
            await db.customStatement(
              'UPDATE message_vectors SET indexed_at = ?1 WHERE id = ?2',
              [_nowIso(), id],
            );
          }
        });
        indexed += rows.length;
        // A short page is the last page.
        if (rows.length < batch) break;
      }
    } catch (e) {
      debugPrint('vec: backfill stopped after $indexed: $e');
    }
    return indexed;
  }

  /// Throws the index away and builds it again from `message_vectors`.
  ///
  /// The self-heal, and it costs zero model calls — every float it needs is
  /// already stored. Reach for it when the index is suspect: a partial
  /// backfill, a width change, a file restored from underneath the app.
  Future<void> rebuild() async {
    if (!await ensureReady()) return;
    try {
      await _recreate();
    } catch (e) {
      debugPrint('vec: rebuild failed: $e');
      return;
    }
    await backfill();
  }

  /// ISO-8601 UTC text, matching `MessageStore` — every timestamp column in
  /// this database is written and compared as that string.
  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

/// One neighbour: the `message_vectors.id` that was indexed, and how far it
/// sits from the query under the table's cosine metric (0 is identical, 1 is
/// orthogonal, 2 is opposed).
class VecHit {
  final int id;
  final double distance;

  const VecHit(this.id, this.distance);

  @override
  String toString() => 'VecHit($id, $distance)';
}
