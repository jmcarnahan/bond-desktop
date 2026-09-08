import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The lookback pair as the SCREEN assembles it.
///
/// `settings_lookback_test.dart` pins what the control does with the values it
/// is handed; this pins the wire behind it — that the host passes the stored
/// days in, and that a pick lands in `app_prefs` under the key the next sync
/// reads. Neither of those is visible from the widget's own tests.

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

  Future<void> openSync(WidgetTester tester) async {
    await openSettings(tester);
    await tapVisible(tester, find.byKey(SettingsSection.toggleKey('Sync & data')));
  }

  /// Picks [label] out of the dropdown at [key]. The open menu puts a second
  /// copy of every item on screen, so the tap goes to the last match.
  Future<void> pick(WidgetTester tester, Key key, String label) async {
    await tapVisible(tester, find.byKey(key));
    await tapVisible(tester, find.text(label).last);
  }

  testWidgets('a mail preset lands in app_prefs under the key the sync reads',
      (tester) async {
    await openSync(tester);

    await pick(tester, const ValueKey('settings-mail-lookback'), '90 days');

    expect(await store.getPref(mailLookbackDaysKey), '90');
    // The other side is untouched — two settings, not one.
    expect(await store.getPref(teamsLookbackDaysKey), isNull);
  });

  testWidgets('and a Teams preset lands under its own key', (tester) async {
    await openSync(tester);

    await pick(tester, const ValueKey('settings-teams-lookback'), '30 days');

    expect(await store.getPref(teamsLookbackDaysKey), '30');
    expect(await store.getPref(mailLookbackDaysKey), isNull);
  });
}
