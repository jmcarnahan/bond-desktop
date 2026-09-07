/// Enough of an XLSX workbook to show somebody what is in it.
///
/// **Why this file exists at all.** The plan named the `excel` package, and it
/// cannot be used: its newest release requires `archive ^3` and `xml <7`, while
/// `pdfrx` 2.6 — which decides the whole toolchain floor — requires
/// `archive ^4`. One of the two had to give, and it was not the PDF engine. A
/// workbook is a zip of XML documents, so the parts a preview actually needs
/// are read here directly, and this is the only file allowed to import
/// `archive` or `xml`.
///
/// **What it deliberately does not do.** No number formatting, no dates, no
/// styles, no formulas evaluated. A cell comes out as the characters the file
/// stored: `45231` stays `45231` even where Excel would draw it as a date,
/// because the style table that says so is a second parse for a gain a preview
/// does not need — the person reading it can open the real file, and the button
/// to do that is right there. Say so rather than half-doing it: a date silently
/// rendered wrong is worse than a number rendered plainly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute, immutable;
import 'package:xml/xml.dart';

/// The most rows any one sheet hands back. A preview is for recognising a
/// document, and past five hundred rows nobody is reading — they are opening it
/// in Excel. [SheetTable.totalRows] still counts every row, so the table can
/// say what it is not showing.
const int rowCap = 500;

/// One worksheet, flattened into a header and its rows.
@immutable
class SheetTable {
  final String name;

  /// The first non-empty row. A spreadsheet's first row is a header often
  /// enough that treating it as one is right more than it is wrong, and a
  /// wrong guess costs a bold line rather than a missing one — the row is
  /// still shown.
  final List<String> header;

  /// The rows after the header, at most [rowCap] of them.
  final List<List<String>> rows;

  /// How many data rows the sheet actually has, cap or no cap.
  final int totalRows;

  const SheetTable({
    required this.name,
    this.header = const [],
    this.rows = const [],
    this.totalRows = 0,
  });

  bool get truncated => totalRows > rows.length;
}

/// A whole workbook, in the order the workbook lists its sheets.
@immutable
class WorkbookTables {
  final List<SheetTable> sheets;

  const WorkbookTables(this.sheets);
}

/// How a preview asks for a workbook, so a test can hand over a fake one
/// without a zip.
typedef WorkbookDecoder = Future<WorkbookTables> Function(Uint8List bytes);

/// The real decoder, on a background isolate.
///
/// A workbook is unzipped and its XML parsed, both of which are pure CPU on
/// megabytes; doing that on the UI isolate is a visible stall. [decodeXlsx] is
/// a top-level function and [WorkbookTables] is strings and ints, so both ends
/// are sendable.
Future<WorkbookTables> xlsxWorkbookDecoder(Uint8List bytes) =>
    compute(decodeXlsx, bytes);

/// [bytes] as tables. Synchronous, pure, and throws [FormatException] when it
/// is handed something that is not a workbook.
WorkbookTables decodeXlsx(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const FormatException('not a workbook');
  }

  final workbookXml = _textOf(archive, 'xl/workbook.xml');
  if (workbookXml == null) throw const FormatException('not a workbook');

  final XmlDocument workbook;
  try {
    workbook = XmlDocument.parse(workbookXml);
  } on XmlException {
    throw const FormatException('not a workbook');
  }

  final rels = _relationships(archive);
  final shared = _sharedStrings(archive);

  final sheets = <SheetTable>[];
  for (final element in workbook.findAllElements('sheet', namespaceUri: '*')) {
    final name = element.getAttribute('name') ?? 'Sheet${sheets.length + 1}';
    final id = element.getAttribute('id', namespaceUri: '*');
    final target = id == null ? null : rels[id];
    final xml = target == null ? null : _textOf(archive, _resolve(target));
    if (xml == null) {
      // A sheet whose part is missing is still a sheet the workbook claims to
      // have; showing it empty says more than dropping it.
      sheets.add(SheetTable(name: name));
      continue;
    }
    sheets.add(_readSheet(name, xml, shared));
  }

  return WorkbookTables(sheets);
}

/// One worksheet part as a table.
SheetTable _readSheet(String name, String xml, List<String> shared) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    return SheetTable(name: name);
  }

  final header = <String>[];
  final rows = <List<String>>[];
  var width = 0;
  var dataRows = 0;
  var haveHeader = false;

  for (final rowElement in document.findAllElements('row', namespaceUri: '*')) {
    final cells = <int, String>{};
    var widest = -1;
    for (final cell in rowElement.findElements('c', namespaceUri: '*')) {
      final column = _columnOf(cell.getAttribute('r'), widest + 1);
      final value = _valueOf(cell, shared);
      if (column > widest) widest = column;
      if (value.isNotEmpty) cells[column] = value;
    }
    if (cells.isEmpty) continue;

    // Gaps are cells, not absences: `A1` and `C1` with nothing between them is
    // a row of three, or the columns after it line up under the wrong header.
    final flat = [
      for (var i = 0; i <= widest; i++) cells[i] ?? '',
    ];
    if (flat.length > width) width = flat.length;

    if (!haveHeader) {
      header.addAll(flat);
      haveHeader = true;
      continue;
    }
    dataRows++;
    if (rows.length < rowCap) rows.add(flat);
  }

  // Ragged rows are the normal state of a spreadsheet. Padding once at the end
  // means the widest row seen decides the table's width, whether it was the
  // header or row four hundred.
  _pad(header, width);
  for (final row in rows) {
    _pad(row, width);
  }

  return SheetTable(
    name: name,
    header: header,
    rows: rows,
    totalRows: dataRows,
  );
}

