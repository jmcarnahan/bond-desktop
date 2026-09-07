/// A workbook as a table somebody can read, not as a spreadsheet they can
/// edit.
///
/// The whole point is recognising a document — is this the quote I was sent,
/// which column holds the totals — and past a few hundred rows nobody is doing
/// that here, they are opening it in Excel. So the rows are capped upstream in
/// `xlsx_reader.dart`, this says how many it is not showing, and Open is one
/// button away.
///
/// **Fixed column widths, never `IntrinsicColumnWidth`.** An intrinsic pass
/// measures every cell in a column on every frame; five hundred rows across
/// twenty columns is ten thousand measurements per frame for a table nobody is
/// resizing.
library;

import 'package:flutter/material.dart';

import '../../services/attachments/xlsx_reader.dart';
import '../../theme/tokens.dart';
import '../chips.dart';

/// One sheet as tab-separated lines: what the Text segment shows, and what
/// lands on the clipboard when a reader copies it out.
///
/// Header first when there is one, then the rows the table is showing — never
/// the rows past the cap, which this app does not have.
String sheetAsTsv(SheetTable sheet) {
  final lines = <String>[
    if (sheet.header.isNotEmpty) sheet.header.join('\t'),
    for (final row in sheet.rows) row.join('\t'),
  ];
  return lines.join('\n');
}

class SheetPreview extends StatefulWidget {
  final WorkbookTables workbook;

  const SheetPreview({super.key, required this.workbook});

  static const Key tabsKey = ValueKey('sheet-preview-tabs');

  static ValueKey<String> truncationKeyFor(String sheet) =>
      ValueKey('sheet-preview-truncated-$sheet');

  /// Wide enough for a date or a five-figure amount, narrow enough that four
  /// columns fit the split pane without a scroll.
  static const double columnWidth = 160;

  @override
  State<SheetPreview> createState() => _SheetPreviewState();
}

class _SheetPreviewState extends State<SheetPreview> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final sheets = widget.workbook.sheets;
    if (sheets.isEmpty) return _emptyLine('This workbook has no sheets.');

    // Clamped rather than reset in `didUpdateWidget`: a workbook arriving with
    // fewer sheets than the one before is a different file in the same panel,
    // and the first sheet is the right landing either way.
    final index = _index >= sheets.length ? 0 : _index;
    final sheet = sheets[index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One sheet needs no pills — a row of one option is a control that
        // does nothing, and the sheet's name is already in the header above.
        if (sheets.length > 1) ...[
          BondFilterPillRow<int>(
            key: SheetPreview.tabsKey,
            options: [for (var i = 0; i < sheets.length; i++) i],
            selected: index,
            labelOf: (i) => sheets[i].name,
            onSelected: (i) => setState(() => _index = i),
          ),
          const SizedBox(height: BondSpacing.s8),
        ],
        Expanded(child: _table(sheet)),
        if (sheet.truncated) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(
            'Showing the first ${sheet.rows.length} of '
            '${sheet.totalRows} rows.',
            key: SheetPreview.truncationKeyFor(sheet.name),
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
      ],
    );
  }

  Widget _emptyLine(String text) => Center(
        child: Text(
          text,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      );

  Widget _table(SheetTable sheet) {
    if (sheet.header.isEmpty && sheet.rows.isEmpty) {
      return _emptyLine('This sheet is empty.');
    }

    var columns = sheet.header.length;
    for (final row in sheet.rows) {
      if (row.length > columns) columns = row.length;
    }
    if (columns == 0) return _emptyLine('This sheet is empty.');

    // Vertical outside, horizontal inside: the reader scrolls down a sheet far
    // more often than across it, so the down gesture is the one that reaches
    // the whole table rather than one column of it.
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: SheetPreview.columnWidth * columns,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sheet.header.isNotEmpty)
                _row(sheet.header, columns, header: true),
              for (final row in sheet.rows) _row(row, columns, header: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(List<String> cells, int columns, {required bool header}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: header ? BondColors.faintGround : null,
        border: const Border(
          bottom: BorderSide(color: BondColors.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < columns; i++)
            SizedBox(
              width: SheetPreview.columnWidth,
              child: Padding(
                padding: const EdgeInsets.all(BondSpacing.s8),
                child: Text(
                  i < cells.length ? cells[i] : '',
                  style: header
                      ? BondType.small.copyWith(
                          fontWeight: FontWeight.w600,
                          color: BondColors.ink,
                        )
                      : BondType.mono,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
