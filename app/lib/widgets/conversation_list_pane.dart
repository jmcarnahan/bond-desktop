import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../models/label_models.dart';
import '../models/message_models.dart';
import '../services/sender_display.dart';
import '../theme/tokens.dart';
import 'conversation_row.dart';
import 'hover_actions.dart' show HoverAction;
import 'label_picker.dart';
import 'quick_replies.dart' show QuickReply, QuickReplyBox;

/// Which threads the list shows. [open] is the working view — everything not
/// yet resolved, split into what needs the user and what is waiting on someone
/// else; the rest are single-bucket views.
///
/// [needsAction] is the model's view rather than the thread state machine's:
/// it cuts across `needs_reply` and `waiting` and shows only what triage left
/// an ask on.
///
/// It lives beside the bucketing that consumes it rather than on the screen
/// that renders the pills, so the pane does not have to import its parent.
enum InboxFilter { open, needsAction, needsReply, waiting, done }

extension InboxFilterLabel on InboxFilter {
  String get label => switch (this) {
        InboxFilter.open => 'Open',
        InboxFilter.needsAction => 'Needs action',
        InboxFilter.needsReply => 'Needs reply',
        InboxFilter.waiting => 'Waiting',
        InboxFilter.done => 'Done',
      };
}

/// The left pane: section headers and thread rows in one flat scroll.
class ConversationListPane extends StatelessWidget {
  /// Which connectors to show. Email-only today; the source rail will pass a
  /// wider set without this widget changing.
  final List<String> sources;

  final InboxFilter filter;
  final List<Conversation> conversations;
  final String? selectedId;

  /// The open thread's connector. A conversation key is unique only within one
  /// source, so a bare [selectedId] can match a row from the other connector
  /// and highlight it too. Null keeps the id-only comparison, which is what a
  /// host with a single connector wants.
  final String? selectedSource;

  /// The row's source travels with its id: the host cannot resolve one from
  /// the other, because both connectors mint keys with no knowledge of each
  /// other and a shared key would otherwise open whichever thread the host
  /// happened to scan first.
  final void Function(String source, String conversationId) onSelect;

  /// Sections the caller has already bucketed, rendered instead of anything
  /// this pane would compute. The rail's sections do not line up with the
  /// filter enum, and forcing them to would mean inventing filter values
  /// nothing else uses. Null leaves [filter] in charge.
  final List<(String, List<Conversation>)>? sectionsOverride;

  /// When this session started, handed down to every row. Null shows no
  /// processing hints at all.
  final DateTime? processingSince;

  /// Puts a closed thread back into the working inbox. Offered on the DONE
  /// section only, and only when a host passed one — a Reopen beside a live
  /// thread is an action with nothing to undo.
  final void Function(String source, String conversationKey)? onReopen;

  /// A second line for one row, in place of the one it would draw for itself —
  /// see [ConversationRow.caption]. Null, the default, leaves every row saying
  /// what it always says; a builder that answers null for a given row does the
  /// same for that one.
  final String? Function(Conversation)? captionFor;

  /// What an empty pane says. The default is the plain fact; a host with a
  /// narrower list to draw — one tab of Needs You — says what that tab's
  /// emptiness means.
  final String emptyText;

  /// Drawn under [emptyText] when the pane is empty — the host's line about
  /// WHY it might be, and the way out. Null draws nothing. Here rather than
  /// in the sentence because the reason is the host's (a source filter it
  /// owns) and the pane must not pretend to know it.
  final Widget? emptyNotice;

  /// Files the thread away from here — the ✓ on the quick-action cluster. Null
  /// leaves that button off, which is what every host that wired none of these
  /// gets: no cluster at all and a list identical to the one before it.
  final void Function(Conversation conversation)? onDismiss;

  /// Asks the host to open the inline picker for that row. The host answers by
  /// changing what [labelPickerFor] reports, so the same open can come from a
  /// key press somewhere else.
  final void Function(Conversation conversation)? onLabel;

  /// Defers the thread. Null leaves the button off.
  final void Function(Conversation conversation)? onLater;

