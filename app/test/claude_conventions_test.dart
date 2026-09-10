import 'package:bond_inbox/services/context/claude_conventions.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conventions a Claude Code project already keeps, read without a model.
///
/// Pure functions over strings, so every case here is a literal in and a
/// literal out — no database, no disk, no clock. What is being pinned is
/// mostly the tolerances: a header the author is midway through writing, a
/// `paths` line written three different ways, an import that points at
/// nothing. Every one of those has to answer rather than throw, because they
/// all run inside a reconcile pass that must not fail over one odd file.
void main() {
  group('frontmatter', () {
    test('a leading fence is read as YAML and the body starts after it', () {
      final parsed = parseFrontmatter(
        '---\nname: pricing\ndescription: How rates are set\n---\n'
        '# Pricing\n\nThe body.\n',
      );

      expect(parsed.yaml['name'], 'pricing');
      expect(parsed.yaml['description'], 'How rates are set');
      expect(parsed.body, '# Pricing\n\nThe body.\n');
    });

    test('a file with no fence is all body and declares nothing', () {
      final parsed = parseFrontmatter('# Pricing\n\nNo header here.\n');

      expect(parsed.yaml, isEmpty);
      expect(parsed.body, '# Pricing\n\nNo header here.\n');
    });

    test('a fence that never closes is all body', () {
      final parsed = parseFrontmatter('---\nname: pricing\n# Pricing\n');

      expect(parsed.yaml, isEmpty);
      expect(parsed.body, '---\nname: pricing\n# Pricing\n');
    });

    test('CRLF line endings are read the same as LF', () {
      final parsed = parseFrontmatter(
        '---\r\nname: pricing\r\n---\r\n# Pricing\r\n',
      );

      expect(parsed.yaml['name'], 'pricing');
      expect(parsed.body, '# Pricing\r\n');
    });

    test('YAML that will not parse declares nothing rather than throwing',
        () {
      // A header somebody is midway through writing. The file is still a
      // file, and the walk must not fail over it.
      final parsed = parseFrontmatter('---\nname: [unclosed\n---\nBody.\n');

      expect(parsed.yaml, isEmpty);
      expect(parsed.body, '---\nname: [unclosed\n---\nBody.\n');
    });

    test('a header that is not a map declares nothing, and the fence still '
        'comes off', () {
      final parsed = parseFrontmatter('---\n- one\n- two\n---\nBody.\n');

      // Those two `---` lines were real frontmatter whatever sits between
      // them. A body that still carried them would hand `---` to the caller
      // that falls back to the first line of the body for a description.
      expect(parsed.yaml, isEmpty);
      expect(parsed.body, 'Body.\n');
    });

    test('unknown keys are kept, and nested ones come back as plain maps',
        () {
      final parsed = parseFrontmatter(
        '---\nname: pricing\nallowed-tools: [Read, Grep]\n'
        'meta:\n  owner: wren\n---\nBody.\n',
      );

      expect(parsed.yaml['allowed-tools'], ['Read', 'Grep']);
      expect(parsed.yaml['meta'], isA<Map<String, Object?>>());
      expect((parsed.yaml['meta']! as Map)['owner'], 'wren');
    });
  });

  group('cleanDescription', () {
    test('angle-bracket runs come out and the whitespace collapses', () {
      expect(
        cleanDescription('Use when <argument> is\n  a  rate <b>quote</b>'),
        'Use when is a rate quote',
      );
    });

    test('anything that is not a string is no description at all', () {
      expect(cleanDescription(null), '');
      expect(cleanDescription(const ['a list']), '');
      expect(cleanDescription(42), '');
    });

    test('a very long description is clamped', () {
      expect(cleanDescription('x' * 900).length, 500);
    });
  });

  group('skillOf', () {
    test('the folder name wins over the frontmatter name', () {
      // Claude Code invokes the FOLDER, so a header whose name has drifted
      // would have the app matching on a word nobody can type.
      final skill = skillOf(
        '.claude/skills/rate-quote/SKILL.md',
        '---\nname: something-else\ndescription: Quote a rate\n---\nBody.\n',
      )!;

      expect(skill.name, 'rate-quote');
      expect(skill.description, 'Quote a rate');
    });

    test('a skill with no description falls back to its first real line', () {
      final skill = skillOf(
        '.claude/skills/rate-quote/SKILL.md',
        '---\nname: rate-quote\n---\n# Rate quote\n\nQuotes a renewal rate '
            'from the current table.\n',
      )!;

      expect(
        skill.description,
        'Quotes a renewal rate from the current table.',
      );
    });

    test('a list where the header goes still falls back to the body', () {
      final skill = skillOf(
        '.claude/skills/rate-quote/SKILL.md',
        '---\n- one\n- two\n---\nQuote a renewal rate.\n',
      )!;

      // The header declares nothing, so the first prose line is the guess —
      // and `---` is not a sentence anybody wrote about this skill.
      expect(skill.description, 'Quote a renewal rate.');
    });

    test('a file that is not a skill is null', () {
      expect(skillOf('docs/pricing.md', '---\nname: x\n---\n'), isNull);
      expect(skillOf('.claude/rules/style.md', 'Anything.'), isNull);
    });
  });

  group('ruleOf', () {
    test('a YAML list of paths comes through trimmed', () {
      final rule = ruleOf(
        '.claude/rules/style.md',
        '---\npaths:\n  - "src/**/*.dart"\n  - "test/**"\n'
            'description: House style\n---\nBody.\n',
      );

      expect(rule.paths, ['src/**/*.dart', 'test/**']);
      expect(rule.description, 'House style');
    });

    test('one path written as a string is one path', () {
      final rule = ruleOf(
        '.claude/rules/style.md',
        '---\npaths: src/**/*.dart\n---\nBody.\n',
      );

      expect(rule.paths, ['src/**/*.dart']);
    });

    test('a comma-separated string is several paths', () {
      final rule = ruleOf(
        '.claude/rules/style.md',
        '---\npaths: "src/**, test/**, "\n---\nBody.\n',
      );

      // The trailing empty is dropped rather than stored as a glob that
      // matches everything.
      expect(rule.paths, ['src/**', 'test/**']);
    });

    test('a leading ./ is stripped, because a rel path never carries one',
        () {
      final rule = ruleOf(
        '.claude/rules/style.md',
        '---\npaths:\n  - ./src/**\n  - ./docs/**\n---\n',
      );

      expect(rule.paths, ['src/**', 'docs/**']);
    });

    test('a file that is not a rule is empty on both halves', () {
      final rule = ruleOf('docs/style.md', '---\npaths: src/**\n---\n');

      expect(rule.paths, isEmpty);
      expect(rule.description, '');
    });
  });

  group('resolveImports', () {
    Future<String?> Function(String) readerOf(Map<String, String> files) =>
        (relPath) async => files[relPath];

    test('one hop pulls the file in, fenced with the path on both sides',
        () async {
      final out = await resolveImports(
        '# Atlas\n@docs/conventions.md\nEnd.\n',
        readerOf({'docs/conventions.md': 'Cite the notebook.'}),
      );

      expect(out, contains('<!-- imported: docs/conventions.md -->'));
      expect(out, contains('Cite the notebook.'));
      expect(out, contains('<!-- end docs/conventions.md -->'));
      expect(out, contains('End.'));
    });

    test('the words after the path stay in the notes', () async {
      final out = await resolveImports(
        '@docs/conventions.md — the short version\n',
        readerOf({'docs/conventions.md': 'Cite the notebook.'}),
      );

      expect(out, contains('— the short version'));
      expect(out, contains('Cite the notebook.'));
    });

    test('two hops resolve and the third is left as the line it was',
        () async {
      final out = await resolveImports(
        '@a.md\n',
        readerOf({
          'a.md': 'A\n@b.md\n',
          'b.md': 'B\n@c.md\n',
          'c.md': 'C should never appear',
        }),
      );

      expect(out, contains('A'));
      expect(out, contains('B'));
      expect(out, isNot(contains('C should never appear')));
      // Left exactly as the author wrote it, which is what a note pointing
      // at a document three levels down should read as.
      expect(out, contains('@c.md'));
    });

    test('a cycle leaves the line rather than recursing forever', () async {
      // Deliberately generous with hops so that what stops this is the
      // STACK and not the hop count.
      final out = await resolveImports(
        '@a.md\n',
        readerOf({'a.md': 'A\n@b.md\n', 'b.md': 'B\n@a.md\n'}),
        hops: 5,
      );

      expect(out, contains('A'));
      expect(out, contains('B'));
      expect(out, contains('@a.md'));
    });

    test('an import of a file nothing indexed is left as the line', () async {
      final out = await resolveImports('@docs/gone.md\n', readerOf(const {}));

      expect(out.trim(), '@docs/gone.md');
    });

    test('a line inside a code fence is never an import', () async {
      final out = await resolveImports(
        'Write it like this:\n```\n@docs/conventions.md\n```\nDone.\n',
        readerOf({'docs/conventions.md': 'SHOULD NOT APPEAR'}),
      );

      // A `CLAUDE.md` documenting this very syntax must not import itself
      // into its own example.
      expect(out, isNot(contains('SHOULD NOT APPEAR')));
      expect(out, contains('@docs/conventions.md'));
    });

    test('a tilde line does not close a backtick block', () async {
      final out = await resolveImports(
        'Write it like this:\n```\n~~~\n@docs/conventions.md\n```\nDone.\n',
        readerOf({'docs/conventions.md': 'SHOULD NOT APPEAR'}),
      );

      // The two markers are not interchangeable. Treating the `~~~` as the
      // close leaves the rest of the block reading as prose, and the `@`
      // line inside the example gets resolved into the notes documenting it.
      expect(out, isNot(contains('SHOULD NOT APPEAR')));
      expect(out, contains('@docs/conventions.md'));
    });

    test('a root that imports a file importing it back is not inlined into '
        'itself', () async {
      final out = await resolveImports(
        '# Atlas\n@docs/a.md\nEnd.\n',
        readerOf({'docs/a.md': 'A\n@../CLAUDE.md\n'}),
        hops: 5,
        selfPath: 'CLAUDE.md',
      );

      expect(out, contains('<!-- imported: docs/a.md -->'));
      // The root is not on the cycle stack unless the caller puts it there,
      // and without it the notes get inlined into the middle of themselves.
      expect(out, isNot(contains('<!-- imported: CLAUDE.md -->')));
      expect(out, contains('@../CLAUDE.md'));
    });

    test('an @ inside inline code or followed by a space is not an import',
        () async {
      final out = await resolveImports(
        '`@docs/conventions.md` is the syntax.\n@ docs/conventions.md\n'
        'Ask wren@example.com.\n',
        readerOf({'docs/conventions.md': 'SHOULD NOT APPEAR'}),
      );

      expect(out, isNot(contains('SHOULD NOT APPEAR')));
    });

    test('a home-relative or absolute import is left alone', () async {
      final out = await resolveImports(
        '@~/notes/global.md\n@/etc/hosts\n',
        (relPath) async => 'SHOULD NOT APPEAR',
      );

      expect(out, isNot(contains('SHOULD NOT APPEAR')));
      expect(out, contains('@~/notes/global.md'));
      expect(out, contains('@/etc/hosts'));
    });

    test('an import that climbs out of the root is left alone', () async {
      final out = await resolveImports(
        '@../outside.md\n',
        (relPath) async => 'SHOULD NOT APPEAR',
      );

      expect(out, isNot(contains('SHOULD NOT APPEAR')));
      expect(out, contains('@../outside.md'));
    });

    test('a relative import resolves against the directory it sits in',
        () async {
      final read = <String>[];
      final out = await resolveImports(
        '@sibling.md\n',
        (relPath) async {
          read.add(relPath);
          return relPath == 'docs/sibling.md' ? 'The sibling.' : null;
        },
        baseDir: 'docs',
      );

      expect(read, ['docs/sibling.md']);
      expect(out, contains('The sibling.'));
    });

    test('a nested import resolves against ITS own directory', () async {
      final out = await resolveImports(
        '@docs/one.md\n',
        readerOf({
          'docs/one.md': '@two.md\n',
          'docs/two.md': 'The second.',
        }),
      );

      expect(out, contains('The second.'));
    });

    test('the result is clamped at twenty thousand characters', () async {
      final out = await resolveImports(
        '@big.md\n',
        readerOf({'big.md': 'x' * 40000}),
      );

      expect(out.length, 20000);
    });
  });
}
