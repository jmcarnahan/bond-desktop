import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chrome every side panel wears, on its own.
///
/// The screen tests pin what opens beside what; this file pins the header
/// itself — the three controls it owns, the fact that a panel with nowhere to
/// expand to draws no ⤢ rather than a dead one, and the fact that a panel with
/// nothing underneath draws no back row rather than a second ✕.

void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    String title = 'Terms.pdf',
    String? subtitle,
    Widget? leading,
    Widget? trailing,
    VoidCallback? onExpand,
    VoidCallback? onClose,
    VoidCallback? onBack,
    String? backLabel,
  }) async {
    await tester.binding.setSurfaceSize(const Size(600, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SidePanelHost(
          title: title,
          subtitle: subtitle,
          leading: leading,
          trailing: trailing,
          onExpand: onExpand,
          onClose: onClose ?? () {},
          onBack: onBack,
          backLabel: backLabel,
          child: const Text('panel body'),
        ),
      ),
    ));
  }

  testWidgets('the header carries the title, the subtitle and the child',
      (tester) async {
    await pumpHost(
      tester,
      title: 'Survey window',
      subtitle: 'Dana Whitfield',
      leading: const Text('✉'),
      trailing: const Text('240 KB'),
    );

    expect(find.text('Survey window'), findsOneWidget);
    expect(find.text('Dana Whitfield'), findsOneWidget);
    expect(find.text('✉'), findsOneWidget);
    expect(find.text('240 KB'), findsOneWidget);
    expect(find.text('panel body'), findsOneWidget);
  });

  testWidgets('a subtitle nobody passed leaves one line', (tester) async {
    await pumpHost(tester);

    expect(find.text('Terms.pdf'), findsOneWidget);
    // Nothing where the second line would be, rather than an empty one that
    // pushes the divider down.
    expect(find.byType(Text), findsNWidgets(2));
  });

  testWidgets('the two controls report, by key and by tooltip',
      (tester) async {
    var expanded = 0;
    var closed = 0;
    await pumpHost(
      tester,
      onExpand: () => expanded++,
      onClose: () => closed++,
    );

    expect(find.byTooltip('Expand'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.tap(find.byKey(SidePanelHost.closeKey));
    await tester.pump();

    expect(expanded, 1);
    expect(closed, 1);
  });

  testWidgets('no expand is no button, not a dead one', (tester) async {
    await pumpHost(tester);

    // There is nowhere to expand a thread to that is not simply selecting it,
    // and a control that answered nothing would still invite the tap.
    expect(find.byKey(SidePanelHost.expandKey), findsNothing);
    expect(find.byKey(SidePanelHost.closeKey), findsOneWidget);
  });

  group('the row back to the panel underneath', () {
    testWidgets('names it, and reports the tap', (tester) async {
      var popped = 0;
      await pumpHost(
        tester,
        onBack: () => popped++,
        backLabel: 'Survey window',
      );

      // The words a reader has to be able to act on without hovering
      // anything: which conversation the ✕ is about to give back.
      expect(find.text('Back to Survey window'), findsOneWidget);

      await tester.tap(find.byKey(SidePanelHost.backKey));
      await tester.pump();

      expect(popped, 1);
    });

    testWidgets('nothing underneath is no row, not a second close',
        (tester) async {
      await pumpHost(tester);

      // The ✕ already says what a close does when there is nothing behind the
      // panel, and two controls saying one thing is one of them lying.
      expect(find.byKey(SidePanelHost.backKey), findsNothing);
      expect(find.textContaining('Back to'), findsNothing);
    });

    testWidgets('a panel underneath with no name still offers the way out',
        (tester) async {
      await pumpHost(tester, onBack: () {}, backLabel: null);

      // A label the host could not resolve — a conversation the list no longer
      // has — must not cost the reader the row itself.
      expect(find.text('Back'), findsOneWidget);
      expect(find.byKey(SidePanelHost.backKey), findsOneWidget);
    });
  });

  group('the width beside the main pane', () {
    test('is the fraction, clamped to the panel minimum and maximum', () {
      // 0.45 of 1000 is 450, which is between a file's 360 and the 640 cap.
      expect(
        SidePanelHost.widthFor(
          available: 1000,
          minWidth: SidePanelHost.fileMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        450,
      );
      // And the cap holds on an ultrawide window rather than letting the panel
      // grow with it.
      expect(
        SidePanelHost.widthFor(
          available: 2000,
          minWidth: SidePanelHost.fileMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        SidePanelHost.maxWidth,
      );
    });

    test('gives way to the main pane before it gives up', () {
      // 0.45 of 800 is 360, which would leave main 440 — fine. At 780 the
      // fraction would leave main under its minimum, so the panel shrinks to
      // whatever is left rather than squeezing the transcript.
      expect(
        SidePanelHost.widthFor(
          available: 780,
          minWidth: SidePanelHost.fileMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        360,
      );
    });

    test('answers null when both cannot be had', () {
      // Below this the panel would be under its own minimum, which is the
      // point at which it replaces the main pane instead.
      expect(
        SidePanelHost.widthFor(
          available: 700,
          minWidth: SidePanelHost.fileMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        isNull,
      );
      // A thread needs more room than a file, so it gives up sooner: 840 is
      // enough for a 420 file and not for a 420 thread beside a 420 main.
      expect(
        SidePanelHost.widthFor(
          available: 800,
          minWidth: SidePanelHost.threadMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        isNull,
      );
      expect(
        SidePanelHost.widthFor(
          available: 840,
          minWidth: SidePanelHost.threadMinWidth,
          mainMinWidth: SidePanelHost.mainMinWidth,
        ),
        420,
      );
    });

    test('is measured after the rail, not on the window', () {
      // 260 of rail, its 1px divider and the 16px seam. Applying the two-pane
      // breakpoint to the window instead would open the split at 960, where
      // the main pane would be left under its own minimum.
      expect(SidePanelHost.availableBesideRail(1400), 1067);
      // The window at which the split first appears: the icon rail's 56, the
      // list column's 260, the divider and the seam leave exactly 960.
      expect(SidePanelHost.availableBesideRail(1293), 960);
    });
  });
}
