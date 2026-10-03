import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/reminder_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/tasks_backend.dart';
import 'package:bond_inbox/services/backend/tasks_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/reminders/reminder_planner.dart';
import 'package:bond_inbox/services/reminders/reminder_service.dart';
import 'package:bond_inbox/services/reminders/tasks_availability.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// The deadline planner: a Needs You thread with a deadline gets ONE To Do
/// reminder at 09:00 on that day, and nothing else gets one.
///
/// The clock is fixed (Wednesday 2026-10-07, mid-afternoon in Los Angeles)
/// and every mail stamp is chosen to fall on the same day in Los Angeles and
/// in UTC, because `parseDeadline` anchors to the device's own day.

/// A recording [TasksBackend] that accepts everything. Duplicated per test
/// file on purpose.
class _FakeTasks implements TasksBackend {
  final List<({DateTime? reminderAtUtc, String title})> created = [];

  /// Every title `createTask` was called with, thrown on or not.
  final List<String> attempted = [];

  /// What `createTask` throws for a title, when it throws.
  Object? Function(String title)? throwFor;

  @override
  Future<TodoList> ensureList({String name = 'Bond follow-ups'}) async =>
      TodoList(id: 'list-1', name: name);

  @override
  Future<TodoTask> createTask({
    required String listId,
    required String title,
    String? bodyText,
    CalendarDate? dueDate,
    String? dueTimeZone,
    DateTime? reminderAtUtc,
    String status = 'notStarted',
    String importance = 'normal',
    TodoLink? link,
  }) async {
    attempted.add(title);
    if (throwFor?.call(title) case final e?) throw e;
    created.add((reminderAtUtc: reminderAtUtc, title: title));
    return TodoTask(
      id: 'task-${created.length}',
      listId: listId,
      title: title,
      status: status,
    );
  }

