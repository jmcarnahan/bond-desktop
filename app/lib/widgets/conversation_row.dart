import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'time_format.dart';

/// One row per thread: a state dot, the primary participant, the subject, a
/// CTA (needs-reply) or the last-message preview, the timestamp, and a chip
/// row.
class ConversationRow extends StatelessWidget {
  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  const ConversationRow({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  /// Urgent needs-reply is error, needs-reply is attention, waiting is
  /// neutral, done is success.
  BondTone get _dotTone {
    switch (conversation.state) {
      case ConversationState.needsReply:
        return conversation.ctaUrgency == CtaUrgency.urgent
            ? BondTone.error
            : BondTone.attention;
      case ConversationState.done:
        return BondTone.success;
      case ConversationState.waiting:
        return BondTone.neutral;
    }
  }

  /// The CTA line's ink. Only the top two urgencies get a tint — tinting
  /// every ask would make none of them read as louder than the others.
  Color get _ctaColor => switch (conversation.ctaUrgency) {
        CtaUrgency.urgent => BondColors.onErrorTint,
        CtaUrgency.high => BondColors.onAttentionTint,
        CtaUrgency.normal || CtaUrgency.low => BondColors.inkSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final cta = c.ctaText;
    final hasCta = cta != null && cta.isNotEmpty;
    final secondary = hasCta ? cta : c.lastMessagePreview;
    final who = c.primaryParticipant?.display ?? '(no sender)';
    final time = formatTimestamp(c.lastMessageAt);

    // The 2px selection ring paints over the constant 1px border rather than
    // replacing it, so selecting a row never shifts the list's layout.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      foregroundDecoration: selected
          ? BoxDecoration(
              borderRadius: BondRadii.mdAll,
              border: Border.all(color: BondColors.primary, width: 2),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: BondColors.surface,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: BondChip.dot(_dotTone),
                ),
                const SizedBox(width: BondSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              who,
                              style: BondType.body
                                  .copyWith(fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (time != null) ...[
                            const SizedBox(width: BondSpacing.s8),
                            Text(time, style: BondType.caption),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        c.subject?.isNotEmpty == true
                            ? c.subject!
                            : '(no subject)',
                        style: BondType.small.copyWith(color: BondColors.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (secondary != null && secondary.isNotEmpty) ...[
                        const SizedBox(height: BondSpacing.s4),
                        Text(
                          secondary,
                          style: hasCta
                              ? BondType.small.copyWith(
                                  color: _ctaColor,
                                  fontWeight: FontWeight.w600,
                                )
                              : BondType.small,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: BondSpacing.s8),
                      Wrap(
                        spacing: BondSpacing.s8,
                        runSpacing: BondSpacing.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (c.ctaUrgency == CtaUrgency.urgent)
                            const BondChip(
                                label: 'Urgent', tone: BondTone.attention),
                          BondChip.metric(
                            c.messageCount == 1
                                ? '1 message'
                                : '${c.messageCount} messages',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
