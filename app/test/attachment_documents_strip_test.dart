import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/attachment_documents_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// Every document on a storyline, the pinned ones first — and the controls
/// that move a file between those two states: one tap to pin, two to unpin.
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
      documents: [ref(pinnedStorylineId: 'sl-1')],
      storylineId: 'sl-1',
      onOpen: (_) {},
    )));

    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('an unpinned document offers Pin and a pinned one offers Remove',
      (tester) async {
    final loose = ref(name: 'Loose.pdf', attachmentId: 'a1');
    final pinned =
        ref(name: 'Pinned.pdf', attachmentId: 'a2', pinnedStorylineId: 'sl-1');
    await tester.pumpWidget(_host(SizedBox(
      width: 800,
      child: AttachmentDocumentsStrip(
        documents: [pinned, loose],
        storylineId: 'sl-1',
        onOpen: (_) {},
        onPin: (_) {},
        onUnpin: (_) {},
      ),
    )));

    expect(find.byKey(AttachmentDocumentsStrip.pinKeyFor(loose)),
        findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(loose)),
        findsNothing);
    expect(find.byKey(AttachmentDocumentsStrip.unpinKeyFor(pinned)),
        findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.pinKeyFor(pinned)), findsNothing);
    // The order already says which one is pinned; the marker is what keeps
    // that readable once the shelf is longer than a screen.
    expect(find.text('📌 📕 Pinned.pdf'), findsOneWidget);
    expect(find.text('📕 Loose.pdf'), findsOneWidget);
  });

  testWidgets('a file pinned to ANOTHER storyline is an ordinary document here',
      (tester) async {
    final elsewhere = ref(name: 'Quote.pdf', pinnedStorylineId: 'sl-9');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [elsewhere],
      storylineId: 'sl-1',
      onOpen: (_) {},
      onPin: (_) {},
      onUnpin: (_) {},
    )));

    expect(find.byKey(AttachmentDocumentsStrip.pinKeyFor(elsewhere)),
        findsOneWidget);
    expect(find.text('📕 Quote.pdf'), findsOneWidget);
  });

  testWidgets('Pin reports the document', (tester) async {
    AttachmentRef? pinned;
    final document = ref(name: 'Quote.pdf');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      storylineId: 'sl-1',
      onOpen: (_) {},
      onPin: (a) => pinned = a,
    )));

    await tester.tap(find.byKey(AttachmentDocumentsStrip.pinKeyFor(document)));
    expect(pinned?.attachmentId, document.attachmentId);
  });

  testWidgets('the order the store gave is the order shown', (tester) async {
    final first = ref(name: 'One.pdf', attachmentId: 'a1');
    final second = ref(name: 'Two.pdf', attachmentId: 'a2');
    final third = ref(name: 'Three.pdf', attachmentId: 'a3');
    await tester.pumpWidget(_host(SizedBox(
      width: 1200,
      child: AttachmentDocumentsStrip(
        documents: [third, first, second],
        storylineId: 'sl-1',
        onOpen: (_) {},
      ),
    )));

    // The shelf never re-sorts: the store answered pinned-first, then newest
    // message first, and re-deciding that here would put two orders in the app.
    final shown = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where((text) => text.endsWith('.pdf'))
        .toList();
    expect(shown, ['📕 Three.pdf', '📕 One.pdf', '📕 Two.pdf']);
  });

  testWidgets('removing is two taps', (tester) async {
    var removed = 0;
    final document = ref(name: 'Quote.pdf', pinnedStorylineId: 'sl-1');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      storylineId: 'sl-1',
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
    final document = ref(name: 'Quote.pdf', pinnedStorylineId: 'sl-1');
    await tester.pumpWidget(_host(AttachmentDocumentsStrip(
      documents: [document],
      storylineId: 'sl-1',
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
    final first =
        ref(name: 'One.pdf', attachmentId: 'a1', pinnedStorylineId: 'sl-1');
    final second =
        ref(name: 'Two.pdf', attachmentId: 'a2', pinnedStorylineId: 'sl-1');
    await tester.pumpWidget(_host(SizedBox(
      width: 800,
      child: AttachmentDocumentsStrip(
        documents: [first, second],
        storylineId: 'sl-1',
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
