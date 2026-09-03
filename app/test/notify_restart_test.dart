import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What survives a process ending, and what deliberately does not.
///
/// The state is on disk so a crash between "the model is still thinking" and
/// "tell the user" cannot lose the message and cannot announce it twice. The
/// arm is in memory so the next process starts quiet. Every test here runs two
/// coordinators over ONE database — the second one standing in for the next
/// launch of the app.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late DateTime now;

  final armedAt = DateTime.utc(2026, 9, 2, 12);

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    now = armedAt;
  });

  tearDown(() => db.close());

  ({NotificationCoordinator coordinator, List<MessageSettled> emitted})
      launch() {
    final emitted = <MessageSettled>[];
    final coordinator = NotificationCoordinator(store, clock: () => now);
    coordinator.notifications.listen(emitted.add);
    return (coordinator: coordinator, emitted: emitted);
  }

  Future<void> seedWorthy(
    String id, {
    String key = 'conv-1',
    String triageStatus = 'triaged',
    double? attentionScore = 0.9,
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': 'Thread $key',
      'state': 'needs_reply',
      'last_message_at': '2026-09-02T11:55:00.000Z',
    });
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Subject of $id',
      'received_at': '2026-09-02T11:55:00.000Z',
      'created_at': '2026-09-02T12:01:00.000Z',
    });
    await store.writeTriage(
      'email',
      id,
      status: triageStatus,
      result: const TriageResult(
        urgency: 'high',
        category: 'work',
        summary: 'needs an answer',
        needsAction: true,
        actionItems: [],
        replyExpected: true,
      ),
    );
    if (attentionScore != null) {
      await store.writeAttentionScore('email', key, attentionScore);
    }
  }

  Future<Map<String, Object?>> notifyRow(String id) async {
    final rows = await db.customSelect(
      'SELECT * FROM message_notify WHERE source_message_id = ?',
      variables: [Variable<String>(id)],
    ).get();
    return Map<String, Object?>.from(rows.single.data);
  }

  test('a message one process announced is not announced again by the next',
      () async {
    final first = launch();
    addTearDown(first.coordinator.dispose);
    first.coordinator.noteSyncCompleted();
    await seedWorthy('m-1');
    await first.coordinator.sweep();
    await pumpEventQueue();
    expect(first.emitted, hasLength(1));

    // The next launch: a fresh instance, a fresh arm, the same database. The
    // settled row is what keeps it quiet — `INSERT OR IGNORE` cannot reopen it.
    final second = launch();
    addTearDown(second.coordinator.dispose);
    second.coordinator.noteSyncCompleted();
    await second.coordinator.sweep();
    await pumpEventQueue();

    expect(second.emitted, isEmpty);
    expect(await notifyRow('m-1'), containsPair('state', 'notified'));
  });

  test('a row admitted by a process that died is settled by the next one',
      () async {
    // The crash window this whole table exists for: the message was admitted,
    // the model was still working, and the process went away before anything
    // could be decided.
    final first = launch();
    addTearDown(first.coordinator.dispose);
    first.coordinator.noteSyncCompleted();
    await seedWorthy('m-1', triageStatus: 'processing', attentionScore: null);
    await first.coordinator.sweep();
    await pumpEventQueue();
    expect(await notifyRow('m-1'), containsPair('state', 'pending'));
    expect(first.emitted, isEmpty);

    // The pipeline finishes under the new process, which never admitted this
    // row and does not need to have.
    await store.writeTriage('email', 'm-1', status: 'triaged');
    await store.writeAttentionScore('email', 'conv-1', 0.9);

    final second = launch();
    addTearDown(second.coordinator.dispose);
    second.coordinator.noteSyncCompleted();
    await second.coordinator.sweep();
    await second.coordinator.sweep();
    await pumpEventQueue();

    expect(second.emitted, hasLength(1));
    expect(second.emitted.single.sourceMessageId, 'm-1');
    expect(first.emitted, isEmpty);
  });

  test('a row whose deadline passed while nothing ran is closed in silence',
      () async {
    final first = launch();
    addTearDown(first.coordinator.dispose);
    first.coordinator.noteSyncCompleted();
    await seedWorthy('m-1', triageStatus: 'processing', attentionScore: null);
    await first.coordinator.sweep();
    expect(await notifyRow('m-1'), containsPair('state', 'pending'));

    // Hours later, a new launch. Whatever this message was, it is not news —
    // and start() closes it before anything of this process can emit.
    now = armedAt.add(const Duration(hours: 5));
    final second = launch();
    await second.coordinator.start();
    await pumpEventQueue();

    final row = await notifyRow('m-1');
    expect(row['state'], 'suppressed');
    expect(row['reason'], 'stale');
    expect(second.emitted, isEmpty);
    await second.coordinator.dispose();
  });

  test('a disposed coordinator sweeps without emitting', () async {
    // The provider that owns this disposes it on a hot restart while the drain
    // hook may still be holding a reference. Sweeping a dead coordinator has
    // to be a no-op rather than an "add after close".
    final only = launch();
    await only.coordinator.start();
    // Twice: a second start must not re-subscribe or restart the timer.
    await only.coordinator.start();
    only.coordinator.noteSyncCompleted();
    await seedWorthy('m-1');
    await only.coordinator.dispose();

    await only.coordinator.sweep();
    await pumpEventQueue();

    expect(only.emitted, isEmpty);
    expect(await notifyRow('m-1'), containsPair('state', 'notified'));
  });
}
