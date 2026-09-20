import 'package:bond_inbox/screens/consent_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one question the app asks before a draft leaves this machine.
///
/// The copy is the feature here, so it is pinned word for word: what goes,
/// what never goes, the two measured numbers a person is choosing between, and
/// the cap. A change to any of them is a change to what somebody consented to.

void main() {
  Future<void> open(
    WidgetTester tester, {
    String targetName = 'Bedrock Opus',
    String stageLabel = 'Draft generation',
    int dailyCap = 50,
    VoidCallback? onContinue,
    VoidCallback? onNotNow,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CloudDraftsConsentPane(
          targetName: targetName,
          stageLabel: stageLabel,
          dailyCap: dailyCap,
          onContinue: onContinue ?? () {},
          onNotNow: onNotNow ?? () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('it names the target and the stage it would answer',
      (tester) async {
    await open(tester);

    expect(find.text('Send drafts to Bedrock Opus?'), findsOneWidget);
    expect(
      find.text('This target would answer the Draft generation stage.'),
      findsOneWidget,
    );
    // One flag covers both draft stages, and the pane says so: the scope of
    // a yes is the scope the person read.
    expect(
      find.text('Allowing it covers Draft reply and Improve a draft alike. '
          'No other stage sends drafts anywhere.'),
      findsOneWidget,
    );
  });

  testWidgets('it says what goes and what never goes', (tester) async {
    await open(tester);

    expect(
      find.text(
        'Every draft sent to this target leaves this machine. What goes: the '
        'message being answered, the last few messages of its thread, the '
        'storyline summary if there is one, and short excerpts from your '
        'registered directories. What never goes: the rest of the mailbox, '
        'your sign in, and your settings.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the two measured rows sit in a table with their date',
      (tester) async {
    await open(tester);

    final table = find.byKey(CloudDraftsConsentPane.measuredKey);
    expect(table, findsOneWidget);
    for (final cell in [
      'Local 27B',
      '6 of 25 drafts passed',
      'Opus 5',
      '17 of 25 drafts passed',
    ]) {
      expect(
        find.descendant(of: table, matching: find.text(cell)),
        findsOneWidget,
        reason: '$cell is missing from the measured table',
      );
    }
    expect(
      find.text('Measured on 25 replies from the golden set, 2026-09-17.'),
      findsOneWidget,
    );
  });

  testWidgets('the cap is the host\'s number, not a hardcoded one',
      (tester) async {
    await open(tester, dailyCap: 12);

    expect(
      find.text(
        'At most 12 drafts a day go to a third-party target. You can change '
        'the cap under Settings, Processing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Continue and Not now each reach their own callback',
      (tester) async {
    var continued = 0;
    var declined = 0;
    await open(
      tester,
      onContinue: () => continued++,
      onNotNow: () => declined++,
    );

    await tester.tap(find.byKey(CloudDraftsConsentPane.continueKey));
    await tester.pumpAndSettle();
    expect((continued, declined), (1, 0));

    await tester.tap(find.byKey(CloudDraftsConsentPane.notNowKey));
    await tester.pumpAndSettle();
    expect((continued, declined), (1, 1));
  });

  testWidgets('the pane survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester);

    expect(tester.takeException(), isNull);
  });
}
