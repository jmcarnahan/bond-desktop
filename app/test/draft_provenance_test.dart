import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a draft says it was written from.
///
/// Two promises: the column round-trips, and a column that does NOT round-trip
/// — hand-edited, written by an older build, garbage — costs a caption and
/// never the composer around it.
void main() {
  const full = DraftProvenance(
    documents: ['Lease Addendum.pdf'],
    directories: ['acme'],
    files: [
      (dir: 'acme', path: 'docs/pricing.md', locator: 'Pricing > Q4 rates'),
    ],
    skills: ['vendor-replies'],
  );

  group('the column', () {
    test('round-trips through encode and decode', () {
      final decoded = DraftProvenance.decode(full.encode())!;

      expect(decoded.documents, full.documents);
      expect(decoded.directories, full.directories);
      expect(decoded.files, full.files);
      expect(decoded.skills, full.skills);
      expect(decoded.isEmpty, isFalse);
    });

    test('carries all four keys even when three are empty', () {
      const documentsOnly = DraftProvenance(
        documents: ['a file'],
        directories: [],
        files: [],
        skills: [],
      );

      expect(documentsOnly.encode(), contains('"directories":[]'));
      expect(documentsOnly.encode(), contains('"files":[]'));
      expect(documentsOnly.encode(), contains('"skills":[]'));
    });

    test('none is empty and encodes to nothing worth storing', () {
      expect(DraftProvenance.none.isEmpty, isTrue);
      expect(DraftProvenance.none.caption(), isNull);
    });
  });

  group('a column that will not decode', () {
    test('null, empty and garbage all read as nothing recorded', () {
      expect(DraftProvenance.decode(null), isNull);
      expect(DraftProvenance.decode(''), isNull);
      expect(DraftProvenance.decode('nope'), isNull);
      // Valid JSON that is not a map. Every caller means the same thing by
      // it, so there is one answer for all of them.
      expect(DraftProvenance.decode('[]'), isNull);
      expect(DraftProvenance.decode('7'), isNull);
    });

    test('missing keys are empty lists, not a failure', () {
      final decoded = DraftProvenance.decode('{"documents":["a.pdf"]}')!;

      expect(decoded.documents, ['a.pdf']);
      expect(decoded.directories, isEmpty);
      expect(decoded.files, isEmpty);
      expect(decoded.skills, isEmpty);
    });

    test('entries of the wrong shape are dropped, and the rest survives', () {
      final decoded = DraftProvenance.decode(
        '{"documents":["a.pdf",7,null],'
        '"directories":"acme",'
        '"files":[{"path":"docs/p.md"},{"dir":"acme"},"nope",'
        '{"dir":"acme","path":"docs/q.md","locator":"digest"}],'
        '"skills":[{"name":"x"},"vendor-replies"]}',
      )!;

      expect(decoded.documents, ['a.pdf']);
      // A string where a list belongs is a key this build cannot read.
      expect(decoded.directories, isEmpty);
      // A file needs a path to be worth naming; a directory and a locator are
      // both allowed to be missing.
      expect(decoded.files, [
        (dir: '', path: 'docs/p.md', locator: ''),
        (dir: 'acme', path: 'docs/q.md', locator: 'digest'),
      ]);
      expect(decoded.skills, ['vendor-replies']);
    });
  });

  group('the caption', () {
    test('documents only names the files the sender attached', () {
      const provenance = DraftProvenance(
        documents: ['Lease Addendum.pdf'],
        directories: [],
        files: [],
        skills: [],
      );

      expect(
        provenance.caption(),
        '✨ Suggested reply — drafted from this thread, your past mail '
        'and Lease Addendum.pdf',
      );
    });

    test('directories only names the project and what was read in it', () {
      const provenance = DraftProvenance(
        documents: [],
        directories: ['acme'],
        files: [
          (dir: 'acme', path: 'docs/pricing.md', locator: 'Pricing > Q4 rates'),
        ],
        skills: ['vendor-replies'],
      );

      expect(
        provenance.caption(),
        '✨ Suggested reply — drafted from this thread, your past mail '
        'and «acme» '
        '(docs/pricing.md § Pricing › Q4 rates · SKILL vendor-replies)',
      );
    });

    test('and the heading path is drawn as a breadcrumb, in the caption only',
        () {
      // `>` is the chunker's spelling and the index's; a comparison operator
      // in the middle of a sentence is not what a person reading a caption
      // above their reply box should be shown. The stored column keeps the
      // chunker's word, so the locator in the row still matches the locator
      // in the index.
      expect(full.caption(), contains('Pricing › Q4 rates'));
      expect(full.caption(), isNot(contains('Pricing > Q4 rates')));
      expect(full.encode(), contains('Pricing > Q4 rates'));
      expect(DraftProvenance.decode(full.encode())!.files.single.locator,
          'Pricing > Q4 rates');
    });

    test('both, and the documents come first', () {
      expect(
        full.caption(),
        '✨ Suggested reply — drafted from this thread, your past mail, '
        'Lease Addendum.pdf and «acme» '
        '(docs/pricing.md § Pricing › Q4 rates · SKILL vendor-replies)',
      );
    });

    test('a passage with no locator is named by its path alone', () {
      const provenance = DraftProvenance(
        documents: [],
        directories: ['acme'],
        files: [(dir: 'acme', path: 'notes.md', locator: '')],
        skills: [],
      );

      expect(provenance.caption(), endsWith('«acme» (notes.md)'));
    });

    test('a digest is called a summary, which is the word on the switch', () {
      const provenance = DraftProvenance(
        documents: [],
        directories: ['acme'],
        files: [(dir: 'acme', path: 'analysis.html', locator: 'digest')],
        skills: [],
      );

      expect(provenance.caption(), endsWith('(analysis.html § summary)'));
    });

    test('three files, then a count — this is a caption, not a manifest', () {
      const provenance = DraftProvenance(
        documents: [],
        directories: ['acme'],
        files: [
          (dir: 'acme', path: 'a.md', locator: ''),
          (dir: 'acme', path: 'b.md', locator: ''),
          (dir: 'acme', path: 'c.md', locator: ''),
          (dir: 'acme', path: 'd.md', locator: ''),
          (dir: 'acme', path: 'e.md', locator: ''),
        ],
        skills: [],
      );

      expect(provenance.caption(), endsWith('(a.md · b.md · c.md · +2 more)'));
    });

    test('two directories are listed as prose', () {
      const provenance = DraftProvenance(
        documents: [],
        directories: ['acme', 'ridge'],
        files: [],
        skills: [],
      );

      expect(
        provenance.caption(),
        '✨ Suggested reply — drafted from this thread, your past mail, '
        '«acme» and «ridge»',
      );
    });
  });
}
