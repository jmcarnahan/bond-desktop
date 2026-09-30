import 'package:bond_inbox/widgets/write_confirm_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int confirmed;
  late int dismissed;

  setUp(() {
    confirmed = 0;
    dismissed = 0;
  });

  Future<void> pump(
    WidgetTester tester, {
    List<String> notifies = const ['dana@contoso.com'],
    bool busy = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WriteConfirmStrip(
          summary: 'Accept "Design review" · Thu Oct 8 · 10:00–11:00 AM',
          notifies: notifies,
          confirmLabel: 'Send',
          dismissLabel: 'Cancel',
          onConfirm: () => confirmed += 1,
          onDismiss: () => dismissed += 1,
          busy: busy,
        ),
      ),
    ));
    // The strip takes focus after its first frame.
    await tester.pump();
  }

  testWidgets('shows the summary and who it emails', (tester) async {
    await pump(tester);
    expect(find.text('Accept "Design review" · Thu Oct 8 · 10:00–11:00 AM'),
        findsOneWidget);
    expect(find.byKey(WriteConfirmStrip.emailsKey), findsOneWidget);
    expect(find.text('This emails: dana@contoso.com'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('no emails line when nobody is emailed', (tester) async {
    await pump(tester, notifies: const []);
    expect(find.byKey(WriteConfirmStrip.emailsKey), findsNothing);
  });

  testWidgets('Enter confirms, numpad Enter too', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(confirmed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(confirmed, 2);
    expect(dismissed, 0);
  });

  testWidgets('a held Enter is one confirm', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(confirmed, 1);
  });

  testWidgets('Escape dismisses', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(dismissed, 1);
    expect(confirmed, 0);
  });

  testWidgets('the buttons press', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await tester.tap(find.byKey(WriteConfirmStrip.dismissKey));
    expect(confirmed, 1);
    expect(dismissed, 1);
  });

  testWidgets('busy ignores the keys and the buttons', (tester) async {
    await pump(tester, busy: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    expect(confirmed, 0);
    expect(dismissed, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
