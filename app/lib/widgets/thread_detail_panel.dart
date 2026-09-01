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

  /// Opens the pane that picks — or names — the storyline this thread goes
  /// into. The menu does not list the storylines itself: the choice is a pane
  /// with a way back, because the house rule is screens rather than popups.
  /// Null hides the item, so a host that knows nothing about storylines
  /// renders exactly what it used to.
  final VoidCallback? onAddToStoryline;

  /// Defers this thread's sender. Sender-scoped rather than thread-scoped
  /// because that is the correction worth collecting: one thread going quiet
  /// changes one row, a sender going quiet changes the shape of the inbox.
  /// Null hides the item.
  final VoidCallback? onSendToLater;

  /// Brings a deferred thread back. Only shown when the thread is actually in
  /// a bucket — an "undo" for something that never happened is a menu item
  /// that reads as broken.
  final VoidCallback? onKeepInInbox;

  /// Rendered at the END of the transcript, inside the same scroll view and
  /// indented to the message body column, so it reads as attached to the last
  /// message rather than parked under the pane.
  ///
  /// Hosts pass the reply affordance here. The panel does not know what it is
  /// and does not ask — it renders a transcript and knows nothing about drafts
  /// or sending, which is the arrangement the composer already lives under.
  final Widget? afterTranscript;

  const ThreadDetailPanel({
    super.key,
    required this.conversation,
    required this.messages,
    required this.onMarkDone,
    this.onBack,
    this.onAddToStoryline,
    this.onSendToLater,
    this.onKeepInInbox,
    this.afterTranscript,
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

    final after = afterTranscript;
    if (after != null) {
      items.add(Padding(
        // The avatar column plus its gutter — `MessageRow` reserves exactly
        // this much on continuation rows, so the affordance starts where the
        // message bodies above it do.
        padding: const EdgeInsets.only(
          left: _bodyColumnInset,
          top: BondSpacing.s16,
        ),
        child: after,
      ));
    }
    return items;
  }

  /// [MessageRow]'s avatar diameter (36) plus the gutter it puts beside it.
  static const double _bodyColumnInset = 36 + BondSpacing.s12;

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
          ?_overflowMenu(),
        ],
      ),
    );
  }

  /// Filing this thread — into a storyline, or out of the inbox. An overflow
  /// menu rather than visible controls: these are corrections, not part of
  /// reading mail, and the automatic passes are supposed to get them right
  /// without being asked.
  ///
  /// The storyline half is one item that opens a pane. Listing every storyline
  /// here would put the whole choice in a popup, and the house rule is a screen
  /// with a way back.
  Widget? _overflowMenu() {
    final bucketed = conversation.bucket != null;
    final showKeep = onKeepInInbox != null && bucketed;
    if (onAddToStoryline == null && onSendToLater == null && !showKeep) {
      return null;
    }

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz),
      iconSize: 20,
      tooltip: 'More',
      itemBuilder: (context) => [
        if (onAddToStoryline != null)
          const PopupMenuItem<String>(
            value: _addToStorylineValue,
            child: Text('Add to storyline…'),
          ),
        if (onAddToStoryline != null && (onSendToLater != null || showKeep))
          const PopupMenuDivider(),
        if (onSendToLater != null)
          const PopupMenuItem<String>(
            value: _sendToLaterValue,
            child: Text('Send to Later'),
          ),
        if (showKeep)
          const PopupMenuItem<String>(
            value: _keepInInboxValue,
            child: Text('Keep in inbox'),
          ),
      ],
      onSelected: (value) {
        switch (value) {
          case _addToStorylineValue:
            onAddToStoryline?.call();
          case _sendToLaterValue:
            onSendToLater?.call();
          case _keepInInboxValue:
            onKeepInInbox?.call();
        }
      },
    );
  }

  static const String _addToStorylineValue = '__add_to_storyline__';
  static const String _sendToLaterValue = '__send_to_later__';
  static const String _keepInInboxValue = '__keep_in_inbox__';
}