  /// Quiets the whole sender, current and future — the standing correction
  /// behind entry 6b. Drawn only on a row whose sender has a name to put in the
  /// tooltip, because "Drop sender Unknown sender" is not an offer anybody can
  /// judge.
  final void Function(Conversation conversation)? onDismissSender;

  /// The owner's vocabulary for the inline picker, in the order the picker wants
  /// it (see [LabelPicker.labels]).
  final List<Label> labels;

  /// What the rows measure "external" against — see [ConversationRow.ownerDomains].
  /// Empty means nobody is external, which is what an unwired host gets.
  final Set<String> ownerDomains;

  /// Which question the picker under a row is asking, and null for the rows —
  /// every row, by default — that have none open.
  ///
  /// A question per row rather than one id, because a conversation key is unique
  /// only within its source: asking the host about the row it is drawing costs
  /// nothing and cannot mix two connectors' threads up. Host-owned like the
  /// thread panel's own picker, and for the same reason — a key press outside
  /// this pane has to be able to open it.
  final LabelPickerMode? Function(Conversation conversation)? labelPickerFor;

  /// An existing label was chosen for that row.
  final void Function(Conversation conversation, Label label)? onApplyLabel;

  /// A name nothing matched was typed for that row; the host creates it and
  /// applies what comes back. A future handed back holds the picker busy until
  /// it settles — see [LabelPicker.onCreate].
  final FutureOr<void> Function(Conversation conversation, String name)?
      onCreateLabel;

  /// Dismiss that row with nothing on it.
  final void Function(Conversation conversation)? onDismissWithoutLabel;

  /// Escape, or the strip's ✕: the host collapses the picker.
  final void Function(Conversation conversation)? onCloseLabelPicker;

  /// How far this triage session has got — entry 12g's *12 of 60 cleared*.
  /// Null, the default, draws nothing.
  ///
  /// The host's arithmetic, not this pane's: what a session started with is a
  /// fact about a moment the pane was not there for, and counting the rows it
  /// can see would report the list shrinking rather than the reader's progress.
  /// Drawn only once something HAS been cleared — a line reading *0 of 60* is a
  /// scoreboard telling somebody who just sat down that they have done nothing.
  final ({int cleared, int total})? progress;

  /// Which row has a quick reply open, and what it is doing — see
  /// [QuickReply]. Null for every other row, and the default answers null for
  /// all of them.
  ///
  /// Host-owned for [labelPickerFor]'s reason, and it matters more here: `r` is
  /// pressed on the screen's own key map, not in this pane, so the state saying
  /// which row is being answered has to live where that press lands.
  final QuickReply? Function(Conversation conversation)? quickReplyFor;

  /// Sends what the reader typed in that row's box. The pane owns no send path
  /// — this is the composer's own [onSend] one row up the tree.
  ///
  /// `FutureOr` and handed straight through to [QuickReplyBox.onSend]: the box
  /// lets go of its send latch when the returned future settles. A host that
  /// returns nothing leaves the box waiting on an error or notice that CHANGES,
  /// and the same error twice in a row never does.
  final FutureOr<void> Function(Conversation conversation, String body)?
      onQuickReplySend;

  /// Escape, Cancel, or a send the host decided closes the box.
  final void Function(Conversation conversation)? onCloseQuickReply;

  /// The rows the reader has ticked for a bulk act — requirement 12c. Empty,
  /// the default, ticks nothing.
  ///
  /// Host-owned for [labelPickerFor]'s reason: `x` is pressed on the screen's
  /// own key map, and the bulk bar that acts on the selection is drawn outside
  /// this pane. Keyed by source and id together, because a conversation key is
  /// unique only within its connector.
  final Set<({String source, String key})> checked;

  /// The reader ticked or unticked that row. [range] is a Shift-click: the host
  /// adds everything between its anchor and this row, which is arithmetic over
  /// the pile the host drew and this pane only draws.
  ///
  /// Null, the default, draws no gutter at all — the list every other host
  /// gets. Wired, the gutter is RESERVED on every row whether or not its box is
  /// showing, so a pointer crossing a row never shifts the card under it.
  final void Function(Conversation conversation, {required bool range})?
      onToggleChecked;

