import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';

/// The pictures one message carried, as a grid of squares.
///
/// Two photographs stacked one above the other is a scroll; two photographs
/// side by side is a message with two photographs on it. Every chat app a
/// reader has used draws the second, so this one does too.
///
/// Past [max] tiles the grid stops drawing and starts counting: the last tile
/// wears a `+N` over it, because a message with eleven pictures on it is a fact
/// about the message rather than eleven things to look at, and the reader who
/// wants them opens one.
class ImageGrid extends StatelessWidget {
  final List<AttachmentRef> images;

  /// The picture for one of them, or null while there is none — the same
  /// contract `MessageRow.thumbnailFor` has, and passed the same way so the
  /// grid never learns where bytes come from.
  final ImageProvider? Function(AttachmentRef attachment) imageFor;

  /// Null leaves every tile a statement rather than a control, the rule a chip
  /// with nowhere to go follows.
  final void Function(AttachmentRef attachment)? onTap;

  /// How many tiles are drawn before the overflow tile takes over. Four fills
  /// the reading column twice over and still leaves the words above it on
  /// screen.
  final int max;

  const ImageGrid({
    super.key,
    required this.images,
    required this.imageFor,
    this.onTap,
    this.max = 4,
  });

  /// The host's key for the whole grid — what a test asks for to say "these
  /// pictures are a grid and not a column of thumbnails".
  static const Key gridKey = ValueKey('image-grid');

  static ValueKey<String> tileKeyFor(AttachmentRef attachment) =>
      attachmentKey('image-tile', attachment);

  static const Key overflowKey = ValueKey('image-grid-overflow');

  /// Square, and small enough that four of them wrap to two rows inside the
  /// reading column rather than one very long one.
  static const double tileSize = 156;

  /// How dark the overflow tile goes. Enough that white numerals read over any
  /// photograph, light enough that the picture underneath is still visibly a
  /// picture rather than a grey box.
  static const double _scrimAlpha = 0.55;

  @override
  Widget build(BuildContext context) {
    final drawn = images.length > max ? images.take(max).toList() : images;
    final overflow = images.length - (max - 1);

    return Wrap(
      spacing: BondSpacing.s4,
      runSpacing: BondSpacing.s4,
      children: [
        for (var i = 0; i < drawn.length; i++)
          // The LAST drawn tile becomes the counter when there are more than
          // fit. Adding a fifth tile for the count would make the grid one
          // wider than it says it is.
          if (images.length > max && i == max - 1)
            _tile(drawn[i], overflowCount: overflow)
          else
            _tile(drawn[i]),
      ],
    );
  }

  Widget _tile(AttachmentRef attachment, {int? overflowCount}) {
    final provider = imageFor(attachment);
    final tap = onTap;

    Widget content = provider == null
        ? Container(
            color: BondColors.previewGround,
            alignment: Alignment.center,
            child: Text(
              attachmentGlyph(
                attachment.kind,
                attachment.contentType,
                name: attachment.name,
              ),
              style: const TextStyle(fontSize: 24),
            ),
          )
        : Image(
            image: provider,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => Container(
              color: BondColors.previewGround,
            ),
          );

    if (overflowCount != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          Container(
            key: overflowKey,
            color: BondColors.ink.withValues(alpha: _scrimAlpha),
            alignment: Alignment.center,
            child: Text(
              '+$overflowCount',
              style: BondType.title.copyWith(color: BondColors.onDarkPrimary),
            ),
          ),
        ],
      );
    }

    final tile = SizedBox(
      key: tileKeyFor(attachment),
      width: tileSize,
      height: tileSize,
      child: ClipRRect(borderRadius: BondRadii.smAll, child: content),
    );

    if (tap == null) return tile;
    // Its own transparent Material — ink paints on the nearest Material
    // ancestor, which is behind the pane's own decorated surface.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => tap(attachment),
        borderRadius: BondRadii.smAll,
        child: tile,
      ),
    );
  }
}
