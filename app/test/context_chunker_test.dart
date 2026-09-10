import 'package:bond_inbox/services/context/context_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Splitting one local file into the passages a reply can cite.
///
/// Two properties carry the whole feature and both are asserted here rather
/// than assumed. The first is the header line: every passage opens with its
/// own path, because a paragraph about "the Q4 number" is near every other
/// paragraph about a Q4 number in every project the user registered, and the
/// path is what makes it near the RIGHT one. The second is determinism — the
/// reconcile handler replaces a file's chunks with a delete and an insert, so
/// a pass that re-derives the same list replaces the passages with themselves
/// instead of doubling them.
void main() {
  /// A paragraph of roughly [chars] characters, made of whole words.
  String paragraph(String word, int chars) {
    final buffer = StringBuffer();
    while (buffer.length < chars) {
      buffer.write('$word ');
    }
    return buffer.toString().trim();
  }

  const priceSheet = '''
Rates are reviewed each quarter by the Marrowfield desk.

# Pricing

The desk publishes one sheet and nothing else is binding.

## Q4 rates

Standard freight is 41 credits per pallet.

## Terms

Net thirty, with two percent off for early settlement.

# Contacts

Devi Okonkwo owns the sheet.
''';

  List<String> locators(List<ContextChunk> chunks) =>
      [for (final chunk in chunks) chunk.locator];

  group('the contextual header', () {
    test('every passage opens with its path and locator', () {
      final chunks = chunkContextText('docs/pricing.md', priceSheet);

      for (final chunk in chunks) {
        final expected = chunk.locator.isEmpty
            ? 'docs/pricing.md\n'
            : 'docs/pricing.md · ${chunk.locator}\n';
        expect(chunk.text, startsWith(expected));
      }
      // Both spellings really occur in this one file — the preamble has no
      // heading to be located by, the sections do.
      expect(chunks.first.locator, isEmpty);
      expect(chunks[1].locator, 'Pricing');
    });

    test('a file that is one passage gets the bare path', () {
      final chunks = chunkContextText('lib/rate.dart', 'int rate() => 41;');

      expect(chunks.single.text, startsWith('lib/rate.dart\n'));
      expect(chunks.single.text, contains('int rate() => 41;'));
    });
  });

  group('markdown', () {
    test('the locator is the breadcrumb of the headings above', () {
      final chunks = chunkContextText('docs/pricing.md', priceSheet);

      // Not just `Q4 rates`: a project has four sections called "Notes", and
      // a citation that says which one is the difference between a checkable
      // claim and a shrug.
      expect(locators(chunks), [
        '',
        'Pricing',
        'Pricing > Q4 rates',
        'Pricing > Terms',
        'Contacts',
      ]);
    });

    test('a heading closes every deeper one', () {
      final chunks = chunkContextText('docs/pricing.md', priceSheet);
      final terms = chunks.firstWhere((c) => c.locator.endsWith('Terms'));

      // `## Terms` after `## Q4 rates` is a sibling, not a child. Without the
      // trail being cleared, every later section inherits a heading it is not
      // under and the citation points at the wrong place.
      expect(terms.locator, isNot(contains('Q4 rates')));
    });

    test('text before the first heading is located by nothing', () {
      final chunks = chunkContextText('docs/pricing.md', priceSheet);

      expect(chunks.first.locator, '');
      expect(chunks.first.text, contains('Rates are reviewed each quarter'));
    });

    test('the heading line stays with its section', () {
      final chunks = chunkContextText('docs/pricing.md', priceSheet);
      final q4 = chunks.firstWhere((c) => c.locator.endsWith('Q4 rates'));

      // It is the sentence that says what the passage is about; a section
      // read without it is orphaned.
      expect(q4.text, contains('## Q4 rates'));
      expect(q4.text, contains('41 credits per pallet'));
    });

    test('a long section says which part of it this is', () {
      final long = [
        '# Pricing',
        '',
        '## Q4 rates',
        '',
        paragraph('pallet', 600),
        '',
        paragraph('crate', 600),
        '',
        paragraph('drayage', 600),
        '',
        paragraph('tariff', 600),
      ].join('\n');

      final chunks = chunkContextText('docs/pricing.md', long);

      // Appended rather than replacing the breadcrumb: the heading is still
      // the useful half of the citation.
      expect(locators(chunks), [
        'Pricing',
        'Pricing > Q4 rates · part 1',
        'Pricing > Q4 rates · part 2',
        'Pricing > Q4 rates · part 3',
        'Pricing > Q4 rates · part 4',
      ]);
    });

    test('a heading inside a fenced block is not a section break', () {
      const withFence = '''
# Pricing

Run the report like this:

```
# not a heading, a shell comment
bin/report --desk marrowfield
```

The output lands in reports/.

# Contacts

Devi Okonkwo owns the sheet.
''';

      final chunks = chunkContextText('docs/pricing.md', withFence);

      // Inside a fence a `#` is a Python comment or a shell prompt. Cutting
      // there splits a command from its explanation and invents a section
      // called "not a heading, a shell comment".
      expect(locators(chunks), ['Pricing', 'Contacts']);
      expect(chunks.first.text, contains('# not a heading, a shell comment'));
    });

    test('CLAUDE.md and SKILL.md take the markdown path', () {
      const skill = '''
# Vendor notes

## When to use

Reach for this before quoting a Halcyon Freight lane.
''';

      expect(
        locators(chunkContextText('CLAUDE.md', priceSheet)),
        contains('Pricing > Q4 rates'),
      );
      expect(
        locators(chunkContextText('.claude/skills/vendor-notes/SKILL.md', skill)),
        ['Vendor notes', 'Vendor notes > When to use'],
      );
    });
  });

  group('code and structured config', () {
    String dartFile(int lines) =>
        [for (var i = 1; i <= lines; i++) 'final step$i = ${i * 2};'].join('\n');

    test('windows of sixty lines overlap by ten', () {
      final chunks = chunkContextText('lib/pipeline.dart', dartFile(150));

      // The locator is what an editor shows in its gutter, so a citation can
      // be opened. En dash, because it is a range a person reads.
      expect(locators(chunks), ['lines 1–60', 'lines 51–110', 'lines 101–150']);
    });

    test('the overlap really overlaps', () {
      final chunks = chunkContextText('lib/pipeline.dart', dartFile(150));

      // Ten carried lines are why a function's signature and its body are
      // never in different passages only.
      expect(chunks[0].text, contains('final step55 = 110;'));
      expect(chunks[1].text, contains('final step55 = 110;'));
      expect(chunks[1].text, contains('final step105 = 210;'));
      expect(chunks[2].text, contains('final step105 = 210;'));
    });

    test('a short code file is one passage with nowhere to point', () {
      final chunks = chunkContextText('lib/rate.dart', dartFile(12));

      expect(chunks, hasLength(1));
      expect(chunks.single.locator, '');
    });

    test('yaml and json go through the window path too', () {
      final yaml = [for (var i = 1; i <= 150; i++) 'key$i: value$i'].join('\n');
      final json = [for (var i = 1; i <= 150; i++) '  "key$i": $i,'].join('\n');

      // Config has no paragraphs and no headings: its lines are the unit of
      // meaning, exactly as code's are.
      expect(locators(chunkContextText('deploy.yaml', yaml)).first, 'lines 1–60');
      expect(locators(chunkContextText('conf.json', json)).first, 'lines 1–60');
    });
  });

  group('everything else', () {
    test('prose is packed into parts', () {
      final text = [
        paragraph('alpha', 600),
        paragraph('bravo', 600),
        paragraph('charlie', 600),
      ].join('\n\n');

      expect(
        locators(chunkContextText('notes.txt', text)),
        ['part 1', 'part 2', 'part 3'],
      );
    });

    test('a single passage of prose has no locator', () {
      final chunks = chunkContextText('notes.txt', 'Devi owns the sheet.');

      // `part 1` of one part is noise on every line that quotes it.
      expect(chunks.single.locator, '');
      expect(chunks.single.text, 'notes.txt\nDevi owns the sheet.');
    });
  });

  test('a huge file stops at sixty passages, numbered without a gap', () {
    final chunks = chunkContextText(
      'notes.txt',
      [for (var i = 0; i < 400; i++) paragraph('clause$i', 900)].join('\n\n'),
    );

    // Each passage costs a POST at embed time and a row forever, and the
    // sixty-first is not where the answer is.
    expect(chunks, hasLength(maxChunksPerContextFile));
    expect([for (final c in chunks) c.seq], [for (var i = 0; i < 60; i++) i]);
  });

  test('the same text chunks the same way twice', () {
    final first = chunkContextText('docs/pricing.md', priceSheet);
    final second = chunkContextText('docs/pricing.md', priceSheet);

    // The contract the reconcile handler leans on: `replaceChunks` is a
    // delete and an insert, so a re-derived list replaces the passages with
    // themselves rather than doubling them, and a park on the embedding
    // server resumes instead of restarting.
    expect(second, hasLength(first.length));
    for (var i = 0; i < first.length; i++) {
      expect(second[i].seq, first[i].seq);
      expect(second[i].locator, first[i].locator);
      expect(second[i].text, first[i].text);
    }
  });

  group('contextSection', () {
    /// A section with a nested one under it, a sibling that is not, and a
    /// fenced heading that is neither.
    const manual = """
Rates are reviewed each quarter.

## Pricing

The desk publishes one sheet.

### Q4 rates

Standard freight is 41 credits per pallet.

## Terms

Net thirty.
""";

    test('a section carries the sections nested under it', () {
      final section = contextSection('docs/pricing.md', manual, 'Pricing');

      // The whole of `## Pricing` is `## Pricing` AND its `### Q4 rates`:
      // the question the caller is asking is "what does this section say",
      // and a section stops at its next SIBLING.
      expect(section, isNotNull);
      expect(section, contains('The desk publishes one sheet.'));
      expect(section, contains('### Q4 rates'));
      expect(section, contains('41 credits per pallet'));
      // And stops there. `## Terms` is the next section, not part of this one.
      expect(section, isNot(contains('Net thirty')));
    });

    test('a nested section is just itself', () {
      final section =
          contextSection('docs/pricing.md', manual, 'Pricing > Q4 rates');

      expect(section, contains('41 credits per pallet'));
      expect(section, isNot(contains('The desk publishes one sheet.')));
      expect(section, isNot(contains('Net thirty')));
    });

    test('a part suffix names the whole section it is part of', () {
      // `Pricing · part 2` is one passage of a section; the section is what
      // was asked for.
      expect(
        contextSection('docs/pricing.md', manual, 'Pricing · part 2'),
        contextSection('docs/pricing.md', manual, 'Pricing'),
      );
    });

    test('a heading inside a code fence is not a section', () {
      const fenced = """
## Setup

```sh
# Install
brew install ripgrep
```

Then run it.
""";

      expect(contextSection('README.md', fenced, 'Install'), isNull);
      final setup = contextSection('README.md', fenced, 'Setup');
      expect(setup, contains('brew install ripgrep'));
      expect(setup, contains('Then run it.'));
    });

    test('an empty locator is the whole file', () {
      expect(contextSection('docs/pricing.md', manual, ''), manual);
    });

    test('a breadcrumb this file does not have answers null', () {
      expect(contextSection('docs/pricing.md', manual, 'Renewals'), isNull);
      // And a guess about a section that only LOOKS like one is still null.
      expect(contextSection('docs/pricing.md', manual, 'Q4 rates'), isNull);
    });

    test('a line window reaches two windows on', () {
      final code = [for (var i = 1; i <= 200; i++) 'line $i'].join('\n');

      final section = contextSection('lib/rate.dart', code, 'lines 61–120');

      // A function rarely ends where the sixty-line window it was cut at
      // did, so the reader gets the next one too.
      expect(section, isNotNull);
      expect(section!.split('\n').first, 'line 61');
      expect(section.split('\n').last, 'line 180');
      // The hyphen a model types back is the same range.
      expect(contextSection('lib/rate.dart', code, 'lines 61-120'), section);
    });

    test('a line window that runs off the end stops at the end', () {
      final code = [for (var i = 1; i <= 80; i++) 'line $i'].join('\n');

      final section = contextSection('lib/rate.dart', code, 'lines 61–80');

      expect(section!.split('\n').last, 'line 80');
      // Past the file entirely is nothing, not an empty string.
      expect(contextSection('lib/rate.dart', code, 'lines 900–960'), isNull);
      expect(contextSection('lib/rate.dart', code, 'lines wat'), isNull);
    });

    test('every other locator is the whole text, for the caller to clamp', () {
      const notes = 'Devi owns the sheet.\n\nThe rung is settled.';

      for (final locator in ['part 2', 'digest', '']) {
        expect(contextSection('notes.txt', notes, locator), notes,
            reason: locator);
      }
    });

    test("a chunker's own locators all read back", () {
      // The property that matters: every locator this file writes is one
      // this function can find again.
      for (final chunk in chunkContextText('docs/pricing.md', priceSheet)) {
        expect(
          contextSection('docs/pricing.md', priceSheet, chunk.locator),
          isNotNull,
          reason: chunk.locator,
        );
      }
    });

    test("a long preamble's own locators read back too", () {
      // A file whose intro runs past the prose packer's thousand characters
      // before its first heading. The preamble has no breadcrumb, so the
      // chunker locates its passages `part 1` and `part 2` with no section
      // in front — and those are exactly the locators the selector can name.
      final intro = List.filled(
        30,
        'The desk reviews every rate before the quarter closes, and the '
                'sheet below is what it publishes.',
      ).join(' ');
      final long = '$intro\n\n## Pricing\n\nStandard freight is 41 credits.\n';

      final chunks = chunkContextText('docs/intro.md', long);
      expect(
        chunks.map((chunk) => chunk.locator),
        containsAll(<String>['part 1', 'part 2']),
      );
      for (final chunk in chunks) {
        expect(
          contextSection('docs/intro.md', long, chunk.locator),
          isNotNull,
          reason: chunk.locator,
        );
      }
    });
  });

  test('nothing to say is no passages', () {
    // An empty passage costs an embedding and matches everything weakly.
    for (final path in ['notes.md', 'lib/rate.dart', 'notes.txt']) {
      expect(chunkContextText(path, ''), isEmpty, reason: path);
      expect(chunkContextText(path, '   \n\n  \t \n'), isEmpty, reason: path);
    }
  });
}
