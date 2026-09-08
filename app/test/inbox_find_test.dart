// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
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
import 'package:bond_inbox/widgets/find_field.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fixtures/test_db.dart';

/// The Find field, ⌘K and the Unread toggle, as the shell wires them.
///
/// Find is not search: it narrows the rows already on the rail, live, and
/// Enter opens the first one still drawn. What this file pins is that the row
/// Enter opens is the row the reader can SEE — and what happens when there is
/// no such row.

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
    required String who,
    String receivedAt = '2026-09-03T09:00:00Z',
    bool unread = false,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': who,
      'from_address': '${who.split(' ').first.toLowerCase()}@example.com',
      'received_at': receivedAt,
      'is_read': unread ? 0 : 1,
      'body_text': 'the hero paragraph',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"$who",'
          '"email":"${who.split(' ').first.toLowerCase()}@example.com"}]',
      'state': 'needs_reply',
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

    // Everything eligible reaches the rail. The scoring pass lands a few pumps
    // in, and the default slider would cut rows this file is about; the slider
    // has its own tests.
    await store.setPref(attentionThresholdKey, '0');
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
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Three threads and one storyline nothing on the rail is named after.
  Future<void> seedAll() async {
    await seedThread(
      'c1',
      'Homepage copy',
      cta: 'Confirm the launch date',
      who: 'Dana Whitfield',
      unread: true,
    );
    await seedThread(
      'c2',
      'Invoice 4471',
      cta: 'Sign the invoice',
      who: 'Eric Vance',
      receivedAt: '2026-09-03T10:00:00Z',
    );
    await seedThread(
      'c3',
      'Vendor quote',
      cta: 'Approve the quote',
      who: 'Priya Raman',
      receivedAt: '2026-09-03T11:00:00Z',
    );
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
  }

  Future<void> type(WidgetTester tester, String needle) async {
    await tester.enterText(find.byKey(FindField.fieldKey), needle);
    await tester.pump();
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// A row title, scoped to the list column — the overview beside it names the
  /// same threads.
  Finder railRow(String text) =>
      find.descendant(of: find.byType(AppRail), matching: find.text(text));

  testWidgets('⌘K puts the cursor in the field from anywhere', (tester) async {
    await seedAll();
    await pumpInbox(tester);

    expect(
      tester.widget<EditableText>(find.descendant(
        of: find.byKey(FindField.fieldKey),
        matching: find.byType(EditableText),
      )).focusNode.hasFocus,
      isFalse,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.pump();

    // The `Focus(autofocus: true)` wrapper is what makes this work: bindings
    // only see keys while focus is inside their subtree, and on a fresh screen
    // nothing has focus at all.
    expect(
      tester.widget<EditableText>(find.descendant(
        of: find.byKey(FindField.fieldKey),
        matching: find.byType(EditableText),
      )).focusNode.hasFocus,
      isTrue,
    );
    await settleQueues(tester);
  });

  testWidgets('typing narrows the column and leaves the badge alone',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await type(tester, 'invoice');

    expect(railRow('Sign the invoice · Eric Vance'), findsOneWidget);
    expect(railRow('Confirm the launch date · Dana Whitfield'), findsNothing);
    // A filter changes what you can see, never what you owe.
    expect(
      find.descendant(of: find.byType(AppRail), matching: find.text('3')),
      findsOneWidget,
    );
    await settleQueues(tester);
  });

  testWidgets('Enter opens the first row still drawn, in the main pane',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await type(tester, 'invoice');
    await submit(tester);

    final panel = find.byType(ThreadDetailPanel);
    expect(panel, findsOneWidget);
    expect(tester.widget<ThreadDetailPanel>(panel).conversation.id, 'c2');
    // The main pane, not beside it: Find is a switcher, and a switcher takes
    // you somewhere.
    expect(find.byType(SidePanelHost), findsNothing);
    // And the switcher closes on a pick, as Slack's does.
    expect(
      tester
          .widget<TextField>(find.byKey(FindField.fieldKey))
          .controller!
          .text,
      isEmpty,
    );
    await settleQueues(tester);
  });

  testWidgets('a needle only a storyline answers opens the storyline',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await type(tester, 'redesign');
    await submit(tester);

    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Escape empties the box and puts every row back', (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await type(tester, 'invoice');
    expect(railRow('Confirm the launch date · Dana Whitfield'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    expect(railRow('Confirm the launch date · Dana Whitfield'), findsOneWidget);
    expect(railRow('Sign the invoice · Eric Vance'), findsOneWidget);
    expect(railRow('Approve the quote · Priya Raman'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a needle nothing on the rail answers escalates to Home search',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    await type(tester, 'zzzznothing');
    await submit(tester);

    // The honest escalation: Find only ever looked at the rail, and search
    // looks at the whole index. What the search comes BACK with is not this
    // file's business — the embedding server is unreachable in a widget test.
    expect(find.byType(HomePane), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('the Unread toggle hides read rows, and says which way it is on',
      (tester) async {
    await seedAll();
    await pumpInbox(tester);

    expect(find.byTooltip('Unread only'), findsOneWidget);
    expect(railRow('Sign the invoice · Eric Vance'), findsOneWidget);

    await tester.tap(find.byKey(const Key('unread-toggle')));
    await tester.pump();
    await tester.pump();

    expect(railRow('Confirm the launch date · Dana Whitfield'), findsOneWidget);
    expect(railRow('Sign the invoice · Eric Vance'), findsNothing);
    // The tooltip names what pressing it would DO, so it flips with the state.
    expect(find.byTooltip('Show everything'), findsOneWidget);

    await tester.tap(find.byKey(const Key('unread-toggle')));
    await tester.pump();
    await tester.pump();

    expect(railRow('Sign the invoice · Eric Vance'), findsOneWidget);
    await settleQueues(tester);
  });
}
