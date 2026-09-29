import 'dart:async';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart' show CalendarEvent;
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
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
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
}
