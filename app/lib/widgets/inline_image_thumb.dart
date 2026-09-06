import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';

/// A picture drawn where the sender put it, at a size that keeps the transcript
/// readable.
///
/// It takes an [ImageProvider] rather than bytes or a path for two reasons: the
/// bytes arrive asynchronously and from a cache this widget must know nothing
/// about, and a test can hand over a `MemoryImage` where the app hands over a
/// `FileImage` — no widget under here ever touches the disk.
///
/// Bounded on BOTH axes, always. This lives inside the thread's `ListView`,
/// where an unbounded child is not a layout mistake with a wrong-looking result
/// but an assertion.
class InlineImageThumb extends StatelessWidget {
  final AttachmentRef attachment;

  /// Null means "no bytes yet, or none that decoded" — the frame stands in, so
  /// the reader still sees that a picture belongs here.
  final ImageProvider? image;

  final double maxWidth;
  final double maxHeight;
  final VoidCallback? onTap;

  const InlineImageThumb({
    super.key,
    required this.attachment,
    required this.image,
    this.maxWidth = 320,
    this.maxHeight = 240,
    this.onTap,
  });

  /// The height of the stand-in frame: tall enough to read as a picture's
  /// place, short enough that a thread of unfetched images still scrolls.
  static const double placeholderHeight = 96;

  /// The key the HOST puts on this widget — the row does, so that a picture
  /// keeps its decode across a rebuild. Nothing inside carries it, so
  /// `find.byKey` names exactly one widget.
  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('inline-image', attachment);

  static ValueKey<String> placeholderKeyFor(AttachmentRef attachment) =>
      attachmentKey('inline-image-placeholder', attachment);

  @override
  Widget build(BuildContext context) {
    final provider = image;
    final tap = onTap;

    final Widget picture = provider == null
        ? _placeholder()
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: ClipRRect(
              borderRadius: BondRadii.smAll,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: BondColors.previewGround,
                ),
                child: Image(
                  image: provider,
                  fit: BoxFit.contain,
                  // The same picture across a rebuild keeps its pixels rather
                  // than flashing empty while it decodes again — a transcript
                  // rebuilds on every sync.
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) => _placeholder(),
                ),
              ),
            ),
          );

    // Left in the gutter and never stretched to the pane. A parent that hands
    // down a TIGHT width — a `ListView` child does exactly that — would
    // otherwise beat the constraints below it and letterbox a small picture
    // across the whole thread.
    final content = Align(alignment: Alignment.centerLeft, child: picture);

    if (tap == null) return content;
    // Its own transparent Material — ink paints on the nearest Material
    // ancestor, which is behind the pane's own decorated surface.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: tap,
        borderRadius: BondRadii.smAll,
        child: content,
      ),
    );
  }

  Widget _placeholder() {
    final glyph = attachmentGlyph(
      attachment.kind,
      attachment.contentType,
      name: attachment.name,
    );
    return Container(
      key: placeholderKeyFor(attachment),
      width: maxWidth,
      height: placeholderHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BondColors.previewGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.borderDashed),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
        child: Text(
          '$glyph ${attachment.name ?? 'image'}',
          style: BondType.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
