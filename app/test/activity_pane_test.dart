// `show`: drift generates row classes named Message/Conversation/ActivityEvent
// from the tables, and this file means the app's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/activity_log_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The activity pane as the SCREEN assembles it.
///
/// `activity_log_panel_test.dart` pins what the panel does with stats and rows
/// it is handed; nothing pinned where those come from. That gap mattered the
/// moment the store went asynchronous: the pane's stats, its rows, its three
/// freshness stamps and the subject behind each row are no longer four reads a
/// build can make for itself, and the read model that replaced them is only
/// exercised through this door.

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

  Future<void> openPane(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await store.setPref(showActivityLogKey, 'true');
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Activity log'));
    // One for the tap, then one per round trip the pane's read model makes.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders the stored rows and the freshness stamps',
      (tester) async {
    await store.recordActivity(
      kind: 'sync_mail',
      status: 'ok',
      source: 'email',
      count: 3,
      createdAt: '2026-08-28T09:00:00Z',
    );
    await store.setPref(activityLastSyncMailKey, '2026-08-28T09:00:00Z');

    await openPane(tester);

    expect(find.byType(ActivityLogPanel), findsOneWidget);
    expect(find.text('Mail sync — 3 new'), findsOneWidget);
    // The tile reads the pref, not the row — a pane that only read rows would
    // show a dash here for the passes that record nothing.
    expect(find.text('Last sync'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Last sync'),
          matching: find.byType(Column),
        ).first,
        matching: find.text('—'),
      ),
      findsNothing,
      reason: 'a stamp that was read renders as a time, not a dash',
    );
  });

  testWidgets('names the thread an event was about', (tester) async {
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Appraisal review',
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
    await store.recordActivity(
      kind: 'draft',
      status: 'ok',
      source: 'email',
      entityId: 'c1',
      createdAt: '2026-08-28T09:00:00Z',
    );

    await openPane(tester);

    // The subject lives in the tap-to-expand block, which is the only place
    // the entity lookup is rendered.
    await tester.tap(find.descendant(
      of: find.byType(ActivityLogPanel),
      matching: find.byType(InkWell),
    ));
    await tester.pump();

    // Scoped to the panel: the rail behind it lists the same thread, and an
    // unscoped finder would pass whether or not the lookup resolved anything.
    expect(
      find.descendant(
        of: find.byType(ActivityLogPanel),
        matching: find.textContaining('Appraisal review'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty log still renders the panel', (tester) async {
    await openPane(tester);

    expect(find.byType(ActivityLogPanel), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
