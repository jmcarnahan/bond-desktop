import 'package:bond_inbox/widgets/needs_you_rules_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What this editor guards is the exact text the model reads: the owner's
/// rules ARE the body of the needs-you system prompt, so an editor that saved
/// something the user did not mean to save — a half-typed thought abandoned by
/// closing the section, a stray trailing newline — would change how every
/// message is judged.
///
/// Hence the contracts pinned hardest here: **Save is the only thing that
/// commits** (Cancel reverts and dispose discards), the trim happens HERE
/// because the store keeps whatever it is handed verbatim, and a body
/// identical to the defaults is stored as the EMPTY preference so the default
/// path keeps serving its one const prompt.
///
/// The field is prefilled with the defaults, because they are the text in
/// force. The fixed tail is disclosed verbatim: the owner may replace every
/// word above it and not one word of it.
void main() {
  const defaults = 'Line one of the defaults.\nLine two of the defaults.';
  const tail = '\n\nBond answers in a fixed form.';

  /// The editor over plain closures — it reaches for no providers, so nothing
  /// else has to exist for it to be driven. Pumping a second time at the same
  /// tree position is how the tests drive [State.didUpdateWidget].
  Future<void> pump(
    WidgetTester tester, {
    String value = '',
    String defaultRules = defaults,
    String fixedTail = tail,
    int maxLength = 4000,
    required void Function(String) onSave,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NeedsYouRulesEditor(
          value: value,
          defaultRules: defaultRules,
          fixedTail: fixedTail,
          maxLength: maxLength,
          onSave: onSave,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

  bool resetEnabled(WidgetTester tester) => tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('Reset to default'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed !=
      null;

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('renders the blurb, the stored rules, and the controls',
      (tester) async {
    await pump(
      tester,
      value: 'Anything about the budget needs me.',
      onSave: (_) {},
    );

    expect(
      find.textContaining('These are the rules the model reads'),
      findsOneWidget,
    );
    expect(find.text('Anything about the budget needs me.'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Reset to default'), findsOneWidget);
    expect(find.text('What Bond adds after your rules'), findsOneWidget);
    // No header of its own: this is the body of a settings section, and the
    // section's own title already names it. A back arrow here would offer a
    // way out of something that is not a pane.
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.text('Needs You rules'), findsNothing);
    // Collapsed to start: the tail is reference material, not the point of the
    // editor.
    expect(find.text(tail.trimLeft()), findsNothing);
  });

  testWidgets('prefills the default body when nothing is stored',
      (tester) async {
    // An empty preference means the defaults are what the model reads, so the
    // defaults are what the editor opens on — and opening on them is not an
    // edit.
    await pump(tester, value: '', onSave: (_) {});

    expect(fieldText(tester), defaults);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('Save stays disabled until the field differs from what it opened '
      'on', (tester) async {
    await pump(tester, value: 'Original rules.', onSave: (_) {});

    expect(saveEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'Original rules. And more.');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);

    // Typing the original back is not a change, whatever route got there.
    await tester.enterText(find.byType(TextField), 'Original rules.');
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('Save trims, fires once, and stays put', (tester) async {
    final saved = <String>[];
    await pump(tester, value: 'old', onSave: saved.add);

    await tester.enterText(find.byType(TextField), '  rules text \n');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(saved, ['rules text']);
    // Saving is not leaving: the editor lives inside an open settings section,
    // which stays open, and Save disables again because the field now shows
    // what was saved.
    expect(find.byType(NeedsYouRulesEditor), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('Cancel reverts the field to the last saved text',
      (tester) async {
    final saved = <String>[];
    await pump(tester, value: 'old', onSave: saved.add);

    await tester.enterText(find.byType(TextField), 'something new');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(fieldText(tester), 'old');
    expect(saved, isEmpty);
    expect(find.byType(NeedsYouRulesEditor), findsOneWidget);
  });

  testWidgets('a second Save after a second edit fires again', (tester) async {
    // The baseline moves with each Save, so the editor stays usable for a
    // second thought without being closed and reopened.
    final saved = <String>[];
    await pump(tester, value: 'old', onSave: saved.add);

    await tester.enterText(find.byType(TextField), 'first edit');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'second edit');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(saved, ['first edit', 'second edit']);
  });

  testWidgets('Cancel after a Save reverts to the saved text, not the original',
      (tester) async {
    final saved = <String>[];
    await pump(tester, value: 'old', onSave: saved.add);

    await tester.enterText(find.byType(TextField), 'kept edit');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'abandoned edit');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(fieldText(tester), 'kept edit');
    expect(saved, ['kept edit']);
  });

  testWidgets('a clean field adopts a value changed underneath it',
      (tester) async {
    // A sign-in from inside Settings wipes the previous person's rules to the
    // empty preference. Nobody was typing, so the field must follow rather
    // than keep showing text that is no longer stored.
    await pump(tester, value: 'the previous person rules', onSave: (_) {});
    expect(fieldText(tester), 'the previous person rules');

    await pump(tester, value: '', onSave: (_) {});

    expect(fieldText(tester), defaults);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('a dirty field keeps its edit when the value changes underneath '
      'it', (tester) async {
    await pump(tester, value: 'old', onSave: (_) {});

    await tester.enterText(find.byType(TextField), 'half-typed thought');
    await tester.pump();
    await pump(tester, value: 'something the host now stores', onSave: (_) {});

    // An unsaved edit is the user's. Nothing gets to overwrite it.
    expect(fieldText(tester), 'half-typed thought');
  });

  testWidgets('nothing is saved on dispose', (tester) async {
    final saved = <String>[];
    await pump(tester, value: 'old', onSave: saved.add);

    await tester.enterText(find.byType(TextField), 'abandoned half-thought');
    await tester.pump();
    // The editor goes away without anyone pressing anything — the host
    // swapping the main pane, which is exactly what the rail does.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('somewhere else'))),
    );
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
  });

  testWidgets('Reset to default is local, and Save commits it', (tester) async {
    final saved = <String>[];
    await pump(
      tester,
      value: 'Anything about the budget needs me.',
      onSave: saved.add,
    );

    await tester.tap(find.text('Reset to default'));
    await tester.pump();

    expect(fieldText(tester), defaults);
    expect(saved, isEmpty);
    expect(saveEnabled(tester), isTrue);

    await tester.tap(find.text('Save'));
    await tester.pump();
    // The empty string, not the defaults themselves: an empty preference is how
    // the app says "the default body is in force", and it is what keeps the
    // const prompt serving.
    expect(saved, ['']);
  });

  testWidgets('Reset to default is disabled when the field already shows it',
      (tester) async {
    await pump(tester, value: '', onSave: (_) {});

    expect(resetEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'a rule');
    await tester.pump();
    expect(resetEnabled(tester), isTrue);
  });

  testWidgets('a save that retypes the defaults stores the empty pref',
      (tester) async {
    // However the field arrived at the default text — the button, or typing it
    // out — the same normalization applies.
    final saved = <String>[];
    await pump(tester, value: 'custom', onSave: saved.add);

    await tester.enterText(find.byType(TextField), defaults);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(saved, ['']);
  });

  testWidgets('the disclosure shows the fixed tail verbatim', (tester) async {
    await pump(tester, value: '', onSave: (_) {});

    expect(find.text(tail.trimLeft()), findsNothing);
    await tester.tap(find.text('What Bond adds after your rules'));
    await tester.pumpAndSettle();

    // Verbatim, not a summary: this is the text the model actually reads after
    // whatever the owner wrote. Left-trimmed only — the leading blank line is
    // a concatenation separator rather than prose.
    expect(find.text(tail.trimLeft()), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('the field enforces the cap the prompt clamps to',
      (tester) async {
    await pump(
      tester,
      value: '',
      defaultRules: 'short defaults',
      maxLength: 20,
      onSave: (_) {},
    );

    await tester.enterText(find.byType(TextField), 'x' * 30);
    await tester.pump();

    expect(fieldText(tester).length, 20);
  });
}
