import 'dart:async';
import 'dart:convert';

// `show`: drift generates row classes named Message/Conversation/Storyline
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/storylines_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:bond_inbox/widgets/storyline_blocks_section.dart';
import 'package:bond_inbox/widgets/storyline_pickers.dart';
import 'package:bond_inbox/widgets/room_header.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The membership of an open storyline, as the SCREEN assembles it.
///
/// `storyline_timeline_test.dart` pins what the panel does with a member list
/// it is handed. This file pins where that list comes from, which stopped being
/// a read the build could make for itself when the store went asynchronous: it
/// is a cached provider now, and a cache that nothing dropped would leave the
/// header counting the membership from before the user's last action.

class _FakeSync implements MailSync {
  /// How many times the screen has asked for a pull. The launch sync is one
  /// of them, so the button tests read this before and after their tap.
  int syncs = 0;

  /// Set to hold a pull open, so a test can look at the screen while a sync
  /// is genuinely in flight. Completed by the test before it ends.
  Completer<void>? gate;

  @override
  Future<void> syncNow() async {
    syncs++;
    await gate?.future;
  }

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A Teams connector that answers instantly.
///
/// The real one asks the auth session whether `Chat.Read` was granted, and in
/// a widget test that question reaches an MCP stack nothing started — so the
/// pull never comes back at all. Every other test in this file survives that
/// because nothing awaits the launch refresh; a Sync button whose label is
/// held up until the whole pass lands does not, so the tests that press it
/// hand the screen a connector with nothing behind it.
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

