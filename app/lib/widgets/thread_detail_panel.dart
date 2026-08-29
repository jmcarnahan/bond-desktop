import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'email_bubble.dart';
import 'inline_alert.dart';

/// The thread view: right column on wide layouts, stacked below the list on
/// narrow ones. It fills whatever box the parent gives it.
///
/// No composer yet — this phase reads mail, it does not send it.
class ThreadDetailPanel extends StatelessWidget {
  final Conversation conversation;
  final List<Message> messages;

  /// Flips the thread to done. Phase 1 mutates the in-memory fixture list.
  final VoidCallback onMarkDone;

  const ThreadDetailPanel({
    super.key,
    required this.conversation,
    required this.messages,
    required this.onMarkDone,
  });

  static String _stateLabel(ConversationState state) => switch (state) {
        ConversationState.needsReply => 'Needs reply',
        ConversationState.waiting => 'Waiting',
        ConversationState.done => 'Done',
      };

  static BondTone _stateTone(ConversationState state) => switch (state) {
        ConversationState.needsReply => BondTone.attention,
        ConversationState.waiting => BondTone.neutral,
        ConversationState.done => BondTone.success,
      };

  @override
  Widget build(BuildContext context) {
    final cta = conversation.ctaText;
    final showCta = conversation.state == ConversationState.needsReply &&
        cta != null &&
        cta.isNotEmpty;

    // A height-filling bordered surface, not a shrink-wrapping card: the
    // message ListView below needs a bounded height to scroll in.
    return Container(
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const Divider(height: 1, color: BondColors.border),
          if (showCta)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BondSpacing.s16,
                BondSpacing.s12,
                BondSpacing.s16,
                0,
              ),
              // Two lines, not however many the model wrote: the ask sits
              // directly above the transcript, and the tooltip keeps the full
              // text a hover away.
              child: Tooltip(
                message: cta,
                child: InlineAlert(
                  severity: InlineAlertSeverity.attention,
                  text: cta,
                  maxLines: 2,
                ),
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text('No messages in this thread.',
                        style: BondType.small),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(BondSpacing.s16),
                    itemCount: messages.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: BondSpacing.s16),
                    itemBuilder: (context, i) =>
                        EmailBubble(message: messages[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final participants = conversation.participants
        .map((p) => p.display)
        .where((d) => d.isNotEmpty)
        .join(', ');

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            conversation.subject?.isNotEmpty == true
                ? conversation.subject!
                : '(no subject)',
            style: BondType.titleSm,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (participants.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(
              participants,
              style: BondType.small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: BondSpacing.s12),
          Wrap(
            spacing: BondSpacing.s12,
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              BondChip.semantic(
                _stateLabel(conversation.state),
                _stateTone(conversation.state),
              ),
              if (conversation.state != ConversationState.done)
                TextButton(
                  onPressed: onMarkDone,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s8,
                    ),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Mark done'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
