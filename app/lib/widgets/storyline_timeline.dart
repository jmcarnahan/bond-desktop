import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/open_asks.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'message_row.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// One storyline as a spine of thread episodes, newest at the bottom.
///
/// Each member thread is one collapsible card rather than a run of messages
/// spliced into a merged transcript: a storyline is several conversations, and
/// interleaving them by timestamp made the reader reassemble each one in their
/// head. Collapse is how you skim the spine; the card header is how you jump
/// into the thread the card stands for.
class StorylineTimelinePanel extends StatefulWidget {
  final Storyline storyline;

  /// One card each, oldest activity first. That is the canonical order — what
  /// opens by default and what a member's label is read from — but the spine
  /// may be displayed reversed, per [newestFirst].
  final List<StorylineEpisode> episodes;

  final List<StorylineMember> members;

  /// Null hides the back affordance, for a layout where the storyline is not
  /// something you navigated into.
  final VoidCallback? onBack;

  final void Function(String title) onRename;

  /// Saves the storyline's membership criteria. Passed through untrimmed —
  /// the service decides what an empty charter means.
  final void Function(String charter) onSetCharter;

  /// Takes the charter the refresh pass parked as the storyline's own. Hosts
  /// route it through the same save [onSetCharter] uses: accepting the model's
  /// sentence is the user saying this is what the storyline is about, which
  /// locks the charter and sends the model hunting for threads that match.
  final void Function(String charter) onAcceptSuggestion;

  /// Throws the parked charter away. The user's own charter and its lock are
  /// untouched.
  final VoidCallback onDismissSuggestion;

  final void Function(String source, String conversationKey) onRemoveThread;
  final void Function(String source, String conversationKey) onOpenThread;

  /// Opens the pane that picks a thread to file in here. A pane and not a
  /// menu: the choice is a whole mailbox long.
  final VoidCallback onAddThread;

  /// Displays the spine newest card first. Only the rendering order changes:
  /// the newest episode is still the one that opens on its own.
  final bool newestFirst;

  final VoidCallback onToggleSort;

  /// Retires the storyline. The host decides what that leaves on screen — this
  /// panel is one of the things it takes away.
  final VoidCallback onDismiss;

  /// Rendered at the END of an OPEN card, under that thread's messages, so it
  /// reads as attached to the episode rather than to the spine.
  ///
  /// Hosts pass the reply affordance here. The panel does not know what it is
  /// and does not ask — it renders a spine and knows nothing about drafts or
  /// sending, which is the arrangement `ThreadDetailPanel.afterTranscript`
  /// already lives under. The widget owns its own spacing, so a footer with
  /// nothing to show can render nothing and leave no gap behind.
  final Widget Function(StorylineEpisode episode)? episodeFooter;

  /// A message's open ask was tapped, on the card it belongs to. Null leaves
  /// every ask a statement.
  final void Function(StorylineEpisode episode)? onAskTap;

  /// The same action the overview's Sync runs: the ordinary two-connector
  /// pull, whose tail heals the refreshes and recaps the storylines were owed.
  /// Asking for mail from this screen is asking for this storyline to be
  /// brought up to date.
  final Future<void> Function() onSync;

  /// Whether that pull is running right now. The flag rides in rather than
  /// living here because the panel is pure: the screen owns the sync, and it
  /// is the same sync the overview's button is already holding a label up for.
  final bool syncing;

  const StorylineTimelinePanel({
    super.key,
    required this.storyline,
    required this.episodes,
    required this.members,
    required this.onBack,
    required this.onRename,
    required this.onSetCharter,
    required this.onAcceptSuggestion,
    required this.onDismissSuggestion,
    required this.onRemoveThread,
    required this.onOpenThread,
    required this.onAddThread,
    required this.newestFirst,
    required this.onToggleSort,
    required this.onDismiss,
    required this.onSync,
    required this.syncing,
    this.episodeFooter,
    this.onAskTap,
  });

  /// Matches the thread panel: wide enough for a long paragraph, narrow enough
  /// that an ultrawide window does not turn every message into one line.
  static const double _maxContentWidth = 900;

  /// A member entry carries a whole subject line, which can be arbitrarily
  /// long.
  static const double _entryMaxWidth = 320;

  @override
  State<StorylineTimelinePanel> createState() => _StorylineTimelinePanelState();
}

