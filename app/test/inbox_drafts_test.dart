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
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/drafts_pane.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Drafts & sent, as the shell assembles it.
///
/// The seam this file pins: the row lives in the HOME STACK rather than on the
/// icon rail, and its pane opens threads BESIDE — so a reader can work down
/// the list without the list going away underneath them.

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
    String receivedAt = '2026-09-03T09:00:00Z',
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
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
      'state': 'needs_reply',
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

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(RailSection.home),
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
    // Bounded pumps: the screen owns a sixty-second periodic timer and an
    // unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Two threads, a suggestion on one of them, and one message already sent.
  Future<void> seedAll() async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date', receivedAt: '2026-09-03T10:00:00Z');
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c1',
      replyToMessageId: 'c1-m1',
      body: 'Friday works for me.',
    );
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'c2-out1',
      'conversation_key': 'c2',
      'direction': 'outbound',
      'subject': 'Launch date',
      'to_json': '["dana@example.com"]',
      'received_at': '2026-09-03T11:00:00Z',
      'body_text': 'On it.',
    });
  }

  /// The row in the list column, scoped so the pane beside it cannot answer.
  final draftsRow = find.descendant(
    of: find.byType(AppRail),
    matching: find.text('DRAFTS & SENT'),
  );

  Future<void> openDrafts(WidgetTester tester) async {
    await tester.tap(draftsRow);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the row sits in the Home stack, badged with what is waiting',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    expect(draftsRow, findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppRail), matching: find.text('1')),
      findsWidgets,
    );
    // And it is NOT a stop: the strip has six icons and Drafts & sent is not
    // one of them.
    expect(
      find.descendant(
        of: find.byType(IconRail),
        matching: find.text('Drafts & sent'),
      ),
      findsNothing,
    );
    await settleQueues(tester);
  });

  testWidgets('opening it shows both halves', (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await openDrafts(tester);

    expect(find.byType(DraftsPane), findsOneWidget);
    expect(find.text('Dana Whitfield · Homepage copy'), findsOneWidget);
    expect(find.text('dana@example.com · Launch date'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the icon rail lights Home while the pane is up', (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await openDrafts(tester);

    final material = tester.widget<Material>(find
        .ancestor(
          of: find.descendant(
            of: find.byType(IconRail),
            matching: find.text('Home'),
          ),
          matching: find.byType(Material),
        )
        .first);
    // A Home-stack row lights the stack it belongs to. Anything else would
    // leave every icon dark, which reads as "you are nowhere".
    expect(material.color, BondColors.onDarkTint);
    await settleQueues(tester);
  });

  testWidgets('a draft row opens its thread BESIDE, one Use it from full',
      (tester) async {
    // Rewritten: the box no longer opens holding the suggestion. The hint
    // above it is what says one is waiting, and `Use it` is what fills it.
    await seedAll();
    await pumpInbox(tester);
    await openDrafts(tester);

    await tester.tap(find.byKey(DraftsPane.draftKeyFor('email', 'c1-m1')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Beside, not instead: the list is still there to work down.
    expect(find.byType(DraftsPane), findsOneWidget);
    final sideThread = find.descendant(
      of: find.byType(SidePanelHost),
      matching: find.byType(ThreadDetailPanel),
    );
    expect(sideThread, findsOneWidget);
    expect(
      tester.widget<ThreadDetailPanel>(sideThread).conversation.id,
      'c1',
    );

    Composer sideComposer() => tester.widget<Composer>(find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(Composer),
        ));
    expect(sideComposer().suggestedBody, isNull);
    expect(find.byKey(InboxScreen.useSuggestionKey), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byKey(InboxScreen.useSuggestionKey),
      matching: find.text('Use it'),
    ));
    await tester.pump();
    await tester.pump();

    expect(sideComposer().suggestedBody, 'Friday works for me.');
    await settleQueues(tester);
  });

  testWidgets('a sent row opens its thread beside too', (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await openDrafts(tester);

    await tester.tap(find.byKey(DraftsPane.sentKeyFor('email', 'c2-out1')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<ThreadDetailPanel>(find.descendant(
            of: find.byType(SidePanelHost),
            matching: find.byType(ThreadDetailPanel),
          ))
          .conversation
          .id,
      'c2',
    );
    await settleQueues(tester);
  });

  testWidgets('Dismiss takes the row and the badge with it', (tester) async {
    await seedAll();
    await pumpInbox(tester);
    await openDrafts(tester);

    await tester.tap(find.byKey(DraftsPane.dismissKeyFor('email', 'c1-m1')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Dana Whitfield · Homepage copy'), findsNothing);
    expect(find.text('No suggested replies waiting.'), findsOneWidget);
    // The badge comes off the conversation list's own count, so the second
    // reload is what makes the rail agree with the pane.
    expect(
      find.descendant(of: find.byType(AppRail), matching: find.text('1')),
      findsNothing,
    );
    await settleQueues(tester);
  });

  testWidgets('a mailbox with nothing waiting says so in both halves',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openDrafts(tester);

    expect(find.text('No suggested replies waiting.'), findsOneWidget);
    expect(find.text('Nothing sent yet.'), findsOneWidget);
    await settleQueues(tester);
  });
}
