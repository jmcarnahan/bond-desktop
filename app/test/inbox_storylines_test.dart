// `show`: drift generates row classes named Message/Conversation/Storyline
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/storylines_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:bond_inbox/widgets/storyline_pickers.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The member strip on an open storyline, as the SCREEN assembles it.
///
/// `storyline_timeline_test.dart` pins what the panel does with a member list
/// it is handed. This file pins where that list comes from, which stopped being
/// a read the build could make for itself when the store went asynchronous: it
/// is a cached provider now, and a cache that nothing dropped would leave the
/// strip showing the membership from before the user's last action.

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
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'body',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
  }

  /// Runs out the 400ms reload debounce the triage and AI queues arm when they
  /// report, so the test does not end with one pending.
  Future<void> settleQueues(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 500));

  /// Opens the storyline named [title] in the main pane.
  Future<void> openStoryline(WidgetTester tester, String title) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
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

    // The rail's storylines section is expanded by default, so the row is
    // already on screen.
    await tester.tap(find.text(title));
    // One for the tap, then one per round trip behind the timeline and the
    // member strip.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the member strip counts what the storyline holds',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    expect(find.text('2 threads'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('and follows a thread joining it', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');
    expect(find.text('1 thread'), findsOneWidget);

    // The strip is read through a cache. What drops it is the list load every
    // one of these actions ends with — without that, the count below stays at
    // one however many threads the storyline actually holds.
    await container
        .read(storylinesProvider.notifier)
        .addThread('sl-1', 'email', 'c2');
    await tester.pump();
    await tester.pump();

    expect(find.text('2 threads'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Add thread opens a pane over the storyline, and back returns',
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await seedThread('c2', 'Launch date');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    await tester.tap(find.text('Add thread'));
    await tester.pump();
    await tester.pump();

    // A pane in the main pane, not a popup over it — that is the whole point
    // of the surface.
    expect(find.byType(AddThreadToStorylinePane), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    // The thread already in the storyline is not on offer.
    expect(find.text('✉ Launch date'), findsOneWidget);
    expect(find.text('✉ Homepage copy'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AddThreadToStorylinePane), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Open thread on a card opens it, whatever the source filter says',
      (tester) async {
    // One key, two connectors — which is legal, since a conversation key is
    // only unique within the connector that issued it.
    await seedThread('shared-1', 'Homepage copy');
    await seedThread('shared-1', 'Sarah Whitfield', source: 'teams');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'teams', 'shared-1',
        addedBy: 'auto');

    await openStoryline(tester, 'Website redesign');

    // Mail only, so the chat this storyline holds is not in the list the pane
    // resolves the selection against first.
    await tester.tap(find.byKey(SourceFilterBar.mailKey));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Open thread'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The card knows which connector its key belongs to and says so, which is
    // what stops the key resolving to the mail thread that shares it. An
    // explicit click also outranks the filter — landing on a section overview
    // instead would read as a broken card.
    final panel =
        tester.widget<ThreadDetailPanel>(find.byType(ThreadDetailPanel));
    expect(panel.conversation.source, 'teams');
    expect(panel.conversation.subject, 'Sarah Whitfield');
    await settleQueues(tester);
  });
}
