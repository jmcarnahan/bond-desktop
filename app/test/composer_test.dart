import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reply box.
///
/// The assertion this file exists for is the negative one: [Composer.onSend]
/// fires on a button press and on nothing else — no timer, no debounce, no
/// state change.

void main() {
  Future<void> pumpComposer(
    WidgetTester tester, {
    String? suggestedBody,
    String? provenance = '✨ Suggested reply',
    bool generating = false,
    bool sending = false,
    SendCapability capability = SendCapability.send,
    required void Function(String) onSend,
    VoidCallback? onGenerate,
    VoidCallback? onDismiss,
    void Function(String)? onEdited,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Composer(
          suggestedBody: suggestedBody,
          provenance: provenance,
          generating: generating,
          sending: sending,
          capability: capability,
          onSend: onSend,
          onGenerate: onGenerate,
          onDismiss: onDismiss,
          onEdited: onEdited,
        ),
      ),
    ));
    await tester.pump();
  }

  TextStyle fieldStyle(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).style!;

  group('the suggested state', () {
    testWidgets('prefills the field, dimmed, behind an accent rule',
        (tester) async {
      await pumpComposer(
        tester,
        suggestedBody: 'Hi Sarah — Friday works.',
        onSend: (_) {},
      );

      expect(find.text('Hi Sarah — Friday works.'), findsOneWidget);
      expect(find.text('✨ Suggested reply'), findsOneWidget);
      expect(
        fieldStyle(tester).color,
        BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
      );
      final rule = tester.widgetList<Container>(find.byType(Container)).where(
            (c) => (c.decoration as BoxDecoration?)?.border is Border &&
                ((c.decoration as BoxDecoration).border as Border).left.color ==
                    BondColors.seaGlassOnDark,
          );
      expect(rule, hasLength(1));
    });

    testWidgets('the first edit takes the chrome away and fires onEdited',
        (tester) async {
      final edits = <String>[];
      await pumpComposer(
        tester,
        suggestedBody: 'Hi Sarah — Friday works.',
        onSend: (_) {},
        onEdited: edits.add,
      );

      await tester.enterText(find.byType(TextField), 'Hi Sarah — Monday.');
      await tester.pump();

      // From this point the words are the LO's, and dressing them as a
      // machine's suggestion would be a lie about who wrote them.
      expect(find.text('✨ Suggested reply'), findsNothing);
      expect(fieldStyle(tester).color, isNot(
        BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
      ));

      expect(edits, isEmpty, reason: 'debounced, not per keystroke');
      await tester.pump(Composer.editDebounce);
      expect(edits, ['Hi Sarah — Monday.']);
    });

    testWidgets('a burst of typing collapses into one onEdited', (tester) async {
      final edits = <String>[];
      await pumpComposer(
        tester,
        suggestedBody: 'draft',
        onSend: (_) {},
        onEdited: edits.add,
      );

      for (final text in ['a', 'ab', 'abc']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(Composer.editDebounce);

      expect(edits, ['abc']);
    });

    testWidgets('dismiss clears the field and reports it', (tester) async {
      var dismissed = 0;
      await pumpComposer(
        tester,
        suggestedBody: 'Hi Sarah — Friday works.',
        onSend: (_) {},
        onDismiss: () => dismissed++,
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(dismissed, 1);
      expect(find.text('Hi Sarah — Friday works.'), findsNothing);
      expect(find.text('✨ Suggested reply'), findsNothing);
    });

    testWidgets('with no suggestion there is no chrome at all', (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      expect(find.text('✨ Suggested reply'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(fieldStyle(tester).color, isNot(
        BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
      ));
    });
  });

  group('the generate button', () {
    testWidgets('offers to draft when the box is empty', (tester) async {
      await pumpComposer(tester, onSend: (_) {}, onGenerate: () {});

      expect(find.text('Draft reply'), findsOneWidget);
      expect(find.text('Regenerate'), findsNothing);
    });

    testWidgets('offers to regenerate when a draft is there', (tester) async {
      await pumpComposer(
        tester,
        suggestedBody: 'a draft',
        onSend: (_) {},
        onGenerate: () {},
      );

      expect(find.text('Regenerate'), findsOneWidget);
      expect(find.text('Draft reply'), findsNothing);
    });

    testWidgets('becomes a spinner while a draft is being written',
        (tester) async {
      await pumpComposer(
        tester,
        generating: true,
        onSend: (_) {},
        onGenerate: () {},
      );

      expect(find.text('Draft reply'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('is absent when the host wires no generator', (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      expect(find.text('Draft reply'), findsNothing);
      expect(find.text('Regenerate'), findsNothing);
    });

    testWidgets('fires on a press', (tester) async {
      var asked = 0;
      await pumpComposer(tester, onSend: (_) {}, onGenerate: () => asked++);

      await tester.tap(find.text('Draft reply'));
      await tester.pump();

      expect(asked, 1);
    });
  });

  group('the send button', () {
    ElevatedButton sendButton(WidgetTester tester) =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));

    testWidgets('is disabled over an empty box', (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      expect(sendButton(tester).onPressed, isNull);
    });

    testWidgets('and over a box holding only whitespace', (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();

      expect(sendButton(tester).onPressed, isNull);
    });

    testWidgets('enables as soon as there is something to send',
        (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      await tester.enterText(find.byType(TextField), 'Friday works.');
      await tester.pump();

      expect(sendButton(tester).onPressed, isNotNull);
    });

    testWidgets('disables again when the box is emptied', (tester) async {
      await pumpComposer(tester, onSend: (_) {});

      await tester.enterText(find.byType(TextField), 'typed');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();

      expect(sendButton(tester).onPressed, isNull);
    });

    testWidgets('names what it will do, per capability', (tester) async {
      await pumpComposer(
        tester,
        suggestedBody: 'a draft',
        capability: SendCapability.send,
        onSend: (_) {},
      );
      expect(find.text('Send'), findsOneWidget);

      await pumpComposer(
        tester,
        suggestedBody: 'a draft',
        capability: SendCapability.draftToOutlook,
        onSend: (_) {},
      );
      expect(find.text('Save to Outlook Drafts'), findsOneWidget);

      await pumpComposer(
        tester,
        suggestedBody: 'a draft',
        capability: SendCapability.copyOnly,
        onSend: (_) {},
      );
      expect(find.text('Copy reply'), findsOneWidget);
    });

    testWidgets('hands over exactly what is in the box', (tester) async {
      final sent = <String>[];
      await pumpComposer(
        tester,
        suggestedBody: 'the suggestion',
        onSend: sent.add,
      );

      await tester.enterText(find.byType(TextField), 'what I actually wrote');
      await tester.pump();
      await tester.tap(find.text('Send'));
      await tester.pump();

      expect(sent, ['what I actually wrote']);
    });

    testWidgets('is disabled and spinning while a send is in flight',
        (tester) async {
      // What stops a double click sending the same reply twice.
      await pumpComposer(
        tester,
        suggestedBody: 'a draft',
        sending: true,
        onSend: (_) {},
      );

      expect(sendButton(tester).onPressed, isNull);
      expect(find.text('Send'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('nothing sends on its own', () {
    testWidgets('a suggestion sitting untouched never fires onSend',
        (tester) async {
      final sent = <String>[];
      await pumpComposer(
        tester,
        suggestedBody: 'Hi Sarah — Friday works.',
        onSend: sent.add,
        onEdited: (_) {},
      );

      // Long past every debounce and animation this widget owns.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 30));

      expect(sent, isEmpty);
    });

    testWidgets('nor does typing, however long it settles', (tester) async {
      final sent = <String>[];
      await pumpComposer(tester, onSend: sent.add, onEdited: (_) {});

      await tester.enterText(find.byType(TextField), 'a reply I never sent');
      await tester.pump(const Duration(seconds: 10));

      expect(sent, isEmpty);
    });
  });
}
