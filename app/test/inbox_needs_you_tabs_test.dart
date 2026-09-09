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
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/needs_you_tabs.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The five lenses on the Needs You overview, wired to a real store.
///
/// `needs_you_tabs_test` holds the filtering and the ordering; this holds the
/// seam — the pills and the order control are there, the two data-driven tabs
/// read the columns `loadConversations` adds, the order the control writes is
/// the order the rail draws, and the choice survives a trip into a thread and
/// back.

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
    String urgency = 'normal',
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
      'cta_urgency': urgency,
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

  /// The pane's title — the icon rail wears the same words on its stop, so a
  /// plain text finder would count two.
  Finder title(String text) => find.byWidgetPredicate(
        (w) => w is Text && w.data == text && w.style == BondType.title,
      );

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

  testWidgets('a source pill names itself on the title, and an empty pane '
      'says which half it is showing and offers the way back', (tester) async {
    // Every row here is mail. Under the Teams pill the pane is empty, and an
    // empty pane titled plain 'Needs You' would be saying nothing needs you.
    await seedAll();
    await pumpInbox(tester);
    expect(title('Needs You'), findsOneWidget);
    expect(rowTitles(tester), isNotEmpty);

    await tester.tap(find.byKey(SourceFilterBar.teamsKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(title('Needs You · ${sourceFilterLabel('teams')}'), findsOneWidget);
    expect(title('Needs You'), findsNothing);
    expect(find.text(NeedsYouTab.all.emptyText), findsOneWidget);
    expect(
      find.text('Showing ${sourceFilterLabel('teams')} only.'),
      findsOneWidget,
    );

    // Another tab, another sentence — the notice stays.
    await pickTab(tester, NeedsYouTab.deadlines);
    expect(find.text(NeedsYouTab.deadlines.emptyText), findsOneWidget);
    expect(find.text(NeedsYouTab.all.emptyText), findsNothing);
    expect(find.byKey(InboxScreen.showAllSourcesKey), findsOneWidget);

    await tester.tap(find.byKey(InboxScreen.showAllSourcesKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(title('Needs You'), findsOneWidget);
    expect(find.textContaining('Showing'), findsNothing);
    expect(rowTitles(tester), isNotEmpty);
    await settleQueues(tester);
  });

  testWidgets('an empty tab with nothing narrowed says only what it means',
      (tester) async {
    await seedThread('c1', 'Homepage copy', cta: 'Confirm the launch date');
    await pumpInbox(tester);

    await pickTab(tester, NeedsYouTab.suggestedDrafts);

    expect(find.text(NeedsYouTab.suggestedDrafts.emptyText), findsOneWidget);
    expect(find.text('Nothing here.'), findsNothing);
    expect(find.byKey(InboxScreen.showAllSourcesKey), findsNothing);
    await settleQueues(tester);
  });

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

  /// The thread panel in the side panel, if there is one — the finder every
  /// test of something that opens beside is written against.
  final sideThread = find.descendant(
    of: find.byType(SidePanelHost),
    matching: find.byType(ThreadDetailPanel),
  );

  testWidgets('the tab survives opening a thread beside and closing it',
      (tester) async {
    // Rewritten: a row on this overview opens BESIDE now. The list is the room
    // the reader is standing in, so it stays — and the tab with it.
    await seedAll();
    await pumpInbox(tester);
    await pickTab(tester, NeedsYouTab.deadlines);

    await tester.tap(find.text('Deadline · by Friday'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(sideThread, findsOneWidget);
    // The pills never left, and neither did the list under them.
    expect(find.byKey(const Key('needs-you-tabs')), findsOneWidget);
    expect(rowTitles(tester), ['Homepage copy']);
    // And the row that opened it is lit, so the list says which thread is over
    // there.
    expect(
      tester
          .widget<ConversationRow>(find.byWidgetPredicate(
            (w) => w is ConversationRow && w.conversation.id == 'c1',
          ))
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    expect(rowTitles(tester), ['Homepage copy']);
    await settleQueues(tester);
  });

  testWidgets('⤢ hands the thread the main pane', (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await pickTab(tester, NeedsYouTab.deadlines);

    await tester.tap(find.text('Deadline · by Friday'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // ⤢ is a selection: the thread takes the whole pane, so the overview it
    // came from is not on screen and it is never in both.
    expect(find.byType(SidePanelHost), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    expect(find.byKey(const Key('needs-you-tabs')), findsNothing);

    // Scoped to the panel: the main pane's thread draws the only Back on
    // screen, and an unscoped tooltip finder would be one more thing to break
    // when a neighbouring pane grows one.
    await tester.tap(find.descendant(
      of: find.byType(ThreadDetailPanel),
      matching: find.byTooltip('Back'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Coming back lands on the tab the reader left, exactly as the Archive
    // pane's pills do.
    expect(find.byKey(const Key('needs-you-tabs')), findsOneWidget);
    expect(rowTitles(tester), ['Homepage copy']);
    await settleQueues(tester);
  });

  group('the order of the pile', () {
    /// Two threads whose ranking and whose clock disagree: the older one is
    /// urgent and outscores the newer one however the recency decay lands, so
    /// the fixture does not rot as the dates recede.
    Future<void> seedRankedAgainstTheClock() async {
      await seedThread(
        'a',
        'Homepage copy',
        cta: 'Confirm the launch date',
        receivedAt: '2026-09-01T09:00:00Z',
        urgency: 'urgent',
      );
      await seedThread(
        'b',
        'Invoice 4471',
        cta: 'Sign the invoice',
        receivedAt: '2026-09-03T09:00:00Z',
      );
    }

    /// One row's position in whichever list it is scoped to.
    double topOf(WidgetTester tester, Finder scope, String id) =>
        tester.getTopLeft(find.descendant(
          of: scope,
          matching: find.byWidgetPredicate(
            (w) => w is ConversationRow && w.conversation.id == id,
          ),
        )).dy;

    /// One Needs You row's position on the rail. Its title carries a `· who`
    /// suffix, which makes the row a `Text.rich` rather than plain text.
    double railTopOf(WidgetTester tester, String ask) =>
        tester.getTopLeft(find.descendant(
          of: find.byType(AppRail),
          matching: find.textContaining(ask),
        )).dy;

    Future<void> pickOrder(WidgetTester tester, NeedsYouSort sort) async {
      await tester.tap(find.byKey(const Key('needs-you-sort')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(Key('needs-you-sort-${sort.name}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the order control is there, and By priority is the default',
        (tester) async {
      await seedAll();
      await pumpInbox(tester);

      expect(find.byKey(const Key('needs-you-sort')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('needs-you-sort')),
          matching: find.text(NeedsYouSort.priority.label),
        ),
        findsOneWidget,
      );
      await settleQueues(tester);
    });

    testWidgets('Newest first puts today above a louder older thread',
        (tester) async {
      await seedRankedAgainstTheClock();
      await pumpInbox(tester);

      final list = find.byType(ConversationListPane);
      // By priority, the urgent thread from the first leads.
      expect(topOf(tester, list, 'a'), lessThan(topOf(tester, list, 'b')));
      expect(
        railTopOf(tester, 'Confirm the launch date'),
        lessThan(railTopOf(tester, 'Sign the invoice')),
      );

      await pickOrder(tester, NeedsYouSort.newest);

      expect(topOf(tester, list, 'b'), lessThan(topOf(tester, list, 'a')));
      // And the rail flipped with it: one pile, one order, wherever it is
      // drawn. A column still ranking by loudness would teach the reader that
      // the control does not mean what it says.
      expect(
        railTopOf(tester, 'Sign the invoice'),
        lessThan(railTopOf(tester, 'Confirm the launch date')),
      );
      await settleQueues(tester);
    });

    testWidgets('and the order is remembered', (tester) async {
      await seedRankedAgainstTheClock();
      await pumpInbox(tester);

      await pickOrder(tester, NeedsYouSort.newest);

      expect(await store.getPref(needsYouSortKey), 'newest');
      expect(
        find.descendant(
          of: find.byKey(const Key('needs-you-sort')),
          matching: find.text(NeedsYouSort.newest.label),
        ),
        findsOneWidget,
      );
      await settleQueues(tester);
    });
  });
}
