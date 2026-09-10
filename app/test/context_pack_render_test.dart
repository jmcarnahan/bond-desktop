import 'package:bond_inbox/services/context/context_pack_render.dart';
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:flutter_test/flutter_test.dart';

/// How the owner's own directories read to the model.
///
/// The retriever decides what is worth showing; this decides how it reads,
/// and the two are tested apart because the wording is the half a person
/// argues about and it should not need a database to argue with.
///
/// The rule under every cap here is `renderAttachmentExcerpts`': whole blocks
/// come off the END first, because the ranking put the nearest one first, and
/// only what is left is hard-cut.
void main() {
  ContextPack packOf({
    List<ContextBriefLine> briefs = const [],
    List<ContextGuidance> guidance = const [],
    List<ContextExcerpt> excerpts = const [],
    List<String> skills = const [],
    List<String> directories = const ['acme'],
  }) =>
      ContextPack(
        directories: directories,
        briefs: briefs,
        guidance: guidance,
        excerpts: excerpts,
        skills: skills,
      );

  ContextExcerpt excerptOf({
    String dirName = 'acme',
    String relPath = 'docs/pricing.md',
    String locator = 'Pricing > Q4 rates',
    String modified = '2026-08-30',
    String text = 'Q4 rates hold at nine.',
    bool truncated = false,
  }) =>
      ContextExcerpt(
        dirName: dirName,
        relPath: relPath,
        locator: locator,
        modified: modified,
        text: text,
        fileId: 1,
        dirId: 'd1',
        truncated: truncated,
      );

  group('the brief', () {
    test('names the directory, then its facts and its words', () {
      final rendered = renderContextBrief(
        packOf(briefs: [
          const ContextBriefLine(
            dirName: 'acme',
            about: 'A renewal pricing model for the Marrowfield portfolio.',
            keyFacts: ['Q4 rates hold at nine.', 'Renewals close on the 4th.'],
            vocabulary: ['Marrowfield', 'rung'],
          ),
        ]),
        700,
      );

      expect(
        rendered,
        '«acme»: A renewal pricing model for the Marrowfield portfolio.\n'
        'Facts: Q4 rates hold at nine.; Renewals close on the 4th.\n'
        'Terms: Marrowfield, rung',
      );
    });

    test('leaves out the lines it has nothing for', () {
      final rendered = renderContextBrief(
        packOf(briefs: [
          const ContextBriefLine(dirName: 'acme', about: 'A pricing model.'),
        ]),
        700,
      );

      expect(rendered, '«acme»: A pricing model.');
      expect(rendered, isNot(contains('Facts:')));
      expect(rendered, isNot(contains('Terms:')));
    });

    test('two directories are two blocks', () {
      final rendered = renderContextBrief(
        packOf(briefs: [
          const ContextBriefLine(dirName: 'acme', about: 'Pricing.'),
          const ContextBriefLine(dirName: 'ridge', about: 'Field notes.'),
        ]),
        700,
      );

      expect(rendered, '«acme»: Pricing.\n---\n«ridge»: Field notes.');
    });

    test('an empty pack renders nothing at all', () {
      expect(renderContextBrief(ContextPack.empty, 700), '');
      expect(renderContextGuidance(ContextPack.empty, 700), '');
      expect(renderContextExcerpts(ContextPack.empty, 700), '');
    });
  });

  group('the guidance', () {
    test('every block wears the label the app gave it', () {
      final rendered = renderContextGuidance(
        packOf(guidance: const [
          ContextGuidance(label: 'guidance', text: 'Answer in two lines.'),
          ContextGuidance(label: 'docs/CLAUDE.md', text: 'Cite the table.'),
          ContextGuidance(label: 'SKILL vendor-replies', text: 'Quote a rate.'),
          ContextGuidance(label: 'rule pricing.md', text: 'Never round up.'),
        ]),
        1500,
      );

      expect(
        rendered,
        '[guidance]\nAnswer in two lines.\n---\n'
        '[docs/CLAUDE.md]\nCite the table.\n---\n'
        '[SKILL vendor-replies]\nQuote a rate.\n---\n'
        '[rule pricing.md]\nNever round up.',
      );
    });
  });

  group('the passages', () {
    test('the bracket line says which file, where in it, and how fresh', () {
      expect(
        renderContextExcerpts(packOf(excerpts: [excerptOf()]), 2500),
        '[acme/docs/pricing.md, Pricing > Q4 rates, modified 2026-08-30]\n'
        'Q4 rates hold at nine.',
      );
    });

    test('a whole-file passage and a dateless row say so in words', () {
      expect(
        renderContextExcerpts(
          packOf(excerpts: [excerptOf(locator: '', modified: '')]),
          2500,
        ),
        '[acme/docs/pricing.md, whole file, modified an unknown date]\n'
        'Q4 rates hold at nine.',
      );
    });

    test('a digest says a model wrote it', () {
      // Not filtered, unlike an attachment's: this is a summary of the
      // OWNER'S own file, and it is very often the only passage that answers
      // a question about what an analysis found. The label is what keeps a
      // reply from quoting it as though the file said it.
      expect(
        renderContextExcerpts(
          packOf(excerpts: [excerptOf(locator: 'digest')]),
          2500,
        ),
        contains("digest (a model's summary of this file)"),
      );
    });

    test('a file the extractor cut short says so after the locator', () {
      expect(
        renderContextExcerpts(
          packOf(excerpts: [excerptOf(truncated: true)]),
          2500,
        ),
        contains('[acme/docs/pricing.md, Pricing > Q4 rates (truncated), '
            'modified 2026-08-30]'),
      );
    });
  });

  group('the caps', () {
    test('whole blocks come off the far end first', () {
      final rendered = renderContextExcerpts(
        packOf(excerpts: [
          excerptOf(text: 'A' * 100),
          excerptOf(relPath: 'docs/terms.md', text: 'B' * 100),
        ]),
        200,
      );

      // The nearest passage survives whole; the far one is gone rather than
      // half-quoted.
      expect(rendered, contains('A' * 100));
      expect(rendered, isNot(contains('B')));
      expect(rendered.length, lessThanOrEqualTo(200));
    });

    test('one block over the cap on its own is hard-cut', () {
      final rendered = renderContextExcerpts(
        packOf(excerpts: [excerptOf(text: 'A' * 500)]),
        120,
      );

      expect(rendered.length, 120);
      expect(rendered, startsWith('[acme/docs/pricing.md'));
    });

    test('the guidance and the brief clamp the same way', () {
      final guidance = renderContextGuidance(
        packOf(guidance: [
          ContextGuidance(label: 'guidance', text: 'X' * 60),
          const ContextGuidance(label: 'rule pricing.md', text: 'never'),
        ]),
        80,
      );
      expect(guidance, contains('X' * 60));
      expect(guidance, isNot(contains('rule pricing.md')));

      final brief = renderContextBrief(
        packOf(briefs: [
          ContextBriefLine(dirName: 'acme', about: 'Y' * 60),
          const ContextBriefLine(dirName: 'ridge', about: 'Field notes.'),
        ]),
        80,
      );
      expect(brief, contains('Y' * 60));
      expect(brief, isNot(contains('ridge')));
    });
  });
}
