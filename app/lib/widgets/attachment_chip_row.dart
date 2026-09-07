import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_chip.dart';
import 'attachment_format.dart';

/// The files a message carried, in the order the connector listed them.
///
/// A `Wrap` rather than a scrolling row: a message with six attachments should
/// show all six, and a horizontal scroller inside a vertical transcript hides
/// files behind a gesture nobody makes.
///
/// Empty renders NOTHING — not an empty box with padding around it. Most
/// messages have no attachments, and a zero-height widget that still costs a
/// gap would show up as a crooked line under every one of them.
class AttachmentChipRow extends StatelessWidget {
  final List<AttachmentRef> attachments;

  /// The file the preview is showing, if it is one of these. Matched with
  /// `sameAttachment`, never `==`.
  final AttachmentRef? selected;

  /// Null leaves every chip a statement — see [AttachmentChip.onTap].
  final void Function(AttachmentRef attachment)? onOpen;

  const AttachmentChipRow({
    super.key,
    required this.attachments,
    this.selected,
    this.onOpen,
  });

  static const Key rowKey = ValueKey('attachment-chip-row');

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final open = onOpen;
    return Wrap(
      key: rowKey,
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final attachment in attachments)
          AttachmentChip(
            key: AttachmentChip.keyFor(attachment),
            attachment: attachment,
            selected: sameAttachment(selected, attachment),
            onTap: open == null ? null : () => open(attachment),
          ),
      ],
    );
  }
}
