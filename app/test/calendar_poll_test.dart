import 'dart:async';
import 'dart:convert';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
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

/// The calendar's place in the inbox's refresh, which only the assembled
/// screen can show: the launch forces a sync, the poll timer reaches it
/// unforced (it is Graph calendar, not the Teams messaging endpoints), and a
/// calendar that never answers holds up nothing the mail list shows.

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

/// Records each call's `force` and answers with a future the test holds,
/// publishing what it answers as a real tick does.
class _RecordingCalendarSync extends CalendarSync {
  _RecordingCalendarSync(
    MessageStore store,
    CalendarStore calendar, {
    super.onOutcome,
  }) : super(const UnavailableCalendarBackend(), store, calendar);

  final List<bool> forces = [];
  final Completer<CalendarSyncOutcome> gate = Completer();

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) {
    forces.add(force);
    return gate.future.then((outcome) {
      onOutcome?.call(outcome);
      return outcome;
    });
  }
}

const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _RecordingCalendarSync calendarSync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread() async {
    final at = MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    await store.upsertMessage({
      'source_message_id': 'c1-m1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': at,
      'body_text': 'The homepage copy is in.',
    });
    // Needs You is the decision model's probability against the slider since
    // the needs-you signals round; the thread sits there by it.
    await seedNeedsYou(store, 'email', 'c1-m1');
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': at,
      'last_inbound_at': at,
    });
    await store.recomputeConversationCounts('email', 'c1');
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    bool processing = false,
    String? ownerMail,
    List<Override> overrides = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Built inside the test body, not in setUp: a completer made outside the
    // fake-async zone schedules its callbacks on the real event loop, which
    // `tester.pump` never drains. Built by the override, so it publishes
    // through the provider's own wiring.

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _readGrant;
    // The brief planner plans nothing until it knows whose calendar it is.
    if (ownerMail != null) {
      tokens.values['account_json'] =
          jsonEncode({'displayName': 'Me', 'mail': ownerMail});
    }
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The default MCP session would ask a server that is not there.
    await store.setPref(backendModeKey, backendModeSdk);
    await store.setPref(processingOnKey, processing ? 'true' : 'false');
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
        calendarSyncProvider.overrideWith((ref) {
          late final _RecordingCalendarSync sync;
          sync = _RecordingCalendarSync(
            store,
            CalendarStore(db),
            onOutcome: calendarOutcomePublisher(ref, () => sync.availability),
          );
          return calendarSync = sync;
        }),
        ...overrides,
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Pumps rather than a settle: this screen owns a sixty-second periodic
    // timer, and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the launch forces a calendar sync and the poll reaches it '
      'unforced, while a calendar that never answers delays no mail',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);

    expect(calendarSync.forces, [true],
        reason: 'opening the app is a refresh, and a refresh is forced');
    // The calendar's future is still open, and the mail is on screen anyway.
    expect(calendarSync.gate.isCompleted, isFalse);
    expect(find.text('Homepage copy'), findsWidgets);

    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    await tester.pump();

    expect(calendarSync.forces, [true, false],
        reason: 'the poll timer may reach the calendar, throttled inside it');
    expect(find.text('Homepage copy'), findsWidgets);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(InboxScreen)));
    expect(container.read(calendarRevisionProvider), 0);
    calendarSync.gate.complete(
      const CalendarSyncOutcome(CalendarSyncStatus.synced, upserts: 1),
    );
    await tester.pump();
    // Both waiting ticks saw a change, so the mirror's readers were told
    // twice — by the sync's publisher, not by the inbox.
    expect(container.read(calendarRevisionProvider), 2);
  });

  group('briefs after a synced tick', () {
    setUpAll(initCalendarZones);

    const owner = 'me@contoso.com';
    const dana = 'dana.ortiz@contoso.com';

    /// A meeting tomorrow at 10:00 in Los Angeles with Dana — inside the
    /// briefs' box at any hour — and a thread with her an hour old, so the
    /// planner's gather finds mail and queues the brief.
    Future<void> seedMeeting(CalendarZone la) async {
      final start = la
          .localDateTime(la.dateOf(DateTime.now().toUtc()).addDays(1), 10, 0)
          .toUtc();
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'evt-brief',
          subject: 'Fabrikam sync',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          showAs: 'busy',
          attendees: const [
            Attendee(name: 'Me', address: owner),
            Attendee(name: 'Dana Ortiz', address: dana),
          ],
        ),
      ], syncRun: 'run-1');
      final at = MessageStore.isoStamp(
          DateTime.now().toUtc().subtract(const Duration(hours: 1)));
      await store.upsertMessage({
        'source_message_id': 'd1-m1',
        'conversation_key': 'd1',
        'direction': 'inbound',
        'subject': 'Fabrikam renewal',
        'from_name': 'Dana Ortiz',
        'from_address': dana,
        'received_at': at,
        'body_text': 'Can we go over the renewal?',
      });
      await store.upsertConversation({
        'conversation_key': 'd1',
        'subject': 'Fabrikam renewal',
        'participants_json': jsonEncode([
          {'name': 'Dana Ortiz', 'email': dana},
        ]),
        'state': 'waiting',
        'last_message_at': at,
        'last_inbound_at': at,
      });
    }

    /// Completes the launch's forced sync as `synced` and lets the planner,
    /// which is store reads off the real event loop, run.
    Future<String?> syncedThenStatus(WidgetTester tester) async {
      calendarSync.gate.complete(
        const CalendarSyncOutcome(CalendarSyncStatus.synced, upserts: 1),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pump();
      return tester.runAsync<String?>(() =>
          store.workStatusOf('meeting_brief', 'calendar', 'evt-brief'));
    }

    testWidgets('a synced tick with the zone resolved plans the brief',
        (tester) async {
      final la = CalendarZone.tryNamed('America/Los_Angeles')!;
      await seedMeeting(la);
      await pumpScreen(tester, processing: true, ownerMail: owner, overrides: [
        calendarZoneProvider.overrideWith((ref) async => la),
      ]);

      // Queued by the planner. Processing is on (the planner runs only
      // then), so the woken draft lane may already have claimed the row —
      // and failed it, with no model in a test: the row's existence is the
      // claim, and its null payload says the planner wrote it, not a press.
      expect(await syncedThenStatus(tester), isNotNull,
          reason: 'the planner queued the meeting');
      final row = await tester.runAsync(() => db
          .customSelect('SELECT payload_json FROM work_items '
              "WHERE task_kind = 'meeting_brief' AND entity_id = 'evt-brief'")
          .getSingle());
      expect(row!.data['payload_json'], isNull);
    });

    testWidgets('a synced tick before the zone has resolved plans nothing: '
        "UTC's tomorrow is not the owner's", (tester) async {
      final la = CalendarZone.tryNamed('America/Los_Angeles')!;
      await seedMeeting(la);
      // Never completes, and nothing in the body awaits it.
      final never = Completer<CalendarZone>();
      await pumpScreen(tester, processing: true, ownerMail: owner, overrides: [
        calendarZoneProvider.overrideWith((ref) => never.future),
      ]);

      expect(await syncedThenStatus(tester), isNull,
          reason: 'no zone, no pass: no work row at all');
    });
  });
}
