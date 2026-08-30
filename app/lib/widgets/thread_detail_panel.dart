import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'inline_alert.dart';
import 'message_row.dart';
import 'time_format.dart';

/// The thread view: the main pane's whole content once a thread is open.
///
/// The transcript reads as one flat column — day dividers, left-aligned
/// messages, runs collapsed under one header — rather than as a chat of
/// facing bubbles.
///
/// No composer yet — this phase reads mail, it does not send it.
class ThreadDetailPanel extends StatelessWidget {
  final Conversation conversation;
  final List<Message> messages;

  /// Flips the thread to done.
  final VoidCallback onMarkDone;

  /// Returns to the section overview. Null hides the back affordance, for
  /// layouts where the thread is not something you navigated into.
  final VoidCallback? onBack;

  const ThreadDetailPanel({
    super.key,
    required this.conversation,
    required this.messages,
    required this.onMarkDone,
    this.onBack,
  });

  /// Wide enough for a long paragraph, narrow enough that an ultrawide window
  /// does not turn every message into one unreadable line.
  static const double _maxContentWidth = 900;

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

  /// The transcript, flattened: a divider each time the calendar day turns
  /// over, then one row per message with its header suppressed when it
  /// continues the run above it.
  List<Widget> _transcript() {
    final items = <Widget>[];
    String? previousDay;
    Message? previous;
    var first = true;

    for (final message in messages) {
      final day = dayKeyOf(message);
      final label = formatDayLabel(message.receivedAt);
      if (label != null && (first || day != previousDay)) {
        items.add(DayDivider(label: label));
        // A new day always opens with a full header, however close in time
        // the previous message was.
        previous = null;
      }
      previousDay = day;
      first = false;

      items.add(MessageRow(
        key: ValueKey(message.id),
        message: message,
        showHeader: previous == null || !sameRun(previous, message),
      ));
      previous = message;
    }
    return items;
  }

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
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _maxContentWidth,
                      ),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          BondSpacing.s24,
                          0,
                          BondSpacing.s24,
                          BondSpacing.s24,
                        ),
                        children: _transcript(),
                      ),
                    ),
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
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s16,
        vertical: BondSpacing.s12,
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              iconSize: 20,
              tooltip: 'Back',
            ),
            const SizedBox(width: BondSpacing.s4),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  conversation.subject?.isNotEmpty == true
                      ? conversation.subject!
                      : '(no subject)',
                  style: BondType.titleSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (participants.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    participants,
                    style: BondType.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: BondSpacing.s12),
          BondChip.semantic(
            _stateLabel(conversation.state),
            _stateTone(conversation.state),
          ),
          if (conversation.state != ConversationState.done) ...[
            const SizedBox(width: BondSpacing.s4),
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
        ],
      ),
    );
  }
}
