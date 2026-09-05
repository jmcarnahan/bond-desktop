import 'dart:math' as math;

import 'package:bond_inbox/data/conversation_vec_index.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
// `show Variable` and no more: drift exports an `isNotNull` of its own, which
// would shadow the matcher every assertion below reaches for.
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/vec_test_db.dart';

/// A unit vector in the plane spanned by dimensions `2 * plane` and
/// `2 * plane + 1`, zero everywhere else.
///
/// Two rays in the SAME plane sit at cosine `cos(a - b)`; two in different
/// planes are orthogonal, at cosine 0. That is the whole geometry these tests
/// need, and it means an expected similarity can be read off the angles
/// instead of being derived from 768 numbers.
List<double> ray(int plane, double radians) {
  final v = List<double>.filled(ConversationVectorIndex.dims, 0.0);
  v[plane * 2] = math.cos(radians);
  v[plane * 2 + 1] = math.sin(radians);
  return v;
}

void main() {
  group('the disabled clustering index', () {
    // No database at all, and every method still safe to call — the seam that
    // lets a caller hold an index unconditionally.
    final index = ConversationVectorIndex.disabled();

    test('is never ready', () async {
      expect(await index.ensureReady(), isFalse);
    });

    test('backfill reports no index rather than a count', () async {
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag),
          isNull);
    });

    test('neighbors finds nothing', () async {
      expect(await index.neighbors(encodeEmbedding(ray(0, 0)), k: 5), isEmpty);
    });

    test('reset completes', () async {
      await expectLater(index.reset(), completes);
    });
  });

  group('the real clustering index', () {
    // The native asset is expected to be here — the sqlite3 package ships its
    // own SQLite the same way. The guard exists so a build without code assets
    // reports a skip rather than a screenful of confusing failures.
    late bool available;
    setUpAll(() {
      available = ensureSqliteVecLoaded();
      if (!available) {
        printOnFailure('sqlite-vec native asset missing — vec tests skipped');
      }
    });

    late BondDatabase db;
    late MessageStore store;
    late ConversationVectorIndex index;

    setUp(() {
      db = vecTestDb();
      store = MessageStore(db);
      index = ConversationVectorIndex(db);
    });

    // Drift holds the connection open; a suite that leaks them exhausts the
    // process rather than failing on the test that leaked.
    tearDown(() => db.close());

    Future<void> seed(
      String key,
      List<double> vector, {
      String source = 'email',
      String hash = 'h1',
      String embedModel = EmbeddingsClient.modelTag,
    }) =>
        store.upsertConversationAi(
          source,
          key,
          embedding: encodeEmbedding(vector),
          embeddedHash: hash,
          embedModel: embedModel,
        );

    /// What the index holds, as `source/key@hash` — the three columns the diff
    /// turns on, read back out of the vec0 table itself.
    Future<List<String>> contents() async {
      final rows = await db
          .customSelect('SELECT source, conversation_key, embedded_hash '
              'FROM vec_conversations')
          .get();
      return [
        for (final r in rows)
          '${r.data['source']}/${r.data['conversation_key']}'
              '@${r.data['embedded_hash']}',
      ]..sort();
    }

    test('the diff backfill heals a changed vector and drops an orphan',
        () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      await seed('b', ray(1, 0), hash: 'h-b');
      await seed('c', ray(2, 0), hash: 'h-c', source: 'teams');

      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 3);
      expect(await contents(),
          ['email/a@h-a', 'email/b@h-b', 'teams/c@h-c']);

      // b is re-embedded onto a different vector under a new hash, and a is
      // deleted out from under the index. Neither writer told the index
      // anything — the diff is the only bookkeeping there is.
      await seed('b', ray(1, math.pi / 2), hash: 'h-b2');
      await db.customUpdate(
        'DELETE FROM conversation_ai WHERE source = ? AND conversation_key = ?',
        variables: [const Variable('email'), const Variable('a')],
      );

      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 2);
      expect(await contents(), ['email/b@h-b2', 'teams/c@h-c']);

      // And the replaced vector is genuinely gone: b now answers to where it
      // moved TO and not to where it was.
      final moved = await index.neighbors(
        encodeEmbedding(ray(1, math.pi / 2)),
        k: 5,
      );
      expect(moved.first.key, 'b');
      expect(moved.first.similarity, closeTo(1.0, 1e-6));
      final was = await index.neighbors(encodeEmbedding(ray(1, 0)), k: 5);
      expect(was.firstWhere((h) => h.key == 'b').similarity,
          closeTo(0.0, 1e-6));
    });

    test('a thread re-tagged to another model leaves the index', () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      await seed('b', ray(1, 0), hash: 'h-b');
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 2);

      // The row is still there; it is simply no longer part of THIS corpus,
      // which is the same thing as far as an index for one corpus goes.
      await seed('b', ray(1, 0), hash: 'h-b', embedModel: 'some-other-model');

      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 1);
      expect(await contents(), ['email/a@h-a']);
    });

    test('a second backfill over an unchanged corpus changes nothing',
        () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      await seed('b', ray(0, 0.05), hash: 'h-b');
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 2);
      final before = await contents();

      // The diff is run on every sweep, so "no change" has to mean no writes
      // and, above all, no duplicate rows — the failure mode a diff keyed on
      // something other than the pair would have.
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 2);
      expect(await contents(), before);
      expect(await index.neighbors(encodeEmbedding(ray(0, 0)), k: 10),
          hasLength(2));
    });

    test('a row at another width is skipped rather than indexed', () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      await seed('narrow', const [1.0, 0.0], hash: 'h-n');

      // Counted as indexed rows only: the narrow one is a hole, and the sweep
      // is what refuses to trust an index with one.
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 1);
      expect(await contents(), ['email/a@h-a']);
    });

    test('the similarity it reports is the cosine the sweep would compute',
        () async {
      if (!available) return;
      // The conversion under test is `1 - distance` against a cosine table,
      // and this is what pins it: an angle whose cosine is a number written
      // out here, matched against both the index and `cosine()` itself. The
      // tolerance is float32's, not a fudge — the blob the index reads and
      // the blob `decodeEmbedding` reads are the same 32-bit floats.
      final anchor = ray(0, 0);
      final near = ray(0, math.acos(0.65));
      await seed('anchor', anchor, hash: 'h-1');
      await seed('near', near, hash: 'h-2');
      await seed('far', ray(1, 0), hash: 'h-3');
      await index.backfill(embedModel: EmbeddingsClient.modelTag);

      final hits = await index.neighbors(encodeEmbedding(anchor), k: 10);
      final byKey = {for (final h in hits) h.key: h.similarity};
      expect(byKey['anchor'], closeTo(1.0, 1e-6));
      expect(byKey['near'], closeTo(0.65, 1e-6));
      expect(byKey['far'], closeTo(0.0, 1e-6));
      // Against the arithmetic the fallback path uses, on the same floats.
      expect(byKey['near'], closeTo(cosine(anchor, near), 1e-6));
    });

    test('an index built in another shape is thrown away', () async {
      if (!available) return;
      // What an older build — one that carried the key some other way — leaves
      // behind.
      await db.customStatement('CREATE VIRTUAL TABLE vec_conversations '
          'USING vec0(embedding float[768] distance_metric=cosine)');
      await seed('a', ray(0, 0), hash: 'h-a');

      expect(await index.ensureReady(), isTrue);
      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 1);
      expect(await contents(), ['email/a@h-a']);
    });

    test('reset empties it and the next backfill refills it', () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      await index.backfill(embedModel: EmbeddingsClient.modelTag);

      await index.reset();
      expect(await contents(), isEmpty);

      expect(await index.backfill(embedModel: EmbeddingsClient.modelTag), 1);
      expect(await contents(), ['email/a@h-a']);
    });

    test('wipeAll takes the clustering index with it', () async {
      if (!available) return;
      await seed('a', ray(0, 0), hash: 'h-a');
      // The store's own index, not this test's — what the wipe reaches.
      expect(
        await store.prepareConversationIndex(
            embedModel: EmbeddingsClient.modelTag),
        1,
      );
      expect(await contents(), ['email/a@h-a']);

      await store.wipeAll();

      // A DELETE against `conversation_ai` does not reach inside a virtual
      // table, so this is the assertion that the previous mailbox's floats are
      // not still sitting in the shadow tables.
      expect(await contents(), isEmpty);
    });
  });
}
