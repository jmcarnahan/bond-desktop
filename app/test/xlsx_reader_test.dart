import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading a workbook without the `excel` package.
///
/// It could not be used — its dependency pins fight pdfrx's — so the few parts
/// a preview needs are read straight out of the zip, and this file is what says
/// they are read right. Every workbook below is BUILT HERE, from strings: a
/// binary fixture would be a file nobody can review in a public repository, and
/// the point of most of these tests is the exact XML that produced the answer.
void main() {
  /// One workbook, zipped.
  ///
  /// [sheets] are `(name, sheetData XML)` in the order the workbook lists them.
  Uint8List workbook({
    required List<(String, String)> sheets,
    List<String>? shared,
    bool withRels = true,
  }) {
    final archive = Archive();

    final entries = [
      for (var i = 0; i < sheets.length; i++)
        '<sheet name="${sheets[i].$1}" sheetId="${i + 1}" '
            'r:id="rId${i + 1}"/>',
    ].join();
    archive.add(ArchiveFile.string(
      'xl/workbook.xml',
      '<?xml version="1.0"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>$entries</sheets></workbook>',
    ));

    if (withRels) {
      final rels = [
        for (var i = 0; i < sheets.length; i++)
          '<Relationship Id="rId${i + 1}" '
              'Target="worksheets/sheet${i + 1}.xml"/>',
      ].join();
      archive.add(ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '<?xml version="1.0"?><Relationships>$rels</Relationships>',
      ));
    }

    if (shared != null) {
      final items = [
        for (final value in shared) '<si><t>$value</t></si>',
      ].join();
      archive.add(ArchiveFile.string(
        'xl/sharedStrings.xml',
        '<?xml version="1.0"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '$items</sst>',
      ));
    }

    for (var i = 0; i < sheets.length; i++) {
      archive.add(ArchiveFile.string(
        'xl/worksheets/sheet${i + 1}.xml',
        '<?xml version="1.0"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>${sheets[i].$2}</sheetData></worksheet>',
      ));
    }

    return ZipEncoder().encodeBytes(archive);
  }

  String row(int number, String cells) => '<row r="$number">$cells</row>';

  test('a two-sheet workbook comes back in the order the workbook lists them',
      () {
    final tables = decodeXlsx(workbook(
      sheets: [
        ('Rates', row(1, '<c r="A1" t="inlineStr"><is><t>Term</t></is></c>')),
        ('Notes', row(1, '<c r="A1" t="inlineStr"><is><t>Memo</t></is></c>')),
      ],
    ));

    expect([for (final s in tables.sheets) s.name], ['Rates', 'Notes']);
  });

  test('shared strings and inline strings both read as words', () {
    final tables = decodeXlsx(workbook(
      shared: ['Product', 'Rate'],
      sheets: [
        (
          'Sheet1',
          row(1, '<c r="A1" t="s"><v>0</v></c>'
                  '<c r="B1" t="inlineStr"><is><t>Rate</t></is></c>'),
        ),
      ],
    ));

    expect(tables.sheets.single.header, ['Product', 'Rate']);
  });

  test('a rich-text shared string keeps every run', () {
    // A word somebody bolded splits the string across two <t> runs; reading
    // only the first truncates the cell.
    final archive = Archive()
      ..add(ArchiveFile.string(
        'xl/workbook.xml',
        '<workbook xmlns:r="r"><sheets>'
        '<sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>',
      ))
      ..add(ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '<Relationships>'
        '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
        '</Relationships>',
      ))
      ..add(ArchiveFile.string(
        'xl/sharedStrings.xml',
        '<sst><si><r><t>Net </t></r><r><t>30</t></r></si></sst>',
      ))
      ..add(ArchiveFile.string(
        'xl/worksheets/sheet1.xml',
        '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="s"><v>0</v></c></row>'
        '</sheetData></worksheet>',
      ));

    final tables = decodeXlsx(ZipEncoder().encodeBytes(archive));

    expect(tables.sheets.single.header, ['Net 30']);
  });

  test('a gap in the columns is an empty cell, not a shifted one', () {
    final tables = decodeXlsx(workbook(
      shared: ['A', 'C'],
      sheets: [
        (
          'Sheet1',
          row(1, '<c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c>'),
        ),
      ],
    ));

    expect(tables.sheets.single.header, ['A', '', 'C']);
  });

  test('a cell reference past the last column is read as the next column along',
      () {
    // Excel stops at `XFD`, and nothing in the file format stops a cell
    // claiming otherwise. Twelve letters name column 3,817,158,266,467,285, so
    // trusting the reference means building a row that long before anything
    // can refuse it — the decode below returning at all is half of what this
    // test says. The other half is that the refusal costs the row nothing: the
    // cell takes the next column, exactly as one carrying no reference does.
    final tables = decodeXlsx(workbook(
      sheets: [
        (
          'Sheet1',
          row(
            1,
            '<c r="A1" t="inlineStr"><is><t>Term</t></is></c>'
            '<c r="AAAAAAAAAAAA1" t="inlineStr"><is><t>Rate</t></is></c>',
          ),
        ),
      ],
    ));

    expect(tables.sheets.single.header, ['Term', 'Rate']);
  });

  test('a reference that would overflow is not trusted either', () {
    // Thirty letters do not run the count up, they run it over: the column
    // index wraps negative, which is a different wrong answer from the same
    // missing bound. Both end at the same place.
    final tables = decodeXlsx(workbook(
      sheets: [
        (
          'Sheet1',
          row(
            1,
            '<c r="A1" t="inlineStr"><is><t>Term</t></is></c>'
            '<c r="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1" t="inlineStr">'
            '<is><t>Rate</t></is></c>',
          ),
        ),
      ],
    ));

    expect(tables.sheets.single.header, ['Term', 'Rate']);
  });

  test('booleans read as TRUE and FALSE', () {
    final tables = decodeXlsx(workbook(
      shared: ['Signed'],
      sheets: [
        (
          'Sheet1',
          row(1, '<c r="A1" t="s"><v>0</v></c>') +
              row(2, '<c r="A2" t="b"><v>1</v></c>') +
              row(3, '<c r="A3" t="b"><v>0</v></c>'),
        ),
      ],
    ));

    expect(tables.sheets.single.rows, [
      ['TRUE'],
      ['FALSE'],
    ]);
  });

  test('numbers stay exactly as the file wrote them', () {
    // No style table is read this round, so a serial date stays a serial date
    // rather than being guessed at.
    final tables = decodeXlsx(workbook(
      shared: ['Amount'],
      sheets: [
        (
          'Sheet1',
          row(1, '<c r="A1" t="s"><v>0</v></c>') +
              row(2, '<c r="A2"><v>4200.5</v></c>') +
              row(3, '<c r="A3"><v>45231</v></c>'),
        ),
      ],
    ));

    expect(tables.sheets.single.rows, [
      ['4200.5'],
      ['45231'],
    ]);
  });

  test('the first non-empty row is the header and the rest are data', () {
    final tables = decodeXlsx(workbook(
      shared: ['Term', 'Rate'],
      sheets: [
        (
          'Sheet1',
          row(1, '<c r="A1"/>') +
              row(2, '<c r="A2" t="s"><v>0</v></c>'
                      '<c r="B2" t="s"><v>1</v></c>') +
              row(3, '<c r="A3"><v>30</v></c><c r="B3"><v>6.5</v></c>'),
        ),
      ],
    ));

    final sheet = tables.sheets.single;
    expect(sheet.header, ['Term', 'Rate']);
    expect(sheet.rows, [
      ['30', '6.5'],
    ]);
    expect(sheet.totalRows, 1);
    expect(sheet.truncated, isFalse);
  });

  test('past the cap the table says how many rows there really were', () {
    final buffer = StringBuffer(row(1, '<c r="A1" t="inlineStr">'
        '<is><t>Id</t></is></c>'));
    for (var i = 2; i <= rowCap + 21; i++) {
      buffer.write(row(i, '<c r="A$i"><v>$i</v></c>'));
    }

    final sheet = decodeXlsx(workbook(
      sheets: [('Big', buffer.toString())],
    )).sheets.single;

    expect(sheet.rows.length, rowCap);
    expect(sheet.totalRows, rowCap + 20);
    expect(sheet.truncated, isTrue);
  });

  test('a workbook with no shared strings still opens', () {
    final tables = decodeXlsx(workbook(
      sheets: [('Sheet1', row(1, '<c r="A1"><v>7</v></c>'))],
    ));

    expect(tables.sheets.single.header, ['7']);
  });

  test('a workbook whose relationships are missing still names its sheets', () {
    final tables = decodeXlsx(workbook(
      sheets: [('Orphan', row(1, '<c r="A1"><v>1</v></c>'))],
      withRels: false,
    ));

    expect(tables.sheets.single.name, 'Orphan');
    expect(tables.sheets.single.rows, isEmpty);
  });

  test('a zip that is not a workbook says so', () {
    final archive = Archive()
      ..add(ArchiveFile.string('readme.txt', 'not a spreadsheet'));

    expect(
      () => decodeXlsx(ZipEncoder().encodeBytes(archive)),
      throwsA(isA<FormatException>()),
    );
  });

  test('bytes that are not a zip at all say so', () {
    expect(
      () => decodeXlsx(Uint8List.fromList([1, 2, 3, 4, 5])),
      throwsA(isA<FormatException>()),
    );
  });
}
