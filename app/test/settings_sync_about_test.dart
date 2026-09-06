import 'dart:async';

import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The last two sections: when things last ran, and what this build is.
///
/// The subject worth pinning is the destructive action. The house rule forbids
/// a confirmation dialog, so the confirmation is the button changing shape in
/// place — and the protection that buys is only real if the second click lands
/// on a button that did not exist a moment ago. These tests are what keep that
/// two-step from being quietly collapsed back into one.
///
/// The clock is pinned rather than read, so the relative strings are exact.

final DateTime _now = DateTime.utc(2026, 9, 5, 12, 0);
String _ago(Duration d) => _now.subtract(d).toIso8601String();

void main() {
  Future<void> open(
    WidgetTester tester, {
    String? mail,
    String? teams,
    String? sweep,
    Future<void> Function()? onRefreshNow,
    Future<void> Function()? onSignOutAndClear,
    String? appVersion,
    String? databasePath,
    bool wireRefresh = true,
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
          lastMailSyncIso: mail,
          lastTeamsSyncIso: teams,
          lastSweepIso: sweep,
          onRefreshNow: wireRefresh ? (onRefreshNow ?? () async {}) : null,
          onSignOutAndClear: onSignOutAndClear,
          appVersion: appVersion,
          databasePath: databasePath,
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

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final target = find.byKey(key);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('a mailbox nothing has ever pulled says so', (tester) async {
    await open(tester);

    expect(find.text('Not synced yet'), findsOneWidget);

    await expand(tester, 'Sync & data');
    expect(find.text('never'), findsNWidgets(3));
  });

  testWidgets('the summary is relative, in one unit', (tester) async {
    await open(
      tester,
      mail: _ago(const Duration(minutes: 4)),
      teams: _ago(const Duration(hours: 2)),
    );

    expect(find.text('Mail synced 4m ago · Teams 2h ago'), findsOneWidget);

    await expand(tester, 'Sync & data');
    // The sweep alone has never run.
    expect(find.text('never'), findsOneWidget);
    expect(find.text('4m ago'), findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
  });

  testWidgets('a side that has never run is said in words, not as "synced '
      'never"', (tester) async {
    await open(tester, mail: _ago(const Duration(minutes: 4)));
    expect(
      find.text('Mail synced 4m ago · Teams not synced yet'),
      findsOneWidget,
    );

    await open(tester, teams: _ago(const Duration(hours: 2)));
    expect(
      find.text('Mail not synced yet · Teams synced 2h ago'),
      findsOneWidget,
    );
  });

  testWidgets('Refresh now asks the host to pull', (tester) async {
    var pulls = 0;
    await open(tester, onRefreshNow: () async => pulls++);
    await expand(tester, 'Sync & data');

    await tapKey(tester, SettingsScreen.refreshNowKey);

    expect(pulls, 1);
  });

  testWidgets('Refresh now says it is refreshing until the pull is back, and '
      'cannot be pressed twice', (tester) async {
    final pending = Completer<void>();
    var pulls = 0;
    await open(tester, onRefreshNow: () {
      pulls++;
      return pending.future;
    });
    await expand(tester, 'Sync & data');

    await tapKey(tester, SettingsScreen.refreshNowKey);

    expect(find.text('Refreshing…'), findsOneWidget);
    expect(find.text('Refresh now'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(SettingsScreen.refreshNowKey))
          .onPressed,
      isNull,
      reason: 'a second click while the pull is out would double it',
    );

    pending.complete();
    await tester.pumpAndSettle();

    expect(find.text('Refresh now'), findsOneWidget);
    expect(find.text('Refreshing…'), findsNothing);
    expect(pulls, 1);
  });

  testWidgets('a pull that throws still lets go of the button',
      (tester) async {
    await open(tester, onRefreshNow: () async => throw StateError('graph'));
    await expand(tester, 'Sync & data');

    await tapKey(tester, SettingsScreen.refreshNowKey);

    expect(tester.takeException(), isNull);
    expect(find.text('Refresh now'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(SettingsScreen.refreshNowKey))
          .onPressed,
      isNotNull,
    );
  });

  group('the wipe is two clicks, not one', () {
    testWidgets('the first tap swaps the button for a confirm pair, and Keep '
        'puts it back', (tester) async {
      var wipes = 0;
      await open(tester, onSignOutAndClear: () async => wipes++);
      await expand(tester, 'Sync & data');

      await tapKey(tester, SettingsScreen.signOutClearKey);

      // The button that was tapped is GONE. That is the protection: the second
      // click is on a different, red button in a different place.
      expect(find.byKey(SettingsScreen.signOutClearKey), findsNothing);
      expect(find.text('Yes, clear and sign out'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
      expect(wipes, 0);

      await tapKey(tester, SettingsScreen.signOutKeepKey);

      expect(find.byKey(SettingsScreen.signOutClearKey), findsOneWidget);
      expect(find.text('Yes, clear and sign out'), findsNothing);
      expect(wipes, 0);
    });

    testWidgets('the confirm fires once, disables both buttons while it runs, '
        'and re-arms afterwards', (tester) async {
      final pending = Completer<void>();
      var wipes = 0;
      await open(tester, onSignOutAndClear: () {
        wipes++;
        return pending.future;
      });
      await expand(tester, 'Sync & data');
      await tapKey(tester, SettingsScreen.signOutClearKey);
      await tapKey(tester, SettingsScreen.signOutConfirmKey);

      expect(wipes, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(SettingsScreen.signOutConfirmKey),
            )
            .onPressed,
        isNull,
        reason: 'a second click while the wipe is out would race the first',
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(SettingsScreen.signOutKeepKey))
            .onPressed,
        isNull,
      );

      pending.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(SettingsScreen.signOutClearKey), findsOneWidget);
      expect(wipes, 1);
    });

    testWidgets('a failed wipe says so and leaves the pair up', (tester) async {
      await open(
        tester,
        onSignOutAndClear: () async => throw StateError('keychain'),
      );
      await expand(tester, 'Sync & data');
      await tapKey(tester, SettingsScreen.signOutClearKey);
      await tapKey(tester, SettingsScreen.signOutConfirmKey);

      expect(find.byType(InlineAlert), findsOneWidget);
      expect(find.text('Sign-out failed.'), findsOneWidget);
      // Still armed: the user is about to press it again.
      expect(find.byKey(SettingsScreen.signOutConfirmKey), findsOneWidget);
      expect(find.byKey(SettingsScreen.signOutKeepKey), findsOneWidget);

      // Standing down takes the failure with it: a stale "failed" under a
      // single disarmed button would read as a live problem.
      await tapKey(tester, SettingsScreen.signOutKeepKey);
      expect(find.byType(InlineAlert), findsNothing);
      expect(find.byKey(SettingsScreen.signOutClearKey), findsOneWidget);
    });
  });

  testWidgets('the wipe block is absent when the host wires no sign-out, and '
      'the section is absent when it wires no refresh', (tester) async {
    await open(tester);
    await expand(tester, 'Sync & data');

    expect(find.byKey(SettingsScreen.refreshNowKey), findsOneWidget);
    expect(find.byKey(SettingsScreen.signOutClearKey), findsNothing);
    expect(find.text('This device'), findsNothing);

    await open(tester, wireRefresh: false);
    expect(find.text('Sync & data'), findsNothing);
  });

  testWidgets('About names the build and where the mailbox lives',
      (tester) async {
    await open(
      tester,
      appVersion: '1.2.3 (4)',
      databasePath: '/tmp/bond_inbox.db',
    );

    expect(find.text('Bond 1.2.3 (4)'), findsOneWidget);

    await expand(tester, 'About');

    expect(find.text('Version 1.2.3 (4)'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, '/tmp/bond_inbox.db'),
      findsOneWidget,
    );
    expect(
      find.text('Local model servers are configured in the Models section '
          'above.'),
      findsOneWidget,
    );
    expect(
      find.text('The pipeline is documented in docs/pipeline in the '
          'repository.'),
      findsOneWidget,
    );
  });

  testWidgets('About renders on half an answer, and not at all on none',
      (tester) async {
    // The ordinary widget-test case: no platform on the other end of the
    // channel, so the version is unknown but the path override is not.
    await open(tester, databasePath: '/tmp/bond_inbox.db');

    expect(find.text('Version unknown'), findsOneWidget);
    await expand(tester, 'About');
    // Twice now: the summary stays visible while the body is open, and the
    // body's own version line says the same thing.
    expect(find.text('Version unknown'), findsNWidgets(2));
    expect(
      find.widgetWithText(SelectableText, '/tmp/bond_inbox.db'),
      findsOneWidget,
    );

    await open(tester);
    expect(find.text('About'), findsNothing);
  });

  testWidgets('both sections survive a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(
      tester,
      mail: _ago(const Duration(days: 2)),
      onSignOutAndClear: () async {},
      appVersion: '1.2.3 (4)',
      databasePath: '/tmp/bond_inbox.db',
    );
    await expand(tester, 'Sync & data');
    await expand(tester, 'About');

    expect(tester.takeException(), isNull);
  });
}
