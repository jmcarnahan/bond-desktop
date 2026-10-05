import 'dart:async';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/draft_provenance.dart' show DraftProvenance;
import 'package:bond_inbox/models/calendar_models.dart'
    show MeetingTimeSuggestion, MeetingTimes, WritePreview;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart'
    show conversationsProvider;
import 'package:bond_inbox/providers/day_providers.dart'
    show schedulingAsksProvider;
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/new_message_screen.dart'
    show NewMessageScreen;
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/activity_log.dart' show ActivityLog;
import 'package:bond_inbox/services/ai_worker.dart' show AiWorker;
import 'package:bond_inbox/services/drain_gate.dart' show DrainGate;
import 'package:bond_inbox/services/calendar/ask_hints.dart'
    show readAskHintsFromRead;
import 'package:bond_inbox/services/calendar/ask_reader.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/scheduling_ask.dart'
    show schedulingAskMessageIds;
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/llm/ask_read_task.dart' show AskRead;
import 'package:bond_inbox/services/llm/llm_client.dart'
    show LlmUnavailableException;
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show CalendarDate, CalendarEvent;
import 'package:bond_inbox/services/calendar/day_items.dart'
    show dayTitle, formatEventRange, shortDate;
import 'package:bond_inbox/services/calendar/find_time.dart'
    show FindTimeWindow, findTimeUnreadableNote, findTimeWindowUtc;
import 'package:bond_inbox/theme/tokens.dart' show BondColors;
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/command_plan_card.dart'
    show CommandPlanCard;
import 'package:bond_inbox/widgets/day_command_bar.dart' show DayCommandBar;
import 'package:bond_inbox/widgets/day_grid.dart' show DayGrid;
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/scheduling_ask_rows.dart';
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart'
    show WriteConfirmStrip;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// Find a time inside the assembled screen: a needs-reply thread whose newest
/// mail the decision model read as scheduling shows up in the Day column's
/// Scheduling asks, finds its slots there in place, and shows a picked slot
/// on its day as the command card's proposal; it also wears the chip in its
/// header, opens the pane over itself, and hands the slots to the reply box
/// or to an invite. Scaffolding is `inbox_day_test.dart`'s; fictional people.

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

/// A calendar sync that never finishes a tick: nothing here reads its
/// outcome.
class _QuietCalendarSync extends CalendarSync {
  _QuietCalendarSync(MessageStore store, CalendarStore calendar)
      : super(const UnavailableCalendarBackend(), store, calendar);

  final Completer<CalendarSyncOutcome> gate = Completer();

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) => gate.future;
}

/// A calendar sync whose every tick completes at once, `synced`: what the
/// inbox plans briefs and redrafts stale offered times off.
class _SyncedCalendarSync extends CalendarSync {
  _SyncedCalendarSync(MessageStore store, CalendarStore calendar)
      : super(const UnavailableCalendarBackend(), store, calendar);

  int ticks = 0;

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) {
    ticks += 1;
    return Future.value(
        const CalendarSyncOutcome(CalendarSyncStatus.synced, upserts: 1));
  }
}

/// `find_meeting_times` answering [slots], each call's attendees recorded.
class _Backend extends Fake implements CalendarBackend {
  _Backend(this.slots);

  final List<MeetingTimeSuggestion> slots;
  final List<List<String>> asked = [];
  final List<int> minutes = [];
  final List<(DateTime, DateTime)> windows = [];
  final List<String> domains = [];

  /// Graph's reason on an empty answer; set with [slots] empty.
  String emptyReason = '';

  /// When true each call waits on its own Completer in [held], in call
  /// order, so a test can answer them out of order.
  bool hold = false;
  final List<Completer<List<MeetingTimeSuggestion>>> held = [];

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
    String activityDomain = 'work',
  }) async {
    asked.add(attendees);
    minutes.add(durationMinutes);
    windows.add((windowStartUtc, windowEndUtc));
    domains.add(activityDomain);
    if (hold) {
      final c = Completer<List<MeetingTimeSuggestion>>();
      held.add(c);
      return MeetingTimes(suggestions: await c.future);
    }
    return MeetingTimes(suggestions: slots, emptyReason: emptyReason);
  }
}

/// The real store over the same database, whose read of an ask's message
/// can be held, and counted.
class _HoldingStore extends MessageStore {
  _HoldingStore(super.db);

  Completer<void>? hold;
  int askReads = 0;

  /// When set, only this message's read waits on [hold].
  String? holdOnly;

  @override
  Future<Map<String, Object?>?> getMessageRow(
      String source, String sourceMessageId) async {
    if (sourceMessageId.startsWith('ask-')) {
      askReads += 1;
      final h = hold;
      if (h != null && (holdOnly == null || holdOnly == sourceMessageId)) {
        await h.future;
      }
    }
    return super.getMessageRow(source, sourceMessageId);
  }
}

/// Answers every dry run with [notifies] and every commit with success.
class _RecordingWriter implements CalendarWriter {
  _RecordingWriter({this.notifies = const []});

  final List<String> notifies;
  final List<CalendarWrite> previewed = [];
  final List<CalendarWrite> committed = [];

  /// When set, a commit waits for it. Made inside the test body.
  Completer<void>? hold;

  /// When set, a dry run waits for it. Made inside the test body.
  Completer<void>? previewHold;

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
    final held = previewHold;
    if (held != null) await held.future;
    final p = WritePreview(method: 'POST', path: '/x', notifies: notifies);
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    committed.add(write);
    final held = hold;
    if (held != null) await held.future;
    // A private create offers its Undo, as the real writer's does.
    return write is CreateEvent && write.attendees.isEmpty
        ? const WriteOutcome.ok(undo: DeleteEvent('new-1'))
        : const WriteOutcome.ok();
  }
}

const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';
const String _dana = 'dana.ortiz@fabrikam.example';
const String _subject = 'Time for the Fabrikam review?';

