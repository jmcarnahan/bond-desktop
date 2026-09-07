import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';

/// The same panel with the pane to itself — and exactly one way out of it.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onBack,
    VoidCallback? onHome,
    String? name = 'Terms.pdf',
    int size = 240 * 1024,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: AttachmentViewerPane(
            attachment: ref(name: name, size: size),
            bytes: FakeAttachmentBytes(),
            engines: PreviewEngines(
              pdf: FakePdfRenderer(),
              workbook: (bytes) async => throw UnimplementedError(),
            ),
            onBack: onBack ?? () {},
            onHome: onHome,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('it wears the name and the size', (tester) async {
    await pump(tester);

    expect(find.text('Terms.pdf'), findsOneWidget);
    expect(find.widgetWithText(BondChip, '240 KB'), findsOneWidget);
  });

  testWidgets('a file nobody named still has a title', (tester) async {
    await pump(tester, name: null);

    expect(find.text('(unnamed attachment)'), findsOneWidget);
  });

  testWidgets('a size nobody stated leaves the slot empty', (tester) async {
    await pump(tester, size: 0);

    expect(find.byType(BondChip), findsNothing);
  });

  testWidgets('Back is the way out and there is no second close',
      (tester) async {
    var back = 0;
    await pump(tester, onBack: () => back++);

    expect(find.byKey(AttachmentPreviewPanel.closeKey), findsNothing);
    expect(find.byKey(AttachmentPreviewPanel.expandKey), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    expect(back, 1);
  });

  testWidgets('the pane draws one border, not a box within a box',
      (tester) async {
    await pump(tester);

    // PaneSurface is the bordered surface. The panel inside it must not wear
    // its own — the split view is where that border belongs.
    final bordered = find.descendant(
      of: find.byType(AttachmentPreviewPanel),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).borderRadius == BondRadii.mdAll),
    );
    expect(bordered, findsNothing);
  });

  testWidgets('the full pane never offers Use in reply', (tester) async {
    // There is no composer here, so a draft written from this pane would land
    // somewhere off screen. The pane takes no such callback at all — the split
    // preview beside a thread is where that offer belongs.
    await pump(tester);

    expect(find.byKey(AttachmentPreviewPanel.useInReplyKey), findsNothing);
  });

  testWidgets('Home renders only when it is wired', (tester) async {
    await pump(tester);
    expect(find.text('Home'), findsNothing);

    var home = 0;
    await pump(tester, onHome: () => home++);
    expect(find.text('Home'), findsOneWidget);

    await tester.tap(find.text('Home'));
    expect(home, 1);
  });
}
