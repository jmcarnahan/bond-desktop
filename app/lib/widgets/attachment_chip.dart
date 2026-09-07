import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';

/// One file, named where the message that carried it can be read.
///
/// A chip rather than a list row because attachments are part of a message, not
/// a section of their own: they wrap under the body in the reading column and
/// take exactly as much width as their name needs.
///
/// Selection is fill and border, never size — a chip that grew when it was
/// picked would reflow the whole run beneath it and move the next file out from
/// under the pointer.
class AttachmentChip extends StatelessWidget {
  final AttachmentRef attachment;

  /// Whether this is the file the preview is showing. Compared by the host
  /// through `sameAttachment` — [AttachmentRef] has no `==`.
  final bool selected;

  /// What tapping it does. Null leaves it a statement, the same rule
  /// `MessageRow._askLine` follows: a chip whose host has nowhere to send the
  /// tap must not look like it takes one.
  final VoidCallback? onTap;

  const AttachmentChip({
    super.key,
    required this.attachment,
    this.selected = false,
    this.onTap,
  });

  /// Characters, not code units: an emoji or a combining accent in a file name
  /// is one thing the reader sees, and cutting a name mid-grapheme renders a
  /// replacement box.
  static const int nameCap = 28;

  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('attachment-chip', attachment);

  @override
  Widget build(BuildContext context) {
    final glyph = attachmentGlyph(
      attachment.kind,
      attachment.contentType,
      name: attachment.name,
    );
    final size = formatBytes(attachment.size);
    final tap = onTap;

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? BondColors.previewGround : BondColors.surface,
        borderRadius: BondRadii.fullAll,
        border: Border.all(
          color: selected ? BondColors.primary : BondColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(glyph, style: BondType.caption),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              _displayName,
              style: BondType.label.copyWith(
                letterSpacing: 0,
                fontSize: 12,
                color: BondColors.ink,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (size.isNotEmpty) ...[
            const SizedBox(width: 5),
            Text(size, style: BondType.caption),
          ],
          // What the model is doing with this file, in the model's own quiet
          // voice — and only once a digest is genuinely on its way: the words
          // have landed and the model has not answered yet. A freshly synced
          // attachment is `pending` on both counts, and a chip that said
          // "reading…" on every file the policy will never read would be a
          // promise the pipeline does not keep.
          if (attachment.textStatus == 'done' &&
              attachment.digestStatus == 'pending') ...[
            const SizedBox(width: 5),
            Text(
              'reading…',
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
          ],
        ],
      ),
    );

    if (tap == null) return body;
    // Its own transparent Material: ink paints on the nearest Material
    // ANCESTOR, and the thread pane is a decorated Container — the trap
    // `message_row._askLine` and `thread_detail_panel._ctaBanner` document.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: tap,
        borderRadius: BondRadii.fullAll,
        child: body,
      ),
    );
  }

  /// The name, truncated on graphemes before the `Text` sees it.
  ///
  /// Ellipsis alone would do the eliding, but only after laying out the whole
  /// string — a 300-character name in a `Wrap` measures every one of those
  /// characters on every frame.
  String get _displayName {
    final name = attachment.name?.trim() ?? '';
    if (name.isEmpty) return '(unnamed)';
    final characters = name.characters;
    if (characters.length <= nameCap) return name;
    return '${characters.take(nameCap)}…';
  }
}