  @override
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  }) async =>
      TodoTask(id: taskId, listId: listId, title: '', status: 'completed');

  @override
  Future<void> deleteTask({
    required String listId,
    required String taskId,
  }) async {}

  @override
  Future<List<TodoTask>> listTasks({
    required String listId,
    String? status,
    String? externalId,
  }) async =>
      const [];

  @override
  Future<FlagOutcome> flagMessages(
    List<String> messageIds, {
    required String status,
    DateTime? dueUtc,
  }) async =>
      FlagOutcome(updated: messageIds.length);
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeTasks tasks;
  late CalendarZone la;
  // Wednesday 2026-10-07, 15:00 in Los Angeles.
  final now = DateTime.utc(2026, 10, 7, 22);
  var enabled = true;
  var availability = TasksAvailability.available;
  var ids = 0;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    tasks = _FakeTasks();
    enabled = true;
    availability = TasksAvailability.available;
    ids = 0;
  });

  tearDown(() => db.close());

  ReminderPlanner planner({DateTime? clock}) {
    final service = ReminderService(
      store: store,
      backend: tasks,
      zone: () => la,
      log: ActivityLog(store),
      availability: () async => availability,
      clock: () => clock ?? now,
      newId: () => 'r${++ids}',
    );
    return ReminderPlanner(
      store: store,
      service: service,
      enabled: () => enabled,
      availability: () async => availability,
      clock: () => clock ?? now,
    );
  }

  /// A thread whose newest inbound message, received at [receivedAt], named
  /// [deadline], decided at [p].
  Future<void> seed(
    String key, {
    String deadline = 'by Friday',
    double p = 0.9,
    String state = 'needs_reply',
    String receivedAt = '2026-10-07T20:00:00Z',
    String subject = 'Q3 numbers',
  }) async {
    final id = '$key-m1';
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Reyes',
      'from_address': 'dana@contoso.com',
      'received_at': receivedAt,
      'body_text': 'Can you send the Q3 numbers by Friday?',
      'source_meta_json':
          '{"web_link": "https://outlook.office365.com/owa/?ItemID=$id"}',
    });
    await writeTriaged(store, 'email', id,
        status: 'triaged', replyExpected: true, deadline: deadline);
    await store.writeNeedsYouP('email', id, p: p);
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"Dana Reyes","email":"dana@contoso.com"}]',
      'state': state,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
  }

  Future<int> plan({DateTime? clock}) async => planner(clock: clock).plan(
        zone: la,
        needsYouThreshold: 0.35,
        conversations: await store.loadConversations(),
      );

  test('a Needs You thread due Friday gets one reminder at 09:00 that Friday',
      () async {
    await seed('c1');

    expect(await plan(), 1);

    final row = (await store.activeReminders()).single;
    expect(row.kind, ReminderKind.deadline);
    expect(row.createdFrom, ReminderOrigin.auto);
    expect(row.conversationKey, 'c1');
    // 09:00 PDT on Friday 2026-10-09.
    expect(row.remindAtUtc, DateTime.utc(2026, 10, 9, 16));
    expect(row.dueDate, '2026-10-09');
    expect(row.title, 'Reply to Dana Reyes: Q3 numbers');
    expect(row.anchorMessageId, 'c1-m1');
    expect(tasks.created.single.reminderAtUtc, DateTime.utc(2026, 10, 9, 16));

    // Not a second one on the next pass.
    expect(await plan(), 0);
    expect(await store.activeReminders(), hasLength(1));
    expect(tasks.created, hasLength(1));
  });

  test('a deadline today whose 09:00 has passed is skipped', () async {
    await seed('c1', deadline: 'today', receivedAt: '2026-10-07T16:30:00Z');

    // 10:00 in Los Angeles: 09:00 is gone.
    expect(await plan(clock: DateTime.utc(2026, 10, 7, 17)), 0);
    expect(tasks.created, isEmpty);
  });

  test('a deadline today before its 09:00 is reminded that morning', () async {
    await seed('c1', deadline: 'today', receivedAt: '2026-10-07T13:00:00Z');

    // 07:00 in Los Angeles.
    expect(await plan(clock: DateTime.utc(2026, 10, 7, 14)), 1);
    expect((await store.activeReminders()).single.remindAtUtc,
        DateTime.utc(2026, 10, 7, 16));
  });

  test('the switch off plans nothing', () async {
    await seed('c1');
    enabled = false;

    expect(await plan(), 0);
    expect(tasks.created, isEmpty);
  });

  test('To Do unavailable plans nothing', () async {
    await seed('c1');
    availability = TasksAvailability.scopeMissing;

    expect(await plan(), 0);
    expect(await store.activeReminders(), isEmpty);
  });

  test('at most five a pass; the rest on the next', () async {
    for (var i = 0; i < 7; i++) {
      await seed('c$i');
    }

    expect(await plan(), ReminderPlanner.perPass);
    expect(await plan(), 2);
    expect(await plan(), 0);
  });

  test('a Done, a Later, a below-the-slider and an already-reminded thread '
      'are skipped', () async {
    await seed('done', state: 'done');
    await seed('later');
    await store.setConversationBucket('email', 'later',
        bucket: 'later', reason: 'user');
    await seed('low', p: 0.1);
    await seed('held');
    await store.insertReminder(Reminder(
      id: 'existing',
      kind: ReminderKind.replyBy,
      source: 'email',
      conversationKey: 'held',
      title: 'Reply to Dana Reyes: Q3 numbers',
      remindAt: MessageStore.isoStamp(DateTime.utc(2026, 10, 8, 16)),
      status: ReminderStatus.active,
      createdFrom: ReminderOrigin.bar,
      createdAt: MessageStore.isoStamp(now),
      updatedAt: MessageStore.isoStamp(now),
    ));

    expect(await plan(), 0);
    expect(tasks.created, isEmpty);
  });

  test('a past deadline or no deadline is skipped', () async {
    await seed('past', deadline: '2026-10-01');
    await seed('none', deadline: '');
    await seed('plan', deadline: 'Day 1');

    expect(await plan(), 0);
  });

  group('a failing create', () {
    const bad = 'Reply to Dana Reyes: Refused';

    test('a thread To Do refuses is skipped and the next one is planned',
        () async {
      await seed('bad', subject: 'Refused');
      await seed('good', subject: 'Accepted');
      tasks.throwFor = (title) => title == bad
          ? const TasksRefused('invalid_options', 'x')
          : null;

      expect(await plan(), 1);

      expect(tasks.attempted, contains(bad));
      final row = (await store.activeReminders()).single;
      expect(row.conversationKey, 'good');
      expect(await store.hasActiveReminder('email', 'bad'), isFalse);
    });

    test('a refused thread is not retried on the next pass', () async {
      await seed('bad', subject: 'Refused');
      tasks.throwFor = (title) => title == bad
          ? const TasksRefused('invalid_options', 'x')
          : null;
      final p = planner();
      Future<int> again() async => p.plan(
            zone: la,
            needsYouThreshold: 0.35,
            conversations: await store.loadConversations(),
          );

      expect(await again(), 0);
      expect(tasks.attempted, [bad]);

      expect(await again(), 0);
      expect(tasks.attempted, [bad]);
    });

    test('a transient failure still ends the pass and propagates', () async {
      await seed('c1');
      await seed('c2');
      tasks.throwFor = (_) => const TasksTransient('Graph 503');

      await expectLater(plan(), throwsA(isA<TasksTransient>()));

      expect(tasks.attempted, hasLength(1));
      expect(await store.activeReminders(), isEmpty);
    });
  });
}
