import 'dart:async';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show MeetingTimeSuggestion, WritePreview;
import 'package:bond_inbox/providers/app_providers.dart';
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
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/find_time_pane.dart';
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart'
    show WriteConfirmStrip;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// Find a time inside the assembled screen: a needs-reply thread whose newest
/// mail the decision model read as scheduling shows up in today's agenda,
/// wears the chip in its header, opens the pane over itself, and hands the
/// slots to the reply box or to an invite. Scaffolding is
/// `inbox_day_test.dart`'s; fictional people.

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

  @override
  Future<List<MeetingTimeSuggestion>> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) async {
    asked.add(attendees);
    return slots;
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
    backend = _Backend([
      MeetingTimeSuggestion(
          startUtc: at(10), endUtc: at(10).add(const Duration(minutes: 30))),
      MeetingTimeSuggestion(
          startUtc: at(14), endUtc: at(14).add(const Duration(minutes: 30))),
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
  Future<void> seedAsk() async {
    final received = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'ask-m1',
      'conversation_key': 'c-ask',
      'direction': 'inbound',
      'subject': _subject,
      'from_name': 'Dana Ortiz',
      'from_address': _dana,
      'received_at': received,
      'body_text': 'Could we find 30 minutes next week for the review?',
    });
    await writeTriaged(store, 'email', 'ask-m1',
        status: 'triaged', replyExpected: true);
    // Needs You is the decision model's probability against the slider since
    // the needs-you signals round; the ask sits there by it.
    await store.writeNeedsYouP('email', 'ask-m1', p: 0.9);
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c-ask',
      'subject': _subject,
      'participants_json': '[{"name":"Dana Ortiz","email":"$_dana"}]',
      'state': 'needs_reply',
      'cta_text': 'Reply to Dana',
      'cta_urgency': 'normal',
      'last_message_at': received,
      'last_inbound_at': received,
    });
    await store.writeDecision(
      'email',
      'ask-m1',
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

  /// Day → the Scheduling asks row → the thread in the main pane.
  Future<void> openThreadFromDay(WidgetTester tester) async {
    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.text('Scheduling asks · 1'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(DayPane.schedulingAsksKey),
        matching: find.text(_subject)));
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

  /// The docked reply box's text, whatever it is.
  String composerText(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .map((e) => e.controller.text)
      .firstWhere((t) => t.contains('Would any of these work?'),
          orElse: () => '');

  testWidgets('the Day agenda lists the ask today, and its button opens the '
      'pane over the thread', (tester) async {
    await seedAsk();
    await pumpScreen(tester);

    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.text('Scheduling asks · 1'), findsOneWidget);
    expect(find.text('Dana Ortiz'), findsWidgets);

    await tester.tap(find.byKey(DayPane.schedulingAskKeyFor('email|c-ask')));
    await pumps(tester);
    await pumps(tester);
    expect(find.byType(FindTimePane), findsOneWidget);
    expect(backend.asked.single, [_dana]);
    expect(find.byKey(FindTimePane.slotKeyFor(0)), findsOneWidget);
    expect(find.byKey(FindTimePane.slotKeyFor(1)), findsOneWidget);

    // Back lands on the thread it was opened for.
    await tester.tap(find.byKey(FindTimePane.backKey));
    await pumps(tester);
    expect(find.byType(FindTimePane), findsNothing);
    expect(find.byKey(ThreadActionBar.findTimeKey), findsOneWidget);
  });

  testWidgets('the header chip opens the pane, and Put these in the reply '
      'lands in the thread\'s reply box', (tester) async {
    await seedAsk();
    await pumpScreen(tester);
    await openPane(tester);

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
    expect(find.byKey(DayPane.schedulingAsksKey), findsNothing);
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
