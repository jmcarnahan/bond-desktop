import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/image_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The pictures on one message, as a grid.
///
/// What this file pins is the counting: the grid draws at most [ImageGrid.max]
/// tiles, and past that the last one stops being a picture and starts being a
/// number — so a message with eleven photographs on it never becomes eleven
/// things to scroll past.

void main() {
  final ImageProvider memoryImage =
      MemoryImage(Uint8List.fromList(onePixelPng));

  List<AttachmentRef> images(int count) => [
        for (var i = 0; i < count; i++)
          imageRef(attachmentId: 'i$i', name: 'Shot$i.png', isInline: false),
      ];

  Future<void> pumpGrid(
    WidgetTester tester, {
    required List<AttachmentRef> attachments,
    void Function(AttachmentRef)? onTap,
    bool withPictures = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ImageGrid(
          images: attachments,
          imageFor: (_) => withPictures ? memoryImage : null,
          onTap: onTap,
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('two pictures are two tiles and no counter', (tester) async {
    await pumpGrid(tester, attachments: images(2));

    expect(find.byKey(ImageGrid.tileKeyFor(images(2).first)), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byKey(ImageGrid.overflowKey), findsNothing);
  });

  testWidgets('exactly four still fit, so nothing is counted', (tester) async {
    await pumpGrid(tester, attachments: images(4));

    expect(find.byType(Image), findsNWidgets(4));
    expect(find.byKey(ImageGrid.overflowKey), findsNothing);
  });

  testWidgets('six draw four tiles, and the last one says how many are left',
      (tester) async {
    await pumpGrid(tester, attachments: images(6));

    expect(find.byType(Image), findsNWidgets(4));
    expect(find.byKey(ImageGrid.overflowKey), findsOneWidget);
    // Three tiles are drawn as pictures and the fourth stands for the rest of
    // them, itself included.
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('a picture that has not arrived is its glyph, not a hole',
      (tester) async {
    await pumpGrid(tester, attachments: images(2), withPictures: false);

    expect(find.byType(Image), findsNothing);
    expect(find.text('🖼'), findsNWidgets(2));
  });

  testWidgets('a tap hands back the picture it was on', (tester) async {
    final shots = images(3);
    final opened = <String>[];
    await pumpGrid(
      tester,
      attachments: shots,
      onTap: (a) => opened.add(a.attachmentId),
    );

    await tester.tap(find.byKey(ImageGrid.tileKeyFor(shots[1])));
    await tester.pump();

    expect(opened, ['i1']);
  });

  testWidgets('tapping the counter opens the picture under it', (tester) async {
    final shots = images(6);
    final opened = <String>[];
    await pumpGrid(
      tester,
      attachments: shots,
      onTap: (a) => opened.add(a.attachmentId),
    );

    await tester.tap(find.byKey(ImageGrid.overflowKey));
    await tester.pump();

    // The fourth picture is the one the counter is drawn over, so it is the
    // one the tap means — the rest are reached from there.
    expect(opened, ['i3']);
  });

  testWidgets('a host with nowhere to open one leaves the tiles inert',
      (tester) async {
    await pumpGrid(tester, attachments: images(2));

    expect(find.byType(InkWell), findsNothing);
  });
}
