import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/screens/message_history_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/message_history_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The story's HOST: the one place the history provider is read, and every
/// lever wired to the service behind it.
///
/// Split out of the inbox screen so a second host — a side panel — seats the
/// same story without a second copy of this wiring. What these tests pin is
/// the half the screen's own tests cannot see: that the providers are really
/// read, that a lever the host owns is handed the pair it acts on, and that
/// `chrome: false` drops the pane's title bar and nothing else.

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

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seed({String id = 'm1', String conversationKey = 'c1'}) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': 'Renewal paperwork',
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'Could you look at the DPA before Friday?',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': conversationKey,
      'subject': 'Renewal paperwork',
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
  }

  ProviderContainer container() {
    final made = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      // A worker with no handlers: the real one would dial a model server
      // this test has no business reaching.
      aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
      // Unstarted, so it owns no sweep timer — the container is disposed in a
      // tearDown, which runs after flutter_test has already checked for
      // leaked timers.
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
    ]);
    addTearDown(made.dispose);
    return made;
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    bool chrome = true,
    VoidCallback? onBack,
    void Function(String source, String threadKey)? onAddToStoryline,
    Future<void> Function(String source, String threadKey)? onKeepInInbox,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container(),
      child: MaterialApp(
        home: Scaffold(
          body: MessageHistoryHost(
            target: (source: 'email', id: 'm1'),
            chrome: chrome,
            onBack: onBack ?? () {},
            onHome: () {},
            onOpenThread: (_, _) {},
            onOpenStoryline: (_) {},
            onAddToStoryline: onAddToStoryline,
            onKeepInInbox: onKeepInInbox,
          ),
        ),
      ),
    ));
    // Bounded pumps rather than a settle: the notifier's debounce is a timer
    // and an unbounded settle would wait on it forever.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets('the host reads the story and seats it under the pane title',
      (tester) async {
    await seed();
    await pumpHost(tester);

    expect(find.text('What happened'), findsOneWidget);
    expect(find.text('Renewal paperwork'), findsOneWidget);
  });

  testWidgets('chrome: false keeps the sections and drops the title bar',
      (tester) async {
    await seed();
    await pumpHost(tester, chrome: false);

    // The header a side panel draws for itself would otherwise be drawn
    // twice, which is the whole reason the flag exists.
    expect(find.text('What happened'), findsNothing);
    expect(find.text('Renewal paperwork'), findsOneWidget);
  });

  testWidgets('Back is the host\'s, not the pane\'s', (tester) async {
    await seed();
    var backs = 0;
    await pumpHost(tester, onBack: () => backs++);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();

    expect(backs, 1);
  });

  testWidgets('Ignore, confirmed, drops the row through the repair service',
      (tester) async {
    await seed();
    await pumpHost(tester);

    expect((await store.getProgressRow('email', 'm1'))!['dropped'], 0);

    // Two taps: the first arms the question, the second answers it. The
    // pane's own two-step, exercised here because the write behind it is the
    // host's wiring.
    await tester.tap(find.byKey(MessageHistoryScreen.ignoreKey));
    await tester.pump();
    await tester.tap(find.byKey(MessageHistoryScreen.ignoreKey));
    // Past the notifier's tick debounce as well as the write: the drop
    // publishes, and a test that left that timer armed would fail on the
    // leak rather than on the assertion below.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect((await store.getProgressRow('email', 'm1'))!['dropped'], 1);
  });

  testWidgets('Add to storyline hands the host the thread it acts on',
      (tester) async {
    await seed();
    (String, String)? picked;
    await pumpHost(
      tester,
      onAddToStoryline: (source, threadKey) => picked = (source, threadKey),
    );

    await tester.tap(find.byKey(MessageHistoryScreen.addToStorylineKey));
    await tester.pump();

    // The THREAD's key, not the message id: the picker files a thread.
    expect(picked, ('email', 'c1'));
  });

  testWidgets('Keep in inbox hands the host the thread, on a Later row',
      (tester) async {
    await seed();
    await store.setConversationBucket(
      'email',
      'c1',
      bucket: 'later',
      reason: 'a newsletter you read on Sundays',
    );
    (String, String)? kept;
    await pumpHost(
      tester,
      onKeepInInbox: (source, threadKey) async => kept = (source, threadKey),
    );

    await tester.tap(find.byKey(MessageHistoryScreen.keepKey));
    await tester.pump();

    expect(kept, ('email', 'c1'));
  });

  testWidgets('a lever the host did not wire is not drawn', (tester) async {
    await seed();
    await store.setConversationBucket(
      'email',
      'c1',
      bucket: 'later',
      reason: 'a newsletter you read on Sundays',
    );
    await pumpHost(tester);

    // Null means the host cannot do it, and a button that does nothing is
    // worse than no button.
    expect(find.byKey(MessageHistoryScreen.addToStorylineKey), findsNothing);
    expect(find.byKey(MessageHistoryScreen.keepKey), findsNothing);
  });
}
