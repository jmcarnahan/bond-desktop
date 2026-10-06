import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'database.dart';

/// The nearest-neighbour index over the CLUSTERING corpus — the one vector per
/// conversation card that `conversation_ai` already holds.
///
/// [MessageVectorIndex]'s sibling, and deliberately built to the same shape:
/// a `vec0` virtual table that is derived, disposable, created lazily, and
/// never in a migration. What differs is the corpus and, following from it,
/// the bookkeeping.
///
/// **No physical table of its own.** `message_vectors` exists because a
/// message's embedding had nowhere else to live; a conversation's already has
/// somewhere — `conversation_ai.embedding`, written by
/// the storyline assign pass. So this class adds exactly one thing to the
/// database, the vec0 table, and adds nothing to `schema.drift`.
///
/// **No `indexed_at` column, so the diff IS the bookkeeping.** The message
/// index stamps every durable row it has filed and then asks for the unstamped
/// ones. `conversation_ai` has no such column and must not grow one for a
/// derived index's convenience, so [backfill] compares the two sides instead:
/// the `(source, key) → embedded_hash` pairs the corpus has against the ones
/// the index holds, inserting what is missing, replacing what changed, and
/// deleting what is gone. That is a full scan of both sides' KEYS and HASHES
/// on every call — a few hundred rows of three short columns, once per sweep,
/// which is far below the cost of the model calls the sweep exists to make.
/// The vectors themselves (4 KB each) are read only for the rows being
/// written, and a call that finds nothing to do writes nothing. The key scan
/// is still linear in the corpus, so it is worth revisiting if the clustering
/// corpus ever reaches the tens of thousands, at which point an
/// `indexed_at`-style watermark (and the schema change to carry it) starts to
/// pay for itself.
///
/// Everything fails soft, for [MessageVectorIndex]'s reason and one more of
/// its own: the sweep's caller has an exact arithmetic fallback, so an index
/// that cannot answer costs nothing but time. [ensureReady] and [backfill]
/// return false rather than throwing, and [neighbors] returns `const []`.
class ConversationVectorIndex {
  /// The embedding width, fixed by the model on `:8081` — the same
  /// `Qwen3-Embedding-0.6B` behind [MessageVectorIndex.dims], reached for
  /// through its own constant because the two corpora are free to diverge and
  /// a shared literal would hide the day they did. 1024 since Round E Phase 2
  /// on 2026-09-19, when the clustering vector left embeddinggemma's 768.
  static const int dims = 1024;

  /// The vec0 table. Cosine for the same reason the message index is cosine —
  /// the sweep compares direction, not magnitude — and the conversion in
  /// [neighbors] is written against exactly this declaration.
  ///
  /// The three `+` columns are sqlite-vec AUXILIARY columns: stored alongside
  /// each vector, returned by a KNN query, and not filterable. That is
  /// precisely the job here. The clustering corpus is keyed by
  /// `(source, conversation_key)` and not by any integer, so the alternative
  /// would be minting a rowid mapping and keeping it honest; carrying the key
  /// on the row instead means a KNN hit already says which thread it is, and
  /// the `embedded_hash` beside it is what makes [backfill] a diff.
  static const String ddl =
      'CREATE VIRTUAL TABLE IF NOT EXISTS vec_conversations USING vec0('
      'embedding float[$dims] distance_metric=cosine, '
      '+source text, +conversation_key text, +embedded_hash text)';

  final BondDatabase? _db;

  ConversationVectorIndex(BondDatabase db) : _db = db;

  /// An index that holds nothing and finds nothing — the seam a caller uses to
  /// hold one unconditionally, and the shape `MessageVectorIndex.disabled`
  /// already has.
  ConversationVectorIndex.disabled() : _db = null;

  /// One attempt, shared, exactly as the message index memoizes its own.
  Future<bool>? _ready;

  /// True when `vec_conversations` exists on this connection in this shape.
  Future<bool> ensureReady() => _ready ??= _prepare();

