/// A picture at the size the pane allows, and as close as the reader wants.
///
/// The zoom is what makes this worth a panel rather than a larger thumbnail:
/// the pictures people send are screenshots of the thing they are asking
/// about, and a screenshot scaled to fit a 400-pixel column is unreadable
/// exactly where it matters.
///
/// It takes bytes rather than an `ImageProvider` because the panel already has
/// them — it fetched them to decide what to draw — and re-wrapping them in a
/// provider per rebuild would restart the decode on every frame the sixty
/// second poll causes. The HOST holds one `Uint8List` instance across
/// rebuilds; `Image.memory` keys its cache on that instance.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'unsupported_preview.dart';

class ImagePreview extends StatelessWidget {
  final Uint8List bytes;
  final String? name;

  const ImagePreview({super.key, required this.bytes, this.name});

  static const Key imageKey = ValueKey('image-preview-image');
  static const Key failedKey = ValueKey('image-preview-failed');

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: BondColors.previewGround,
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 8,
        child: Center(
          child: Image.memory(
            bytes,
            key: imageKey,
            fit: BoxFit.contain,
            // The same bytes across a rebuild keep their pixels rather than
            // flashing empty while they decode again.
            gaplessPlayback: true,
            // A picture that will not decode is the one case this panel cannot
            // recover from by asking again: the bytes arrived and they are not
            // an image this platform reads.
            errorBuilder: (context, error, stack) => UnsupportedPreview(
              key: failedKey,
              glyph: '🖼',
              name: name,
              reason: 'This image could not be decoded.',
            ),
          ),
        ),
      ),
    );
  }
}
