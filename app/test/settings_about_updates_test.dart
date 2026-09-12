import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:bond_inbox/widgets/time_format.dart' show relativeTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The About section's update controls.
///
/// Three independent controls with three independent wires, and that is the
/// subject: a development build has the not-configured sentence and neither
/// control, a packaged build has both, and the section's own visibility rule —
/// a version or a database path, and not under the AI scope — is unchanged by
/// any of it. A future round that collapses the three `if`s into one would
/// take the sentence off the screen for the developer who needs it most.
///
/// The clock is pinned rather than read, so 'Last checked …' is exact.

final DateTime _now = DateTime.utc(2026, 9, 11, 12, 0);
String _ago(Duration d) => _now.subtract(d).toIso8601String();

void main() {
  Future<void> open(
    WidgetTester tester, {
    bool? automaticUpdates,
    String? lastUpdateCheckIso,
    String? updatesUnavailableReason,
    VoidCallback? onCheckForUpdates,
    ValueChanged<bool>? onAutomaticUpdatesChanged,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
          now: () => _now,
          appVersion: '1.2.3 (4)',
          automaticUpdates: automaticUpdates,
          lastUpdateCheckIso: lastUpdateCheckIso,
          updatesUnavailableReason: updatesUnavailableReason,
          onCheckForUpdates: onCheckForUpdates,
          onAutomaticUpdatesChanged: onAutomaticUpdatesChanged,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    final toggle = find.byKey(SettingsSection.toggleKey(title));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  testWidgets('a packaged build offers the check and says when it last looked',
      (tester) async {
    var checks = 0;
    await open(
      tester,
      onCheckForUpdates: () => checks++,
      lastUpdateCheckIso: _ago(const Duration(hours: 3)),
    );

    await expand(tester, 'About');

    expect(find.text('Check for updates'), findsOneWidget);
    // Whatever relativeTime prints for three hours — asserted through the
    // function rather than against a copied literal, so the two can never
    // drift apart.
    final ago = relativeTime(_ago(const Duration(hours: 3)), _now);
    expect(ago, isNotNull);
    expect(find.text('Last checked $ago'), findsOneWidget);
    expect(find.textContaining('Last checked'), findsOneWidget);

    await tester.tap(find.byKey(SettingsScreen.checkForUpdatesKey));
    await tester.pumpAndSettle();
    expect(checks, 1);
  });

  testWidgets('a build that has never checked says so in words', (tester) async {
    await open(tester, onCheckForUpdates: () {});

    await expand(tester, 'About');

    expect(find.text('Never checked for updates'), findsOneWidget);
    expect(find.textContaining('Last checked'), findsNothing);
  });

  testWidgets('the automatic switch shows Sparkle\'s answer and reports moves',
      (tester) async {
    final moves = <bool>[];
    await open(
      tester,
      automaticUpdates: false,
      onAutomaticUpdatesChanged: moves.add,
    );

    await expand(tester, 'About');

    final tile = find.widgetWithText(
      SwitchListTile,
      'Check for updates automatically',
    );
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(moves, [true]);
    // Still false: the host re-reads the updater and rebuilds with its answer,
    // so the tile must NOT have flipped itself on the way.
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets('a switch with no value behind it does not render',
      (tester) async {
    // Half the wiring is not wiring: a callback with no current value would be
    // a switch that has to guess which way it points.
    await open(tester, onAutomaticUpdatesChanged: (_) {});

    await expand(tester, 'About');

    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('a build without the keys says so and offers nothing',
      (tester) async {
    await open(
      tester,
      updatesUnavailableReason: 'Updates are not configured in this build.',
    );

    await expand(tester, 'About');

    expect(
      find.text('Updates are not configured in this build.'),
      findsOneWidget,
    );
    expect(find.text('Check for updates'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('nothing wired is nothing rendered, and the version stays',
      (tester) async {
    await open(tester);

    await expand(tester, 'About');

    expect(find.text('Version 1.2.3 (4)'), findsOneWidget);
    expect(find.text('Check for updates'), findsNothing);
    expect(find.text('Never checked for updates'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(
      find.text('Updates are not configured in this build.'),
      findsNothing,
    );
  });
}