void main() {
  setUpAll(initCalendarZones);

  late BondDatabase db;
  late MessageStore store;
  late CalendarZone la;
  late _Backend backend;
  late _RecordingWriter writer;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    // Two slots a week out, whenever the test runs: 10:00 and 14:00 local.
    final day = la.dateOf(DateTime.now().toUtc()).addDays(7);
    DateTime at(int h) => la.localDateTime(day, h, 0).toUtc();
    // Graph's own order leads with two, when Dana is busy; at ten everyone
    // is free, so the ranking puts ten first.
    backend = _Backend([
      MeetingTimeSuggestion(
          startUtc: at(14),
          endUtc: at(14).add(const Duration(minutes: 30)),
          confidence: 90,
          organizerAvailability: 'free',
          attendeeAvailability: const {_dana: 'busy'}),
      MeetingTimeSuggestion(
          startUtc: at(10),
          endUtc: at(10).add(const Duration(minutes: 30)),
          confidence: 50,
          organizerAvailability: 'free',
          attendeeAvailability: const {_dana: 'free'}),
    ]);
    writer = _RecordingWriter(notifies: const [_dana]);
  });

  tearDown(() {
    InboxScreen.askReadWaitOverride = null;
    InboxScreen.askResultLifetimeOverride = null;
    return db.close();
  });

  Future<void> pumps(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// A needs-reply thread with Dana whose one message the decision model
  /// read as scheduling at p 0.9.
  Future<void> seedAsk({
    String key = 'c-ask',
    String messageId = 'ask-m1',
    String subject = _subject,
    String participantsJson = '[{"name":"Dana Ortiz","email":"$_dana"}]',
    String body = 'Could we find 30 minutes next week for the review?',
    int minutesAgo = 60,
  }) async {
    final received = DateTime.now()
        .toUtc()
        .subtract(Duration(minutes: minutesAgo))
        .toIso8601String();
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': messageId,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Ortiz',
      'from_address': _dana,
      'received_at': received,
      'body_text': body,
    });
    await writeTriaged(store, 'email', messageId,
        status: 'triaged', replyExpected: true);
    // Needs You is the decision model's probability against the slider since
    // the needs-you signals round; the ask sits there by it.
    await store.writeNeedsYouP('email', messageId, p: 0.9);
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json': participantsJson,
      'state': 'needs_reply',
      'cta_text': 'Reply to Dana',
      'cta_urgency': 'normal',
      'last_message_at': received,
      'last_inbound_at': received,
    });
    await store.writeDecision(
      'email',
      messageId,
      fakeDecision(fakeAnswers(intent: 'scheduling', choiceP: 0.9)),
      qhash: DecisionHeads.expectedQhash,
      ownerKnown: true,
    );
  }

  Future<void> pumpScreen(WidgetTester tester,
      {bool zoneResolves = true,
      MessageStore? storeOverride,
      AskReader? askReader,
      CalendarSync? calendarSyncOverride,
      bool processing = false}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calendarSync =
        calendarSyncOverride ?? _QuietCalendarSync(store, CalendarStore(db));
    // Processing on with three idle lanes: what runs off a sync is seen in
    // the store, and no drain dials a server.
    final idle = [
      if (processing)
        for (var i = 0; i < 3; i++)
          AiWorker(store, handlers: const [], gate: DrainGate()),
    ];
    for (final w in idle) {
      addTearDown(w.dispose);
    }
    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _readGrant;
    final auth = GraphAuth(httpClient: client, store: tokens);
    await store.setPref(backendModeKey, backendModeSdk);
    await store.setPref(processingOnKey, 'false');
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        if (storeOverride != null)
          messageStoreProvider.overrideWithValue(storeOverride),
        keepingDecisionClient(),
        noCommandHeads(),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        calendarSyncProvider.overrideWithValue(calendarSync),
        if (processing) ...[
          processingProvider.overrideWith((ref) => ProcessingNotifier(true)),
          aiWorkerProvider.overrideWithValue(idle[0]),
          storylineWorkerProvider.overrideWithValue(idle[1]),
          draftWorkerProvider.overrideWithValue(idle[2]),
        ],
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.available),
        // A zone that never resolves is the one a slow mailbox read leaves.
        calendarZoneProvider.overrideWith((ref) =>
            zoneResolves ? Future.value(la) : Completer<CalendarZone>().future),
        calendarBackendProvider.overrideWithValue(backend),
        calendarWritesProvider.overrideWithValue(writer),
        // The model off unless a test reads with one: the rules alone.
        askReaderProvider.overrideWithValue(askReader ??
            AskReader(
              store: store,
              client: () => ScriptedLlm.never(label: 'ask_read off'),
              log: ActivityLog(store),
              zone: () => la,
              enabled: false,
            )),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await pumps(tester);
  }

  /// Day → the Scheduling asks row opened, its search landed.
  Future<void> openAsk(WidgetTester tester) async {
    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
    await tester.tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
  }

  /// Day → the ask's Open thread → the thread in the main pane.
  Future<void> openThreadFromDay(WidgetTester tester) async {
    await openAsk(tester);
    await tester.tap(find.byKey(SchedulingAskTile.openKeyFor('email', 'c-ask')));
    await pumps(tester);
  }

  /// The thread bar's Find a time pressed, and the Day stop it lands on
  /// given its write, its read and its search.
  Future<void> pressFindTime(WidgetTester tester) async {
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
    await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
    await pumps(tester);
    await pumps(tester);
    await pumps(tester);
  }

  /// The ask opened and its first slot picked: the proposal on its day.
  Future<void> pickFirstSlot(WidgetTester tester) async {
    await openAsk(tester);
    await tester
        .tap(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)));
    await pumps(tester);
    await pumps(tester);
  }

  /// The ask opened and its Next week pressed (outside the grid group).
  Future<void> openAskNextWeekTop(WidgetTester tester) async {
    await openAsk(tester);
    await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
        'email', 'c-ask', FindTimeWindow.nextWeek)));
    await pumps(tester);
    await pumps(tester);
  }

  /// Grid face on the day the pane is on, and a tap high on it.
  Future<void> tapEmptyGridTop(WidgetTester tester) async {
    if (find.byType(DayGrid).evaluate().isEmpty) {
      await tester.tap(find.byKey(DayPane.gridKey));
      await pumps(tester);
      await pumps(tester);
    }
    final grid = tester.getRect(find.byType(DayGrid));
    await tester.tapAt(grid.center);
    await pumps(tester);
    await pumps(tester);
  }

  /// The docked reply box's text, whatever it is.
  String composerText(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .map((e) => e.controller.text)
      .firstWhere((t) => t.contains('Would any of these work?'),
          orElse: () => '');

  testWidgets('the Day column lists the ask, and opening it searches at once '
      'and shows the slots ranked by who is free', (tester) async {
    await seedAsk();
    await pumpScreen(tester);

    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
    expect(find.text(_subject), findsOneWidget);
    expect(find.text('Dana Ortiz'), findsOneWidget);
    expect(backend.asked, isEmpty, reason: 'nothing is searched folded');

    await tester.tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(backend.asked.single, [_dana]);
    expect(backend.minutes.single, 30);
    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
        findsOneWidget);
    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 1)),
        findsOneWidget);
    // Graph led with two; the slot everyone can make is drawn first.
    expect(
        find.descendant(
            of: find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
            matching: find.text('Everyone free')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 1)),
            matching: find.text('1 of 2 free')),
        findsOneWidget);
    expect(find.text(CommandPlanCard.graphCaption), findsOneWidget);
    // The agenda carries no asks group of its own any more.
    expect(find.text('Scheduling asks · 1'), findsNothing);

    // The search's activity row says where it was asked from.
    final rows = await store.recentActivity(limit: 20);
    final searches = [
      for (final r in rows)
        if (r['kind'] == 'find_time' &&
            (r['detail_json'] as String? ?? '').contains('"source"'))
          r['detail_json'] as String,
    ];
    expect(searches.single, contains('"graph_calls":1'));

    // A length pressed searches again with it.
    await tester.tap(
        find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)));
    await pumps(tester);
    await pumps(tester);
    expect(backend.minutes, [30, 45]);
  });

  testWidgets('a slot picked shows its day with the proposal card; Send waits '
      'on the strip naming Dana, and Keep it sends nothing', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await pickFirstSlot(tester);

    final today = la.dateOf(DateTime.now().toUtc());
    final slotDay = today.addDays(7);
    expect(find.text(dayTitle(slotDay, today)), findsOneWidget,
        reason: 'the pane moved to the slot\'s day');
    expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);
    expect(find.byKey(CommandPlanCard.doKey), findsOneWidget);
    expect(find.text('This emails: $_dana'), findsOneWidget);
    final proposed = writer.previewed.single as CreateEvent;
    expect(proposed.attendees, [_dana]);
    expect(proposed.subject, 'Re: $_subject');

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await pumps(tester);
    expect(find.byType(WriteConfirmStrip), findsOneWidget);
    expect(writer.committed, isEmpty);

    await tester.tap(find.byKey(WriteConfirmStrip.dismissKey));
    await pumps(tester);
    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(writer.committed, isEmpty);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget,
        reason: 'nothing was sent, so the ask is still owed');
  });

  testWidgets('a confirmed invite goes to Dana, and the ask closes: it '
      'leaves the column and the thread bar', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await pickFirstSlot(tester);

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await pumps(tester);
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await pumps(tester);
    final write = writer.committed.single as CreateEvent;
    expect(write.attendees, [_dana]);
    expect(write.subject, 'Re: $_subject');
    expect(find.byType(CommandPlanCard), findsNothing);
    await pumps(tester);
    expect(find.byKey(AppRail.asksHeaderKey), findsNothing,
        reason: 'the only ask closed');
    final labels = await store.decisionLabels();
    expect(labels.single['question'], 'scheduling_ask');
    expect(labels.single['origin'], 'invite');
    expect(labels.single['source_message_id'], 'ask-m1');
    final rows = await store.recentActivity(limit: 20);
    expect(
        rows.where((r) =>
            r['kind'] == 'find_time' &&
            (r['detail_json'] as String? ?? '')
                .contains('"action":"send_invite"')),
        hasLength(1),
        reason: 'the invite\'s own Find a time row, an enum word only');

    // Not an ask any more, but Dana's message is still unanswered, so the
    // thread still offers Find a time — a press would be the owner's word.
    await tester.tap(find.text('Needs You').first);
    await pumps(tester);
    await tester.tap(find.text(_subject).first);
    await pumps(tester);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
  });

  testWidgets('the invite labels the message its slot was picked for: a '
      'newer request that lands before Send keeps its ask', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await pickFirstSlot(tester);

    // Dana writes again while the card stands, and the asks are re-read.
    await seedAsk(
        messageId: 'ask-m2',
        body: 'Or could we do Thursday instead?',
        minutesAgo: 10);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
    container.invalidate(schedulingAsksProvider);
    await pumps(tester);

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await pumps(tester);
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await pumps(tester);
    await pumps(tester);
    expect(writer.committed.single, isA<CreateEvent>());
    final labels = await store.decisionLabels();
    expect(labels.single['source_message_id'], 'ask-m1');
    expect(labels.single['answer'], 'no');
    expect(await schedulingAskMessageIds(store), {'email|c-ask': 'ask-m2'});
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget,
        reason: 'the newer request stands');
  });

  testWidgets('a slot added to your own calendar with nobody on it leaves '
      'the ask owed', (tester) async {
    await seedAsk(participantsJson: '[]');
    writer = _RecordingWriter();
    await pumpScreen(tester);
    await pickFirstSlot(tester);

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await pumps(tester);
    // Nobody on it and nobody emailed: it goes straight on, with its Undo.
    expect(find.byType(WriteConfirmStrip), findsNothing);
    final write = writer.committed.single as CreateEvent;
    expect(write.attendees, isEmpty);
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
    expect(await store.decisionLabels(), isEmpty);
  });

  testWidgets('× dismisses the ask with a toast, and z brings it back',
      (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);

    await tester
        .tap(find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(find.byKey(AppRail.asksHeaderKey), findsNothing);
    expect(find.text('Dismissed — it comes back if they write again.'),
        findsOneWidget);
    expect((await store.decisionLabels()).single['origin'], 'dismiss');
    expect(backend.asked, isEmpty, reason: 'a dismiss searches nothing');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await pumps(tester);
    await pumps(tester);
    expect(await store.decisionLabels(), isEmpty);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
  });

  testWidgets('after a dismiss, a newer inbound scheduling message makes it '
      'an ask again', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    await tester
        .tap(find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(find.byKey(AppRail.asksHeaderKey), findsNothing);

    // Dana writes again: that time does not work, could we try another.
    await seedAsk(messageId: 'ask-m2', minutesAgo: 10);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
    await container.read(conversationsProvider.notifier).load();
    await pumps(tester);
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
  });

  testWidgets('the grid draws the picked slot as the Proposed tile',
      (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await pickFirstSlot(tester);

    await tester.tap(find.byKey(DayPane.gridKey));
    await pumps(tester);
    await pumps(tester);
    expect(find.byKey(DayGrid.proposalKey), findsOneWidget);
    // Thirty minutes is one line: the name and "Proposed" share it.
    expect(
        find.descendant(
            of: find.byKey(DayGrid.proposalKey),
            matching: find.text('Re: $_subject · Proposed', findRichText: true)),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Put in reply from the column opens the thread with the slots '
      'in its reply box', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openAsk(tester);

    await tester.tap(
        find.byKey(SchedulingAskTile.putInReplyKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
    expect(composerText(tester), startsWith('Would any of these work? · '));
  });

  testWidgets('the chevron folds the asks and keeps the header, and brings '
      'them back', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);

    await tester.tap(find.byKey(AppRail.asksChevronKey));
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
    expect(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')),
        findsNothing);

    await tester.tap(find.byKey(AppRail.asksChevronKey));
    await pumps(tester);
    expect(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')),
        findsOneWidget);
  });

  testWidgets('a typed command after a slot pick does not mark the ask',
      (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await pickFirstSlot(tester);
    expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);

    await tester.enterText(
        find.byKey(DayCommandBar.fieldKey), 'add focus time tomorrow 3pm');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(find.byKey(CommandPlanCard.doKey), findsOneWidget);
    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await pumps(tester);
    // The recording writer names Dana on every dry run, so it confirms.
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await pumps(tester);
    final write = writer.committed.single as CreateEvent;
    expect(write.subject, isNot('Re: $_subject'),
        reason: 'the typed command was sent, not the ask');
    expect(await store.decisionLabels(), isEmpty,
        reason: 'the typed command closed no ask');
    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
        findsOneWidget,
        reason: 'the ask did not fold on the typed command\'s account');
  });

  testWidgets('Put in reply from the column keeps the draft already in the '
      'box', (tester) async {
    await seedAsk();
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c-ask',
      replyToMessageId: 'ask-m1',
      body: 'Tuesday could work.',
      status: 'edited',
    );
    await pumpScreen(tester);
    await openAsk(tester);

    await tester.tap(
        find.byKey(SchedulingAskTile.putInReplyKeyFor('email', 'c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(composerText(tester),
        startsWith('Tuesday could work.\n\nWould any of these work? · '));
  });

  testWidgets('one ask open at a time', (tester) async {
    await seedAsk();
    await seedAsk(
        key: 'c-ask2', messageId: 'ask-m2', subject: 'Northwind sync slot?');
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.text('SCHEDULING ASKS · 2'), findsOneWidget);

    await tester.tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
    await pumps(tester);
    expect(find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)),
        findsOneWidget);

    await tester
        .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask2')));
    await pumps(tester);
    expect(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')),
        findsOneWidget);
    expect(find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)),
        findsNothing,
        reason: 'the first ask folded');
    expect(
        find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask2', 45)),
        findsOneWidget);
  });

  testWidgets('an answer a newer pill press overtook is dropped',
      (tester) async {
    await seedAsk();
    backend.hold = true;
    await pumpScreen(tester);
    await openAsk(tester);
    await tester.tap(
        find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)));
    await pumps(tester);
    await pumps(tester);
    expect(backend.minutes, [30, 45]);
    expect(backend.held, hasLength(2));

    // The 45-minute answer lands first: one slot at noon, Graph's.
    final day = la.dateOf(DateTime.now().toUtc()).addDays(7);
    final noon = la.localDateTime(day, 12, 0).toUtc();
    backend.held[1].complete([
      MeetingTimeSuggestion(
          startUtc: noon, endUtc: noon.add(const Duration(minutes: 45))),
    ]);
    await pumps(tester);
    await pumps(tester);
    // Then the stale 30-minute one, with two slots.
    backend.held[0].complete(backend.slots);
    await pumps(tester);
    await pumps(tester);

    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
        findsOneWidget);
    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 1)),
        findsNothing,
        reason: 'the stale answer was not drawn');
  });

  testWidgets('an attendee Graph cannot read falls back to your own free '
      'times, said, and a slot still stands the proposal', (tester) async {
    await seedAsk();
    // Live 2026-10-02: an attendee in another tenant, zero suggestions.
    backend = _Backend(const [])
      ..emptyReason = 'attendeesunavailableorunknown';
    await pumpScreen(tester);
    await openAsk(tester);

    expect(find.text(findTimeUnreadableNote), findsOneWidget);
    expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
        findsOneWidget);
    expect(find.text('your free time'), findsWidgets);
    expect(find.text(CommandPlanCard.localCaption), findsOneWidget);
    expect(find.textContaining('Nobody is free'), findsNothing);

    await tester
        .tap(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)));
    await pumps(tester);
    await pumps(tester);
    expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);
    expect((writer.previewed.single as CreateEvent).attendees, [_dana]);
  });

  group('the ask\'s own words', () {
    // Tomorrow's weekday by name, so the day read is never today (whose
    // evening may already be over when the suite runs). From the real clock:
    // the screen reads DateTime.now() itself and this harness has no clock
    // to inject, so the day is derived the way the screen will derive it.
    late CalendarDate day;
    late String weekday;
    setUp(() {
      day = la.dateOf(DateTime.now().toUtc()).addDays(1);
      weekday = const [
        'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
        'sunday',
      ][day.weekday - 1];
    });
    DateTime local(int h, int m) => DateTime.fromMicrosecondsSinceEpoch(
        la.localDateTime(day, h, m).microsecondsSinceEpoch,
        isUtc: true);

    testWidgets('dinner on a day: the row opens on its length and its day, '
        'and Graph is asked about that evening, outside work time',
        (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await pumpScreen(tester);
      await openAsk(tester);

      expect(find.text('Asked for: ${shortDate(day)} · dinner'),
          findsOneWidget);
      expect(find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 90)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(SchedulingAskTile.windowKeyFor(
                  'email', 'c-ask', FindTimeWindow.theirs)),
              matching: find.text(shortDate(day))),
          findsOneWidget);
      expect(backend.minutes.single, 90);
      expect(backend.windows.single, (local(17, 30), local(20, 30)));
      expect(backend.domains.single, 'unrestricted');
    });

    testWidgets('the first open moves the pane to their day, and Next week '
        'to that weekday next week, where a grid press proposes',
        (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await pumpScreen(tester);
      final today = la.dateOf(DateTime.now().toUtc());
      await openAsk(tester);
      expect(find.text(dayTitle(day, today)), findsOneWidget,
          reason: 'the pane follows the first search to their day');

      final nextWeek = find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek));
      // The pill reads "Next Mon" only while the day it covers lies in next
      // week's Monday–Sunday (`findTimeWindowLabel`). On a Sunday, tomorrow
      // is next week's Monday, so Next week covers the Monday AFTER that and
      // the pill names the date instead — the same rule, from the real clock.
      // The rule itself is pinned on fixed dates in `find_time_search_test`
      // ('a week pill whose Friday has gone says the date it now means').
      final then = day.addDays(7);
      final nextMonday = today.addDays(1 - today.weekday).addDays(7);
      final inNextWeek = !then.isBefore(nextMonday) &&
          then.isBefore(nextMonday.addDays(7));
      expect(
          find.descendant(
              of: nextWeek,
              matching: find.text(inNextWeek
                  ? 'Next ${shortDate(day).split(' ').first}'
                  : shortDate(then))),
          findsOneWidget);
      await tester.tap(nextWeek);
      await pumps(tester);
      await pumps(tester);
      expect(find.text(dayTitle(then, today)), findsOneWidget);
      expect(backend.windows.last, (
        DateTime.fromMicrosecondsSinceEpoch(
            la.localDateTime(then, 17, 30).microsecondsSinceEpoch,
            isUtc: true),
        DateTime.fromMicrosecondsSinceEpoch(
            la.localDateTime(then, 20, 30).microsecondsSinceEpoch,
            isUtc: true),
      ));

      // The grid on that day: a press proposes that day.
      await tester.tap(find.byKey(DayPane.gridKey));
      await pumps(tester);
      await pumps(tester);
      final grid = tester.getRect(find.byType(DayGrid));
      await tester.tapAt(grid.center + Offset(0, grid.height / 4));
      await pumps(tester);
      await pumps(tester);
      final proposed = writer.previewed.single as CreateEvent;
      expect(la.dateOf(proposed.startUtc), then);
      expect(proposed.attendees, [_dana]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the thread bar\'s Find a time opens the ask on the same '
        'day and length', (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await pumpScreen(tester);
      await tester.tap(find.text('dinner on $weekday').first);
      await pumps(tester);
      await pressFindTime(tester);
      expect(
          find.descendant(
              of: find.byKey(SchedulingAskTile.windowKeyFor(
                  'email', 'c-ask', FindTimeWindow.theirs)),
              matching: find.text(shortDate(day))),
          findsOneWidget);
      expect(find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 90)),
          findsOneWidget);
      expect(backend.minutes.last, 90);
      expect(backend.windows.last, (local(17, 30), local(20, 30)));
    });

    testWidgets('one ask open at a time: an ask folded during its hint read '
        'does not pull the pane to its day', (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await seedAsk(
          key: 'c-ask2', messageId: 'ask-m2', subject: 'Northwind sync slot?');
      final holding = _HoldingStore(db)
        ..hold = Completer<void>()
        ..holdOnly = 'ask-m1';
      await pumpScreen(tester, storeOverride: holding);
      // The plain ask's window: this week from today, or Monday once the
      // week is over (a Friday evening run).
      final plainDay = findTimeWindowUtc(FindTimeWindow.thisWeek,
              now: DateTime.now(), zone: la, durationMinutes: 30)
          .firstDay;
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);
      // The other ask, opened while the dinner's read is out.
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask2')));
      await pumps(tester);
      await pumps(tester);
      expect(tester.widget<DayPane>(find.byType(DayPane)).day, plainDay);

      holding.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(tester.widget<DayPane>(find.byType(DayPane)).day, plainDay,
          reason: 'the folded dinner ask did not move the pane to $day');
      expect(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask2', 45)),
          findsOneWidget,
          reason: 'the open ask stays open');
    });

    testWidgets('a pill pressed while New message is open leaves it open',
        (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await pumpScreen(tester);
      await openAsk(tester);
      await tester.tap(find.byTooltip('New message'));
      await pumps(tester);
      expect(find.byType(NewMessageScreen), findsOneWidget);

      await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek)));
      await pumps(tester);
      await pumps(tester);
      expect(backend.windows, hasLength(2), reason: 'it searched again');
      expect(find.byType(NewMessageScreen), findsOneWidget,
          reason: 'following the search only moved the day underneath');
    });

    testWidgets('"tomorrow" is read against the day it was sent: sent two '
        'days ago, it names no day', (tester) async {
      await seedAsk(
          subject: 'dinner tomorrow?',
          body: 'could we grab dinner tomorrow?',
          minutesAgo: 2 * 24 * 60);
      await pumpScreen(tester);
      await openAsk(tester);
      expect(
          find.byKey(SchedulingAskTile.windowKeyFor(
              'email', 'c-ask', FindTimeWindow.theirs)),
          findsNothing,
          reason: 'the day it named has gone');
      // Dinner with no day is one Graph call per day left in the window —
      // one on a weekday evening, five once this week is over (a Friday
      // evening run) — each for a dinner's length.
      expect(backend.minutes, isNotEmpty);
      expect(backend.minutes, everyElement(90), reason: 'still a dinner');
    });
  });

  group('the one past rule and stale rows', () {
    MeetingTimeSuggestion slot(Duration from, Duration length) {
      final start = DateTime.now().toUtc().add(from);
      return MeetingTimeSuggestion(
          startUtc: start,
          endUtc: start.add(length),
          confidence: 50,
          organizerAvailability: 'free',
          attendeeAvailability: const {_dana: 'free'});
    }

    testWidgets('a slot under way is shown but refused as past: no card, '
        'nothing dry-run', (tester) async {
      backend = _Backend([
        slot(const Duration(minutes: -10), const Duration(minutes: 30)),
      ]);
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);
      await tester
          .tap(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)));
      await pumps(tester);
      expect(find.text('That time has passed.'), findsOneWidget);
      expect(find.byType(CommandPlanCard), findsNothing);
      expect(writer.previewed, isEmpty);
    });

    testWidgets('a row draws no slot that has ended', (tester) async {
      backend = _Backend([
        slot(const Duration(hours: -2), const Duration(minutes: 30)),
        slot(const Duration(days: 7), const Duration(minutes: 30)),
      ]);
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 1)),
          findsNothing,
          reason: 'the slot two hours ago is not offered');
      await tester
          .tap(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)));
      await pumps(tester);
      await pumps(tester);
      final proposed = writer.previewed.single as CreateEvent;
      expect(proposed.startUtc.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('an answer older than its lifetime is searched again', () {
      final at = DateTime.utc(2026, 10, 5, 9);
      expect(askResultStale(at, at.add(const Duration(minutes: 29))), isFalse);
      expect(askResultStale(at, at.add(askResultLifetime)), isFalse);
      expect(askResultStale(at, at.add(const Duration(minutes: 31))), isTrue);
      expect(askResultStale(null, at), isTrue);
    });

    test('the ask\'s words are read again for a newer message or a new day',
        () {
      final monday = CalendarDate(2026, 10, 5);
      expect(
          askHintsStale(
              readFor: 'm1', newest: 'm1', readOn: monday, today: monday),
          isFalse);
      expect(
          askHintsStale(
              readFor: 'm1', newest: 'm2', readOn: monday, today: monday),
          isTrue);
      expect(
          askHintsStale(
              readFor: 'm1',
              newest: 'm1',
              readOn: monday,
              today: monday.addDays(1)),
          isTrue,
          reason: '"tomorrow" read on Monday is today on Tuesday');
      expect(
          askHintsStale(readFor: 'm1', newest: null, readOn: monday,
              today: monday),
          isFalse);
    });

    testWidgets('the refresher runs on a synced outcome', (tester) async {
      // A suggested draft whose one offered time began an hour ago.
      final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c-old',
        replyToMessageId: 'old-m1',
        body: 'Happy to.\n\nWould any of these work? · …',
        contextJson: DraftProvenance.none.copyWith(calendar: {
          'slots': [
            {
              'start_utc': MessageStore.isoStamp(past),
              'end_utc': MessageStore.isoStamp(
                  past.add(const Duration(minutes: 30))),
            },
          ],
        }).encode(),
      );
      final sync = _SyncedCalendarSync(store, CalendarStore(db));
      await pumpScreen(tester, calendarSyncOverride: sync, processing: true);
      await pumps(tester);

      expect(sync.ticks, greaterThanOrEqualTo(1));
      expect(await store.getDraftForMessage('email', 'old-m1'), isNull,
          reason: 'its time has gone');
      final work = await db
          .customSelect(
            "SELECT status FROM work_items WHERE task_kind = 'draft' "
            "AND source = 'email' AND entity_id = 'old-m1'",
          )
          .get();
      expect(work.single.data['status'], 'pending');
    });

    testWidgets('the search\'s activity row counts its Graph calls',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      final rows = await store.recentActivity(limit: 20);
      final search = rows.firstWhere((r) =>
          r['kind'] == 'find_time' &&
          (r['detail_json'] as String? ?? '').contains('"source"'));
      expect(search['detail_json'], contains('"graph_calls":1'));
    });

    testWidgets('an ask dismissed while its slot is dry-run lands no card',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      writer.previewHold = Completer<void>();
      await tester
          .tap(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)));
      await pumps(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask')));
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(AppRail.asksHeaderKey), findsNothing);

      writer.previewHold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(find.byType(CommandPlanCard), findsNothing,
          reason: 'no invite for an ask nobody owes');
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
    });

    testWidgets('an ask that left and came back is folded, with no stale '
        'slots, and a press meanwhile is a blank event', (tester) async {
      await seedAsk();
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await openAskNextWeekTop(tester);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);

      // The owner replies: the ask leaves the column.
      final replied = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 30))
          .toIso8601String();
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'out-1',
        'conversation_key': 'c-ask',
        'direction': 'outbound',
        'subject': 'Re: $_subject',
        'from_address': 'owner@contoso.com',
        'received_at': replied,
        'body_text': 'Let me check.',
      });
      await db.customStatement(
          "UPDATE conversations SET last_outbound_at = ?, last_message_at = ? "
          "WHERE conversation_key = 'c-ask'",
          [replied, replied]);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.invalidate(schedulingAsksProvider);
      await container.read(conversationsProvider.notifier).load();
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(AppRail.asksHeaderKey), findsNothing);

      // A press meanwhile: nobody's ask is open, so a blank event.
      await tapEmptyGridTop(tester);
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      expect((writer.previewed.last as CreateEvent).attendees, isEmpty);
      await tester.tap(find.byKey(CommandPlanCard.cancelKey));
      await pumps(tester);

      // Dana writes again: the ask is back, folded, its old slots gone.
      await seedAsk(messageId: 'ask-m2', minutesAgo: 10);
      container.invalidate(schedulingAsksProvider);
      await container.read(conversationsProvider.notifier).load();
      await pumps(tester);
      await pumps(tester);
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsNothing);
      expect(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)),
          findsNothing,
          reason: 'folded');
      final before = writer.previewed.length;
      await tapEmptyGridTop(tester);
      expect(writer.previewed, hasLength(before + 1));
      expect((writer.previewed.last as CreateEvent).attendees, isEmpty,
          reason: 'a blank event, not an invite on the old search');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a newer message on an open ask folds its row: no slots '
        'of the old search, and a press is a blank event', (tester) async {
      await seedAsk();
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await openAskNextWeekTop(tester);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);

      // Dana writes again while the row is open; the ask never left.
      await seedAsk(messageId: 'ask-m2', minutesAgo: 10);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.invalidate(schedulingAsksProvider);
      await pumps(tester);
      await pumps(tester);
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsNothing);
      await tapEmptyGridTop(tester);
      expect((writer.previewed.last as CreateEvent).attendees, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the hint read', () {
    testWidgets('a newer inbound message is read again on the next open',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      expect(backend.minutes.single, 30);
      expect(
          find.byKey(SchedulingAskTile.windowKeyFor(
              'email', 'c-ask', FindTimeWindow.theirs)),
          findsNothing);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);

      // Dana writes again, about lunch on a day.
      await seedAsk(
          messageId: 'ask-m2',
          subject: 'lunch tuesday?',
          body: 'or lunch tuesday?',
          minutesAgo: 10);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      await container.read(conversationsProvider.notifier).load();
      await pumps(tester);
      await pumps(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);
      await pumps(tester);
      expect(backend.minutes.last, 60);
      expect(
          find.byKey(SchedulingAskTile.windowKeyFor(
              'email', 'c-ask', FindTimeWindow.theirs)),
          findsOneWidget);
    });

    testWidgets('a newer message that says nothing about a time is a new ask: '
        'the pills go back to 30 minutes and this week', (tester) async {
      await seedAsk(subject: 'lunch tuesday?', body: 'or lunch tuesday?');
      await pumpScreen(tester);
      await openAsk(tester);
      expect(backend.minutes.single, 60);
      expect(
          find.byKey(SchedulingAskTile.windowKeyFor(
              'email', 'c-ask', FindTimeWindow.theirs)),
          findsOneWidget);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);

      await seedAsk(
          messageId: 'ask-m2',
          subject: 'Quick sync',
          body: 'Can we do a quick sync about the deck?',
          minutesAgo: 10);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      await container.read(conversationsProvider.notifier).load();
      await pumps(tester);
      await pumps(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);
      await pumps(tester);
      expect(backend.minutes.last, 30, reason: 'a fresh entry, not lunch\'s');
      expect(
          find.byKey(SchedulingAskTile.windowKeyFor(
              'email', 'c-ask', FindTimeWindow.theirs)),
          findsNothing);
      // This week is the pill chosen, not a their-day no pill offers.
      final thisWeek = tester.widget<Material>(find
          .descendant(
              of: find.byKey(SchedulingAskTile.windowKeyFor(
                  'email', 'c-ask', FindTimeWindow.thisWeek)),
              matching: find.byType(Material))
          .first);
      expect(thisWeek.color, BondColors.onDarkTint);
    });

    testWidgets('following the search never closes the thread being read',
        (tester) async {
      await seedAsk();
      final monday = findTimeWindowUtc(FindTimeWindow.nextWeek,
              now: DateTime.now(), zone: la, durationMinutes: 30)
          .firstDay;
      // A meeting that Monday, so the column lists the day as a row.
      final nine = la.localDateTime(monday, 9, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'mon-1',
          subject: 'Northwind standup',
          startUtc: nine,
          endUtc: nine.add(const Duration(minutes: 30)),
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      await pumpScreen(tester);
      await openAsk(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.openKeyFor('email', 'c-ask')));
      await pumps(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);

      await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek)));
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget,
          reason: 'the thread stays open');
      // The day underneath moved: its row in the column is the selected one.
      // The DAY row, not a slot: the suite's slots sit a week from today,
      // which on a Monday is this very Monday, so the ask tile's slot rows
      // carry the same date and come first in the tree.
      final dated = find.textContaining(shortDate(monday));
      final slotTexts = find
          .descendant(of: find.byType(SchedulingAskTile), matching: dated)
          .evaluate()
          .toSet();
      final dayRow = dated
          .evaluate()
          .where((e) => !slotTexts.contains(e))
          .single;
      final row = find
          .ancestor(
              of: find.byElementPredicate((e) => e == dayRow),
              matching: find.byType(Material))
          .first;
      expect(tester.widget<Material>(row).color, BondColors.onDarkTint);
    });

    testWidgets('leaving the Day stop during the first read does not pull '
        'the owner back', (tester) async {
      await seedAsk();
      final holding = _HoldingStore(db)..hold = Completer<void>();
      await pumpScreen(tester, storeOverride: holding);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);
      await tester.tap(find.text('Needs You').first);
      await pumps(tester);
      expect(find.byType(DayPane), findsNothing);

      holding.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(find.byType(DayPane), findsNothing);
    });

    // The pressed length winning is the rule; the one read is what the
    // shared in-flight read ([_readAskHints]'s `??=`) gives, pinned so a
    // pill press can never start a second read of its own.
    testWidgets('a length pressed while the read is out stays, and both wait '
        'on the one read', (tester) async {
      await seedAsk(subject: 'dinner friday?', body: 'dinner friday?');
      final holding = _HoldingStore(db)..hold = Completer<void>();
      await pumpScreen(tester, storeOverride: holding);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask')));
      await pumps(tester);
      await tester.tap(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)));
      await pumps(tester);
      expect(backend.minutes, isEmpty, reason: 'both wait on the read');

      holding.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(backend.minutes, [45], reason: 'dinner\'s 90 did not win');
      expect(holding.askReads, 1);
    });

    testWidgets('a press on the thread bar reads the ask once, and searches '
        'when the read lands', (tester) async {
      await seedAsk();
      final holding = _HoldingStore(db)..hold = Completer<void>();
      await pumpScreen(tester, storeOverride: holding);
      // Needs You → the row opens the thread beside, wearing the chip.
      await tester.tap(find.text(_subject).first);
      await pumps(tester);
      await pressFindTime(tester);
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(backend.asked, isEmpty, reason: 'the search waits on the read');
      expect(holding.askReads, 1);

      holding.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(
          find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);
      expect(holding.askReads, 1);
    });
  });

  group('a press on empty grid time', () {
    /// Day → Grid → a tap on empty time in the body.
    Future<void> tapEmptyGrid(WidgetTester tester, {double at = 0.25}) async {
      if (find.byKey(DayPane.gridKey).evaluate().isEmpty) {
        await tester.tap(find.text('Day'));
        await pumps(tester);
      }
      if (find.byType(DayGrid).evaluate().isEmpty) {
        await tester.tap(find.byKey(DayPane.gridKey));
        await pumps(tester);
        await pumps(tester);
      }
      final grid = tester.getRect(find.byType(DayGrid));
      await tester.tapAt(grid.center + Offset(0, grid.height * at));
      await pumps(tester);
      await pumps(tester);
    }

    /// Lets the grid finish paging to the day it was moved to.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    /// A desktop drag of the ghost by [by], no hold.
    Future<void> dragGhost(WidgetTester tester, Offset by) async {
      final gesture = await tester
          .startGesture(tester.getCenter(find.byKey(DayGrid.proposalKey)));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(by / 2);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(by / 2);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await pumps(tester);
      await pumps(tester);
    }

    /// The ask opened and its Next week pressed: the pane on a day that is
    /// always ahead, so a dragged ghost is never refused as past.
    Future<void> openAskNextWeek(WidgetTester tester) async {
      await openAsk(tester);
      await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek)));
      await pumps(tester);
      await pumps(tester);
    }

    testWidgets('with no ask open: a blank event, named on the card, written '
        'with nobody on it and offered back', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      // Tomorrow: today's grid may already be behind the clock.
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester);

      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      final proposed = writer.previewed.single as CreateEvent;
      expect(proposed.subject, 'New event');
      expect(proposed.endUtc.difference(proposed.startUtc),
          const Duration(minutes: 30));
      expect(find.byKey(DayGrid.proposalKey), findsOneWidget,
          reason: 'the span is the Proposed ghost, not a tile');

      await tester.enterText(
          find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await pumps(tester);
      expect(
          find.descendant(
              of: find.byKey(DayGrid.proposalKey),
              matching: find.text('Dentist · Proposed', findRichText: true)),
          findsOneWidget,
          reason: 'the ghost takes the name as it is typed');
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      final written = writer.committed.single as CreateEvent;
      expect(written.subject, 'Dentist');
      expect(written.attendees, isEmpty);
      expect(written.transactionId, proposed.transactionId);
      expect(find.textContaining('Dentist'), findsWidgets,
          reason: 'the toast names it');
      expect(find.textContaining('New event'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an open row whose ask closed meanwhile makes a blank event',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      // The ask closes behind the open row (an invite sent elsewhere).
      await store.writeSchedulingAskLabel(
        source: 'email',
        conversationKey: 'c-ask',
        sourceMessageId: 'ask-m1',
        answer: 'no',
        origin: 'invite',
      );
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.invalidate(schedulingAsksProvider);
      await pumps(tester);
      // Tomorrow: today's grid may already be behind the clock.
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester);

      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      expect((writer.previewed.single as CreateEvent).attendees, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the ghost names the ask, the row says it is proposed, a '
        'drag re-proposes, and a tap flashes the card', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      // Mid-grid: a drag that starts near its bottom edge scrolls it.
      await tapEmptyGrid(tester, at: 0);

      final ghost = find.byKey(DayGrid.proposalKey);
      expect(
          find.descendant(
              of: ghost,
              matching:
                  find.text('Re: $_subject · Proposed', findRichText: true)),
          findsOneWidget);
      expect(
          find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsOneWidget);
      final first = writer.previewed.single as CreateEvent;
      final summaryBefore =
          tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data;

      // An hour earlier, dragged as this app is used: on the desktop, no
      // hold. The ghost is the ask's 30 minutes tall, which
      // gives the grid's scale.
      // Let the grid finish paging to the slot's day before grabbing.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final hour = tester.getSize(ghost).height * 2;
      final gesture = await tester.startGesture(tester.getCenter(ghost));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(Offset(0, -hour / 2));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset(0, -hour / 2));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await pumps(tester);
      await pumps(tester);
      final again = writer.previewed.last as CreateEvent;
      expect(writer.previewed, hasLength(2));
      expect(again.startUtc,
          first.startUtc.subtract(const Duration(hours: 1)));
      expect(again.endUtc.difference(again.startUtc),
          const Duration(minutes: 30));
      expect(again.attendees, [_dana]);
      expect(tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data,
          isNot(summaryBefore));
      expect(find.text('This emails: $_dana'), findsOneWidget);

      await tester.tap(find.byKey(DayGrid.proposalKey));
      await tester.pump();
      expect(
          tester.widget<CommandPlanCard>(find.byType(CommandPlanCard)).flash,
          1);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('in the week, a ghost dragged one column right re-proposes '
        'on the next day', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      // The week face first, then the press, as an owner working the week
      // would: the ghost is drawn in its day's column.
      await tester.tap(find.byKey(DayPane.gridKey));
      await pumps(tester);
      await tester.tap(find.byKey(DayPane.spanWeekKey));
      await pumps(tester);
      await pumps(tester);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tapEmptyGrid(tester, at: 0);
      final first = writer.previewed.single as CreateEvent;
      final ghost = find.byKey(DayGrid.proposalKey);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final width = tester.getSize(ghost).width;
      // Held a moment before moving sideways: a quick horizontal drag in the
      // week is the page swipe's (day_grid_test's week drag holds too). A
      // little past one column: the landing column is read from the
      // feedback's LEFT edge, and exactly one column's width can land a
      // fraction of a pixel short of the next.
      final gesture = await tester.startGesture(tester.getCenter(ghost));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(Offset((width + 8) / 2, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset((width + 8) / 2, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await pumps(tester);
      await pumps(tester);
      final moved = writer.previewed.last as CreateEvent;
      expect(la.dateOf(moved.startUtc), la.dateOf(first.startUtc).addDays(1));
      expect(la.toLocal(moved.startUtc).hour, la.toLocal(first.startUtc).hour);
      expect(moved.attendees, [_dana]);
      expect(
          find.text(
              'Proposed: ${shortDate(la.dateOf(moved.startUtc))} · '
              '${formatEventRange(la, moved.startUtc, moved.endUtc)}'),
          findsOneWidget,
          reason: 'the row says the new day');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('while the card\'s write is out, the ghost holds still and '
        'the grid proposes nothing new', (tester) async {
      await seedAsk();
      writer.hold = Completer<void>();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
      await pumps(tester);
      expect(writer.committed, hasLength(1));
      final before = writer.previewed.length;

      await dragGhost(tester, const Offset(0, -42));
      await tapEmptyGrid(tester, at: -0.2);
      expect(writer.previewed, hasLength(before),
          reason: 'no dry run under the write in the air');
      expect(find.byType(CommandPlanCard), findsOneWidget);

      writer.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(find.byType(CommandPlanCard), findsNothing);
      expect(find.byKey(AppRail.asksHeaderKey), findsNothing,
          reason: 'the invite closed the ask');
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a ghost resized into the next day is refused, said',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tester.tap(find.byKey(DayPane.gridKey));
      await pumps(tester);
      await tester.tap(find.byKey(DayPane.spanWeekKey));
      await pumps(tester);
      await settle(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      final before = writer.previewed.length;

      // A hovering mouse shows the end band; pressed 4 px above the bottom
      // and dragged into the next column.
      final r = tester.getRect(find.byKey(DayGrid.proposalKey));
      final from = Offset(r.center.dx, r.bottom - 4);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: from - const Offset(0, 1));
      await gesture.moveTo(from);
      await tester.pump();
      await tester.pump();
      await gesture.down(from);
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(Offset((r.width + 4) / 2, 10));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset((r.width + 4) / 2, 10));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await gesture.removePointer();
      await pumps(tester);

      expect(find.text(DayGrid.resizeLeavesDay), findsOneWidget);
      expect(writer.previewed, hasLength(before));
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a new card never flashes as it appears', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.tap(find.byKey(DayGrid.proposalKey));
      await tester.pump();
      expect(
          tester.widget<CommandPlanCard>(find.byType(CommandPlanCard)).flash,
          1);
      await tester.enterText(
          find.byKey(DayCommandBar.fieldKey), 'add focus time tomorrow 3pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 700));
      expect(
          tester.widget<CommandPlanCard>(find.byType(CommandPlanCard)).flash,
          0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a press on yesterday is refused, said: no card, nothing '
        'dry-run', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Previous day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      expect(find.text('That time has passed.'), findsOneWidget);
      expect(find.byType(CommandPlanCard), findsNothing);
      expect(writer.previewed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with an ask open, a press on yesterday is refused too, '
        'never a blank event in its place', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      // Back to yesterday from wherever the search moved the pane.
      final yesterday = la.dateOf(DateTime.now().toUtc()).addDays(-1);
      for (var i = 0;
          i < 10 &&
              tester.widget<DayPane>(find.byType(DayPane)).day != yesterday;
          i++) {
        await tester.tap(find.byTooltip('Previous day'));
        await pumps(tester);
      }
      await tapEmptyGrid(tester, at: 0);
      expect(find.text('That time has passed.'), findsOneWidget);
      expect(find.byType(CommandPlanCard), findsNothing);
      expect(writer.previewed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a ghost moved across midnight says to pick a time inside '
        'the day; one stretched across it says to move it', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      final before = writer.previewed.length;
      final tomorrow = la.dateOf(DateTime.now().toUtc()).addDays(1);
      // The grid hands a cross-midnight span up as it is (only a resize is
      // refused there); handed straight in, as kalender would.
      final grid = tester.widget<DayGrid>(find.byType(DayGrid));
      final late = la.localDateTime(tomorrow, 23, 45).toUtc();
      grid.onProposalChanged!(late, late.add(const Duration(minutes: 30)));
      await pumps(tester);
      expect(find.text(moveLeavesDay), findsOneWidget);
      expect(writer.previewed, hasLength(before));

      grid.onProposalChanged!(late, late.add(const Duration(minutes: 90)));
      await pumps(tester);
      expect(find.text(DayGrid.resizeLeavesDay), findsOneWidget);
      expect(writer.previewed, hasLength(before));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an overnight proposal shortened inside its days re-proposes; '
        'stretched past them it is refused', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      final tomorrow = la.dateOf(DateTime.now().toUtc()).addDays(1);
      final eleven = la.localDateTime(tomorrow, 23, 0).toUtc();
      // An overnight blank event, 23:00–01:00, handed in as kalender would.
      tester.widget<DayGrid>(find.byType(DayGrid)).onCreateRequested!(
          eleven, eleven.add(const Duration(hours: 2)));
      await pumps(tester);
      await pumps(tester);
      final overnight = writer.previewed.last as CreateEvent;
      expect(overnight.endUtc.difference(overnight.startUtc),
          const Duration(hours: 2));
      final before = writer.previewed.length;

      // Its end pulled back to 00:30: still inside the days it covered.
      tester.widget<DayGrid>(find.byType(DayGrid)).onProposalChanged!(
          eleven, eleven.add(const Duration(minutes: 90)));
      await pumps(tester);
      await pumps(tester);
      expect(writer.previewed, hasLength(before + 1));
      expect((writer.previewed.last as CreateEvent).endUtc,
          eleven.add(const Duration(minutes: 90)));
      expect(find.text(DayGrid.resizeLeavesDay), findsNothing);

      // Its end pushed into the day after: out of its days, refused.
      tester.widget<DayGrid>(find.byType(DayGrid)).onProposalChanged!(
          eleven, eleven.add(const Duration(hours: 26)));
      await pumps(tester);
      expect(find.text(DayGrid.resizeLeavesDay), findsOneWidget);
      expect(writer.previewed, hasLength(before + 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refusal leaves the Undo of the write just done on z',
        (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      expect(writer.committed.single, isA<CreateEvent>());
      expect(find.text('Undo'), findsOneWidget);

      // Refused: yesterday.
      await tester.tap(find.byTooltip('Previous day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Previous day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      expect(find.text('That time has passed.'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await pumps(tester);
      await pumps(tester);
      expect(writer.committed.last, isA<DeleteEvent>(),
          reason: 'z still undid the event just written');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an Enter while the card writes: the new card\'s grid is '
        'live, and a press proposes again', (tester) async {
      writer = _RecordingWriter();
      writer.hold = Completer<void>();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      // Nobody on it: the press writes at once, and the write is held.
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      expect(writer.committed, hasLength(1));

      await tester.enterText(
          find.byKey(DayCommandBar.fieldKey), 'add focus time tomorrow 3pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(find.byType(CommandPlanCard), findsOneWidget);
      final before = writer.previewed.length;

      await tapEmptyGrid(tester, at: -0.35);
      expect(writer.previewed, hasLength(before + 1),
          reason: 'the grid is not held by the old card\'s write');
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);

      writer.hold!.complete();
      await pumps(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a typed Enter after a blank event is the typed command\'s '
        'card: no name field, no carried name', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await tester.enterText(
          find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await pumps(tester);

      await tester.enterText(
          find.byKey(DayCommandBar.fieldKey), 'add focus time tomorrow 3pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(find.byType(CommandPlanCard), findsOneWidget);
      expect(find.byKey(CommandPlanCard.subjectKey), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(DayGrid.proposalKey),
              matching: find.textContaining('Dentist', findRichText: true)),
          findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a dragged invite still labels the message its slot was '
        'picked for', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      // Dana writes again while the card stands.
      await seedAsk(
          messageId: 'ask-m2',
          body: 'Or could we do Thursday instead?',
          minutesAgo: 10);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.invalidate(schedulingAsksProvider);
      await pumps(tester);

      await dragGhost(tester, const Offset(0, 42));
      expect(writer.previewed, hasLength(2), reason: 'it re-proposed');
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
      await pumps(tester);
      await pumps(tester);
      final labels = await store.decisionLabels();
      expect(labels.single['source_message_id'], 'ask-m1');
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget,
          reason: 'the newer request keeps its ask');
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('an ask\'s ghost dragged keeps its card, its ghost and the '
        'row\'s Proposed line on screen through the dry run', (tester) async {
      await seedAsk();
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      expect(find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsOneWidget);

      writer.previewHold = Completer<void>();
      await dragGhost(tester, const Offset(0, 42));
      expect(find.byType(CommandPlanCard), findsOneWidget,
          reason: 'the invite\'s card stands while the new span is dry-run');
      expect(find.byKey(DayGrid.proposalKey), findsOneWidget);
      expect(find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsOneWidget, reason: 'the row still says it is proposed');
      writer.previewHold!.complete();
      writer.previewHold = null;
      await pumps(tester);
      expect(writer.previewed, hasLength(2));
      final again = writer.previewed.last as CreateEvent;
      expect(again.attendees, [_dana]);
      expect(find.byType(CommandPlanCard), findsOneWidget);
      expect(find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a second invite for the same ask, put up while the first '
        'is in the air, goes when the first closes the ask', (tester) async {
      await seedAsk();
      writer.hold = Completer<void>();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
      await pumps(tester);
      expect(writer.committed, hasLength(1));

      // A typed Enter frees the grid; a press then is the ask's invite again.
      await tester.enterText(
          find.byKey(DayCommandBar.fieldKey), 'add focus time tomorrow 3pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      await tapEmptyGrid(tester, at: -0.35);
      expect((writer.previewed.last as CreateEvent).attendees, [_dana]);
      expect(find.byType(CommandPlanCard), findsOneWidget);

      writer.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(find.byType(CommandPlanCard), findsNothing,
          reason: 'the ask it invites for has just been answered');
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap on the ghost while the card writes flashes nothing',
        (tester) async {
      writer = _RecordingWriter();
      writer.hold = Completer<void>();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      expect(writer.committed, hasLength(1));

      await tester.tap(find.byKey(DayGrid.proposalKey));
      await tester.pump();
      expect(
          tester.widget<CommandPlanCard>(find.byType(CommandPlanCard)).flash,
          0);
      writer.hold!.complete();
      await pumps(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a blank ghost dragged keeps its card on screen through the '
        'dry run', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.enterText(
          find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await pumps(tester);

      writer.previewHold = Completer<void>();
      await dragGhost(tester, const Offset(0, 42));
      expect(find.byType(CommandPlanCard), findsOneWidget,
          reason: 'the old card stands while the new span is dry-run');
      expect(find.byKey(DayGrid.proposalKey), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(CommandPlanCard.subjectKey))
              .controller!
              .text,
          'Dentist',
          reason: 'the name as typed, not the old write\'s "New event"');
      writer.previewHold!.complete();
      writer.previewHold = null;
      await pumps(tester);
      expect((writer.previewed.last as CreateEvent).subject, 'Dentist');
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a blank event with a known name on it: the press shows the '
        'strip, Send invites them, and no Undo is offered', (tester) async {
      await seedAsk();
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.enterText(
          find.byKey(CommandPlanCard.subjectKey), 'Review');
      await tester.enterText(find.byKey(CommandPlanCard.withKey), 'Dana');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumps(tester);
      expect(find.byKey(CommandPlanCard.chipKeyFor(_dana)), findsOneWidget);

      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await pumps(tester);
      expect(find.byType(WriteConfirmStrip), findsOneWidget);
      expect(writer.committed, isEmpty);
      await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
      await pumps(tester);
      final written = writer.committed.single as CreateEvent;
      expect(written.subject, 'Review');
      expect(written.attendees, [_dana]);
      expect(written.isOnlineMeeting, isTrue);
      expect(find.text('Undo'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a blank ghost dragged after naming people re-proposes with '
        'them', (tester) async {
      await seedAsk();
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.enterText(find.byKey(CommandPlanCard.withKey), 'Dana');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumps(tester);
      expect(find.byKey(CommandPlanCard.chipKeyFor(_dana)), findsOneWidget);

      await dragGhost(tester, const Offset(0, 42));
      final again = writer.previewed.last as CreateEvent;
      expect(again.attendees, [_dana]);
      expect(again.isOnlineMeeting, isTrue);
      expect(find.byKey(CommandPlanCard.chipKeyFor(_dana)), findsOneWidget,
          reason: 'the new card starts from the chips');
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a blank ghost dragged keeps the name typed', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      await tester.enterText(
          find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await pumps(tester);
      final first = writer.previewed.last as CreateEvent;

      await dragGhost(tester, const Offset(0, 42));
      final again = writer.previewed.last as CreateEvent;
      expect(again.startUtc, isNot(first.startUtc));
      expect(again.subject, 'Dentist');
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget,
          reason: 'still the blank event\'s card');
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the Proposed line goes when the card is dismissed, and a '
        'dismissed ask takes its card and ghost with it', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester, at: 0);
      expect(find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsOneWidget);
      await tester.tap(find.byKey(CommandPlanCard.cancelKey));
      await pumps(tester);
      expect(find.byKey(SchedulingAskTile.proposedKeyFor('email', 'c-ask')),
          findsNothing);

      // Again, then the ask's own ×.
      await tapEmptyGrid(tester, at: 0);
      expect(find.byType(CommandPlanCard), findsOneWidget);
      await tester
          .tap(find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask')));
      await pumps(tester);
      await pumps(tester);
      expect(find.byType(CommandPlanCard), findsNothing);
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with an ask open: that ask\'s invite on the span',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      // Next week: today's grid may already be behind the clock.
      await openAskNextWeek(tester);
      await tapEmptyGrid(tester);

      expect(find.byKey(CommandPlanCard.subjectKey), findsNothing);
      final proposed = writer.previewed.single as CreateEvent;
      expect(proposed.attendees, [_dana]);
      expect(proposed.subject, 'Re: $_subject');
      // The ask's own length (its message asks for 30 minutes).
      expect(proposed.endUtc.difference(proposed.startUtc),
          const Duration(minutes: 30));
      expect(find.text('This emails: $_dana'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Open thread opens the thread, wearing the chip', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openThreadFromDay(tester);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
  });

  testWidgets('a thread that is not asking is not a scheduling ask',
      (tester) async {
    await seedAsk();
    await store.writeDecision(
      'email',
      'ask-m1',
      fakeDecision(fakeAnswers(intent: 'question', choiceP: 0.9)),
      qhash: DecisionHeads.expectedQhash,
      ownerKnown: true,
    );
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.byKey(AppRail.asksHeaderKey), findsNothing);
  });

  /// Needs You with nothing in the main pane: the row opens BESIDE.
  Future<void> openThreadBeside(WidgetTester tester) async {
    await tester.tap(find.text(_subject).first);
    await pumps(tester);
    expect(find.byKey(SidePanelHost.closeKey), findsOneWidget,
        reason: 'the thread is open beside');
  }

  /// The ask's decision overwritten: the model reads it as a question.
  Future<void> notScheduling() => store.writeDecision(
        'email',
        'ask-m1',
        fakeDecision(fakeAnswers(intent: 'question', choiceP: 0.9)),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );

  group('Find a time on the thread bar', () {
    testWidgets('a listed ask opened beside: the press writes nothing and '
        'lands on the Day stop with the ask open and searched',
        (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openThreadBeside(tester);
      await pressFindTime(tester);

      expect(await store.decisionLabels(), isEmpty);
      expect(find.byKey(SidePanelHost.closeKey), findsNothing,
          reason: 'the thread beside went with the trip to the Day stop');
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(
          find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget,
          reason: 'the row is open and its search ran');
      expect(backend.asked.single, [_dana]);
      final rows = await store.recentActivity(limit: 20);
      expect(
        [for (final r in rows) r['detail_json'] as String? ?? ''],
        contains(contains('"graph_calls":1')),
      );
    });

    testWidgets('on a thread the model did not flag: the owner\'s yes makes '
        'it an ask, open in the column', (tester) async {
      await seedAsk();
      await notScheduling();
      await pumpScreen(tester);
      await openThreadBeside(tester);
      await pressFindTime(tester);

      final label = (await store.decisionLabels()).single;
      expect(label['question'], 'scheduling_ask');
      expect(label['answer'], 'yes');
      expect(label['origin'], 'owner');
      expect(label['source_message_id'], 'ask-m1');
      expect(label['created_at'] as String,
          matches(RegExp(r'\.\d{6}Z$')));
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(
          find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);
      expect(backend.asked.single, [_dana]);
    });

    testWidgets('after a dismiss, the press brings the ask back: the '
        'owner\'s newer word wins', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      await openAsk(tester);
      await tester
          .tap(find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask')));
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(AppRail.asksHeaderKey), findsNothing);

      await tester.tap(find.text('Needs You').first);
      await pumps(tester);
      await openThreadBeside(tester);
      await pressFindTime(tester);
      expect([for (final r in await store.decisionLabels()) r['answer']],
          ['yes']);
      expect(find.text('SCHEDULING ASKS · 1'), findsOneWidget);
      expect(
          find.byKey(SchedulingAskTile.slotKeyFor('email', 'c-ask', 0)),
          findsOneWidget);
    });

    testWidgets('not offered when the owner wrote last', (tester) async {
      await seedAsk();
      await notScheduling();
      await pumpScreen(tester);
      await openThreadBeside(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);

      // The owner replies; the thread stays open beside as the list reloads.
      await db.customUpdate(
        'UPDATE conversations SET last_outbound_at = ? '
        "WHERE conversation_key = 'c-ask'",
        variables: [Variable(MessageStore.isoStamp(DateTime.now()))],
      );
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      await container.read(conversationsProvider.notifier).load();
      await pumps(tester);
      expect(find.byKey(SidePanelHost.closeKey), findsOneWidget);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsNothing);
    });

    testWidgets('not offered with nobody to answer', (tester) async {
      await seedAsk(participantsJson: '[]');
      await notScheduling();
      await pumpScreen(tester);
      await openThreadBeside(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsNothing);
    });

    testWidgets('a double press writes one yes', (tester) async {
      await seedAsk();
      await notScheduling();
      await pumpScreen(tester);
      await openThreadBeside(tester);
      await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
      await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
      await pumps(tester);
      await pumps(tester);
      final yes = [
        for (final l in await store.decisionLabels())
          if (l['answer'] == 'yes') l,
      ];
      expect(yes, hasLength(1));
    });

    testWidgets('not offered before the zone resolves: no asks column to '
        'land on', (tester) async {
      await seedAsk();
      await pumpScreen(tester, zoneResolves: false);
      await openThreadBeside(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsNothing);
      expect(backend.asked, isEmpty, reason: 'no search without a clock');
    });

    testWidgets('not offered when the calendar has no mirror to show (scope '
        'missing)', (tester) async {
      await seedAsk();
      await pumpScreen(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.read(calendarAvailabilityProvider.notifier).state =
          CalendarAvailability.scopeMissing;
      await pumps(tester);
      await openThreadBeside(tester);
      expect(find.byKey(ThreadActionBar.findTimeKey), findsNothing);
    });
  });

  group('the model reads the ask (ask_read)', () {
    /// The model's answer, every key the schema requires.
    Map<String, dynamic> read(List<String> when,
            {String time = '', String meal = 'none'}) =>
        {
          'evidence': 'Dana asks to meet.',
          'asks_for_time': true,
          'when': when,
          'time': time,
          'duration': '',
          'meal': meal,
        };

    AskReader readerWith(ScriptedLlm llm) => AskReader(
          store: store,
          client: () => llm,
          log: ActivityLog(store),
          zone: () => la,
        );

    /// The screen's own `ask_read` rows (the reader writes one of its own
    /// per call, without `agree`).
    Future<List<String>> verdicts() async => [
          for (final r in await store.recentActivity(limit: 40))
            if (r['kind'] == 'ask_read' &&
                (r['detail_json'] as String? ?? '').contains('"agree"'))
              r['detail_json'] as String,
        ];

    /// The local days the backend was asked about, in call order.
    List<CalendarDate> askedDays() =>
        [for (final (start, _) in backend.windows) la.dateOf(start)];

    /// The next [weekday] from today (today when it is today's).
    CalendarDate next(int weekday) {
      final today = la.dateOf(DateTime.now().toUtc());
      return today.addDays((weekday - today.weekday + 7) % 7);
    }

    // The rules read the last day named: the ruled-out Friday.
    const notFriday =
        "How about Monday instead? Friday doesn't work for me.";

    testWidgets("the model's reading replaces the rules': the row and the "
        'search name Monday', (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final llm = ScriptedLlm(delay: Duration.zero)
        ..answer('ask_read', read(['Monday']));
      await seedAsk(body: notFriday, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pumps(tester);

      final monday = next(DateTime.monday);
      expect(llm.calls.map((c) => c.schemaName), ['ask_read']);
      expect(find.text('Asked for: ${shortDate(monday)}'), findsOneWidget);
      expect(askedDays(), [monday],
          reason: 'a quick reading seeds the first search: one search, '
              'on Monday');
      final rows = await verdicts();
      expect(rows.single, contains('"applied":true'));
      expect(rows.single, contains('"agree":false'));
      expect(rows.single, contains('"cached":false'));
    });

    testWidgets('a reading that agrees leaves one search', (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final llm = ScriptedLlm(delay: Duration.zero)
        ..answer('ask_read', read(['Friday'], meal: 'dinner'));
      await seedAsk(
          body: 'Could we grab dinner on Friday to go over the plan?',
          minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pumps(tester);

      expect(llm.calls, hasLength(1));
      expect(backend.windows, hasLength(1));
      final rows = await verdicts();
      expect(rows.single, contains('"agree":true'));
      expect(rows.single, contains('"applied":false'));
    });

    testWidgets('a slow read: the rules search first, the model refines and '
        'searches once more', (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final gate = Completer<void>();
      final llm = ScriptedLlm(delay: Duration.zero)
        ..scriptFor('ask_read', [gate, read(['Monday'])]);
      await seedAsk(body: notFriday, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      expect(backend.windows, isEmpty,
          reason: 'the first search waits for the model');

      await tester.pump(const Duration(milliseconds: 350));
      await pumps(tester);
      expect(backend.windows, hasLength(1),
          reason: 'past the wait the rules search alone');
      final monday = next(DateTime.monday);
      expect(askedDays().single, isNot(monday));
      expect(await verdicts(), isEmpty);

      gate.complete();
      await pumps(tester);
      await pumps(tester);
      expect(askedDays(), hasLength(2), reason: 'one search more, no other');
      expect(askedDays().last, monday);
      expect(find.text('Asked for: ${shortDate(monday)}'), findsOneWidget);
      expect((await verdicts()).single, contains('"applied":true'));
    });

    testWidgets('a pill the owner pressed survives a late reading',
        (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final gate = Completer<void>();
      final llm = ScriptedLlm(delay: Duration.zero)
        ..scriptFor('ask_read', [gate, read(['Monday'])]);
      await seedAsk(body: notFriday, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await pumps(tester);
      expect(backend.windows, hasLength(1), reason: 'the rules searched');

      await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek)));
      await pumps(tester);
      await pumps(tester);
      expect(backend.windows, hasLength(2), reason: 'the pill searched');

      gate.complete();
      await pumps(tester);
      await pumps(tester);
      final monday = next(DateTime.monday);
      expect(find.text('Asked for: ${shortDate(monday)}'), findsOneWidget,
          reason: "the row says the model's day");
      expect(backend.windows, hasLength(3),
          reason: 'one search more for the new reading');
      // Next week as the pill reads it with the model's Monday, not their
      // day: the owner's pill was not re-seeded.
      final model = readAskHintsFromRead(
        read: AskRead.fromJson(read(['Monday'])),
        subject: _subject,
        body: notFriday,
        now: DateTime.now(),
        zone: la,
      );
      final nextWeek = findTimeWindowUtc(FindTimeWindow.nextWeek,
          now: DateTime.now(),
          zone: la,
          durationMinutes: 30,
          hints: model);
      expect(askedDays().last, nextWeek.firstDay);
      expect((await verdicts()).single, contains('"applied":true'));
    });

    /// Next week as the pill reads it with the model's Monday on the
    /// [notFriday] ask: its first day.
    CalendarDate nextWeekWithMonday() {
      final model = readAskHintsFromRead(
        read: AskRead.fromJson(read(['Monday'])),
        subject: _subject,
        body: notFriday,
        now: DateTime.now(),
        zone: la,
      );
      return findTimeWindowUtc(FindTimeWindow.nextWeek,
              now: DateTime.now(),
              zone: la,
              durationMinutes: 45,
              hints: model)
          .firstDay;
    }

    Future<void> pressPills(WidgetTester tester) async {
      await tester.tap(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45)));
      await pumps(tester);
      await tester.tap(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.nextWeek)));
      await pumps(tester);
    }

    testWidgets("a pill the owner pressed during the wait survives the "
        "model's reading", (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final gate = Completer<void>();
      final llm = ScriptedLlm(delay: Duration.zero)
        ..scriptFor('ask_read', [gate, read(['Monday'])]);
      await seedAsk(body: notFriday, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      expect(backend.windows, isEmpty, reason: 'still in the wait');

      await pressPills(tester);
      expect(backend.windows, isEmpty,
          reason: "the pills' search waits for the reading too");
      gate.complete();
      await pumps(tester);
      await pumps(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await pumps(tester);

      final monday = next(DateTime.monday);
      expect(find.text('Asked for: ${shortDate(monday)}'), findsOneWidget);
      expect(backend.minutes.last, 45);
      expect(askedDays().last, nextWeekWithMonday());
      expect(backend.windows, hasLength(1),
          reason: 'the one search, on the pills, after the reading');
    });

    testWidgets("a stale answer forgotten on reopen keeps the owner's pills",
        (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      // No model the first time (nothing stored), Monday the second.
      final llm = ScriptedLlm(delay: Duration.zero)
        ..scriptFor('ask_read', [
          const LlmUnavailableException('no server'),
          read(['Monday']),
        ]);
      await seedAsk(body: notFriday, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pressPills(tester);
      await pumps(tester);
      expect(backend.minutes.last, 45);

      // Folded and opened again with the answer stale: the words are read
      // again, and this time the model differs from the rules.
      InboxScreen.askResultLifetimeOverride = Duration.zero;
      final row = find.byKey(SchedulingAskTile.rowKeyFor('email', 'c-ask'));
      await tester.tap(row);
      await pumps(tester);
      await tester.tap(row);
      await pumps(tester);
      await pumps(tester);
      await pumps(tester);

      expect(llm.calls, hasLength(2));
      final monday = next(DateTime.monday);
      expect(find.text('Asked for: ${shortDate(monday)}'), findsOneWidget);
      expect(backend.minutes.last, 45);
      expect(askedDays().last, nextWeekWithMonday(),
          reason: 'Next week stands; their day would be the Monday itself');
      expect((await verdicts()).single, contains('"applied":true'));
    });

    testWidgets("the model saying nobody asked leaves the rules' day",
        (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final llm = ScriptedLlm(delay: Duration.zero)
        ..answer('ask_read', {
          'evidence': 'Not asking for a time.',
          'asks_for_time': false,
          'when': <String>[],
          'time': '',
          'duration': '',
          'meal': 'none',
        });
      await seedAsk(
          body: 'Could we grab dinner on Friday to go over the plan?',
          minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pumps(tester);

      final friday = next(DateTime.friday);
      expect(find.textContaining('Asked for: '), findsOneWidget);
      expect(find.textContaining('· dinner'), findsOneWidget,
          reason: "the rules' dinner stands");
      expect(backend.windows, hasLength(1));
      // The rules' Friday: today's dinner gone rolls a week, which the
      // search then asks about.
      expect(askedDays().single.weekday, DateTime.friday);
      expect(askedDays().single.isBefore(friday), isFalse);
      final rows = await verdicts();
      expect(rows.single, contains('"agree":false'));
      expect(rows.single, contains('"applied":false'));
    });

    testWidgets('model off: the rules stand, no toast, no activity row',
        (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      final llm = ScriptedLlm(delay: Duration.zero)
        ..answer('ask_read', const LlmUnavailableException('no server'));
      await seedAsk(
          body: 'Could we grab dinner on Friday to go over the plan?',
          minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pumps(tester);

      expect(llm.calls, hasLength(1));
      expect(backend.windows, hasLength(1));
      expect(find.textContaining('Asked for: '), findsOneWidget);
      expect(find.textContaining('· dinner'), findsOneWidget,
          reason: "the rules' reading");
      expect(find.byType(SnackBar), findsNothing);
      final rows = await store.recentActivity(limit: 40);
      expect(rows.where((r) => r['kind'] == 'ask_read'), isEmpty);
    });

    testWidgets('two alternatives: both days asked, both said',
        (tester) async {
      InboxScreen.askReadWaitOverride = const Duration(milliseconds: 300);
      const body = 'Could we meet next Tuesday or next Thursday afternoon?';
      final answer =
          read(['next Tuesday', 'next Thursday'], time: 'afternoon');
      final llm = ScriptedLlm(delay: Duration.zero)
        ..answer('ask_read', answer);
      await seedAsk(body: body, minutesAgo: 1);
      await pumpScreen(tester, askReader: readerWith(llm));
      await openAsk(tester);
      await pumps(tester);

      // "next <weekday>" is strictly after today, so neither day is today
      // and neither can run out of afternoon; the days themselves are the
      // resolution layer's, which `ask_hints_test` pins.
      final want = readAskHintsFromRead(
        read: AskRead.fromJson(answer),
        subject: _subject,
        body: body,
        now: DateTime.now(),
        zone: la,
      );
      expect(want.days, hasLength(2));
      expect(askedDays(), want.days, reason: 'one call per day named');
      expect(
          find.text('Asked for: ${shortDate(want.days.first)} or '
              '${shortDate(want.days.last)} · afternoon'),
          findsOneWidget);
    });
  });
}
