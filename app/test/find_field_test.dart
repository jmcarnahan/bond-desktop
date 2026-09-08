import 'package:bond_inbox/widgets/find_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The quick switcher's box.
///
/// It is a view of a controller its host owns, so nothing here is about state
/// — it is about the four ways out of the field: a keystroke, Enter, Escape,
/// and the ×.

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmit,
    VoidCallback? onClear,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 236,
          child: FindField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged ?? (_) {},
            onSubmit: onSubmit ?? (_) {},
            onClear: onClear ?? () {},
          ),
        ),
      ),
    ));
  }

  testWidgets('the hint names the shortcut, because nothing else can',
      (tester) async {
    await pumpField(tester);

    expect(find.text('Find… ⌘K'), findsOneWidget);
  });

  testWidgets('the × appears only once there is something to clear',
      (tester) async {
    var cleared = 0;
    await pumpField(tester, onClear: () => cleared++);

    expect(find.byTooltip('Clear'), findsNothing);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.pump();

    expect(find.byTooltip('Clear'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();

    expect(cleared, 1);
  });

  testWidgets('every keystroke is reported — Find runs live', (tester) async {
    final seen = <String>[];
    await pumpField(tester, onChanged: seen.add);

    await tester.enterText(find.byKey(FindField.fieldKey), 'la');
    await tester.enterText(find.byKey(FindField.fieldKey), 'lau');
    await tester.pump();

    expect(seen, ['la', 'lau']);
  });

  testWidgets('Enter submits what is in the box', (tester) async {
    String? submitted;
    await pumpField(tester, onSubmit: (value) => submitted = value);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(submitted, 'launch');
  });

  testWidgets('Escape clears, and only while the box has focus',
      (tester) async {
    var cleared = 0;
    await pumpField(tester, onClear: () => cleared++);

    await tester.enterText(find.byKey(FindField.fieldKey), 'launch');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(cleared, 1);
  });
}
