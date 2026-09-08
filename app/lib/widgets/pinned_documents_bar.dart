import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
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
/// Phase 5 swaps these entries for the compact document cards; the bar's place
/// and meaning do not change with them.
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

  /// A file name can be arbitrarily long; a bookmark bar of them cannot.
  static const double _entryMaxWidth = 200;

  @override
  Widget build(BuildContext context) {
    if (documents.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: barKey,
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: [
        for (final document in documents) _entry(document),
      ],
    );
  }

  Widget _entry(AttachmentRef document) {
    final glyph = attachmentGlyph(
      document.kind,
      document.contentType,
      name: document.name,
    );
    final open = onOpen;
    // Its own transparent Material, because ink paints on the nearest Material
    // ANCESTOR — which here is the room's opaque surface, where no hover could
    // ever show.
    return Material(
      key: entryKeyFor(document),
      type: MaterialType.transparency,
      child: InkWell(
        onTap: open == null ? null : () => open(document),
        borderRadius: BondRadii.fullAll,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: BondSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: BondColors.faintGround,
            borderRadius: BondRadii.fullAll,
            border: Border.all(color: BondColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.push_pin_outlined, size: 12),
              const SizedBox(width: BondSpacing.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _entryMaxWidth),
                child: Text(
                  '$glyph ${document.name ?? '(unnamed)'}',
                  style: BondType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
