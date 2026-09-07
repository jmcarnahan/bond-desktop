import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/preview/text_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Words on a page: selectable, never markdown, and honest about how many of
/// them there are.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

void main() {
  testWidgets('the words are there to be copied out', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(text: 'Total: 4,200')));

    final body = tester.widget<SelectableText>(
      find.byKey(TextPreview.bodyKey),
    );
    expect(body.data, 'Total: 4,200');
  });

  testWidgets('asterisks stay asterisks', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(text: '**not bold**')));

    expect(find.text('**not bold**'), findsOneWidget);
  });

  testWidgets('structured text is set in the mono face', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(text: 'a\tb', mono: true)));

    final body = tester.widget<SelectableText>(
      find.byKey(TextPreview.bodyKey),
    );
    expect(body.style?.fontFamily, BondType.mono.fontFamily);
  });

  testWidgets('nothing to read says why', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(
      text: '   ',
      emptyReason: 'Still reading this file…',
    )));

    expect(find.byKey(TextPreview.bodyKey), findsNothing);
    expect(find.byKey(TextPreview.emptyKey), findsOneWidget);
    expect(find.text('Still reading this file…'), findsOneWidget);
  });

  testWidgets('with no reason given it still says something', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(text: '')));

    expect(find.text('No text was extracted from this file.'), findsOneWidget);
  });

  testWidgets('a note about the words sits under them', (tester) async {
    await tester.pumpWidget(_host(const TextPreview(
      text: 'the beginning of it',
      note: 'Text was cut at 20000 characters.',
    )));

    expect(find.byKey(TextPreview.noteKey), findsOneWidget);
    expect(find.text('Text was cut at 20000 characters.'), findsOneWidget);
  });

  testWidgets('a very long file is clamped before it is laid out',
      (tester) async {
    final long = 'x' * (TextPreview.charCap + 500);
    await tester.pumpWidget(_host(TextPreview(text: long)));

    final body = tester.widget<SelectableText>(
      find.byKey(TextPreview.bodyKey),
    );
    expect(body.data!.length, TextPreview.charCap);
  });
}
