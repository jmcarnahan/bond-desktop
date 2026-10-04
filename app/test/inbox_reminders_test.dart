import 'dart:async' show Completer;

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart' show CalendarDate;
import 'package:bond_inbox/models/message_models.dart' show Conversation;
import 'package:bond_inbox/models/reminder_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/tasks_backend.dart';
import 'package:bond_inbox/services/backend/tasks_errors.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/reminders/business_days.dart';
import 'package:bond_inbox/services/reminders/reminder_planner.dart';
import 'package:bond_inbox/services/reminders/reminder_service.dart';
import 'package:bond_inbox/services/reminders/tasks_availability.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// The three ways a reminder is made, inside the assembled screen: Remind me
/// on the thread bar, Follow up at send, and the poll's tend — plus the Day
/// row a reminder draws. To Do is a recording fake; the carrier is made
/// AVAILABLE by overriding both `tasksBackendProvider` and
/// `tasksAvailabilityProvider` (the default under a test is unavailable).

class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureBodiesFor(
    String conversationKey,
    List<String> sourceMessageIds,
  ) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A mail backend that sends every reply it is given.
class _SendingMail implements MailBackend {
  final List<String> bodies = [];

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async =>
      const {'id': 'graph-draft-1'};

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    bodies.add(text);
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      SentDraft(draftId: draftId, subject: 'Re: Invoice 4471');

  @override
  Future<void> deleteDraft(String draftId) async {}

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A calendar tick that never answers, so the screen's calendar stays as the
/// overrides say.
class _QuietCalendarSync extends CalendarSync {
  _QuietCalendarSync(MessageStore store, CalendarStore calendar)
      : super(const UnavailableCalendarBackend(), store, calendar);

  final Completer<CalendarSyncOutcome> gate = Completer();

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) => gate.future;
}

/// Everything a send needs, so the composer is armed rather than offering a
/// copy.
const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite '
    'https://graph.microsoft.com/Mail.Send';

