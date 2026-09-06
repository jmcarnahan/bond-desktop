import 'package:bond_inbox/services/attachments/attachment_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a document becomes before it is embedded.
///
/// Every rule here is about ONE question: when a search lands on a passage,
/// can the reader tell where it came from? That is why the locator is asserted
/// as hard as the text, and why the shape is read off the extractor's own
/// delimiters rather than off a file name that says `.xlsx` and means nothing.
void main() {
  List<AttachmentChunk> chunk(
    String text, {
    String contentType = 'text/plain',
    String? name = 'Document.txt',
  }) =>
      chunkAttachmentText(text, contentType: contentType, name: name);

  /// A worksheet as the server writes one: a header line, a column row, then
  /// [rows] numbered data rows.
  String sheet(String title, int rows, {int from = 1}) => [
        '--- Sheet: $title ---',
        'Unit\tTenant\tRent',
        for (var i = from; i <= rows; i++) '$i\tTenant $i\t${1000 + i}',
      ].join('\n');

  group('a spreadsheet', () {
    test('chunks per forty rows with the header repeated', () {
      final chunks = chunk(sheet('Rent Roll', 95), contentType: 'application/vnd.ms-excel');

      expect(chunks, hasLength(3));
      for (final piece in chunks) {
        // Both header lines ride every passage: a vector for forty bare
        // numbers says nothing about what the numbers are.
        expect(piece.text, startsWith('--- Sheet: Rent Roll ---\n'));
        expect(piece.text, contains('Unit\tTenant\tRent'));
      }
      expect(chunks.first.text, contains('Tenant 1\t'));
      expect(chunks.first.text, isNot(contains('Tenant 41\t')));
      expect(chunks.last.text, contains('Tenant 95\t'));
    });

    test('the locator names the sheet and the row range', () {
      final chunks = chunk(sheet('Rent Roll', 95));

      // Row 1 is the column header, so the first data row is row 2 — the
      // numbers a person reads down the side of the spreadsheet.
      expect(chunks.map((c) => c.locator), [
        'Sheet Rent Roll rows 2–41',
        'Sheet Rent Roll rows 42–81',
        'Sheet Rent Roll rows 82–96',
      ]);
    });

    test('every sheet in the workbook gets its own passages', () {
      final chunks = chunk('${sheet('Q3', 5)}\n${sheet('Q4', 50)}');

      expect(chunks.map((c) => c.locator), [
        'Sheet Q3 rows 2–6',
        'Sheet Q4 rows 2–41',
        'Sheet Q4 rows 42–51',
      ]);
    });

    test('a sheet with nothing under its header is one passage', () {
      final chunks = chunk('--- Sheet: Notes ---\nUnit\tTenant\tRent');

      expect(chunks.single.locator, 'Sheet Notes');
    });

    test('the extractor\'s truncation notice is not a row', () {
      final chunks = chunk(
        '${sheet('Rent Roll', 3)}\n[... showing first 500 of ~2400 rows]',
      );

      // It is a statement about the extraction. Embedded, it would make every
      // truncated workbook a near neighbour of every other one.
      expect(chunks.single.text, isNot(contains('showing first')));
      expect(chunks.single.locator, 'Sheet Rent Roll rows 2–4');
    });

    test('a refused spreadsheet chunks as prose', () {
      // The mime type says workbook and the text says otherwise, because the
      // extractor gave up. Shape follows the text, always.
      final chunks = chunk(
        'This workbook is password protected and could not be read.',
        contentType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        name: 'Rent Roll.xlsx',
      );

      expect(chunks.single.locator, '');
      expect(chunks.single.text, startsWith('This workbook'));
    });
  });

  group('a deck', () {
    const deck = '--- Slide 1 ---\nQ3 review\n\n'
        '--- Slide 2 ---\nRevenue is up eleven percent\n'
        '[Speaker Notes]: do not promise a date here\n\n'
        '--- Slide 3 ---\nNext steps';

    test('chunks one passage per slide', () {
      final chunks = chunk(deck);

      expect(chunks, hasLength(3));
      expect(chunks.map((c) => c.locator), ['slide 1', 'slide 2', 'slide 3']);
      // The header line stays in: "slide 2" is part of what the passage says.
      expect(chunks[1].text, startsWith('--- Slide 2 ---'));
    });

    test('speaker notes stay with their slide', () {
      final chunks = chunk(deck);

      // A note read apart from its slide is a sentence with no subject.
      expect(chunks[1].text, contains('do not promise a date here'));
      expect(chunks[2].text, isNot(contains('do not promise a date here')));
    });
  });

  group('prose', () {
    /// A paragraph of roughly [chars] characters, made of whole words.
    String paragraph(String word, int chars) {
      final buffer = StringBuffer();
      while (buffer.length < chars) {
        buffer.write('$word ');
      }
      return buffer.toString().trim();
    }

    test('splits on paragraphs with an overlap that starts on a word', () {
      final text = [
        paragraph('alpha', 600),
        paragraph('bravo', 600),
        paragraph('charlie', 600),
      ].join('\n\n');

      final chunks = chunk(text);

      expect(chunks.length, greaterThan(1));
      for (final piece in chunks.skip(1)) {
        // The overlap is trimmed FORWARD to a boundary, so a passage never
        // opens on half a word — `pha alpha` reads as a mistake and embeds as
        // noise.
        expect(piece.text.split(' ').first, anyOf('alpha', 'bravo', 'charlie'));
      }
      // What the overlap is for: the tail of one passage is in the head of the
      // next, so a sentence on a boundary is embedded whole at least once.
      expect(chunks[1].text, contains('alpha'));
    });

    test('an over-long paragraph is split rather than dropped', () {
      // One 3,500-character wall with no blank line in it — a legitimate
      // shape of extracted PDF.
      final chunks = chunk(paragraph('lease', 3500));

      expect(chunks.length, greaterThanOrEqualTo(4));
      expect(chunks.map((c) => c.locator).toList(), [
        'part 1',
        'part 2',
        'part 3',
        'part 4',
      ]);
    });

    test('a document that is one passage has no locator', () {
      final chunks = chunk('The tenant pays the first month on the fourth.');

      // 'part 1' of one part is noise on every line that quotes it.
      expect(chunks.single.locator, '');
    });

    test('an empty document produces no chunks', () {
      expect(chunk(''), isEmpty);
      expect(chunk('   \n\n  \t \n'), isEmpty);
    });

    test('a hundred-page document stops at sixty chunks', () {
      final chunks = chunk(
        List.generate(400, (i) => paragraph('clause$i', 900)).join('\n\n'),
      );

      // Each passage costs a POST at embed time and a row forever, and the
      // sixty-first is not where the answer is.
      expect(chunks, hasLength(maxChunksPerAttachment));
    });
  });
}
