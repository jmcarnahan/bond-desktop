import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/preview/sheet_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A workbook as a table somebody can read — and what it says about the rows
/// it is not showing.
Widget _host(WorkbookTables workbook) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 400,
          child: SheetPreview(workbook: workbook),
        ),
      ),
    );

const _quote = SheetTable(
  name: 'Quote',
  header: ['Item', 'Amount'],
  rows: [
    ['Survey', '1,200'],
    ['Filing', '340'],
  ],
  totalRows: 2,
);

const _terms = SheetTable(
  name: 'Terms',
  header: ['Clause'],
  rows: [
    ['Payable in thirty days'],
  ],
  totalRows: 1,
);

void main() {
  testWidgets('the header is bold and the data is mono', (tester) async {
    await tester.pumpWidget(_host(const WorkbookTables([_quote])));

    final header = tester.widget<Text>(find.text('Item'));
    expect(header.style?.fontWeight, FontWeight.w600);

    final cell = tester.widget<Text>(find.text('Survey'));
    expect(cell.style?.fontFamily, BondType.mono.fontFamily);
    expect(cell.maxLines, 1);
  });

  testWidgets('one sheet needs no pills', (tester) async {
    await tester.pumpWidget(_host(const WorkbookTables([_quote])));

    expect(find.byKey(SheetPreview.tabsKey), findsNothing);
  });

  testWidgets('two sheets get pills, and picking one swaps the table',
      (tester) async {
    await tester.pumpWidget(_host(const WorkbookTables([_quote, _terms])));

    expect(find.byKey(SheetPreview.tabsKey), findsOneWidget);
    expect(find.text('Survey'), findsOneWidget);
    expect(find.text('Payable in thirty days'), findsNothing);

    await tester.tap(find.widgetWithText(BondFilterPill, 'Terms'));
    await tester.pump();

    expect(find.text('Payable in thirty days'), findsOneWidget);
    expect(find.text('Survey'), findsNothing);
  });

  testWidgets('past the cap it says how much it is showing', (tester) async {
    const big = SheetTable(
      name: 'Ledger',
      header: ['Row'],
      rows: [
        ['one'],
        ['two'],
      ],
      totalRows: 900,
    );
    await tester.pumpWidget(_host(const WorkbookTables([big])));

    expect(find.byKey(SheetPreview.truncationKeyFor('Ledger')), findsOneWidget);
    expect(find.text('Showing the first 2 of 900 rows.'), findsOneWidget);
  });

  testWidgets('a sheet that is showing everything says nothing',
      (tester) async {
    await tester.pumpWidget(_host(const WorkbookTables([_quote])));

    expect(find.byKey(SheetPreview.truncationKeyFor('Quote')), findsNothing);
  });

  testWidgets('an empty sheet says so', (tester) async {
    await tester.pumpWidget(_host(
      const WorkbookTables([SheetTable(name: 'Blank')]),
    ));

    expect(find.text('This sheet is empty.'), findsOneWidget);
  });

  group('sheetAsTsv', () {
    test('one line per row, header first', () {
      expect(
        sheetAsTsv(_quote),
        'Item\tAmount\nSurvey\t1,200\nFiling\t340',
      );
    });

    test('a sheet with nothing in it is nothing', () {
      expect(sheetAsTsv(const SheetTable(name: 'Blank')), '');
    });
  });
}