  Future<bool> _prepare() async {
    final db = _db;
    if (db == null) return false;
    if (!ensureSqliteVecLoaded()) {
      debugPrint('vec: native extension unavailable — clustering index off');
      return false;
    }
    try {
      // The registration is process-global and reaches only connections opened
      // AFTER it, so the live connection is what has to be asked.
      await db.customSelect('SELECT vec_version() AS v').getSingle();

      final existing = await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'table' "
              "AND name = 'vec_conversations'")
          .get();
      final sql = existing.isEmpty ? null : existing.single.data['sql'] as String?;
      if (sql == null) {
        await db.customStatement(ddl);
      } else if (!sql.contains('float[$dims]') ||
          !sql.contains('+conversation_key')) {
        // Built at another width, or by a build that carried the key some
        // other way. A vec0 table changes neither in place, and the whole
        // thing is derived, so throwing it away is the cheap correct move —
        // the next [backfill] refills it from `conversation_ai` at no model
        // cost at all.
        debugPrint('vec: clustering index shape changed — rebuilding');
        await _recreate();
      }
      return true;
    } catch (e) {
      debugPrint('vec: clustering index unavailable on this connection: $e');
      return false;
    }
  }

  Future<void> _recreate() async {
    final db = _db!;
    // The shadow tables (`vec_conversations_chunks` and friends) go with it.
    await db.customStatement('DROP TABLE IF EXISTS vec_conversations');
    await db.customStatement(ddl);
  }

  /// Throws the index away and leaves it empty.
  ///
  /// What `MessageStore.wipeAll` needs and what [ConversationVectorIndex] can
  /// offer instead of a rebuild: the durable rows are being deleted in the
  /// same breath, so there is nothing to refill from, and the next sweep's
  /// [backfill] is what fills it again. A DELETE against `conversation_ai`
  /// does not reach inside a virtual table, so without this the previous
  /// mailbox's floats would survive a wipe in the shadow tables.
  Future<void> reset() async {
    if (!await ensureReady()) return;
    try {
      await _recreate();
    } catch (e) {
      debugPrint('vec: clustering index reset failed: $e');
    }
  }

  /// Brings the index level with `conversation_ai` for [embedModel], and
  /// returns how many rows it holds afterwards — `null` when it could not be
  /// brought level at all.
  ///
  /// A count rather than a bool because the caller needs it: a KNN probe has
  /// to ask for as many neighbours as there are rows to be sure it has seen
  /// every one of them, and only this side knows how many that is.
  ///
  /// [embedModel] is a parameter for [MessageStore.conversationsWithEmbeddings]'
  /// reason — two vectors are comparable only under one tag, and this layer
  /// imports nothing above itself.
  ///
  /// Rows whose blob is not exactly [dims] wide are skipped rather than
  /// attempted. They are not an error (a model change leaves a corpus at two
  /// widths for a while) but they ARE a hole in the index, which is why the
  /// sweep checks its own candidates' width before trusting this.
  ///
  /// Two scans of keys and hashes decide what moves; the blobs are fetched
  /// only for the rows to insert, [_chunk] keys per select, and every delete
  /// and insert goes in ONE batch — one transaction and one round trip to the
  /// database isolate. A call over an unchanged corpus returns after the two
  /// scans, having written nothing.
  Future<int?> backfill({required String embedModel}) async {
    if (!await ensureReady()) return null;
    final db = _db!;
    try {
      // Keys, hashes and the blob's WIDTH, never the blob: most calls find
      // nothing to write, and a vector is fetched below only for a row about
      // to be inserted.
      final durable = <String, ({String source, String key})>{};
      final hashes = <String, String>{};
      for (final row in await db
          .customSelect(
            'SELECT source, conversation_key, embedded_hash, '
            'length(embedding) AS width '
            'FROM conversation_ai '
            'WHERE embedding IS NOT NULL AND embed_model = ?1',
            variables: [Variable<String>(embedModel)],
          )
          .get()) {
        final source = row.data['source'] as String? ?? '';
        final key = row.data['conversation_key'] as String? ?? '';
        final width = row.data['width'];
        if (key.isEmpty || width is! int) continue;
        if (width != dims * 4) {
          debugPrint('vec: $source/$key is ${width ~/ 4}-wide, '
              'not $dims — skipped');
          continue;
        }
        final id = _rowKey(source, key);
        durable[id] = (source: source, key: key);
        // NULL is a hash like any other here: the pair only ever has to be
        // compared against itself, and a row whose writer left it null is a
        // row the diff treats as unchanged rather than one it re-files on
        // every sweep.
        hashes[id] = row.data['embedded_hash'] as String? ?? '';
      }

      final keep = <String, int>{};
      final stale = <int>[];
      for (final row in await db
          .customSelect('SELECT rowid, source, conversation_key, embedded_hash '
              'FROM vec_conversations')
          .get()) {
        final rowid = row.data['rowid'] as int;
        final id = _rowKey(
          row.data['source'] as String? ?? '',
          row.data['conversation_key'] as String? ?? '',
        );
        final hash = row.data['embedded_hash'] as String? ?? '';
        // Three ways to be stale, and a duplicate is the third: an index row
        // whose thread has left the corpus or been re-tagged, one whose card
        // was re-embedded under a new hash, and a second copy of a key the
        // first pass through this loop already kept.
        final current = durable.containsKey(id) &&
            hashes[id] == hash &&
            !keep.containsKey(id);
        if (current) {
          keep[id] = rowid;
        } else {
          stale.add(rowid);
        }
      }

      final missing = [
        for (final entry in durable.entries)
          if (!keep.containsKey(entry.key)) entry.value,
      ];
      // The common case on every sweep: the index is already level, and a
      // call that has nothing to do writes nothing — no transaction, no
      // batch, no further statement.
      if (stale.isEmpty && missing.isEmpty) return durable.length;

      // The blobs for the rows to insert, a chunk of keys per select. Each
      // insert takes the hash and the blob THIS select returned, so the pair
      // written to the index is one row's even if the thread was re-embedded
      // since the scan above; a row deleted meanwhile is simply not returned
      // and not inserted. Keyed, then written in [missing]'s order, so the
      // index's rowids are assigned in the order they always were.
      final fetched = <String, List<Object?>>{};
      for (var start = 0; start < missing.length; start += _chunk) {
        final chunk = missing.sublist(
          start,
          math.min(start + _chunk, missing.length),
        );
        final pairs = List.filled(chunk.length, '(?, ?)').join(', ');
        for (final row in await db
            .customSelect(
              'SELECT source, conversation_key, embedded_hash, embedding '
              'FROM conversation_ai '
              'WHERE embedding IS NOT NULL AND embed_model = ? '
              'AND (source, conversation_key) IN (VALUES $pairs)',
              variables: [
                Variable<String>(embedModel),
                for (final m in chunk) ...[
                  Variable<String>(m.source),
                  Variable<String>(m.key),
                ],
              ],
            )
            .get()) {
          final blob = row.data['embedding'];
          if (blob is! Uint8List || blob.lengthInBytes != dims * 4) continue;
          final source = row.data['source'] as String? ?? '';
          final key = row.data['conversation_key'] as String? ?? '';
          fetched[_rowKey(source, key)] = [
            blob,
            source,
            key,
            row.data['embedded_hash'] as String? ?? '',
          ];
        }
      }
      final inserts = [
        for (final m in missing) ?fetched[_rowKey(m.source, m.key)],
      ];
      // Every missing row left between the scan and the fetch, and nothing was
      // stale: there is nothing to write after all.
      if (stale.isEmpty && inserts.isEmpty) return durable.length;

      // One batch: one transaction and one round trip to the database
      // isolate, however many rows move.
      await db.batch((batch) {
        for (final rowid in stale) {
          batch.customStatement(
              'DELETE FROM vec_conversations WHERE rowid = ?', [rowid]);
        }
        for (final args in inserts) {
          batch.customStatement(
            'INSERT INTO vec_conversations'
            '(embedding, source, conversation_key, embedded_hash) '
            'VALUES (?, ?, ?, ?)',
            args,
          );
        }
      });
      return durable.length;
    } catch (e) {
      debugPrint('vec: clustering backfill failed: $e');
      return null;
    }
  }

  /// The [k] threads nearest [query], closest first, as cosine SIMILARITIES.
  ///
  /// The table declares `distance_metric=cosine`, whose distance is
  /// `1 - cos(a, b)` — 0 for identical direction, 1 for orthogonal, 2 for
  /// opposed. So the similarity the sweep compares against
  /// `StorylineTuning.clusterLinkThreshold` is `1 - distance`, and that single
  /// subtraction is the whole conversion. (Were the table an L2 one over
  /// normalised vectors the algebra would instead be `1 - d² / 2`; it is not,
  /// and [ddl] is the authority on which.)
  ///
  /// The probe's own row comes back like any other, at similarity 1 — this
  /// side cannot tell which row asked. Excluding it is the caller's job, and
  /// the sweep does it by key.
  ///
  /// `AND k = ?` is not a typo for a LIMIT: in sqlite-vec's KNN form `k` is a
  /// constraint the virtual table reads off the WHERE clause. A LIMIT instead
  /// would make it a full scan.
  Future<List<({String source, String key, double similarity})>> neighbors(
    Uint8List query, {
    required int k,
  }) async {
    if (!await ensureReady()) return const [];
    if (k <= 0) return const [];
    try {
      final rows = await _db!
          .customSelect(
            'SELECT source, conversation_key, distance FROM vec_conversations '
            'WHERE embedding MATCH ?1 AND k = ?2',
            variables: [Variable<Uint8List>(query), Variable<int>(k)],
          )
          .get();
      return [
        for (final row in rows)
          (
            source: row.data['source'] as String? ?? '',
            key: row.data['conversation_key'] as String? ?? '',
            similarity: 1 - (row.data['distance'] as num).toDouble(),
          ),
      ];
    } catch (e) {
      debugPrint('vec: clustering knn failed: $e');
      return const [];
    }
  }

  /// The composite the diff is keyed on. `\n` because neither a source nor a
  /// conversation key contains one, which is the same reason
  /// `StorylineService._threadKey` picked it.
  static String _rowKey(String source, String key) => '$source\n$key';

  /// Keys per blob fetch in [backfill]: 201 variables a select (the model and
  /// a pair per key), well under SQLite's variable limit.
  static const int _chunk = 100;
}
