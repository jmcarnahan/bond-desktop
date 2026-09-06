import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// How far back each connector syncs, as the Sync & data section offers it.
///
/// The subject worth pinning is the pair of contracts a control with no Save
/// of its own has to keep: a preset commits the moment it is picked, and a
/// custom date commits on Enter, on focus leaving the field, and on the three
/// clicks that take the field off the screen without moving focus. Beside them
/// sits the line that is the whole point of the setting — the calendar day the
/// window actually reaches — which is only exact because the clock is pinned.
///
/// A date that does not parse commits NOTHING, which is where this control
/// parts company with the custom server URL beside it: a half-typed URL is a
/// server nobody can reach, but a half-typed date is not a window at all.

final DateTime _now = DateTime.utc(2026, 9, 5, 12, 0);

void main() {
  Future<void> open(
    WidgetTester tester, {
    int mailDays = 14,
    int teamsDays = 14,
    void Function(int days)? onMail,
    void Function(int days)? onTeams,
    bool wireMail = true,
    bool wireTeams = true,
    VoidCallback? onBack,
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
          onBack: onBack ?? () {},
          now: () => _now,
          // Sync & data exists at all only because a refresh is wired.
          onRefreshNow: () async {},
          mailLookbackDays: mailDays,
          teamsLookbackDays: teamsDays,
          onMailLookbackChanged: wireMail ? (onMail ?? (_) {}) : null,
          onTeamsLookbackChanged: wireTeams ? (onTeams ?? (_) {}) : null,
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

  const mailKey = ValueKey('settings-mail-lookback');
  const teamsKey = ValueKey('settings-teams-lookback');
  const mailCustomKey = ValueKey('settings-mail-lookback-custom');

  /// Picks [label] out of the dropdown at [key]. The menu route puts a second
  /// copy of every item on screen, so the tap goes to the last match — the one
  /// in the open menu rather than the one under it in the closed button.
  Future<void> pick(WidgetTester tester, Key key, String label) async {
    await tapKey(tester, key);
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> typeCustom(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(mailCustomKey), text);
    await tester.pump();
  }

  testWidgets('both sides open on what is stored, and say which day that '
      'reaches', (tester) async {
    await open(tester);
    await expand(tester, 'Sync & data');

    expect(find.text('How far back to sync'), findsOneWidget);
    expect(find.byKey(mailKey), findsOneWidget);
    expect(find.byKey(teamsKey), findsOneWidget);
    // Once per side. The day, not the span, is the thing the user is asking
    // about when they set this.
    expect(find.text('Last 14 days · since Aug 22, 2026'), findsNWidgets(2));
    // Nothing is typed until Custom… is chosen.
    expect(find.byKey(mailCustomKey), findsNothing);
  });

  testWidgets('a preset commits the moment it is picked, on that side alone',
      (tester) async {
    final mail = <int>[];
    final teams = <int>[];
    await open(tester, onMail: mail.add, onTeams: teams.add);
    await expand(tester, 'Sync & data');

    await pick(tester, mailKey, '90 days');

    expect(mail, [90]);
    expect(teams, isEmpty);
    expect(find.text('Last 90 days · since Jun 7, 2026'), findsOneWidget);
    // The other side did not move with it.
    expect(find.text('Last 14 days · since Aug 22, 2026'), findsOneWidget);
  });

  testWidgets('Teams is its own setting', (tester) async {
    final mail = <int>[];
    final teams = <int>[];
    await open(tester, onMail: mail.add, onTeams: teams.add);
    await expand(tester, 'Sync & data');

    await pick(tester, teamsKey, '30 days');

    expect(teams, [30]);
    expect(mail, isEmpty);
    expect(find.text('Last 30 days · since Aug 6, 2026'), findsOneWidget);
  });

  testWidgets('Custom… only reveals the field, prefilled with the window in '
      'force', (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');

    await pick(tester, mailKey, 'Custom…');

    expect(find.byKey(mailCustomKey), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(mailCustomKey)).controller!.text,
      '2026-08-22',
    );
    // Revealing a field is not choosing anything.
    expect(mail, isEmpty);
    expect(find.text('Last 14 days · since Aug 22, 2026'), findsNWidgets(2));
  });

  testWidgets('a typed date commits on Enter, as the days it resolves to',
      (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');

    await typeCustom(tester, '2026-08-07');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Once, not twice: Enter both submits and drops focus.
    expect(mail, [29]);
    expect(find.text('Last 29 days · since Aug 7, 2026'), findsOneWidget);
  });

  testWidgets('a date that is not a past date within the last year commits '
      'nothing', (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');

    await typeCustom(tester, 'not-a-date');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(mail, isEmpty);
    expect(
      find.text('Use YYYY-MM-DD, a past date within the last year'),
      findsOneWidget,
    );
    // The window in force is untouched, and still says so.
    expect(find.text('Last 14 days · since Aug 22, 2026'), findsNWidgets(2));

    // A date in the future is the same refusal: there is no mail there.
    await typeCustom(tester, '2026-12-25');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(mail, isEmpty);
    expect(
      find.text('Use YYYY-MM-DD, a past date within the last year'),
      findsOneWidget,
    );

    // And a day that does not exist, which DateTime.utc would otherwise roll
    // forward into March without a word.
    await typeCustom(tester, '2026-02-31');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(mail, isEmpty);
  });

  testWidgets('a valid date after a refused one commits and drops the error',
      (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');

    await typeCustom(tester, 'not-a-date');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(mail, isEmpty);

    // The recovery every real user makes: fix the text, press Enter again.
    // The error must not outlive the commit that resolves it.
    await typeCustom(tester, '2026-08-07');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(mail, [29]);
    expect(
      find.text('Use YYYY-MM-DD, a past date within the last year'),
      findsNothing,
    );
    expect(find.text('Last 29 days · since Aug 7, 2026'), findsOneWidget);
  });

  testWidgets('leaving the field commits it, with no Enter', (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');

    await typeCustom(tester, '2026-08-07');
    expect(mail, isEmpty, reason: 'nothing commits per keystroke');

    // Focus moves to another control, which is what a user does when they are
    // done typing and reach for the next thing. The Teams dropdown rather than
    // the Refresh button because a button press does not take focus on the
    // platform a widget test reports itself as.
    await tapKey(tester, teamsKey);

    expect(mail, [29]);
    expect(find.text('Last 29 days · since Aug 7, 2026'), findsOneWidget);
  });

  testWidgets('collapsing the section commits the typed date', (tester) async {
    final mail = <int>[];
    await open(tester, onMail: mail.add);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');
    await typeCustom(tester, '2026-08-07');

    // The click that takes the field off the screen without ever moving focus.
    await expand(tester, 'Sync & data');

    expect(mail, [29]);
  });

  testWidgets('Back commits the typed date on the way out', (tester) async {
    final mail = <int>[];
    var backs = 0;
    await open(tester, onMail: mail.add, onBack: () => backs++);
    await expand(tester, 'Sync & data');
    await pick(tester, mailKey, 'Custom…');
    await typeCustom(tester, '2026-08-07');

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(mail, [29]);
    expect(backs, 1);
  });

  testWidgets('a stored value outside the presets opens on Custom…',
      (tester) async {
    await open(tester, mailDays: 45);
    await expand(tester, 'Sync & data');

    // Never handed to the dropdown as a value of its own — a value none of the
    // items carries is an assertion failure, not a blank row.
    expect(find.byKey(mailCustomKey), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(mailCustomKey)).controller!.text,
      '2026-07-22',
    );
    expect(find.text('Last 45 days · since Jul 22, 2026'), findsOneWidget);
  });

  testWidgets('an unwired side has no control, and the section still renders',
      (tester) async {
    await open(tester, wireMail: false);
    await expand(tester, 'Sync & data');

    expect(find.byKey(mailKey), findsNothing);
    expect(find.byKey(teamsKey), findsOneWidget);
    expect(find.text('How far back to sync'), findsOneWidget);
    expect(find.byKey(SettingsScreen.refreshNowKey), findsOneWidget);
  });

  testWidgets('neither side wired takes the sub-heading with it, and leaves '
      'the rest of the section', (tester) async {
    await open(tester, wireMail: false, wireTeams: false);
    await expand(tester, 'Sync & data');

    expect(find.text('How far back to sync'), findsNothing);
    expect(find.byKey(mailKey), findsNothing);
    expect(find.byKey(teamsKey), findsNothing);
    expect(find.byKey(SettingsScreen.refreshNowKey), findsOneWidget);
  });

  testWidgets('the pair survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester, mailDays: 45);
    await expand(tester, 'Sync & data');

    expect(tester.takeException(), isNull);
  });
}
