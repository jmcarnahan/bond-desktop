import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_notifications_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one permission this app asks for, and the one screen where the wording
/// is the whole design.
///
/// EXACTLY ONE button, labelled `Continue`. macOS is about to put its own
/// dialog up with its own Allow and Don't Allow in it, and a Bond button
/// spelled the same way would read as the system prompt arriving twice — or
/// worse, as this app collecting the answer itself.
void main() {
  Future<void> open(
    WidgetTester tester, {
    bool? granted,
    VoidCallback? onContinue,
    VoidCallback? onOpenSettings,
    bool wireSettings = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupNotificationsBody(
            granted: granted,
            onContinue: onContinue ?? () {},
            onOpenSettings:
                wireSettings ? (onOpenSettings ?? () {}) : null,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('there is one button, it says Continue, and Allow is nowhere',
      (tester) async {
    await open(tester);

    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      find.text('Bond can let you know when a message needs you, even while '
          'it is in the background. macOS will ask whether to allow it.'),
      findsOneWidget,
    );
    // Nothing has been asked yet, so neither verdict is on screen.
    expect(find.textContaining('Notifications are'), findsNothing);
  });

  testWidgets('a refusal says where to change it, and still only one button',
      (tester) async {
    var opens = 0;
    await open(tester, granted: false, onOpenSettings: () => opens++);

    expect(
      find.text('Notifications are off for Bond. You can turn them on any '
          'time in System Settings.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);

    await tester.tap(find.byKey(SetupNotificationsBody.openSettingsKey));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('a host with nowhere to send them hides the link',
      (tester) async {
    await open(tester, granted: false, wireSettings: false);

    expect(find.byKey(SetupNotificationsBody.openSettingsKey), findsNothing);
    expect(find.textContaining('Notifications are off for Bond'), findsOneWidget);
  });

  testWidgets('a grant says so quietly', (tester) async {
    await open(tester, granted: true);

    expect(find.text('Notifications are on.'), findsOneWidget);
    expect(find.byKey(SetupNotificationsBody.openSettingsKey), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('Continue fires the host callback', (tester) async {
    var continues = 0;
    await open(tester, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
