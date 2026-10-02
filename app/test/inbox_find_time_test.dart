import 'dart:async';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show MeetingTimeSuggestion, MeetingTimes, WritePreview;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart'
    show conversationsProvider;
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
import 'package:bond_inbox/services/calendar/day_items.dart' show dayTitle;
import 'package:bond_inbox/services/calendar/find_time.dart'
    show findTimeUnreadableNote;
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
  }) async {
    asked.add(attendees);
    minutes.add(durationMinutes);
    if (hold) {
      final c = Completer<List<MeetingTimeSuggestion>>();
      held.add(c);
      return MeetingTimes(suggestions: await c.future);
    }
    return MeetingTimes(suggestions: slots, emptyReason: emptyReason);
  }
}

/// Answers every dry run with [notifies] and every commit with success.
class _RecordingWriter implements CalendarWriter {
  _RecordingWriter({this.notifies = const []});

  final List<String> notifies;
  final List<CalendarWrite> previewed = [];
  final List<CalendarWrite> committed = [];

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
    return const WriteOutcome.ok();
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
      'body_text': 'Could we find 30 minutes next week for the review?',
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

  Future<void> pumpScreen(WidgetTester tester, {bool zoneResolves = true})
      async {
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
    expect(find.text('Proposed'), findsOneWidget);
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