  const ConversationListPane({
    super.key,
    required this.sources,
    required this.filter,
    required this.conversations,
    required this.selectedId,
    required this.onSelect,
    this.selectedSource,
    this.sectionsOverride,
    this.processingSince,
    this.onReopen,
    this.captionFor,
    this.emptyText = 'Nothing here.',
    this.emptyNotice,
    this.onDismiss,
    this.onLabel,
    this.onLater,
    this.onDismissSender,
    this.labels = const [],
    this.ownerDomains = const {},
    this.labelPickerFor,
    this.onApplyLabel,
    this.onCreateLabel,
    this.onDismissWithoutLabel,
    this.onCloseLabelPicker,
    this.progress,
    this.quickReplyFor,
    this.onQuickReplySend,
    this.onCloseQuickReply,
    this.checked = const {},
    this.onToggleChecked,
  });

  /// One row's quick actions, keyed by the thread rather than by its place in
  /// the list: a section above it growing by one would move an index, and a
  /// moving key throws away the button the pointer is on.
  static Key dismissKeyFor(Conversation c) => _actionKey('dismiss', c);
  static Key labelKeyFor(Conversation c) => _actionKey('label', c);
  static Key laterKeyFor(Conversation c) => _actionKey('later', c);
  static Key dismissSenderKeyFor(Conversation c) =>
      _actionKey('dismiss-sender', c);

  /// The selection box in one row's gutter.
  static Key checkKeyFor(Conversation c) => _actionKey('check', c);

  /// The inline picker under one row.
  static Key pickerKeyFor(Conversation c) => _actionKey('label-picker', c);

  /// The quick-reply box under one row. Per row like the picker's, even though
  /// the host opens one at a time: a box carrying the row's own key is a box
  /// whose state cannot follow the focus onto the next thread.
  static Key quickReplyKeyFor(Conversation c) => _actionKey('quick-reply', c);

  /// The session's progress line over the list.
  static const Key progressKey = ValueKey('triage-progress');


  static Key _actionKey(String what, Conversation c) =>
      ValueKey('row-$what-${c.source}|${c.id}');

  List<Conversation> _inState(ConversationState state) => [
        for (final c in conversations)
          if (sources.contains(c.source) && c.state == state) c,
      ];

  /// Threads triage left an ask on, in any state but done. A CTA on a thread
  /// the user already closed is history, not work — and `cta_text` is set only
  /// from a result that either named an action item or said the message needs
  /// one, so its presence IS the model's needs-action answer folded up.
  List<Conversation> get _needsAction => [
        for (final c in conversations)
          if (sources.contains(c.source) &&
              c.state != ConversationState.done &&
              c.ctaText?.isNotEmpty == true)
            c,
      ];

  /// (label, rows) in render order. `open` is the only filter that produces
  /// two sections.
  List<(String, List<Conversation>)> get _sections =>
      sectionsOverride ?? _byFilter;

  List<(String, List<Conversation>)> get _byFilter => switch (filter) {
        InboxFilter.open => [
            ('NEEDS REPLY', _inState(ConversationState.needsReply)),
            ('WAITING', _inState(ConversationState.waiting)),
          ],
        InboxFilter.needsAction => [
            ('NEEDS ACTION', _needsAction),
          ],
        InboxFilter.needsReply => [
            ('NEEDS REPLY', _inState(ConversationState.needsReply)),
          ],
        InboxFilter.waiting => [
            ('WAITING', _inState(ConversationState.waiting)),
          ],
        InboxFilter.done => [
            ('DONE', _inState(ConversationState.done)),
          ],
      };

  /// Whether rows carry a Reopen. The done section as THIS pane bucketed it,
  /// never a section a host labelled 'DONE' through [sectionsOverride] — the
  /// rows under an override are the caller's own, and reopening a live thread
  /// does nothing anyone asked for.
  bool get _showReopen =>
      onReopen != null && sectionsOverride == null && filter == InboxFilter.done;

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final total = sections.fold<int>(0, (n, s) => n + s.$2.length);

