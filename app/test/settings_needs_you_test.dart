import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart'
    show needsYouDefaultRules;
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/needs_you_rules_editor.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The rules editor as the SCREEN assembles it.
///
/// `needs_you_rules_editor_test.dart` pins what the editor does with the values
/// it is handed; this pins the door in front of it — that the gear opens
/// Settings, that the Needs You section holds the editor, that it opens on what
/// is stored, and that a Save from inside it lands in `app_prefs` and moves the
/// summary above it. Those are wiring touches on the screen, and none of them
/// is visible from the editor's own tests.
///
/// The Home & feed switch is pinned here too, for the same reason: its second
/// write — the one that moves the feed now rather than at the next launch —
/// only exists in the host.

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

  /// The gear, which is the only route to Settings.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // A worker with no handlers: a rules save wakes the queue, and the
        // real one would reach a model server this test has no business
        // dialling — and would claim the very rows the assertions read.
        aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();

    // The scope's own container, read back rather than injected: an
    // UncontrolledProviderScope disposed in a tearDown outlives the timer
    // check flutter_test runs first, and the pane's coordinator owns one.
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );

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

  Future<void> openRules(WidgetTester tester) async {
    await openSettings(tester);
    await expand(tester, 'Needs You');
  }

  testWidgets('the gear lands on Settings with every section collapsed',
      (tester) async {
    await openSettings(tester);

    expect(find.text('Settings'), findsOneWidget);
    // Eight sections on a wired host; every one of them shut.
    expect(find.text('Expand'), findsWidgets);
    expect(find.text('Collapse'), findsNothing);
    expect(find.byType(NeedsYouRulesEditor), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('Settings opens the rules on what is stored', (tester) async {
    await store.setPref(needsYouRulesKey, 'Anything about the budget.');

    await openRules(tester);

    expect(find.byType(NeedsYouRulesEditor), findsOneWidget);
    expect(find.text('Anything about the budget.'), findsOneWidget);
  });

  testWidgets('a Save from the section lands in app_prefs', (tester) async {
    await openRules(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(NeedsYouRulesEditor),
        matching: find.byType(TextField),
      ),
      '  Invoices always. \n',
    );
    await tester.pump();
    await tapVisible(tester, find.text('Save'));
    await tester.pump();

    // Trimmed by the editor, stored verbatim by the store — the two halves of
    // the one contract.
    expect(await store.getPref(needsYouRulesKey), 'Invoices always.');
    // Still here: Save commits and stays, because there is nowhere to go back
    // to from a section.
    expect(find.byType(NeedsYouRulesEditor), findsOneWidget);
    // And the summary followed it, which only happens because the host watches
    // the prefs rather than reading them once.
    expect(find.textContaining('custom rules'), findsOneWidget);
  });

  testWidgets('a fresh install shows the default body in the field',
      (tester) async {
    // Nothing stored means the app's own rules are what the model reads, so
    // they are what the editor opens on — and the screen has to hand the
    // editor the real ones for that to be true.
    await openRules(tester);

    // Scoped to the editor: About me holds a TextField of its own, and a bare
    // type finder would depend on which sections happen to be open.
    expect(
      tester
          .widget<TextField>(find.descendant(
            of: find.byType(NeedsYouRulesEditor),
            matching: find.byType(TextField),
          ))
          .controller!
          .text,
      needsYouDefaultRules,
    );
  });

  /// One kept inbound message, [ageDays] old.
  Future<void> seedJudgeable(String id, {required int ageDays}) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': 'Launch date',
      'from_address': 'sarah@x.com',
      'received_at': DateTime.now()
          .toUtc()
          .subtract(Duration(days: ageDays))
          .toIso8601String(),
      'triage_status': 'triaged',
    });
  }

  /// Every `needs_you` work row, as `entity_id` → status.
  Future<Map<String, String>> needsYouWork() async {
    final rows = await db
        .customSelect(
          "SELECT entity_id, status FROM work_items "
          "WHERE task_kind = 'needs_you'",
        )
        .get();
    return {
      for (final row in rows)
        row.data['entity_id'] as String: row.data['status'] as String,
    };
  }

  Future<List<Map<String, Object?>>> rejudgeEvents() async => [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'needs_you_rejudge') row,
      ];

  /// Types [text] into the rules field and saves it.
  Future<void> saveRules(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(NeedsYouRulesEditor),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pump();
    await tapVisible(tester, find.text('Save'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('saving the same rules again re-judges nothing', (tester) async {
    // The whitespace is what makes Save available at all: the editor trims on
    // the way out, so what the host is handed is the string already stored.
    await store.setPref(needsYouRulesKey, 'Invoices always.');
    await seedJudgeable('m1', ageDays: 1);

    await openRules(tester);
    await saveRules(tester, '  Invoices always. \n');

    expect(await needsYouWork(), isEmpty);
    expect(await rejudgeEvents(), isEmpty);
  });

  testWidgets('new rules re-judge the recent window and record what they queued',
      (tester) async {
    await seedJudgeable('m-today', ageDays: 1);
    await seedJudgeable('m-week', ageDays: 5);
    await seedJudgeable('m-month', ageDays: 30);

    await openRules(tester);
    await saveRules(tester, 'Anything about the budget.');

    expect(
      (await needsYouWork()).keys,
      unorderedEquals(['m-today', 'm-week']),
      reason: 'the month-old verdict is history, not a mistake',
    );
    final events = await rejudgeEvents();
    expect(events, hasLength(1));
    expect(events.single['count'], 2);
  });

  testWidgets('the Needs You summary counts the queue down', (tester) async {
    await seedJudgeable('m-today', ageDays: 1);

    await openRules(tester);
    await saveRules(tester, 'Anything about the budget.');

    expect(find.textContaining('judging 1 message'), findsOneWidget);
  });

  testWidgets('the Home & feed switch moves the feed now, not at next launch',
      (tester) async {
    // The feed reads this preference once, when its notifier is built, so the
    // host has to tell the notifier as well as the store. Writing only the
    // pref would leave Home unchanged until the app was restarted.
    await openSettings(tester);
    await expand(tester, 'Home & feed');

    expect(container.read(homeFeedProvider).includeDropped, isFalse);

    await tapVisible(tester, find.byType(SwitchListTile));

    expect(container.read(homeFeedProvider).includeDropped, isTrue);
    expect(await store.getPref(homeShowDroppedKey), 'true');
  });
}
