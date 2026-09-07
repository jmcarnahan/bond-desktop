import 'dart:typed_data';

import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/preview/image_preview.dart';
import 'package:bond_inbox/widgets/preview/unsupported_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/png_fixture.dart';

/// A picture at the size the pane allows, and as close as the reader wants.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

void main() {
  testWidgets('a real picture renders on the preview ground', (tester) async {
    await tester.pumpWidget(_host(ImagePreview(
      bytes: Uint8List.fromList(onePixelPng),
      name: 'Screenshot.png',
    )));
    await tester.pump();

    expect(find.byKey(ImagePreview.imageKey), findsOneWidget);
    expect(find.byKey(ImagePreview.failedKey), findsNothing);

    final ground = tester.widget<ColoredBox>(find
        .descendant(
          of: find.byType(ImagePreview),
          matching: find.byType(ColoredBox),
        )
        .first);
    expect(ground.color, BondColors.previewGround);
  });

  testWidgets('it can be zoomed in on', (tester) async {
    await tester.pumpWidget(_host(ImagePreview(
      bytes: Uint8List.fromList(onePixelPng),
    )));

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.minScale, 1);
    expect(viewer.maxScale, 8);
  });

  testWidgets('bytes that are not a picture fall back to the frame',
      (tester) async {
    await tester.pumpWidget(_host(ImagePreview(
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      name: 'Broken.png',
    )));
    // Two pumps: the decode fails asynchronously and the error builder runs on
    // the frame after it.
    await tester.pump();
    await tester.pump();

    expect(find.byKey(ImagePreview.failedKey), findsOneWidget);
    expect(find.byType(UnsupportedPreview), findsOneWidget);
    expect(find.text('This image could not be decoded.'), findsOneWidget);
  });
}