    if (total == 0) {
      final notice = emptyNotice;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                emptyText,
                style: BondType.small,
                textAlign: TextAlign.center,
              ),
              if (notice != null) ...[
                const SizedBox(height: BondSpacing.s8),
                notice,
              ],
            ],
          ),
        ),
      );
    }

    // Flattened to one index of header/row entries, then built lazily. A
    // section with no rows contributes nothing — in the two-section `open` view
    // an empty half just pushes the other half down. Building the entry list is
    // cheap (records, not widgets); the win is `ListView.builder` materialising
    // only the rows on screen. The eager `ListView(children:)` this replaced
    // built a widget for every thread up front, which on a mailbox with
    // thousands of "Done" threads exhausted the GPU and crashed the app.
    final entries = <_PaneEntry>[];
    // The session's own line first: it is about the reader rather than about
    // any thread, and it scrolls away with the rest — a counter pinned over a
    // list of mail would be the loudest thing on the screen.
    final progressLine = _progressRow();
    if (progressLine != null) entries.add(_LooseEntry(progressLine));
    for (final (label, rows) in sections) {
      if (rows.isEmpty) continue;
      entries.add(_HeaderEntry(label, rows.length));
      for (final c in rows) {
        entries.add(_RowEntry(c));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        if (entry is _LooseEntry) return entry.child;
        if (entry is _HeaderEntry) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              BondSpacing.s4,
              BondSpacing.s16,
              BondSpacing.s4,
              BondSpacing.s8,
            ),
            child: Row(
              children: [
                Text(entry.label, style: BondType.label),
                const SizedBox(width: BondSpacing.s8),
                Text('${entry.count}', style: BondType.caption),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: _row((entry as _RowEntry).conversation),
        );
      },
    );
  }

  /// One thread's card, with Reopen beside it where the section offers one, the
  /// quick-action cluster beside that where the host wired any, and the inline
  /// label picker under it while the host has one open.
  ///
  /// Everything is outside the card rather than in it: [ConversationRow] is the
  /// same row everywhere it appears, and a card that grows an action in one list
  /// is a card that reads differently in the others.
  Widget _row(Conversation c) {
    final toggle = onToggleChecked;
    final row = ConversationRow(
      conversation: c,
      selected: c.id == selectedId &&
          (selectedSource == null || selectedSource == c.source),
      // A Shift-click on the card is a range, and it does not open the row:
      // the reader is sweeping a selection, and a thread opening beside on
      // every sweep would be the list fighting them.
      onTap: () {
        if (toggle != null && HardwareKeyboard.instance.isShiftPressed) {
          toggle(c, range: true);
          return;
        }
        onSelect(c.source, c.id);
      },
      processingSince: processingSince,
      caption: captionFor?.call(c),
      ownerDomains: ownerDomains,
    );

    Widget body = row;
    if (_showReopen) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          const SizedBox(width: BondSpacing.s8),
          TextButton(
            onPressed: () => onReopen!(c.source, c.id),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Reopen'),
          ),
        ],
      );
    }

    final actions = _quickActions(c);
    final gutter = _checkGutter(c);
    if (actions.isNotEmpty || gutter != null) {
      body = _RowActions(actions: actions, leading: gutter, child: body);
    }

    final box = _quickReply(c);
    final picker = _picker(c);
    if (box == null && picker == null) return body;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        body,
        // The box first where both are up: it holds a cursor, and a picker
        // pushing a half-written reply down the pane would move the words the
        // reader is looking at.
        if (box != null) ...[
          const SizedBox(height: BondSpacing.s8),
          box,
        ],
        if (picker != null) ...[
          const SizedBox(height: BondSpacing.s8),
          picker,
        ],
      ],
    );
  }

  /// The quick-reply box under one row, or null while that row has none open.
  ///
  /// Under the card and outside it, on [_picker]'s rule and the Reopen button's:
  /// [ConversationRow] draws the same row in every list, and a card that grew a
  /// text field here would be a different card in the four lists that never
  /// wired this.
  ///
  /// The reader it names comes off the thread itself rather than from the host —
  /// the same `displaySenderName` the sender rule's tooltip uses, so the box says
  /// who it is answering in the words the row already shows.
  Widget? _quickReply(Conversation c) {
    final openFor = quickReplyFor;
    final send = onQuickReplySend;
    final close = onCloseQuickReply;
    if (openFor == null || send == null || close == null) return null;
    final reply = openFor(c);
    if (reply == null) return null;
    return QuickReplyBox(
      key: quickReplyKeyFor(c),
      reply: reply,
      who: displaySenderName(
        name: c.primaryParticipant?.name,
        address: c.primaryEmail,
        fallback: '',
      ),
      onSend: (body) => send(c, body),
      onClose: () => close(c),
    );
  }

  /// What the pointer — or the keyboard, on a focused row — offers beside one
  /// thread: the four things entries 12b and 6b asked for, in the order they
  /// cost the reader. Empty when the host wired none, which is what leaves the
  /// row unwrapped.
  ///
  /// Every one of them also lives in the thread's own header, so a row that
  /// never sees a pointer is not a row with actions nobody can reach.
  List<HoverAction> _quickActions(Conversation c) {
    final dismiss = onDismiss;
    final label = onLabel;
    final later = onLater;
    final sender = onDismissSender;
    // The tooltip carries the sender the button cannot name in its own width.
    final who = displaySenderName(
      name: c.primaryParticipant?.name,
      address: c.primaryEmail,
      fallback: '',
    );

    return [
      if (dismiss != null)
        HoverAction(
          icon: Icons.check,
          tooltip: 'Mark done',
          onTap: () => dismiss(c),
          key: dismissKeyFor(c),
        ),
      if (label != null)
        HoverAction(
          icon: Icons.label_outline,
          tooltip: 'Label…',
          onTap: () => label(c),
          key: labelKeyFor(c),
        ),
      if (later != null)
        HoverAction(
          icon: Icons.schedule,
          tooltip: 'Later',
          onTap: () => later(c),
          key: laterKeyFor(c),
        ),
      // Last, because it is the widest correction on the strip: the others
      // change one row, this one changes the shape of the inbox.
      if (sender != null && who.isNotEmpty)
        HoverAction(
          icon: Icons.block_outlined,
          // The ⋯ menu's and the palette's word: dropping gates the sender's
          // new mail and files what is here in Later, so "everything" would
          // overclaim.
          tooltip: 'Drop sender $who',
          onTap: () => sender(c),
          key: dismissSenderKeyFor(c),
        ),
    ];
  }

  /// The selection box beside one row, as a builder [_RowActions] calls with
  /// whether the row is under the pointer or the focus — or null when the host
  /// wired no [onToggleChecked].
  ///
  /// In a gutter OUTSIDE the card, on the Reopen button's rule: the external
  /// tint's stripe owns the card's left edge, and [ConversationRow] stays the
  /// same row in every list. The box draws on hover, on focus, on a ticked row,
  /// and on every row once anything is ticked — a reader mid-selection should
  /// see where the rest of the boxes are without hunting for them.
  Widget Function(bool revealed)? _checkGutter(Conversation c) {
    final toggle = onToggleChecked;
    if (toggle == null) return null;
    final ticked = checked.contains((source: c.source, key: c.id));
    final anyTicked = checked.isNotEmpty;
    return (revealed) => SizedBox(
          width: _gutterWidth,
          child: (revealed || ticked || anyTicked)
              ? Padding(
                  padding: const EdgeInsets.only(top: BondSpacing.s12),
                  child: Checkbox(
                    key: checkKeyFor(c),
                    value: ticked,
                    onChanged: (_) => toggle(
                      c,
                      range: HardwareKeyboard.instance.isShiftPressed,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                )
              : null,
        );
  }

  static const double _gutterWidth = 24;

  /// The inline picker under one row, or null while that row has none open.
  ///
  /// Under the card rather than over it: nothing opens over anything here, and a
  /// strip in the flow pushes the rows below down where a popup would hide them.
  /// Like the panel's own mount, it draws only when the host wired the callbacks
  /// it cannot work without.
  Widget? _picker(Conversation c) {
    final openFor = labelPickerFor;
    final apply = onApplyLabel;
    final create = onCreateLabel;
    final close = onCloseLabelPicker;
    if (openFor == null || apply == null || create == null || close == null) {
      return null;
    }
    final mode = openFor(c);
    if (mode == null) return null;

    final without = onDismissWithoutLabel;
    return LabelPicker(
      key: pickerKeyFor(c),
      labels: labels,
      // The ✓ on what the thread already wears, exactly as the panel's
      // picker draws it — `l` on a row and `l` on the open thread are the
      // same question and must offer the same answers.
      appliedIds: {for (final l in c.labels) l.id},
      prompt: mode.prompt,
      onApply: (label) => apply(c, label),
      onCreate: (name) => create(c, name),
      // Only the dismiss path can end with no word on the thread.
      onDismissWithoutLabel: mode == LabelPickerMode.dismiss && without != null
          ? () => without(c)
          : null,
      onClose: () => close(c),
    );
  }

  /// *12 of 60 cleared*, or null — see [progress].
  ///
  /// One line of caption and nothing else: no bar, no percentage and no
  /// celebration. The reader can see the list getting shorter; this says how
  /// much of it was theirs.
  Widget? _progressRow() {
    final done = progress;
    if (done == null || done.cleared <= 0 || done.total <= 0) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s4,
        BondSpacing.s12,
        BondSpacing.s4,
        0,
      ),
      child: Text(
        '${done.cleared} of ${done.total} cleared',
        key: progressKey,
        style: BondType.caption,
      ),
    );
  }
}

