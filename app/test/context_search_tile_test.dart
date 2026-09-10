import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/widgets/context_search_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One directory passage on the search screen.
///
/// The two promises: the row says which project and which file it came out of
/// without repeating the chunker's header line inside the quote, and a tile
/// with nowhere to go is a statement rather than a control.

ContextChunkHit _hit({
  int chunkId = 3,
  int fileId = 7,
  String relPath = 'docs/pricing.md',
  String locator = 'Pricing > Q4 rates',
  String? text,
}) =>
    ContextChunkHit(
      fileId: fileId,
      dirId: 'd1',
      dirName: 'acme',
      relPath: relPath,
      chunkId: chunkId,
      seq: 0,
      locator: locator,
      text: text ?? '$relPath · $locator\nQ4 rates hold at nine per cent.',
      distance: 0.4,
    );

void main() {
  Future<void> pump(
    WidgetTester tester,
    ContextChunkHit hit, {
    VoidCallback? onOpen,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: ContextSearchTile(hit: hit, onOpen: onOpen),
        ),
      ),
    ));
    await tester.pump();
  }

  test('the key names the passage it drew', () {
    expect(
      ContextSearchTile.keyFor(_hit()),
      const ValueKey('search-dir-3'),
    );
  });

  testWidgets('the title is the project, the path and the section',
      (tester) async {
    await pump(tester, _hit());

    // Drawn as a breadcrumb, like the reply caption and the chips: the
    // chunker's `>` is a comparison operator in the middle of a result row.
    expect(
      find.text('acme/docs/pricing.md · Pricing › Q4 rates'),
      findsOneWidget,
    );
  });

  testWidgets('a summary passage is named the way the caption names it',
      (tester) async {
    await pump(tester, _hit(locator: 'digest', text: 'notes.md\nWhat it is.'));

    expect(find.text('acme/docs/pricing.md · summary'), findsOneWidget);
  });

  testWidgets('a passage with no section is named by its path alone',
      (tester) async {
    await pump(tester, _hit(locator: '', text: 'notes.md\nA short note.'));

    expect(find.text('acme/docs/pricing.md'), findsOneWidget);
  });

  testWidgets('the snippet drops the stored header line', (tester) async {
    await pump(tester, _hit());

    // The title above already says the path and the section; a snippet that
    // repeated them would spend its first line saying what the row is called.
    expect(find.text('Q4 rates hold at nine per cent.'), findsOneWidget);
  });

  testWidgets('a long passage is cut, on one breath', (tester) async {
    await pump(
      tester,
      _hit(text: 'docs/pricing.md · Pricing\n${'word ' * 200}'),
    );

    final snippet = tester.widget<Text>(find.textContaining('word word')).data!;
    expect(snippet.length, ContextSearchTile.snippetCap + 1);
    expect(snippet, endsWith('…'));
    expect(snippet, isNot(contains('\n')));
  });

  testWidgets('nowhere to go is no ink', (tester) async {
    await pump(tester, _hit());
    expect(find.byType(InkWell), findsNothing);

    var opened = 0;
    await pump(tester, _hit(), onOpen: () => opened++);
    expect(find.byType(InkWell), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pump();

    expect(opened, 1);
  });
}
