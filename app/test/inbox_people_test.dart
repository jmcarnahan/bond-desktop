// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/person_room_pane.dart';
import 'package:bond_inbox/widgets/room_header.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The shell as the screen assembles it: the icon rail, the list column it
/// scopes, and the People room a colleague's row opens.
///
/// The interesting claim is that ONE row stands for a person however many ways
/// they reach this mailbox — a mail thread and a Teams chat with the same
/// colleague are one room, and what they deferred is in none.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// The real connector asks the auth session whether `Chat.Read` was granted,
/// and in a widget test that question reaches an MCP stack nothing started.
class _FakeTeamsSync implements TeamsSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<String?> get lastSyncedAt async => null;
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread(
    String key,
    String subject, {
    String source = 'email',
    String who = 'Dana Whitfield',
    String address = 'dana@example.test',
    String receivedAt = '2026-08-28T09:00:00Z',
    String? bucket,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': who,
      'from_address': address,
      'received_at': receivedAt,
      'body_text': 'The $subject body.',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"$who","email":"$address"}]',
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
    if (bucket != null) {
      await store.setConversationBucket(source, key, bucket: bucket);
    }
  }

  /// One colleague on both connectors, plus a thread she is not waiting on.
  Future<void> seedPerson() async {
    await seedThread('c1', 'Homepage copy');
    await seedThread(
      'chat-1',
      'Launch date',
      source: 'teams',
      address: 'teams:19:abc',
      receivedAt: '2026-08-28T10:00:00Z',
    );
    await seedThread(
      'c2',
      'Old invoice',
      receivedAt: '2026-08-20T09:00:00Z',
      bucket: 'later',
    );
  }

  /// Runs out every window the queues arm behind them.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(
    WidgetTester tester, {
    Size surface = const Size(1400, 900),
    RailSection section = RailSection.people,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(section),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// The room row in the list column, never the overview beside it.
  Finder roomRow(String title) => find.descendant(
        of: find.byType(AppRail),
        matching: find.text(title),
      );

  Future<void> openRoom(WidgetTester tester, String title) async {
    await tester.tap(roomRow(title));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapStop(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text(label),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the shell has both rails and nothing at the foot of the column',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);

    expect(find.byType(IconRail), findsOneWidget);
    expect(find.byType(AppRail), findsOneWidget);
    // Identity and the app's own controls live in the avatar menu now.
    expect(find.byTooltip('Sign out'), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
    // What acts on the list stayed with the list.
    expect(find.byTooltip('New message'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('one row stands for a person on both connectors',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);

    expect(roomRow('Dana Whitfield'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the room holds her live threads and not what was deferred',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    // Rewritten in Phase 6: the room is a merged timeline, not a list pane.
    final pane = find.byType(PersonRoomPane);
    expect(pane, findsOneWidget);
    expect(find.descendant(
      of: find.byType(RoomHeader<ThreadTab>),
      matching: find.text('Dana Whitfield'),
    ), findsOneWidget);
    expect(find.text('2 threads · mail and Teams'), findsOneWidget);
    expect(find.text('💬 Launch date'), findsOneWidget);
    expect(find.text('Homepage copy'), findsOneWidget);
    // Deferred mail is in Later, and in no room at all.
    expect(find.text('Old invoice'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a mail thread in the room opens BESIDE it', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byKey(RootMessageCard.keyFor('email', 'c1')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // D3: a thread reached from INSIDE a room opens beside, so the history
    // the reader came from stays on screen.
    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(find.byType(PersonRoomPane), findsOneWidget);
    expect(
      tester.widget<ThreadDetailPanel>(find.byType(ThreadDetailPanel))
          .conversation
          .id,
      'c1',
    );
    await settleQueues(tester);
  });

  testWidgets('Back out of the room lands on the People overview',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.descendant(
      of: find.byType(RoomHeader<ThreadTab>),
      matching: find.byTooltip('Back'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(PersonRoomPane), findsNothing);
    expect(find.text('People'), findsWidgets);
    await settleQueues(tester);
  });

  testWidgets('the Home stop clears the room', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');
    expect(find.byType(PersonRoomPane), findsOneWidget);

    await tapStop(tester, 'Home');

    expect(find.byType(PersonRoomPane), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('the AI stop is Settings, narrowed and retitled', (tester) async {
    await seedPerson();
    await pumpInbox(tester);

    await tapStop(tester, 'AI');

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester.widget<SettingsScreen>(find.byType(SettingsScreen)).scope,
      SettingsScope.ai,
    );
    expect(find.text('AI'), findsWidgets);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Needs You'), findsWidgets);
    // What is about the app rather than the model is not on this pane.
    expect(find.text('Sync & data'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('the column shows only the stop that is lit', (tester) async {
    await seedPerson();
    await pumpInbox(tester);

    // The header caption names the scope too, so PEOPLE reads twice; what
    // says the column is narrowed is the sections that are NOT there.
    expect(find.text('PEOPLE'), findsWidgets);
    expect(find.text('NEEDS YOU'), findsNothing);
    expect(find.text('STORYLINES'), findsNothing);
    expect(find.text('LATER'), findsNothing);

    await tapStop(tester, 'Home');

    // Home is the whole stack again.
    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('STORYLINES'), findsOneWidget);
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('LATER'), findsOneWidget);
    await settleQueues(tester);
  });
}
