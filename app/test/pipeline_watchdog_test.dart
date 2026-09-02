import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The three things that make "no message is ever stuck" true of the rows
/// themselves: a claim nobody is holding comes back, a claim somebody IS
/// holding does not, and a row that ran out of retries gets one more a day
/// until a ceiling that is high enough to be an honest end.
///
/// All four windows are string comparisons against `updated_at`, so the tests
/// write timestamps directly rather than waiting for real minutes to pass.

String isoAgo(Duration ago) =>
    DateTime.now().toUtc().subtract(ago).toIso8601String();

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String triageStatus = 'processing',
    int attempts = 0,
    Duration age = Duration.zero,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': 'Subject',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'Body',
      'triage_status': triageStatus,
    });
    await db.customUpdate(
      'UPDATE messages SET triage_status = ?, triage_attempts = ?, '
      'updated_at = ? WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(triageStatus),
        Variable(attempts),
        Variable(isoAgo(age)),
        Variable(source),
        Variable(id),
      ],
    );
  }

  Future<void> seedWork(
    String kind,
    String entityId, {
    String source = 'email',
    String status = 'processing',
    int attempts = 0,
    Duration age = Duration.zero,
  }) async {
    await store.enqueueWork(kind, source, entityId);
    await db.customUpdate(
      'UPDATE work_items SET status = ?, attempts = ?, updated_at = ? '
      'WHERE task_kind = ? AND source = ? AND entity_id = ?',
      variables: [
        Variable(status),
        Variable(attempts),
        Variable(isoAgo(age)),
        Variable(kind),
        Variable(source),
        Variable(entityId),
      ],
    );
  }

  Future<Map<String, Object?>> messageRow(String id,
          {String source = 'email'}) async =>
      (await store.getMessageRow(source, id))!;

  Future<Map<String, Object?>> workRow(String kind, String entityId) async =>
      Map<String, Object?>.from(
        (await db
                .customSelect(
                  'SELECT * FROM work_items '
                  'WHERE task_kind = ? AND entity_id = ?',
                  variables: [Variable(kind), Variable(entityId)],
                )
                .get())
            .single
            .data,
      );

  group('reclaiming a stale claim', () {
    test('takes back only what is older than the window', () async {
      await seedMessage('old', age: const Duration(minutes: 30));
      await seedMessage('fresh', age: const Duration(seconds: 5));

      final reclaimed = await store.reclaimStaleTriage(
        staleBeforeIso: isoAgo(staleClaimAfter),
      );

      expect(reclaimed, 1);
      expect((await messageRow('old'))['triage_status'], 'pending');
      // A claim taken thirty seconds ago belongs to a worker that is very
      // probably still holding it.
      expect((await messageRow('fresh'))['triage_status'], 'processing');
    });

    test('does not spend an attempt — nothing about the row failed', () async {
      await seedMessage('m1', attempts: 1, age: const Duration(minutes: 30));

      await store.reclaimStaleTriage(staleBeforeIso: isoAgo(staleClaimAfter));

      expect((await messageRow('m1'))['triage_attempts'], 1);
    });

    test('leaves every status but processing alone', () async {
      await seedMessage('done', triageStatus: 'triaged', age: const Duration(hours: 2));
      await seedMessage('bad', triageStatus: 'error', age: const Duration(hours: 2));
      await seedMessage('waiting',
          triageStatus: 'pending', age: const Duration(hours: 2));

      expect(
        await store.reclaimStaleTriage(staleBeforeIso: isoAgo(staleClaimAfter)),
        0,
      );
      expect((await messageRow('done'))['triage_status'], 'triaged');
      expect((await messageRow('bad'))['triage_status'], 'error');
    });

    test('is scoped to the sources it was asked about', () async {
      await seedMessage('m1', age: const Duration(minutes: 30));
      await seedMessage('t1', source: 'teams', age: const Duration(minutes: 30));

      final reclaimed = await store.reclaimStaleTriage(
        staleBeforeIso: isoAgo(staleClaimAfter),
        sources: const ['teams'],
      );

      expect(reclaimed, 1);
      expect((await messageRow('m1'))['triage_status'], 'processing');
      expect(
        (await messageRow('t1', source: 'teams'))['triage_status'],
        'pending',
      );
    });

    test('the work queue behaves the same, across every kind', () async {
      await seedWork('extract', 'm1', age: const Duration(minutes: 30));
      await seedWork('storyline_sweep', 'sweep', age: const Duration(hours: 1));
      await seedWork('draft', 'conv-1', age: const Duration(seconds: 5));
      await seedWork('extract', 'm2',
          status: 'done', age: const Duration(hours: 1));

      final reclaimed =
          await store.reclaimStaleWork(staleBeforeIso: isoAgo(staleClaimAfter));

      expect(reclaimed, 2);
      expect((await workRow('extract', 'm1'))['status'], 'pending');
      expect((await workRow('storyline_sweep', 'sweep'))['status'], 'pending');
      expect((await workRow('draft', 'conv-1'))['status'], 'processing');
      expect((await workRow('extract', 'm2'))['status'], 'done');
    });
  });

  group('the heartbeat', () {
    test('keeps a long claim out of the watchdog\'s reach', () async {
      // A storyline sweep is one item that legitimately runs for minutes.
      await seedWork('storyline_sweep', 'sweep', age: const Duration(hours: 1));

      await store.touchWork('storyline_sweep', 'email', 'sweep');

      expect(
        await store.reclaimStaleWork(staleBeforeIso: isoAgo(staleClaimAfter)),
        0,
      );
      expect((await workRow('storyline_sweep', 'sweep'))['status'], 'processing');
    });

    test('does the same for a slow message', () async {
      await seedMessage('m1', age: const Duration(minutes: 30));

      await store.touchTriage('email', 'm1');

      expect(
        await store.reclaimStaleTriage(staleBeforeIso: isoAgo(staleClaimAfter)),
        0,
      );
    });

    test('moves nothing but updated_at, and only while claimed', () async {
      await seedMessage('m1', attempts: 2, age: const Duration(minutes: 30));
      await seedMessage('done',
          triageStatus: 'triaged', age: const Duration(minutes: 30));
      final before = (await messageRow('done'))['updated_at'];

      await store.touchTriage('email', 'm1');
      await store.touchTriage('email', 'done');

      final row = await messageRow('m1');
      expect(row['triage_status'], 'processing');
      expect(row['triage_attempts'], 2);
      // A row that is not claimed is not being worked on, and a heartbeat for
      // it would be a lie.
      expect((await messageRow('done'))['updated_at'], before);
    });
  });

  group('releasing a claim', () {
    test('hands the row back without spending an attempt', () async {
      await seedWork('extract', 'm1', attempts: 1);

      await store.releaseWorkClaim('extract', 'email', 'm1');

      final row = await workRow('extract', 'm1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 1);
    });

    test('cannot reopen an item that already finished', () async {
      await seedWork('extract', 'm1', status: 'done');
      await seedMessage('m2', triageStatus: 'triaged');

      await store.releaseWorkClaim('extract', 'email', 'm1');
      await store.releaseTriageClaim('email', 'm2');

      // The guard is what keeps a dispose racing a result from re-running a
      // model call and resurrecting the CTA a reply had cleared.
      expect((await workRow('extract', 'm1'))['status'], 'done');
      expect((await messageRow('m2'))['triage_status'], 'triaged');
    });
  });

  group('one more try a day', () {
    test('revives only what is past the ordinary ceiling and gone cold',
        () async {
      // Below six is [reviveErroredTriage]'s business, not this one's.
      await seedMessage('young', triageStatus: 'error', attempts: 5, age: const Duration(days: 2));
      await seedMessage('ready', triageStatus: 'error', attempts: 6, age: const Duration(days: 2));
      await seedMessage('recent', triageStatus: 'error', attempts: 7, age: const Duration(hours: 1));
      await seedMessage('dead',
          triageStatus: 'error',
          attempts: terminalMaxAttempts,
          age: const Duration(days: 2));

      final revived = await store.reviveTerminalTriage(
        olderThanIso: isoAgo(terminalRetryAfter),
      );

      expect(revived, 1);
      expect((await messageRow('ready'))['triage_status'], 'pending');
      expect((await messageRow('young'))['triage_status'], 'error');
      // One retry per row per DAY: the failing write restamps `updated_at`,
      // so a row revived an hour ago is out of reach.
      expect((await messageRow('recent'))['triage_status'], 'error');
      expect((await messageRow('dead'))['triage_status'], 'error');
    });

    test('and leaves the attempt count where it was', () async {
      await seedMessage('m1',
          triageStatus: 'error', attempts: 8, age: const Duration(days: 2));

      await store.reviveTerminalTriage(olderThanIso: isoAgo(terminalRetryAfter));

      expect((await messageRow('m1'))['triage_attempts'], 8);
    });

    test('the work queue has the same bounds, and can be narrowed to a kind',
        () async {
      await seedWork('extract', 'm1',
          status: 'error', attempts: 6, age: const Duration(days: 2));
      await seedWork('draft', 'conv-1',
          status: 'error', attempts: 6, age: const Duration(days: 2));
      await seedWork('extract', 'm2',
          status: 'error',
          attempts: terminalMaxAttempts,
          age: const Duration(days: 2));

      final revived = await store.reviveTerminalWork(
        olderThanIso: isoAgo(terminalRetryAfter),
        kind: 'extract',
      );

      expect(revived, 1);
      expect((await workRow('extract', 'm1'))['status'], 'pending');
      expect((await workRow('draft', 'conv-1'))['status'], 'error');
      expect((await workRow('extract', 'm2'))['status'], 'error');
    });
  });

  group('pipelineHealth', () {
    test('counts each bucket, and dead is the subset nothing will retry',
        () async {
      await seedMessage('p1', triageStatus: 'pending');
      await seedMessage('p2', triageStatus: 'pending');
      await seedMessage('c1');
      await seedMessage('e1', triageStatus: 'error', attempts: 6);
      await seedMessage('e2',
          triageStatus: 'error', attempts: terminalMaxAttempts);
      await seedWork('extract', 'w1', status: 'pending');
      await seedWork('extract', 'w2');
      await seedWork('draft', 'w3',
          status: 'error', attempts: terminalMaxAttempts + 1);

      final health = await store.pipelineHealth();

      expect(health.triagePending, 2);
      expect(health.triageProcessing, 1);
      expect(health.triageError, 2);
      expect(health.triageDead, 1);
      expect(health.workPending, 1);
      expect(health.workProcessing, 1);
      expect(health.workError, 1);
      expect(health.workDead, 1);
    });

    test('the oldest claim spans both queues, and is null when none is held',
        () async {
      expect((await store.pipelineHealth()).oldestClaimIso, isNull);

      await seedMessage('m1', age: const Duration(minutes: 3));
      await seedWork('extract', 'w1', age: const Duration(minutes: 40));
      await seedWork('draft', 'w2', status: 'done', age: const Duration(days: 1));

      final oldest = (await store.pipelineHealth()).oldestClaimIso;

      // Whichever queue holds it, an old claim means the same thing — and a
      // finished row is not a claim at all.
      expect(oldest, isNotNull);
      expect(
        DateTime.parse(oldest!).isBefore(
          DateTime.now().toUtc().subtract(const Duration(minutes: 30)),
        ),
        isTrue,
      );
    });

    test('counts only the sources it was asked about', () async {
      await seedMessage('t1', source: 'teams', triageStatus: 'pending');

      expect((await store.pipelineHealth(sources: const ['email'])).triagePending, 0);
      expect((await store.pipelineHealth()).triagePending, 1);
    });
  });
}
