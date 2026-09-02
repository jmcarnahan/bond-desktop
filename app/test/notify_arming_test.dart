import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The one thing standing between this feature and a first launch that
/// announces an entire mailbox: **nothing is admitted until a sync of THIS
/// process has completed, and then only what arrived after it.**
///
/// The arm is held in memory rather than on disk on purpose. A fresh process
/// arms fresh, so everything the database already held when it armed is
/// backlog by definition — which is exactly the flood that must never be
/// announced, however many times the app is restarted.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late DateTime now;
  late NotificationCoordinator coordinator;
  late List<MessageSettled> emitted;

  final armedAt = DateTime.utc(2026, 9, 2, 12);

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    now = armedAt;
    emitted = [];
    coordinator = NotificationCoordinator(store, clock: () => now);
    coordinator.notifications.listen(emitted.add);
  });

  tearDown(() async {
    await coordinator.dispose();
    await db.close();
  });

  /// A message that would be announced on any sweep that admitted it: unread,
  /// triaged, high-scoring, with a reply expected.
  Future<void> seedWorthy(
    String id, {
    String key = 'conv-1',
    required String createdAt,
    String receivedAt = '2026-09-02T11:55:00.000Z',
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': 'Thread $key',
      'state': 'needs_reply',
      'last_message_at': receivedAt,
    });
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Subject of $id',
      'received_at': receivedAt,
      'created_at': createdAt,
    });
    await store.writeTriage(
      'email',
      id,
      status: 'triaged',
      result: const TriageResult(
        urgency: 'high',
        category: 'work',
        summary: 'needs an answer',
        needsAction: true,
        actionItems: [],
        replyExpected: true,
      ),
    );
    await store.writeAttentionScore('email', key, 0.9);
  }

  Future<List<String>> admittedIds() async {
    final rows = await db
        .customSelect('SELECT source_message_id FROM message_notify')
        .get();
    return [for (final row in rows) row.data['source_message_id'] as String];
  }

  Future<void> sweep() async {
    await coordinator.sweep();
    await pumpEventQueue();
  }

  test('an unarmed coordinator admits nothing at all', () async {
    await seedWorthy('m-1', createdAt: '2026-09-02T12:01:00.000Z');
    await sweep();

    expect(await admittedIds(), isEmpty);
    expect(emitted, isEmpty);
  });

  test('arming admits what arrived after it and nothing before', () async {
    await seedWorthy('m-old',
        key: 'conv-old', createdAt: '2026-09-02T11:59:00.000Z');
    coordinator.noteSyncCompleted();
    await seedWorthy('m-new',
        key: 'conv-new', createdAt: '2026-09-02T12:01:00.000Z');
    await sweep();

    expect(await admittedIds(), ['m-new']);
    expect(emitted.map((e) => e.sourceMessageId), ['m-new']);
  });

  test('a first-run backlog produces no notifications whatsoever', () async {
    // Forty messages, every one of them worth announcing on its merits. The
    // only thing keeping the user from forty toasts is that they were all
    // stored before the arm.
    for (var i = 0; i < 40; i++) {
      await seedWorthy('m-$i',
          key: 'conv-$i', createdAt: '2026-09-02T11:5${i % 10}:00.000Z');
    }
    coordinator.noteSyncCompleted();
    await sweep();
    now = armedAt.add(const Duration(minutes: 10));
    await sweep();

    expect(await admittedIds(), isEmpty);
    expect(emitted, isEmpty);
  });

  test('the arm is the FIRST sync, not the latest one', () async {
    coordinator.noteSyncCompleted();
    now = armedAt.add(const Duration(minutes: 2));
    await seedWorthy('m-1', createdAt: '2026-09-02T12:01:00.000Z');
    // A second sync must not move the arm forward — a message that landed
    // between the two syncs is new mail, not backlog.
    coordinator.noteSyncCompleted();
    await sweep();

    expect(await admittedIds(), ['m-1']);
  });

  test('a first connect that stores weeks of old chat announces none of it',
      () async {
    // The shape a first Teams connect makes: `created_at` of right now,
    // because it was just written, and a `received_at` from a fortnight ago.
    coordinator.noteSyncCompleted();
    await seedWorthy(
      'm-1',
      createdAt: '2026-09-02T12:01:00.000Z',
      receivedAt: '2026-08-19T09:00:00.000Z',
    );
    await sweep();

    expect(await admittedIds(), isEmpty);
    expect(emitted, isEmpty);
  });

  test('a message just inside the recency window is still new mail', () async {
    coordinator.noteSyncCompleted();
    await seedWorthy(
      'm-1',
      createdAt: '2026-09-02T12:01:00.000Z',
      receivedAt: '2026-09-02T07:00:00.000Z',
    );
    await sweep();

    expect(await admittedIds(), ['m-1']);
  });
}
