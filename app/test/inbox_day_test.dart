import 'dart:async';
import 'dart:convert';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show
        Attendee,
        BriefMaterialOut,
        BriefMaterialRef,
        BriefPoint,
        BriefThreadRef,
        CalendarDate,
        CalendarEvent,
        EventBrief,
        MeetingBrief,
        WritePreview,
        calendarStamp;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/day_providers.dart' show dayEventsProvider;
import 'package:bond_inbox/providers/draft_provider.dart' show DraftNotifier;
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/services/backend/backend_types.dart'
    show AccountInfo;
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_lexicon.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/command/command_router.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart'
    show KnownPerson;
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/brief_section.dart' show BriefSection;
import 'package:bond_inbox/widgets/command_plan_card.dart'
    show CommandPlanCard;
import 'package:bond_inbox/widgets/day_command_bar.dart' show DayCommandBar;
import 'package:bond_inbox/widgets/day_grid.dart' show DayGrid;
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/event_actions.dart' show EventActions;
import 'package:bond_inbox/widgets/event_panel.dart' show EventPanelBody;
import 'package:bond_inbox/widgets/find_field.dart' show FindField, askDayLabel;
import 'package:bond_inbox/widgets/meeting_card.dart' show MeetingCard;
import 'package:bond_inbox/widgets/person_meeting_line.dart'
    show PersonMeetingLine;
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart'
    show AttachmentPreviewPanel;
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
import 'package:bond_inbox/widgets/write_confirm_strip.dart'
    show WriteConfirmStrip;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// The Day stop inside the assembled screen: the stop forces a calendar tick
/// on arrival, the pane draws the mirror, and the list column's day rows move
/// the pane. Scaffolding is `calendar_poll_test.dart`'s.

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

/// Records each call's `force` and answers with a future the test holds.
class _RecordingCalendarSync extends CalendarSync {
  _RecordingCalendarSync(MessageStore store, CalendarStore calendar)
      : super(const UnavailableCalendarBackend(), store, calendar);

  final List<bool> forces = [];
  final Completer<CalendarSyncOutcome> gate = Completer();

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) {
    forces.add(force);
    return gate.future;
  }
}

/// A calendar writer that answers every preview with [notifies] and every
/// commit with success, recording what it was asked.
class _RecordingWriter implements CalendarWriter {
  _RecordingWriter({this.notifies = const []});

  final List<String> notifies;
  final List<CalendarWrite> previewed = [];
  final List<({CalendarWrite write, bool isUndo})> committed = [];

  /// When set, a commit waits for it before answering, so the screen can
  /// move on while the write is in the air. Made inside the test body.
  Completer<void>? hold;

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
    final p = WritePreview(method: 'PATCH', path: '/x', notifies: notifies);
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    committed.add((write: write, isUndo: isUndo));
    final held = hold;
    if (held != null) await held.future;
    if (isUndo || write is! MoveEvent) return const WriteOutcome.ok();
    // The move back to where it was, as the real writer offers it.
    return WriteOutcome.ok(
      eventId: write.eventId,
      undo: MoveEvent.timed(write.eventId,
          startUtc: DateTime.utc(2026, 1, 1, 17),
          endUtc: DateTime.utc(2026, 1, 1, 18)),
    );
  }
}

/// A [_RecordingWriter] that moves the mirror as the real writer does after
/// an answer: the row's response stored at once, then [onChanged] — the
/// revision bump `calendarWritesProvider` wires — so the agenda reads again.
class _AnsweringWriter extends _RecordingWriter {
  _AnsweringWriter(this.calendar);

  final CalendarStore calendar;

  /// Set once the screen is up, from the test's own container.
  void Function()? onChanged;

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    final outcome =
        await super.commit(write, preview: preview, isUndo: isUndo);
    if (write is RespondToEvent) {
      await calendar.setResponseStatus(
        write.eventId,
        switch (write.response) {
          RsvpResponse.accept => 'accepted',
          RsvpResponse.tentative => 'tentativelyAccepted',
          RsvpResponse.decline => 'declined',
        },
      );
      onChanged?.call();
    }
    return outcome;
  }
}

/// The command bar's backend: nothing in these tests asks for a common
/// time, so every call is a failure the test would see.
class _NoMeetingTimes extends Fake implements CalendarBackend {}

/// The directory, for names nobody in the mail has: [hits] per query (none
/// unless a test scripts some), every query recorded.
class _NoDirectory extends Fake implements PeopleBackend {
  final List<String> queries = [];
  final Map<String, List<Person>> hits = {};

  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    queries.add(query);
    return hits[query] ?? const [];
  }
}

/// A router whose Enter throws, which the real one never does: the screen's
/// belt must still end the spin with a sentence.
class _ThrowingRouter extends CommandRouter {
  _ThrowingRouter(CommandPlanner planner)
      : super(
          classifiers: const [LexiconClassifier()],
          planner: planner,
          intentClient: () => throw StateError('no model here'),
          people: _NoDirectory(),
        );

  @override
  Future<CommandOutcome> submit(
    String text, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
    required List<KnownPerson> people,
    required List<CalendarEvent> events,
    List<CommandBind> binds = const [],
    CommandOutcome? resume,
  }) async =>
      throw StateError('the router broke');
}

const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

