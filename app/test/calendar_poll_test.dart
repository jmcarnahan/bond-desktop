import 'dart:async';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
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
        noCommandHeads(),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        calendarSyncProvider.overrideWithValue(calendarSync),
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
    // twice.
    expect(container.read(calendarRevisionProvider), 2);
  });
}
