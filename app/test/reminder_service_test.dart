import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/reminder_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/tasks_backend.dart';
import 'package:bond_inbox/services/backend/tasks_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/reminders/reminder_service.dart';
import 'package:bond_inbox/services/reminders/tasks_availability.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The reminders carried by To Do: what the service sends, what it stores,
/// and what the poll's reconcile completes — over a fake backend that records
/// every call and an in-memory store.

/// A recording [TasksBackend]. Each scripted throw is used once, in order.
class _FakeTasks implements TasksBackend {
  final List<({String call, Map<String, Object?> args})> calls = [];

  /// Thrown by the next `createTask` calls, one each, before any succeed.
  final List<Object> createThrows = [];

  /// Run inside `completeTask` / `deleteTask` before they answer: the seam
  /// a test races the row through.
  Future<void> Function()? duringComplete;
  Future<void> Function()? duringDelete;

  /// Thrown by every `completeTask` / `deleteTask` / `flagMessages`.
  Object? completeThrows;
  Object? deleteThrows;
  Object? flagThrows;

  int _lists = 0;
  int _tasks = 0;

  List<Map<String, Object?>> argsOf(String call) => [
        for (final c in calls)
          if (c.call == call) c.args,
      ];

  @override
  Future<TodoList> ensureList({String name = 'Bond follow-ups'}) async {
    calls.add((call: 'ensureList', args: {'name': name}));
    _lists++;
    return TodoList(id: 'list-$_lists', name: name, created: true);
  }

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
    calls.add((
      call: 'createTask',
      args: {
        'listId': listId,
        'title': title,
        'bodyText': bodyText,
        'dueDate': dueDate,
        'dueTimeZone': dueTimeZone,
        'reminderAtUtc': reminderAtUtc,
        'status': status,
        'link': link,
      },
    ));
    if (createThrows.isNotEmpty) throw createThrows.removeAt(0);
    _tasks++;
    return TodoTask(
      id: 'task-$_tasks',
      listId: listId,
      title: title,
      status: status,
    );
  }

  @override
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  }) async {
    calls.add((call: 'completeTask', args: {'listId': listId, 'taskId': taskId}));
    await duringComplete?.call();
    if (completeThrows case final e?) throw e;
    return TodoTask(id: taskId, listId: listId, title: '', status: 'completed');
  }

  @override
  Future<void> deleteTask({
    required String listId,
    required String taskId,
  }) async {
    calls.add((call: 'deleteTask', args: {'listId': listId, 'taskId': taskId}));
    await duringDelete?.call();
    if (deleteThrows case final e?) throw e;
  }

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
  }) async {
    calls.add((
      call: 'flagMessages',
      args: {'ids': messageIds, 'status': status, 'dueUtc': dueUtc},
    ));
    if (flagThrows case final e?) throw e;
    return FlagOutcome(updated: messageIds.length);
  }
}

/// A store whose reminder insert always fails, as a full disk would.
class _FailingInsertStore extends MessageStore {
  _FailingInsertStore(super.db);

