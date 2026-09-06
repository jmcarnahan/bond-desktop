import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/attachment_documents_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The documents pinned to a storyline, and the two taps it takes to unpin
/// one. Built in this round; the storyline pane wires it in the next.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)));

void main() {
  testWidgets('an empty shelf says so', (tester) async {
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: const [],
      onOpen: (_) {},
    )));

    expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsOneWidget);
    expect(find.text('No documents on this storyline yet.'), findsOneWidget);
  });

  testWidgets('an entry names itself, its size and the model read',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [
        ref(
          name: 'Quote.pdf',
          size: 240 * 1024,
          digest: const AttachmentDigest(summary: 'A quote for the survey.'),
        ),
      ],
      onOpen: (_) {},
    )));

    expect(find.text('📕 Quote.pdf'), findsOneWidget);
    expect(find.text('240 KB · A quote for the survey.'), findsOneWidget);
  });

  testWidgets('a document the model never read is just its size',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [ref(name: 'Quote.pdf', size: 240 * 1024, digest: null)],
      onOpen: (_) {},
    )));

    expect(find.text('240 KB'), findsOneWidget);
  });

  testWidgets('tapping one opens it', (tester) async {
    AttachmentRef? opened;
    final document = ref(name: 'Quote.pdf');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      onOpen: (a) => opened = a,
    )));

    await tester.tap(find.byKey(AttachmentDocumentsStrip.entryKeyFor(document)));
    expect(opened?.attachmentId, document.attachmentId);
  });

  testWidgets('a read-only shelf offers no way to remove anything',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [ref()],
      onOpen: (_) {},
    )));

    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('removing is two taps', (tester) async {
    var removed = 0;
    final document = ref(name: 'Quote.pdf');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      onOpen: (_) {},
      onUnpin: (_) => removed++,
    )));

    await tester.tap(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(document)));
    await tester.pump();
    expect(removed, 0);
    expect(find.text('Remove document'), findsOneWidget);

    await tester.tap(
      find.byKey(AttachmentDocumentsStrip.confirmKeyFor(document)),
    );
    await tester.pump();
    expect(removed, 1);
    // Back to the first step, ready for the next one.
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('cancel restores the first step and removes nothing',
      (tester) async {
    var removed = 0;
    final document = ref(name: 'Quote.pdf');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      onOpen: (_) {},
      onUnpin: (_) => removed++,
    )));

    await tester.tap(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(document)));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(removed, 0);
    expect(find.text('Remove document'), findsNothing);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('only the entry that was pressed asks a second time',
      (tester) async {
    final first = ref(name: 'One.pdf', attachmentId: 'a1');
    final second = ref(name: 'Two.pdf', attachmentId: 'a2');
    await tester.pumpWidget(_host(SizedBox(
      width: 800,
      child: AttachmentDocumentsStrip(
        documents: [first, second],
        onOpen: (_) {},
        onUnpin: (_) {},
      ),
    )));

    await tester.tap(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(first)));
    await tester.pump();

    expect(find.byKey(AttachmentDocumentsStrip.confirmKeyFor(first)),
        findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.confirmKeyFor(second)),
        findsNothing);
  });
}
