import 'dart:async';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart'
    show Attendee, CalendarEvent;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/event_panel.dart' show EventPanelBody;
import 'package:bond_inbox/widgets/meeting_card.dart' show MeetingCard;
import 'package:bond_inbox/widgets/person_meeting_line.dart'
    show PersonMeetingLine;
import 'package:bond_inbox/widgets/side_panel.dart' show SidePanelHost;
import 'package:flutter/material.dart';
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

  Future<void> pumpScreen(WidgetTester tester) async {
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
}
