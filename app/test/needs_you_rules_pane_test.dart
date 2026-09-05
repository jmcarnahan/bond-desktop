import 'package:bond_inbox/widgets/needs_you_rules_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What this pane guards is the exact text the model reads: the owner's rules
/// are fenced straight into every below-the-floor needs-you judgement, so an
/// editor that saved something the user did not mean to save — a half-typed
/// thought abandoned with Back, a stray trailing newline — would change how
/// every message is judged.
///
/// Hence the two contracts pinned hardest here: **Save is the only thing that
/// commits** (Cancel, the back arrow, and dispose all discard), and the trim
/// happens HERE, because the store keeps whatever it is handed verbatim.
///
/// The defaults disclosure is pinned too. It must show the rules VERBATIM —
/// they are what the owner's text refines, and a paraphrase would make the
/// pane lie about the prompt.
void main() {
  const defaults = 'Line one of the defaults.\nLine two of the defaults.';

  /// The pane over plain closures — it reaches for no providers, so nothing
  /// else has to exist for it to be driven.
  Future<void> pump(
    WidgetTester tester, {
    String value = '',
    String defaultRules = defaults,
    int maxLength = 800,
    required void Function(String) onSave,
    required VoidCallback onBack,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NeedsYouRulesPane(
          value: value,
          defaultRules: defaultRules,
          maxLength: maxLength,
          onSave: onSave,
          onBack: onBack,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

  bool clearEnabled(WidgetTester tester) => tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('Clear my rules'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed !=
      null;

  testWidgets('renders the title, the stored rules, and the controls',
      (tester) async {
    await pump(
      tester,
      value: 'Anything about the budget needs me.',
      onSave: (_) {},
      onBack: () {},
    );

    expect(find.text('Needs You rules'), findsOneWidget);
    expect(find.text('Anything about the budget needs me.'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Clear my rules'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('What Bond already asks'), findsOneWidget);
    // Collapsed to start: the defaults are reference material, not the point
    // of the screen.
    expect(find.text(defaults), findsNothing);
  });

  testWidgets('Save stays disabled until the field differs from what is stored',
      (tester) async {
    await pump(
      tester,
      value: 'Original rules.',
      onSave: (_) {},
      onBack: () {},
    );

    expect(saveEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'Original rules. And more.');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);

    // Typing the original back is not a change, whatever route got there.
    await tester.enterText(find.byType(TextField), 'Original rules.');
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('Save trims, fires once, and then leaves the pane',
      (tester) async {
    final saved = <String>[];
    var backs = 0;
    await pump(
      tester,
      value: 'old',
      onSave: saved.add,
      onBack: () => backs++,
    );

    await tester.enterText(find.byType(TextField), '  rules text \n');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(saved, ['rules text']);
    expect(backs, 1);
  });

  testWidgets('Cancel discards the edit', (tester) async {
    final saved = <String>[];
    var backs = 0;
    await pump(
      tester,
      value: 'old',
      onSave: saved.add,
      onBack: () => backs++,
    );

    await tester.enterText(find.byType(TextField), 'something new');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(saved, isEmpty);
    expect(backs, 1);
  });

  testWidgets('the back arrow discards the edit too', (tester) async {
    final saved = <String>[];
    var backs = 0;
    await pump(
      tester,
      value: 'old',
      onSave: saved.add,
      onBack: () => backs++,
    );

    await tester.enterText(find.byType(TextField), 'something new');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();

    expect(saved, isEmpty);
    expect(backs, 1);
  });

  testWidgets('nothing is saved on dispose', (tester) async {
    final saved = <String>[];
    await pump(
      tester,
      value: 'old',
      onSave: saved.add,
      onBack: () {},
    );

    await tester.enterText(find.byType(TextField), 'abandoned half-thought');
    await tester.pump();
    // The pane goes away without anyone pressing anything — the host swapping
    // the main pane, which is exactly what the rail does.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('somewhere else'))),
    );
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
  });

  testWidgets('Clear empties the field only; Save is what commits it',
      (tester) async {
    final saved = <String>[];
    await pump(
      tester,
      value: 'Anything about the budget needs me.',
      onSave: saved.add,
      onBack: () {},
    );

    await tester.tap(find.text('Clear my rules'));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(saved, isEmpty);
    expect(saveEnabled(tester), isTrue);

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saved, ['']);
  });

  testWidgets('Clear is disabled when there is nothing to clear',
      (tester) async {
    await pump(tester, value: '', onSave: (_) {}, onBack: () {});

    expect(clearEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'a rule');
    await tester.pump();
    expect(clearEnabled(tester), isTrue);
  });

  testWidgets('the disclosure shows the defaults verbatim', (tester) async {
    await pump(tester, value: '', onSave: (_) {}, onBack: () {});

    expect(find.text(defaults), findsNothing);
    await tester.tap(find.text('What Bond already asks'));
    await tester.pumpAndSettle();

    // Verbatim, not a summary: this is the text the model actually reads.
    expect(find.text(defaults), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('the field enforces the cap the prompt clamps to',
      (tester) async {
    await pump(
      tester,
      value: '',
      maxLength: 20,
      onSave: (_) {},
      onBack: () {},
    );

    await tester.enterText(find.byType(TextField), 'x' * 30);
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text.length,
      20,
    );
  });
}
