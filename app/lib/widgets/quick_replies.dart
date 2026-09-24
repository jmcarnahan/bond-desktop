import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../providers/draft_provider.dart' show PendingSend;
import '../services/llm/draft_task.dart' show DraftOption;
import '../theme/tokens.dart';
import 'composer.dart' show Composer;
import 'linked_text.dart' show LinkRun;

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
/// A tap ASKS. Where the host can really send, tapping a card puts an inline
/// question on it — *Send this reply?* Send · Edit first · Cancel — and
/// nothing happens until one of the three is answered: a reply that is already
/// right should not need a trip through the box to go, and a card that sent on
/// a single tap is not what text on screen promises. Where the host cannot
/// send there is nothing to confirm, so a tap stages the words in the docked
/// composer outright, which is the only thing it could have meant.
class QuickReplyBar extends StatefulWidget {
  /// Zero, one or two. Zero leaves the ask-for-a-suggestion button alone, or
  /// nothing at all where there is nothing to ask.
  final List<DraftOption> options;

  /// Whether this build holds a real send grant. Nothing in this widget reads
  /// it any more — what a tap does is decided by [onSend] alone — and it stays
  /// on the constructor only because every host still passes it. Dropping it
  /// is a follow-up, not a fact about this bar.
  final bool armed;

  /// The reader wants these words in the box. What that means is the host's
  /// decision, not this widget's — it is the *Edit first* answer where the
  /// host can send, and the tap itself where it cannot.
  final void Function(DraftOption option) onPick;

  /// Sends a card's reply as it stands, after the card's own confirm. Null
  /// means a tap has nothing to ask about and stages at once — a host without
  /// a real send grant offers nothing that only looks like a send.
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

  /// The options of the draft being written this moment, growing as they
  /// arrive. Drawn only where there are no STORED options yet: a real pair the
  /// reader can act on always outranks a preview of one.
  final List<({String stance, String body})> streamingOptions;

  /// Where the real action is, when it is not a reply: the first anchored link
  /// in the message's own body — the words the sender wrote over it, and the
  /// address behind them (`DraftState.openIn`).
  ///
  /// Drawn IN PLACE OF **Suggest a reply**, and only where that button is not
  /// offered: [onSuggest] null with no options in hand is a host saying a reply
  /// would be wrong here, which for an automated notification is true and
  /// unhelpful on its own. The notification's point is somewhere else, and this is
  /// the one thing in the body that says where — so the row that offered a reply
  /// nobody wanted offers the thing the reader actually came for.
  ///
  /// Null is the whole of the off switch, and it is the normal case: a thread that
  /// wants a reply wants the reply.
  final LinkRun? openIn;

