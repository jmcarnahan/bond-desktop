import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/attachment_chip.dart';
import 'package:bond_inbox/widgets/attachment_chip_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The run of files under a message: what it draws, how it wraps, and which one
/// of them says it is the one on screen.
Widget _host(Widget child, {double width = 320}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

void main() {
  testWidgets('no files is no gap', (tester) async {
    await tester.pumpWidget(_host(const AttachmentChipRow(attachments: [])));

    expect(find.byKey(AttachmentChipRow.rowKey), findsNothing);
    expect(tester.getSize(find.byType(AttachmentChipRow)).height, 0);
  });

  testWidgets('one chip per file, in the order they were listed',
      (tester) async {
    await tester.pumpWidget(_host(
      AttachmentChipRow(attachments: [
        ref(attachmentId: 'a1', name: 'One.pdf'),
        ref(attachmentId: 'a2', name: 'Two.docx'),
      ]),
      width: 700,
    ));

    expect(find.byType(AttachmentChip), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('One.pdf')).dx,
      lessThan(tester.getTopLeft(find.text('Two.docx')).dx),
    );
  });

  testWidgets('six files wrap rather than overflow a narrow column',
      (tester) async {
    final files = [
      for (var i = 0; i < 6; i++)
        ref(attachmentId: 'a$i', name: 'Statement $i.pdf'),
    ];
    await tester.pumpWidget(_host(AttachmentChipRow(attachments: files)));

    expect(tester.takeException(), isNull);
    final first = tester.getTopLeft(find.byType(AttachmentChip).first);
    final last = tester.getTopLeft(find.byType(AttachmentChip).last);
    expect(last.dy, greaterThan(first.dy));
  });

  testWidgets('only the selected file says it is selected', (tester) async {
    final files = [
      ref(attachmentId: 'a1', name: 'One.pdf'),
      ref(attachmentId: 'a2', name: 'Two.pdf'),
    ];
    await tester.pumpWidget(_host(AttachmentChipRow(
      attachments: files,
      // A ref carrying different metadata for the same file: selection is the
      // pair of ids, never value equality.
      selected: ref(attachmentId: 'a2', name: 'Two.pdf', digestStatus: 'pending'),
    )));

    final chips =
        tester.widgetList<AttachmentChip>(find.byType(AttachmentChip)).toList();
    expect(chips.first.selected, isFalse);
    expect(chips.last.selected, isTrue);
  });

  testWidgets('tapping one hands the host that file', (tester) async {
    AttachmentRef? opened;
    await tester.pumpWidget(_host(AttachmentChipRow(
      attachments: [
        ref(attachmentId: 'a1', name: 'One.pdf'),
        ref(attachmentId: 'a2', name: 'Two.pdf'),
      ],
      onOpen: (attachment) => opened = attachment,
    )));

    await tester.tap(find.text('Two.pdf'));
    expect(opened?.attachmentId, 'a2');
  });

  testWidgets('a row with nowhere to send a tap offers none', (tester) async {
    await tester.pumpWidget(_host(AttachmentChipRow(attachments: [ref()])));

    expect(find.byType(InkWell), findsNothing);
  });
}
