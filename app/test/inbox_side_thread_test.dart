// `show`: drift generates row classes named Message/Conversation/Storyline
// from the tables, and this file means the app's own models.
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
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A thread opened BESIDE what the reader was looking at, as the screen
/// assembles it.
///
/// A storyline is the only room a thread opens beside in this phase: its
/// episode cards are root messages, and tapping one puts that conversation in
/// the side panel with the spine still on screen. What this file pins is the
/// seam — which pane holds what, and every way back out of it.

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
    String body = 'body',
    String receivedAt = '2026-08-28T09:00:00Z',
    String state = 'waiting',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'received_at': receivedAt,
      'body_text': body,
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'state': state,
      'last_message_at': receivedAt,
    });
  }

  /// One storyline over two threads, the launch thread newest.
  Future<void> seedStoryline() async {
    await seedThread('c1', 'Homepage copy', body: 'The hero paragraph.');
    await seedThread(
      'c2',
      'Launch date',
      body: 'The fourteenth works.',
      receivedAt: '2026-08-28T10:00:00Z',
    );
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');
  }

  /// Runs out every window the queues arm behind them, so a test does not end
  /// with one pending.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(
    WidgetTester tester, {
    Size surface = const Size(1400, 900),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(RailSection.needsYou),
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

  /// Opens the storyline in the main pane. At narrow widths the rail is an
  /// overlay, so the hamburger comes first.
  Future<void> openStoryline(WidgetTester tester, {bool narrow = false}) async {
    Future<void> openRail() async {
      if (!narrow) return;
      await tester.tap(find.byTooltip('Sections'));
      await tester.pump();
      await tester.pump();
    }

    // The list column shows the stop that is lit, so the icon rail comes
    // first. Picking a stop clears the narrow overlay, so it is reopened.
    await openRail();
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    await tester.pump();
    await tester.pump();
    await openRail();
    // Scoped to the column: the overview beside it names the same storylines.
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text('Website redesign'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Taps one episode card, which opens that thread beside the spine.
  Future<void> openEpisode(WidgetTester tester, String cardText) async {
    await tester.tap(find.text(cardText));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// The thread panel in the side panel, if there is one.
  final sideThread = find.descendant(
    of: find.byType(SidePanelHost),
    matching: find.byType(ThreadDetailPanel),
  );

  testWidgets('a card opens its thread beside the spine', (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);

    expect(find.byType(SidePanelHost), findsNothing);

    await openEpisode(tester, '✉ Homepage copy');

    // The storyline keeps the main pane: it is the room the reader is in, and
    // the thread is one conversation in it.
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    expect(sideThread, findsOneWidget);
    final panel = tester.widget<ThreadDetailPanel>(sideThread);
    expect(panel.conversation.id, 'c1');
    // The transcript is loaded, not merely announced. Scoped, because the
    // card in the spine previews the same sentence.
    expect(
      find.descendant(of: sideThread, matching: find.text('The hero paragraph.')),
      findsOneWidget,
    );
    // The host's ✕ is the way out, so the panel draws no Back of its own —
    // there is no selection under this thread for one to return to.
    expect(panel.onBack, isNull);
    await settleQueues(tester);
  });

  testWidgets('the thread beside has its draft reloaded on the sync tick',
      (tester) async {
    // The hazard the selected thread's reload was written for, on the side
    // that carries it now: an Inbox row opens BESIDE and never sets the
    // selection, so this is the thread the reader is actually looking at. A
    // suggestion left on screen after the sync deleted it gets sent as a
    // reply to a message that is no longer the newest one.
    await seedStoryline();
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c1',
      replyToMessageId: 'c1-m1',
      body: 'The hero paragraph reads well.',
    );
    await pumpInbox(tester);
    await openStoryline(tester);
    await openEpisode(tester, '✉ Homepage copy');

    expect(find.byKey(InboxScreen.useSuggestionKey), findsOneWidget);

    // What the next pull does to a thread that just received new mail.
    await store.deleteDraftForMessage('email', 'c1-m1');

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(InboxScreen.useSuggestionKey),
      findsNothing,
      reason: 'the composer beside has to find out on the pull, not on the '
          'next AI progress event',
    );
    await settleQueues(tester);
  });

  testWidgets('and a second card replaces the first', (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);

    await openEpisode(tester, '✉ Homepage copy');
    await openEpisode(tester, '✉ Launch date');

    // One thing at a time on that side of the seam.
    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(
      tester.widget<ThreadDetailPanel>(sideThread).conversation.id,
      'c2',
    );
    await settleQueues(tester);
  });

  testWidgets('Expand hands it the main pane and closes the side',
      (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);
    await openEpisode(tester, '✉ Homepage copy');

    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // ⤢ on a thread is a selection: the thread is in the main pane and the
    // storyline it came from is not on screen, so it is never in both.
    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    final panel =
        tester.widget<ThreadDetailPanel>(find.byType(ThreadDetailPanel));
    expect(panel.conversation.id, 'c1');
    // And the main pane's thread has its own way back.
    expect(panel.onBack, isNotNull);
    await settleQueues(tester);
  });

  testWidgets('the close gives the width back to the spine', (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);
    await openEpisode(tester, '✉ Homepage copy');

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a rail row takes the thread beside with it', (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);
    await openEpisode(tester, '✉ Homepage copy');
    expect(find.byType(SidePanelHost), findsOneWidget);

    // Every selection clears the overlays, and a thread left open beside the
    // next thing the user asked for is exactly what that list is for.
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Needs You'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a window with no room for both gives the panel the pane',
      (tester) async {
    await seedStoryline();
    // Wide enough for the rail and a main pane, and not wide enough for a
    // 420 thread beside a 420 transcript: 1100 leaves 823 after the rail.
    await pumpInbox(tester, surface: const Size(1100, 900));
    await openStoryline(tester);
    await openEpisode(tester, '✉ Homepage copy');

    expect(sideThread, findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('and under the two-pane breakpoint so does the narrow layout',
      (tester) async {
    await seedStoryline();
    await pumpInbox(tester, surface: const Size(900, 900));
    await openStoryline(tester, narrow: true);
    await openEpisode(tester, '✉ Homepage copy');

    expect(sideThread, findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('opening a thread beside is reading it', (tester) async {
    await seedStoryline();
    await pumpInbox(tester);
    await openStoryline(tester);

    final before = await db
        .customSelect(
          "SELECT is_read FROM messages WHERE source_message_id = 'c1-m1'",
        )
        .getSingle();
    expect(before.data['is_read'], 0);

    await openEpisode(tester, '✉ Homepage copy');
    await tester.pump();

    // The same rule the main pane's selection follows: opening it IS reading
    // it, wherever it opened.
    final after = await db
        .customSelect(
          "SELECT is_read FROM messages WHERE source_message_id = 'c1-m1'",
        )
        .getSingle();
    expect(after.data['is_read'], 1);
    await settleQueues(tester);
  });

  testWidgets('two members sharing a key open their own thread',
      (tester) async {
    // A conversation key is unique within one connector and not across
    // them: the mail and chat connectors mint keys with no knowledge of each
    // other. The pill row that used to pick a storyline's reply target
    // carried this rule; the card does now — its tap names the source with
    // the key, so a chat never opens its mail namesake.
    await seedStoryline();
    await store.upsertMessage({
      'source': 'teams',
      'source_message_id': 'c1-t1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'teams:u1',
      'received_at': '2026-08-28T11:00:00Z',
      'body_text': 'Any word on the copy?',
    });
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': 'c1',
      'state': 'waiting',
      'last_message_at': '2026-08-28T11:00:00Z',
      'participants_json':
          '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
    });
    await store.addStorylineMember('sl-1', 'teams', 'c1', addedBy: 'auto');
    await pumpInbox(tester);
    await openStoryline(tester);

    // The chat card is named by who is on it — a chat has no subject — and
    // scoped to the spine, because the rail names the same chat.
    await tester.tap(find.descendant(
      of: find.byType(StorylineTimelinePanel),
      matching: find.text('💬 Sarah Whitfield'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final panel = tester.widget<ThreadDetailPanel>(sideThread);
    expect(panel.conversation.source, 'teams');
    expect(panel.conversation.id, 'c1');

    await openEpisode(tester, '✉ Homepage copy');
    final mail = tester.widget<ThreadDetailPanel>(sideThread);
    expect(mail.conversation.source, 'email');
    expect(mail.conversation.id, 'c1');
    await settleQueues(tester);
  });
}
