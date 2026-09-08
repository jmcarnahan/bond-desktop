// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
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
import 'package:bond_inbox/widgets/hover_actions.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:bond_inbox/widgets/why_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Why panel, as the screen opens it.
///
/// What this file pins is the seam rather than the wording — `why_panel_test`
/// owns the sentences. Which gestures open it, which pane it lands in, and
/// that opening it from a thread that is ITSELF beside replaces that thread
/// rather than stacking a second panel behind it.

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
    String body = 'The hero paragraph.',
    String receivedAt = '2026-08-28T09:00:00Z',
    String cta = 'Send the survey back',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.test',
      'received_at': receivedAt,
      'body_text': body,
    });
    await store.writeNeedsYouVerdict(
      'email',
      '$key-m1',
      verdict: true,
      reason: 'She asked you to confirm the closing date.',
    );
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.test"}]',
      'state': 'needs_reply',
      'cta_text': cta,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    await store.recomputeConversationCounts('email', key);
  }

  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // The scoring pass lands a few pumps in, so a row asserted on before then
    // must not be gated on a score it does not have yet.
    await store.setPref(attentionThresholdKey, '0');
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
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  /// Opens a thread in the MAIN pane from the rail.
  ///
  /// A Needs You row is titled by its ASK, not by its subject, and it carries a
  /// dimmed `· who` suffix — which makes it a `Text.rich`, so a plain
  /// `find.text` would miss it.
  Future<void> openThread(WidgetTester tester, String ask) async {
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.textContaining(ask),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Puts a MOUSE over one transcript row. Touch never enters a `MouseRegion`.
  Future<void> hover(WidgetTester tester, Finder row) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(row));
    await tester.pump();
  }

  Finder whyPanel() => find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(WhyPanelBody),
      );

  testWidgets('hovering a message offers Why, and it opens beside',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');

    await hover(tester, find.byKey(const ValueKey('c1-m1')));
    await tester.tap(find.byKey(HoverActions.whyKeyFor('c1-m1')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(whyPanel(), findsOneWidget);
    expect(find.text('Needs you'), findsOneWidget);
    expect(
      find.text('She asked you to confirm the closing date.'),
      findsOneWidget,
    );
    // The thread the reader was on is still in the main pane.
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the CTA banner opens it too', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');

    // Scoped: the rail row that opened the thread wears the same ask.
    await tester.tap(find.descendant(
      of: find.byType(ThreadDetailPanel),
      matching: find.text('Send the survey back'),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(whyPanel(), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the ✕ closes it', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');
    await tester.tap(find.descendant(
      of: find.byType(ThreadDetailPanel),
      matching: find.text('Send the survey back'),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(whyPanel(), findsOneWidget);

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('from a thread that is already beside, it REPLACES that thread',
      (tester) async {
    // The side panel shows one thing. A Why opened from beside takes the slot
    // its own thread was in — the same rule a file opened from there follows.
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await pumpInbox(tester);

    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text('Website redesign'),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    // The episode card opens the thread beside. Its title carries the source
    // mark, and the finder is scoped because the rail names the same thread.
    await tester.tap(find.descendant(
      of: find.byType(StorylineTimelinePanel),
      matching: find.text('✉ Homepage copy'),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(ThreadDetailPanel),
      ),
      findsOneWidget,
    );

    await hover(tester, find.byKey(const ValueKey('c1-m1')));
    await tester.tap(find.byKey(HoverActions.whyKeyFor('c1-m1')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(whyPanel(), findsOneWidget);
    // One panel, not two: the thread it came from has gone.
    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await settleQueues(tester);
  });
}
