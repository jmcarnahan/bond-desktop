import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/pinned_documents_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The room's bookmark bar: what somebody pinned, under the room's name.
///
/// It is a statement about pins and a way to open them, and nothing else — no
/// ×, because taking a pin down is a correction and corrections are a
/// two-step on the Files tab.

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required List<AttachmentRef> documents,
    void Function(AttachmentRef)? onOpen,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PinnedDocumentsBar(documents: documents, onOpen: onOpen),
      ),
    ));
    await tester.pump();
  }

  testWidgets('nothing pinned draws no bar at all', (tester) async {
    await pumpBar(tester, documents: const []);

    expect(find.byKey(PinnedDocumentsBar.barKey), findsNothing);
  });

  testWidgets('one entry per document, keyed by the file it stands for',
      (tester) async {
    final quote = ref(name: 'Quote.pdf');
    final brief = ref(name: 'Brief.pdf', attachmentId: 'a2');
    await pumpBar(tester, documents: [quote, brief]);

    expect(find.byKey(PinnedDocumentsBar.barKey), findsOneWidget);
    expect(find.byKey(PinnedDocumentsBar.entryKeyFor(quote)), findsOneWidget);
    expect(find.byKey(PinnedDocumentsBar.entryKeyFor(brief)), findsOneWidget);
    // The glyph rides with the name, the way it does on every other chip.
    expect(find.text('📕 Quote.pdf'), findsOneWidget);
    // No way to unpin from here: that question belongs beside the whole shelf.
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('a file with no name still has an entry', (tester) async {
    final unnamed = ref(name: null, contentType: null);
    await pumpBar(tester, documents: [unnamed]);

    expect(find.textContaining('(unnamed)'), findsOneWidget);
  });

  testWidgets('a tap reports the document it was on', (tester) async {
    final quote = ref(name: 'Quote.pdf');
    final brief = ref(name: 'Brief.pdf', attachmentId: 'a2');
    final opened = <String>[];
    await pumpBar(
      tester,
      documents: [quote, brief],
      onOpen: (attachment) => opened.add(attachment.attachmentId),
    );

    await tester.tap(find.byKey(PinnedDocumentsBar.entryKeyFor(brief)));
    await tester.pump();

    expect(opened, ['a2']);
  });

  testWidgets('a host with nowhere to open one leaves the entries inert',
      (tester) async {
    final quote = ref(name: 'Quote.pdf');
    await pumpBar(tester, documents: [quote]);

    // Still says what is pinned; a tap simply does nothing rather than
    // throwing.
    await tester.tap(find.byKey(PinnedDocumentsBar.entryKeyFor(quote)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('📕 Quote.pdf'), findsOneWidget);
  });
}
