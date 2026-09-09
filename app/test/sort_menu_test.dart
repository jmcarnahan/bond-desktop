import 'package:bond_inbox/models/people_sort.dart';
import 'package:bond_inbox/widgets/sort_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one order control every list in the app wears.
///
/// What it has to keep saying is which order is up: a bare icon would leave
/// the reader guessing, and a menu that did not check the current option would
/// let them pick the order they were already in and learn nothing.

void main() {
  Future<void> pump(
    WidgetTester tester, {
    PeopleSort value = PeopleSort.recent,
    ValueChanged<PeopleSort>? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SortMenu<PeopleSort>(
            key: const Key('a-sort'),
            value: value,
            options: PeopleSort.values,
            labelOf: (o) => o.label,
            itemKeyFor: (o) => Key('a-sort-${o.name}'),
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// The `PopupMenuButton` idiom: tap, pump, let the route's animation run.
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('a-sort')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('it wears the current order in words', (tester) async {
    await pump(tester, value: PeopleSort.name);

    expect(find.text(PeopleSort.name.label), findsOneWidget);
    expect(find.byIcon(Icons.sort), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
  });

  testWidgets('opening it lists every option, with the current one checked',
      (tester) async {
    await pump(tester, value: PeopleSort.needsYou);
    await open(tester);

    for (final option in PeopleSort.values) {
      expect(find.byKey(Key('a-sort-${option.name}')), findsOneWidget);
    }
    final checked = tester.widget<CheckedPopupMenuItem<PeopleSort>>(
      find.byKey(Key('a-sort-${PeopleSort.needsYou.name}')),
    );
    expect(checked.checked, isTrue);
    final other = tester.widget<CheckedPopupMenuItem<PeopleSort>>(
      find.byKey(Key('a-sort-${PeopleSort.name.name}')),
    );
    expect(other.checked, isFalse);
  });

  testWidgets('picking one reports it', (tester) async {
    final picked = <PeopleSort>[];
    await pump(tester, onChanged: picked.add);
    await open(tester);

    await tester.tap(find.byKey(Key('a-sort-${PeopleSort.name.name}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(picked, [PeopleSort.name]);
  });

  testWidgets('the tooltip says what the control is for', (tester) async {
    await pump(tester);
    expect(find.byTooltip('Order'), findsOneWidget);
  });
}
