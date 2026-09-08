import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_card.dart';
import 'attachment_format.dart';

/// The files somebody pinned to this room, under its name and one tap away —
/// Slack's bookmark bar.
///
/// A pin is a statement that this file is what the room keeps coming back to,
/// and the honest place for that statement is where the room starts rather
/// than behind a tab. Unpinning is NOT here: taking a pin down is a correction,
/// it is a two-step, and it lives on the Files tab beside everything else the
/// room holds — so this bar carries no ×.
///
/// Each entry is an [AttachmentCard] in its compact shape: one line saying what
/// is pinned, and under it the model's one-sentence read of the document. The
/// digest is the whole reason the shape changed — a pinned file is the one
/// whose contents somebody keeps coming back for, so the bar that names it
/// should say what is in it rather than making the reader open it to remember.
class PinnedDocumentsBar extends StatelessWidget {
  final List<AttachmentRef> documents;

  /// Null leaves the entries inert — the bar still says what is pinned.
  final void Function(AttachmentRef attachment)? onOpen;

  const PinnedDocumentsBar({
    super.key,
    required this.documents,
    this.onOpen,
  });

  static const Key barKey = ValueKey('pinned-documents-bar');

  static ValueKey<String> entryKeyFor(AttachmentRef attachment) =>
      attachmentKey('pinned-entry', attachment);

  @override
  Widget build(BuildContext context) {
    if (documents.isEmpty) return const SizedBox.shrink();
    final open = onOpen;
    return Wrap(
      key: barKey,
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: [
        for (final document in documents)
          AttachmentCard(
            key: entryKeyFor(document),
            attachment: document,
            compact: true,
            onTap: open == null ? null : () => open(document),
          ),
      ],
    );
  }
}
