import 'package:bond_inbox/widgets/hover_actions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The per-message strip that appears under the pointer.
///
/// The rule this file pins is that the strip is an ACCELERATOR: it is absent
/// until a mouse is over the row, so nothing may live only here.

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required List<HoverAction> actions,
  }) async {
    await tester.binding.setSurfaceSize(const Size(600, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: HoverActions(
            actions: actions,
            child: const SizedBox(
              width: 400,
              height: 80,
              child: Text('The homepage copy is in.'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Puts a MOUSE over the row. Touch never enters a `MouseRegion`, which is
  /// the whole reason the strip can be an accelerator.
  Future<TestGesture> hoverRow(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(HoverActions)));
    await tester.pump();
    return gesture;
  }

  testWidgets('there is no strip until a pointer arrives', (tester) async {
    await pumpRow(tester, actions: [
      HoverAction(icon: Icons.reply_outlined, tooltip: 'Reply', onTap: () {}),
    ]);

    expect(find.byIcon(Icons.reply_outlined), findsNothing);
    expect(find.text('The homepage copy is in.'), findsOneWidget);
  });

  testWidgets('a mouse brings it up, and leaving takes it away',
      (tester) async {
    await pumpRow(tester, actions: [
      HoverAction(icon: Icons.reply_outlined, tooltip: 'Reply', onTap: () {}),
    ]);

    final gesture = await hoverRow(tester);
    expect(find.byIcon(Icons.reply_outlined), findsOneWidget);

    await gesture.moveTo(Offset.zero);
    await tester.pump();

    expect(find.byIcon(Icons.reply_outlined), findsNothing);
  });

  testWidgets('each button says what it does and fires only itself',
      (tester) async {
    final fired = <String>[];
    await pumpRow(tester, actions: [
      HoverAction(
        icon: Icons.reply_outlined,
        tooltip: 'Reply',
        onTap: () => fired.add('reply'),
        key: HoverActions.replyKeyFor('m1'),
      ),
      HoverAction(
        icon: Icons.auto_awesome,
        tooltip: 'Suggest a reply',
        onTap: () => fired.add('suggest'),
        key: HoverActions.suggestKeyFor('m1'),
      ),
    ]);

    await hoverRow(tester);

    expect(find.byTooltip('Reply'), findsOneWidget);
    expect(find.byTooltip('Suggest a reply'), findsOneWidget);

    await tester.tap(find.byKey(HoverActions.replyKeyFor('m1')));
    await tester.pump();

    expect(fired, ['reply']);
  });

  testWidgets('nothing to offer is the bare child, with no MouseRegion at all',
      (tester) async {
    await pumpRow(tester, actions: const []);

    expect(find.text('The homepage copy is in.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(HoverActions),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
  });
}
