import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, KeyDownEvent;

import '../models/label_models.dart';
import '../theme/tokens.dart';
import 'label_chip.dart';

/// Everything that can be done TO a thread, in one row under its header, and
/// the thread's own words under that.
///
/// It replaces three places that each held some of it — the header's Mark
/// done, the ⋯ menu's filing items and the Dismiss…/Label… strip under the
/// ask — which made the reader learn three homes for one kind of decision,
/// and spelled the same act two ways ("Dismiss" was Mark done with a label).
/// Here the verb is Mark done, and pressing it opens its two choices — plain,
/// or with a label — in place under the bar, each saying what it does.
///
/// The one other button with a word is the owner's Needs You answer —
/// "Remove from Needs You" or "Add to Needs You", whichever the thread's place
/// calls for — because what it does reaches past this thread, and an icon
/// would not say so. Its word gives way first when the row runs short.
///
/// The rest are icons, each with a tooltip that names the act and, where one
/// exists, the key that does it from the list, because the panel shares its
/// width with a split and a row of words would be clipped long before a row
/// of icons is. What stays in the header's ⋯ is what is about the SENDER
/// rather than this thread.
///
/// Every callback is optional and a null one draws no button, so a host that
/// wires nothing draws nothing.
class ThreadActionBar extends StatefulWidget {
  /// Whether the thread is closed. Mark done then reads Reopen.
  final bool done;

  /// Whether the thread is filed in Later. Later then reads Keep in inbox.
  final bool inLater;

  final VoidCallback? onDone;
  final VoidCallback? onDoneWithReason;
  final VoidCallback? onReopen;
  final VoidCallback? onLater;
  final VoidCallback? onKeepInInbox;

  /// Whether the thread is in Needs You at the owner's slider (the rail's
  /// `isNeedsYou`). It picks which of the two Needs You buttons draws:
  /// "Remove from Needs You" when it is, "Add to Needs You" when it is not.
  final bool inNeedsYou;

  /// The owner's answer about this thread, kept as a label the decision
  /// model's every later verdict inherits. Remove draws only when
  /// [inNeedsYou]; Add only when it is not AND the thread is neither done
  /// nor in Later — Needs You reads neither, so an Add there would change
  /// nothing the reader could see.
  final VoidCallback? onRemoveFromNeedsYou;
  final VoidCallback? onAddToNeedsYou;

  final VoidCallback? onStoryline;
  final VoidCallback? onContext;

  /// How many context files this thread reads — the count rides the tooltip,
  /// and a small badge when there are any.
  final int contextLinked;

  final VoidCallback? onCompose;

  /// The thread's labels, most-used first (the store's order).
  final List<Label> labels;
  final VoidCallback? onAddLabel;
  final void Function(Label label)? onRemoveLabel;
  final void Function(Label label)? onFindLabel;

  const ThreadActionBar({
    super.key,
    this.done = false,
    this.inLater = false,
    this.onDone,
    this.onDoneWithReason,
    this.onReopen,
    this.onLater,
    this.onKeepInInbox,
    this.inNeedsYou = false,
    this.onRemoveFromNeedsYou,
    this.onAddToNeedsYou,
    this.onStoryline,
    this.onContext,
    this.contextLinked = 0,
    this.onCompose,
    this.labels = const [],
    this.onAddLabel,
    this.onRemoveLabel,
    this.onFindLabel,
  });

  static const Key doneKey = ValueKey('thread-action-done');
  static const Key doneChoicesKey = ValueKey('thread-action-done-choices');
  static const Key donePlainKey = ValueKey('thread-action-done-plain');
  static const Key doneWithReasonKey = ValueKey('thread-action-done-reason');
  static const Key reopenKey = ValueKey('thread-action-reopen');
  static const Key laterKey = ValueKey('thread-action-later');
  static const Key keepKey = ValueKey('thread-action-keep');
  static const Key needsYouRemoveKey =
      ValueKey('thread-action-needs-you-remove');
  static const Key needsYouAddKey = ValueKey('thread-action-needs-you-add');
  static const Key storylineKey = ValueKey('thread-action-storyline');
  static const Key contextKey = ValueKey('thread-context');
  static const Key composeKey = ValueKey('thread-compose');
  static const Key addLabelKey = ValueKey('thread-label');
  static const Key labelRowKey = ValueKey('thread-action-labels');