/// A row's quick actions, revealed at its trailing edge under the pointer or on
/// focus.
///
/// The transcript's `HoverActions` shape, and for its reason: a strip in the
/// FLOW beside every row would reserve four buttons' width — a sixth of a narrow
/// list column — on every row forever, and one under the row would move every
/// row below it each time the pointer crossed one. A strip over the card's
/// trailing edge costs nothing until it is asked for and reflows nothing when it
/// is.
///
/// Two differences from the transcript's: focus reveals it as well as hover,
/// because a keyboard-first pass down the list (`j`/`k`) never moves the mouse
/// and must still see what it can do; and the strip is a SIBLING of the card,
/// which is what keeps [ConversationRow] the same row in every list.
///
/// The strip is built only while it shows, so a test that finds its buttons is a
/// test that the reveal happened.
class _RowActions extends StatefulWidget {
  final Widget child;
  final List<HoverAction> actions;

  /// A leading gutter beside the card, told whether the row is revealed — the
  /// selection box. Here rather than a second [MouseRegion] of its own, so one
  /// region answers "is the pointer on this row" for both edges.
  final Widget Function(bool revealed)? leading;

  const _RowActions({
    required this.child,
    required this.actions,
    this.leading,
  });

  @override
  State<_RowActions> createState() => _RowActionsState();
}

