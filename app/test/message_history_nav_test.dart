import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/message_history_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/storyline_pickers.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// "What happened" as a SIDE PANEL: the door in from the home table, and the
/// ways out.
///
/// Navigation here is a bag of booleans rather than a route stack, so every
/// one of these is a wiring touch on `_InboxScreenState` that none of the
/// screen's own tests can see — that the history is a [HistoryPanel] beside
/// the main pane and not a rung of it, that opening it leaves the table
/// underneath alone, that the storyline picker it opens draws in MAIN while
/// the story stays beside, and that every selector closes it.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _FakeTeamsSync implements TeamsSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<String?> get lastSyncedAt async => null;
}

/// The row's history target. Built through the tile's own key function rather
/// than spelled out here, so a change to how a row is keyed breaks the widget
/// tests rather than silently missing this one.
final Finder _historyBar = find.byKey(HomeFeedRowTile.historyBarKey(
  const HomeFeedRow(
    source: 'email',
    sourceMessageId: 'm1',
    conversationKey: 'c1',
    receivedAt: '',
    triageState: 'pending',
    extractState: 'pending',
    storylineState: 'pending',
    draftState: 'pending',
    settleState: 'pending',
    outcome: 'pending',
    dropped: false,
  ),
));

/// The story, inside the side panel's chrome and nowhere else.
final Finder _historyBeside = find.descendant(
  of: find.byType(SidePanelHost),
  matching: find.byType(MessageHistoryScreen),
);

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seed() async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Renewal paperwork',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'Could you look at the DPA before Friday?',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c1',
      'subject': 'Renewal paperwork',
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    // Icon rail 56 + list column 260 + a main pane wide enough that the panel
    // opens BESIDE it rather than replacing it.
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.home),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
        // A worker with no handlers: the real one would dial a model server
        // this test has no business reaching.
        aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
        // Unstarted: no sweep timer under the test.
        notificationCoordinatorProvider
            .overrideWithValue(NotificationCoordinator(store)),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Future<void> openHistory(WidgetTester tester) async {
    await tester.tap(_historyBar);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets("a row's stage bar opens what happened to it, beside the table",
      (tester) async {
    await seed();
    await pumpInbox(tester);
    expect(find.byType(HomePane), findsOneWidget);
    expect(find.byType(MessageHistoryScreen), findsNothing);

    await openHistory(tester);

    expect(_historyBeside, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.text('What happened'),
      ),
      findsOneWidget,
    );
    // The table the question was asked from is still in the main pane.
    expect(find.byType(HomePane), findsOneWidget);
    // Prose about one message: no ⤢, the Why panel's rule.
    expect(find.byKey(SidePanelHost.expandKey), findsNothing);
  });

  testWidgets('✕ closes the panel and the table underneath is untouched',
      (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
  });

  testWidgets('Open thread closes the panel and opens the thread in main',
      (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    await tester.scrollUntilVisible(
      find.byKey(MessageHistoryScreen.openThreadKey),
      200,
      scrollable: find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(MessageHistoryScreen.openThreadKey));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
  });

  testWidgets(
      'Add to storyline… draws the picker in main while the story stays '
      'beside, and Back returns to the table', (tester) async {
    // The picker is a rung of the main pane and the history is not, which is
    // the whole reason the picker's Back has somewhere to go: the story was
    // never cleared, so it is still there when the picker leaves.
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    // The story is a lazy list and the panel is narrower than the pane the
    // full-width host drew, so the levers are below the fold.
    await tester.scrollUntilVisible(
      find.byKey(MessageHistoryScreen.addToStorylineKey),
      200,
      scrollable: find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(MessageHistoryScreen.addToStorylineKey));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(AddToStorylinePane), findsOneWidget);
    expect(_historyBeside, findsOneWidget);
    expect(find.byType(HomePane), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(AddToStorylinePane), findsNothing);
    expect(_historyBeside, findsOneWidget);
    expect(find.byType(HomePane), findsOneWidget);
  });

  testWidgets('moving to another stop closes it', (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);
    expect(_historyBeside, findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.byTooltip('Needs You'),
    ));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(HomePane), findsNothing);
  });
}