  static Key removeLabelKey(String id) => ValueKey('thread-label-remove-$id');

  /// The bar's own chip keys, apart from [labelChipKey]: the selected
  /// thread's rail row draws that same label with that key, and one key on
  /// two widgets on one screen makes a test's `find.byKey` match twice.
  static Key labelKeyFor(String id) => ValueKey('thread-label-chip-$id');

  @override
  State<ThreadActionBar> createState() => _ThreadActionBarState();
}

class _ThreadActionBarState extends State<ThreadActionBar> {
  /// Whether Mark done's two choices are open under the bar.
  bool _choosing = false;

  /// The choices' own node, taken by hand as they open. `autofocus` is not
  /// enough: it only applies when nothing in the scope holds focus, and during
  /// triage the list or the side panel always does — so Escape went past the
  /// choices to the screen, which closed the whole side panel instead.
  ///
  /// Nothing hands it BACK by hand. Closing unmounts the [Focus] that holds
  /// it, and a detached focus falls to the scope's previously focused child —
  /// the triage list, the side panel, the reply box, whichever it was, the
  /// list and the bar sharing one scope. That covers Escape, a pick, `e`
  /// advancing into a new panel and the bar's disposal alike.
  final FocusNode _choicesFocus = FocusNode(debugLabel: 'Mark done choices');

  /// A thread that closed or reopened under open choices — `e` pressed while
  /// they were up, or a Reopen — starts from a shut bar. Hidden-but-set would
  /// bring the choices back unasked the next time the thread reopened. The
  /// same for a host that stops offering the with-label way while they are
  /// up: Mark done acts directly then, so nothing else could close them.
  @override
  void didUpdateWidget(ThreadActionBar old) {
    super.didUpdateWidget(old);
    if (old.done != widget.done || widget.onDoneWithReason == null) {
      _choosing = false;
    }
  }

  @override
  void dispose() {
    _choicesFocus.dispose();
    super.dispose();
  }

