import 'package:flutter/material.dart';

import '../providers/draft_provider.dart' show PendingSend;
import '../services/llm/draft_task.dart' show DraftOption;
import '../theme/tokens.dart';
import 'composer.dart' show Composer;

/// The short answers to one message: at most two cards, each one a reply that
/// could go as it stands.
///
/// Drawn twice over, from the same widget: inline under each message that
/// still has a live suggestion, and once at the end of the transcript, where it
/// is the way to ask for a suggestion on a thread that has none and the undo
/// row while a send is queued.
///
/// It is no longer anybody's doorway. The composer is docked under every thread
/// that can be answered, so there is nothing left here to open — what remains
/// is the cards, the × that closes them, and the button that asks for a fresh
/// pair.
///
/// Machine-written text reads the same everywhere in this app — the accent rule
/// down the left is the composer's, and it means the same thing here: these
/// words are the model's until somebody acts on them. Two cards is the ceiling
/// because two is the point at which a choice is still a choice; a row of five
/// is a menu, and the user would read all five before writing their own reply
/// anyway.
///
/// A TAP never sends. It puts that reply in the docked composer, where the
/// reader changes it or presses Send — because a card is text on screen, and
/// text that quietly put mail in front of somebody is not what a tap on it
/// promises. The card's own Send does send, and asks first: a reply that is
/// already right should not need a trip through the box to go, and the inline
/// question is what keeps the tap and the send from ever being confused.
class QuickReplyBar extends StatefulWidget {
  /// Zero, one or two. Zero leaves the ask-for-a-suggestion button alone, or
  /// nothing at all where there is nothing to ask.
  final List<DraftOption> options;

  /// Whether this build holds a real send grant. It no longer changes what a
  /// card does — every tap stages, either way — and is kept for the pending
  /// row's sake and for the hosts that already know the answer.
  final bool armed;

  /// A card was tapped. What that means is the host's decision, not this
  /// widget's.
  final void Function(DraftOption option) onPick;

  /// Sends a card's reply as it stands, after the card's own confirm. Null
  /// hides the affordance — a host without a real send grant offers nothing
  /// that only looks like a send.
  final void Function(DraftOption option)? onSend;

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

  const QuickReplyBar({
    super.key,
    this.options = const [],
    this.armed = false,
    required this.onPick,
    this.onSend,
    this.onDismiss,
    this.pending,
    this.onUndo,
    this.onSuggest,
    this.suggesting = false,
  });

  /// The card's own Send, and the two answers to the question it asks. Keyed
  /// by INDEX rather than by stance, because two suggestions can share a
  /// stance and a test that tapped the wrong one would still pass.
  static Key sendKeyFor(int index) => Key('quick-reply-send-$index');
  static Key confirmSendKeyFor(int index) =>
      Key('quick-reply-confirm-send-$index');
  static Key cancelSendKeyFor(int index) =>
      Key('quick-reply-cancel-send-$index');

  @override
  State<QuickReplyBar> createState() => _QuickReplyBarState();
}

class _QuickReplyBarState extends State<QuickReplyBar> {
  /// Whether the × has been armed. The cards stay up while it is: the question
  /// is about them, and answering it should not mean remembering what they
  /// said.
  bool _confirmingDismiss = false;

  /// Which card has been asked about, or null. One at a time: the question is
  /// about a specific reply, and two of them standing at once would be two
  /// unanswered questions about words that say different things.
  int? _confirmingSend;

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
      // And the send's question with it, for the same reason: the card the
      // reader was being asked about is not the card that is there now.
      _confirmingSend = null;
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
    // Nothing to offer and nothing to ask with: an inline card with no options
    // is not an empty state, it is a card that should not be there.
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
              for (final (i, option) in widget.options.indexed) _card(i, option),
            ],
          ),
          const SizedBox(height: BondSpacing.s8),
          // The confirm takes the caption's line rather than opening anything:
          // the two-step stands where a confirm dialog would, and it belongs
          // where the words it is replacing were.
          if (_confirmingDismiss)
            _confirmRow()
          else
            // Said once, above the button, and the same sentence in every grant
            // state: what a tap does no longer depends on what Entra consented
            // to, and a card that read differently in two builds is how a
            // reader learns not to trust the line at all.
            Text(
              widget.onSend == null
                  ? 'Tap a reply to put it in the box.'
                  : 'Tap a reply to put it in the box, or send it as it '
                      'stands.',
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

  /// The question a card's Send asks, and both answers — in the card, under
  /// the words it is about. Quiet buttons, like the ×'s: the loud thing on
  /// this card is the reply itself.
  Widget _sendConfirmRow(int index, DraftOption option) {
    return Row(
      children: [
        Flexible(child: Text('Send this reply?', style: BondType.caption)),
        _quietButton(
          'Send',
          () {
            setState(() => _confirmingSend = null);
            widget.onSend!(option);
          },
          key: QuickReplyBar.confirmSendKeyFor(index),
        ),
        _quietButton(
          'Cancel',
          () => setState(() => _confirmingSend = null),
          key: QuickReplyBar.cancelSendKeyFor(index),
        ),
      ],
    );
  }

  Widget _quietButton(String label, VoidCallback onPressed, {Key? key}) {
    return TextButton(
      key: key,
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

  /// One suggestion, whole: a tap puts the ENTIRE reply in the box, so the whole
  /// reply is shown — nobody should stage words they could only read three lines
  /// of. No tooltip for the rest; the card just takes the height its words need.
  ///
  /// The header is the action: the compose icon, because that is what every tap
  /// does, beside the stance in the app's action color — and, where the host
  /// can really send, a quiet Send at the other end of that row. The button
  /// sits INSIDE the card's [InkWell] and consumes its own tap, so the card's
  /// stage-on-tap is untouched by it.
  ///
  /// The question Send asks is drawn UNDER the body rather than over it: the
  /// reader is confirming words, and words they cannot see while they answer
  /// are words they are not really confirming.
  Widget _card(int index, DraftOption option) {
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
                    const Icon(
                      Icons.edit_outlined,
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
                    if (widget.onSend != null)
                      TextButton.icon(
                        key: QuickReplyBar.sendKeyFor(index),
                        onPressed: () =>
                            setState(() => _confirmingSend = index),
                        icon: const Icon(Icons.send_outlined, size: 14),
                        label: const Text('Send'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: BondSpacing.s8,
                          ),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                if (_confirmingSend == index) _sendConfirmRow(index, option),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The ask-for-a-suggestion button, plus the × when there is something to
  /// close. Null when there is neither.
  ///
  /// Asking is offered only where there is nothing to suggest yet — that is
  /// what makes a dismissal reversible: the × takes the cards away, and this
  /// button is how they come back. The composer's Regenerate is where a
  /// DIFFERENT pair comes from.
  Widget? _replyRow() {
    final suggest = widget.onSuggest;
    final canDismiss = widget.options.isNotEmpty && widget.onDismiss != null;
    final canSuggest = suggest != null && widget.options.isEmpty;
    if (!canSuggest && !canDismiss) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A Wrap where a Spacer used to be: a labelled button does not always
        // fit beside a thread read in the side panel, and a second line beats
        // a clipped one. It still pushes the × to the right.
        Expanded(
          child: Wrap(
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canSuggest)
                TextButton.icon(
                  onPressed: widget.suggesting ? null : suggest,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(
                    widget.suggesting ? 'Drafting…' : 'Suggest a reply',
                  ),
                ),
            ],
          ),
        ),
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
