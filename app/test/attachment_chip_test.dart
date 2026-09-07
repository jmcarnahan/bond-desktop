import 'package:bond_inbox/widgets/attachment_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// What one file says about itself, and whether it offers to be opened.
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

void main() {
  testWidgets('names the file, its glyph and its size', (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(name: 'Loan terms.pdf', size: 240 * 1024),
    )));

    expect(find.text('Loan terms.pdf'), findsOneWidget);
    expect(find.text('📕'), findsOneWidget);
    expect(find.text('240 KB'), findsOneWidget);
  });

  testWidgets('a file nobody named still says it is a file', (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(name: null, contentType: null, size: 0),
    )));

    expect(find.text('(unnamed)'), findsOneWidget);
    // No size was ever stated, so none is claimed.
    expect(find.textContaining(' B'), findsNothing);
  });

  testWidgets('a long name is cut on graphemes before it is laid out',
      (tester) async {
    final name = '${'é' * 60}.pdf';
    await tester.pumpWidget(_host(AttachmentChip(attachment: ref(name: name))));

    final text = tester.widget<Text>(find.text('${'é' * AttachmentChip.nameCap}…'));
    expect(text.data!.characters.length, AttachmentChip.nameCap + 1);
  });

  testWidgets('a chip with nowhere to go is a statement', (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(attachment: ref())));

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a chip with somewhere to go opens it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(),
      onTap: () => taps++,
    )));

    await tester.tap(find.byType(AttachmentChip));
    expect(taps, 1);
  });

  testWidgets('the selected file says so in fill and border, not in size',
      (tester) async {
    await tester.pumpWidget(_host(Column(children: [
      AttachmentChip(attachment: ref(), selected: true),
      AttachmentChip(attachment: ref(attachmentId: 'a2')),
    ])));

    final boxes = tester
        .widgetList<Container>(find.descendant(
          of: find.byType(AttachmentChip),
          matching: find.byType(Container),
        ))
        .map((c) => c.decoration! as BoxDecoration)
        .toList();
    expect(boxes.first.color == boxes.last.color, isFalse);
    expect(boxes.first.border == boxes.last.border, isFalse);

    final chips = find.byType(AttachmentChip);
    expect(
      tester.getSize(chips.first).height,
      tester.getSize(chips.last).height,
      reason: 'selection must not change the height and reflow the run',
    );
  });

  testWidgets('a file whose words landed but whose digest has not says so',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(textStatus: 'done', digestStatus: 'pending'),
    )));

    expect(find.text('reading…'), findsOneWidget);
  });

  testWidgets('a freshly synced file promises nothing', (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(textStatus: 'pending', digestStatus: 'pending'),
    )));

    expect(find.text('reading…'), findsNothing);
  });

  testWidgets('and a file it has read says nothing about reading',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentChip(
      attachment: ref(textStatus: 'done', digestStatus: 'done'),
    )));

    expect(find.text('reading…'), findsNothing);
  });
}