  void _open() {
    setState(() => _choosing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _choosing) _choicesFocus.requestFocus();
    });
  }

  void _close() {
    if (_choosing) setState(() => _choosing = false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: _buildIn);
  }

  Widget _buildIn(BuildContext context, BoxConstraints box) {
    final hasDone = widget.done
        ? widget.onReopen != null
        : widget.onDone != null;
    // The chevron is Mark done's alone: Reopen acts, it never opens choices.
    final chevron = !widget.done && widget.onDoneWithReason != null;
    // What the button's word actually costs, at this font and text scale —
    // measured rather than guessed, because a guess is exactly what a larger
    // system text size breaks, and measured as the word it WILL show: Reopen
    // is a different width from Mark done. Measured in the style the Text
    // renders in, or an inherited letter spacing makes the sum come out
    // short — and the button's Material resets the ambient style to the
    // theme's body text, so that, under the button's own, is what is
    // measured. Below the width the whole row needs, the button gives up its
    // word for its icon (the tooltip and the screen reader still name it),
    // which is what lets the row fit a side panel at any text size.
    final word = TextPainter(
      text: TextSpan(
        text: widget.done ? 'Reopen' : 'Mark done',
        style: (Theme.of(context).textTheme.bodyMedium ??
                DefaultTextStyle.of(context).style)
            .merge(_doneStyle),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final wordWidth = word.width;
    // Each line grows with the text size rather than clipping its glyphs: the
    // button's padding and border around one line of its word.
    final lineHeight = word.height + 14 > 34 ? word.height + 14 : 34.0;
    word.dispose();
    double doneWidth(double? w) => hasDone ? _doneWidth(w, chevron) : 0;
    // The Needs You button is labelled too, and measured the same way. Its
    // word goes first when room runs short, Mark done's only after it: the
    // bar's one decision keeps its word longest.
    final needsYou = _needsYouButton;
    double? needsYouWord;
    if (needsYou != null) {
      final painter = TextPainter(
        text: TextSpan(
          text: needsYou.word,
          style: (Theme.of(context).textTheme.bodyMedium ??
                  DefaultTextStyle.of(context).style)
              .merge(_doneStyle),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      needsYouWord = painter.width;
      painter.dispose();
    }
    double needsYouWidth(double? w) =>
        needsYou == null ? 0 : BondSpacing.s4 + _doneWidth(w, false);
    final icons = _iconCount();
    final showLabels = widget.onAddLabel != null || widget.labels.isNotEmpty;
    final inner = box.maxWidth - 2 * BondSpacing.s12;
    final tail = showLabels ? _ruleWidth + _iconWidth : 0.0;
    final rest = icons * _iconWidth + tail;
    final needsYouCompact =
        doneWidth(wordWidth) + needsYouWidth(needsYouWord) + rest > inner;
    final compact = doneWidth(wordWidth) + needsYouWidth(null) + rest > inner;
    final verbs = doneWidth(compact ? null : wordWidth) +
        needsYouWidth(needsYouCompact ? null : needsYouWord) +
        icons * _iconWidth;
    // Still no room for the rule and the add button beside even the compact
    // verbs: the whole label strip — button and chips — takes the line below.
    final labelsBelow = showLabels && verbs + tail > inner;

    final actions = <Widget>[
      // Labelled, both of them, and in the same place: the one decision the
      // bar exists for reads as a word, and a closed thread is reopened from
      // exactly where it was closed.
      if (widget.done && widget.onReopen != null)
        _DoneButton(
          buttonKey: ThreadActionBar.reopenKey,
          name: 'Reopen',
          label: compact ? null : 'Reopen',
          icon: Icons.undo,
          tooltip: 'Reopen — back to where it stood',
          onDone: widget.onReopen!,
        )
      else if (!widget.done && widget.onDone != null)
        _DoneButton(
          buttonKey: ThreadActionBar.doneKey,
          name: 'Mark done',
          label: compact ? null : 'Mark done',
          icon: Icons.check,
          tooltip: 'Mark done  ·  e',
          shortcut: 'e',
          // With a second way to finish, the press opens the two choices
          // under the bar rather than acting — no dropdown, and nothing
          // happens that the reader has not read. With only one way it
          // simply does it. `e` is the fast path either way.
          onDone: widget.onDoneWithReason == null
              ? widget.onDone!
              : () => _choosing ? _close() : _open(),
          open: chevron ? _choosing : null,
        ),
      if (widget.inLater && widget.onKeepInInbox != null)
        _ActionIcon(
          key: ThreadActionBar.keepKey,
          icon: Icons.move_to_inbox_outlined,
          tooltip: 'Keep in inbox',
          onTap: widget.onKeepInInbox!,
        )
      else if (_showLater)
        _ActionIcon(
          key: ThreadActionBar.laterKey,
          icon: Icons.schedule,
          tooltip: 'Send to Later',
          shortcut: 's',
          onTap: widget.onLater!,
        ),
      if (needsYou != null)
        _DoneButton(
          buttonKey: needsYou.key,
          name: needsYou.word,
          label: needsYouCompact ? null : needsYou.word,
          icon: needsYou.icon,
          tooltip: needsYou.tooltip,
          onDone: needsYou.onTap,
        ),
      if (widget.onStoryline != null)
        _ActionIcon(
          key: ThreadActionBar.storylineKey,
          icon: Icons.auto_stories_outlined,
          tooltip: 'Add to storyline',
          onTap: widget.onStoryline!,
        ),
      if (widget.onContext != null)
        _ActionIcon(
          key: ThreadActionBar.contextKey,
          icon: Icons.folder_open_outlined,
          tooltip: widget.contextLinked > 0
              ? 'Context · ${widget.contextLinked}'
              : 'Add context',
          badge: widget.contextLinked > 0 ? '${widget.contextLinked}' : null,
          onTap: widget.onContext!,
        ),
      if (widget.onCompose != null)
        _ActionIcon(
          key: ThreadActionBar.composeKey,
          icon: Icons.edit_outlined,
          tooltip: 'New message to these people',
          onTap: widget.onCompose!,
        ),
    ];

    if (actions.isEmpty && !showLabels) return const SizedBox.shrink();

    // One row where it fits: the verbs, a rule, then the thread's labels led
    // by the button that adds one. The chips move to a line of their own only
    // when there ARE chips and the row cannot show the widest one whole after
    // the add button — a side panel leaves ~80px after the verbs, which clips
    // even one chip's ✕ — so an unlabelled thread never grows a line holding
    // nothing but "Add label".
    final room = inner -
        verbs -
        _ruleWidth -
        (widget.onAddLabel != null ? _iconWidth : 0);
    final inline =
        !labelsBelow && (widget.labels.isEmpty || room >= _pillMaxWidth);
    final verbRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: BondSpacing.s4),
          actions[i],
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s12,
        BondSpacing.s8,
        BondSpacing.s12,
        BondSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: lineHeight,
            child: Row(
              children: [
                // The last resort, narrower than any panel the app
                // draws: the verbs scroll rather than overflow.
                if (verbs > inner)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: verbRow,
                    ),
                  )
                else
                  verbRow,
                // Only when something actually follows it: chips inline, or
                // the add button standing in for them — a chips-only bar
                // whose chips moved below would end its row with a rule
                // dividing the verbs from nothing.
                if (actions.isNotEmpty &&
                    showLabels &&
                    !labelsBelow &&
                    (inline || widget.onAddLabel != null))
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s8,
                    ),
                    color: BondColors.border,
                  ),
                if (showLabels && !labelsBelow)
                  if (inline)
                    Expanded(child: _labels())
                  else if (widget.onAddLabel != null)
                    _addLabelIcon(),
              ],
            ),
          ),
          if (labelsBelow)
            SizedBox(
              key: ThreadActionBar.labelRowKey,
              height: lineHeight,
              child: Row(
                children: [
                  if (widget.onAddLabel != null) _addLabelIcon(),
                  if (widget.labels.isNotEmpty) ...[
                    const SizedBox(width: BondSpacing.s4),
                    Expanded(child: _chipList()),
                  ],
                ],
              ),
            )
          else if (!inline)
            SizedBox(
              key: ThreadActionBar.labelRowKey,
              height: lineHeight,
              child: _chipList(),
            ),
          if (_choosing && !widget.done) _choices(),
        ],
      ),
    );
  }

  /// Letter spacing stated, so the measure above and the rendered word agree
  /// whatever the theme's ambient style carries.
  static final TextStyle _doneStyle = BondType.small.copyWith(
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );

  /// One icon button and the gap before it.
  static const double _iconWidth = 34 + BondSpacing.s4;

  /// The rule between the verbs and the labels, with its margins.
  static const double _ruleWidth = 1 + 2 * BondSpacing.s8;

  /// The widest a label pill draws: its name's cap, the padding either side
  /// of it, the ✕'s target and the border.
  static const double _pillMaxWidth =
      10 + _LabelPill.nameMaxWidth + 2 + _LabelPill.removeWidth + 2;

  /// Mark done's (or Reopen's) width with its word ([word] its measured
  /// width) or, null, as its icon alone: padding, icon, gap, word, the
  /// chevron when it opens choices, and 2px for the border and rounding.
  static double _doneWidth(double? word, bool chevron) =>
      2 * BondSpacing.s8 +
      16 +
      (word == null ? 0 : 4 + word) +
      (chevron ? 2 + 16 : 0) +
      2;

  /// Later is for a thread still being worked: filing a closed one in Later
  /// would move nothing anybody is looking at. (`s` still can.)
  bool get _showLater =>
      !widget.inLater && !widget.done && widget.onLater != null;

  /// The one Needs You button the bar draws, or null: Remove for a thread in
  /// Needs You, Add for one that is not and is still being worked (neither
  /// done nor in Later), and nothing whose callback is unwired.
  ({Key key, String word, IconData icon, String tooltip, VoidCallback onTap})?
      get _needsYouButton {
    final remove = widget.onRemoveFromNeedsYou;
    final add = widget.onAddToNeedsYou;
    if (widget.inNeedsYou) {
      if (remove == null) return null;
      return (
        key: ThreadActionBar.needsYouRemoveKey,
        word: 'Remove from Needs You',
        icon: Icons.notifications_off_outlined,
        tooltip: 'Remove from Needs You — and anything like it',
        onTap: remove,
      );
    }
    if (add == null || widget.done || widget.inLater) return null;
    return (
      key: ThreadActionBar.needsYouAddKey,
      word: 'Add to Needs You',
      icon: Icons.notification_add_outlined,
      tooltip: 'Add to Needs You',
      onTap: add,
    );
  }

  /// How many icon buttons the row draws — the same conditions as the list
  /// below them, so the measure and the row cannot disagree.
  int _iconCount() {
    var n = 0;
    if ((widget.inLater && widget.onKeepInInbox != null) || _showLater) n++;
    if (widget.onStoryline != null) n++;
    if (widget.onContext != null) n++;
    if (widget.onCompose != null) n++;
    return n;
  }

  /// The tallest the choices stand: a third of the window, never under 180.
  static double _choicesCap(BuildContext context) {
    final third = MediaQuery.sizeOf(context).height / 3;
    return third < 180 ? 180 : third;
  }

  /// Mark done's two choices, open under the bar: each says what it does in a
  /// sentence, because "Done" alone left the reader guessing whether it
  /// dropped the mail, filed it, or wrote a label called Done.
  Widget _choices() {
    void pick(VoidCallback? act) {
      _close();
      act?.call();
    }

    // Focused as it opens (see [_choicesFocus]), so Escape shuts it — the
    // picker strip's rule — and every other key falls through to the triage
    // map above, `e` and `z` included.
    return Focus(
      focusNode: _choicesFocus,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // A third of the window at most, scrolling past it: at a large text
      // size the two sentences stand tall, and the bar sits in the panel's
      // column above the transcript that must keep a height of its own.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _choicesCap(context)),
        child: SingleChildScrollView(child: _choicesPanel(pick)),
      ),
    );
  }

  Widget _choicesPanel(void Function(VoidCallback? act) pick) {
    return Container(
      key: ThreadActionBar.doneChoicesKey,
      margin: const EdgeInsets.only(top: BondSpacing.s8),
      padding: const EdgeInsets.all(BondSpacing.s8),
      decoration: BoxDecoration(
        color: BondColors.primary.withValues(alpha: 0.05),
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Choice(
              key: ThreadActionBar.donePlainKey,
              icon: Icons.check,
              title: 'Mark done',
              shortcut: 'e',
              detail: 'Off Needs You. Kept in the mailbox — nothing is '
                  'deleted, and a new message reopens it.',
              onTap: () => pick(widget.onDone),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            child: _Choice(
              key: ThreadActionBar.doneWithReasonKey,
              icon: Icons.label_outline,
              title: 'Mark done with a label',
              shortcut: '⇧E',
              detail: 'The same, and files it under a label — with an offer '
                  'to do the same for similar mail.',
              onTap: () => pick(widget.onDoneWithReason),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// The add-label button first, then the chips, scrolling sideways in
  /// whatever width the verbs leave — a thread filed under six words keeps
  /// its height, and the button never scrolls away because it leads. The
  /// button says "Add label" while there is nothing beside it, and shrinks to
  /// its icon once chips are there to say what it is for.
  Widget _labels() {
    // Measured, because the bar lives in a side panel as often as a pane: the
    // worded button needs ~170px, and in a narrower slot it gives way to its
    // icon rather than pushing the row off the edge. Under one icon's width
    // there is no button at all — `l` still opens the picker.
    return LayoutBuilder(
      builder: (context, box) => _labelsIn(box.maxWidth),
    );
  }

  Widget _labelsIn(double width) {
    if (width < 36) return const SizedBox.shrink();
    final worded = widget.labels.isEmpty && width >= 170;
    return Row(
      key: ThreadActionBar.labelRowKey,
      children: [
        if (widget.onAddLabel != null)
          worded
              // Flexible, with an ellipsis, so a larger text size shortens the
              // word rather than pushing the row past the edge.
              ? Flexible(
                  child: Tooltip(
                    message: 'Add a label  ·  l',
                    waitDuration: const Duration(milliseconds: 300),
                    child: TextButton.icon(
                      key: ThreadActionBar.addLabelKey,
                      onPressed: widget.onAddLabel,
                      icon: const Icon(Icons.label_outline, size: 16),
                      label: const Text(
                        'Add label',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: BondSpacing.s8,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: BondType.small,
                      ),
                    ),
                  ),
                )
              : _addLabelIcon(),
        if (widget.labels.isNotEmpty) ...[
          const SizedBox(width: BondSpacing.s4),
          Expanded(child: _chipList()),
        ],
      ],
    );
  }

  Widget _addLabelIcon() => _ActionIcon(
        key: ThreadActionBar.addLabelKey,
        icon: Icons.label_outline,
        tooltip: 'Add a label',
        shortcut: 'l',
        onTap: widget.onAddLabel!,
      );

  /// The thread's labels, one line that scrolls sideways.
  Widget _chipList() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: widget.labels.length,
      separatorBuilder: (_, _) => const SizedBox(width: BondSpacing.s4),
      itemBuilder: (_, i) => Center(
        child: _LabelPill(
          label: widget.labels[i],
          onTap: widget.onFindLabel == null
              ? null
              : () => widget.onFindLabel!(widget.labels[i]),
          onRemove: widget.onRemoveLabel == null
              ? null
              : () => widget.onRemoveLabel!(widget.labels[i]),
        ),
      ),
    );
  }
}

/// One square icon button that lights on hover and names itself in a tooltip.
/// A key read out as a hint. As typed, not upper-cased: `e` and `⇧E` are two
/// different keys here.
String? _shortcutHint(String? key) => key == null ? null : 'Shortcut: $key';

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final String? shortcut;
  final String? badge;
  final VoidCallback onTap;

  const _ActionIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.shortcut,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.transparent,
      borderRadius: BondRadii.smAll,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        hoverColor: BondColors.primary.withValues(alpha: 0.08),
        child: SizedBox(
          width: 34,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 18, color: BondColors.inkSecondary),
              if (badge != null)
                Positioned(
                  right: 3,
                  top: 3,
                  child: Text(
                    badge!,
                    style: BondType.caption.copyWith(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: BondColors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // The name said outright rather than left to the tooltip, which not every
    // screen reader speaks, and the tooltip kept out of the tree so the name
    // is not announced twice. The key rides as the hint. `excludeSemantics`
    // also keeps the badge's count out, which the name already carries.
    return Tooltip(
      message: shortcut == null ? tooltip : '$tooltip  ·  $shortcut',
      waitDuration: const Duration(milliseconds: 300),
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: tooltip,
        hint: _shortcutHint(shortcut),
        onTap: onTap,
        excludeSemantics: true,
        child: button,
      ),
    );
  }
}

/// Mark done (or Reopen): a labelled, bordered button — the one decision the
/// bar exists for reads as a word. When it opens choices rather than acting,
/// a chevron says so and turns while they are open.
class _DoneButton extends StatelessWidget {
  final Key buttonKey;

  /// What a screen reader calls it, word shown or not.
  final String name;

  /// The key that does it from the list, read out as the hint.
  final String? shortcut;

  /// The word. Null draws the icon alone — the narrow-row form, named by its
  /// tooltip and [name].
  final String? label;
  final IconData icon;
  final String tooltip;
  final VoidCallback onDone;

  /// Whether the choices it opens are showing. Null draws no chevron: the
  /// button acts rather than opens.
  final bool? open;

  const _DoneButton({
    required this.buttonKey,
    required this.name,
    this.shortcut,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onDone,
    this.open,
  });

  @override
  Widget build(BuildContext context) {
    final open = this.open;
    // A button by name even when it is only an icon; the word it draws is
    // excluded so a labelled one is not read as "Mark done, Mark done".
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      excludeFromSemantics: true,
      // And whether the choices it opens are showing — the chevron's state,
      // which a reader who cannot see the chevron still needs.
      child: Semantics(
        button: true,
        label: name,
        hint: _shortcutHint(shortcut),
        expanded: open,
        onTap: onDone,
        excludeSemantics: true,
        child: Material(
          color: open == true
              ? BondColors.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BondRadii.smAll,
            side: const BorderSide(color: BondColors.border),
          ),
          child: InkWell(
            key: buttonKey,
            onTap: onDone,
            borderRadius: BondRadii.smAll,
            hoverColor: BondColors.primary.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: BondSpacing.s8,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: BondColors.primary),
                  if (label != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      label!,
                      style: _ThreadActionBarState._doneStyle.copyWith(
                        color: BondColors.primary,
                      ),
                    ),
                  ],
                  if (open != null) ...[
                    const SizedBox(width: 2),
                    Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: BondColors.primary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of Mark done's choices: a highlighted target with its name, its key,
/// and what it does.
class _Choice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String shortcut;
  final String detail;
  final VoidCallback onTap;

  const _Choice({
    super.key,
    required this.icon,
    required this.title,
    required this.shortcut,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // One button to a screen reader, its title and sentence as the name and
    // its key as the hint — not a focusable run of text with a bare "⇧E" in
    // the middle of it.
    return Semantics(
      button: true,
      label: '$title. $detail',
      hint: _shortcutHint(shortcut),
      onTap: onTap,
      excludeSemantics: true,
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    // The key's width is its own, up to a cap that grows with the text size:
    // a flex split gave it half the card whether it used it or not, which is
    // what wrapped "Mark done with a label" in a card with room to spare.
    // Past the cap it ellipsizes rather than overflowing the card's edge.
    final keyCap = MediaQuery.textScalerOf(context).scale(32.0);
    return Material(
      color: BondColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BondRadii.smAll,
        side: BorderSide(color: BondColors.primary.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        hoverColor: BondColors.primary.withValues(alpha: 0.10),
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: BondColors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: BondType.small.copyWith(
                        fontWeight: FontWeight.w600,
                        color: BondColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: keyCap),
                    child: Text(
                      shortcut,
                      style: BondType.caption,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(detail, style: BondType.caption),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label as a pill: its tone, its name (which searches for it), and a ✕.
class _LabelPill extends StatelessWidget {
  final Label label;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _LabelPill({required this.label, this.onTap, this.onRemove});

  /// The name's cap, past which it ellipsizes.
  static const double nameMaxWidth = 160;

  /// The ✕'s target: its icon and the padding around it. Wider than the
  /// glyph, because a miss on a destructive target lands on the name.
  static const double removeWidth = 4 + 14 + 8;

  @override
  Widget build(BuildContext context) {
    final colors = bondToneColors[labelToneOf(label.tone)]!;
    final tip = onTap == null
        ? label.name
        : 'Filter Needs You by ${label.name}';
    final name = Text(
      label.name,
      style: BondType.label.copyWith(
        letterSpacing: 0,
        color: colors.foreground,
        fontSize: 12,
      ),
      overflow: TextOverflow.ellipsis,
    );
    return Container(
      key: ThreadActionBar.labelKeyFor(label.id),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BondRadii.fullAll,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            // What it does, exactly: Find narrows the LIVE lists, so a thread
            // closed under this label is on the Done shelf, not in what this
            // opens.
            message: tip,
            waitDuration: const Duration(milliseconds: 300),
            excludeFromSemantics: true,
            // A button when it does something, so a screen reader offers it
            // as one rather than as a word to read past — and said once: the
            // drawn word is excluded, or a pill that does nothing was read as
            // its tooltip and then again as itself. A node of its own
            // (`container`), or an inert pill's name would fold into its
            // neighbour's instead of standing as the word it is.
            child: Semantics(
              container: true,
              button: onTap != null,
              label: tip,
              onTap: onTap,
              excludeSemantics: true,
              child: InkWell(
                onTap: onTap,
                borderRadius: BondRadii.fullAll,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 10,
                    right: onRemove == null ? 10 : 2,
                    top: 3,
                    bottom: 3,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: nameMaxWidth),
                    child: name,
                  ),
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Semantics(
              label: 'Remove ${label.name}',
              button: true,
              child: InkWell(
                key: ThreadActionBar.removeLabelKey(label.id),
                onTap: onRemove,
                borderRadius: BondRadii.fullAll,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
                  child: Icon(Icons.close, size: 14, color: colors.foreground),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