/// One cell's text.
///
/// The `t` attribute says how to read `<v>`, and getting it wrong is how a
/// shared-string index ends up rendered as the number 7.
String _valueOf(XmlElement cell, List<String> shared) {
  final type = cell.getAttribute('t') ?? 'n';
  switch (type) {
    case 's':
      final index = int.tryParse(_childText(cell, 'v'));
      if (index == null || index < 0 || index >= shared.length) return '';
      return shared[index];
    case 'inlineStr':
      final inline = cell.getElement('is', namespaceUri: '*');
      return inline == null ? '' : _joinText(inline);
    case 'b':
      return _childText(cell, 'v') == '1' ? 'TRUE' : 'FALSE';
    default:
      // `str` (a formula's cached result), `e` (an error like #REF!) and plain
      // numbers all read as what the file wrote.
      return _childText(cell, 'v');
  }
}

/// Excel's last column is `XFD` — three letters, zero-based index 16383. A
/// reference naming anything past it names a column no workbook has.
const int _maxColumnLetters = 3;
const int _maxColumn = 16383;

/// The zero-based column a cell reference names: `A` → 0, `B` → 1, `AA` → 26.
///
/// [fallback] is used when a cell carries no reference at all, which is legal
/// and means "the next column along".
///
/// Counting stops at [_maxColumnLetters] because an unbounded parse is a hang
/// rather than a wrong number. Nothing in the file format stops a cell writing
/// `r="AAAAAAAAAAAA1"`, twelve letters name column 3,817,158,266,467,285, and
/// [_readSheet] would then sit in the isolate building a row that long; thirty
/// letters overflow the count into a negative index instead. A reference past
/// `XFD` carries nothing this reader can use, so it is read the way a missing
/// one is — the next column along — and the rest of the row still decodes.
int _columnOf(String? reference, int fallback) {
  if (reference == null || reference.isEmpty) return fallback;
  var value = 0;
  var seen = 0;
  for (final unit in reference.codeUnits) {
    if (unit >= 0x41 && unit <= 0x5A) {
      value = value * 26 + (unit - 0x40);
      seen++;
    } else if (unit >= 0x61 && unit <= 0x7A) {
      value = value * 26 + (unit - 0x60);
      seen++;
    } else {
      break;
    }
    if (seen > _maxColumnLetters) return fallback;
  }
  if (seen == 0) return fallback;
  final column = value - 1;
  return column > _maxColumn ? fallback : column;
}

/// `Id` → `Target`, from the workbook's relationship part.
///
/// Missing rels are tolerated: the workbook still names its sheets, and a
/// preview showing empty tables beats one throwing.
Map<String, String> _relationships(Archive archive) {
  final xml = _textOf(archive, 'xl/_rels/workbook.xml.rels');
  if (xml == null) return const {};
  try {
    final document = XmlDocument.parse(xml);
    final out = <String, String>{};
    for (final rel
        in document.findAllElements('Relationship', namespaceUri: '*')) {
      final id = rel.getAttribute('Id');
      if (id == null || id.isEmpty) continue;
      out[id] = rel.getAttribute('Target') ?? '';
    }
    return out;
  } on XmlException {
    return const {};
  }
}

/// The shared string table, one entry per `<si>`.
///
/// Every `<t>` inside an entry is concatenated, because rich text splits one
/// string across a run per format — reading only the first `<t>` truncates
/// every cell somebody bolded a word in.
List<String> _sharedStrings(Archive archive) {
  final xml = _textOf(archive, 'xl/sharedStrings.xml');
  if (xml == null) return const [];
  try {
    final document = XmlDocument.parse(xml);
    return [
      for (final entry in document.findAllElements('si', namespaceUri: '*')) _joinText(entry),
    ];
  } on XmlException {
    return const [];
  }
}

/// A relationship target as a path inside the zip. Targets are relative to
/// `xl/`, except the absolute ones, which some writers emit as `/xl/…`.
String _resolve(String target) {
  if (target.startsWith('/')) return target.substring(1);
  if (target.startsWith('xl/')) return target;
  return 'xl/$target';
}

String? _textOf(Archive archive, String path) {
  final file = archive.findFile(path);
  final bytes = file?.readBytes();
  if (bytes == null) return null;
  return utf8.decode(bytes, allowMalformed: true);
}

String _childText(XmlElement element, String name) =>
    element.getElement(name, namespaceUri: '*')?.innerText ?? '';

String _joinText(XmlElement element) =>
    element.findAllElements('t', namespaceUri: '*').map((e) => e.innerText).join();

void _pad(List<String> row, int width) {
  while (row.length < width) {
    row.add('');
  }
}
