import 'package:flutter/material.dart';

import '../providers/draft_provider.dart' show PendingSend;
import '../services/llm/draft_task.dart' show DraftOption;
import '../theme/tokens.dart';
import 'composer.dart' show Composer;

/// The short answers, under the newest message: at most two cards, each one a
/// reply that could go as it stands.
///
/// Machine-written text reads the same everywhere in this app — the accent rule
/// down the left is the composer's, and it means the same thing here: these
/// words are the model's until somebody acts on them. Two cards is the ceiling
/// because two is the point at which a choice is still a choice; a row of five
/// is a menu, and the user would read all five before writing their own reply
/// anyway.
///
/// Tapping a card SENDS only when [armed]. Without a send grant the same tap
/// opens the reply window with the text in it, because a card that appeared to
/// send and quietly did not would be worse than one that never offered.
class QuickReplyBar extends StatelessWidget {
  /// Zero, one or two. Zero renders the `Reply…` affordance alone — this bar
  /// is also how a thread with no suggestions reaches the composer.
  final List<DraftOption> options;

  /// Whether a tap on a card sends. False means it prefills instead, and the
  /// cards say so.
  final bool armed;

  /// A card was tapped. What that means is the host's decision, not this
  /// widget's.
  final void Function(DraftOption option) onPick;

  /// Opens the reply window.
  final VoidCallback onReply;

  /// Closes the suggestions. Null hides the ×.
  final VoidCallback? onDismiss;

  /// Non-null while a send is queued: the cards give way to the undo row, in
  /// place, so the thing being taken back sits where the thing that started it
  /// was.
  final PendingSend? pending;

  final VoidCallback? onUndo;

  const QuickReplyBar({
    super.key,
    this.options = const [],
    this.armed = false,
    required this.onPick,
    required this.onReply,
    this.onDismiss,
    this.pending,
    this.onUndo,
  });

  /// Enough of the reply to recognise which one is going, and no more — the
  /// undo row is a question about a decision the user just made, not a
  /// second look at the text.
  static const int _pendingPreviewCap = 80;

  @override
  Widget build(BuildContext context) {
    final queued = pending;
    if (queued != null) return _tile(_pendingRow(queued));
    if (options.isEmpty) return _replyRow();
    return _tile(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Wrap rather than Row: a narrow pane stacks the two cards instead of
          // squeezing both replies down to one word each.
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s8,
            children: [
              for (final option in options) _card(option),
            ],
          ),
          // Said once, above the button, both ways: a card that sends and a
          // card that prefills look identical, so the words are the only thing
          // separating "one tap and this is on its way" from "one tap and you
          // are editing it" — and guessing wrong in either direction is the
          // dishonest version of this bar.
          const SizedBox(height: BondSpacing.s8),
          Text(
            armed
                ? 'Tap a suggestion to send it — you can undo for a few '
                    'seconds.'
                : 'Tap a reply to open it in the composer.',
            style: BondType.caption,
          ),
          const SizedBox(height: BondSpacing.s4),
          _replyRow(),
        ],
      ),
    );
  }

  /// The surface the suggestions sit on, marked as the model's with the same
  /// left rule the composer draws around an untouched draft.
  Widget _tile(Widget child) {
    return Container(
      padding: const EdgeInsets.all(BondSpacing.s12),
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      child: Container(
        padding: const EdgeInsets.only(left: BondSpacing.s8),
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: BondColors.seaGlassOnDark, width: 2),
          ),
        ),
        child: child,
      ),
    );
  }

  /// One suggestion, whole: the full reply is the thing being offered, and a
  /// tap may SEND it — nobody should commit to words they could only read
  /// three lines of. No tooltip for the rest; the card just takes the height
  /// its words need.
  ///
  /// The header is the action: an icon that says what the tap does (send when
  /// [armed], compose when not) beside the stance in the app's action color.
  Widget _card(DraftOption option) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _cardWidth),
      child: InkWell(
        onTap: () => onPick(option),
        borderRadius: BondRadii.smAll,
        child: Container(
          padding: const EdgeInsets.all(BondSpacing.s8),
          decoration: BoxDecoration(
            borderRadius: BondRadii.smAll,
            border: Border.all(color: BondColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    armed ? Icons.send_outlined : Icons.edit_outlined,
                    size: 14,
                    color: BondColors.primary,
                  ),
                  const SizedBox(width: BondSpacing.s4),
                  Expanded(
                    child: Text(
                      option.stance,
                      style: BondType.label.copyWith(
                        fontWeight: FontWeight.w600,
                        color: BondColors.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                option.body,
                style: BondType.caption.copyWith(
                  color: BondColors.ink
                      .withValues(alpha: Composer.suggestedOpacity),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The way into the composer, plus the × when there is something to close.
  /// Quiet on purpose: writing your own reply is the normal case, and it is one
  /// click either way.
  Widget _replyRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: onReply,
          icon: const Icon(Icons.reply_outlined, size: 16),
          label: const Text('Reply…'),
        ),
        const Spacer(),
        if (options.isNotEmpty && onDismiss != null)
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
            iconSize: 16,
            tooltip: 'Dismiss suggestions',
            padding: const EdgeInsets.all(BondSpacing.s4),
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _pendingRow(PendingSend queued) {
    final firstLine = queued.body.split('\n').first.trim();
    final preview = firstLine.length > _pendingPreviewCap
        ? '${firstLine.substring(0, _pendingPreviewCap)}…'
        : firstLine;
    return Row(
      children: [
        Expanded(
          child: Text(
            preview,
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: BondSpacing.s8),
        Text('Sending…', style: BondType.caption),
        const SizedBox(width: BondSpacing.s4),
        TextButton(onPressed: onUndo, child: const Text('Undo')),
      ],
    );
  }

  /// Wide enough for three lines of a short reply, narrow enough that two sit
  /// side by side in the thread pane.
  static const double _cardWidth = 320;
}
