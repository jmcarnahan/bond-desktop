// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/people_sort.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/new_message_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/person_panel.dart';
import 'package:bond_inbox/widgets/person_room_pane.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A person's room, as the screen assembles it.
///
/// The claim: one colleague, one list. Every thread with her — mail and chat,
/// hers alone and shared with others — is a CARD in one top-anchored column,
/// in the order she asked for, and every way into a conversation from here
/// opens it BESIDE the room rather than over it. The room itself offers one
/// thing about the PERSON: `Message`.

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

/// A grant, without the whole SDK stack behind it. The thread that opens
/// beside only gets a box on the `Chat.ReadWrite` rung.
class _FakeAuth implements AuthSession {
  final Set<String> scopes;

  _FakeAuth({this.scopes = const {'mail.send', 'chat.readwrite'}});

  @override
  Future<bool> hasScope(String bareScope) async => scopes.contains(bareScope);

  @override
  Future<AccountInfo?> get storedAccount async => const AccountInfo(
        displayName: 'Jordan Bond',
        mail: 'jordan@example.test',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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

  Future<void> seedMessage(
    String key,
    String id, {
    String source = 'email',
    String? subject,
    String receivedAt = '2026-08-28T09:00:00Z',
    String body = 'A line.',
    String who = 'Dana Whitfield',
    String address = 'dana@example.test',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': who,
      'from_address': address,
      'received_at': receivedAt,
      'body_text': body,
      'is_read': 0,
    });
  }

  Future<void> seedThread(
    String key,
    String? subject, {
    String source = 'email',
    String participantsJson =
        '[{"name":"Dana Whitfield","email":"dana@example.test"}]',
    String receivedAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'participants_json': participantsJson,
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
    await store.recomputeConversationCounts(source, key);
  }

  /// One colleague on both connectors: a mail thread, and a 1:1 chat with two
  /// messages in it.
  Future<void> seedPerson() async {
    await seedMessage('c1', 'c1-m1',
        subject: 'Homepage copy', body: 'The hero paragraph.');
    await seedThread('c1', 'Homepage copy');

    await seedMessage('chat-1', 'chat-1-m1',
        source: 'teams',
        address: 'teams:19:abc',
        receivedAt: '2026-08-28T10:00:00Z',
        body: 'Is the fourteenth still good?');
    await seedMessage('chat-1', 'chat-1-m2',
        source: 'teams',
        address: 'teams:19:abc',
        receivedAt: '2026-08-28T11:00:00Z',
        body: 'The fourteenth works.');
    await seedThread('chat-1', 'Launch date',
        source: 'teams',
        participantsJson:
            '[{"name":"Dana Whitfield","email":"teams:19:abc"}]',
        receivedAt: '2026-08-28T11:00:00Z');
  }

  /// Runs out every window the queues arm behind them.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(
    WidgetTester tester, {
    Set<String> scopes = const {'mail.send', 'chat.readwrite'},
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(RailSection.people),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      authSessionProvider.overrideWithValue(_FakeAuth(scopes: scopes)),
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

  Future<void> openRoom(WidgetTester tester, String title) async {
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text(title),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  double topOf(WidgetTester tester, String source, String id) =>
      tester.getTopLeft(find.byKey(RootMessageCard.keyFor(source, id))).dy;

  testWidgets('one column holds every thread with her, as cards',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    expect(find.byType(PersonRoomPane), findsOneWidget);
    expect(find.byKey(RootMessageCard.keyFor('email', 'c1')), findsOneWidget);
    expect(
      find.byKey(RootMessageCard.keyFor('teams', 'chat-1')),
      findsOneWidget,
    );
    // Cards and not transcripts: the messages are in the thread that opens
    // beside, which is where the box and the files are too.
    expect(find.text('The fourteenth works.'), findsNothing);
    expect(find.text('The hero paragraph.'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('newest first, anchored at the TOP of the pane', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    // The chat is the newer of the two.
    expect(
      topOf(tester, 'teams', 'chat-1'),
      lessThan(topOf(tester, 'email', 'c1')),
    );
    // What used to pin the whole list to the bottom of the pane: a room with
    // three cards in it read as a gap with three cards under it.
    expect(
      tester.widget<ListView>(find.byKey(PersonRoomPane.listKey)).reverse,
      isFalse,
    );
    await settleQueues(tester);
  });

  testWidgets('a card opens its thread beside, with the room still in main',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byKey(RootMessageCard.keyFor('email', 'c1')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(ThreadDetailPanel),
      ),
      findsOneWidget,
    );
    expect(find.byType(PersonRoomPane), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the room\'s order control flips it, and is remembered',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byKey(PersonRoomPane.sortKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester
        .tap(find.byKey(PersonRoomPane.sortItemKeyFor(RoomSort.oldest)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      topOf(tester, 'email', 'c1'),
      lessThan(topOf(tester, 'teams', 'chat-1')),
    );
    expect(await store.getPref(roomSortKey), 'oldest');
    await settleQueues(tester);
  });

  testWidgets('the Direct and Groups pills narrow her threads', (tester) async {
    await seedPerson();
    // A thread she is on with somebody else, so Groups has something to keep.
    await seedMessage('g1', 'g1-m1', subject: 'The five of us');
    await seedThread(
      'g1',
      'The five of us',
      participantsJson: '[{"name":"Dana Whitfield","email":"dana@example.test"},'
          '{"name":"Priya Raman","email":"priya@example.test"}]',
    );
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.descendant(
      of: find.byKey(PersonRoomPane.filterPillsKey),
      matching: find.text(RoomFilter.groups.label),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(RootMessageCard.keyFor('email', 'g1')), findsOneWidget);
    expect(find.byKey(RootMessageCard.keyFor('email', 'c1')), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('the filter field narrows the room as it is typed',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.enterText(
      find.descendant(
        of: find.byType(PersonRoomPane),
        matching: find.byType(TextField),
      ),
      'homepage',
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(RootMessageCard.keyFor('email', 'c1')), findsOneWidget);
    expect(find.byKey(RootMessageCard.keyFor('teams', 'chat-1')), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('Message opens her direct chat beside, with the box focused',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byTooltip('Message'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    final composer = find.descendant(
      of: find.byType(SidePanelHost),
      matching: find.byType(Composer),
    );
    expect(composer, findsOneWidget);
    expect(
      tester.widget<Composer>(composer).focusNode?.hasFocus,
      isTrue,
      reason: 'the cursor lands in the box, the way the hover Reply hands over',
    );
    await settleQueues(tester);
  });

  testWidgets('Message on a mail-only person composes instead',
      (tester) async {
    await seedMessage('c1', 'c1-m1', subject: 'Homepage copy');
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byTooltip('Message'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.byType(NewMessageScreen), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('opening a room marks nothing read', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');
    await settleQueues(tester);

    // Every row here is a CARD — a summary, not the mail. The chat used to be
    // drawn inline and read on open; now its messages are in the thread that
    // opens beside, and that is where reading it happens.
    final rows = await store.loadConversations(sources: ['email', 'teams']);
    expect(rows.firstWhere((c) => c.id == 'chat-1').unreadCount, 2);
    expect(rows.firstWhere((c) => c.id == 'c1').unreadCount, 1);
  });

  testWidgets('Profile opens the person beside the room', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byTooltip('Profile'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(PersonPanelBody),
      ),
      findsOneWidget,
    );
    expect(find.text('2 threads · 1 mail · 1 chat'), findsOneWidget);
    await settleQueues(tester);
  });
}
