import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/needs_you_rules_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The rules editor as the SCREEN assembles it.
///
/// `needs_you_rules_pane_test.dart` pins what the pane does with the values it
/// is handed; this pins the door in front of it — that Settings actually opens
/// it, that it opens on what is stored, and that a Save from inside it lands in
/// `app_prefs`. Those are six separate wiring touches on the screen, and none
/// of them is visible from the pane's own tests.

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

  /// Settings → "What counts as needing you…" → the pane, which is the only
  /// route to it.
  Future<void> openPane(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('What counts as needing you…'));
    // One for the tap, one for the dialog's pop, one for the pane.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Settings opens the pane on the stored rules', (tester) async {
    await store.setPref(needsYouRulesKey, 'Anything about the budget.');

    await openPane(tester);

    expect(find.byType(NeedsYouRulesPane), findsOneWidget);
    expect(find.text('Anything about the budget.'), findsOneWidget);
    // The dialog got out of the way rather than sitting on top of the pane.
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('a Save from the pane lands in app_prefs', (tester) async {
    await openPane(tester);

    await tester.enterText(find.byType(TextField), '  Invoices always. \n');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();

    // Trimmed by the pane, stored verbatim by the store — the two halves of
    // the one contract.
    expect(await store.getPref(needsYouRulesKey), 'Invoices always.');
    // Back on the mail, not left in the editor.
    expect(find.byType(NeedsYouRulesPane), findsNothing);
  });
}