class _RowActionsState extends State<_RowActions> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final revealed = _hovered || _focused;
    Widget card = Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (revealed && widget.actions.isNotEmpty)
          Positioned(
            top: 0,
            bottom: 0,
            right: BondSpacing.s8,
            child: _strip(),
          ),
      ],
    );
    final leading = widget.leading;
    if (leading != null) {
      card = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading(revealed),
          Expanded(child: card),
        ],
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Not a tab stop of its own — the row's own ink well is the stop, and this
      // node exists only to hear when the focus lands anywhere inside it.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) => setState(() => _focused = has),
        child: card,
      ),
    );
  }

  Widget _strip() {
    return Center(
      widthFactor: 1,
      child: Material(
        color: BondColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BondRadii.smAll,
          side: const BorderSide(color: BondColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in widget.actions)
              IconButton(
                key: action.key,
                onPressed: action.onTap,
                icon: Icon(action.icon),
                iconSize: 16,
                tooltip: action.tooltip,
                padding: const EdgeInsets.all(BondSpacing.s4),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}

/// One line in the pane's flattened, lazily-built list: a section header, a
/// thread row, or the progress line over the top of them. Flattening is what
/// lets a `ListView.builder` render only the entries on screen instead of a
/// widget per thread.
sealed class _PaneEntry {
  const _PaneEntry();
}

class _HeaderEntry extends _PaneEntry {
  final String label;
  final int count;
  const _HeaderEntry(this.label, this.count);
}

class _RowEntry extends _PaneEntry {
  final Conversation conversation;
  const _RowEntry(this.conversation);
}

/// A one-off line over the list — the session's progress — built ONCE in
/// `build` rather than in the item builder: there is at most one, and it does
/// not depend on the index it lands at.
class _LooseEntry extends _PaneEntry {
  final Widget child;
  const _LooseEntry(this.child);
}
