import 'dart:async';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show MeetingTimeSuggestion, MeetingTimes, WritePreview;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart'
    show conversationsProvider;
import 'package:bond_inbox/providers/day_providers.dart'
    show schedulingAsksProvider;
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show CalendarDate, CalendarEvent;
import 'package:bond_inbox/services/calendar/day_items.dart'
    show dayTitle, formatEventRange, shortDate;
import 'package:bond_inbox/services/calendar/find_time.dart'
    show findTimeUnreadableNote, findTimeWindowUtc;
import 'package:bond_inbox/theme/tokens.dart' show BondColors;
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/command_plan_card.dart'
    show CommandPlanCard;
import 'package:bond_inbox/widgets/day_command_bar.dart' show DayCommandBar;
import 'package:bond_inbox/widgets/day_grid.dart' show DayGrid;
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/find_time_pane.dart';
import 'package:bond_inbox/widgets/scheduling_ask_rows.dart';
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart'
    show WriteConfirmStrip;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
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

  @override
  Future<Map<String, Object?>?> getMessageRow(
      String source, String sourceMessageId) async {
    if (sourceMessageId.startsWith('ask-')) {
      askReads += 1;
      final h = hold;
      if (h != null) await h.future;
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

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
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

  tearDown(() => db.close());

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
      {bool zoneResolves = true, MessageStore? storeOverride}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calendarSync = _QuietCalendarSync(store, CalendarStore(db));
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
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.available),
        // A zone that never resolves is the one a slow mailbox read leaves.
        calendarZoneProvider.overrideWith((ref) =>
            zoneResolves ? Future.value(la) : Completer<CalendarZone>().future),
        calendarBackendProvider.overrideWithValue(backend),
        calendarWritesProvider.overrideWithValue(writer),
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

  Future<void> openPane(WidgetTester tester) async {
    await openThreadFromDay(tester);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
    await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
    await pumps(tester);
    expect(find.byType(FindTimePane), findsOneWidget);
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
    expect(searches.single, contains('"surface":"column"'));

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

    // The thread no longer offers Find a time.
    await tester.tap(find.text('Needs You').first);
    await pumps(tester);
    await tester.tap(find.text(_subject).first);
    await pumps(tester);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsNothing);
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
      expect(
          find.descendant(
              of: nextWeek,
              matching: find.text('Next ${shortDate(day).split(' ').first}')),
          findsOneWidget);
      await tester.tap(nextWeek);
      await pumps(tester);
      await pumps(tester);
      final then = day.addDays(7);
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

    testWidgets('the pane opens on the same day and length', (tester) async {
      await seedAsk(
          subject: 'dinner on $weekday',
          body: 'could we grab dinner on $weekday?');
      await pumpScreen(tester);
      await openPane(tester);
      await pumps(tester);
      expect(
          find.descendant(
              of: find.byKey(
                  FindTimePane.windowKeyFor(FindTimeWindow.theirs)),
              matching: find.text(shortDate(day))),
          findsOneWidget);
      expect(find.byKey(FindTimePane.durationKeyFor(90)), findsOneWidget);
      expect(backend.minutes.last, 90);
      expect(backend.windows.last, (local(17, 30), local(20, 30)));
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
      final row = find
          .ancestor(
              of: find.textContaining(shortDate(monday)),
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

    testWidgets('a length pressed while the read is out stays', (tester) async {
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

    testWidgets('the pane waits on one read, however often it is built',
        (tester) async {
      await seedAsk();
      final holding = _HoldingStore(db)..hold = Completer<void>();
      await pumpScreen(tester, storeOverride: holding);
      // Needs You → the row opens the thread beside, wearing the chip.
      await tester.tap(find.text(_subject).first);
      await pumps(tester);
      await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(FindTimePane.waitingKey), findsOneWidget);
      expect(holding.askReads, 1);

      holding.hold!.complete();
      await pumps(tester);
      await pumps(tester);
      expect(find.byKey(FindTimePane.waitingKey), findsNothing);
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
        origin: 'invite',
      );
      final container =
          ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
      container.invalidate(schedulingAsksProvider);
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

    testWidgets('a ghost dragged into the past is refused, said', (tester) async {
      writer = _RecordingWriter();
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Previous day'));
      await pumps(tester);
      await tapEmptyGrid(tester, at: 0);
      await settle(tester);
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      final before = writer.previewed.length;

      await dragGhost(tester, const Offset(0, -42));
      expect(find.text('That time has passed.'), findsOneWidget);
      expect(writer.previewed, hasLength(before));
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
      await openAsk(tester);
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

  testWidgets('the header chip opens the pane, and Put these in the reply '
      'lands in the thread\'s reply box', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openPane(tester);
    // The pane's own search says it came from the pane.
    final rows = await store.recentActivity(limit: 20);
    expect(
      [for (final r in rows) r['detail_json'] as String? ?? ''],
      contains(contains('"surface":"pane"')),
    );

    await tester.tap(find.byKey(FindTimePane.putAllKey));
    await pumps(tester);
    expect(find.byType(FindTimePane), findsNothing);
    final text = composerText(tester);
    expect(text, startsWith('Would any of these work? · '));
    expect(' · '.allMatches(text), hasLength(2),
        reason: 'both slots, one line');
    expect(text, contains(RegExp(r'P[DS]T')));
  });

  testWidgets('Send invite previews, waits on the strip naming Dana, and '
      'sends to her', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openPane(tester);

    await tester.tap(find.byKey(FindTimePane.inviteKeyFor(0)));
    await pumps(tester);
    expect(writer.previewed.single, isA<CreateEvent>());
    expect(find.byType(WriteConfirmStrip), findsOneWidget);
    expect(find.text('This emails: $_dana'), findsOneWidget);
    expect(writer.committed, isEmpty);

    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await pumps(tester);
    final write = writer.committed.single as CreateEvent;
    expect(write.attendees, [_dana]);
    expect(write.subject, 'Re: $_subject');
    expect(find.byType(FindTimePane), findsNothing,
        reason: 'a sent invite returns to the thread');
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

  testWidgets('a thread opened beside wears the chip too, and it opens the '
      'pane in the main column', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openThreadBeside(tester);

    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
    await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
    await pumps(tester);
    await pumps(tester);
    expect(find.byType(FindTimePane), findsOneWidget);
    expect(find.byKey(SidePanelHost.closeKey), findsNothing,
        reason: 'the thread moved into the main column under the pane');
    expect(backend.asked.single, [_dana]);

    // Back lands on the thread, now in the main pane.
    await tester.tap(find.byKey(FindTimePane.backKey));
    await pumps(tester);
    expect(find.byType(FindTimePane), findsNothing);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
  });

  testWidgets('before the zone resolves the pane says so and keeps Back, '
      'never a blank column', (tester) async {
    await seedAsk();
    await pumpScreen(tester, zoneResolves: false);
    await openThreadBeside(tester);

    await tester.tap(find.byKey(ThreadActionBar.findTimeKey));
    await pumps(tester);
    expect(find.byKey(FindTimePane.waitingKey), findsOneWidget);
    expect(find.text('Reading your calendar…'), findsOneWidget);
    expect(backend.asked, isEmpty, reason: 'no search without a clock');

    await tester.tap(find.byKey(FindTimePane.backKey));
    await pumps(tester);
    expect(find.byKey(FindTimePane.waitingKey), findsNothing);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
  });
}
