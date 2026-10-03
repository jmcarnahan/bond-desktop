import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The Needs You slider as the SCREEN assembles it.
///
/// `settings_screen_test.dart` pins what the slider does with the values it is
/// handed; this pins the door in front of it — that the gear opens Settings,
/// that the Needs You section opens on the stored threshold, that a drag lands
/// in `app_prefs` and moves the summary above it, and that a needs-you text an
/// older build stored brings no editor back. Those are wiring touches on the
/// screen, and none of them is visible from the screen's own tests.

class _FakeSync implements MailSync {
  @override
  Future<void> ensureBodiesFor(
    String conversationKey,
    List<String> sourceMessageIds,
  ) async {}

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

  /// The gear, which is the only route to Settings.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        keepingDecisionClient(),
        noCommandHeads(),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // A worker with no handlers: the real one would reach a model server
        // this test has no business dialling.
        aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();

    // Settings and the activity log live in the icon rail's account menu now
    // (D8), so getting there is two taps. Bounded pumps throughout —
    // `pumpAndSettle` never comes back with InboxScreen's timer running.
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps something after scrolling it into view. The sections stack into one
  /// scroll view, so a control in an open body can easily sit below the fold.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
    await tester.pump();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    await tapVisible(tester, find.byKey(SettingsSection.toggleKey(title)));
  }

  Future<void> openNeedsYou(WidgetTester tester) async {
    await openSettings(tester);
    await expand(tester, 'Needs You');
  }

  testWidgets('the avatar menu lands on Settings with every section collapsed',
      (tester) async {
    await openSettings(tester);

    expect(find.text('Settings'), findsOneWidget);
    // Eight sections on a wired host; every one of them shut.
    expect(find.text('Expand'), findsWidgets);
    expect(find.text('Collapse'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('Settings opens the slider on what is stored', (tester) async {
    await store.setPref(needsYouThresholdKey, '0.45');

    await openNeedsYou(tester);

    expect(find.text('At 45% or more'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(SettingsScreen.needsYouThresholdLineKey))
          .data,
      'Needs you at 45% or more',
    );
  });

  testWidgets('a drag lands in app_prefs and moves the summary',
      (tester) async {
    await openNeedsYou(tester);
    expect(find.text('At 35% or more'), findsOneWidget);

    // All the way right: anything plausible, the lowest threshold.
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.pump();
    await tester.drag(slider, const Offset(2000, 0));
    await tester.pump();
    await tester.pump();

    expect(await store.getPref(needsYouThresholdKey), '0.05');
    // The summary followed it, which only happens because the host watches
    // the prefs rather than reading them once.
    expect(find.text('At 5% or more'), findsOneWidget);
  });

  testWidgets('a needs-you text an older build stored brings back no editor, '
      'only one quiet line saying so', (tester) async {
    await store.setPref(needsYouRulesKey, 'Anything about the budget.');

    await openNeedsYou(tester);

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Anything about the budget.'), findsNothing);
    expect(
      find.text('Your earlier Needs You rules are no longer used; the slider '
          'is the one control.'),
      findsOneWidget,
    );
  });

  testWidgets('with no old rules text there is no such line', (tester) async {
    await openNeedsYou(tester);

    expect(find.byKey(SettingsScreen.oldNeedsYouRulesKey), findsNothing);
    expect(find.textContaining('rules'), findsNothing);
  });
}
