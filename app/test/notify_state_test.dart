import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The one rule the `message_notify` table exists to enforce: **a message is
/// announced once or not at all.**
///
/// The store half of that is three statements — admission, which opens a row
/// and can never reopen one; the settle, which leaves `pending` exactly once
/// no matter how many callers race for it; and the expiry, which closes what a
/// dead process left behind WITHOUT anything being emitted for it. Everything
/// this file pins is one of those three.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  // Fixed rather than relative: every admission bound is a string comparison,
  // and a test that computes its own "now" hides which side of the bound it
  // meant to be on.
  const armedAt = '2026-09-02T12:00:00.000Z';
  const recencyFloor = '2026-09-02T06:00:00.000Z';
  const deadline = '2026-09-02T12:06:00.000Z';
  const createdAfterArm = '2026-09-02T12:01:00.000Z';
  const receivedRecently = '2026-09-02T11:55:00.000Z';

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String key = 'conv-1',
    String direction = 'inbound',
    String triageStatus = 'pending',
    int isRead = 0,
    String? createdAt = createdAfterArm,
    String? receivedAt = receivedRecently,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'subject': 'Subject of $id',
      'received_at': receivedAt,
      'is_read': isRead,
      'triage_status': triageStatus,
      'created_at': createdAt,
    });
  }

  Future<int> admit() => store.admitNotifyCandidates(
        armedAtIso: armedAt,
        recencyFloorIso: recencyFloor,
        deadlineIso: deadline,
      );

  Future<List<Map<String, Object?>>> notifyRows() async {
    final rows = await db.customSelect('SELECT * FROM message_notify').get();
    return [for (final row in rows) Map<String, Object?>.from(row.data)];
  }

  group('admission', () {
    test('opens one pending row per eligible message', () async {
      await seedMessage('m-1');
      await seedMessage('m-2');

      expect(await admit(), 2);
      final rows = await notifyRows();
      expect(rows, hasLength(2));
      expect(rows.first['state'], 'pending');
      expect(rows.first['reason'], isNull);
      expect(rows.first['settled_at'], isNull);
      expect(rows.first['deadline_at'], deadline);
      expect(rows.first['conversation_key'], 'conv-1');
    });

    test('is idempotent — a second pass admits nothing new', () async {
      await seedMessage('m-1');
      expect(await admit(), 1);
      expect(await admit(), 0);
      expect(await notifyRows(), hasLength(1));
    });

    test('cannot resurrect a settled row', () async {
      // The whole point of `INSERT OR IGNORE` on the message's own key: a
      // message that has already been decided stays decided, however many
      // sweeps run over it afterwards.
      await seedMessage('m-1');
      await admit();
      await store.settleNotify('email', 'm-1',
          state: 'suppressed', reason: 'read');

      expect(await admit(), 0);
      final row = (await notifyRows()).single;
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'read');
    });

    test('skips outbound messages', () async {
      await seedMessage('m-1', direction: 'outbound');
      expect(await admit(), 0);
    });

    test('skips messages the gate already threw out', () async {
      await seedMessage('m-1', triageStatus: 'skipped');
      expect(await admit(), 0);
    });

    test('skips messages already read', () async {
      await seedMessage('m-1', isRead: 1);
      expect(await admit(), 0);
    });

    test('skips the backlog stored before the arm', () async {
      // `created_at` at the arming instant is not "after" it: the backlog is
      // everything the database already held when the first sync completed.
      await seedMessage('m-1', createdAt: armedAt);
      await seedMessage('m-2', createdAt: '2026-09-02T11:59:59.999Z');
      expect(await admit(), 0);
    });

    test('skips old mail that a fresh connect only just stored', () async {
      // The first Teams connect writes weeks of chat with a `created_at` of
      // right now. Only the message's own timestamp shows that it is old.
      await seedMessage('m-1', receivedAt: '2026-08-20T09:00:00.000Z');
      expect(await admit(), 0);
    });

    test('skips a message with no received_at at all', () async {
      // `NULL >= ?` is NULL, which is not true — and that is the wanted
      // behaviour: a message with no time on it cannot be shown to be recent.
      await seedMessage('m-1', receivedAt: null);
      expect(await admit(), 0);
    });

    test('admits nothing when there are no sources', () async {
      await seedMessage('m-1');
      expect(
        await store.admitNotifyCandidates(
          armedAtIso: armedAt,
          recencyFloorIso: recencyFloor,
          deadlineIso: deadline,
          sources: const [],
        ),
        0,
      );
      expect(await notifyRows(), isEmpty);
    });
  });

  group('settle', () {
    test('the first caller wins and the second is told it lost', () async {
      await seedMessage('m-1');
      await admit();

      expect(
        await store.settleNotify('email', 'm-1',
            state: 'notified', reason: 'settled'),
        isTrue,
      );
      // The emission is gated on this `false`, which is what keeps two
      // concurrent settles — two app instances, a sweep racing the drain hook
      // — from both announcing the same message.
      expect(
        await store.settleNotify('email', 'm-1',
            state: 'suppressed', reason: 'read'),
        isFalse,
      );

      final row = (await notifyRows()).single;
      expect(row['state'], 'notified');
      expect(row['reason'], 'settled');
      expect(row['settled_at'], isNotNull);
    });

    test('a row nobody admitted cannot be settled', () async {
      expect(
        await store.settleNotify('email', 'ghost',
            state: 'notified', reason: 'settled'),
        isFalse,
      );
    });

    test('a settled row leaves openNotifyCandidates', () async {
      await seedMessage('m-1');
      await seedMessage('m-2');
      await admit();
      await store.settleNotify('email', 'm-1',
          state: 'notified', reason: 'settled');

      final open = await store.openNotifyCandidates();
      expect(open.map((r) => r['source_message_id']), ['m-2']);
    });
  });

  group('expiry', () {
    test('closes only pending rows whose deadline has passed', () async {
      await seedMessage('m-past');
      await seedMessage('m-future');
      await seedMessage('m-settled');
      await store.admitNotifyCandidates(
        armedAtIso: armedAt,
        recencyFloorIso: recencyFloor,
        deadlineIso: '2026-09-02T12:06:00.000Z',
      );
      // Push one row's deadline out and settle another, so the three rows
      // differ in exactly the two things the statement looks at.
      await db.customUpdate(
        "UPDATE message_notify SET deadline_at = '2026-09-02T23:00:00.000Z' "
        "WHERE source_message_id = 'm-future'",
      );
      await store.settleNotify('email', 'm-settled',
          state: 'notified', reason: 'settled');

      expect(
        await store.expireStaleNotify(nowIso: '2026-09-02T13:00:00.000Z'),
        1,
      );

      final byId = {
        for (final row in await notifyRows()) row['source_message_id']: row,
      };
      expect(byId['m-past']!['state'], 'suppressed');
      expect(byId['m-past']!['reason'], 'stale');
      expect(byId['m-past']!['settled_at'], isNotNull);
      expect(byId['m-future']!['state'], 'pending');
      expect(byId['m-settled']!['reason'], 'settled');
    });
  });

  group('reads', () {
    test('recentNotified returns notified rows only, newest first', () async {
      await seedMessage('m-1');
      await seedMessage('m-2');
      await seedMessage('m-3');
      await admit();
      await store.settleNotify('email', 'm-1',
          state: 'notified', reason: 'settled');
      await store.settleNotify('email', 'm-2',
          state: 'suppressed', reason: 'read');
      await store.settleNotify('email', 'm-3',
          state: 'notified', reason: 'deadline');

      final recent = await store.recentNotified(sinceIso: armedAt);
      expect(recent.map((r) => r['source_message_id']), ['m-3', 'm-1']);
    });

    test('recentNotified excludes anything settled before the window',
        () async {
      await seedMessage('m-1');
      await admit();
      await store.settleNotify('email', 'm-1',
          state: 'notified', reason: 'settled');

      expect(
        await store.recentNotified(sinceIso: '2099-01-01T00:00:00.000Z'),
        isEmpty,
      );
    });
  });

  test('wipeAll empties message_notify', () async {
    await seedMessage('m-1');
    await admit();
    expect(await notifyRows(), isNotEmpty);

    await store.wipeAll();
    expect(await notifyRows(), isEmpty);
  });
}
