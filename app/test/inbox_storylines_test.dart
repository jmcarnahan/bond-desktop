import 'dart:async';
import 'dart:convert';

// `show`: drift generates row classes named Message/Conversation/Storyline
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show TriageResult;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/storylines_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/quick_replies.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:bond_inbox/widgets/storyline_pickers.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The member strip on an open storyline, as the SCREEN assembles it.
///
/// `storyline_timeline_test.dart` pins what the panel does with a member list
/// it is handed. This file pins where that list comes from, which stopped being
/// a read the build could make for itself when the store went asynchronous: it
/// is a cached provider now, and a cache that nothing dropped would leave the
/// strip showing the membership from before the user's last action.

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

  /// The reply pills by label, and which one is filled. The source filter bar
  /// is made of the same pill, so this reads them by name rather than counting
  /// what is on screen.
  Map<String, bool> replyPills(WidgetTester tester) => {
        for (final pill
            in tester.widgetList<BondFilterPill>(find.byType(BondFilterPill)))
          pill.label: pill.selected,
      };

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

    // The rail's storylines section is expanded by default, so the row is
    // already on screen.
    await tester.tap(find.text(title));
    // One for the tap, then one per round trip behind the timeline and the
    // member strip.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the member strip counts what the storyline holds',
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

    expect(find.text('2 threads'), findsOneWidget);
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
    expect(find.text('1 thread'), findsOneWidget);

    // The strip is read through a cache. What drops it is the list load every
    // one of these actions ends with — without that, the count below stays at
    // one however many threads the storyline actually holds.
    await container
        .read(storylinesProvider.notifier)
        .addThread('sl-1', 'email', 'c2');
    await tester.pump();
    await tester.pump();

    expect(find.text('2 threads'), findsOneWidget);
    await settleQueues(tester);
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

    await tester.tap(find.text('Add thread'));
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

    await tester.tap(find.text('Add thread'));
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
    // in the rail. The panel is where a user is when they decide it is done.
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
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

  group('the storyline reply window', () {
    Future<void> seedTwoThreadStoryline() async {
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
    }

    testWidgets('is shut until the user says they are writing', (tester) async {
      await seedTwoThreadStoryline();
      await openStoryline(tester, 'Website redesign');

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Reply to'), findsNothing);
      expect(find.text('Reply…'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('opens onto the pills and the box', (tester) async {
      await seedTwoThreadStoryline();
      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('Reply…'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Reply to'), findsOneWidget);
      expect(find.text('Write a reply…'), findsOneWidget);
      final pills = replyPills(tester);
      expect(pills.containsKey('Homepage copy'), isTrue);
      expect(pills.containsKey('Launch date'), isTrue);
      await settleQueues(tester);
    });

    testWidgets('and the close shuts it again', (tester) async {
      await seedTwoThreadStoryline();
      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('Reply…'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Reply to'), findsNothing);
      expect(find.text('Reply…'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('a pill moves the box to that thread', (tester) async {
      await seedTwoThreadStoryline();
      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('Reply…'));
      await tester.pump();
      await tester.pump();

      // Which member thread answers by default is the newest one's business,
      // not this test's: whichever is not filled is the one to tap.
      final before = replyPills(tester);
      final wasOn =
          before['Homepage copy'] == true ? 'Homepage copy' : 'Launch date';
      final other =
          wasOn == 'Homepage copy' ? 'Launch date' : 'Homepage copy';
      expect(before[wasOn], isTrue);

      // By the pill and not by its text: the list pane names the same thread.
      await tester.tap(
        find.byWidgetPredicate((w) => w is BondFilterPill && w.label == other),
      );
      await tester.pump();
      await tester.pump();

      final after = replyPills(tester);
      expect(after[other], isTrue);
      expect(after[wasOn], isFalse);
      await settleQueues(tester);
    });

    testWidgets('two members sharing a key are two pills, one per connector',
        (tester) async {
      // The same conversation key on both sides, which is legal: keys are
      // unique within the connector that issued them and nowhere else. Keyed
      // on the bare key the picker held ONE of these and silently dropped the
      // other, so replying to the chat would have answered the mail thread.
      await seedThread('shared-1', 'Homepage copy');
      await seedThread('shared-1', 'Sarah Whitfield',
          source: 'teams', receivedAt: '2026-08-28T10:00:00Z');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'shared-1',
          addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'teams', 'shared-1',
          addedBy: 'auto');

      await openStoryline(tester, 'Website redesign');

      await tester.tap(find.text('Reply…'));
      await tester.pump();
      await tester.pump();

      final pills = replyPills(tester);
      expect(pills.containsKey('Homepage copy'), isTrue);
      expect(pills.containsKey('Sarah Whitfield'), isTrue);
      // The chat is the newer of the two, so it is the default pick — and the
      // pane routes it down the chat path, which this build cannot send on.
      expect(pills['Sarah Whitfield'], isTrue);
      expect(pills['Homepage copy'], isFalse);
      expect(find.text('Reply in Microsoft Teams'), findsOneWidget);
      expect(find.text('Write a reply…'), findsNothing);

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is BondFilterPill && w.label == 'Homepage copy',
        ),
      );
      await tester.pump();
      await tester.pump();

      // Same key, other connector: the box is the mail one now.
      expect(replyPills(tester)['Homepage copy'], isTrue);
      expect(find.text('Write a reply…'), findsOneWidget);
      expect(find.text('Reply in Microsoft Teams'), findsNothing);
      await settleQueues(tester);
    });
  });

  group('a storyline is answerable from its episodes', () {
    /// The same two threads, an hour apart, so which card opens on its own is
    /// the spine's rule rather than a tie the database broke: the newest
    /// episode is the open one, and here that is Launch date.
    Future<void> seedTimedStoryline({String c1State = 'waiting'}) async {
      await seedThread('c1', 'Homepage copy', state: c1State);
      await seedThread('c2', 'Launch date', receivedAt: '2026-08-28T10:00:00Z');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');
    }

    /// One suggestion on [key], in the shape the draft handler writes.
    Future<void> seedSuggestion(String key, String stance, String body) =>
        store.upsertDraft(
          source: 'email',
          conversationKey: key,
          replyToMessageId: '$key-m1',
          body: body,
          optionsJson: '[{"stance":"$stance","body":"$body"}]',
        );

    /// Marks [key]'s only message as still waiting on an answer.
    Future<void> seedAsk(String key, String ask) => store.writeTriage(
          'email',
          '$key-m1',
          status: 'done',
          result: TriageResult(
            urgency: 'normal',
            category: 'other',
            summary: key,
            needsAction: true,
            actionItems: [ask],
            replyExpected: true,
          ),
        );

    testWidgets('the suggestions sit on the episode they answer',
        (tester) async {
      await seedTimedStoryline();
      await seedSuggestion('c2', 'Confirm Friday', 'Friday works for me.');

      await openStoryline(tester, 'Website redesign');
      // The draft is a round trip of its own, behind the timeline's.
      await tester.pump();
      await tester.pump();

      // Inside the spine, on the open card — not parked under the pane.
      expect(
        find.descendant(
          of: find.byType(StorylineTimelinePanel),
          matching: find.byType(QuickReplyBar),
        ),
        findsOneWidget,
      );
      expect(find.text('Friday works for me.'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('and a card without one shows nothing at all', (tester) async {
      await seedTimedStoryline();

      await openStoryline(tester, 'Website redesign');
      await tester.pump();
      await tester.pump();

      // The pane's own Reply… owns the empty state; a bare button per card
      // would say nothing about any of them.
      expect(find.byType(QuickReplyBar), findsNothing);
      expect(find.text('Reply…'), findsOneWidget);
      expect(find.text('Suggest a reply'), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('a card whose suggestions were closed offers them back',
        (tester) async {
      await seedTimedStoryline();
      await seedSuggestion('c2', 'Confirm Friday', 'Friday works for me.');
      // What the × writes once the user has confirmed it: the draft survives,
      // its cards do not.
      await store.dismissDraftOptions('email', 'c2-m1');

      await openStoryline(tester, 'Website redesign');
      await tester.pump();
      await tester.pump();

      // The cards are gone, and the way back to them is on the card they were
      // on — a dismissal nothing could undo is the reason this exists.
      expect(find.byType(QuickReplyBar), findsNothing);
      expect(find.text('Friday works for me.'), findsNothing);
      expect(find.text('Suggest a reply'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('tapping a suggestion opens the reply on that thread',
        (tester) async {
      await seedTimedStoryline();
      await seedSuggestion('c2', 'Confirm Friday', 'Friday works for me.');

      await openStoryline(tester, 'Website redesign');
      await tester.pump();
      await tester.pump();

      // Mail bottoms out at the clipboard, so a tap prefills rather than
      // sends: what it owes the user is the box, open, on this thread.
      await tester.tap(find.text('Friday works for me.'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Reply to'), findsOneWidget);
      expect(replyPills(tester)['Launch date'], isTrue);
      await settleQueues(tester);
    });

    testWidgets('an ask on an older episode opens the reply on ITS thread',
        (tester) async {
      // The ask line only renders while the thread still wants the user, so
      // the older episode is seeded as one that does.
      await seedTimedStoryline(c1State: 'needs_reply');
      await seedAsk('c1', 'Send the deck');

      await openStoryline(tester, 'Website redesign');
      await tester.pump();

      // The older card is shut by default; its header opens it.
      await tester.tap(find.text('✉ Homepage copy'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Send the deck'));
      await tester.pump();
      await tester.pump();

      // Not the newest thread, which is what the box would answer if the tap
      // had only opened it.
      expect(find.text('Reply to'), findsOneWidget);
      final pills = replyPills(tester);
      expect(pills['Homepage copy'], isTrue);
      expect(pills['Launch date'], isFalse);
      await settleQueues(tester);
    });
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

      await tester.tap(find.text('Sync'));
      await tester.pump();

      expect(sync.syncs, before + 1);

      await settleQueues(tester);
      expect(find.text('Sync'), findsOneWidget);
    });
  });
}
