import 'dart:async';

// `show`: drift generates row classes named Message/Conversation/Storyline
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/desktop_notifier.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/notification_ribbon.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/later_digest.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Navigation asked for from outside the widget tree.
///
/// There is no router here: every selection the app makes is a `setState`
/// inside `InboxScreen`, reachable only from the widgets it built. A
/// notification is the first thing that has to navigate without being one of
/// those widgets, and this file pins the seam it goes through — including the
/// rule that makes it safe, that an intent always carries the SOURCE and never
/// a bare conversation key.

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

  /// The settle seam, driven by hand. Overriding the STREAM rather than the
  /// coordinator is what lets this file put a settle on screen: the
  /// coordinator emits from a private controller, and every surface reads this
  /// provider instead of it.
  late StreamController<MessageSettled> settles;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    settles = StreamController<MessageSettled>.broadcast();
  });

  tearDown(() async {
    await settles.close();
    await db.close();
  });

  Future<void> seedThread(
    String key,
    String subject, {
    String source = 'email',
    String state = 'waiting',
    int isRead = 1,
    String lastMessageAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$source-$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'is_read': isRead,
      'received_at': lastMessageAt,
      'body_text': 'body of $subject',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': state,
      'last_message_at': lastMessageAt,
    });
    await store.recomputeConversationCounts(source, key);
  }

  /// Runs out the 400ms reload debounce the triage and AI queues arm when they
  /// report, AND the OS dispatcher's coalesce window, which a settle arms.
  /// Neither may be left pending when a test ends.
  Future<void> settleQueues(WidgetTester tester) =>
      tester.pump(DesktopNotificationService.defaultCoalesceWindow +
          const Duration(milliseconds: 500));

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // Predates Home: this file asserts on a pane the rail's old landing
      // section opened.
      initialSectionProvider.overrideWithValue(RailSection.needsYou),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      // Unstarted, so it owns no sweep timer — this file's container is
      // disposed in a tearDown, which runs after flutter_test has already
      // checked for leaked timers. The ribbon's own notifier hangs off this
      // coordinator's stream and stays timer-free while nothing settles.
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
      settledEventsProvider.overrideWithValue(settles.stream),
      // The OS dispatcher reads the same stream this file drives by hand, so
      // every settle below would otherwise reach a real notification centre
      // over a method channel. It gets the seam's unsupported implementation
      // instead — this file is about where a click LANDS, not about toasts.
      desktopNotifierProvider.overrideWithValue(const NoopDesktopNotifier()),
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

  /// Asks for [intent] the way a ribbon click does, then lets the screen act
  /// on it and clear it.
  Future<void> request(WidgetTester tester, NavIntent intent) async {
    container.read(navIntentProvider.notifier).request(intent);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an intent carrying the source opens THAT connector’s thread',
      (tester) async {
    // The same conversation key on both sides, which is the case a bare id
    // cannot survive: keys are unique within a connector, not across them.
    await seedThread('shared', 'Homepage copy');
    await seedThread('shared', 'Sarah Whitfield', source: 'teams');
    await pumpScreen(tester);

    await request(tester, OpenThreadIntent('teams', 'shared'));

    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    // The pane is titled by the conversation it resolved, so the subject is
    // what says which of the two threads opened.
    expect(
      find.descendant(
        of: find.byType(ThreadDetailPanel),
        matching: find.text('Sarah Whitfield'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ThreadDetailPanel),
        matching: find.text('Homepage copy'),
      ),
      findsNothing,
    );
    // And the transcript under that title is the chat's alone. The pane used
    // to read both connectors' messages for the key and interleave them; the
    // thread is keyed by (source, key) now, and these two lines are what pins
    // it — a regression would put the mail body under the chat's heading.
    expect(
      find.descendant(
        of: find.byType(ThreadDetailPanel),
        matching: find.textContaining('body of Sarah Whitfield'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ThreadDetailPanel),
        matching: find.textContaining('body of Homepage copy'),
      ),
      findsNothing,
    );

    await settleQueues(tester);
  });

  testWidgets('the intent is cleared once the screen has acted on it',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpScreen(tester);

    await request(tester, OpenThreadIntent('email', 'c1'));

    // Cleared in a post-frame callback, so a rebuild cannot replay it.
    expect(container.read(navIntentProvider), isNull);

    await settleQueues(tester);
  });

  testWidgets('opening a thread this way marks it read', (tester) async {
    // Pins the recorded decision: a notification click is as explicit as a
    // rail click, and opening a thread IS reading it. `_select` is untouched.
    await seedThread('c1', 'Homepage copy', isRead: 0);
    await pumpScreen(tester);

    expect(await unreadOf(db, 'email', 'c1'), 1);

    await request(tester, OpenThreadIntent('email', 'c1'));
    await tester.pump();

    expect(await unreadOf(db, 'email', 'c1'), 0);

    await settleQueues(tester);
  });

  testWidgets('a storyline intent opens the storyline', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await pumpScreen(tester);

    await request(tester, OpenStorylineIntent('sl-1'));

    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsNothing);

    await settleQueues(tester);
  });

  testWidgets('a section intent lands on that section', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpScreen(tester);

    await request(tester, OpenSectionIntent(RailSection.later));

    expect(find.byType(LaterDigestPanel), findsOneWidget);

    await settleQueues(tester);
  });

  testWidgets('the same intent twice navigates twice', (tester) async {
    // No `==` on the intents, deliberately: a StateNotifier only notifies on a
    // changed state, so an equal second request would be silently dropped.
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await pumpScreen(tester);

    await request(tester, OpenThreadIntent('email', 'c1'));
    await request(tester, OpenSectionIntent(RailSection.later));
    await request(tester, OpenThreadIntent('email', 'c1'));

    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    expect(find.byType(LaterDigestPanel), findsNothing);

    await settleQueues(tester);
  });

  group('the ribbon over the inbox', () {
    MessageSettled settled({
      String source = 'email',
      String key = 'c1',
      String? title = 'Homepage copy',
    }) =>
        MessageSettled(
          source: source,
          sourceMessageId: '$source-$key-m1',
          conversationKey: key,
          settledAt: '2026-09-02T10:00:00Z',
          title: title,
        );

    /// Runs out the ribbon's real dwell AND its ceiling, so no test ends with
    /// one of them pending.
    Future<void> dwellOut(WidgetTester tester) =>
        tester.pump(const Duration(seconds: 21));

    /// Whether the ribbon is actually being shown. It stays MOUNTED once it
    /// has said anything — that is what lets it animate out — so its presence
    /// in the tree is not the answer and the fade is.
    bool shown(WidgetTester tester) {
      final fade = find
          .ancestor(
            of: find.byType(NotificationRibbon),
            matching: find.byType(AnimatedOpacity),
          )
          .first;
      return tester.widget<AnimatedOpacity>(fade).opacity == 1;
    }

    testWidgets('a settle raises it, and clicking it opens the thread',
        (tester) async {
      await seedThread('c1', 'Homepage copy');
      await pumpScreen(tester);

      expect(find.byType(NotificationRibbon), findsNothing,
          reason: 'nothing has settled — the ribbon does not exist yet');

      settles.add(settled());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(NotificationRibbon), findsOneWidget);
      expect(find.text('Homepage copy'), findsWidgets);

      await tester.tap(find.byType(NotificationRibbon));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(ThreadDetailPanel), findsOneWidget);
      expect(container.read(navIntentProvider), isNull);
      await settleQueues(tester);
    });

    testWidgets('the close button takes it away without navigating anywhere',
        (tester) async {
      await seedThread('c1', 'Homepage copy');
      await pumpScreen(tester);

      settles.add(settled());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.descendant(
        of: find.byType(NotificationRibbon),
        matching: find.byIcon(Icons.close),
      ));
      // Long enough for the exit animation, short of the dwell.
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ThreadDetailPanel), findsNothing);
      expect(container.read(navIntentProvider), isNull);
      // The child stays mounted to animate out, so what says it is gone is the
      // fade rather than the tree.
      expect(shown(tester), isFalse);
      await settleQueues(tester);
    });

    testWidgets('the thread already on screen is not announced',
        (tester) async {
      // Telling someone about the message they are reading is telling them
      // what is on their screen.
      await seedThread('c1', 'Homepage copy');
      await pumpScreen(tester);

      await request(tester, OpenThreadIntent('email', 'c1'));
      expect(find.byType(ThreadDetailPanel), findsOneWidget);

      settles.add(settled());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(shown(tester), isFalse,
          reason: 'raised for a thread the user is already reading');

      // A different thread in the same batch and there is somewhere to go.
      settles.add(settled(key: 'c2', title: 'Launch date'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(shown(tester), isTrue);
      expect(find.text('2 messages need you'), findsOneWidget);

      await dwellOut(tester);
      await settleQueues(tester);
    });

    testWidgets('with the preference off, nothing is announced',
        (tester) async {
      await seedThread('c1', 'Homepage copy');
      await store.setPref(notifyStyleKey, 'off');
      await pumpScreen(tester);

      settles.add(settled());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(NotificationRibbon), findsNothing);
      await settleQueues(tester);
    });
  });
}

/// How many unread inbound messages the thread still holds, read straight from
/// the database rather than from anything on screen.
Future<int> unreadOf(BondDatabase db, String source, String key) async {
  final rows = await db.customSelect('SELECT * FROM messages').get();
  return rows
      .where((row) =>
          row.data['source'] == source &&
          row.data['conversation_key'] == key &&
          row.data['direction'] == 'inbound' &&
          row.data['is_read'] == 0)
      .length;
}
