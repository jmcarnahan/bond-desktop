import 'dart:typed_data';

import 'package:bond_inbox/widgets/inline_image_thumb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// A picture drawn where the sender put it — and what stands in its place while
/// there are no bytes for it.
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

MemoryImage _pixel() => MemoryImage(Uint8List.fromList(onePixelPng));

void main() {
  testWidgets('draws the provider it was handed', (tester) async {
    final provider = _pixel();
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(),
      image: provider,
    )));

    final image = tester.widget<Image>(find.byType(Image));
    expect(identical(image.image, provider), isTrue);
    expect(image.fit, BoxFit.contain);
    expect(image.gaplessPlayback, isTrue);
    expect(
      find.byKey(InlineImageThumb.placeholderKeyFor(imageRef())),
      findsNothing,
    );
  });

  testWidgets('no bytes yet is a framed place for the picture',
      (tester) async {
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(name: 'Whiteboard.png'),
      image: null,
    )));

    expect(find.byType(Image), findsNothing);
    expect(
      find.byKey(InlineImageThumb.placeholderKeyFor(
          imageRef(name: 'Whiteboard.png'))),
      findsOneWidget,
    );
    expect(find.text('🖼 Whiteboard.png'), findsOneWidget);
  });

  testWidgets('a picture nobody named still has a place', (tester) async {
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(name: null),
      image: null,
    )));

    expect(find.text('🖼 image'), findsOneWidget);
  });

  testWidgets('it is bounded on both axes inside a list', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          InlineImageThumb(attachment: imageRef(), image: null),
          const Text('under the picture'),
        ]),
      ),
    ));
    await tester.pump();

    // A ListView asserts on an unbounded child rather than laying one out
    // badly, so getting this far IS the assertion.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(InlineImageThumb.placeholderKeyFor(imageRef()))),
      const Size(320, InlineImageThumb.placeholderHeight),
    );
    expect(find.text('under the picture'), findsOneWidget);
  });

  testWidgets('and never stretches to the width of the pane', (tester) async {
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(),
      image: _pixel(),
    )));

    final box = tester.widget<ConstrainedBox>(find.descendant(
      of: find.byType(InlineImageThumb),
      matching: find.byType(ConstrainedBox),
    ));
    expect(box.constraints.maxWidth, 320);
    expect(box.constraints.maxHeight, 240);
  });

  testWidgets('bytes that will not decode fall back to the frame',
      (tester) async {
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(),
      image: MemoryImage(Uint8List.fromList(const [1, 2, 3, 4])),
    )));
    // Let the decode fail and the error builder run.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(InlineImageThumb.placeholderKeyFor(imageRef())),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picture with nowhere to go takes no tap', (tester) async {
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(),
      image: _pixel(),
    )));

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('and one with somewhere to go opens it', (tester) async {
    var taps = 0;
    // The frame rather than a decoded picture: a `MemoryImage` needs a real
    // event loop to decode, and a zero-sized picture takes no tap.
    await tester.pumpWidget(_host(InlineImageThumb(
      attachment: imageRef(),
      image: null,
      onTap: () => taps++,
    )));

    await tester.tap(find.byKey(InlineImageThumb.placeholderKeyFor(imageRef())));
    expect(taps, 1);
  });
}
