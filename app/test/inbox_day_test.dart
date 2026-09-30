import 'dart:async';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show Attendee, CalendarEvent, WritePreview;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/day_providers.dart' show dayEventsProvider;
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/day_grid.dart' show DayGrid;
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:bond_inbox/widgets/event_actions.dart' show EventActions;
import 'package:bond_inbox/widgets/event_panel.dart' show EventPanelBody;
import 'package:bond_inbox/widgets/meeting_card.dart' show MeetingCard;
import 'package:bond_inbox/widgets/person_meeting_line.dart'
    show PersonMeetingLine;
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
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
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
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
      expect(find.text('Moving here…'), findsOneWidget);
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
}
