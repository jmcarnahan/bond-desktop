/// What the panel shows when there is nothing to show.
///
/// A stated answer rather than an empty pane: "there is no preview for this
/// kind of file" and "this file is 24 MB — too large to preview here" are
/// different facts, and a reader who is told which one applies knows whether
/// to press Save or to give up. The dashed frame is the same one
/// `InlineImageThumb` uses for a picture that has not arrived, so the two read
/// as the same absence.
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../attachment_format.dart';

class UnsupportedPreview extends StatelessWidget {
  /// The file's own glyph, from `attachmentGlyph` — the host picks it, because
  /// the reason a preview is missing does not always come from the file's kind
  /// (a link and a too-large PDF land here from different rungs).
  final String glyph;

  final String? name;

  /// Rendered through `formatBytes`, so an unknown size (0) says nothing at
  /// all rather than `0 B`.
  final int? size;

  final String? reason;

  /// The way out, when there is one: an Open-in-Outlook link for a file this
  /// app cannot fetch. Null renders nothing — an empty button row under a
  /// refusal reads as a control that stopped working.
  final Widget? action;

  const UnsupportedPreview({
    super.key,
    required this.glyph,
    this.name,
    this.size,
    this.reason,
    this.action,
  });

  static const Key reasonKey = ValueKey('unsupported-preview-reason');

  @override
  Widget build(BuildContext context) {
    final sizeText = formatBytes(size);
    final act = action;
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(BondSpacing.s24),
      decoration: BoxDecoration(
        color: BondColors.previewGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.borderDashed),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(glyph, style: BondType.heading),
          if (name != null && name!.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s8),
            Text(
              name!,
              style: BondType.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
          if (sizeText.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(sizeText, style: BondType.caption),
          ],
          const SizedBox(height: BondSpacing.s8),
          Text(
            reason ?? 'There is no preview for this kind of file.',
            key: reasonKey,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
            textAlign: TextAlign.center,
          ),
          if (act != null) ...[
            const SizedBox(height: BondSpacing.s8),
            act,
          ],
        ],
      ),
    );
  }
}
