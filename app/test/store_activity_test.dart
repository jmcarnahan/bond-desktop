import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'fixtures/test_db.dart';

/// The `activity_events` table and the four calls over it.
///
/// The arithmetic in [MessageStore.activityStats] is the part worth pinning:
/// it is the only place in the app that averages anything, and a header that
/// quietly reports the wrong number is worse than one that reports none.

String _iso(Duration ago) =>
    DateTime.now().toUtc().subtract(ago).toIso8601String();

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<int> rowCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM activity_events').get())
          .first
          .data['n'] as int;

  group('recordActivity', () {
    test('round-trips every column, detail included', () async {
      await store.recordActivity(
        kind: 'triage',
        status: 'ok',
        source: 'email',
        entityId: 'm1',
        count: 3,
        durationMs: 1200,
        detailJson: '{"urgency":"high"}',
        createdAt: '2026-08-29T10:00:00.000Z',
      );

      final row = (await store.recentActivity()).single;
      expect(row['kind'], 'triage');
      expect(row['status'], 'ok');
      expect(row['source'], 'email');
      expect(row['entity_id'], 'm1');
      expect(row['count'], 3);
      expect(row['duration_ms'], 1200);
      expect(row['detail_json'], '{"urgency":"high"}');
      expect(row['created_at'], '2026-08-29T10:00:00.000Z');
    });

    test('everything but kind, status and time may be absent', () async {
      await store.recordActivity(kind: 'embed_fail', status: 'error');

      final row = (await store.recentActivity()).single;
      expect(row['source'], isNull);
      expect(row['entity_id'], isNull);
      expect(row['count'], isNull);
      expect(row['duration_ms'], isNull);
      expect(row['detail_json'], isNull);
      expect(row['created_at'], isNotNull);
    });

    test('a double duration is rejected by the STRICT table', () async {
      // Why the recorder's parameters are typed `int`: a stray double here is
      // a write that fails at runtime rather than a column that rounds.
      await expectLater(
        db.customUpdate(
          'INSERT INTO activity_events (kind, status, duration_ms, created_at) '
          'VALUES (?, ?, ?, ?)',
          variables: [
            Variable('triage'),
            Variable('ok'),
            Variable(1.5),
            Variable(_iso(Duration.zero)),
          ],
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(await rowCount(), 0);
    });
  });

  group('recentActivity', () {
    test('hands back the newest first', () async {
      for (final kind in ['first', 'second', 'third']) {
        await store.recordActivity(kind: kind, status: 'ok');
      }

      expect(
        [for (final row in await store.recentActivity()) row['kind']],
        ['third', 'second', 'first'],
      );
    });

    test('respects the limit, from the newest end', () async {
      for (final kind in ['first', 'second', 'third']) {
        await store.recordActivity(kind: kind, status: 'ok');
      }

      expect(
        [for (final row in await store.recentActivity(limit: 2)) row['kind']],
        ['third', 'second'],
      );
    });

    test('respects sinceIso', () async {
      await store.recordActivity(
        kind: 'old',
        status: 'ok',
        createdAt: _iso(const Duration(days: 10)),
      );
      await store.recordActivity(
        kind: 'recent',
        status: 'ok',
        createdAt: _iso(const Duration(hours: 1)),
      );

      final rows =
          await store.recentActivity(sinceIso: _iso(const Duration(days: 1)));

      expect([for (final row in rows) row['kind']], ['recent']);
    });
  });

  group('pruneActivity', () {
    test('deletes what is older than keepDays and keeps the rest', () async {
      await store.recordActivity(
        kind: 'ancient',
        status: 'ok',
        createdAt: _iso(const Duration(days: 40)),
      );
      await store.recordActivity(
        kind: 'recent',
        status: 'ok',
        createdAt: _iso(const Duration(days: 2)),
      );

      expect(await store.pruneActivity(), 1);

      expect([for (final row in await store.recentActivity()) row['kind']],
          ['recent']);
    });

    test('deletes past the row cap, oldest first', () async {
      for (var i = 0; i < 5; i++) {
        await store.recordActivity(kind: 'k$i', status: 'ok');
      }

      expect(await store.pruneActivity(maxRows: 2), 3);

      // The cap is what stops a first sync of a large mailbox from filling the
      // window, and it must take from the old end.
      expect(
        [for (final row in await store.recentActivity()) row['kind']],
        ['k4', 'k3'],
      );
    });

    test('both rules apply in one call', () async {
      await store.recordActivity(
        kind: 'ancient',
        status: 'ok',
        createdAt: _iso(const Duration(days: 40)),
      );
      for (var i = 0; i < 3; i++) {
        await store.recordActivity(kind: 'k$i', status: 'ok');
      }

      expect(await store.pruneActivity(maxRows: 2), 2);
      expect(
        [for (final row in await store.recentActivity()) row['kind']],
        ['k2', 'k1'],
      );
    });

    test('a table inside both rules loses nothing', () async {
      await store.recordActivity(kind: 'a', status: 'ok');
      await store.recordActivity(kind: 'b', status: 'ok');

      expect(await store.pruneActivity(), 0);
      expect(await rowCount(), 2);
    });
  });

  group('activityStats', () {
    String since = _iso(const Duration(days: 7));

    setUp(() => since = _iso(const Duration(days: 7)));

    test('sums ingest per source over the sync kinds only', () async {
      await store.recordActivity(
        kind: 'sync_mail',
        status: 'ok',
        source: 'email',
        count: 5,
      );
      await store.recordActivity(
        kind: 'sync_mail',
        status: 'ok',
        source: 'email',
        count: 3,
      );
      await store.recordActivity(
        kind: 'sync_teams',
        status: 'ok',
        source: 'teams',
        count: 2,
      );
      // Neither of these may reach the total: a failed sync ingested nothing,
      // and a triage row's count is not messages.
      await store.recordActivity(
        kind: 'sync_mail',
        status: 'error',
        source: 'email',
        count: 99,
      );
      await store.recordActivity(
        kind: 'triage',
        status: 'ok',
        source: 'email',
        count: 99,
      );

      expect(
        (await store.activityStats(sinceIso: since)).ingestedBySource,
        {'email': 8, 'teams': 2},
      );
    });

    test('counts the work kinds by status, errors apart from parks', () async {
      await store.recordActivity(kind: 'triage', status: 'ok');
      await store.recordActivity(kind: 'triage', status: 'ok');
      await store.recordActivity(kind: 'triage', status: 'error');
      await store.recordActivity(kind: 'triage', status: 'parked');
      await store.recordActivity(kind: 'extract', status: 'skipped');
      await store.recordActivity(kind: 'extract', status: 'retry');
      // Not an AI work kind: it belongs to neither count.
      await store.recordActivity(kind: 'sync_mail', status: 'ok', count: 1);

      final stats = await store.activityStats(sinceIso: since);

      expect(stats.byKind, {
        'triage': {'ok': 2, 'error': 1, 'parked': 1},
        'extract': {'skipped': 1, 'retry': 1},
      });
      // A park is a state, not a failure — a model server that is not running
      // must not read as six errors.
      expect(stats.errorCount, 1);
      expect(stats.aiItemCount, 6);
    });

    test('averages and medians the successful durations', () async {
      for (final ms in [10, 20, 30, 50]) {
        await store.recordActivity(kind: 'triage', status: 'ok', durationMs: ms);
      }
      // Neither counts: a failure's duration is the time spent failing, and a
      // row with no duration has nothing to average.
      await store.recordActivity(
          kind: 'triage', status: 'error', durationMs: 9000);
      await store.recordActivity(kind: 'triage', status: 'ok');

      final stats = await store.activityStats(sinceIso: since);

      expect(stats.avgMsByKind['triage'], 28);
      // An even-length list takes the mean of the middle pair.
      expect(stats.medianMsByKind['triage'], 25);
    });

    test('an odd-length list takes the middle value', () async {
      for (final ms in [10, 200, 30]) {
        await store.recordActivity(
            kind: 'extract', status: 'ok', durationMs: ms);
      }

      final stats = await store.activityStats(sinceIso: since);

      expect(stats.medianMsByKind['extract'], 30);
      expect(stats.avgMsByKind['extract'], 80);
    });

    test('everything before the window is invisible', () async {
      final old = _iso(const Duration(days: 30));
      await store.recordActivity(
        kind: 'sync_mail',
        status: 'ok',
        source: 'email',
        count: 100,
        createdAt: old,
      );
      await store.recordActivity(
        kind: 'triage',
        status: 'error',
        durationMs: 500,
        createdAt: old,
      );

      final stats = await store.activityStats(sinceIso: since);

      expect(stats.ingestedBySource, isEmpty);
      expect(stats.byKind, isEmpty);
      expect(stats.avgMsByKind, isEmpty);
      expect(stats.medianMsByKind, isEmpty);
      expect(stats.errorCount, 0);
      expect(stats.aiItemCount, 0);
    });

    test('an empty table reads as zeros rather than throwing', () async {
      final stats = await store.activityStats(sinceIso: since);

      expect(stats.ingestedBySource, isEmpty);
      expect(stats.aiItemCount, 0);
      expect(stats.errorCount, 0);
    });
  });
}
