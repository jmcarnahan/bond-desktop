import 'package:flutter/material.dart';

import '../providers/draft_provider.dart' show PendingSend;
import '../services/llm/draft_task.dart' show DraftOption;
import '../theme/tokens.dart';
import 'composer.dart' show Composer;

/// The short answers to one message: at most two cards, each one a reply that
/// could go as it stands.
///
/// Drawn twice over, from the same widget. Under the transcript it is the
/// composer's doorway and the undo row; inline, under each message that still
/// has a live suggestion, it is the cards alone — [showReplyRow] hides the
/// trailing row there, because the `Reply…`/`Suggest a reply` affordance is
/// about the THREAD and belongs once, at the bottom, rather than repeated under
/// every message the model answered.
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
class QuickReplyBar extends StatefulWidget {
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

  /// Asks for suggestions on a thread that has none — including one whose
  /// cards the user closed. Offered ONLY in the zero-options state: a bar
  /// already holding suggestions has nothing to ask for, and the composer's
  /// Regenerate is where a different pair comes from.
  final VoidCallback? onSuggest;

  /// A suggestion is being written right now.
  final bool suggesting;

  /// Whether the trailing `Reply…` row is drawn. False on an inline card, where
  /// the way into the composer already sits at the end of the transcript — and
  /// where a bar with no options has nothing left to draw at all.
  final bool showReplyRow;

  const QuickReplyBar({
    super.key,
    this.options = const [],
    this.armed = false,
    required this.onPick,
    required this.onReply,
    this.onDismiss,
    this.pending,
    this.onUndo,
    this.onSuggest,
    this.suggesting = false,
    this.showReplyRow = true,
  });

  @override
  State<QuickReplyBar> createState() => _QuickReplyBarState();
}

class _QuickReplyBarState extends State<QuickReplyBar> {
  /// Whether the × has been armed. The cards stay up while it is: the question
  /// is about them, and answering it should not mean remembering what they
  /// said.
  bool _confirmingDismiss = false;

  /// Enough of the reply to recognise which one is going, and no more — the
  /// undo row is a question about a decision the user just made, not a
  /// second look at the text.
  static const int _pendingPreviewCap = 80;

  /// Wide enough for three lines of a short reply, narrow enough that two sit
  /// side by side in the thread pane.
  static const double _cardWidth = 320;

  @override
  void didUpdateWidget(covariant QuickReplyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh PAIR is a fresh question — left standing, the half-answered one
    // would sit under two suggestions nobody has been asked about yet. A fresh
    // LIST OBJECT holding the same words is the same question, mid-answer:
    // `DraftState.options` mints a new list on every read, so an identity check
    // here would disarm the ×'s question on any parent rebuild — every inbox
    // setState, every sync reload.
    if (!_sameOptions(oldWidget.options, widget.options)) {
      _confirmingDismiss = false;
    }
  }

  /// Whether two option lists say the same thing. By value, because
  /// [DraftOption] has no `==`.
  bool _sameOptions(List<DraftOption> a, List<DraftOption> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].stance != b[i].stance || a[i].body != b[i].body) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final queued = widget.pending;
    if (queued != null) return _tile(_pendingRow(queued));
    // Nothing to offer and no row to offer it in: an inline card with no
    // options is not an empty state, it is a card that should not be there.
    if (widget.options.isEmpty) return _replyRow() ?? const SizedBox.shrink();
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
              for (final option in widget.options) _card(option),
            ],
          ),
          const SizedBox(height: BondSpacing.s8),
          // The confirm takes the caption's line rather than opening anything:
          // the two-step stands where a confirm dialog would, and it belongs
          // where the words it is replacing were.
          if (_confirmingDismiss)
            _confirmRow()
          else
            // Said once, above the button, both ways: a card that sends and a
            // card that prefills look identical, so the words are the only
            // thing separating "one tap and this is on its way" from "one tap
            // and you are editing it" — and guessing wrong in either direction
            // is the dishonest version of this bar.
            Text(
              widget.armed
                  ? 'Tap a suggestion to send it — you can undo for a few '
                      'seconds.'
                  : 'Tap a reply to open it in the composer.',
              style: BondType.caption,
            ),
          const SizedBox(height: BondSpacing.s4),
          ?_replyRow(),
        ],
      ),
    );
  }

  /// The question the × asks, and both answers. Quiet buttons: throwing away
  /// two suggestions is a small act, and the row it sits in is a caption.
  Widget _confirmRow() {
    return Row(
      children: [
        Flexible(
          child: Text('Dismiss these suggestions?', style: BondType.caption),
        ),
        _quietButton('Dismiss', () {
          setState(() => _confirmingDismiss = false);
          widget.onDismiss?.call();
        }),
        _quietButton('Keep', () => setState(() => _confirmingDismiss = false)),
      ],
    );
  }

  Widget _quietButton(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
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
      // Its own transparent Material, because ink paints on the nearest
      // Material ANCESTOR — which is behind this bar's opaque surface tile,
      // where no hover could ever show. On its own layer the card lights up
      // under the mouse like every other clickable thing in the app.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => widget.onPick(option),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.primaryTint,
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
                      widget.armed
                          ? Icons.send_outlined
                          : Icons.edit_outlined,
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
      ),
    );
  }

  /// The way into the composer, plus the × when there is something to close.
  /// Quiet on purpose: writing your own reply is the normal case, and it is one
  /// click either way.
  ///
  /// Asking for a suggestion sits beside it, and only where there is nothing to
  /// suggest yet — that is what makes a dismissal reversible: the × takes the
  /// cards away, and this button is how they come back.
  ///
  /// Null when there is nothing left to draw. Without [showReplyRow] the two
  /// buttons are gone — they are about the thread, and an inline card is about
  /// one message — but the × stays: it closes THESE cards, and it is the only
  /// thing on the row that belongs to them.
  Widget? _replyRow() {
    final suggest = widget.onSuggest;
    final canDismiss = widget.options.isNotEmpty && widget.onDismiss != null;
    if (!widget.showReplyRow && !canDismiss) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showReplyRow)
          TextButton.icon(
            onPressed: widget.onReply,
            icon: const Icon(Icons.reply_outlined, size: 16),
            label: const Text('Reply…'),
          ),
        if (widget.showReplyRow && suggest != null && widget.options.isEmpty)
          TextButton.icon(
            onPressed: widget.suggesting ? null : suggest,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(widget.suggesting ? 'Drafting…' : 'Suggest a reply'),
          ),
        const Spacer(),
        if (canDismiss)
          IconButton(
            // Arms rather than closes: what the × means has not changed, only
            // how many taps it takes to mean it.
            onPressed: () => setState(() => _confirmingDismiss = true),
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
        TextButton(onPressed: widget.onUndo, child: const Text('Undo')),
      ],
    );
  }
}