  @override
  Future<void> insertReminder(Reminder reminder) async =>
      throw StateError('disk full');
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeTasks tasks;
  late CalendarZone la;
  late DateTime now;
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
    // Whole seconds, so a message stamped at `now` in the store's `…Z` form
    // and the reminder's six-digit stamp compare as the same instant.
    final wall = DateTime.now().toUtc();
    now = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute,
        wall.second);
    availability = TasksAvailability.available;
    ids = 0;
  });

  tearDown(() => db.close());

  ReminderService service({
    DateTime Function()? clock,
    MessageStore? on,
    CalendarZone? zone,
  }) =>
      ReminderService(
        store: on ?? store,
        backend: tasks,
        zone: () => zone ?? la,
        log: ActivityLog(store),
        availability: () async => availability,
        clock: clock ?? () => now,
        newId: () => 'r${++ids}',
      );

  String stamp(DateTime t) =>
      '${t.toUtc().toIso8601String().split('.').first}Z';

  ReminderRequest request({
    ReminderKind kind = ReminderKind.replyBy,
    String key = 'c1',
    String anchor = 'm1',
    String? webLink = 'https://outlook.office365.com/owa/?ItemID=m1',
    String? graphId,
    String? body,
    DateTime? remindAt,
    ReminderOrigin from = ReminderOrigin.bar,
    String title = 'Reply to Dana: Q3 numbers',
  }) =>
      ReminderRequest(
        kind: kind,
        source: 'email',
        conversationKey: key,
        anchorMessageId: anchor,
        title: title,
        remindAtUtc: remindAt ?? now.add(const Duration(days: 1)),
        createdFrom: from,
        bodyText: body,
        anchorWebLink: webLink,
        anchorGraphId: graphId,
      );

  Future<void> message(
    String id, {
    String key = 'c1',
    String direction = 'inbound',
    required DateTime at,
    String? meta,
  }) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': direction,
        'subject': 'Q3 numbers',
        'from_address': direction == 'inbound' ? 'dana@contoso.com' : null,
        'received_at': stamp(at),
        'source_meta_json': meta,
      });

  Future<void> conversation({
    String key = 'c1',
    String state = 'needs_reply',
    DateTime? lastOutbound,
  }) =>
      store.upsertConversation({
        'source': 'email',
        'conversation_key': key,
        'subject': 'Q3 numbers',
        'state': state,
        'last_message_at': stamp(now),
        'last_inbound_at': stamp(now.subtract(const Duration(hours: 1))),
        'last_outbound_at': lastOutbound == null ? null : stamp(lastOutbound),
      });

  Future<List<Map<String, Object?>>> reminderRows() async => [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'reminder')
            {
              'status': row['status'],
              ...(jsonDecode(row['detail_json']! as String) as Map)
                  .cast<String, Object?>(),
            },
      ];

  group('create', () {
    test('persists the list id and reuses it', () async {
      final s = service();
      final remindAt = DateTime.utc(2026, 10, 9, 16);

      final first = await s.create(request(remindAt: remindAt));
      await s.create(request(key: 'c2'));

      expect(tasks.argsOf('ensureList'), hasLength(1));
      expect(await store.getPref(todoListIdKey), 'list-1');
      final sent = tasks.argsOf('createTask').first;
      expect(sent['listId'], 'list-1');
      expect(sent['title'], 'Reply to Dana: Q3 numbers');
      expect(sent['dueDate'], const CalendarDate(2026, 10, 9));
      expect(sent['dueTimeZone'], 'America/Los_Angeles');
      expect(sent['reminderAtUtc'], remindAt);
      expect(sent['status'], 'notStarted');
      final link = sent['link']! as TodoLink;
      expect(link.webUrl, 'https://outlook.office365.com/owa/?ItemID=m1');
      expect(link.displayName, 'Reply to Dana: Q3 numbers');
      expect(link.externalId, 'r1');

      expect(first.id, 'r1');
      final row = (await store.reminderById('r1'))!;
      expect(row.status, ReminderStatus.active);
      expect(row.kind, ReminderKind.replyBy);
      expect(row.createdFrom, ReminderOrigin.bar);
      expect(row.todoListId, 'list-1');
      expect(row.todoTaskId, 'task-1');
      expect(row.anchorMessageId, 'm1');
      expect(row.dueDate, '2026-10-09');
      expect(row.remindAtUtc, remindAt);
      expect(row.remindAt, MessageStore.isoStamp(remindAt));
      expect((await store.reminderById('r2'))!.todoListId, 'list-1');
      expect(await store.activeReminders(), hasLength(2));
      expect(await store.hasActiveReminder('email', 'c1'), isTrue);
      expect(
        await store.hasActiveReminder('email', 'c1',
            kind: ReminderKind.followUp),
        isFalse,
      );
    });

    test('a gone list is found again once, and the create retried once',
        () async {
      await store.setPref(todoListIdKey, 'stale');
      tasks.createThrows.add(const TasksGone());

      final r = await service().create(request());

      expect(tasks.argsOf('ensureList'), hasLength(1));
      expect(
        [for (final c in tasks.argsOf('createTask')) c['listId']],
        ['stale', 'list-1'],
      );
      expect(await store.getPref(todoListIdKey), 'list-1');
      expect(r.todoListId, 'list-1');
    });

    test('a list gone twice is not chased further, and writes no row',
        () async {
      await store.setPref(todoListIdKey, 'stale');
      tasks.createThrows.addAll([const TasksGone(), const TasksGone()]);

      await expectLater(
          service().create(request()), throwsA(isA<TasksGone>()));

      expect(tasks.argsOf('ensureList'), hasLength(1));
      expect(tasks.argsOf('createTask'), hasLength(2));
      expect(await store.activeReminders(), isEmpty);
    });

    test('a follow-up is waitingOnOthers and flags the sent mail', () async {
      final remindAt = now.add(const Duration(days: 2));
      final r = await service().create(request(
        kind: ReminderKind.followUp,
        anchor: 'sent-1',
        graphId: 'sent-1',
        remindAt: remindAt,
        from: ReminderOrigin.send,
      ));

      expect(tasks.argsOf('createTask').single['status'], 'waitingOnOthers');
      final flag = tasks.argsOf('flagMessages').single;
      expect(flag['ids'], ['sent-1']);
      expect(flag['status'], 'flagged');
      expect(flag['dueUtc'], remindAt);
      expect(r.flagMessageId, 'sent-1');
      expect((await store.reminderById(r.id))!.flagMessageId, 'sent-1');
      expect((await reminderRows()).single, {
        'status': 'ok',
        'action': 'create',
        'kind': 'follow_up',
        'created_from': 'send',
        'flagged': true,
        'linked': true,
      });
    });

    test('a flag that fails is logged and never fails the reminder',
        () async {
      tasks.flagThrows = const TasksTransient('Graph 503');

      final r = await service().create(request(
        kind: ReminderKind.followUp,
        anchor: 'sent-1',
        graphId: 'sent-1',
      ));

      expect(r.status, ReminderStatus.active);
      expect(r.flagMessageId, isEmpty);
      final rows = await reminderRows();
      expect(rows.map((e) => (e['action'], e['status'])),
          containsAll([('flag', 'error'), ('create', 'ok')]));
      expect(rows.firstWhere((e) => e['action'] == 'create')['flagged'],
          isFalse);
    });

    test('a local echo anchor is not flagged at create', () async {
      final r = await service().create(request(
        kind: ReminderKind.followUp,
        anchor: 'local:d1',
        graphId: 'local:d1',
      ));

      expect(tasks.argsOf('flagMessages'), isEmpty);
      expect(r.flagMessageId, isEmpty);
      expect(r.anchorMessageId, 'local:d1');
    });

    test('the link is omitted without a web link, or with a non-web one',
        () async {
      final s = service();
      await s.create(request(webLink: null));
      await s.create(request(webLink: 'javascript:alert(1)'));
      await s.create(request(webLink: ''));

      for (final sent in tasks.argsOf('createTask')) {
        expect(sent['link'], isNull);
      }
      for (final row in await reminderRows()) {
        expect(row['linked'], isFalse);
      }
    });

    test('the body is capped at 300 on a word', () async {
      final long = List.filled(80, 'numbers').join(' ');
      await service().create(request(body: long));

      final body = tasks.argsOf('createTask').single['bodyText']! as String;
      expect(body.length, lessThanOrEqualTo(ReminderService.bodyCap));
      expect(body.endsWith('numbers'), isTrue);
    });

    test('a long title is cut at a word to 200 characters', () async {
      final long = 'Reply to Dana: ${List.filled(60, 'numbers').join(' ')}';

      final r = await service().create(request(title: long));

      final sent = tasks.argsOf('createTask').single['title']! as String;
      expect(sent.length, lessThanOrEqualTo(ReminderService.titleCap));
      expect(long.startsWith(sent), isTrue);
      expect(sent.endsWith('numbers'), isTrue);
      expect(r.title, sent);
      expect((tasks.argsOf('createTask').single['link']! as TodoLink)
          .displayName, sent);
    });

    test('the due date and its zone come from the same zone', () async {
      // 20:00 on the 9th in Los Angeles, 03:00 on the 10th in UTC.
      final remindAt = DateTime.utc(2026, 10, 10, 3);

      await service().create(request(remindAt: remindAt));
      await service(zone: CalendarZone.utc())
          .create(request(key: 'c2', remindAt: remindAt));

      final sent = tasks.argsOf('createTask');
      expect(sent[0]['dueDate'], const CalendarDate(2026, 10, 9));
      expect(sent[0]['dueTimeZone'], 'America/Los_Angeles');
      expect(sent[1]['dueDate'], const CalendarDate(2026, 10, 10));
      expect(sent[1]['dueTimeZone'], CalendarZone.utc().iana);
    });

    test('a row that cannot be written takes its task back out of To Do',
        () async {
      final failing = _FailingInsertStore(db);

      await expectLater(
          service(on: failing).create(request()), throwsA(isA<StateError>()));

      expect(tasks.argsOf('createTask'), hasLength(1));
      expect(tasks.argsOf('deleteTask').single,
          {'listId': 'list-1', 'taskId': 'task-1'});
      expect(await store.activeReminders(), isEmpty);
    });

    test('a failed take-back still fails as the write failed', () async {
      tasks.deleteThrows = const TasksTransient('Graph 503');

      await expectLater(service(on: _FailingInsertStore(db)).create(request()),
          throwsA(isA<StateError>()));

      expect(tasks.argsOf('deleteTask'), hasLength(1));
    });

    test('two creates with no stored list make one ensure_list call',
        () async {
      final s = service();

      final both = await Future.wait(
          [s.create(request()), s.create(request(key: 'c2'))]);

      expect(tasks.argsOf('ensureList'), hasLength(1));
      expect(both[0].todoListId, 'list-1');
      expect(both[1].todoListId, 'list-1');
      expect(await store.getPref(todoListIdKey), 'list-1');
    });

    test('a missing permission throws before any call or row', () async {
      availability = TasksAvailability.scopeMissing;
      await expectLater(
          service().create(request()), throwsA(isA<TasksScopeMissing>()));

      availability = TasksAvailability.sdkMode;
      await expectLater(
          service().create(request()), throwsA(isA<TasksUnavailable>()));

      expect(tasks.calls, isEmpty);
      expect(await store.activeReminders(), isEmpty);
      expect(await reminderRows(), isEmpty);
    });

    test('a time that has passed is refused before any call or row',
        () async {
      // The bar's pills are worked out at build: a pane left open offers a
      // "5 pm today" that is now behind the clock.
      await expectLater(
        service().create(
            request(remindAt: now.subtract(const Duration(minutes: 1)))),
        throwsA(isA<ReminderPast>().having((e) => e.toString(), 'toast',
            'That time has passed. Nothing was set.')),
      );
      // The clock's own instant is not ahead either.
      await expectLater(service().create(request(remindAt: now)),
          throwsA(isA<ReminderPast>()));

      expect(tasks.calls, isEmpty);
      expect(await store.activeReminders(), isEmpty);
      expect(await reminderRows(), isEmpty);
    });

    test('a reconsent propagates and writes no row', () async {
      tasks.createThrows.add(const ReconsentRequired());

      await expectLater(
          service().create(request()), throwsA(isA<ReconsentRequired>()));
      expect(await store.activeReminders(), isEmpty);
    });
  });

  group('complete and cancel', () {
    test('complete marks the task, completes the flag, and the row is done',
        () async {
      final s = service();
      final r = await s.create(request(
          kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));

      await s.complete(r.id, reason: 'owner');

      expect(tasks.argsOf('completeTask').single,
          {'listId': 'list-1', 'taskId': 'task-1'});
      expect(tasks.argsOf('flagMessages').last['status'], 'complete');
      final row = (await store.reminderById(r.id))!;
      expect(row.status, ReminderStatus.done);
      expect(row.doneAt, MessageStore.isoStamp(now));
      expect((await reminderRows()).first,
          {'status': 'ok', 'action': 'complete', 'kind': 'follow_up',
              'reason': 'owner'});
    });

    test('a task already deleted in To Do still completes the row', () async {
      final s = service();
      final r = await s.create(request());
      tasks.completeThrows = const TasksGone();

      await s.complete(r.id, reason: 'done');

      expect((await store.reminderById(r.id))!.status, ReminderStatus.done);
    });

    test('cancel deletes the task, clears the flag, and the row is cancelled',
        () async {
      final s = service();
      final r = await s.create(request(
          kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));

      await s.cancel(r.id);

      expect(tasks.argsOf('deleteTask').single,
          {'listId': 'list-1', 'taskId': 'task-1'});
      final unflag = tasks.argsOf('flagMessages').last;
      expect(unflag['ids'], ['sent-1']);
      expect(unflag['status'], 'notflagged');
      expect((await store.reminderById(r.id))!.status,
          ReminderStatus.cancelled);
      expect(await store.activeReminders(), isEmpty);
      expect((await reminderRows()).first,
          {'status': 'ok', 'action': 'cancel', 'kind': 'follow_up'});
      // Cancelling twice is a no-op, not a second delete.
      await s.cancel(r.id);
      expect(tasks.argsOf('deleteTask'), hasLength(1));
    });

    test('completing a cancelled reminder records nothing', () async {
      final s = service();
      final r = await s.create(request());
      // The Undo lands while the task is being completed in To Do.
      tasks.duringComplete = () => s.cancel(r.id);

      await s.complete(r.id, reason: 'done');

      expect((await store.reminderById(r.id))!.status,
          ReminderStatus.cancelled);
      expect([for (final row in await reminderRows()) row['action']],
          ['cancel', 'create']);
    });

    test('cancelling a completed reminder records nothing', () async {
      final s = service();
      final r = await s.create(request());
      // The reconcile's complete lands while the task is being deleted.
      tasks.duringDelete = () => s.complete(r.id, reason: 'done');

      await s.cancel(r.id);

      expect((await store.reminderById(r.id))!.status, ReminderStatus.done);
      expect([for (final row in await reminderRows()) row['action']],
          ['complete', 'create']);
    });

    test('the store moves only an active row to done or cancelled', () async {
      final r = await service().create(request());
      final stamp = MessageStore.isoStamp(now);

      await store.updateReminder(r.id,
          status: ReminderStatus.cancelled, updatedAt: stamp);
      // A complete that lost the race: the row stays cancelled, and its
      // done_at is not written.
      await store.updateReminder(r.id,
          status: ReminderStatus.done, doneAt: stamp, updatedAt: stamp);

      var row = (await store.reminderById(r.id))!;
      expect(row.status, ReminderStatus.cancelled);
      expect(row.doneAt, isNull);
      // Nor back the other way.
      final d = await service().create(request(key: 'c2'));
      await store.updateReminder(d.id,
          status: ReminderStatus.done, doneAt: stamp, updatedAt: stamp);
      await store.updateReminder(d.id,
          status: ReminderStatus.cancelled, updatedAt: stamp);
      row = (await store.reminderById(d.id))!;
      expect(row.status, ReminderStatus.done);
      expect(row.doneAt, stamp);
    });
  });

  group('reconcile', () {
    test('completes a follow-up on a human reply, not on an auto-reply',
        () async {
      await conversation();
      final s = service();
      final r = await s.create(request(
          kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));
      // Before the reminder: never an answer to it.
      await message('old', at: now.subtract(const Duration(hours: 3)));
      await message('away',
          at: now.add(const Duration(minutes: 5)),
          meta: '{"auto_reply": true}');

      expect(await s.reconcile(), 0);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.active);

      await message('reply', at: now.add(const Duration(minutes: 30)));

      expect(await s.reconcile(), 1);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.done);
      expect(tasks.argsOf('completeTask'), hasLength(1));
      expect((await reminderRows()).first['reason'], 'reply');
    });

    test('a follow-up stands when the thread is Done — the send itself may '
        'have marked it done', () async {
      await conversation();
      final s = service();
      final r = await s.create(request(
          kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));

      await conversation(
          state: 'done', lastOutbound: now.add(const Duration(seconds: 1)));
      expect(await s.reconcile(), 0);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.active);
      expect(tasks.argsOf('completeTask'), isEmpty);
    });

    test('completes a reply-by when the thread is Done', () async {
      await conversation();
      final s = service();
      final r = await s.create(request());

      expect(await s.reconcile(), 0);

      await conversation(state: 'done');
      expect(await s.reconcile(), 1);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.done);
      expect((await reminderRows()).first['reason'], 'done');
    });

    test("completes a reply-by on the owner's reply after it was set",
        () async {
      // A reply the owner sent BEFORE setting the reminder is not an answer.
      await conversation(lastOutbound: now.subtract(const Duration(hours: 2)));
      final s = service();
      final r = await s.create(request());

      expect(await s.reconcile(), 0);

      await conversation(lastOutbound: now.add(const Duration(minutes: 10)));
      expect(await s.reconcile(), 1);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.done);
      expect((await reminderRows()).first['reason'], 'reply');
    });

    test('re-anchors a follow-up from its echo to the Sent Items copy, and '
        'flags it then', () async {
      await conversation();
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'local:d1',
        'internet_message_id': '<sent-1@contoso.com>',
        'conversation_key': 'c1',
        'direction': 'outbound',
        'subject': 'Q3 numbers',
        'received_at': stamp(now),
      });
      final s = service();
      final r = await s.create(request(
        kind: ReminderKind.followUp,
        anchor: 'local:d1',
        graphId: 'local:d1',
      ));

      // The echo still stands: nothing to move to yet.
      expect(await s.reconcile(), 0);
      expect(tasks.argsOf('flagMessages'), isEmpty);

      // The drain replaces the echo with the Sent Items copy.
      await store.deleteLocalEcho('email', '<sent-1@contoso.com>');
      await message('sent-graph-1', direction: 'outbound', at: now);
      // An older reply of the owner's on the same thread is not the copy.
      await message('sent-old',
          direction: 'outbound', at: now.subtract(const Duration(days: 2)));

      expect(await s.reconcile(), 1);
      final row = (await store.reminderById(r.id))!;
      expect(row.anchorMessageId, 'sent-graph-1');
      expect(row.flagMessageId, 'sent-graph-1');
      expect(row.status, ReminderStatus.active);
      final flag = tasks.argsOf('flagMessages').single;
      expect(flag['ids'], ['sent-graph-1']);
      expect(flag['status'], 'flagged');

      // Once moved, it stays put.
      expect(await s.reconcile(), 0);
    });

    test('a reminder 31 days past is marked done as expired with no To Do '
        'call', () async {
      await conversation();
      final r = await service().create(request(
          kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));
      final flags = tasks.argsOf('flagMessages').length;
      final later = r.remindAtUtc.add(const Duration(days: 31));

      expect(await service(clock: () => later).reconcile(), 1);

      final row = (await store.reminderById(r.id))!;
      expect(row.status, ReminderStatus.done);
      expect(row.doneAt, MessageStore.isoStamp(later));
      expect(tasks.argsOf('completeTask'), isEmpty);
      expect(tasks.argsOf('flagMessages'), hasLength(flags));
      expect((await reminderRows()).first,
          {'status': 'ok', 'action': 'complete', 'kind': 'follow_up',
              'reason': 'expired'});
    });

    test('a reminder 29 days past is still reconciled', () async {
      await conversation();
      final r = await service().create(request());
      final later = r.remindAtUtc.add(const Duration(days: 29));

      expect(await service(clock: () => later).reconcile(), 0);
      expect((await store.reminderById(r.id))!.status, ReminderStatus.active);

      await conversation(state: 'done');
      expect(await service(clock: () => later).reconcile(), 1);
      expect(tasks.argsOf('completeTask'), hasLength(1));
      expect((await reminderRows()).first['reason'], 'done');
    });

    test('does nothing while To Do is unavailable', () async {
      await conversation();
      final s = service();
      await s.create(request());
      await conversation(state: 'done');
      availability = TasksAvailability.scopeMissing;

      expect(await s.reconcile(), 0);
      expect(tasks.argsOf('completeTask'), isEmpty);
    });

    test('changes at most twenty rows a pass', () async {
      final s = service();
      for (var i = 0; i < 22; i++) {
        await conversation(key: 'c$i');
        await s.create(request(key: 'c$i'));
        await conversation(key: 'c$i', state: 'done');
      }

      expect(await s.reconcile(), ReminderService.reconcileCap);
      expect(await store.activeReminders(), hasLength(2));
      expect(await s.reconcile(), 2);
    });

    test('a failure on one reminder is retried next poll, the rest go on',
        () async {
      final s = service();
      await conversation(key: 'a');
      await s.create(request(key: 'a'));
      await conversation(key: 'a', state: 'done');
      tasks.completeThrows = const TasksTransient('Graph 503');

      expect(await s.reconcile(), 0);
      expect(await store.activeReminders(), hasLength(1));

      tasks.completeThrows = null;
      expect(await s.reconcile(), 1);
    });

    test('a reconsent propagates out of the pass', () async {
      final s = service();
      await conversation();
      await s.create(request());
      await conversation(state: 'done');
      tasks.completeThrows = const ReconsentRequired();

      await expectLater(s.reconcile(), throwsA(isA<ReconsentRequired>()));
    });
  });

  test('the activity rows carry enum words only', () async {
    final s = service();
    await conversation();
    final a = await s.create(request(body: 'Can you send the Q3 numbers?'));
    final b = await s.create(request(
        kind: ReminderKind.followUp, anchor: 'sent-1', graphId: 'sent-1'));
    tasks.flagThrows = const TasksTransient('x');
    await s.create(request(
        kind: ReminderKind.followUp, anchor: 'sent-2', graphId: 'sent-2'));
    await s.complete(a.id, reason: 'owner');
    await s.cancel(b.id);

    const words = {
      'ok', 'error', 'create', 'complete', 'cancel', 'flag', 'reply_by',
      'follow_up', 'deadline', 'custom', 'bar', 'send', 'auto', 'reply',
      'done', 'owner', true, false,
    };
    final rows = await reminderRows();
    expect(rows, hasLength(6));
    for (final row in rows) {
      for (final value in row.values) {
        expect(words, contains(value), reason: '$row');
      }
    }
    final raw = jsonEncode(await store.recentActivity());
    expect(raw, isNot(contains('Dana')));
    expect(raw, isNot(contains('Q3')));
    expect(raw, isNot(contains('outlook.office365.com')));
  });
}
