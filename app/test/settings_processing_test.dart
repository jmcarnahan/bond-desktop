import 'dart:async';

import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Processing section: the mirror switch, and the two resets behind it.
///
/// The screen is a plain widget over closures, with no provider reads inside,
/// so this file pumps it alone — which is what makes `pumpAndSettle` safe here
/// and nowhere near `InboxScreen`.
///
/// The subject is the two-step, and the one rule the section adds to it: a
/// reset races every drain it does not stop, so both buttons are inert while
/// processing is on and say why.

/// Counts the routes anything in here pushes. The house rule forbids a
/// confirmation dialog, and the two-step IS the confirmation — a route pushed
/// by either button would be the rule broken however it was drawn.
class _RouteCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    // The screen's own route is the first push.
    if (previous != null) pushes++;
  }
}

void main() {
  late _RouteCounter routes;

  Future<void> open(
    WidgetTester tester, {
    bool processingOn = false,
    ValueChanged<bool>? onProcessingChanged,
    Future<void> Function()? onClearAiResults,
    Future<void> Function()? onForgetAndResync,
  }) async {
    routes = _RouteCounter();
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routes],
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
          processingOn: processingOn,
          onProcessingChanged: onProcessingChanged ?? (_) {},
          onClearAiResults: onClearAiResults ?? () async {},
          onForgetAndResync: onForgetAndResync ?? () async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final toggle = find.byKey(SettingsSection.toggleKey('Processing'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, Key key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

  testWidgets('the section is absent when the host wires nothing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Processing'), findsNothing);
  });

  testWidgets('both resets are inert while processing is on, and say why',
      (tester) async {
    await open(tester, processingOn: true);

    expect(enabled(tester, SettingsScreen.clearAiResultsKey), isFalse);
    expect(enabled(tester, SettingsScreen.forgetResyncKey), isFalse);
    // Once under each button: the reason has to sit where the refusal is.
    expect(find.text('Turn processing off first'), findsNWidgets(2));
  });

  testWidgets('and both are live with it off', (tester) async {
    await open(tester);

    expect(enabled(tester, SettingsScreen.clearAiResultsKey), isTrue);
    expect(enabled(tester, SettingsScreen.forgetResyncKey), isTrue);
    expect(find.text('Turn processing off first'), findsNothing);
  });

  testWidgets('the first tap arms and the second clears', (tester) async {
    var cleared = 0;
    await open(tester, onClearAiResults: () async => cleared++);

    await tapKey(tester, SettingsScreen.clearAiResultsKey);

    // A different button, in a different place, that did not exist a moment
    // ago — the whole of the protection a modal would have given.
    expect(cleared, 0);
    expect(find.byKey(SettingsScreen.clearAiResultsKey), findsNothing);
    expect(find.byKey(SettingsScreen.clearAiResultsConfirmKey), findsOneWidget);

    await tapKey(tester, SettingsScreen.clearAiResultsConfirmKey);

    expect(cleared, 1);
    // Disarmed on the way out, so the pair is not left standing over work
    // that is already done.
    expect(find.byKey(SettingsScreen.clearAiResultsKey), findsOneWidget);
    expect(routes.pushes, 0);
  });

  testWidgets('the forget button takes the same two clicks', (tester) async {
    var forgot = 0;
    await open(tester, onForgetAndResync: () async => forgot++);

    await tapKey(tester, SettingsScreen.forgetResyncKey);
    expect(forgot, 0);

    await tapKey(tester, SettingsScreen.forgetResyncConfirmKey);

    expect(forgot, 1);
    expect(find.byKey(SettingsScreen.forgetResyncKey), findsOneWidget);
    expect(routes.pushes, 0);
  });

  testWidgets('arming one reset leaves the other alone', (tester) async {
    await open(tester);

    await tapKey(tester, SettingsScreen.clearAiResultsKey);

    expect(find.byKey(SettingsScreen.clearAiResultsConfirmKey), findsOneWidget);
    expect(find.byKey(SettingsScreen.forgetResyncKey), findsOneWidget);
    expect(find.byKey(SettingsScreen.forgetResyncConfirmKey), findsNothing);
  });

  testWidgets('arming the other reset is refused while one is clearing',
      (tester) async {
    // The two delete overlapping rows, and a second one armed mid-transaction
    // is a race the database would have to settle.
    final held = Completer<void>();
    await open(tester, onClearAiResults: () => held.future);
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });

    await tapKey(tester, SettingsScreen.clearAiResultsKey);
    await tapKey(tester, SettingsScreen.clearAiResultsConfirmKey);

    // Still out: the confirm is inert and so is the other reset's arm.
    expect(enabled(tester, SettingsScreen.clearAiResultsConfirmKey), isFalse);
    expect(enabled(tester, SettingsScreen.forgetResyncKey), isFalse);

    held.complete();
    await tester.pumpAndSettle();

    expect(enabled(tester, SettingsScreen.forgetResyncKey), isTrue);
  });

  testWidgets('both captions say the reset takes a while', (tester) async {
    await open(tester);

    // The only sign a person gets: the button is disabled for as long as the
    // refold and the index rebuilds take, with nothing streaming in between.
    expect(
      find.textContaining('this can take a minute or two'),
      findsNWidgets(2),
    );
  });

  testWidgets('a failure shows an alert and leaves the button armed',
      (tester) async {
    await open(
      tester,
      onClearAiResults: () async => throw StateError('the disk said no'),
    );

    await tapKey(tester, SettingsScreen.clearAiResultsKey);
    await tapKey(tester, SettingsScreen.clearAiResultsConfirmKey);

    expect(find.byType(InlineAlert), findsOneWidget);
    // Still armed: the user is about to press it again.
    expect(find.byKey(SettingsScreen.clearAiResultsConfirmKey), findsOneWidget);
    expect(routes.pushes, 0);
  });

  testWidgets('Keep disarms and drops the last failure', (tester) async {
    await open(
      tester,
      onClearAiResults: () async => throw StateError('the disk said no'),
    );

    await tapKey(tester, SettingsScreen.clearAiResultsKey);
    await tapKey(tester, SettingsScreen.clearAiResultsConfirmKey);
    expect(find.byType(InlineAlert), findsOneWidget);

    await tapKey(tester, SettingsScreen.clearAiResultsKeepKey);

    // Standing down drops the failure with it: a stale "failed" under a
    // single disarmed button would read as a live problem.
    expect(find.byType(InlineAlert), findsNothing);
    expect(find.byKey(SettingsScreen.clearAiResultsKey), findsOneWidget);
  });

  testWidgets('the mirror switch reports the flip immediately',
      (tester) async {
    final written = <bool>[];
    await open(tester, onProcessingChanged: written.add);

    expect(find.text('AI processing'), findsOneWidget);
    expect(find.text('Off'), findsWidgets);

    await tapKey(tester, SettingsScreen.processingToggleKey);

    // The switch behind this pane is the thing it changes, so the host hears
    // about it the instant it moves rather than on the way out.
    expect(written, [true]);
  });
}
