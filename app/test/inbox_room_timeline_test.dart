// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/message_row.dart';
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
/// The claim: one colleague, one history. Her chat reads as messages, her mail
/// reads as a card, both are in one column, and every way into a thread from
/// here opens it BESIDE the room rather than over it.

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

/// A grant, without the whole SDK stack behind it. The room's composer only
/// appears on the top rung, and that rung is one `hasScope` answer.
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
    String address = 'dana@example.test',
    String receivedAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"$address"}]',
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
    await store.recomputeConversationCounts(source, key);
  }

  /// One colleague on both connectors: a mail thread, and a 1:1 chat with two
  /// messages in it.
  Future<void> seedPerson() async {
    await seedMessage('c1', 'c1-m1', subject: 'Homepage copy',
        body: 'The hero paragraph.');
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
        address: 'teams:19:abc',
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

  testWidgets('one column holds her chat messages and her mail card',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    expect(find.byType(PersonRoomPane), findsOneWidget);
    // The chat is drawn as messages, under its own heading.
    expect(find.text('Is the fourteenth still good?'), findsOneWidget);
    expect(find.text('The fourteenth works.'), findsOneWidget);
    expect(find.text('💬 Launch date'), findsOneWidget);
    expect(find.byType(MessageRow), findsNWidgets(2));
    // The mail thread is a card, not a transcript.
    expect(find.byKey(RootMessageCard.keyFor('email', 'c1')), findsOneWidget);
    expect(find.text('The hero paragraph.'), findsNothing);
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

  testWidgets('Open chat opens the chat beside too', (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    await tester.tap(find.byKey(PersonRoomPane.openChatKeyFor('chat-1')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(
      tester
          .widget<ThreadDetailPanel>(find.descendant(
            of: find.byType(SidePanelHost),
            matching: find.byType(ThreadDetailPanel),
          ))
          .conversation
          .id,
      'chat-1',
    );
    await settleQueues(tester);
  });

  testWidgets('a one-person room with a chat docks a composer at her name',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');
    // The capability is a keychain read; the box waits on it.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    final composer = find.descendant(
      of: find.byType(PersonRoomPane).hitTestable(),
      matching: find.byType(Composer),
    );
    expect(find.byType(Composer), findsOneWidget);
    expect(composer, findsNothing, reason: 'the box is docked UNDER the pane');
    expect(
      tester.widget<Composer>(find.byType(Composer)).hint,
      'Message Dana Whitfield…',
    );
    // The alternative is never offered beside it.
    expect(find.byKey(PersonRoomPane.messageButtonKey), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a mail-only room offers the Message button instead',
      (tester) async {
    await seedMessage('c1', 'c1-m1', subject: 'Homepage copy');
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');

    expect(find.byKey(PersonRoomPane.messageButtonKey), findsOneWidget);
    expect(find.text('Message Dana Whitfield'), findsOneWidget);
    expect(find.byType(Composer), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('without a send grant a chat room gets no box either',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester, scopes: const {'mail.send'});
    await openRoom(tester, 'Dana Whitfield');
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // There is no drafts folder behind a Teams message, so a box that could
    // not send would be a lie.
    expect(find.byType(Composer), findsNothing);
    await settleQueues(tester);
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
    // The room's face for her comes off her NEWEST thread, which is the chat
    // — so the address on it is a `teams:` id, which the panel deliberately
    // does not show. What it can say is how much is live.
    expect(find.text('2 threads · 1 mail · 1 chat'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('opening the room marks its chat read, and leaves mail alone',
      (tester) async {
    await seedPerson();
    await pumpInbox(tester);
    await openRoom(tester, 'Dana Whitfield');
    await settleQueues(tester);

    // The chat IS on screen, the way a Slack DM is read when it is opened. The
    // mail is a card — a summary, not the mail.
    final rows = await store.loadConversations(sources: ['email', 'teams']);
    final chat = rows.firstWhere((c) => c.id == 'chat-1');
    final mail = rows.firstWhere((c) => c.id == 'c1');
    expect(chat.unreadCount, 0);
    expect(mail.unreadCount, 1);
  });
}