  /// Where an [openIn] press goes. The app's ONE link seam — the same
  /// `void Function(String url)` a transcript's links are launched through — so a
  /// button on this row and a tap on the same words in the body open the same
  /// address by the same route. Null hides the button, on `LinkedText.onOpenLink`'s
  /// rule: a host with nowhere to send a press must not draw one.
  final void Function(String url)? onOpenLink;

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
    this.streamingOptions = const [],
    this.openIn,
    this.onOpenLink,
  });

  /// The three answers to the question a card's tap asks. Keyed by INDEX
  /// rather than by stance, because two suggestions can share a stance and a
  /// test that tapped the wrong one would still pass.
  static Key confirmSendKeyFor(int index) =>
      Key('quick-reply-confirm-send-$index');

  /// The middle answer: put the words in the box instead of sending them.
  static Key editKeyFor(int index) => Key('quick-reply-edit-$index');

  static Key cancelSendKeyFor(int index) =>
      Key('quick-reply-cancel-send-$index');

  /// One card of a draft still being written, by its position.
  static Key streamingKeyFor(int index) => Key('quick-reply-streaming-$index');

  /// The **Open in …** button. One per bar, so a plain key rather than a
  /// factory.
  static const Key openInKey = Key('quick-reply-open-in');

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

  /// How much of an anchor's words the **Open in …** button shows. A body
  /// anchor may run to a sentence (`bodyMaxLabelChars` is 140) and this is a
  /// BUTTON on a row beside a ×; past this the words are clipped with an
  /// ellipsis and the whole of them goes in the tooltip.
  static const int _openLabelCap = 40;

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
    // And when the send itself went away — a grant that dropped a rung under
    // the poll's re-read — the question has no answer left. A Send button that
    // outlived its callback would throw on the tap.
    if (widget.onSend == null) _confirmingSend = null;
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
    // A pair being written, and none stored yet: the cards grow in place of
    // the ones that are coming. Below the stored branch, never instead of it —
    // a real suggestion outranks a preview of one.
    if (widget.options.isEmpty && widget.streamingOptions.isNotEmpty) {
      return _tile(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: BondSpacing.s8,
              runSpacing: BondSpacing.s8,
              children: [
                for (final (i, option) in widget.streamingOptions.indexed)
                  _streamingCard(i, option),
              ],
            ),
            const SizedBox(height: BondSpacing.s4),
            ?_replyRow(),
          ],
        ),
      );
    }
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
                  : 'Tap a reply to send it — you can edit it first.',
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

  /// The question a card's tap asks, and all three answers — in the card,
  /// under the words it is about. Quiet buttons, like the ×'s: the loud thing
  /// on this card is the reply itself.
  ///
  /// A Wrap rather than a Row: three labelled buttons and the question do not
  /// fit across a 320-wide card, and a second line beats shrinking *Edit
  /// first* to something the reader has to guess at.
  Widget _sendConfirmRow(int index, DraftOption option) {
    return Wrap(
      spacing: BondSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Send this reply?', style: BondType.caption),
        _quietButton(
          'Send',
          () {
            setState(() => _confirmingSend = null);
            widget.onSend!(option);
          },
          key: QuickReplyBar.confirmSendKeyFor(index),
        ),
        _quietButton(
          'Edit first',
          () {
            setState(() => _confirmingSend = null);
            widget.onPick(option);
          },
          key: QuickReplyBar.editKeyFor(index),
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

  /// One suggestion, whole: a tap acts on the ENTIRE reply, so the entire
  /// reply is shown — nobody should send or stage words they could only read
  /// three lines of. No tooltip for the rest; the card just takes the height
  /// its words need.
  ///
  /// The header icon says what a tap leads to: a send glyph where the host can
  /// really send, a compose glyph where all a tap can do is stage. There is no
  /// separate button — the card IS the way in, and a second control on it was
  /// how a tap and a send came to mean different things on the same words.
  ///
  /// Where the question a tap asks is drawn, and why, is [_cardBody]'s.
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
          onTap: () {
            // Nothing to confirm where nothing can be sent: the only thing a
            // tap could mean there is "put these words in the box".
            if (widget.onSend == null) {
              widget.onPick(option);
              return;
            }
            setState(() => _confirmingSend = index);
          },
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.primaryTint,
          child: _cardBody(
            icon: widget.onSend != null
                ? Icons.send_outlined
                : Icons.edit_outlined,
            stance: option.stance,
            body: option.body,
            // Both halves, on purpose: the row is only ever drawn over a
            // callback it can call.
            footer: _confirmingSend == index && widget.onSend != null
                ? _sendConfirmRow(index, option)
                : null,
          ),
        ),
      ),
    );
  }

  /// What a card LOOKS like: the bordered tile, the stance under its glyph,
  /// and the reply under that.
  ///
  /// Shared by the two kinds of card this bar draws, because they differ in
  /// exactly two ways — whether there is anything to press, and whether the
  /// words have finished arriving — and neither is a reason for a second copy
  /// of the layout. [footer] is the question a tap asks, drawn UNDER the body
  /// rather than over it: a reader confirming words they cannot see is not
  /// really confirming them.
  Widget _cardBody({
    required IconData icon,
    required String stance,
    required String body,
    Widget? footer,
    Key? key,
  }) {
    return Container(
      key: key,
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
              Icon(icon, size: 14, color: BondColors.primary),
              const SizedBox(width: BondSpacing.s4),
              Expanded(
                child: Text(
                  stance,
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
            body,
            style: BondType.caption.copyWith(
              color:
                  BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
            ),
          ),
          ?footer,
        ],
      ),
    );
  }

  /// A card of words the model has not finished writing: the [_card] look with
  /// nothing to press.
  ///
  /// No [InkWell], no tap, no caption offering to send. Half a reply is not a
  /// reply, and a card that could be sent before its last clause arrived would
  /// be the one place in this app where machine-written text goes out without
  /// anybody having read all of it.
  Widget _streamingCard(int index, ({String stance, String body}) option) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _cardWidth),
      child: _cardBody(
        key: QuickReplyBar.streamingKeyFor(index),
        icon: Icons.auto_awesome,
        stance: option.stance,
        // The block cursor is the whole of the "still being written" signal.
        body: '${option.body}▍',
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
  /// [openIn] and [onOpenLink] add the one alternative to asking: a message no
  /// reply is offered for, whose body says where the action really is, offers
  /// THAT instead. It takes the Suggest button's place rather than sitting beside
  /// it — the two are answers to the same question, and a row holding both would
  /// be offering a reply this host already declined to offer.
  Widget? _replyRow() {
    final suggest = widget.onSuggest;
    final canDismiss = widget.options.isNotEmpty && widget.onDismiss != null;
    final canSuggest = suggest != null && widget.options.isEmpty;
    // Both halves of the seam, and no options: the button is only ever drawn
    // over a callback it can call, and a bar already holding suggestions is not
    // a bar with nothing to offer.
    final open = canSuggest || widget.options.isNotEmpty ? null : widget.openIn;
    final openLink = widget.onOpenLink;
    final canOpen = open != null && openLink != null;
    if (!canSuggest && !canDismiss && !canOpen) return null;
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
              if (canOpen) _openInButton(open, openLink),
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

  /// The way out to wherever this notification is really about.
  ///
  /// The button wears the SENDER'S OWN WORDS — *View comment*, *Approve request*
  /// — rather than a sentence this app made up. Nothing here knows which platform
  /// it is talking to, and guessing one from a hostname would put a wrong product
  /// name on a button; the anchor text is the one description of the destination
  /// that is certainly right, and the outward arrow says it leaves the app.
  ///
  /// The tooltip is the HOST and not the whole address. A press leaves for another
  /// program and a reader is owed the chance to see where before they press, but a
  /// tracking address runs to hundreds of characters and a tooltip that long is
  /// unreadable — the host is the part of it that answers the question.
  Widget _openInButton(LinkRun open, void Function(String url) onOpenLink) {
    final words = open.label.trim();
    final label = words.length > _openLabelCap
        ? '${words.substring(0, _openLabelCap)}…'
        : words;
    final host = open.target.host;
    return Tooltip(
      message: host.isEmpty ? open.target.toString() : 'Opens $host',
      child: TextButton.icon(
        key: QuickReplyBar.openInKey,
        onPressed: () => onOpenLink(open.target.toString()),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
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

/// What the host says about the quick reply open on one row: the words to start
/// from, whether a send of them is already on its way, and whatever the last
/// attempt had to say.
///
/// A record of the host's own draft state rather than three props on the pane,
/// because all three are answers to one question — *what is the quick reply on
/// this row doing* — and the pane asks it once, for the one row that has a box
/// open.
class QuickReply {
  /// Prefills the box. The stored draft where there is one, so `r` on a thread
  /// the model already answered opens those words rather than an empty box the
  /// reader would have to go to the thread to fill.
  final String body;

  /// A send is in flight. The box stays up and inert: the reply has not landed
  /// yet, and a box that closed on the press would leave the reader guessing.
  final bool sending;

  /// What stopped the last send, from the host's own draft state. Null is the
  /// normal case.
  final String? error;

  /// What the last send wants said though it worked — the copy rung's "the
  /// people you added are not carried". Drawn muted where [error] is red, and
  /// it keeps the box up the same way, because the box is the only place left
  /// on screen to say it.
  final String? notice;

  /// How many people the owner has STAGED onto this reply's Cc — in the thread
  /// composer, where the chips naming them live. The draft is shared, so a
  /// send from this box carries them too, and a box that drew no sign of that
  /// would Cc people it never showed. The count is the box's honest minimum:
  /// the names are one press away, in the thread.
  final int addedRecipients;

  /// Those people ride out as @mentions rather than Cc — a chat reply, where
  /// adding somebody means naming them to the chat's own members.
  final bool mentionsNotCc;

  const QuickReply({
    this.body = '',
    this.sending = false,
    this.error,
    this.notice,
    this.addedRecipients = 0,
    this.mentionsNotCc = false,
  });
}

/// One reply, written without leaving the list (entry 12f).
///
/// It is the composer's job in a fifth of its space: a box, a Send, and a way
/// out. Everything the docked composer does that this does not — suggestions,
/// Regenerate, Improve, recipients, attachments, the draft's provenance — is
/// in the thread, one press away, and a reader who needs any of it is not
/// answering in one line anyway.
///
/// It draws OUTSIDE the row's card, like the Reopen button and the label
/// picker, which is what keeps `ConversationRow` the same row in every list.
///
/// ⌘Enter sends, Escape closes. The two are bound here rather than in the
/// screen's one triage map on purpose: both keys mean something else everywhere
/// else in that map (Escape returns the focus to the list, and Enter opens a
/// row), and a binding closer to the cursor is how a key means one thing in a
/// box and another outside it. The single letters are already dead while the
/// cursor is in an `EditableText`, so `e` typed in here is a letter.
///
/// **Snippets and templates are deferred.** Entry 12f asks for saved phrases
/// inserted with `/` — "Thanks, got it", `Adding <person>` — and they need a
/// vocabulary table of their own to live in, with the editing surface that
/// implies. Nothing here is in their way: a snippet ends up as text in this
/// field, whatever puts it there.
class QuickReplyBox extends StatefulWidget {
  /// Who the reply answers, for the line over the box. Empty draws no line
  /// rather than a line naming nobody.
  final String who;

  /// The host's state for this row — see [QuickReply].
  final QuickReply reply;

  /// Sends what is in the box. The host owns the path: this widget knows
  /// nothing about drafts, grants or the network, exactly as the composer's own
  /// Send does not.
  final void Function(String body) onSend;

  /// Closes the box — Escape, Cancel, or a send the host decided ends it.
  final VoidCallback onClose;

  const QuickReplyBox({
    super.key,
    required this.reply,
    required this.onSend,
    required this.onClose,
    this.who = '',
  });

  /// One box on screen at a time — the host opens it for a single row — so
  /// plain keys rather than per-row factories.
  static const Key fieldKey = Key('quick-reply-field');
  static const Key sendKey = Key('quick-reply-send');
  static const Key cancelKey = Key('quick-reply-cancel');

  /// The line over the field, when there is anything to say on it.
  static const Key scopeKey = Key('quick-reply-scope');

  /// The muted line under the field, for a [QuickReply.notice].
  static const Key noticeKey = Key('quick-reply-notice');

  @override
  State<QuickReplyBox> createState() => _QuickReplyBoxState();
}

class _QuickReplyBoxState extends State<QuickReplyBox> {
  late final TextEditingController _body =
      TextEditingController(text: widget.reply.body);

  /// Its own node so ⌘Enter can be heard around the field rather than in it.
  final FocusNode _focus = FocusNode(debugLabel: 'quick-reply');

  @override
  void initState() {
    super.initState();
    // Taken, not offered: `autofocus` yields when anything else holds focus,
    // and something always does here — the box opens under `r`, pressed on
    // the list's own node. The reader asked to type; the cursor must follow.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant QuickReplyBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A prefill that arrives LATE — the host's draft read landing a frame after
    // the box opened — fills an untouched box. Never over words the reader has
    // typed: the box is theirs the moment they touch it, and a suggestion
    // replacing a half-written reply is the one thing this must not do.
    final prefill = widget.reply.body;
    if (prefill != oldWidget.reply.body && _body.text == oldWidget.reply.body) {
      _body.text = prefill;
    }
  }

  @override
  void dispose() {
    _body.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    if (widget.reply.sending) return;
    final text = _body.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
  }

  /// Who a send from this box reaches, in the composer's own words.
  ///
  /// The Cc half is [QuickReply.addedRecipients]'s point: people staged in the
  /// thread composer ride the shared draft out of THIS box too, and the line
  /// is what keeps that from happening silently. Empty when there is nothing
  /// to say — no name and nobody added — rather than a line naming nobody.
  String get _scopeLine {
    final who = widget.who;
    final count = widget.reply.addedRecipients;
    if (count == 0) return who.isEmpty ? '' : 'Reply to $who';
    final base = who.isEmpty ? 'Reply to the sender' : 'Reply to $who';
    final people = count == 1 ? '1 person' : '$count people';
    if (widget.reply.mentionsNotCc) return '$base, mentioning $people';
    return '$base, plus $people in Cc';
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.reply.error;
    final notice = widget.reply.notice;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        // Control as well, for a keyboard that has no Command: the app runs on
        // one platform today and this costs a line.
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Container(
        padding: const EdgeInsets.all(BondSpacing.s12),
        decoration: BoxDecoration(
          color: BondColors.surface,
          borderRadius: BondRadii.smAll,
          border: Border.all(color: BondColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_scopeLine.isNotEmpty)
              Text(
                _scopeLine,
                key: QuickReplyBox.scopeKey,
                style: BondType.caption,
              ),
            TextField(
              key: QuickReplyBox.fieldKey,
              controller: _body,
              focusNode: _focus,
              // The box is what `r` opened, so the cursor starts in it: a box
              // that opened beside the keyboard rather than under it would cost
              // the reader a reach for the mouse to use a keyboard shortcut.
              autofocus: true,
              enabled: !widget.reply.sending,
              minLines: 1,
              maxLines: 6,
              style: BondType.body,
              decoration: const InputDecoration(
                hintText: 'Reply…',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: BondSpacing.s4),
              Text(
                error,
                style: BondType.caption.copyWith(color: BondColors.error),
              ),
            ],
            if (notice != null) ...[
              const SizedBox(height: BondSpacing.s4),
              Text(
                notice,
                key: QuickReplyBox.noticeKey,
                style: BondType.caption,
              ),
            ],
            const SizedBox(height: BondSpacing.s4),
            // Both buttons read the field, so both rebuild with it — the
            // composer's own rule: emptying the box has to disable Send.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _body,
              builder: (context, value, _) => Row(
                children: [
                  Text(
                    widget.reply.sending ? 'Sending…' : '⌘Enter sends',
                    style: BondType.caption,
                  ),
                  const Spacer(),
                  TextButton(
                    key: QuickReplyBox.cancelKey,
                    onPressed: widget.onClose,
                    style: _quietButton,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: BondSpacing.s4),
                  TextButton(
                    key: QuickReplyBox.sendKey,
                    onPressed:
                        value.text.trim().isEmpty || widget.reply.sending
                            ? null
                            : _send,
                    style: _quietButton,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The list pane's own button shape, so a box under a row reads as part of
  /// the row rather than as a screen that opened inside one.
  static final ButtonStyle _quietButton = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
    minimumSize: const Size(0, 28),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: BondType.caption,
  );
}