void main() {
  setUpAll(initCalendarZones);

  late BondDatabase db;
  late MessageStore store;
  late _RecordingCalendarSync calendarSync;
  late CalendarZone la;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  tearDown(() => db.close());

  Future<void> pumps(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<Override> overrides = const [],
    RailSection section = RailSection.needsYou,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Built inside the test body, not in setUp: a completer made outside the
    // fake-async zone schedules its callbacks on the real event loop, which
    // `tester.pump` never drains.
    calendarSync = _RecordingCalendarSync(store, CalendarStore(db));

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _readGrant;
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The default MCP session would ask a server that is not there.
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
        calendarSyncProvider.overrideWithValue(calendarSync),
        // SDK mode would hide the calendar; this screen is testing the stop
        // as a connected session sees it, and the zone is pinned so "today"
        // is one answer.
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.available),
        calendarZoneProvider.overrideWith((ref) async => la),
        ...overrides,
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Pumps rather than a settle: this screen owns a sixty-second periodic
    // timer, and an unbounded settle would never come back.
    await pumps(tester);
  }

  testWidgets('the Day stop opens today and forces a calendar tick',
      (tester) async {
    await pumpScreen(tester);
    expect(calendarSync.forces, [true]);

    await tester.tap(find.text('Day'));
    await pumps(tester);

    final today = la.dateOf(DateTime.now().toUtc());
    expect(find.text(dayTitle(today, today)), findsOneWidget);
    expect(calendarSync.forces, [true, true],
        reason: 'arriving at the stop asks for a forced tick');
    expect(find.text('Nothing on your calendar.'), findsOneWidget);
  });

  testWidgets('a mirrored event on today is on the pane', (tester) async {
    final today = la.dateOf(DateTime.now().toUtc());
    final start = la.localDateTime(today, 12, 0).toUtc();
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'evt-1',
        subject: 'Contoso planning',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester);

    await tester.tap(find.text('Day'));
    await pumps(tester);

    expect(find.text('Contoso planning'), findsOneWidget);
    expect(find.text('12:00–12:30 PM'), findsOneWidget);
  });

  testWidgets('a meeting row opens the event beside, and the ✕ closes it',
      (tester) async {
    final today = la.dateOf(DateTime.now().toUtc());
    final start = la.localDateTime(today, 12, 0).toUtc();
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'evt-1',
        subject: 'Contoso planning',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester);

    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.byType(SidePanelHost), findsNothing);

    await tester.tap(find.text('Contoso planning'));
    await pumps(tester);

    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.text('Contoso planning'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    await pumps(tester);
    expect(find.byType(SidePanelHost), findsNothing);
  });

  testWidgets('a clash: both rows carry the strip, a chip opens the other '
      "meeting beside, and the panel's clash row opens the first again",
      (tester) async {
    final today = la.dateOf(DateTime.now().toUtc());
    final start = la.localDateTime(today, 12, 0).toUtc();
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'evt-1',
        subject: 'Contoso planning',
        startUtc: start,
        endUtc: start.add(const Duration(hours: 1)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
      CalendarEvent(
        id: 'evt-2',
        subject: 'Fabrikam sync',
        startUtc: start.add(const Duration(minutes: 30)),
        endUtc: start.add(const Duration(minutes: 90)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester);
    Finder inSide(Finder f) =>
        find.descendant(of: find.byType(SidePanelHost), matching: f);

    await tester.tap(find.text('Day'));
    await pumps(tester);
    expect(find.byKey(DayPane.clashKeyFor('evt-1')), findsOneWidget);
    expect(find.byKey(DayPane.clashKeyFor('evt-2')), findsOneWidget);

    await tester.tap(find.byKey(DayPane.clashChipKeyFor('evt-1', 'evt-2')));
    await pumps(tester);
    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(inSide(find.text('Fabrikam sync')), findsOneWidget);

    final back = inSide(find.byKey(EventPanelBody.overlapRowKeyFor(0)));
    expect(
        find.descendant(
            of: back, matching: find.textContaining('Contoso planning')),
        findsOneWidget);
    await tester.tap(back);
    await pumps(tester);
    expect(inSide(find.text('Contoso planning')), findsOneWidget);
    // Opened on top of the clashing meeting, so the ✕'s back comes home.
    expect(find.byKey(SidePanelHost.backKey), findsOneWidget);
  });

  testWidgets('a day row in the list column moves the pane', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);

    final today = la.dateOf(DateTime.now().toUtc());
    final tomorrow = today.addDays(1);
    await tester.tap(find.textContaining(RegExp(r'^Tomorrow · ')).first);
    await pumps(tester);

    expect(find.text(dayTitle(tomorrow, today)), findsOneWidget);
    expect(find.text(dayTitle(today, today)), findsNothing);
  });

  testWidgets('stepping the day keeps the event open beside', (tester) async {
    final today = la.dateOf(DateTime.now().toUtc());
    final start = la.localDateTime(today, 12, 0).toUtc();
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'evt-1',
        subject: 'Contoso planning',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    await tester.tap(find.text('Contoso planning'));
    await pumps(tester);
    expect(find.byType(SidePanelHost), findsOneWidget);

    await tester.tap(find.byTooltip('Next day'));
    await pumps(tester);

    expect(find.text(dayTitle(today.addDays(1), today)), findsOneWidget);
    expect(find.byType(SidePanelHost), findsOneWidget,
        reason: 'a step on the Day stop is not a new stop');
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.text('Contoso planning'),
      ),
      findsOneWidget,
    );
  });

  testWidgets("Inbox's Today section: a meeting opens beside, the invites "
      'row opens the Invites view', (tester) async {
    // Under way now, so it is still "today" whatever the hour, and one
    // invite owed an answer, safely ahead of the clock.
    final now = DateTime.now().toUtc();
    final ahead = now.add(const Duration(days: 3));
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'evt-now',
        subject: 'Contoso planning',
        startUtc: now.subtract(const Duration(minutes: 10)),
        endUtc: now.add(const Duration(minutes: 50)),
        responseStatus: 'accepted',
        showAs: 'busy',
      ),
      CalendarEvent(
        id: 'inv-1',
        subject: 'Fabrikam roadmap',
        startUtc: ahead,
        endUtc: ahead.add(const Duration(minutes: 30)),
        responseStatus: 'notResponded',
        responseRequested: true,
        showAs: 'tentative',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester, section: RailSection.home);

    expect(find.text('TODAY'), findsOneWidget);
    await tester.tap(find.textContaining('Contoso planning').first);
    await pumps(tester);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.text('Contoso planning'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Invites · 1'));
    await pumps(tester);
    expect(find.text('Invites'), findsOneWidget);
    expect(find.text('Fabrikam roadmap'), findsOneWidget);
  });

  test('a calendar Undo is honoured for twice the toast window, then not', () {
    final offered = DateTime.utc(2026, 10, 14, 10);
    expect(calendarUndoWindow, DraftNotifier.undoWindow * 2);
    expect(calendarUndoStillOpen(offered, offered), isTrue);
    expect(calendarUndoStillOpen(offered, offered.add(calendarUndoWindow)),
        isTrue);
    expect(
        calendarUndoStillOpen(
            offered, offered.add(calendarUndoWindow + const Duration(seconds: 1))),
        isFalse);
    expect(
        calendarUndoStillOpen(offered, offered.add(const Duration(minutes: 5))),
        isFalse);
  });

  testWidgets('back from the invites lands on the day that was open',
      (tester) async {
    // One invite still owed an answer, safely ahead of the clock.
    final start = DateTime.now().toUtc().add(const Duration(days: 3));
    await CalendarStore(db).upsertEvents([
      CalendarEvent(
        id: 'inv-1',
        subject: 'Fabrikam roadmap',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: 'notResponded',
        responseRequested: true,
        showAs: 'tentative',
      ),
    ], syncRun: 'run-1');
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);

    final today = la.dateOf(DateTime.now().toUtc());
    final tomorrow = today.addDays(1);
    await tester.tap(find.textContaining(RegExp(r'^Tomorrow · ')).first);
    await pumps(tester);

    await tester.tap(find.text('Invites · 1'));
    await pumps(tester);
    expect(find.text('Fabrikam roadmap'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to Day'));
    await pumps(tester);
    expect(find.text(dayTitle(tomorrow, today)), findsOneWidget);
  });

  testWidgets('leaving the stop and coming back opens today again',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    await tester.tap(find.textContaining(RegExp(r'^Tomorrow · ')).first);
    await pumps(tester);

    await tester.tap(find.byTooltip('People').first);
    await pumps(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);

    final today = la.dateOf(DateTime.now().toUtc());
    expect(find.text(dayTitle(today, today)), findsOneWidget);
    expect(find.text(dayTitle(today.addDays(1), today)), findsNothing);
  });

  testWidgets('a deadline row opens its thread, and Back lands on that day',
      (tester) async {
    final today = la.dateOf(DateTime.now().toUtc());
    final tomorrow = today.addDays(1);
    final received = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'c1-m1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Contoso proposal',
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': received,
      'body_text': 'the revised figures',
    });
    // A dated deadline, so the day it lands on is the display zone's
    // tomorrow whatever zone the machine running this is in.
    await writeTriaged(
      store,
      'email',
      'c1-m1',
      status: 'triaged',
      needsAction: true,
      deadline: tomorrow.toIso(),
    );
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c1',
      'subject': 'Contoso proposal',
      'participants_json': '[{"name":"Dana Whitfield",'
          '"email":"dana@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': received,
      'last_inbound_at': received,
    });
    await pumpScreen(tester);
    await tester.tap(find.text('Day'));
    await pumps(tester);
    await tester.tap(find.textContaining(RegExp(r'^Tomorrow · ')).first);
    await pumps(tester);
    expect(find.text(dayTitle(tomorrow, today)), findsOneWidget);

    await tester.tap(find.text('Contoso proposal').first);
    await pumps(tester);
    expect(find.text(dayTitle(tomorrow, today)), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await pumps(tester);
    expect(find.text(dayTitle(tomorrow, today)), findsOneWidget);
  });

  group('the event panel in the screen', () {
    const invite = 'Invitation: Contoso planning';

    /// A meeting on today's calendar and the invite thread that names it:
    /// triaged into Needs You so the main list can select it, and linked
    /// through `source_meta_json` so the event panel's Conversations list it.
    Future<void> seedMeetingAndInvite() async {
      final today = la.dateOf(DateTime.now().toUtc());
      final start = la.localDateTime(today, 12, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-1',
          subject: 'Contoso planning',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      final received = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String();
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'inv-m1',
        'conversation_key': 'c-inv',
        'direction': 'inbound',
        'subject': invite,
        'from_name': 'Dana Ortiz',
        'from_address': 'dana.ortiz@contoso.com',
        'received_at': received,
        'body_text': 'Please join the planning session.',
        'source_meta_json':
            '{"meeting": "meetingRequest", "event_id": "evt-1"}',
      });
      await writeTriaged(
        store,
        'email',
        'inv-m1',
        status: 'triaged',
        needsAction: true,
      );
      // Needs You is the decision model's probability against the slider
      // since the needs-you signals round; the invite sits there by it.
      await store.writeNeedsYouP('email', 'inv-m1', p: 0.9);
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c-inv',
        'subject': invite,
        'participants_json': '[{"name":"Dana Ortiz",'
            '"email":"dana.ortiz@contoso.com"}]',
        'state': 'needs_reply',
        'cta_text': 'Answer the invite',
        'cta_urgency': 'normal',
        'last_message_at': received,
        'last_inbound_at': received,
      });
    }

    Finder inSide(Finder f) =>
        find.descendant(of: find.byType(SidePanelHost), matching: f);

    Future<void> openEventFromDay(WidgetTester tester) async {
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.text('Contoso planning'));
      await pumps(tester);
      expect(inSide(find.text('Contoso planning')), findsOneWidget);
    }

    testWidgets('a linked conversation pushes on the meeting, and back returns',
        (tester) async {
      await seedMeetingAndInvite();
      await pumpScreen(tester);
      await openEventFromDay(tester);

      final link = find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv'));
      expect(link, findsOneWidget);
      expect(find.byKey(SidePanelHost.backKey), findsNothing);

      await tester.tap(link);
      await pumps(tester);
      expect(find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv')),
          findsNothing);
      expect(
        find.descendant(
          of: find.byKey(SidePanelHost.backKey),
          matching: find.text('Back to the meeting'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(SidePanelHost.backKey));
      await pumps(tester);
      expect(inSide(find.text('Contoso planning')), findsOneWidget);
      expect(find.byKey(SidePanelHost.backKey), findsNothing);
      expect(find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv')),
          findsOneWidget);
    });

    testWidgets("the same meeting pushed again unwinds to it, never stacks",
        (tester) async {
      await seedMeetingAndInvite();
      await pumpScreen(tester);
      await openEventFromDay(tester);

      // Meeting → its thread, pushed on it.
      await tester.tap(find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv')));
      await pumps(tester);
      expect(find.byKey(SidePanelHost.backKey), findsOneWidget);

      // The side thread's invite card opens the same meeting with push: it
      // already sits under the thread, so the stack unwinds back to it.
      final open = inSide(find.byKey(MeetingCard.openEventKey));
      expect(open, findsOneWidget);
      await tester.tap(open);
      await pumps(tester);
      expect(find.byKey(SidePanelHost.backKey), findsNothing,
          reason: 'one panel left: meeting, not meeting → thread → meeting');
      expect(inSide(find.text('Contoso planning')), findsOneWidget);
      expect(find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv')),
          findsOneWidget);

      // And the ✕ closes the side outright.
      await tester.tap(find.byKey(SidePanelHost.closeKey));
      await pumps(tester);
      expect(find.byType(SidePanelHost), findsNothing);
    });

    testWidgets('an invite selected from Needs You carries its card, which '
        'pushes the meeting on the thread', (tester) async {
      await seedMeetingAndInvite();
      await pumpScreen(tester);

      // A Needs You row reads its thread beside the list.
      await tester.tap(find.text(invite).first);
      await pumps(tester);
      final open = inSide(find.byKey(MeetingCard.openEventKey));
      expect(open, findsOneWidget);
      expect(find.byKey(SidePanelHost.backKey), findsNothing);

      await tester.tap(open);
      await pumps(tester);
      expect(inSide(find.text('Contoso planning')), findsOneWidget);
      expect(find.byKey(EventPanelBody.linkKeyFor('email', 'c-inv')),
          findsOneWidget);
      // Asked for from inside the thread beside, so the ✕ owes it back.
      expect(
        find.descendant(
          of: find.byKey(SidePanelHost.backKey),
          matching: find.textContaining('Back to '),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(SidePanelHost.backKey));
      await pumps(tester);
      expect(inSide(find.byKey(MeetingCard.openEventKey)), findsOneWidget);
      expect(find.byKey(SidePanelHost.backKey), findsNothing);
    });

    testWidgets("a person's room names the next meeting with them, and it "
        'opens beside', (tester) async {
      await seedMeetingAndInvite();
      // Safely ahead of the clock and of the quarter-hour floor.
      final start = DateTime.now().toUtc().add(const Duration(hours: 3));
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-2',
          subject: 'Fabrikam sync',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          showAs: 'busy',
          attendees: const [
            Attendee(
              name: 'Dana Ortiz',
              address: 'dana.ortiz@contoso.com',
              response: 'accepted',
            ),
          ],
        ),
      ], syncRun: 'run-2');
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('People').first);
      await pumps(tester);
      await tester.tap(find.descendant(
        of: find.byType(AppRail),
        matching: find.text('Dana Ortiz'),
      ));
      await pumps(tester);

      final next = find.byKey(PersonMeetingLine.nextKey);
      expect(next, findsOneWidget);
      await tester.tap(next);
      await pumps(tester);
      expect(inSide(find.text('Fabrikam sync')), findsOneWidget);
    });

    testWidgets('a stored brief: teased on the Day row, drawn in the panel, '
        'its chip pushes the thread, and Regenerate requeues it',
        (tester) async {
      await seedMeetingAndInvite();
      // Under way now, so it is on today's pane at any hour and the panel
      // still draws its Brief section.
      final start =
          DateTime.now().toUtc().subtract(const Duration(minutes: 10));
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-brief',
          subject: 'Fabrikam sync',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 2)),
          responseStatus: 'accepted',
          showAs: 'busy',
          attendees: const [
            Attendee(name: 'Dana Ortiz', address: 'dana.ortiz@contoso.com'),
          ],
        ),
      ], syncRun: 'run-2');
      const brief = MeetingBrief(
        headline: 'Dana is waiting on the plan.',
        points: [BriefPoint(text: 'The planning invite is open.', thread: 0)],
        threads: [
          BriefThreadRef(
            source: 'email',
            conversationKey: 'c-inv',
            subject: invite,
          ),
        ],
      );
      await CalendarStore(db).putBrief(
        eventId: 'evt-brief',
        inputsHash: 'h',
        status: EventBrief.ready,
        briefJson: jsonEncode(brief.toJson()),
        generatedAt: calendarStamp(DateTime.now()),
      );
      await pumpScreen(tester);

      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byKey(DayPane.briefTeaserKeyFor('evt-brief')), findsOneWidget);

      await tester.tap(find.text('Fabrikam sync'));
      await pumps(tester);
      expect(inSide(find.byKey(BriefSection.headlineKey)), findsOneWidget);
      expect(inSide(find.text('Dana is waiting on the plan.')), findsOneWidget);

      await tester.tap(find.byKey(BriefSection.regenerateKey));
      await pumps(tester);
      expect(
        await tester.runAsync(() =>
            store.workStatusOf('meeting_brief', 'calendar', 'evt-brief')),
        'pending',
      );
      // Marked asked, so the handler rewrites it even over unchanged inputs.
      final queued = await tester.runAsync(() => db
          .customSelect('SELECT payload_json FROM work_items '
              "WHERE task_kind = 'meeting_brief' AND entity_id = 'evt-brief'")
          .getSingle());
      expect(queued!.data['payload_json'], '{"asked":true}');

      await tester.tap(find.byKey(BriefSection.pointThreadKeyFor(0)));
      await pumps(tester);
      expect(
        find.descendant(
          of: find.byKey(SidePanelHost.backKey),
          matching: find.text('Back to the meeting'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Write a brief in the panel requeues an asked brief',
        (tester) async {
      final today = la.dateOf(DateTime.now().toUtc());
      // The day after tomorrow at 10:00: outside the briefs' box at any hour.
      final start = la.localDateTime(today.addDays(2), 10, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-later',
          subject: 'Northwind review',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          showAs: 'busy',
          attendees: const [
            Attendee(name: 'Dana Ortiz', address: 'dana.ortiz@contoso.com'),
          ],
        ),
      ], syncRun: 'run-2');
      await pumpScreen(tester, overrides: [
        processingProvider.overrideWith((ref) => ProcessingNotifier(true)),
      ]);

      await tester.tap(find.text('Day'));
      await pumps(tester);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Next day'));
        await pumps(tester);
      }
      await tester.tap(find.text('Northwind review'));
      await pumps(tester);
      expect(
          tester.widget<Text>(inSide(find.byKey(BriefSection.statusKey))).data,
          BriefSection.tooFarText);

      await tester.tap(inSide(find.byKey(BriefSection.writeKey)));
      await pumps(tester);
      // Queued (processing is on here, so the woken lane may already have
      // claimed it — and failed, with no model in a test), marked asked.
      expect(
        await tester.runAsync(() =>
            store.workStatusOf('meeting_brief', 'calendar', 'evt-later')),
        isNotNull,
      );
      final queued = await tester.runAsync(() => db
          .customSelect('SELECT payload_json FROM work_items '
              "WHERE task_kind = 'meeting_brief' AND entity_id = 'evt-later'")
          .getSingle());
      expect(jsonDecode(queued!.data['payload_json'] as String),
          {'asked': true});
    });

    testWidgets('a block with only the owner, two days out, offers no Write a '
        'brief', (tester) async {
      const me = 'jordan@contoso.com';
      final today = la.dateOf(DateTime.now().toUtc());
      final start = la.localDateTime(today.addDays(2), 10, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-focus',
          subject: 'Focus block',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          showAs: 'busy',
          // Not marked the organiser's copy, so the owner's own attendee row
          // is the one name on it.
          organizerAddress: me,
          attendees: const [Attendee(name: 'Jordan Bond', address: me)],
        ),
      ], syncRun: 'run-2');
      await pumpScreen(tester, overrides: [
        authSessionProvider.overrideWithValue(FakeAuthSession(
          signedIn: true,
          account: const AccountInfo(displayName: 'Jordan Bond', mail: me),
        )),
      ]);

      await tester.tap(find.text('Day'));
      await pumps(tester);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Next day'));
        await pumps(tester);
      }
      await tester.tap(find.text('Focus block'));
      await pumps(tester);
      expect(inSide(find.text('Focus block')), findsWidgets);
      expect(inSide(find.byKey(BriefSection.writeKey)), findsNothing);
    });

    testWidgets('a meeting waiting for its files says so in the agenda; one '
        'that has started does not', (tester) async {
      final nowUtc = DateTime.now().toUtc();
      // Tomorrow at 10:00: ahead of the clock at any hour, on tomorrow's
      // pane.
      final ahead =
          la.localDateTime(la.dateOf(nowUtc).addDays(1), 10, 0).toUtc();
      final started = nowUtc.subtract(const Duration(minutes: 10));
      CalendarEvent meeting(String id, String subject, DateTime start) =>
          CalendarEvent(
            id: id,
            subject: subject,
            startUtc: start,
            endUtc: start.add(const Duration(minutes: 30)),
            responseStatus: 'accepted',
            showAs: 'busy',
            attendees: const [
              Attendee(name: 'Dana Ortiz', address: 'dana.ortiz@contoso.com'),
            ],
          );
      await CalendarStore(db).upsertEvents([
        meeting('evt-pending', 'Fabrikam sync', ahead),
        meeting('evt-started', 'Contoso review', started),
      ], syncRun: 'run-2');
      for (final id in ['evt-pending', 'evt-started']) {
        await CalendarStore(db).putBrief(
          eventId: id,
          inputsHash: '${EventBrief.ineligiblePrefix}materials_pending',
          status: EventBrief.skipped,
          generatedAt: calendarStamp(DateTime.now()),
        );
      }
      // Processing on: with it off no brief is coming and the agenda says
      // nothing (the panel says why).
      await pumpScreen(tester, overrides: [
        processingProvider.overrideWith((ref) => ProcessingNotifier(true)),
      ]);

      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byKey(DayPane.briefNoteKeyFor('evt-started')), findsNothing,
          reason: 'no brief is coming for a meeting under way');

      await tester.tap(find.textContaining(RegExp(r'^Tomorrow · ')).first);
      await pumps(tester);
      final note = find.byKey(DayPane.briefNoteKeyFor('evt-pending'));
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).data,
          'Reading the files sent ahead — brief coming.');
      expect(find.byKey(DayPane.briefToggleKeyFor('evt-pending')), findsNothing);
      expect(find.byKey(DayPane.briefTeaserKeyFor('evt-pending')), findsNothing);
    });

    /// A meeting under way now (on today's pane at any hour, and still ahead
    /// for the Today section), with a ready brief that names two files: one
    /// stored on the invite's mail, one the store no longer holds.
    Future<void> seedBriefWithMaterials() async {
      await seedMeetingAndInvite();
      await store.upsertAttachments('email', 'inv-m1', [
        {
          'attachment_id': 'att-deck',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Planning deck.pdf',
          'content_type': 'application/pdf',
          'size': 120 * 1024,
        },
      ]);
      final start =
          DateTime.now().toUtc().subtract(const Duration(minutes: 10));
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-brief',
          subject: 'Fabrikam sync',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 2)),
          responseStatus: 'accepted',
          showAs: 'busy',
          attendees: const [
            Attendee(name: 'Dana Ortiz', address: 'dana.ortiz@contoso.com'),
          ],
        ),
      ], syncRun: 'run-2');
      const brief = MeetingBrief(
        headline: 'Dana is waiting on the plan; the deck arrived.',
        points: [BriefPoint(text: 'The planning invite is open.', thread: 0)],
        materials: [
          BriefMaterialOut(file: 0, takeaway: 'The deck proposes two phases.'),
          BriefMaterialOut(file: 1, takeaway: 'The old sheet had the dates.'),
        ],
        questions: ['Which phase starts first?'],
        threads: [
          BriefThreadRef(
            source: 'email',
            conversationKey: 'c-inv',
            subject: invite,
          ),
        ],
        materialRefs: [
          BriefMaterialRef(
            source: 'email',
            messageId: 'inv-m1',
            attachmentId: 'att-deck',
            name: 'Planning deck.pdf',
          ),
          BriefMaterialRef(
            source: 'email',
            messageId: 'inv-m1',
            attachmentId: 'att-gone',
            name: 'Old dates.xlsx',
          ),
        ],
      );
      await CalendarStore(db).putBrief(
        eventId: 'evt-brief',
        inputsHash: 'h',
        status: EventBrief.ready,
        briefJson: jsonEncode(brief.toJson()),
        generatedAt: calendarStamp(DateTime.now()),
      );
    }

    testWidgets('the agenda opens a brief inline and a material chip opens '
        'the file panel', (tester) async {
      await seedBriefWithMaterials();
      await pumpScreen(tester);

      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byKey(DayPane.briefTeaserKeyFor('evt-brief')), findsOneWidget);
      expect(find.text('1. Which phase starts first?'), findsNothing,
          reason: 'closed until asked');

      await tester.tap(find.byKey(DayPane.briefToggleKeyFor('evt-brief')));
      await pumps(tester);
      expect(find.text('1. Which phase starts first?'), findsOneWidget);
      expect(find.text('• The deck proposes two phases.'), findsOneWidget);
      expect(find.byType(SidePanelHost), findsNothing,
          reason: 'the toggle opens the brief, not the event');

      // A file the store no longer holds says so and opens nothing.
      await tester.tap(find.byKey(BriefSection.materialKeyFor(1)));
      await pumps(tester);
      expect(find.text('That file is no longer here.'), findsOneWidget);
      expect(find.byType(SidePanelHost), findsNothing);

      await tester.tap(find.byKey(BriefSection.materialKeyFor(0)));
      await pumps(tester);
      expect(
        find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(AttachmentPreviewPanel),
        ),
        findsOneWidget,
      );

      // Closing it again is the same toggle.
      await tester.tap(find.byKey(DayPane.briefToggleKeyFor('evt-brief')));
      await pumps(tester);
      expect(find.text('1. Which phase starts first?'), findsNothing);
    });

    testWidgets('the Today section shows the glance', (tester) async {
      await seedBriefWithMaterials();
      // Home carries the Today section.
      await pumpScreen(tester, section: RailSection.home);

      final glance = find.byKey(AppRail.todayGlanceKeyFor('evt-brief'));
      expect(glance, findsOneWidget);
      expect(tester.widget<Text>(glance).data,
          'Dana is waiting on the plan; the deck arrived.');
    });
  });

  group('calendar writes in the screen', () {
    Finder inSide(Finder f) =>
        find.descendant(of: find.byType(SidePanelHost), matching: f);

    /// An event of the owner's own at noon today: Move and Delete, and a
    /// move that emails nobody.
    Future<void> seedOwnEvent() => CalendarStore(db).upsertEvents([
          CalendarEvent(
            id: 'own-1',
            subject: 'Focus block',
            isOrganizer: true,
            startUtc: la
                .localDateTime(la.dateOf(DateTime.now().toUtc()), 12, 0)
                .toUtc(),
            endUtc: la
                .localDateTime(la.dateOf(DateTime.now().toUtc()), 12, 30)
                .toUtc(),
            responseStatus: 'organizer',
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');

    Future<_RecordingWriter> openOwnEvent(WidgetTester tester) async {
      await seedOwnEvent();
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.text('Focus block'));
      await pumps(tester);
      expect(find.byType(SidePanelHost), findsOneWidget);
      return writer;
    }

    /// Moves the own event privately, Enter in the when field.
    Future<void> movePrivately(WidgetTester tester) async {
      await tester.tap(inSide(find.byKey(EventActions.moveKey)));
      await pumps(tester);
      await tester.enterText(
          inSide(find.byKey(EventActions.whenFieldKey)), 'tomorrow 3pm');
      await pumps(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumps(tester);
    }

    testWidgets("the screen's letter keys stay out of the when field, and "
        'Escape there closes the field, not the panel', (tester) async {
      final writer = await openOwnEvent(tester);
      await tester.tap(inSide(find.byKey(EventActions.moveKey)));
      await pumps(tester);
      final field = inSide(find.byKey(EventActions.whenFieldKey));
      await tester.tap(field);
      await pumps(tester);
      // `e` dismisses a thread and `z` undoes on this screen; typed into
      // the field they are letters and nothing else.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.enterText(field, 'e z tuesday');
      await pumps(tester);

      expect(tester.widget<TextField>(field).controller!.text,
          contains('e z tuesday'));
      expect(find.byType(SidePanelHost), findsOneWidget);
      expect(writer.committed, isEmpty);
      expect(writer.committed.where((c) => c.isUndo), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumps(tester);
      expect(inSide(find.byKey(EventActions.whenFieldKey)), findsNothing);
      expect(find.byType(SidePanelHost), findsOneWidget,
          reason: "Escape in the field is the field's, not the panel's");
      expect(writer.committed, isEmpty);
    });

    testWidgets('after a private move, `z` outside a field takes it back',
        (tester) async {
      final writer = await openOwnEvent(tester);
      await movePrivately(tester);
      expect(writer.committed.single.isUndo, isFalse);

      // No click first: the field that held the keyboard is gone, and the
      // write flow keeps it inside the panel, under the screen's keys, and
      // in no box.
      expect(inSide(find.byKey(EventActions.whenFieldKey)), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await pumps(tester);

      expect(writer.committed, hasLength(2));
      expect(writer.committed.last.isUndo, isTrue);
      expect(writer.committed.last.write, isA<MoveEvent>());
    });

    testWidgets("Escape on an RSVP's strip drops the strip and keeps the panel",
        (tester) async {
      final today = la.dateOf(DateTime.now().toUtc());
      final start = la.localDateTime(today, 12, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'inv-1',
          subject: 'Fabrikam roadmap',
          organizerName: 'Dana Contoso',
          organizerAddress: 'dana@contoso.com',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'notResponded',
          responseRequested: true,
          showAs: 'tentative',
          attendees: const [
            Attendee(name: 'Dana Contoso', address: 'dana@contoso.com'),
            Attendee(name: 'Sam Fabrikam', address: 'sam@fabrikam.com'),
          ],
        ),
      ], syncRun: 'run-1');
      // A dry run that lists nobody: the answer still confirms.
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.text('Fabrikam roadmap'));
      await pumps(tester);
      expect(find.byType(SidePanelHost), findsOneWidget);

      await tester.tap(inSide(find.byKey(EventActions.yesKey)));
      await pumps(tester);
      expect(inSide(find.byType(WriteConfirmStrip)), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumps(tester);
      expect(find.byType(WriteConfirmStrip), findsNothing);
      expect(find.byType(SidePanelHost), findsOneWidget);
      expect(inSide(find.text('Fabrikam roadmap')), findsWidgets);
      expect(writer.committed, isEmpty);
    });

    testWidgets('a private move acts at once, toasts, and Undo moves it back',
        (tester) async {
      final today = la.dateOf(DateTime.now().toUtc());
      final start = la.localDateTime(today, 12, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'own-1',
          subject: 'Focus block',
          isOrganizer: true,
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'organizer',
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.text('Focus block'));
      await pumps(tester);

      await tester.tap(inSide(find.byKey(EventActions.moveKey)));
      await pumps(tester);
      await tester.enterText(
          inSide(find.byKey(EventActions.whenFieldKey)), 'tomorrow 3pm');
      await pumps(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumps(tester);

      expect(find.byType(WriteConfirmStrip), findsNothing);
      // The write went through, so the field typed for it is gone rather
      // than standing ready to send the same move again.
      expect(inSide(find.byKey(EventActions.whenFieldKey)), findsNothing);
      final moved = writer.committed.single;
      expect(moved.isUndo, isFalse);
      final write = moved.write as MoveEvent;
      expect(write.eventId, 'own-1');
      expect(la.dateOf(write.startUtc!), today.addDays(1));
      expect(la.toLocal(write.startUtc!).hour, 15);

      await tester.pump(const Duration(milliseconds: 750));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining('Moved "Focus block"')),
          findsOneWidget);
      await tester.tap(find.text('Undo'));
      await pumps(tester);

      expect(writer.committed, hasLength(2));
      expect(writer.committed.last.isUndo, isTrue);
      expect(writer.committed.last.write, isA<MoveEvent>());
    });

    testWidgets('an invite answered from the Invites view waits on the strip',
        (tester) async {
      final start = DateTime.now().toUtc().add(const Duration(days: 3));
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'inv-1',
          subject: 'Fabrikam roadmap',
          organizerName: 'Dana Contoso',
          organizerAddress: 'dana@contoso.com',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'notResponded',
          responseRequested: true,
          showAs: 'tentative',
          attendees: const [
            Attendee(name: 'Dana Contoso', address: 'dana@contoso.com'),
            Attendee(name: 'Sam Fabrikam', address: 'sam@fabrikam.com'),
          ],
        ),
      ], syncRun: 'run-1');
      final writer = _RecordingWriter(notifies: const ['dana@contoso.com']);
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.text('Invites · 1'));
      await pumps(tester);

      await tester.tap(find.byKey(EventActions.yesKey));
      await pumps(tester);
      expect(writer.previewed.single, isA<RespondToEvent>());
      expect(find.byType(WriteConfirmStrip), findsOneWidget);
      expect(find.text('This emails: dana@contoso.com'), findsOneWidget);
      expect(writer.committed, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumps(tester);
      expect(writer.committed, hasLength(1));
      final answer = writer.committed.single.write as RespondToEvent;
      expect(answer.eventId, 'inv-1');
      expect(answer.response, RsvpResponse.accept);
    });
  });

  group('answered on the agenda', () {
    // A minute from now, derived from the clock (the suite has no clock
    // helper; the grid group derives its day the same way): ahead, so it is
    // owed and its buttons draw (an ended meeting draws the chip). In the
    // day's last minute that start is tomorrow, so the meeting starts five
    // minutes ago instead — still on today and not ended, only not owed in
    // Invites, which the count check allows for.
    Future<DateTime> seedOwed() async {
      final now = DateTime.now().toUtc();
      final soon = now.add(const Duration(minutes: 1));
      final start = la.dateOf(soon) == la.dateOf(now)
          ? soon
          : now.subtract(const Duration(minutes: 5));
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'owed-1',
          subject: 'Fabrikam roadmap',
          organizerName: 'Dana Contoso',
          organizerAddress: 'dana@contoso.com',
          isOrganizer: false,
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'notResponded',
          responseRequested: true,
          showAs: 'tentative',
          attendees: const [
            Attendee(name: 'Dana Contoso', address: 'dana@contoso.com'),
            Attendee(name: 'Sam Fabrikam', address: 'sam@fabrikam.com'),
          ],
        ),
      ], syncRun: 'run-1');
      return start;
    }

    Future<_AnsweringWriter> pumpWithWriter(WidgetTester tester) async {
      final writer = _AnsweringWriter(CalendarStore(db));
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(InboxScreen)));
      writer.onChanged =
          () => container.read(calendarRevisionProvider.notifier).state++;
      await tester.tap(find.text('Day'));
      await pumps(tester);
      return writer;
    }

    Finder inRow(Finder f) => find.descendant(
        of: find.byKey(DayPane.meetingRowKeyFor('owed-1')), matching: f);

    testWidgets('an invite answered on the agenda keeps its row and loses its buttons',
        (tester) async {
      final start = await seedOwed();
      final writer = await pumpWithWriter(tester);
      final ahead = start.isAfter(DateTime.now().toUtc());

      expect(find.byKey(DayPane.meetingRowKeyFor('owed-1')), findsOneWidget);
      expect(find.text('RSVP owed'), findsNothing);
      if (ahead) expect(find.text('Invites · 1'), findsWidgets);

      await tester.tap(inRow(find.byKey(EventActions.yesKey)));
      await pumps(tester);
      expect(writer.previewed.single, isA<RespondToEvent>());
      expect(inRow(find.byType(WriteConfirmStrip)), findsOneWidget);
      expect(writer.committed, isEmpty);

      await tester.tap(inRow(find.byKey(WriteConfirmStrip.confirmKey)));
      await pumps(tester);
      final answer = writer.committed.single.write as RespondToEvent;
      expect(answer.eventId, 'owed-1');
      expect(answer.response, RsvpResponse.accept);
      expect(answer.sendResponse, isTrue);

      // An accepted meeting stays on the day; it no longer asks.
      expect(find.byKey(DayPane.meetingRowKeyFor('owed-1')), findsOneWidget);
      expect(inRow(find.byKey(EventActions.yesKey)), findsNothing);
      expect(find.text('Invites · 1'), findsNothing);
    });

    testWidgets(
        'Dismiss on the agenda row: the strip reads Dismiss, the write is '
        'quiet, and the row is gone', (tester) async {
      await seedOwed();
      final writer = await pumpWithWriter(tester);

      await tester.tap(inRow(find.byKey(EventActions.dismissKey)));
      await pumps(tester);
      final strip = inRow(find.byType(WriteConfirmStrip));
      expect(strip, findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(WriteConfirmStrip.confirmKey),
              matching: find.text('Dismiss')),
          findsOneWidget);
      expect(find.byKey(WriteConfirmStrip.emailsKey), findsNothing,
          reason: 'a Dismiss emails nobody');
      expect(writer.committed, isEmpty);

      await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
      await pumps(tester);
      final quiet = writer.committed.single.write as RespondToEvent;
      expect(quiet.response, RsvpResponse.decline);
      expect(quiet.sendResponse, isFalse);
      expect(quiet.comment, isNull);
      expect(find.byKey(DayPane.meetingRowKeyFor('owed-1')), findsNothing);
      expect(find.text('Fabrikam roadmap'), findsNothing);
    });
  });

  group('the grid in the screen', () {
    /// An own event (organiser, [guests] invited) at noon TOMORROW: a drop an
    /// hour down must land in the future whatever time the suite runs, or
    /// the drop's own check refuses it as passed. [openTomorrow] goes there.
    Future<DateTime> seedAtNoon({List<Attendee> guests = const []}) async {
      // A plain UTC stamp, as the store and the move hold it: a TZDateTime is
      // never `==` to one.
      final start = DateTime.fromMicrosecondsSinceEpoch(
          la
              .localDateTime(la.dateOf(DateTime.now().toUtc()).addDays(1), 12, 0)
              .microsecondsSinceEpoch,
          isUtc: true);
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'own-1',
          subject: 'Focus block',
          isOrganizer: true,
          organizerAddress: 'owner@contoso.com',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 1)),
          responseStatus: 'organizer',
          showAs: 'busy',
          attendees: guests,
        ),
      ], syncRun: 'run-1');
      return start;
    }

    /// The Day stop, then the next-day arrow, and time for the grid's page
    /// to finish scrolling to the morning: a drag that starts while the
    /// hours are still moving under it lands wherever they stopped.
    Future<void> openTomorrow(WidgetTester tester) async {
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    /// The spike's drag, an hour down at the default 42 px an hour.
    Future<void> dragHourDown(WidgetTester tester, Finder f) async {
      final gesture = await tester.startGesture(tester.getCenter(f));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 22));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      await pumps(tester);
    }

    testWidgets('Grid is remembered: the pref is written, and the next launch '
        'opens on the grid', (tester) async {
      await seedAtNoon();
      await pumpScreen(tester);
      await openTomorrow(tester);
      expect(find.byType(DayGrid), findsNothing);
      expect(find.text('Focus block'), findsOneWidget);

      await tester.tap(find.byKey(DayPane.gridKey));
      await pumps(tester);
      expect(find.byType(DayGrid), findsOneWidget);
      expect(find.byKey(DayGrid.tileKeyFor('own-1')), findsOneWidget);
      expect(await store.getPref(dayViewKey), 'grid');

      await tester.tap(find.byKey(DayPane.spanWeekKey));
      await pumps(tester);
      expect(await store.getPref(dayGridSpanKey), 'week');
      expect(find.byKey(DayGrid.tileKeyFor('own-1')), findsOneWidget);

      // A fresh screen over the same store.
      await tester.pumpWidget(const SizedBox());
      await pumpScreen(tester);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byType(DayGrid), findsOneWidget);
      final grid = tester.widget<DayGrid>(find.byType(DayGrid));
      expect(grid.span.name, 'week');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a drop on an own event moves it at once with Undo, and the '
        'tile waits for the store', (tester) async {
      final start = await seedAtNoon();
      await store.setPref(dayViewKey, 'grid');
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await openTomorrow(tester);
      final tile = find.byKey(DayGrid.tileKeyFor('own-1'));
      expect(tile, findsOneWidget);
      final before = tester.getTopLeft(tile);

      await dragHourDown(tester, tile);

      expect(writer.previewed.single, isA<MoveEvent>());
      expect(find.byType(WriteConfirmStrip), findsNothing);
      final moved = writer.committed.single;
      expect(moved.isUndo, isFalse);
      final write = moved.write as MoveEvent;
      expect(write.eventId, 'own-1');
      expect(write.startUtc, start.add(const Duration(hours: 1)));
      expect(write.endUtc, start.add(const Duration(hours: 2)));
      // The recording writer changed no row, so the tile is where it was.
      expect(tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('own-1'))),
          before);

      await tester.pump(const Duration(milliseconds: 750));
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining('Moved "Focus block"')),
          findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a drop on a meeting with guests waits on the strip over the '
        'grid, naming who is emailed', (tester) async {
      await seedAtNoon(guests: const [
        Attendee(name: 'Dana Contoso', address: 'dana@contoso.com'),
      ]);
      await store.setPref(dayViewKey, 'grid');
      final writer = _RecordingWriter(notifies: const ['dana@contoso.com']);
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await openTomorrow(tester);
      final tile = find.byKey(DayGrid.tileKeyFor('own-1'));

      await dragHourDown(tester, tile);

      expect(writer.previewed.single, isA<MoveEvent>());
      expect(writer.committed, isEmpty);
      final strip = find.byType(WriteConfirmStrip);
      expect(strip, findsOneWidget);
      expect(find.text('This emails: dana@contoso.com'), findsOneWidget);
      expect(tester.getTopLeft(strip).dy,
          lessThan(tester.getTopLeft(find.byType(DayGrid)).dy));

      // Where it would land, drawn beside the tile that has not moved.
      expect(find.byKey(DayGrid.proposalKey), findsOneWidget);
      // It says what it is: the move the strip above sends or cancels.
      final ghost = find.byKey(DayGrid.proposalKey);
      expect(
          find.descendant(
              of: ghost, matching: find.textContaining('Move here?')),
          findsOneWidget);
      expect(
          find.descendant(
              of: ghost, matching: find.textContaining('Send or Cancel above')),
          findsOneWidget);
      expect(tester.widget<DayGrid>(find.byType(DayGrid)).locked, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumps(tester);
      expect(find.byType(WriteConfirmStrip), findsNothing);
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
      expect(tester.widget<DayGrid>(find.byType(DayGrid)).locked, isFalse);
      expect(writer.committed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a drop into the past says so and writes nothing',
        (tester) async {
      // Noon YESTERDAY, dragged an hour down: past whenever the suite runs.
      final yesterday = la.dateOf(DateTime.now().toUtc()).addDays(-1);
      final start = la.localDateTime(yesterday, 12, 0).toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'own-1',
          subject: 'Focus block',
          isOrganizer: true,
          organizerAddress: 'owner@contoso.com',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 1)),
          responseStatus: 'organizer',
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      await store.setPref(dayViewKey, 'grid');
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Previous day'));
      await pumps(tester);
      final tile = find.byKey(DayGrid.tileKeyFor('own-1'));
      expect(tile, findsOneWidget);

      await dragHourDown(tester, tile);
      await tester.pump(const Duration(milliseconds: 750));

      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.text('That time has passed.')),
          findsOneWidget);
      expect(writer.previewed, isEmpty);
      expect(writer.committed, isEmpty);
      expect(find.byType(WriteConfirmStrip), findsNothing);
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the next day read in flight keeps the grid on screen',
        (tester) async {
      final today = la.dateOf(DateTime.now().toUtc());
      final tomorrow = today.addDays(1);
      final start = la.localDateTime(tomorrow, 12, 0).toUtc();
      // Tomorrow's read is held until the test lets it go; every other day
      // answers at once with nothing.
      final held = Completer<List<CalendarEvent>>();
      await store.setPref(dayViewKey, 'grid');
      await pumpScreen(tester, overrides: [
        dayEventsProvider.overrideWith((ref, day) =>
            day == tomorrow ? held.future : const <CalendarEvent>[]),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byType(DayGrid), findsOneWidget);

      await tester.tap(find.byTooltip('Next day'));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        expect(find.byType(DayGrid), findsOneWidget);
        expect(find.text(DayPane.readingText), findsNothing);
      }
      expect(tester.widget<DayGrid>(find.byType(DayGrid)).day, tomorrow);

      held.complete([
        CalendarEvent(
          id: 'own-1',
          subject: 'Focus block',
          isOrganizer: true,
          organizerAddress: 'owner@contoso.com',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 1)),
          responseStatus: 'organizer',
          showAs: 'busy',
        ),
      ]);
      await pumps(tester);
      expect(find.byType(DayGrid), findsOneWidget);
      expect(find.byKey(DayGrid.tileKeyFor('own-1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the command bar in the screen', () {
    /// An own event (organiser, nobody invited) at noon TOMORROW, so a move
    /// later that day is in the future whatever time the suite runs.
    Future<void> seedTomorrow() => CalendarStore(db).upsertEvents([
          CalendarEvent(
            id: 'own-1',
            subject: 'Focus block',
            isOrganizer: true,
            organizerAddress: 'owner@contoso.com',
            startUtc: la
                .localDateTime(
                    la.dateOf(DateTime.now().toUtc()).addDays(1), 12, 0)
                .toUtc(),
            endUtc: la
                .localDateTime(
                    la.dateOf(DateTime.now().toUtc()).addDays(1), 13, 0)
                .toUtc(),
            responseStatus: 'organizer',
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');

    late ScriptedLlm llm;
    late _NoDirectory directory;

    /// The router over the test's store and [writer]: the real lexicon,
    /// parser and planner, a model nobody should call, a directory nobody
    /// should search.
    Override routerOver(CalendarWriter writer) {
      llm = ScriptedLlm();
      directory = _NoDirectory();
      return commandRouterProvider.overrideWithValue(CommandRouter(
        classifiers: const [LexiconClassifier()],
        planner: CommandPlanner(
          calendar: CalendarStore(db),
          backend: _NoMeetingTimes(),
          writer: writer,
          mailbox: () async => null,
        ),
        intentClient: () => llm,
        people: directory,
      ));
    }

    Finder bar() => find.byKey(DayCommandBar.fieldKey);

    /// The planner reads the store and dry-runs; a few frames more than the
    /// usual three.
    Future<void> settleCommand(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    Future<void> ask(WidgetTester tester, String text) async {
      await tester.enterText(bar(), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleCommand(tester);
    }

    testWidgets("what's on tomorrow, Enter: an answer card naming the meeting",
        (tester) async {
      await seedTomorrow();
      final writer = _RecordingWriter();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.text(DayCommandBar.hint), findsOneWidget);

      await ask(tester, "what's on tomorrow");

      final answer = find.byKey(CommandPlanCard.answerKey);
      expect(answer, findsOneWidget);
      expect(tester.widget<SelectableText>(answer).data,
          contains('Focus block'));
      expect(llm.calls, isEmpty, reason: 'a clear question asks no model');
      expect(directory.queries, isEmpty);

      await tester.tap(find.byKey(CommandPlanCard.cancelKey));
      await pumps(tester);
      expect(find.byKey(CommandPlanCard.answerKey), findsNothing);
    });

    testWidgets('a move of an own event: the proposal, Do it, the write, the '
        'toast with Undo, and the card gone', (tester) async {
      await seedTomorrow();
      final writer = _RecordingWriter();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);

      await ask(tester, 'move focus block to tomorrow 3pm');

      expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);
      expect(writer.committed, isEmpty, reason: 'nothing before the press');
      expect(llm.calls, isEmpty);

      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await settleCommand(tester);

      final moved = writer.committed.single;
      expect(moved.isUndo, isFalse);
      final write = moved.write as MoveEvent;
      expect(write.eventId, 'own-1');
      final tomorrow = la.dateOf(DateTime.now().toUtc()).addDays(1);
      expect(la.dateOf(write.startUtc!), tomorrow);
      expect(la.toLocal(write.startUtc!).hour, 15);
      expect(find.byKey(CommandPlanCard.summaryKey), findsNothing,
          reason: 'the card goes once its write went through');

      await tester.pump(const Duration(milliseconds: 750));
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining('Moved "Focus block"')),
          findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('a command written while an earlier card\'s write was in the '
        'air keeps its card when that write lands', (tester) async {
      await seedTomorrow();
      final writer = _RecordingWriter()..hold = Completer<void>();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);

      await ask(tester, 'move focus block to tomorrow 3pm');
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await settleCommand(tester);
      expect(writer.committed, hasLength(1), reason: 'the move is in the air');

      await ask(tester, "what's on tomorrow");
      expect(find.byKey(CommandPlanCard.answerKey), findsOneWidget);

      writer.hold!.complete();
      await settleCommand(tester);

      expect(find.byKey(CommandPlanCard.answerKey), findsOneWidget,
          reason: 'the old write clears only its own card');
      await tester.pump(const Duration(milliseconds: 750));
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining('Moved "Focus block"')),
          findsOneWidget,
          reason: 'the write still says what it did');
    });

    testWidgets('the grid draws the standing proposal as the ghost tile',
        (tester) async {
      await seedTomorrow();
      final writer = _RecordingWriter();
      await store.setPref(dayViewKey, 'grid');
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      await tester.tap(find.byTooltip('Next day'));
      await pumps(tester);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(DayGrid), findsOneWidget);
      expect(find.byKey(DayGrid.proposalKey), findsNothing);

      await ask(tester, 'move focus block to tomorrow 3pm');
      expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);
      final grid = tester.widget<DayGrid>(find.byType(DayGrid));
      expect(grid.proposal, isNotNull);
      expect(la.toLocal(grid.proposal!.startUtc).hour, 15);
      expect(find.byKey(DayGrid.proposalKey), findsOneWidget);

      await tester.tap(find.byKey(CommandPlanCard.cancelKey));
      await pumps(tester);
      expect(find.byKey(DayGrid.proposalKey), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    group('a typed move\'s ghost', () {
      Future<_RecordingWriter> moveOnGrid(WidgetTester tester) async {
        await seedTomorrow();
        final writer = _RecordingWriter();
        await store.setPref(dayViewKey, 'grid');
        await pumpScreen(tester, overrides: [
          calendarWritesProvider.overrideWithValue(writer),
          routerOver(writer),
        ]);
        await tester.tap(find.text('Day'));
        await pumps(tester);
        await tester.tap(find.byTooltip('Next day'));
        await pumps(tester);
        await ask(tester, 'move focus block to tomorrow 3pm');
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        return writer;
      }

      /// A desktop drag of the ghost by whole hours (its own height is one).
      Future<void> dragHours(WidgetTester tester, int hours) async {
        final ghost = find.byKey(DayGrid.proposalKey);
        final hour = tester.getSize(ghost).height;
        final gesture = await tester.startGesture(tester.getCenter(ghost));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(Offset(0, hour * hours / 2));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(Offset(0, hour * hours / 2));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await settleCommand(tester);
      }

      testWidgets('is named after the meeting, and dragged it re-proposes '
          'the same meeting under the same change key', (tester) async {
        final writer = await moveOnGrid(tester);
        final grid = tester.widget<DayGrid>(find.byType(DayGrid));
        expect(grid.proposal!.subject, 'Focus block');
        expect(grid.proposal!.adjustable, isTrue);
        final first = writer.previewed.last as MoveEvent;

        await dragHours(tester, -1);
        final again = writer.previewed.last as MoveEvent;
        expect(writer.previewed.length, greaterThan(1));
        expect(again.eventId, 'own-1');
        expect(again.ifMatch, first.ifMatch);
        expect(la.toLocal(again.startUtc!).hour, 14);
        expect(tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data,
            contains('Focus block'));
        await tester.pumpWidget(const SizedBox());
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('dragged back where the meeting already is, it is refused '
          'in the drop\'s words', (tester) async {
        final writer = await moveOnGrid(tester);
        final before = writer.previewed.length;
        await dragHours(tester, -3);
        expect(find.text("That's when it already is."), findsOneWidget);
        expect(writer.previewed, hasLength(before));
        await tester.pumpWidget(const SizedBox());
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    });

    testWidgets('⌘K: a calendar question in Find offers Ask Day, and Enter '
        'lands on the Day stop with the answer', (tester) async {
      // The providers as the app wires them, the writer aside: this is the
      // test that the real router is reachable from the screen.
      await seedTomorrow();
      final writer = _RecordingWriter();
      await pumpScreen(tester,
          overrides: [calendarWritesProvider.overrideWithValue(writer)]);

      await tester.enterText(
          find.byKey(FindField.fieldKey), "what's on tomorrow");
      await pumps(tester);
      expect(
          find.byKey(FindField.commandKeyFor(
              askDayLabel("what's on tomorrow"))),
          findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settleCommand(tester);

      final today = la.dateOf(DateTime.now().toUtc());
      expect(find.text(dayTitle(today, today)), findsOneWidget);
      expect(tester.widget<TextField>(bar()).controller!.text,
          "what's on tomorrow");
      final answer = find.byKey(CommandPlanCard.answerKey);
      expect(answer, findsOneWidget);
      expect(tester.widget<SelectableText>(answer).data,
          contains('Focus block'));
      // The Find box gave the words up.
      expect(
          tester
              .widget<TextField>(find.byKey(FindField.fieldKey))
              .controller!
              .text,
          isEmpty);
    });

    testWidgets('two ambiguous names, two presses: the choices add up to a '
        'proposal, and the model is never asked', (tester) async {
      final writer = _RecordingWriter();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      directory.hits['Sam'] = const [
        Person(id: 'u1', displayName: 'Sam Ortiz', mail: 'sam@contoso.com'),
        Person(id: 'u2', displayName: 'Sam Lee', mail: 'slee@fabrikam.com'),
      ];
      directory.hits['Bob'] = const [
        Person(id: 'u3', displayName: 'Robert Smith', mail: 'rsmith@contoso.com'),
        Person(id: 'u4', displayName: 'Bob Jones', mail: 'bjones@contoso.com'),
      ];
      await tester.tap(find.text('Day'));
      await pumps(tester);

      await ask(tester, 'book planning with Sam and Bob tomorrow 3pm');
      expect(find.text('Which Sam?'), findsOneWidget);
      await tester.tap(find.byKey(CommandPlanCard.optionKeyFor(1)));
      await settleCommand(tester);
      expect(find.text('Which Bob?'), findsOneWidget);
      await tester.tap(find.byKey(CommandPlanCard.optionKeyFor(0)));
      await settleCommand(tester);

      expect(find.byKey(CommandPlanCard.summaryKey), findsOneWidget);
      final create = writer.previewed.single as CreateEvent;
      expect(create.attendees, ['slee@fabrikam.com', 'rsmith@contoso.com']);
      expect(directory.queries, ['Sam', 'Bob']);
      expect(llm.calls, isEmpty);
    });

    testWidgets('a router that throws still ends the spin with a sentence',
        (tester) async {
      final writer = _RecordingWriter();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        commandRouterProvider.overrideWithValue(_ThrowingRouter(CommandPlanner(
          calendar: CalendarStore(db),
          backend: _NoMeetingTimes(),
          writer: writer,
          mailbox: () async => null,
        ))),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);

      await ask(tester, "what's on tomorrow");
      final reason =
          tester.widget<Text>(find.byKey(CommandPlanCard.reasonKey));
      expect(reason.data, 'Something went wrong reading that.');
      expect(find.byKey(DayCommandBar.busyKey), findsNothing);
    });

    testWidgets('where the calendar is not shown (SDK mode) there is no bar, '
        'and ⌘K offers no Ask Day', (tester) async {
      await pumpScreen(tester, overrides: [
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.sdkMode),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      expect(find.byType(DayPane), findsOneWidget);
      expect(bar(), findsNothing);

      await tester.enterText(
          find.byKey(FindField.fieldKey), "what's on tomorrow");
      await pumps(tester);
      expect(
          find.byKey(FindField.commandKeyFor(
              askDayLabel("what's on tomorrow"))),
          findsNothing);
    });

    testWidgets("the screen's letter keys stay out of the bar", (tester) async {
      await seedTomorrow();
      final writer = _RecordingWriter();
      await pumpScreen(tester, overrides: [
        calendarWritesProvider.overrideWithValue(writer),
        routerOver(writer),
      ]);
      await tester.tap(find.text('Day'));
      await pumps(tester);
      final today = la.dateOf(DateTime.now().toUtc());

      await tester.tap(bar());
      await pumps(tester);
      // `e` dismisses a thread and `z` undoes on this screen; typed into
      // the bar they are letters and nothing else.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.enterText(bar(), 'ez');
      await pumps(tester);

      expect(tester.widget<TextField>(bar()).controller!.text, 'ez');
      expect(find.text(dayTitle(today, today)), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(writer.committed, isEmpty);
    });
  });
}