class _StorylineTimelinePanelState extends State<StorylineTimelinePanel> {
  /// Cards the user has opened or shut, by thread key. Only the ones they
  /// touched: everything else follows the default, so a reload that brings in
  /// a newer episode moves what is open without undoing a choice.
  final Map<String, bool> _overrides = {};

  bool _showMembers = false;
  bool _showAbout = false;

  /// Whether each of the recap's two lists is unfolded. Both start folded, and
  /// they fold independently: a storyline can carry half a dozen open items
  /// and as many settled ones, and twelve bullet lines between the paragraph
  /// and the spine is a header nobody reads to the end of. The counts ride on
  /// the headings, so a folded list still says how much is behind it.
  bool _openExpanded = false;
  bool _decidedExpanded = false;
  bool _editingTitle = false;
  bool _editingCharter = false;
  bool _confirmingDismiss = false;

  /// The parked charter's **Use this** has been armed. Its own flag rather
  /// than the dismiss one: accepting a suggestion and retiring the storyline
  /// are different questions, and arming one must not look like arming the
  /// other.
  bool _confirmingSuggestion = false;

  /// The card whose remove × has been armed, by thread key. One at a time: a
  /// spine with three open questions on it is a spine nobody reads.
  String? _confirmingRemoveKey;

  late final TextEditingController _title =
      TextEditingController(text: widget.storyline.title);

  late final TextEditingController _charter =
      TextEditingController(text: widget.storyline.charter ?? '');

  @override
  void dispose() {
    _title.dispose();
    _charter.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StorylineTimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh that parks a different sentence while the confirm is armed
    // makes the arm stale: what the user was about to accept is not what the
    // second tap would now write.
    if (oldWidget.storyline.charterSuggestion !=
        widget.storyline.charterSuggestion) {
      _confirmingSuggestion = false;
    }
  }

  void _startEditing() {
    setState(() {
      _title.text = widget.storyline.title;
      _editingTitle = true;
    });
  }

  void _submitTitle(String value) {
    final trimmed = value.trim();
    setState(() => _editingTitle = false);
    // An empty rename is a cancel. A storyline with no name is not a thing the
    // rail can render, and clearing the field is far more likely to be a
    // mistake than an instruction.
    if (trimmed.isEmpty || trimmed == widget.storyline.title) return;
    widget.onRename(trimmed);
  }

  /// The thread whose messages the storyline ends on, which is the one card
  /// that opens on its own. Read from the episodes on every build rather than
  /// pinned in `initState`: a reload can put a different thread last, and the
  /// open card should follow the conversation.
  String? get _newestKey =>
      widget.episodes.isEmpty ? null : widget.episodes.last.threadKey;

  bool _isExpanded(StorylineEpisode episode) =>
      _overrides[episode.threadKey] ?? (episode.threadKey == _newestKey);

  /// A member thread's name, taken from its episode. A member whose thread
  /// holds no messages has no episode and so no subject, which reads as a
  /// thread with nothing in it rather than as an error.
  ///
  /// Keyed by source AND key: two connectors can carry the same conversation
  /// key, and a lookup on the key alone would label one member row with the
  /// other connector's subject.
  String _labelFor(String source, String conversationKey) {
    final subjects = {
      for (final episode in widget.episodes) episode.threadKey: episode.subject,
    };
    final subject = subjects['$source\n$conversationKey'] ?? '';
    return subject.isEmpty ? '(no subject)' : subject;
  }

