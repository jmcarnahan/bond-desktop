import 'package:bond_inbox/widgets/filter_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The light-pane live filter box.
///
/// Three claims: it reports every keystroke (there is nothing to submit), the
/// × exists only while there is something to clear, and Escape does what the ×
/// does — bound in the field, where the hand that just typed already is.

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<List<String>> pump(WidgetTester tester) async {
    final seen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilterField(
          controller: controller,
          onChanged: seen.add,
          hint: 'Filter people…',
        ),
      ),
    ));
    await tester.pump();
    return seen;
  }

  testWidgets('the hint is the pane\'s own', (tester) async {
    await pump(tester);
    expect(find.text('Filter people…'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('typing reports the needle on every keystroke', (tester) async {
    final seen = await pump(tester);

    await tester.enterText(find.byType(TextField), 'dan');
    await tester.pump();

    expect(seen, ['dan']);
    expect(controller.text, 'dan');
  });

  testWidgets('the × appears only once there is something to clear',
      (tester) async {
    await pump(tester);
    expect(find.byKey(FilterField.clearKey), findsNothing);

    await tester.enterText(find.byType(TextField), 'dana');
    await tester.pump();

    expect(find.byKey(FilterField.clearKey), findsOneWidget);
  });

  testWidgets('and clearing empties the box and says so', (tester) async {
    final seen = await pump(tester);
    await tester.enterText(find.byType(TextField), 'dana');
    await tester.pump();

    await tester.tap(find.byKey(FilterField.clearKey));
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(seen.last, '');
    expect(find.byKey(FilterField.clearKey), findsNothing);
  });

  testWidgets('Escape clears it too', (tester) async {
    final seen = await pump(tester);
    await tester.enterText(find.byType(TextField), 'dana');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(seen.last, '');
  });
}
