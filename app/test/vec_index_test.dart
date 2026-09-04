import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/vec_index.dart';
// `show Variable` and no more: drift exports an `isNotNull` of its own, which
// would shadow the matcher every assertion below reaches for.
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/vec_test_db.dart';

/// A unit vector: 768 float32s, all zero but for a 1.0 at [hotIndex].
///
/// Distinct axes make the geometry arithmetic-free — under cosine, two of
/// these are exactly 1.0 apart and one is exactly 0.0 from itself — so a
/// failure here is a failure of the index, never of the fixture's maths.
Uint8List vec768(int hotIndex) {
  final floats = Float32List(MessageVectorIndex.dims);
  floats[hotIndex] = 1.0;
  return floats.buffer.asUint8List();
}

/// Seeds one durable vector, un-indexed, and returns its id.
Future<int> seedVector(
  BondDatabase db, {
  required String messageId,
  required Uint8List embedding,
  int dims = MessageVectorIndex.dims,
}) async {
  return db.customInsert(
    'INSERT INTO message_vectors (source, source_message_id, embedding, dims, '
    'embedded_hash, embed_model, received_at, embedded_at, indexed_at) '
    'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)',
    variables: [
      const Variable<String>('email'),
      Variable<String>(messageId),
      Variable<Uint8List>(embedding),
      Variable<int>(dims),
      Variable<String>('hash-$messageId'),
      const Variable<String>('embeddinggemma-300M'),
      const Variable<String>('2026-09-03T10:00:00.000Z'),
      const Variable<String>('2026-09-03T10:00:01.000Z'),
    ],
  );
}

