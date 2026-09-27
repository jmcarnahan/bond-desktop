import 'package:bond_inbox/widgets/find_field.dart';
import 'package:bond_inbox/widgets/triage_intents.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The quick switcher's box.
///
/// It is a view of a controller its host owns, so nothing here is about state
/// — it is about the four ways out of the field: a keystroke, Enter, Escape,
/// and the ×.

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmit,
    VoidCallback? onClear,
    List<String> labelNames = const [],
    ValueChanged<Intent>? onCommand,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 236,
          child: FindField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged ?? (_) {},
            onSubmit: onSubmit ?? (_) {},
            onClear: onClear ?? () {},
            labelNames: labelNames,
            onCommand: onCommand,
          ),
        ),
      ),
    ));
  }

  testWidgets('the hint names the shortcut, because nothing else can',
      (tester) async {
    await pumpField(tester);

    expect(find.text('Find… ⌘K'), findsOneWidget);
  });

  testWidgets('the × appears only once there is something to clear',
      (tester) async {
    var cleared = 0;
    await pumpField(tester, onClear: () => cleared++);

    expect(find.byTooltip('Clear'), findsNothing);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.pump();

    expect(find.byTooltip('Clear'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();

    expect(cleared, 1);
  });

  testWidgets('every keystroke is reported — Find runs live', (tester) async {
    final seen = <String>[];
    await pumpField(tester, onChanged: seen.add);

    await tester.enterText(find.byKey(FindField.fieldKey), 'la');
    await tester.enterText(find.byKey(FindField.fieldKey), 'lau');
    await tester.pump();

    expect(seen, ['la', 'lau']);
  });

  testWidgets('Enter submits what is in the box', (tester) async {
    String? submitted;
    await pumpField(tester, onSubmit: (value) => submitted = value);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(submitted, 'launch');
  });

  testWidgets('Escape clears, and only while the box has focus',
      (tester) async {
    var cleared = 0;
    await pumpField(tester, onClear: () => cleared++);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(cleared, 1);
  });

  group('labelSuggestionsFor', () {
    const names = ['Jira update', 'Waiting on legal', 'Legal review'];

    test('nothing at all until the caret is inside a label term', () {
      for (final text in const ['', 'launch', 'from:eric', 'labels:x']) {
        expect(labelSuggestionsFor(text, names), isEmpty, reason: text);
      }
    });

    test('a bare label: offers the whole vocabulary', () {
      expect(labelSuggestionsFor('label:', names), names);
      expect(labelSuggestionsFor('-label:', names), names);
    });

    test('and typing narrows it, with the names being spelled first', () {
      // `Legal review` STARTS with what was typed and `Waiting on legal` merely
      // contains it. A vocabulary somebody wrote is full of second words, so
      // both belong — but the one being spelled leads.
      expect(
        labelSuggestionsFor('label:legal', names),
        ['Legal review', 'Waiting on legal'],
      );
    });

    test('an opening quote is a grouping gesture, not part of the name', () {
      // A reader who opened the quote first is spelling the same word, so the
      // strip must not go looking for the quote mark itself.
      expect(
        labelSuggestionsFor('label:"legal', names),
        labelSuggestionsFor('label:legal', names),
      );
      // And a space inside the quotes is still inside the term being typed.
      expect(labelSuggestionsFor('label:"waiting on', names),
          ['Waiting on legal']);
    });

    test('only the term the caret is in, never an earlier one', () {
      expect(labelSuggestionsFor('is:dismissed label:jira', names),
          ['Jira update']);
      // A finished term — the reader typed a space — has nothing left to
      // complete, which is what stops the strip reappearing under it.
      expect(labelSuggestionsFor('label:jira ', names), isEmpty);
    });

    test('an owner with no words gets nothing, whatever is typed', () {
      expect(labelSuggestionsFor('label:', const []), isEmpty);
    });

    test('and the strip is capped, because it is a rail and not a list', () {
      final many = [for (var i = 0; i < 20; i++) 'word$i'];

      expect(labelSuggestionsFor('label:', many), hasLength(6));
      expect(labelSuggestionsFor('label:', many, max: 2), hasLength(2));
    });
  });

  group('completeLabelFacet', () {
    test('finishes the term and leaves the caret ready for the next one', () {
      expect(completeLabelFacet('label:ji', 'Jira update'),
          'label:"Jira update" ');
      expect(completeLabelFacet('label:le', 'Legal'), 'label:Legal ');
    });

    test('a name with a space comes back quoted — the parser reads no other', () {
      // Completing `vendor outreach` bare would hand the Find parser a label
      // and a stray word.
      expect(completeLabelFacet('label:ven', 'Vendor outreach'),
          'label:"Vendor outreach" ');
    });

    test('keeps the terms in front of it, and the negation on it', () {
      expect(completeLabelFacet('invoice -label:le', 'Legal'),
          'invoice -label:Legal ');
    });

    test('and changes nothing at all when the caret is elsewhere', () {
      expect(completeLabelFacet('from:eric', 'Legal'), 'from:eric');
    });
  });

  group('the label strip', () {
    const names = ['Jira update', 'Waiting on legal', 'Legal review'];

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(FindField.fieldKey), text);
      await tester.pump();
    }

    testWidgets('a host that has not read the vocabulary gets the old box',
        (tester) async {
      String? submitted;
      await pumpField(tester, onSubmit: (value) => submitted = value);

      await type(tester, 'label:');

      expect(find.byKey(FindField.suggestionsKey), findsNothing);

      // And Enter still means Enter, which is the whole point of dormant.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(submitted, 'label:');
    });

    testWidgets('typing label: offers the words, under the box and not over it',
        (tester) async {
      await pumpField(tester, labelNames: names);

      expect(find.byKey(FindField.suggestionsKey), findsNothing);

      await type(tester, 'label:');

      expect(find.byKey(FindField.suggestionsKey), findsOneWidget);
      for (final name in names) {
        expect(find.byKey(FindField.suggestionKeyFor(name)), findsOneWidget);
      }
      // Inline, in the column it filters: the strip sits BELOW the field rather
      // than floating over the list, which is the house rule the field itself
      // exists to answer.
      expect(
        tester.getTopLeft(find.byKey(FindField.suggestionsKey)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(FindField.fieldKey)).dy - 1),
      );
    });

    testWidgets('and -label: offers them too', (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, '-label:');

      expect(find.byKey(FindField.suggestionsKey), findsOneWidget);
    });

    testWidgets('a word nothing answers leaves no strip', (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, 'label:zzz');

      expect(find.byKey(FindField.suggestionsKey), findsNothing);
    });

    testWidgets('a tap finishes the term, quoted, and reports the new needle',
        (tester) async {
      final seen = <String>[];
      await pumpField(tester, labelNames: names, onChanged: seen.add);

      await type(tester, 'label:wait');
      await tester.tap(find.byKey(FindField.suggestionKeyFor('Waiting on legal')));
      await tester.pump();

      expect(controller.text, 'label:"Waiting on legal" ');
      // A completion is a change to the needle like any other keystroke, so the
      // column narrows on it without the host doing anything.
      expect(seen.last, 'label:"Waiting on legal" ');
      // Finished, so there is nothing left to complete.
      expect(find.byKey(FindField.suggestionsKey), findsNothing);
    });

    testWidgets('Enter takes the suggestion instead of opening a row',
        (tester) async {
      var submits = 0;
      await pumpField(tester, labelNames: names, onSubmit: (_) => submits++);

      await type(tester, 'label:ji');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(controller.text, 'label:"Jira update" ');
      expect(submits, 0);

      // With no term in progress, Enter is Enter again — the key does the
      // nearer of its two jobs and never loses the further one.
      await type(tester, 'label:"Jira update" launch');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(submits, 1);
    });

    testWidgets('the arrows walk the strip, and Enter takes where they stopped',
        (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, 'label:legal');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      // Down once from `Legal review`, which led.
      expect(controller.text, 'label:"Waiting on legal" ');
    });

    testWidgets('and they wrap, so neither end is a dead press', (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, 'label:legal');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(controller.text, 'label:"Waiting on legal" ');
    });

    testWidgets('a keystroke puts the highlight back on the first word',
        (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, 'label:legal');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      // The reader has changed what they are asking for, and the entry they had
      // walked to is about to be a different name.
      await type(tester, 'label:legal ');
      await type(tester, 'label:legal');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(controller.text, 'label:"Legal review" ');
    });

    testWidgets('Escape still clears while the strip is showing',
        (tester) async {
      var cleared = 0;
      await pumpField(tester, labelNames: names, onClear: () => cleared++);

      await type(tester, 'label:');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(cleared, 1);
    });

    testWidgets('and nothing animates, so a list test can still settle',
        (tester) async {
      await pumpField(tester, labelNames: names);

      await type(tester, 'label:');
      await tester.pumpAndSettle();

      expect(find.byKey(FindField.suggestionsKey), findsOneWidget);
    });
  });

  group('commandsFor', () {
    test('a needle is a needle until it starts with >', () {
      expect(isCommandNeedle('launch'), isFalse);
      expect(isCommandNeedle('label:legal'), isFalse);
      expect(isCommandNeedle('>'), isTrue);
      // ⌘K selects the whole needle, so the leading space a reader leaves is
      // the app's problem rather than theirs.
      expect(isCommandNeedle('  >dis'), isTrue);
      expect(commandsFor('launch'), isEmpty);
    });

    test('> alone is the whole palette, not a sample of it', () {
      final all = commandsFor('>');

      // Every command, because a palette that hid two of its entries would
      // only serve a reader who already knew they were there.
      expect(all.length, findCommands.length);
      expect(all.first.label, 'Mark done');
      // Every command names a key, because teaching them is half the reason
      // the palette is worth having.
      expect(all.every((c) => c.keyHint != null), isTrue);
      expect([for (final c in all) c.keyHint], [
        'e', '⇧E', 'l', 's', 'm', ']', '[', 'z', 'r', 'x', '?',
      ]);
      expect(
        [for (final c in all.skip(8)) c.label],
        ['Quick reply', 'Select row', 'Keyboard shortcuts'],
      );
    });

    test('the words narrow it, and a leading match leads', () {
      // `Mark done with a label…`, `Quick reply` and `Select row` contain an l
      // as well and come after: what the reader is spelling is the start of a
      // pill, and the rest follow it rather than being refused — the label
      // strip's own rule.
      expect(
        [for (final c in commandsFor('>l')) c.label],
        [
          'Label…',
          'Later',
          'Mark done with a label…',
          'Quick reply',
          'Select row',
        ],
      );
      // Contained rather than leading: the reader typed the word they think in,
      // which is not always the first one on the pill.
      expect(
        [for (final c in commandsFor('>sender')) c.label],
        ['Drop sender'],
      );
      expect(commandsFor('>zzz'), isEmpty);
    });

    test('and every entry means an intent, never a handler', () {
      // The rule `triage_intents.dart` exists for: the palette is a third door
      // onto the same act, so it must not know what the act does.
      for (final command in findCommands) {
        expect(command.intent, isA<Intent>(), reason: command.label);
      }
      expect(
        commandsFor('>mark done').first.intent,
        isA<DismissThreadIntent>(),
      );
    });
  });

  group('the palette', () {
    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(FindField.fieldKey), text);
      await tester.pump();
    }

    testWidgets('a host that listens for no command gets the old box',
        (tester) async {
      String? submitted;
      await pumpField(tester, onSubmit: (value) => submitted = value);

      await type(tester, '>dis');

      expect(find.byKey(FindField.commandsKey), findsNothing);

      // `>` is a character like any other while the feature is dormant, so a
      // needle that happens to start with one still searches.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(submitted, '>dis');
    });

    testWidgets('> offers the commands under the box, with their keys',
        (tester) async {
      await pumpField(tester, onCommand: (_) {});

      await type(tester, '>');

      expect(find.byKey(FindField.commandsKey), findsOneWidget);
      expect(find.byKey(FindField.commandKeyFor('Mark done')), findsOneWidget);
      expect(find.text('Mark done'), findsOneWidget);
      expect(find.text('e'), findsOneWidget);
      // The same place the label strip draws: nothing opens over the list.
      expect(
        tester.getTopLeft(find.byKey(FindField.commandsKey)).dy,
        greaterThan(
          tester.getBottomLeft(find.byKey(FindField.fieldKey)).dy - 1,
        ),
      );
    });

    testWidgets('and it is the commands, not the labels', (tester) async {
      // One strip and two vocabularies: a needle cannot be a command and a
      // half-typed label term at once, so the palette wins outright.
      await pumpField(
        tester,
        labelNames: const ['Jira update'],
        onCommand: (_) {},
      );

      await type(tester, '>label');

      expect(find.byKey(FindField.commandsKey), findsOneWidget);
      expect(find.byKey(FindField.suggestionsKey), findsNothing);
    });

    testWidgets('Enter invokes the intent, and the box gives up the needle',
        (tester) async {
      final invoked = <Intent>[];
      final focusedAtInvoke = <bool>[];
      await pumpField(
        tester,
        onCommand: (intent) {
          invoked.add(intent);
          focusedAtInvoke.add(focusNode.hasFocus);
        },
        onClear: controller.clear,
      );

      await type(tester, '>later');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(invoked.single, isA<LaterThreadIntent>());
      expect(controller.text, isEmpty);
      // The contract the whole deferral exists for: the triage actions are
      // gated on the cursor NOT being in a box, so a command that arrived
      // while this field still held it would be refused in silence.
      expect(focusedAtInvoke.single, isFalse);
      expect(find.byKey(FindField.commandsKey), findsNothing);
    });

    testWidgets('the arrows walk it, and Enter takes where they stopped',
        (tester) async {
      final invoked = <Intent>[];
      await pumpField(
        tester,
        onCommand: invoked.add,
        onClear: controller.clear,
      );

      await type(tester, '>l');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      // Down once from `Label…`, which led.
      expect(invoked.single, isA<LaterThreadIntent>());
    });

    testWidgets('a tap does the same thing the key would', (tester) async {
      final invoked = <Intent>[];
      await pumpField(
        tester,
        onCommand: invoked.add,
        onClear: controller.clear,
      );

      await type(tester, '>');
      await tester.tap(find.byKey(FindField.commandKeyFor('Undo')));
      await tester.pump();

      expect(invoked.single, isA<UndoLastIntent>());
    });

    testWidgets('a command nothing answers leaves Enter alone', (tester) async {
      // No strip and no invoke, so the needle behaves like any other needle
      // nothing matched: the host's own Enter gets it and can escalate.
      final invoked = <Intent>[];
      String? submitted;
      await pumpField(
        tester,
        onCommand: invoked.add,
        onSubmit: (value) => submitted = value,
      );

      await type(tester, '>zzz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(find.byKey(FindField.commandsKey), findsNothing);
      expect(invoked, isEmpty);
      expect(submitted, '>zzz');
    });

    testWidgets('Escape clears the palette the way it clears a needle',
        (tester) async {
      var cleared = 0;
      await pumpField(tester, onCommand: (_) {}, onClear: () => cleared++);

      await type(tester, '>');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(cleared, 1);
    });
  });
}
