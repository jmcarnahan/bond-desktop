// `show BondDatabase`: drift generates row classes named Message/Conversation/
// Storyline from the tables, and this file means the app's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Home as the SCREEN assembles it: the pane the app opens on, and the two
/// places a row leads.
///
/// This file deliberately does NOT override [initialSectionProvider]. Every
/// other screen test does, which is what makes this one the pin on the landing
/// pane: if the default moved, only this file would notice.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
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
    String from = 'Sarah Chen',
    String receivedAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': from,
      'received_at': receivedAt,
      'body_text': 'body',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      // Unstarted, so it owns no sweep timer — this file's container is
      // disposed in a tearDown, which runs after flutter_test has already
      // checked for leaked timers.
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back. One per
    // round trip the feed, the tiles and the strip each make.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Asks the way a notification click does.
  Future<void> request(WidgetTester tester, NavIntent intent) async {
    container.read(navIntentProvider.notifier).request(intent);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Runs out every window the queues arm behind them, so a test does not end
  /// with one pending: the reload debounce the triage and AI queues report on,
  /// and — because their stage writes tick the feed — the feed's own tick
  /// window and the metrics epoch that follows it.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  testWidgets('the app opens on Home, with the stop on the rail',
      (tester) async {
    await seedThread('c1', 'Homepage copy');

    await pumpInbox(tester);

    expect(find.byType(HomePane), findsOneWidget);
    expect(find.text('HOME'), findsOneWidget);
    // The feed read the stored row rather than waiting on a sync.
    expect(
      find.descendant(
        of: find.byType(HomePane),
        matching: find.text('Homepage copy'),
      ),
      findsOneWidget,
    );
    await settleQueues(tester);
  });

  testWidgets('a feed row opens its thread', (tester) async {
    await seedThread('c1', 'Homepage copy');

    await pumpInbox(tester);
    await tester.tap(find.descendant(
      of: find.byType(HomePane),
      matching: find.text('Homepage copy'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    expect(find.byType(HomePane), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a row’s storyline name opens the timeline', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    // What the assign handler writes: the row remembers where it was filed.
    await store.writeStorylineProgress(
      'email',
      'c1',
      state: 'done',
      storylineId: 'sl-1',
    );

    await pumpInbox(tester);
    await tester.tap(find.descendant(
      of: find.byType(HomePane),
      matching: find.text('Website redesign'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    expect(
      find.byType(ThreadDetailPanel),
      findsNothing,
      reason: 'the name is its own target inside the row',
    );
    await settleQueues(tester);
  });

  testWidgets('the rail stop comes back to Home from a thread',
      (tester) async {
    await seedThread('c1', 'Homepage copy');

    await pumpInbox(tester);
    await tester.tap(find.descendant(
      of: find.byType(HomePane),
      matching: find.text('Homepage copy'),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(HomePane), findsNothing);

    await tester.tap(find.text('HOME'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(HomePane), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a message the gate drops arrives, is read, and goes',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);

    // The pair a sync makes: the store writes the row, the recorder says so.
    // Read out of the screen's own container, because the bus the feed is
    // listening on is the one that container built.
    final ingested = await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'n1',
      'conversation_key': 'c-n1',
      'direction': 'inbound',
      'subject': 'Weekly roundup',
      'from_name': 'A Newsletter',
      'received_at': '2026-09-03T09:00:00Z',
      'triage_status': 'skipped',
      'gate_reason': 'newsletter',
    });
    container.read(pipelineProgressProvider).noteIngest(
          'email',
          'n1',
          receivedAt: ingested!,
        );

    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(HomePane),
        matching: find.text('Weekly roundup'),
      ),
      findsOneWidget,
      reason: 'the one glimpse a reader gets of what the gate threw out',
    );
    expect(find.text('Newsletter'), findsOneWidget);

    await tester.pump(HomeFeedNotifier.entryClear);
    await tester.pump(homeDropLinger);
    await tester.pump(homeDropCollapse);
    await tester.pump();

    expect(find.text('Weekly roundup'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(HomePane),
        matching: find.text('Homepage copy'),
      ),
      findsOneWidget,
      reason: 'the row that left took nothing with it',
    );
    await settleQueues(tester);
  });

  testWidgets('an OpenSectionIntent for Home lands on it', (tester) async {
    await seedThread('c1', 'Homepage copy');

    await pumpInbox(tester);
    await tester.tap(find.text('CONVERSATIONS'));
    await tester.pump();
    expect(find.byType(HomePane), findsNothing);

    await request(tester, OpenSectionIntent(RailSection.home));

    expect(find.byType(HomePane), findsOneWidget);
    await settleQueues(tester);
  });
}
