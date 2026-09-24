import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart' show attachmentKey;

/// The message a reply quoted, drawn above the reply itself.
///
/// Teams sends a quote-reply as an ATTACHMENT — a `messageReference` with no
/// name, no url and nothing to fetch — and the transcript used to draw it as
/// every other attachment: a `🔗 (unnamed)` chip whose tap opened a preview
/// panel with nothing in it. It was never a file. It is a piece of the
/// conversation the sender pointed back at, so it reads as one: a muted left
/// rule, who said it, and enough of what they said to recognise the turn.
///
/// Two lines of snippet and no more, because the quoted message is somewhere
/// else on this same screen. The block is a STATEMENT this round — no tap, no
/// hover, no cursor: jumping to the quoted message (and highlighting it) is
/// Phase 5's, and a control that looked tappable and did nothing would be the
/// dead end this replaced.
///
/// Draws nothing at all when Graph sent a reference with neither a sender nor a
/// snippet in it: an empty rule says less than the words underneath it.
class QuoteBlock extends StatelessWidget {
  /// The `message_reference` row. Read through [AttachmentRef.quotedSender] and
  /// [AttachmentRef.quotedPreview], so the column reuse behind them stays in
  /// the model.
  final AttachmentRef attachment;

  const QuoteBlock({super.key, required this.attachment});

  /// The key the transcript builds this under. Keyed by the reference itself,
  /// like every other attachment widget: a re-list must not move it.
  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('message-row-quote', attachment);

  /// How much of the quoted message is shown, whatever the sender's client put
  /// in the preview: two lines of it at this size, with the tail ellipsized.
  static const int previewMaxLines = 2;

  @override
  Widget build(BuildContext context) {
    final sender = attachment.quotedSender?.trim() ?? '';
    final preview = attachment.quotedPreview?.trim() ?? '';
    if (sender.isEmpty && preview.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: BondColors.border, width: 3),
          ),
        ),
        padding: const EdgeInsets.only(left: BondSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sender.isNotEmpty)
              Text(
                sender,
                style: BondType.caption.copyWith(
                  color: BondColors.inkSecondary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (preview.isNotEmpty)
              Text(
                preview,
                // Plain text, like every message body in this transcript: a
                // preview is the sender's own words and is never markdown, and
                // it is never linkified either — the address in a quoted line
                // is live in the message it was quoted from.
                style: BondType.caption.copyWith(color: BondColors.inkMuted),
                maxLines: previewMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