void main() {
  group('disabled index', () {
    // No database at all, and every method still safe to call — the seam that
    // lets a caller hold an index unconditionally.
    final index = MessageVectorIndex.disabled();

    test('is never ready', () async {
      expect(await index.ensureReady(), isFalse);
    });

    test('upsert is a no-op rather than a throw', () async {
      await expectLater(
        index.upsert(id: 1, embedding: vec768(0)),
        completes,
      );
    });

    test('knn finds nothing', () async {
      expect(await index.knn(vec768(0), k: 5), isEmpty);
    });

    test('backfill indexes nothing', () async {
      expect(await index.backfill(), 0);
    });

    test('rebuild completes', () async {
      await expectLater(index.rebuild(), completes);
    });
  });

  group('real vec0 index', () {
    // The native asset is expected to be here — the sqlite3 package ships its
    // own SQLite the same way. The guard exists so a build without code assets
    // reports a skip rather than 7 confusing failures.
    late bool available;
    setUpAll(() {
      available = ensureSqliteVecLoaded();
      if (!available) {
        printOnFailure('sqlite-vec native asset missing — vec tests skipped');
      }
    });

    late BondDatabase db;
    late MessageVectorIndex index;

    setUp(() {
      db = vecTestDb();
      index = MessageVectorIndex(db);
    });

    // Drift holds the connection open; a suite that leaks them exhausts the
    // process rather than failing on the test that leaked.
    tearDown(() => db.close());

    Future<String?> vecTableSql() async {
      final rows = await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'table' "
              "AND name = 'vec_messages'")
          .get();
      return rows.isEmpty ? null : rows.single.data['sql'] as String?;
    }

    Future<List<String?>> indexedStamps() async {
      final rows = await db
          .customSelect('SELECT indexed_at FROM message_vectors ORDER BY id')
          .get();
      return [for (final r in rows) r.data['indexed_at'] as String?];
    }

    test('ensureReady creates vec_messages at the model width', () async {
      if (!available) return;
      expect(await index.ensureReady(), isTrue);
      expect(await vecTableSql(), contains('float[768]'));
    });

    test('knn returns the nearest vector first', () async {
      if (!available) return;
      await index.upsert(id: 1, embedding: vec768(0));
      await index.upsert(id: 2, embedding: vec768(1));
      await index.upsert(id: 3, embedding: vec768(2));

      final hits = await index.knn(vec768(0), k: 3);
      expect(hits, hasLength(3));
      expect(hits.first.id, 1);
      expect(hits.first.distance, lessThan(0.001));
      // Ordered by distance, and the two orthogonal axes sit a full 1.0 away.
      expect(hits[1].distance, greaterThan(0.9));
      expect(hits.map((h) => h.distance).toList(), orderedEquals(
        [...hits.map((h) => h.distance)]..sort(),
      ));

      expect(await index.knn(vec768(0), k: 2), hasLength(2));
    });

    test('upserting the same id twice keeps only the second vector', () async {
      if (!available) return;
      await index.upsert(id: 7, embedding: vec768(0));
      await index.upsert(id: 7, embedding: vec768(5));

      // One row, not two — the DELETE before the INSERT is what makes this an
      // upsert on a table that has no UPSERT.
      expect(await index.knn(vec768(5), k: 10), hasLength(1));

      final hits = await index.knn(vec768(5), k: 1);
      expect(hits.single.id, 7);
      expect(hits.single.distance, lessThan(0.001));
      // And the vector it replaced is genuinely gone.
      expect((await index.knn(vec768(0), k: 1)).single.distance,
          greaterThan(0.9));
    });

    test('backfill indexes every un-indexed vector and stamps it', () async {
      if (!available) return;
      final a = await seedVector(db, messageId: 'm-a', embedding: vec768(0));
      final b = await seedVector(db, messageId: 'm-b', embedding: vec768(1));
      await seedVector(db, messageId: 'm-c', embedding: vec768(2));

      expect(await index.backfill(), 3);
      expect(await indexedStamps(), everyElement(isNotNull));

      expect((await index.knn(vec768(0), k: 1)).single.id, a);
      expect((await index.knn(vec768(1), k: 1)).single.id, b);
      // And a second pass has nothing left to do.
      expect(await index.backfill(), 0);
    });

    test('a blob vec0 refuses does not wedge the backfill', () async {
      if (!available) return;
      final good = await seedVector(db, messageId: 'm-good', embedding: vec768(0));
      // Right dims column, wrong byte length — the shape a truncated write or
      // a writer that disagreed about float32 would leave behind.
      await seedVector(
        db,
        messageId: 'm-short',
        embedding: Float32List(4).buffer.asUint8List(),
      );
      final tail = await seedVector(db, messageId: 'm-tail', embedding: vec768(3));

      // All three are attempted, and all three are stamped — an unstamped bad
      // row would sit at the head of the next page forever.
      expect(await index.backfill(), 3);
      expect(await indexedStamps(), everyElement(isNotNull));
      expect(await index.backfill(), 0);

      // The good rows around it are searchable; the bad one simply is not
      // there.
      expect((await index.knn(vec768(0), k: 1)).single.id, good);
      expect((await index.knn(vec768(3), k: 1)).single.id, tail);
      expect(await index.knn(vec768(0), k: 10), hasLength(2));
    });

    test('a row whose dims column disagrees is skipped, not attempted',
        () async {
      if (!available) return;
      final good = await seedVector(db, messageId: 'm-good', embedding: vec768(0));
      // dims and blob AGREE with each other, and both disagree with the
      // index — the shape a model change would leave behind. This exercises
      // the dims-column check, where the short-blob test above exercises
      // vec0's own rejection.
      await seedVector(
        db,
        messageId: 'm-narrow',
        embedding: Float32List(4).buffer.asUint8List(),
        dims: 4,
      );

      // Both counted as attempted, both stamped — a [rebuild] after a
      // re-embed is what would bring the narrow row back, not this loop.
      expect(await index.backfill(), 2);
      expect(await indexedStamps(), everyElement(isNotNull));
      expect(await index.backfill(), 0);

      expect((await index.knn(vec768(0), k: 1)).single.id, good);
      expect(await index.knn(vec768(0), k: 10), hasLength(1));
    });

    test('rebuild re-creates the index from the durable vectors', () async {
      if (!available) return;
      final a = await seedVector(db, messageId: 'm-a', embedding: vec768(0));
      await seedVector(db, messageId: 'm-b', embedding: vec768(1));
      expect(await index.backfill(), 2);
      final before = await indexedStamps();

      await index.rebuild();

      // Same rows, freshly stamped, and no model was asked for anything.
      expect(await vecTableSql(), contains('float[768]'));
      final after = await indexedStamps();
      expect(after, everyElement(isNotNull));
      expect(after, hasLength(before.length));
      expect((await index.knn(vec768(0), k: 1)).single.id, a);
      expect(await index.knn(vec768(0), k: 10), hasLength(2));
    });

    test('an index built at another width is thrown away', () async {
      if (!available) return;
      // What an older build — or a hand-rolled table — leaves behind.
      await db.customStatement('CREATE VIRTUAL TABLE vec_messages USING vec0('
          'embedding float[4] distance_metric=cosine)');
      expect(await vecTableSql(), contains('float[4]'));

      expect(await index.ensureReady(), isTrue);
      expect(await vecTableSql(), contains('float[768]'));

      // And it is usable at the new width immediately.
      await index.upsert(id: 1, embedding: vec768(0));
      expect((await index.knn(vec768(0), k: 1)).single.id, 1);
    });
  });
}