  @override
  Widget build(BuildContext context) {
    // The only place the preference is applied. Everything else in here reads
    // `widget.episodes`, which stays oldest first whatever is on screen.
    final displayed = widget.newestFirst
        ? widget.episodes.reversed.toList()
        : widget.episodes;

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
          if (_showAbout) _aboutBlock(),
          if (_showMembers) _memberStrip(),
          const Divider(height: 1, color: BondColors.border),
          Expanded(
            child: widget.episodes.isEmpty
                ? Center(
                    child: Text('No messages in this storyline.',
                        style: BondType.small),
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: StorylineTimelinePanel._maxContentWidth,
                      ),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          BondSpacing.s24,
                          BondSpacing.s12,
                          BondSpacing.s24,
                          BondSpacing.s24,
                        ),
                        children: [
                          for (final episode in displayed)
                            _episodeCard(episode),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// One member thread, shut or open. Shut it is a headline the reader can
  /// skip; open it is the thread itself.
  Widget _episodeCard(StorylineEpisode episode) {
    final expanded = _isExpanded(episode);

    return Container(
      margin: const EdgeInsets.only(bottom: BondSpacing.s12),
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardHeader(episode, expanded),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BondSpacing.s12,
                0,
                BondSpacing.s12,
                BondSpacing.s12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ..._run(episode),
                  ?widget.episodeFooter?.call(episode),
                ],
              ),
            )
          else
            ..._preview(episode),
        ],
      ),
    );
  }

  Widget _cardHeader(StorylineEpisode episode, bool expanded) {
    final count = episode.messages.length;
    final meta = [
      if (episode.participants.isNotEmpty) episode.participants.join(', '),
      '$count ${count == 1 ? 'message' : 'messages'}',
      ?relativeTime(episode.latestAt, DateTime.now()),
    ].join(' · ');
    final summary = episode.summary ?? '';
    // Byte-for-byte the rule `thread_detail_panel` renders its CTA banner by,
    // and deliberately shared with it: the two surfaces can never disagree
    // about whether a thread needs the user, and a waiting thread shows no CTA
    // anywhere.
    final cta = episode.ctaText;
    final showCta = episode.state == ConversationState.needsReply &&
        cta != null &&
        cta.isNotEmpty;

    // The banner names the newest ask only. When older ones are still open,
    // the count says so — the messages below are where they are read.
    final openAsks = openAskCount(
      episode.messages,
      conversationClosed: episode.state != ConversationState.needsReply,
    );

    return InkWell(
      onTap: () => setState(
        () => _overrides[episode.threadKey] = !expanded,
      ),
      child: Padding(
        padding: const EdgeInsets.all(BondSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: BondColors.inkMuted,
            ),
            const SizedBox(width: BondSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // The source is marked on EVERY card, mail included: a
                    // storyline merges threads and chats, and marking only the
                    // exception leaves the reader guessing what the unmarked
                    // ones were.
                    '${sourceChipPrefix(episode.source)}'
                    '${episode.subject.isEmpty ? '(no subject)' : episode.subject}',
                    style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: BondType.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The ask replaces the summary rather than stacking above
                  // it: they are the same fact in two moods, and a card that
                  // spent four lines saying it twice would crowd the spine.
                  if (showCta) ...[
                    const SizedBox(height: BondSpacing.s4),
                    _cardCta(
                      episode,
                      cta,
                      openAsks > 1 ? '$cta · $openAsks open asks' : cta,
                    ),
                  ] else if (summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      style: BondType.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // The two-step stands where a confirm dialog would: the first tap
            // asks, the second takes the thread out. Both icons give way to
            // the pair, so the header reads as one question rather than a
            // question next to an unrelated button.
            if (_confirmingRemoveKey == episode.threadKey) ...[
              _quietButton('Remove thread', () {
                setState(() => _confirmingRemoveKey = null);
                widget.onRemoveThread(
                  episode.source,
                  episode.conversationKey,
                );
              }),
              const SizedBox(width: BondSpacing.s4),
              _quietButton(
                'Cancel',
                () => setState(() => _confirmingRemoveKey = null),
              ),
            ] else ...[
              IconButton(
                onPressed: () => widget.onOpenThread(
                  episode.source,
                  episode.conversationKey,
                ),
                icon: const Icon(Icons.open_in_new),
                iconSize: 14,
                tooltip: 'Open thread',
                padding: const EdgeInsets.all(BondSpacing.s4),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: () => setState(
                  () => _confirmingRemoveKey = episode.threadKey,
                ),
                icon: const Icon(Icons.close),
                iconSize: 14,
                tooltip: 'Remove from storyline',
                padding: const EdgeInsets.all(BondSpacing.s4),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The ask on a card header. [tooltip] stays the bare ask: it exists to show
  /// the full text [text] had to clamp.
  ///
  /// It takes its own tap where the host has a reply to open. The thread pane's
  /// banner is the shortest way into the reply
  /// (`thread_detail_panel._ctaBanner`), and the same copper text here must not
  /// mean "shut the card" instead — the nested [InkWell] absorbs the tap so the
  /// header's collapse never sees it. Its own transparent [Material] for the
  /// usual reason: ink paints on the nearest Material ancestor, which sits
  /// behind the card's opaque surface.
  Widget _cardCta(StorylineEpisode episode, String tooltip, String text) {
    final banner = Tooltip(
      message: tooltip,
      child: InlineAlert(
        severity: InlineAlertSeverity.attention,
        text: text,
        maxLines: 2,
      ),
    );
    final onAskTap = widget.onAskTap;
    if (onAskTap == null) return banner;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onAskTap(episode),
        borderRadius: BondRadii.smAll,
        child: banner,
      ),
    );
  }

  /// What a shut card shows of the thread: the newest message, and nothing at
  /// all when that message has no text to show yet.
  List<Widget> _preview(StorylineEpisode episode) {
    if (episode.messages.isEmpty) return const [];
    final message = episode.messages.last;
    final preview = (message.bodyPreview?.isNotEmpty == true
            ? message.bodyPreview!
            : (message.bodyText ?? ''))
        .trim();
    if (preview.isEmpty) return const [];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          BondSpacing.s12,
          0,
          BondSpacing.s12,
          BondSpacing.s12,
        ),
        child: Text(
          preview,
          style: BondType.caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ];
  }

  /// One thread's messages: day dividers and runs collapsed under one header,
  /// the same reading as the thread panel. The dividers live inside the card
  /// because a day only means something within one conversation here.
  List<Widget> _run(StorylineEpisode episode) {
    final items = <Widget>[];
    String? previousDay;
    Message? previous;
    var first = true;

    // One scan of the thread answers the open-ask rule for every row in it.
    // Anything but "needs reply" closes them: without this, a send that clears
    // the banner leaves the ask lines lit for up to a minute until the sent
    // message syncs back.
    final lastOut = latestOutboundAt(episode.messages);
    final closed = episode.state != ConversationState.needsReply;

    for (final message in episode.messages) {
      final day = dayKeyOf(message);
      final label = formatDayLabel(message.receivedAt);
      if (label != null && (first || day != previousDay)) {
        items.add(DayDivider(label: label));
        previous = null;
      }
      previousDay = day;
      first = false;

      final open = hasOpenAsk(
        message,
        lastOutboundAt: lastOut,
        conversationClosed: closed,
      );
      final onAskTap = widget.onAskTap;
      items.add(MessageRow(
        key: ValueKey(message.id),
        message: message,
        showHeader: previous == null || !sameRun(previous, message),
        openAsk: open,
        // Only a line that is actually on screen gets a tap, and it carries
        // the episode with it: the answer goes to the thread the ask is in.
        onAskTap: open && onAskTap != null ? () => onAskTap(episode) : null,
      ));
      previous = message;
    }
    return items;
  }

  Widget _header() {
    final storyline = widget.storyline;
    final summary = storyline.summary ?? '';
    final recap = storyline.recapText ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s16,
        vertical: BondSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.onBack != null) ...[
            IconButton(
              onPressed: widget.onBack,
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
                _titleField(storyline),
                // The recap REPLACES the one-line summary here rather than
                // stacking over it: they answer the same question at
                // different lengths, and the long answer is what this screen
                // is for. The summary is still what the rail and the overview
                // cards show, and it is the header's text until the recap
                // pass has written one.
                if (recap.isNotEmpty)
                  _recapBlock(storyline, recap)
                else if (summary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    style: BondType.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                Row(
                  children: [
                    _quietButton(
                      '${widget.members.length} '
                      '${widget.members.length == 1 ? 'thread' : 'threads'}',
                      () => setState(() => _showMembers = !_showMembers),
                    ),
                    const SizedBox(width: BondSpacing.s4),
                    _quietButton(
                      'About',
                      () => setState(() => _showAbout = !_showAbout),
                    ),
                    const SizedBox(width: BondSpacing.s4),
                    _quietButton('Add thread', widget.onAddThread),
                    const SizedBox(width: BondSpacing.s4),
                    // The label names the order the spine is in; tapping it
                    // flips to the other one.
                    _quietButton(
                      widget.newestFirst ? 'Newest first' : 'Oldest first',
                      widget.onToggleSort,
                    ),
                    const SizedBox(width: BondSpacing.s4),
                    // The two-step stands where a confirm dialog would: the
                    // first tap asks, the second retires the storyline.
                    if (!_confirmingDismiss)
                      _quietButton(
                        'Dismiss',
                        () => setState(() => _confirmingDismiss = true),
                      )
                    else ...[
                      _quietButton('Dismiss storyline', widget.onDismiss),
                      const SizedBox(width: BondSpacing.s4),
                      _quietButton(
                        'Cancel',
                        () => setState(() => _confirmingDismiss = false),
                      ),
                    ],
                    const SizedBox(width: BondSpacing.s4),
                    // Last in the row: it is the only button here that is not
                    // about this storyline in particular. A running pull says
                    // so and takes no second tap — the screen holds the flag,
                    // so the label is the same one the overview shows.
                    _quietButton(
                      widget.syncing ? 'Syncing…' : 'Sync',
                      widget.syncing ? null : widget.onSync,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Where the storyline stands, in the recap pass's words — the catch-up a
  /// colleague would give, so the reader need not open every card below it.
  /// It is the centrepiece of this screen, which is why it takes body type
  /// where the summary took caption.
  ///
  /// The two lists under it stay quiet and compact: they are what is still
  /// open and what has been settled, and a paragraph that has to compete with
  /// them for the eye is a paragraph nobody reads. That is also why they are
  /// folded to a counted heading until asked for. Either can be empty — a
  /// storyline with nothing outstanding shows no OPEN heading at all.
  Widget _recapBlock(Storyline storyline, String recap) {
    final open = storyline.recapOpenItems;
    final decided = storyline.recapDecisions;
    final asOf = relativeTime(storyline.recapThrough, DateTime.now());

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: StorylineTimelinePanel._maxContentWidth,
      ),
      child: Padding(
        padding: const EdgeInsets.only(
          top: BondSpacing.s4,
          bottom: BondSpacing.s4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(recap, style: BondType.body),
            ..._recapList(
              'OPEN',
              open,
              expanded: _openExpanded,
              onToggle: () => setState(() => _openExpanded = !_openExpanded),
            ),
            ..._recapList(
              'DECIDED',
              decided,
              expanded: _decidedExpanded,
              onToggle: () =>
                  setState(() => _decidedExpanded = !_decidedExpanded),
            ),
            if (asOf != null) ...[
              const SizedBox(height: BondSpacing.s4),
              // What the recap has read up to, not when it ran: a pass that
              // found nothing new leaves the watermark where it was, and the
              // honest thing to date the paragraph by is the newest message
              // it has seen.
              Text('as of $asOf', style: BondType.caption),
            ],
          ],
        ),
      ),
    );
  }

  /// One heading and — when [expanded] — its lines, or nothing at all when
  /// there is nothing to head. An empty list has no heading to fold, so it is
  /// still absent entirely rather than present and folded.
  ///
  /// The heading carries its own count and is the thing you tap. It stays a
  /// heading while it does: the tappable text idiom [_titleField] uses, not
  /// the row's `_quietButton`, because a pair of blue buttons here would read
  /// as actions on the storyline and would out-shout the paragraph they sit
  /// under.
  List<Widget> _recapList(
    String heading,
    List<String> items, {
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    if (items.isEmpty) return const [];
    return [
      const SizedBox(height: BondSpacing.s8),
      InkWell(
        onTap: onToggle,
        borderRadius: BondRadii.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          // The count is what a folded heading has to say for itself: OPEN on
          // its own leaves the reader with no way to tell whether the tap is
          // worth making.
          child: Text('$heading · ${items.length}', style: BondType.label),
        ),
      ),
      if (expanded)
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('·', style: BondType.caption),
                const SizedBox(width: BondSpacing.s4),
                Expanded(child: Text(item, style: BondType.caption)),
              ],
            ),
          ),
    ];
  }

  /// The title, editable in place. Tap to edit, enter to commit, focus loss to
  /// abandon — a rename is a small enough act that a dialog for it would be
  /// heavier than the thing being renamed.
  Widget _titleField(Storyline storyline) {
    if (!_editingTitle) {
      return InkWell(
        onTap: _startEditing,
        borderRadius: BondRadii.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            storyline.title.isEmpty ? '(untitled)' : storyline.title,
            style: BondType.titleSm,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return TextField(
      controller: _title,
      autofocus: true,
      style: BondType.titleSm,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: BondSpacing.s4),
      ),
      onSubmitted: _submitTitle,
      onTapOutside: (_) {
        if (_editingTitle) setState(() => _editingTitle = false);
      },
    );
  }

  /// The charter: what belongs in this storyline, in a sentence.
  ///
  /// Editable because it is the membership criteria and not a description of
  /// one — narrowing or widening this sentence is how a user says which
  /// threads belong, and saving it is what sends the model hunting for the
  /// ones that match.
  Widget _aboutBlock() {
    final charter = widget.storyline.charter ?? '';
    final suggestion = widget.storyline.charterSuggestion ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        0,
        BondSpacing.s16,
        BondSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _editingCharter ? _charterField() : _charterText(charter),
          // Not while the field is open: offering to replace a sentence the
          // user is in the middle of writing is offering to throw their work
          // away, and the field is where they would be typing the answer to
          // this suggestion anyway.
          if (!_editingCharter && suggestion.isNotEmpty)
            _suggestionBlock(suggestion),
        ],
      ),
    );
  }

  /// What the refresh pass would have written to the charter, parked because
  /// the charter is the user's own and a locked one is never auto-amended.
  ///
  /// Accepting it is a two-step for the same reason removing a thread is: it
  /// overwrites a sentence a person wrote, and it sends the model hunting for
  /// threads that match the new one.
  Widget _suggestionBlock(String suggestion) {
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SUGGESTED UPDATE', style: BondType.label),
          const SizedBox(height: 2),
          Text(
            suggestion,
            style: BondType.caption.copyWith(fontStyle: FontStyle.italic),
          ),
          Row(
            children: [
              if (!_confirmingSuggestion) ...[
                _quietButton(
                  'Use this',
                  () => setState(() => _confirmingSuggestion = true),
                ),
                const SizedBox(width: BondSpacing.s4),
                // One tap: dismissing throws away the model's text, not the
                // user's, and the next refresh may park another.
                _quietButton('Discard', widget.onDismissSuggestion),
              ] else ...[
                _quietButton('Replace the charter', () {
                  setState(() => _confirmingSuggestion = false);
                  widget.onAcceptSuggestion(suggestion);
                }),
                const SizedBox(width: BondSpacing.s4),
                _quietButton(
                  'Cancel',
                  () => setState(() => _confirmingSuggestion = false),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _charterText(String charter) {
    return InkWell(
      onTap: () => setState(() {
        _charter.text = charter;
        _editingCharter = true;
      }),
      borderRadius: BondRadii.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
        child: Text(
          charter.isEmpty
              ? 'No charter yet — the model drafts one from the threads.'
              : charter,
          style: BondType.caption,
        ),
      ),
    );
  }

  Widget _charterField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _charter,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          style: BondType.caption,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: BondSpacing.s4),
          ),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(
          'Saving pins this description and hunts for matching threads. '
          'Clearing it lets the model redraft.',
          style: BondType.caption,
        ),
        Row(
          children: [
            TextButton(
              onPressed: () {
                // Untrimmed on purpose: the service owns what an empty
                // charter means, and a field wiped to whitespace is a
                // deliberate clear rather than an edit to reject here.
                widget.onSetCharter(_charter.text);
                setState(() => _editingCharter = false);
              },
              child: const Text('Save'),
            ),
            TextButton(
              onPressed: () => setState(() => _editingCharter = false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  /// The member threads and the reason each one is here. Collapsed by default:
  /// it is an explanation, and the episodes are what the user came for.
  ///
  /// Read-only. Removing a thread lives on its episode card, beside the
  /// messages that show whether it belongs — a list of subjects is not enough
  /// to judge that on.
  ///
  /// The one place the grouping explains itself. A user who cannot see why two
  /// threads were put together has no way to tell a good group from a bad one,
  /// and a feature that cannot be checked is a feature that gets turned off.
  Widget _memberStrip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        0,
        BondSpacing.s16,
        BondSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final member in widget.members)
            Padding(
              padding: const EdgeInsets.only(bottom: BondSpacing.s4),
              child: _memberEntry(member),
            ),
        ],
      ),
    );
  }

  Widget _memberEntry(StorylineMember member) {
    return Container(
      constraints: const BoxConstraints(
        maxWidth: StorylineTimelinePanel._entryMaxWidth,
      ),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s8,
        vertical: BondSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _labelFor(member.source, member.conversationKey),
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            member.addedByUser
                ? 'You added this.'
                : (member.evidence?.isNotEmpty == true
                    ? member.evidence!
                    : 'Grouped automatically.'),
            style: BondType.caption,
          ),
        ],
      ),
    );
  }

  /// A null [onPressed] is the row's inert state — the button stays where it
  /// is and stops answering, which is what a label like 'Syncing…' needs.
  Widget _quietButton(String label, VoidCallback? onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: BondType.caption.copyWith(
        color: BondColors.primary,
        fontWeight: FontWeight.w600,
      )),
    );
  }
}
