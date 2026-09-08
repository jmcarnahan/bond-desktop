import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/message_history_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// "What happened" as a PANE: the door in from the home table, and the three
/// ways out.
///
/// Navigation here is a bag of booleans rather than a route stack, so every
/// one of these is a wiring touch on `_InboxScreenState` that none of the
/// screen's own tests can see — the rung [_main] puts it on, the selectors
/// that clear it, and the one thing that makes this pane different from
/// Settings: opening it does not clear the selection underneath, so Back lands
/// back where the question was asked.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
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
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.home),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // A worker with no handlers: the real one would dial a model server
        // this test has no business reaching.
        aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
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

  testWidgets("a row's stage bar opens what happened to it", (tester) async {
    await seed();
    await pumpInbox(tester);
    expect(find.byType(HomePane), findsOneWidget);
    expect(find.byType(MessageHistoryScreen), findsNothing);

    await openHistory(tester);

    expect(find.byType(MessageHistoryScreen), findsOneWidget);
    expect(find.text('What happened'), findsOneWidget);
  });

  testWidgets('Back leaves the pane and lands on what was underneath',
      (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    await tester.tap(find.byTooltip('Back'));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(find.byType(MessageHistoryScreen), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
  });

  testWidgets('Open thread closes the pane and opens the thread',
      (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    await tester.tap(find.byKey(MessageHistoryScreen.openThreadKey));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(MessageHistoryScreen), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
  });

  testWidgets('the Home link lands on Home', (tester) async {
    await seed();
    await pumpInbox(tester);
    await openHistory(tester);

    await tester.tap(find.byTooltip('Home'));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(find.byType(MessageHistoryScreen), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
  });
}
