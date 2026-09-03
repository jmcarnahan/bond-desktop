import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/notification_ribbon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ribbon as a widget: what it draws and what a click on it means.
///
/// It knows nothing about settles, timers or providers — which is what lets
/// this file drive it with two closures and check that the body and the close
/// button are genuinely two different targets.

void main() {
  Future<void> pumpRibbon(
    WidgetTester tester, {
    String text = 'Homepage copy',
    InlineAlertSeverity severity = InlineAlertSeverity.attention,
    VoidCallback? onTap,
    VoidCallback? onDismiss,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: NotificationRibbon(
            severity: severity,
            text: text,
            onTap: onTap ?? () {},
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    ));
  }

  testWidgets('it says what it was handed, in an InlineAlert', (tester) async {
    await pumpRibbon(tester, text: 'Homepage copy · in Website redesign');

    expect(find.byType(InlineAlert), findsOneWidget);
    expect(find.text('Homepage copy · in Website redesign'), findsOneWidget);
  });

  testWidgets('an urgent settle renders the louder alert', (tester) async {
    await pumpRibbon(tester, severity: InlineAlertSeverity.error);

    expect(
      tester.widget<InlineAlert>(find.byType(InlineAlert)).severity,
      InlineAlertSeverity.error,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('anything else renders the attention alert', (tester) async {
    await pumpRibbon(tester);

    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });

  testWidgets('tapping the body opens, and does not dismiss', (tester) async {
    var opened = 0;
    var dismissed = 0;
    await pumpRibbon(
      tester,
      onTap: () => opened++,
      onDismiss: () => dismissed++,
    );

    await tester.tap(find.text('Homepage copy'));
    await tester.pump();

    expect(opened, 1);
    expect(dismissed, 0);
  });

  testWidgets('the close button dismisses, and does not open', (tester) async {
    var opened = 0;
    var dismissed = 0;
    await pumpRibbon(
      tester,
      onTap: () => opened++,
      onDismiss: () => dismissed++,
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(dismissed, 1);
    expect(opened, 0, reason: 'the X is a way out, not a way in');
  });

  testWidgets('a long ask is capped at two lines', (tester) async {
    await pumpRibbon(
      tester,
      text: 'Eric is asking whether the homepage copy can be signed off '
          'before the launch review on Thursday, and whether the pricing '
          'page changes are included in that sign-off or land separately.',
    );

    final label = tester.widget<Text>(
      find.descendant(
        of: find.byType(InlineAlert),
        matching: find.byType(Text),
      ),
    );
    expect(label.maxLines, 2);
    expect(label.overflow, TextOverflow.ellipsis);
  });
}
