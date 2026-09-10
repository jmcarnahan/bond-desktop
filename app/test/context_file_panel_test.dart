import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/widgets/context_file_panel.dart';
import 'package:bond_inbox/widgets/preview/text_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One of the owner's own files, read on its own.
///
/// Prop-only, so there is no `InboxScreen` and no sixty-second timer behind
/// it — `pumpAndSettle` is safe here and nowhere near the shell.
/// `inbox_context_panel_test.dart` is the other half: the same body wired to a
/// real store through the screen.
///
/// The promises this file owns:
///
/// - **The passage a citation named is marked and reachable.** The whole
///   reason a chip opens a file at a section is that the reader lands on the
///   paragraph rather than at the top of ten pages.
/// - **A digest is labelled `AI`.** It is a model's words about the owner's
///   file, and the label is the app's standing promise about whose sentence a
///   reader is looking at.
/// - **Consult exists only where there is a reply to consult for.** A button
///   that answers a tap by doing nothing is worse than no button.
const _now = '2026-09-09T12:00:00Z';

ContextFile _file({
  String relPath = 'docs/pricing.md',
  String status = 'ok',
  String? digestJson,
}) =>
    ContextFile(
      id: 7,
      dirId: 'd1',
      relPath: relPath,
      size: 400,
      mtime: '2026-09-09T09:00:00Z',
      sha256: 'abc',
      kind: 'doc',
      claudeChain: const [],
      digestJson: digestJson,
      digestStatus: digestJson == null ? 'pending' : 'done',
      hasDescEmbedding: false,
      textChars: 400,
      status: status,
      seenAt: _now,
      updatedAt: _now,
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    ContextFile? file,
    String text = 'Intro paragraph.\n\nQ4 rates hold at nine.\n',
    ContextFileDigest? digest,
    String? locator,
    String? located,
    VoidCallback? onConsult,
    String? consultNote,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 600,
              child: ContextFilePanelBody(
                file: file ?? _file(),
                dirName: 'acme',
                text: text,
                digest: digest,
                locator: locator,
                located: located,
                onConsult: onConsult,
                consultNote: consultNote,
                now: DateTime.parse(_now),
              ),
            ),
          ),
        ),
      );

  testWidgets('the caption names the directory, the path and the age',
      (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('acme/docs/pricing.md · modified 3h ago'), findsOneWidget);
  });

  testWidgets('a file the extractor cut short says so', (tester) async {
    await pump(tester, file: _file(status: 'truncated'));
    await tester.pumpAndSettle();

    // A reader concluding something from a file's silence should know the
    // file was not read whole.
    expect(
      find.text('acme/docs/pricing.md · modified 3h ago · truncated'),
      findsOneWidget,
    );
  });

  testWidgets('a digest is shown under AI, above the words', (tester) async {
    await pump(
      tester,
      digest: const ContextFileDigest(
        purpose: 'The renewal pricing model.',
        findings: ['Rates hold at nine.', 'Signed on the fourth.'],
        kindHint: 'analysis',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ContextFilePanelBody.digestKey), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('The renewal pricing model.'), findsOneWidget);
    expect(find.text('• Rates hold at nine.'), findsOneWidget);
    // One paragraph before ten pages: a person asking what is in this file is
    // answered before they have to read it.
    expect(
      tester.getTopLeft(find.text('The renewal pricing model.')).dy,
      lessThan(tester.getTopLeft(find.byType(TextPreview)).dy),
    );
  });

  testWidgets('no digest is no block at all', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(ContextFilePanelBody.digestKey), findsNothing);
    expect(find.text('AI'), findsNothing);
  });

  testWidgets('the located passage is marked inside the words',
      (tester) async {
    await pump(
      tester,
      locator: 'Pricing',
      located: 'Q4 rates hold at nine.',
    );
    await tester.pumpAndSettle();

    final marked = find.byKey(ContextFilePanelBody.locatedKey);
    expect(marked, findsOneWidget);
    expect(
      tester.widget<SelectableText>(marked).data,
      'Q4 rates hold at nine.',
    );
    // Three selectable blocks and not one coloured span: copying a number out
    // of a file has to keep working.
    expect(find.byType(SelectableText), findsNWidgets(3));
  });

  testWidgets('a heading kept with its section is still found',
      (tester) async {
    // The chunker keeps a markdown heading line with the section under it, so
    // the passage a chip names starts with `# ...` and spans a line break
    // before its first sentence.
    await pump(
      tester,
      text: 'Intro.\n\n# Q4 rates\n\nRates hold at nine.\n',
      locator: 'Q4 rates',
      located: '# Q4 rates\n\nRates hold at nine.\n',
    );
    await tester.pumpAndSettle();

    final marked = find.byKey(ContextFilePanelBody.locatedKey);
    expect(marked, findsOneWidget);
    expect(
      tester.widget<SelectableText>(marked).data,
      '# Q4 rates\n\nRates hold at nine.',
    );
  });

  testWidgets('a passage whose whitespace was re-flowed is still found',
      (tester) async {
    // The pass that chunked the file and the pass that stored its words are
    // two walks, and an extractor between them can change the breaks without
    // changing a word.
    await pump(
      tester,
      text: 'Intro.\n# Q4 rates\nRates hold at nine.\n',
      locator: 'Q4 rates',
      located: '# Q4 rates\n\nRates hold at nine.\n',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ContextFilePanelBody.locatedKey), findsOneWidget);
  });

  testWidgets('the caption names the section a citation named', (tester) async {
    await pump(tester, locator: 'Pricing > Q4 rates');
    await tester.pumpAndSettle();

    // A file re-read since the draft quoted it may no longer hold the passage;
    // the reader who arrived by a chip is owed the name either way.
    expect(
      find.text('acme/docs/pricing.md · modified 3h ago · § Pricing › Q4 rates'),
      findsOneWidget,
    );
  });

  testWidgets('no locator is no section in the caption', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('§'), findsNothing);
  });

  testWidgets('a passage that is not in the file marks nothing',
      (tester) async {
    await pump(
      tester,
      locator: 'Pricing',
      located: 'A sentence this file has never contained anywhere in it.',
    );
    await tester.pumpAndSettle();

    // The file was re-read and the passage moved. The words still render.
    expect(find.byKey(ContextFilePanelBody.locatedKey), findsNothing);
    expect(find.byType(TextPreview), findsOneWidget);
  });

  testWidgets('Consult is there only when there is a reply to consult for',
      (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(ContextFilePanelBody.consultKey), findsNothing);

    var consulted = 0;
    await pump(tester, onConsult: () => consulted++);
    await tester.pumpAndSettle();

    expect(find.text('Consult for the reply'), findsOneWidget);
    expect(
      find.text('Regenerates the suggestion with this file read first.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ContextFilePanelBody.consultKey));
    await tester.pumpAndSettle();

    expect(consulted, 1);
  });

  testWidgets('a file the room does not read says so where the button was',
      (tester) async {
    // The retriever re-checks scope and drops a file the room does not link,
    // so a Consult here would press and change nothing. The sentence names
    // the switch that would fix it instead.
    await pump(
      tester,
      consultNote: 'Not linked to this room — switch «acme» on under '
          'Context to consult it.',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ContextFilePanelBody.consultKey), findsNothing);
    expect(find.text('Consult for the reply'), findsNothing);
    expect(
      find.byKey(ContextFilePanelBody.consultNoteKey),
      findsOneWidget,
    );
    expect(
      find.text('Not linked to this room — switch «acme» on under Context '
          'to consult it.'),
      findsOneWidget,
    );
  });

  testWidgets('the button wins over the note when both are handed over',
      (tester) async {
    // Belt and braces on a host that says both things at once: a button that
    // works and a sentence saying it cannot would be the panel contradicting
    // itself in two lines.
    await pump(
      tester,
      onConsult: () {},
      consultNote: 'Not linked to this room.',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ContextFilePanelBody.consultKey), findsOneWidget);
    expect(find.byKey(ContextFilePanelBody.consultNoteKey), findsNothing);
  });

  testWidgets('a file with no words says so', (tester) async {
    await pump(tester, text: '');
    await tester.pumpAndSettle();

    expect(
      find.text('No text was extracted from this file.'),
      findsOneWidget,
    );
  });
}
