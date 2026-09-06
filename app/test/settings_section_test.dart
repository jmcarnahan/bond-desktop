import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of the settings screen, and the two contracts that make the screen
/// readable.
///
/// First: the summary is the answer, and it stays visible when the body opens —
/// otherwise Collapse would be the only way to check what the controls just
/// did. Second: the section holds no state. The screen owns which sections are
/// open, which is what lets several be open at once and keeps the disclosure
/// state out of prefs, so a tap must report and change nothing by itself.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String title = 'About me',
    String summary = 'Not written yet',
    required bool expanded,
    required VoidCallback onToggle,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsSection(
          title: title,
          summary: summary,
          expanded: expanded,
          onToggle: onToggle,
          body: const Text('the section body'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('collapsed shows the title and the summary, not the body',
      (tester) async {
    await pump(tester, expanded: false, onToggle: () {});

    expect(find.text('About me'), findsOneWidget);
    expect(find.text('Not written yet'), findsOneWidget);
    expect(find.text('the section body'), findsNothing);
    expect(find.text('Expand'), findsOneWidget);
    expect(find.text('Collapse'), findsNothing);
  });

  testWidgets('tapping the toggle reports and nothing else', (tester) async {
    // The screen owns the open set, so the section cannot open itself. Pumping
    // it again with expanded: true is the host doing what a host would do.
    var toggles = 0;
    await pump(tester, expanded: false, onToggle: () => toggles++);

    await tester.tap(find.text('Expand'));
    await tester.pump();

    expect(toggles, 1);
    expect(find.text('the section body'), findsNothing);
    expect(find.text('Expand'), findsOneWidget);

    await pump(tester, expanded: true, onToggle: () => toggles++);
    expect(find.text('the section body'), findsOneWidget);
  });

  testWidgets('expanded shows the body and keeps the summary', (tester) async {
    await pump(tester, expanded: true, onToggle: () {});

    expect(find.text('the section body'), findsOneWidget);
    // Still there: the summary is the answer, and hiding it behind the
    // controls would make Collapse the only way to read what they did.
    expect(find.text('Not written yet'), findsOneWidget);
    expect(find.text('About me'), findsOneWidget);
    expect(find.text('Collapse'), findsOneWidget);
    expect(find.text('Expand'), findsNothing);
  });

  testWidgets('the toggle carries a key naming its section', (tester) async {
    // So a screen test can open one named section without walking the tree for
    // the right 'Expand' among eight of them.
    var toggles = 0;
    await pump(
      tester,
      title: 'Microsoft connection',
      expanded: false,
      onToggle: () => toggles++,
    );

    expect(
      find.byKey(SettingsSection.toggleKey('Microsoft connection')),
      findsOneWidget,
    );
    expect(find.byKey(SettingsSection.toggleKey('About me')), findsNothing);

    await tester.tap(find.byKey(SettingsSection.toggleKey(
      'Microsoft connection',
    )));
    await tester.pump();

    expect(toggles, 1);
  });
}
