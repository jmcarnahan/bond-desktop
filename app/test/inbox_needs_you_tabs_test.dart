// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show TriageResult;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/needs_you_tabs.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The five lenses on the Needs You overview, wired to a real store.
///
/// `needs_you_tabs_test` holds the filtering; this holds the seam — the pills
/// are there, the two data-driven tabs read the columns `loadConversations`
/// adds, and the choice survives a trip into a thread and back.

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
    required String cta,
    String state = 'needs_reply',
    String receivedAt = '2026-09-03T09:00:00Z',
    String? deadline,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': receivedAt,
      'body_text': 'the hero paragraph',
    });
    if (deadline != null) {
      await store.writeTriage(
        'email',
        '$key-m1',
        status: 'triaged',
        result: TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: subject,
          needsAction: true,
          actionItems: const [],
          deadline: deadline,
        ),
      );
    }
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
      'state': state,
      'cta_text': cta,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
  }

  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Everything eligible reaches Needs You. The scoring pass lands a few
    // pumps in and a thread waiting on somebody else scores quietly, so the
    // default slider would cut a row this file is about — and the slider has
    // its own tests.
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
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Three rows: one with a deadline, one with a suggestion, one waiting on
  /// somebody else.
  Future<void> seedAll() async {
    await seedThread(
      'c1',
      'Homepage copy',
      cta: 'Confirm the launch date',
      deadline: 'by Friday',
    );
    await seedThread(
      'c2',
      'Invoice 4471',
      cta: 'Sign the invoice',
      receivedAt: '2026-09-03T10:00:00Z',
    );
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c2',
      replyToMessageId: 'c2-m1',
      body: 'Signed and returned.',
    );
    await seedThread(
      'c3',
      'Vendor quote',
      cta: 'Waiting on the vendor',
      state: 'waiting',
      receivedAt: '2026-09-03T11:00:00Z',
    );
  }

  Future<void> pickTab(WidgetTester tester, NeedsYouTab tab) async {
    await tester.tap(find.descendant(
      of: find.byKey(const Key('needs-you-tabs')),
      matching: find.text(tab.label),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// Whatever the list pane is drawing, section label and all.
  List<String> rowTitles(WidgetTester tester) {
    final pane = tester.widget<ConversationListPane>(
      find.byType(ConversationListPane),
    );
    return [
      for (final (_, rows) in pane.sectionsOverride!)
        for (final c in rows) c.subject ?? '',
    ];
  }

  testWidgets('all five pills are there, on All', (tester) async {
    await seedAll();
    await pumpInbox(tester);

    final tabs = find.byKey(const Key('needs-you-tabs'));
    expect(tabs, findsOneWidget);
    for (final tab in NeedsYouTab.values) {
      // Scoped: the source chips carry an 'All' pill of their own.
      expect(
        find.descendant(of: tabs, matching: find.text(tab.label)),
        findsOneWidget,
        reason: tab.label,
      );
    }
    // All leads and is the default, so arriving at the stop shows what the
    // stop always showed.
    expect(find.text('NEEDS YOU'), findsWidgets);
    expect(rowTitles(tester), hasLength(3));
    await settleQueues(tester);
  });

  testWidgets('Deadlines shows only the thread whose newest inbound named one',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await pickTab(tester, NeedsYouTab.deadlines);

    expect(rowTitles(tester), ['Homepage copy']);
    // And the row reads the date in the sender's own words, in place of the
    // ask its title already carries.
    expect(find.text('Deadline · by Friday'), findsOneWidget);
    expect(find.text('Confirm the launch date'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('Suggested drafts shows only the thread the model wrote for',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await pickTab(tester, NeedsYouTab.suggestedDrafts);

    expect(rowTitles(tester), ['Invoice 4471']);
    expect(find.text('SUGGESTED DRAFTS'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the two halves of who is waiting are complements',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await pickTab(tester, NeedsYouTab.waitingOnOthers);
    expect(rowTitles(tester), ['Vendor quote']);

    await pickTab(tester, NeedsYouTab.askedOfMe);
    expect(rowTitles(tester), containsAll(['Homepage copy', 'Invoice 4471']));
    expect(rowTitles(tester), isNot(contains('Vendor quote')));
    await settleQueues(tester);
  });

  testWidgets('the tab survives opening a thread and coming back',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await pickTab(tester, NeedsYouTab.deadlines);

    await tester.tap(find.text('Deadline · by Friday'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(ThreadDetailPanel), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Coming back lands on the tab the reader left, exactly as the Archive
    // pane's pills do.
    expect(rowTitles(tester), ['Homepage copy']);
    await settleQueues(tester);
  });
}