void main() {
  setUpAll(initCalendarZones);

  late BondDatabase db;
  late MessageStore store;
  late CalendarZone la;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  tearDown(() async {
    InboxScreen.followUpWaitOverride = null;
    await db.close();
  });

  String ago(int hours) =>
      DateTime.now().toUtc().subtract(Duration(hours: hours)).toIso8601String();

  Future<void> pumps(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> seedInvoice() async {
    final received = ago(2);
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'c2-m1',
      'conversation_key': 'c2',
      'direction': 'inbound',
      'subject': 'Invoice 4471',
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': received,
      'body_text': 'Could you sign the invoice by Friday?',
    });
    await seedNeedsYou(store, 'email', 'c2-m1');
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c2',
      'subject': 'Invoice 4471',
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
      'state': 'needs_reply',
      'cta_text': 'Sign the invoice',
      'cta_urgency': 'normal',
      'last_message_at': received,
      'last_inbound_at': received,
    });
  }

  /// The screen on the SDK backend with a grant that can send, the zone
  /// pinned, the calendar shown, and To Do [available] (a recording
  /// [tasks] backend) or [unavailable] as said.
  Future<void> pumpScreen(
    WidgetTester tester, {
    _RecordingTasks? tasks,
    TasksAvailability availability = TasksAvailability.available,
    _SendingMail? mail,
    RailSection section = RailSection.needsYou,
    List<Override> overrides = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _sendGrant;
    final auth = GraphAuth(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
      store: tokens,
    );
    await store.setPref(backendModeKey, backendModeSdk);
    await store.setPref(processingOnKey, 'false');
    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        keepingDecisionClient(),
        noCommandHeads(),
        initialSectionProvider.overrideWithValue(section),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        calendarSyncProvider.overrideWith(
            (ref) => _QuietCalendarSync(store, CalendarStore(db))),
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.available),
        calendarZoneProvider.overrideWith((ref) async => la),
        if (mail != null) mailBackendProvider.overrideWithValue(mail),
        if (tasks != null) tasksBackendProvider.overrideWithValue(tasks),
        tasksAvailabilityProvider.overrideWith((ref) async => availability),
        ...overrides,
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await pumps(tester);
  }

  Future<void> openInvoice(WidgetTester tester) async {
    await tester.tap(find.text('Invoice 4471').first);
    await pumps(tester);
    // The capability read the composer waits on before it arms.
    await pumps(tester);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
  }

  testWidgets('Remind me: a To Do task, a toast with Undo, and Undo deletes '
      'the task', (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    await pumpScreen(tester, tasks: tasks);
    await openInvoice(tester);

    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    expect(find.byKey(ThreadActionBar.remindChoicesKey), findsOneWidget);
    final pill = tester.widget<TextButton>(
        find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')));
    expect((pill.child! as Text).data, 'Tomorrow 9 am');

    await tester.tap(find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')));
    await pumps(tester);
    await pumps(tester);

    expect(tasks.created, hasLength(1));
    final made = tasks.created.single;
    expect(made.title, 'Reply to Dana Whitfield: Invoice 4471');
    expect(made.status, 'notStarted');
    expect(made.bodyText, 'Could you sign the invoice by Friday?');
    final today = la.dateOf(DateTime.now().toUtc());
    expect(made.reminderAtUtc, la.localDateTime(today.addDays(1), 9, 0).toUtc());
    final rows = await store.activeReminders();
    expect(rows, hasLength(1));
    expect(rows.single.kind, ReminderKind.replyBy);
    expect(rows.single.createdFrom, ReminderOrigin.bar);
    expect(rows.single.anchorMessageId, 'c2-m1');
    expect(find.text('Reminder set in To Do · Tomorrow 9 am'), findsOneWidget);

    // The bar slides in before its Undo can be pressed.
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Undo'));
    await pumps(tester);
    await pumps(tester);

    expect(tasks.deleted, [made.id]);
    expect(await store.activeReminders(), isEmpty);
    expect((await store.reminderById(rows.single.id))!.status,
        ReminderStatus.cancelled);
  });

  testWidgets('a second Remind me moves the first: one active task, the '
      'earlier one deleted', (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    await pumpScreen(tester, tasks: tasks);
    await openInvoice(tester);

    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    await tester.tap(find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')));
    await pumps(tester);
    await pumps(tester);
    expect(tasks.created, hasLength(1));
    final first = tasks.created.single;

    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    await tester
        .tap(find.byKey(ThreadActionBar.remindPillKeyFor('in-2-hours')));
    await pumps(tester);
    await pumps(tester);

    expect(tasks.created, hasLength(2));
    expect(tasks.deleted, [first.id]);
    final active = await store.activeReminders();
    expect(active, hasLength(1));
    expect(active.single.todoTaskId, tasks.created.last.id);
    expect(find.text('Reminder set in To Do · In 2 hours'), findsOneWidget);
  });

  testWidgets('a second Remind me whose earlier cancel fails still says the '
      'new one was set, and the old one stands', (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    await pumpScreen(tester, tasks: tasks);
    await openInvoice(tester);

    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    await tester.tap(find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')));
    await pumps(tester);
    await pumps(tester);
    expect(tasks.created, hasLength(1));

    tasks.throwOnDelete = const TasksTransient('To Do is busy');
    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    await tester
        .tap(find.byKey(ThreadActionBar.remindPillKeyFor('in-2-hours')));
    await pumps(tester);
    await pumps(tester);

    expect(tasks.created, hasLength(2));
    expect(tasks.deleted, isEmpty);
    // The new one is set; the old one's cancel failed, so it stands too.
    final active = await store.activeReminders();
    expect(active, hasLength(2));
    expect([for (final r in active) r.todoTaskId],
        containsAll([tasks.created.first.id, tasks.created.last.id]));
    expect(find.text('Reminder set in To Do · In 2 hours'), findsOneWidget);
    expect(find.text("Couldn't reach To Do. Nothing was set."), findsNothing);
  });

  testWidgets('an Undo that fails says the reminder stands, and it does',
      (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    await pumpScreen(tester, tasks: tasks);
    await openInvoice(tester);

    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();
    await tester.tap(find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')));
    await pumps(tester);
    await pumps(tester);
    expect(tasks.created, hasLength(1));

    tasks.throwOnDelete = const TasksTransient('To Do is busy');
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Undo'));
    await pumps(tester);
    await pumps(tester);

    // The pressed bar slides out before the next one shows.
    await tester.pump(const Duration(milliseconds: 750));
    await pumps(tester);

    expect(tasks.deleted, isEmpty);
    expect(find.text("Couldn't reach To Do. The reminder stands."),
        findsOneWidget);
    final rows = await store.activeReminders();
    expect(rows, hasLength(1));
    expect(rows.single.status, ReminderStatus.active);
  });

  testWidgets('Send with 2 days: a follow_up row at the next business day '
      '09:00, anchored on the echo, and the toast says so', (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    final mail = _SendingMail();
    await pumpScreen(tester, tasks: tasks, mail: mail);
    await openInvoice(tester);

    expect(find.byKey(Composer.followUpKey), findsOneWidget);
    await tester.tap(
        find.byKey(Composer.followUpChoiceKeyFor(FollowUpChoice.twoDays)));
    await tester.pump();

    final field = find.descendant(
      of: find.byType(Composer),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Signed and sent back.');
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(Composer),
      matching: find.text('Send'),
    ));
    await pumps(tester);
    await pumps(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(mail.bodies, ['Signed and sent back.']);
    expect(tasks.created, hasLength(1));
    final made = tasks.created.single;
    expect(made.title, 'Waiting on Dana Whitfield: Invoice 4471');
    expect(made.status, 'waitingOnOthers');
    final expected =
        nextBusinessDaysAt(days: 2, from: DateTime.now(), zone: la);
    expect(made.reminderAtUtc, expected);
    // An echo id is no Graph id: nothing is flagged at the send.
    expect(tasks.flagged, isEmpty);

    final rows = await store.activeReminders();
    expect(rows, hasLength(1));
    expect(rows.single.kind, ReminderKind.followUp);
    expect(rows.single.createdFrom, ReminderOrigin.send);
    expect(rows.single.anchorMessageId, 'local:graph-draft-1');
    expect(
      find.textContaining(RegExp(r'^Reply sent · Following up \w{3} 9:00 AM$')),
      findsOneWidget,
    );
  });

  testWidgets('with reply-marks-done on, the follow-up is a line on the done '
      "toast, whose one Undo stays the done's", (tester) async {
    await seedInvoice();
    await store.setPref(replySendMarksDoneKey, 'true');
    final tasks = _RecordingTasks();
    await pumpScreen(tester, tasks: tasks, mail: _SendingMail());
    await openInvoice(tester);

    await tester.tap(
        find.byKey(Composer.followUpChoiceKeyFor(FollowUpChoice.oneWeek)));
    await tester.pump();
    await tester.enterText(
      find.descendant(
          of: find.byType(Composer), matching: find.byType(TextField)),
      'Signed and sent back.',
    );
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(Composer),
      matching: find.text('Send'),
    ));
    await pumps(tester);
    await pumps(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(tasks.created, hasLength(1));
    expect(
      find.textContaining(RegExp(
          r'^Reply sent · Marked done · Following up \w{3} 9:00 AM$')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Undo'));
    await pumps(tester);
    await pumps(tester);
    // The done was undone; the reminder stands.
    expect(tasks.deleted, isEmpty);
    expect(await store.activeReminders(), hasLength(1));
  });

  /// Picks 2 days in the invoice's composer and sends a reply.
  Future<void> sendWithFollowUp(WidgetTester tester) async {
    await tester.tap(
        find.byKey(Composer.followUpChoiceKeyFor(FollowUpChoice.twoDays)));
    await tester.pump();
    await tester.enterText(
      find.descendant(
          of: find.byType(Composer), matching: find.byType(TextField)),
      'Signed and sent back.',
    );
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(Composer),
      matching: find.text('Send'),
    ));
    await pumps(tester);
    await pumps(tester);
  }

  testWidgets('a slow To Do does not hold the send', (tester) async {
    InboxScreen.followUpWaitOverride = const Duration(milliseconds: 200);
    await seedInvoice();
    final tasks = _RecordingTasks()..holdCreate = Completer<void>();
    final mail = _SendingMail();
    await pumpScreen(tester, tasks: tasks, mail: mail);
    await openInvoice(tester);

    await sendWithFollowUp(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await pumps(tester);

    // The reply went and says so, with no follow-up line, while To Do is
    // still answering.
    expect(mail.bodies, ['Signed and sent back.']);
    expect(find.text('Reply sent.'), findsOneWidget);
    expect(find.textContaining('Following up'), findsNothing);
    expect(tasks.created, isEmpty);

    tasks.holdCreate!.complete();
    await pumps(tester);
    await pumps(tester);

    // The late answer lands by itself, and says nothing more.
    expect(tasks.created, hasLength(1));
    final rows = await store.activeReminders();
    expect(rows.single.kind, ReminderKind.followUp);
    expect(find.text('Reply sent.'), findsOneWidget);
    expect(find.textContaining('No follow-up set'), findsNothing);
  });

  testWidgets('a late To Do failure toasts without Undo', (tester) async {
    InboxScreen.followUpWaitOverride = const Duration(milliseconds: 200);
    await seedInvoice();
    final tasks = _RecordingTasks()..holdCreate = Completer<void>();
    await pumpScreen(tester, tasks: tasks, mail: _SendingMail());
    await openInvoice(tester);

    await sendWithFollowUp(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await pumps(tester);
    expect(find.text('Reply sent.'), findsOneWidget);

    tasks.holdCreate!.completeError(const TasksTransient('Graph 503'));
    await pumps(tester);
    await pumps(tester);

    expect(
      find.text("No follow-up set — Couldn't reach To Do. Nothing was set."),
      findsOneWidget,
    );
    expect(find.text('Undo'), findsNothing);
    expect(tasks.created, isEmpty);
    expect(await store.activeReminders(), isEmpty);
  });

  testWidgets('unavailable: the strip says the permission sentence, and the '
      'composer has no follow-up', (tester) async {
    await seedInvoice();
    final tasks = _RecordingTasks();
    await pumpScreen(tester,
        tasks: tasks,
        mail: _SendingMail(),
        availability: TasksAvailability.scopeMissing);
    await openInvoice(tester);

    expect(find.byKey(Composer.followUpKey), findsNothing);
    await tester.tap(find.byKey(ThreadActionBar.remindKey));
    await tester.pump();

    expect(
        find.text(
            'Reminders need the To Do permission — Settings › Connection'),
        findsOneWidget);
    expect(find.byKey(ThreadActionBar.remindPillKeyFor('tomorrow')),
        findsNothing);
    expect(find.byKey(ThreadActionBar.remindSettingsKey), findsOneWidget);
    expect(tasks.created, isEmpty);
  });

  testWidgets('a reminder row on the Day stop opens its thread',
      (tester) async {
    await seedInvoice();
    final today = la.dateOf(DateTime.now().toUtc());
    // Noon today on the owner's wall: on today whatever the hour.
    final at = la.localDateTime(today, 12, 0).toUtc();
    final stamp = MessageStore.isoStamp(DateTime.now());
    await store.insertReminder(Reminder(
      id: 'rem-1',
      kind: ReminderKind.replyBy,
      source: 'email',
      conversationKey: 'c2',
      title: 'Reply to Dana Whitfield: Invoice 4471',
      remindAt: MessageStore.isoStamp(at),
      dueDate: today.toIso(),
      status: ReminderStatus.active,
      createdFrom: ReminderOrigin.bar,
      createdAt: stamp,
      updatedAt: stamp,
    ));
    await pumpScreen(tester, tasks: _RecordingTasks());

    await tester.tap(find.text('Day'));
    await pumps(tester);

    final row = find.byKey(DayPane.reminderRowKeyFor('rem-1'));
    expect(row, findsOneWidget);
    expect(find.text('Reminder · in To Do'), findsOneWidget);
    await tester.tap(find.descendant(
      of: row,
      matching: find.text('Reply to Dana Whitfield: Invoice 4471'),
    ));
    await pumps(tester);
    await pumps(tester);

    expect(
      tester
          .widgetList<ThreadDetailPanel>(find.byType(ThreadDetailPanel))
          .map((p) => p.conversation.id),
      contains('c2'),
    );
  });

  testWidgets('the poll reconciles, then plans over the loaded list, once '
      'per tend even when two polls overlap', (tester) async {
    await seedInvoice();
    _RecordingService? service;
    _RecordingPlanner? planner;
    final held = Completer<int>();
    await pumpScreen(tester, tasks: _RecordingTasks(), overrides: [
      reminderServiceProvider.overrideWith((ref) => service = _RecordingService(
            store: ref.watch(messageStoreProvider),
            backend: ref.watch(tasksBackendProvider),
            zone: CalendarZone.utc,
            log: ref.watch(activityLogProvider),
            availability: () async => TasksAvailability.available,
            hold: held,
          )),
      reminderPlannerProvider.overrideWith((ref) => planner = _RecordingPlanner(
            store: ref.watch(messageStoreProvider),
            service: ref.watch(reminderServiceProvider),
            enabled: () => true,
            availability: () async => TasksAvailability.available,
          )),
    ]);

    // A refresh's tend waits on the held reconcile (the startup refresh may
    // already have started it, before the zone resolved or after); a second
    // refresh lands on it and joins it.
    await tester.tap(find.byTooltip('Refresh'));
    await pumps(tester);
    expect(service!.reconciles, 1);
    expect(planner?.plans ?? const [], isEmpty);
    await tester.tap(find.byTooltip('Refresh'));
    await pumps(tester);
    expect(service!.reconciles, 1, reason: 'single-flight');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
    final before = container.read(reminderRevisionProvider);
    held.complete(1);
    await pumps(tester);
    // The reconcile changed a row: the revision is bumped.
    expect(container.read(reminderRevisionProvider), before + 1);
    expect(planner!.plans, hasLength(1));
    expect(planner!.plans.single.zone, la);
    expect(planner!.plans.single.keys, contains('c2'));
    expect(planner!.plans.single.threshold, AppPrefs().needsYouThreshold);

    // The next poll runs a fresh tend.
    await tester.tap(find.byTooltip('Refresh'));
    await pumps(tester);
    await pumps(tester);
    expect(service!.reconciles, 2);
    expect(planner!.plans, hasLength(2));
    // Nothing changed on that pass: no bump.
    expect(container.read(reminderRevisionProvider), before + 1);

    // A plan that throws stays inside the poll: the refresh completes, no
    // error reaches the test, and the next poll tends afresh.
    planner!.throwNext = true;
    await tester.tap(find.byTooltip('Refresh'));
    await pumps(tester);
    await pumps(tester);
    expect(planner!.plans, hasLength(3));
    expect(tester.takeException(), isNull);
    expect(container.read(reminderRevisionProvider), before + 1);
    await tester.tap(find.byTooltip('Refresh'));
    await pumps(tester);
    await pumps(tester);
    expect(service!.reconciles, 4);
    expect(planner!.plans, hasLength(4));
  });
}

/// To Do, recorded: every task created, deleted and flagged.
class _RecordingTasks implements TasksBackend {
  final List<
      ({
        String id,
        String title,
        String? bodyText,
        DateTime? reminderAtUtc,
        String status,
      })> created = [];
  final List<String> deleted = [];
  final List<String> flagged = [];
  var _next = 0;

  /// Thrown by the next `deleteTask`, once.
  Object? throwOnDelete;

  /// When set, every `createTask` waits on it (and throws what it is
  /// completed with as an error): a slow To Do.
  Completer<void>? holdCreate;

  @override
  Future<TodoList> ensureList({String name = 'Bond follow-ups'}) async =>
      const TodoList(id: 'list-1', name: 'Bond follow-ups', created: true);

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
    await holdCreate?.future;
    final id = 'task-${++_next}';
    created.add((
      id: id,
      title: title,
      bodyText: bodyText,
      reminderAtUtc: reminderAtUtc,
      status: status,
    ));
    return TodoTask(
      id: id,
      listId: listId,
      title: title,
      status: status,
      isReminderOn: reminderAtUtc != null,
    );
  }

  @override
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  }) async =>
      TodoTask(
        id: taskId,
        listId: listId,
        title: '',
        status: 'completed',
        isReminderOn: false,
      );

  @override
  Future<void> deleteTask({
    required String listId,
    required String taskId,
  }) async {
    final thrown = throwOnDelete;
    if (thrown != null) {
      throwOnDelete = null;
      throw thrown;
    }
    deleted.add(taskId);
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
    flagged.addAll(messageIds);
    return FlagOutcome(updated: messageIds.length);
  }
}

/// The service with its reconcile counted and held on [hold] (made in the
/// test body, so it delivers under `tester.pump`).
class _RecordingService extends ReminderService {
  _RecordingService({
    required super.store,
    required super.backend,
    required super.zone,
    required super.log,
    required super.availability,
    required this.hold,
  });

  final Completer<int> hold;
  int reconciles = 0;

  @override
  Future<int> reconcile() {
    reconciles++;
    return reconciles == 1 ? hold.future : Future.value(0);
  }
}

/// The planner with each pass's arguments recorded; it plans nothing, and
/// throws a [StateError] on the pass after [throwNext] is set.
class _RecordingPlanner extends ReminderPlanner {
  _RecordingPlanner({
    required super.store,
    required super.service,
    required super.enabled,
    required super.availability,
  });

  final List<({CalendarZone zone, double threshold, List<String> keys})>
      plans = [];
  bool throwNext = false;

  @override
  Future<int> plan({
    required CalendarZone zone,
    required double needsYouThreshold,
    required List<Conversation> conversations,
  }) async {
    plans.add((
      zone: zone,
      threshold: needsYouThreshold,
      keys: [for (final c in conversations) c.id],
    ));
    if (throwNext) {
      throwNext = false;
      throw StateError('planner failed');
    }
    return 0;
  }
}