  /// One inbound message and the conversation row it folds into. [state] is
  /// `waiting` unless the test needs an open ask on screen: the ask lines and
  /// the CTA banner are both rendered only while the thread still wants the
  /// user, so a `needs_reply` row is what puts them there.
  Future<void> seedThread(
    String key,
    String subject, {
    String source = 'email',
    String receivedAt = '2026-08-28T09:00:00Z',
    String state = 'waiting',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'received_at': receivedAt,
      'body_text': 'body',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': state,
      'last_message_at': receivedAt,
    });
  }

  /// Runs out every window the queues arm behind them, so the test does not
  /// end with one pending: the 400ms reload debounce they report on, and —
  /// because their stage writes tick the home feed — its tick window and the
  /// metrics epoch that follows it.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  /// The screen itself, over the seeded store, settled enough to click.
  ///
  /// [section] is the pane it lands on; [sync] and [teamsSync] are the
  /// connectors it lands on it with. The storylines overview needs the first,
  /// and the Sync button needs fakes it can still see afterwards — see
  /// [_FakeTeamsSync] for why the second one is not left to the real thing.
  Future<void> pumpInbox(
    WidgetTester tester, {
    RailSection section = RailSection.needsYou,
    MailSync? sync,
    TeamsSync? teamsSync,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // Predates Home: this file asserts on a pane the rail's old landing
      // section opened.
      initialSectionProvider.overrideWithValue(section),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(sync ?? _FakeSync()),
      if (teamsSync != null)
        teamsSyncProvider.overrideWithValue(teamsSync),
      // Unstarted, so it owns no sweep timer. This file's container outlives
      // the widget tree — it is disposed in a tearDown, after flutter_test has
      // already checked for leaked timers — and nothing here is about
      // notifications.
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

  /// Opens the storyline named [title] in the main pane. [sync] and
  /// [teamsSync] are handed straight to [pumpInbox], for the tests that press
  /// this screen's own Sync.
  Future<void> openStoryline(
    WidgetTester tester,
    String title, {
    MailSync? sync,
    TeamsSync? teamsSync,
  }) async {
    await pumpInbox(tester, sync: sync, teamsSync: teamsSync);

    // The list column is scoped to whichever stop is lit, so the icon rail is
    // the way to the storylines list — and the row is tapped inside the
    // column, because the overview beside it names the same storylines.
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text(title),
    ));
    // One for the tap, then one per round trip behind the timeline and the
    // member strip.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the header counts what the storyline holds',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    expect(find.textContaining('2 threads · '), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('and follows a thread joining it', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');
    expect(find.textContaining('1 thread · '), findsOneWidget);

    // The strip is read through a cache. What drops it is the list load every
    // one of these actions ends with — without that, the count below stays at
    // one however many threads the storyline actually holds.
    await container
        .read(storylinesProvider.notifier)
        .addThread('sl-1', 'email', 'c2');
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('2 threads · '), findsOneWidget);
    await settleQueues(tester);
  });

  group('the removed threads under the spine', () {
    /// The storyline the user's report was about: two threads filed
    /// automatically, one of them then taken out by a re-check.
    Future<void> seedWithRemoval() async {
      await seedThread('c1', 'Homepage copy');
      await seedThread('c2', 'Launch date');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember(
        'sl-1',
        'email',
        'c1',
        addedBy: 'auto',
        evidence: 'Both are about the redesign.',
      );
      await store.addStorylineMember(
        'sl-1',
        'email',
        'c2',
        addedBy: 'auto',
        evidence: 'Both are about the redesign.',
      );
      await store.removeStorylineMember(
        'sl-1',
        'email',
        'c2',
        block: true,
        blockedBy: 'audit',
        evidence: 'The launch date is a calendar matter.',
      );
    }

    testWidgets("Add back puts a re-check's thread back on the spine",
        (tester) async {
      await seedWithRemoval();

      await openStoryline(tester, 'Website redesign');

      // One thread on the spine and one in the removed list — which is where
      // the user was left after running a re-check over six threads. The
      // removed entry names the bare subject; a CARD carries the source glyph,
      // which is what tells the two apart on screen.
      expect(find.text('REMOVED BY RE-CHECK'), findsOneWidget);
      expect(find.textContaining('1 thread · '), findsOneWidget);
      expect(find.text('Launch date'), findsOneWidget);
      expect(find.text('✉ Launch date'), findsNothing);

      await tester.tap(
        find.byKey(StorylineBlocksSection.addBackKeyFor('email', 'c2')),
      );
      // Two store writes and the two reloads behind them.
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(find.text('REMOVED BY RE-CHECK'), findsNothing);
      expect(find.textContaining('2 threads · '), findsOneWidget);
      // The removed entry is gone and the thread is a card on the spine.
      expect(find.text('Launch date'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(StorylineTimelinePanel),
          matching: find.text('✉ Launch date'),
        ),
        findsOneWidget,
      );
      // And the card says who put it back.
      expect(
        tester
            .widget<Text>(find
                .byKey(StorylineTimelinePanel.evidenceKeyFor('email', 'c2')))
            .data,
        'Filed by you',
      );
      await settleQueues(tester);
    });

    testWidgets('Allow again lifts the block and files nothing back',
        (tester) async {
      await seedWithRemoval();

      await openStoryline(tester, 'Website redesign');

      await tester.tap(
        find.byKey(StorylineBlocksSection.allowAgainKeyFor('email', 'c2')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      // The veto is withdrawn — the entry is gone — but the thread was not
      // filed back, which is the difference the caption above the lists is
      // there to explain.
      expect(find.text('REMOVED BY RE-CHECK'), findsNothing);
      expect(find.textContaining('1 thread · '), findsOneWidget);
      // Neither the entry nor a card: the thread is simply not here.
      expect(find.text('Launch date'), findsNothing);
      expect(find.text('✉ Launch date'), findsNothing);
      expect(await store.blocksOf('sl-1'), isEmpty);
      await settleQueues(tester);
    });

    testWidgets('Re-check reads as running until the worker reports',
        (tester) async {
      await seedWithRemoval();

      await openStoryline(tester, 'Website redesign');
      expect(find.text('Re-check members'), findsOneWidget);

      await tester.tap(
        find.byKey(StorylineBlocksSection.auditButtonKey),
      );
      await tester.pump();
      await tester.pump();

      // A button that still says 'Re-check members' under a pass that is
      // running is a button the user presses twice.
      expect(find.text('Re-checking…'), findsOneWidget);
      expect(find.text('Re-check members'), findsNothing);
      await settleQueues(tester);
    });
  });

  group('the parked charter', () {
    /// A storyline whose charter is the user's, with the sentence the refresh
    /// pass would have written waiting under it.
    Future<void> seedSuggestion() async {
      await seedThread('c1', 'Homepage copy');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.updateStoryline(
        'sl-1',
        charter: 'Threads about the new homepage.',
        charterLocked: true,
        charterSuggestion: 'Threads about the homepage and the press briefing.',
      );
    }

    testWidgets('accepting it from the screen writes the charter through',
        (tester) async {
      await seedSuggestion();
      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('About'));
      await tester.pump();
      await tester.tap(find.text('Use this'));
      await tester.pump();
      await tester.tap(find.text('Replace the charter'));
      await tester.pump();
      await tester.pump();

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(
        storyline.charter,
        'Threads about the homepage and the press briefing.',
      );
      expect(storyline.charterSuggestion, isNull);
      await settleQueues(tester);
    });

    testWidgets('discarding it leaves the charter alone', (tester) async {
      await seedSuggestion();
      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('About'));
      await tester.pump();
      await tester.tap(find.text('Discard'));
      await tester.pump();
      await tester.pump();

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charterSuggestion, isNull);
      expect(storyline.charter, 'Threads about the new homepage.');
      await settleQueues(tester);
    });
  });

  testWidgets('Add thread opens a pane over the storyline, and back returns',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    await tester.tap(find.byTooltip('Add thread'));
    await tester.pump();
    await tester.pump();

    // A pane in the main pane, not a popup over it — that is the whole point
    // of the surface.
    expect(find.byType(AddThreadToStorylinePane), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    // The thread already in the storyline is not on offer.
    expect(find.text('✉ Launch date'), findsOneWidget);
    expect(find.text('✉ Homepage copy'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AddThreadToStorylinePane), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a removed thread is not offered back by Add thread',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    // Removal writes a block in the same transaction as the delete: the user
    // said no to this pairing, and the picker must not ask again.
    await container
        .read(storylinesProvider.notifier)
        .removeThread('sl-1', 'email', 'c2');
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Add thread'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AddThreadToStorylinePane), findsOneWidget);
    // c2 is no longer a member — but it is blocked, so it is not on offer;
    // c1 is still a member, so it is not on offer either.
    expect(find.text('✉ Launch date'), findsNothing);
    expect(find.text('✉ Homepage copy'), findsNothing);
    expect(find.text('No threads to add.'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Add to storyline offers the suggestions too', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'suggested',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

    await pumpInbox(tester);
    // These fixtures carry no sender, so every live thread files into the one
    // 'Just you' room; opening it is how the rail reaches a thread now.
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('People'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text('Just you'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Homepage copy').first);
    await tester.pump();
    await tester.pump();

    // The menu route animates; a settle would never come back over the
    // screen's periodic timer, so the pumps are bounded.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Add to storyline…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Filing a thread into a suggestion is the user answering it. Holding the
    // suggestions back was how a thread removed from one could never go back.
    expect(
      find.descendant(
        of: find.byType(AddToStorylinePane),
        matching: find.text('Website redesign'),
      ),
      findsOneWidget,
    );
    await settleQueues(tester);
  });

  testWidgets('Dismiss on the panel retires a kept storyline', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    // A kept storyline could only be dismissed while it was still a suggestion
    // in the rail. The panel is where a user is when they decide it is done,
    // and retiring one is a correction, so it lives behind the ⋯.
    // A menu is a route, so it needs its opening and closing animations run
    // out. A settle would never come back — the screen owns a periodic timer.
    await tester.tap(find.byKey(RoomHeader.moreKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Dismiss…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Dismiss storyline'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(StorylineTimelinePanel), findsNothing);
    expect((await store.getStoryline('sl-1'))!.status, 'dismissed');
    await settleQueues(tester);
  });

  testWidgets('Open thread on a card opens it, whatever the source filter says',
      (tester) async {
    // One key, two connectors — which is legal, since a conversation key is
    // only unique within the connector that issued it.
    await seedThread('shared-1', 'Homepage copy');
    await seedThread('shared-1', 'Sarah Whitfield', source: 'teams');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'teams', 'shared-1',
        addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    // Mail only, so the chat this storyline holds is not in the list the pane
    // resolves the selection against first.
    await tester.tap(find.byKey(SourceFilterBar.mailKey));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Open thread'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The card knows which connector its key belongs to and says so, which is
    // what stops the key resolving to the mail thread that shares it. An
    // explicit click also outranks the filter — landing on a section overview
    // instead would read as a broken card.
    final panel =
        tester.widget<ThreadDetailPanel>(find.byType(ThreadDetailPanel));
    expect(panel.conversation.source, 'teams');
    expect(panel.conversation.subject, 'Sarah Whitfield');
    await settleQueues(tester);
  });

  testWidgets('the Teams pill hides storylines with no chat in them',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('t1', 'Sarah Whitfield', source: 'teams');
    await store.insertStoryline(
      id: 'sl-mail',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.insertStoryline(
      id: 'sl-chat',
      title: 'Launch chatter',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-mail', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-chat', 'teams', 't1', addedBy: 'auto');

    await pumpInbox(tester, section: RailSection.storylines);
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Website redesign'), findsWidgets);
    expect(find.text('Launch chatter'), findsWidgets);

    await tester.tap(find.byKey(SourceFilterBar.teamsKey));
    await tester.pump();
    await tester.pump();

    // A storyline is not itself mail or chat — the threads in it are, and a
    // storyline holding none from this connector is not a row under the pill.
    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.text('Website redesign'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.text('Launch chatter'),
      ),
      findsOneWidget,
    );
    // And the overview beside it agrees, rather than listing what the rail
    // just hid.
    expect(find.text('Website redesign'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a pill never closes the storyline that is open', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('t1', 'Sarah Whitfield', source: 'teams');
    await store.insertStoryline(
      id: 'sl-mail',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.insertStoryline(
      id: 'sl-chat',
      title: 'Launch chatter',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-mail', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-chat', 'teams', 't1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    await tester.tap(find.byKey(SourceFilterBar.teamsKey));
    await tester.pump();
    await tester.pump();

    // The pill narrows what is browsed, never what is open: an explicit
    // selection outranks it, exactly as an opened thread does.
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StorylineTimelinePanel),
        matching: find.text('Website redesign'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.text('Website redesign'),
      ),
      findsNothing,
    );
    await settleQueues(tester);
  });

  group('the storylines overview', () {
    /// One live storyline with a thread in it, which is all a card needs.
    Future<void> seedCard({String? summary}) async {
      await seedThread('c1', 'Homepage copy');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        summary: summary,
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    }

    /// The overview pane, landed on directly — the rail's own storyline rows
    /// carry titles only, so anything else found on screen is the card.
    Future<void> pumpOverview(
      WidgetTester tester, {
      MailSync? sync,
      TeamsSync? teamsSync,
    }) =>
        pumpInbox(
          tester,
          section: RailSection.storylines,
          sync: sync,
          teamsSync: teamsSync,
        );

    testWidgets('an overview card leads with the recap when there is one',
        (tester) async {
      await seedCard(summary: 'Redesigning the site.');
      await store.updateStoryline(
        'sl-1',
        recapText: 'The copy is signed off and the launch date is the '
            'only thing still open.',
      );

      await pumpOverview(tester);

      expect(
        find.text('The copy is signed off and the launch date is the '
            'only thing still open.'),
        findsOneWidget,
      );
      // The recap REPLACES the summary here, exactly as it does on the
      // storyline's own header — two answers to one question is one too many.
      expect(find.text('Redesigning the site.'), findsNothing);
      expect(find.text('1 threads · 0 open'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('a card with no recap falls back to the summary',
        (tester) async {
      await seedCard(summary: 'Redesigning the site.');

      await pumpOverview(tester);

      expect(find.text('Redesigning the site.'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('the card never grows the lists', (tester) async {
      await seedCard(summary: 'Redesigning the site.');
      await store.updateStoryline(
        'sl-1',
        recapText: 'Copy is signed off.',
        recapOpenJson: jsonEncode(['Pick a launch date']),
        recapDecisionsJson: jsonEncode(['Homepage copy approved']),
        recapThrough: '2026-08-28T09:00:00Z',
      );

      await pumpOverview(tester);

      expect(find.text('Copy is signed off.'), findsOneWidget);
      // A card is a way in, not the screen itself: what is open and what was
      // decided are on the storyline, where there is room to read them.
      // Not even the counted heading the storyline screen folds them to.
      expect(find.textContaining('OPEN'), findsNothing);
      expect(find.textContaining('DECIDED'), findsNothing);
      expect(find.text('Pick a launch date'), findsNothing);
      expect(find.text('Homepage copy approved'), findsNothing);
      expect(find.textContaining('as of'), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('Sync asks the sync service once', (tester) async {
      await seedCard();
      final sync = _FakeSync();

      await pumpOverview(tester, sync: sync, teamsSync: _FakeTeamsSync());
      // The launch sync has already run by here; the button's pull is the
      // next one.
      final before = sync.syncs;

      await tester.tap(find.text('Sync'));
      await tester.pump();

      expect(sync.syncs, before + 1);

      // And the label is its own again once the pull has landed.
      await settleQueues(tester);
      expect(find.text('Sync'), findsOneWidget);
    });

    testWidgets('a second tap while syncing asks nothing', (tester) async {
      await seedCard();
      final sync = _FakeSync();

      await pumpOverview(tester, sync: sync, teamsSync: _FakeTeamsSync());
      final before = sync.syncs;

      // Held open, so the second tap lands while the first pull is genuinely
      // still in flight.
      final gate = Completer<void>();
      sync.gate = gate;

      await tester.tap(find.text('Sync'));
      await tester.pump();

      expect(find.text('Syncing…'), findsOneWidget);
      expect(find.text('Sync'), findsNothing);

      await tester.tap(find.text('Syncing…'));
      await tester.pump();
      expect(sync.syncs, before + 1);

      gate.complete();
      await settleQueues(tester);
      expect(find.text('Sync'), findsOneWidget);
    });

    testWidgets('the storyline screen syncs too', (tester) async {
      await seedCard();
      final sync = _FakeSync();

      // Not the overview: opening a card leaves that pane behind, and the
      // button found here is the storyline header's own.
      await openStoryline(
        tester,
        'Website redesign',
        sync: sync,
        teamsSync: _FakeTeamsSync(),
      );
      final before = sync.syncs;

      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Sync'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(sync.syncs, before + 1);

      await settleQueues(tester);
      // And the item is offering the pull again rather than stuck on
      // 'Syncing…'.
      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Sync'), findsOneWidget);
    });
  });
}
