import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/activity_log_panel.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Settings as a PANE: the door in, the two doors out, and what the rest of the
/// screen does while it is open.
///
/// Navigation in this app is a bag of booleans rather than a route stack, so
/// every one of these is a separate wiring touch on `_InboxScreenState` — the
/// gear that sets the flag, the five selectors that clear it, the rail
/// highlight that has to go quiet, and the `_main()` ladder that puts Settings
/// first. None of it is visible from the screen's own tests, which pump the
/// widget alone.

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

  Future<void> seedThread(String key, String subject) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Sarah Chen',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'body',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
  }

  Future<void> pumpInbox(WidgetTester tester) async {
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
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );
  }

  /// Settings lives in the icon rail's account menu now (D8), so getting there
  /// is two taps. Bounded pumps throughout: `pumpAndSettle` never comes back
  /// with `InboxScreen`'s sixty-second timer running.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the gear opens Settings in the main pane', (tester) async {
    await pumpInbox(tester);
    expect(find.byType(SettingsScreen), findsNothing);

    await openSettings(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Back returns to the section underneath', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openSettings(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsScreen), findsNothing);
    // The section the gear was pressed from, not Home: Back leaves the pane
    // without moving the selection.
    expect(find.text('NEEDS YOU'), findsWidgets);
  });

  testWidgets('the Home link lands on Home', (tester) async {
    await pumpInbox(tester);
    await openSettings(tester);

    // Scoped: the icon rail's Home stop wears the same tooltip.
    await tester.tap(find.descendant(
      of: find.byType(PaneSurface),
      matching: find.byTooltip('Home'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
  });

  testWidgets('the rail highlights no section while Settings is open',
      (tester) async {
    await pumpInbox(tester);
    expect(
      tester.widget<AppRail>(find.byType(AppRail)).selectedSection,
      RailSection.needsYou,
    );

    await openSettings(tester);

    expect(
      tester.widget<AppRail>(find.byType(AppRail)).selectedSection,
      isNull,
      reason: 'the pane is not showing a section, so nothing is current',
    );
  });

  testWidgets("a notification's OpenThreadIntent closes Settings",
      (tester) async {
    // The pin on the selectors: a thread opened from a notification while
    // Settings is showing must replace the pane, not open behind it.
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openSettings(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);

    container
        .read(navIntentProvider.notifier)
        .request(OpenThreadIntent('email', 'c1'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
  });

  testWidgets('the activity log link opens the log', (tester) async {
    await store.setPref(showActivityLogKey, 'true');
    await pumpInbox(tester);
    await openSettings(tester);

    final toggle = find.byKey(SettingsSection.toggleKey('Activity log'));
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();

    final link = find.text('Open the activity log');
    await tester.ensureVisible(link);
    await tester.pump();
    await tester.tap(link);
    // One for the tap, then one per round trip the pane's read model makes.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(ActivityLogPanel), findsOneWidget);
  });
}
