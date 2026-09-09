import 'dart:async';

import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/message_models.dart';
import '../models/open_asks.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
import 'attachment_documents_strip.dart';
import 'inline_alert.dart';
import 'pinned_documents_bar.dart';
import 'room_header.dart';
import 'source_glyph.dart';
import 'storyline_blocks_section.dart';
import 'time_format.dart';

/// What the storyline's body is showing. Three tabs and not three folds: the
/// old header opened each of them ON TOP of the spine, so a user reading the
/// files was also, still, looking at the episodes — and every fold pushed the
/// thing they came for further down the pane.
enum StorylineTab { messages, files, about }

/// One storyline as a spine of thread episodes, newest at the bottom.
///
/// Each member thread is ONE card rather than a run of messages spliced into a
/// merged transcript: a storyline is several conversations, and interleaving
/// them by timestamp made the reader reassemble each one in their head.
///
/// A card is a root message and not a drawer: it says what the thread is, what
/// it wants and how much of it there is, and a tap opens the thread itself
/// beside the spine. Cards used to expand in place, which gave the app two
/// ways to read the same conversation — one of them without a header, an
/// overflow menu or anywhere to reply from. There is one way now, and the
/// thread that opens beside carries its own composer, so a reply is addressed
/// to exactly one conversation.
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

  /// Displays the spine newest card first. A reading direction and nothing
  /// more — every card says the same thing whichever end it is read from.
  final bool newestFirst;

  final VoidCallback onToggleSort;

  /// Retires the storyline. The host decides what that leaves on screen — this
  /// panel is one of the things it takes away.
  final VoidCallback onDismiss;

  /// A card was tapped: open that thread beside the spine. Required, because a
  /// card that opens nothing is a headline the reader cannot follow — and the
  /// thread it opens is where the reply, the files and the whole transcript
  /// are.
  final void Function(StorylineEpisode episode) onOpenEpisode;

  /// The same action the overview's Sync runs: the ordinary two-connector
  /// pull, whose tail heals the refreshes and recaps the storylines were owed.
  /// Asking for mail from this screen is asking for this storyline to be
  /// brought up to date.
  final Future<void> Function() onSync;

  /// Whether that pull is running right now. The flag rides in rather than
  /// living here because the panel is pure: the screen owns the sync, and it
  /// is the same sync the overview's button is already holding a label up for.
  final bool syncing;

  /// Every document on this storyline — the files on its member threads, the
  /// pinned ones first — for the shelf behind the Documents button. Empty is
  /// the ordinary state and renders an explanation, not a gap: a storyline
  /// whose threads carry no files has to say so.
  final List<AttachmentRef> documents;

  /// A document on the shelf was tapped. Null leaves the entries inert.
  final void Function(AttachmentRef attachment)? onOpenDocument;

  /// Null renders a shelf nothing can be pinned from — see
  /// [AttachmentDocumentsStrip.onPin].
  final void Function(AttachmentRef attachment)? onPinDocument;

  /// Null renders a read-only shelf: the entries are there, the two-step
  /// Remove is not.
  final void Function(AttachmentRef attachment)? onUnpinDocument;

  /// The threads somebody took out of this storyline — the owner's own and
  /// the re-check pass's — for the two lists at the head of Messages. Empty is
  /// the ordinary state and renders no headings at all.
  final List<StorylineBlock> blocks;

  /// Lifts the veto on one blocked thread without filing it back: the model
  /// may decide for itself, next time a pass looks at it. Null leaves the
  /// button inert.
  final void Function(String source, String conversationKey)? onUnblockThread;

  /// Files a blocked thread back in by hand, which clears its block whichever
  /// pass wrote it. Null leaves the button inert.
  final void Function(String source, String conversationKey)? onAddBackThread;

  /// Re-judges the threads the model filed here. Null leaves the button inert.
  final VoidCallback? onAudit;

  /// True while a re-check this owner asked for is still in the worker. Passed
  /// straight through to the section, which is where the running label and the
  /// inert button live.
  final bool auditing;

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
    required this.onOpenEpisode,
    required this.onAddThread,
    required this.newestFirst,
    required this.onToggleSort,
    required this.onDismiss,
    required this.onSync,
    required this.syncing,
    this.documents = const [],
    this.onOpenDocument,
    this.onPinDocument,
    this.onUnpinDocument,
    this.blocks = const [],
    this.onUnblockThread,
    this.onAddBackThread,
    this.onAudit,
    this.auditing = false,
  });

  static const Key documentsStripKey = ValueKey('storyline-documents-strip');

  /// The About tab's explicit way into the charter field. The sentence itself
  /// is still tappable — two doors, one action — but a sentence that looks
  /// like prose is not an invitation, and this is the one that says so.
  static const Key charterEditKey = ValueKey('storyline-charter-edit');

  /// One episode card's evidence line, keyed by source AND key because two
  /// connectors can carry one conversation key.
  static Key evidenceKeyFor(String source, String key) =>
      Key('storyline-evidence-$source-$key');

  /// Matches the thread panel: wide enough for a long paragraph, narrow enough
  /// that an ultrawide window does not turn every message into one line.
  static const double _maxContentWidth = 900;

  @override
  State<StorylineTimelinePanel> createState() => _StorylineTimelinePanelState();
}

class _StorylineTimelinePanelState extends State<StorylineTimelinePanel> {
  /// Messages is where a storyline opens: the catch-up and the spine are what
  /// the user came for, and the other two tabs are reference.
  StorylineTab _tab = StorylineTab.messages;

  /// Whether the recap paragraph is showing all of itself. Clamped by default
  /// because it is a pinned topic and not the reading — a six-line catch-up
  /// above the spine is a header nobody scrolls past.
  bool _recapExpanded = false;

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

  /// Why this thread is in the storyline, in the words that were recorded when
  /// it was filed — `'Filed by you'` for a hand-filed member, the model's own
  /// sentence for an automatic one, and null for an automatic row that has
  /// none. "Grouped automatically." was filler and said nothing.
  ///
  /// Keyed by source AND key: two connectors can carry the same conversation
  /// key, and a lookup on the key alone would put one connector's reason on
  /// the other connector's card.
  String? _evidenceFor(StorylineEpisode episode) {
    for (final member in widget.members) {
      if ('${member.source}\n${member.conversationKey}' != episode.threadKey) {
        continue;
      }
      // The same words the store writes as a user row's evidence, and the same
      // words a block copied off one shows: one spelling for one fact.
      if (member.addedByUser) return 'Filed by you';
      final evidence = member.evidence ?? '';
      return evidence.isEmpty ? null : evidence;
    }
    return null;
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
          if (_confirmingDismiss) _dismissRow(),
          const Divider(height: 1, color: BondColors.border),
          Expanded(
            child: switch (_tab) {
              StorylineTab.messages => _messagesTab(displayed),
              StorylineTab.files => _filesTab(),
              StorylineTab.about => _aboutTab(),
            },
          ),
        ],
      ),
    );
  }

  /// The catch-up, what has been pinned, and the spine — in that order,
  /// because that is the order a colleague would answer "where are we" in.
  ///
  /// The recap and the pins scroll WITH the episodes rather than sitting above
  /// them in fixed chrome: they are the top of the reading, not a lid on it.
  Widget _messagesTab(List<StorylineEpisode> displayed) {
    final storyline = widget.storyline;
    final summary = storyline.summary ?? '';
    final recap = storyline.recapText ?? '';
    final pinned = [
      for (final document in widget.documents)
        if (document.pinnedStorylineId == storyline.id) document,
    ];

    return Align(
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
            // The recap REPLACES the one-line summary rather than stacking over
            // it: they answer the same question at different lengths, and the
            // long answer is what this screen is for. The summary is still what
            // the rail and the overview cards show, and it is what stands here
            // until the recap pass has written one.
            if (recap.isNotEmpty)
              _recapBlock(storyline, recap)
            else if (summary.isNotEmpty)
              Text(
                summary,
                style: BondType.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            if (pinned.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: BondSpacing.s8),
                child: PinnedDocumentsBar(
                  documents: pinned,
                  onOpen: widget.onOpenDocument,
                ),
              ),
            // The re-check and the removed threads lead the spine they are
            // about, above the first card and under a rule of their own. They
            // were at the foot first, and the foot of a long spine is where
            // nobody looks; a reference tab is not where they would go either.
            const SizedBox(height: BondSpacing.s12),
            StorylineBlocksSection(
              blocks: widget.blocks,
              onUnblockThread: widget.onUnblockThread,
              onAddBackThread: widget.onAddBackThread,
              onAudit: widget.onAudit,
              auditing: widget.auditing,
            ),
            const SizedBox(height: BondSpacing.s12),
            const Divider(height: 1, color: BondColors.border),
            const SizedBox(height: BondSpacing.s12),
            for (final episode in displayed) _episodeCard(episode),
            // Last rather than instead: a storyline whose threads were all
            // removed still has a recap and its pins, and saying "no messages"
            // by hiding them would be answering a different question.
            if (widget.episodes.isEmpty)
              Center(
                child: Text('No messages in this storyline.',
                    style: BondType.small),
              ),
          ],
        ),
      ),
    );
  }

  /// Every file on the storyline, pinned or not — the shelf, whole.
  Widget _filesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(BondSpacing.s16),
      child: AttachmentDocumentsStrip(
        key: StorylineTimelinePanel.documentsStripKey,
        documents: widget.documents,
        // The storyline's own id rides in so an entry can tell a pin to THIS
        // storyline from a pin to another one.
        storylineId: widget.storyline.id,
        onOpen: (attachment) => widget.onOpenDocument?.call(attachment),
        onPin: widget.onPinDocument,
        onUnpin: widget.onUnpinDocument,
      ),
    );
  }

  /// What this storyline is for: the charter, and nothing else.
  ///
  /// The membership used to be listed here too, which said the same thing
  /// twice — the spine on Messages already names every thread, one card each.
  /// The reason a thread is here now reads on its own card, where the thread
  /// is; this tab is the rule, and the spine is what the rule caught.
  Widget _aboutTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s12,
        BondSpacing.s16,
        BondSpacing.s24,
      ),
      child: _aboutBlock(),
    );
  }

  /// The question the Dismiss menu item asks, and both answers. It stands
  /// under the header rather than inside the menu: a two-step that lived in a
  /// popup would ask its second question somewhere the first answer is no
  /// longer visible.
  Widget _dismissRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        0,
        BondSpacing.s16,
        BondSpacing.s12,
      ),
      child: Row(
        children: [
          Flexible(
            child: Text('Dismiss this storyline?', style: BondType.caption),
          ),
          _quietButton('Dismiss storyline', widget.onDismiss),
          _quietButton(
            'Cancel',
            () => setState(() => _confirmingDismiss = false),
          ),
        ],
      ),
    );
  }

  /// One member thread as a root message: what it is, what it is waiting for,
  /// and how much of it there is. The whole card is the tap target and it
  /// opens the thread beside the spine, which is where the transcript, the
  /// files and the reply box actually are.
  Widget _episodeCard(StorylineEpisode episode) {
    final count = episode.messages.length;
    // A chat's messages carry no subject — Graph does not give them one — so
    // an episode built out of them has none either. Named by who is on it
    // instead, the way a chat is named everywhere else: a storyline holding
    // two chats must not put two identical '(no subject)' cards on the spine.
    final named = episode.subject.isEmpty
        ? episode.participants.join(', ')
        : episode.subject;
    // The count is not repeated here: it is the card's own affordance line
    // below, where it is also the promise of what opening the card gives you.
    // Nor are the participants, where they are already the title.
    final meta = [
      if (episode.subject.isNotEmpty && episode.participants.isNotEmpty)
        episode.participants.join(', '),
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
    // the count says so — the thread that opens beside is where they are read.
    final openAsks = openAskCount(
      episode.messages,
      conversationClosed: episode.state != ConversationState.needsReply,
    );

    final preview = _previewOf(episode);

    // The one place the grouping explains itself, moved onto the card it
    // explains. A user who cannot see why two threads were put together has no
    // way to tell a good group from a bad one, and a feature that cannot be
    // checked is a feature that gets turned off.
    final evidence = _evidenceFor(episode);

    // A Material under the InkWell rather than a decorated Container alone:
    // ink paints on the nearest Material ancestor, and the card's own opaque
    // surface would otherwise hide the splash of the tap that opens it.
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s12),
      child: Material(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        child: InkWell(
          onTap: () => widget.onOpenEpisode(episode),
          borderRadius: BondRadii.mdAll,
          child: Container(
            padding: const EdgeInsets.all(BondSpacing.s12),
            decoration: BoxDecoration(
              borderRadius: BondRadii.mdAll,
              border: Border.all(color: BondColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            // The source is marked on EVERY card, mail
                            // included: a storyline merges threads and chats,
                            // and marking only the exception leaves the reader
                            // guessing what the unmarked ones were.
                            '${sourceChipPrefix(episode.source)}'
                            '${named.isEmpty ? '(no subject)' : named}',
                            style: BondType.body
                                .copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              meta,
                              style: BondType.caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          if (evidence != null) ...[
                            const SizedBox(height: 2),
                            // One line, elided, with the whole sentence on the
                            // hover: it is the reason the thread is here, not
                            // the thread itself, and a card that spent three
                            // lines on it would bury the spine.
                            Tooltip(
                              message: evidence,
                              child: Text(
                                evidence,
                                key: StorylineTimelinePanel.evidenceKeyFor(
                                  episode.source,
                                  episode.conversationKey,
                                ),
                                style: BondType.caption.copyWith(
                                  color: BondColors.inkMuted,
                                  fontStyle: FontStyle.italic,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          // The ask replaces the summary rather than stacking
                          // above it: they are the same fact in two moods, and
                          // a card that spent four lines saying it twice would
                          // crowd the spine.
                          if (showCta) ...[
                            const SizedBox(height: BondSpacing.s4),
                            _cardCta(
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
                    // The two-step stands where a confirm dialog would: the
                    // first tap asks, the second takes the thread out. Both
                    // icons give way to the pair, so the card reads as one
                    // question rather than a question next to an unrelated
                    // button.
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
                      // Beside the card's own tap, which opens the thread in
                      // the side panel: this one hands it the whole main pane.
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
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: BondSpacing.s8),
                  Text(
                    preview,
                    style: BondType.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: BondSpacing.s8),
                Text(
                  '$count ${count == 1 ? 'message' : 'messages'} · open \u203a',
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The ask on a card. [tooltip] stays the bare ask: it exists to show the
  /// full text [text] had to clamp.
  ///
  /// It takes no tap of its own any more. The whole card opens the thread the
  /// ask is in, and that thread has the reply box the banner used to reach —
  /// so there is nothing left here for a nested target to mean.
  Widget _cardCta(String tooltip, String text) {
    return Tooltip(
      message: tooltip,
      child: InlineAlert(
        severity: InlineAlertSeverity.attention,
        text: text,
        maxLines: 2,
      ),
    );
  }

  /// What the card shows of the thread: the newest message, and nothing at all
  /// when that message has no text to show yet.
  String _previewOf(StorylineEpisode episode) {
    if (episode.messages.isEmpty) return '';
    final message = episode.messages.last;
    return (message.bodyPreview?.isNotEmpty == true
            ? message.bodyPreview!
            : (message.bodyText ?? ''))
        .trim();
  }

  /// The storyline's identity and what can be done to it. Everything that used
  /// to be a quiet button in a two-line Wrap is now a tab (what the body is
  /// showing), a header action (Add thread) or a ⋯ item (sort, sync, dismiss).
  ///
  /// The recap left the header with the folds: it is the Messages tab's first
  /// block now, the pinned topic at the top of the reading rather than a
  /// paragraph wedged between a title and a row of buttons.
  Widget _header() {
    final members = widget.members.length;
    return RoomHeader<StorylineTab>(
      leading: Text(
        '#',
        style: BondType.titleSm.copyWith(color: BondColors.inkMuted),
      ),
      title: _titleField(widget.storyline),
      subtitle: '$members ${members == 1 ? 'thread' : 'threads'} \u00b7 '
          '${widget.storyline.openCount} open',
      onBack: widget.onBack,
      actions: [
        RoomAction(
          icon: Icons.add,
          label: 'Add thread',
          onTap: widget.onAddThread,
        ),
      ],
      moreItems: [
        // A menu item says what it DOES; the old button named the order the
        // spine was already in, which read as a statement you could not act on.
        RoomMenuItem(
          value: 'sort',
          label: widget.newestFirst ? 'Oldest first' : 'Newest first',
          onTap: widget.onToggleSort,
        ),
        // The only item here that is not about this storyline in particular. A
        // running pull says so and takes no second tap — the screen holds the
        // flag, so the label is the one the overview is already showing.
        RoomMenuItem(
          value: 'sync',
          label: widget.syncing ? 'Syncing…' : 'Sync',
          onTap: widget.syncing ? null : () => unawaited(widget.onSync()),
        ),
        RoomMenuItem(
          value: 'dismiss',
          label: 'Dismiss…',
          onTap: () => setState(() => _confirmingDismiss = true),
          dividerBefore: true,
        ),
      ],
      tabs: StorylineTab.values,
      selectedTab: _tab,
      tabLabel: (tab) => switch (tab) {
        StorylineTab.messages => 'Messages',
        // The count is the label, the way the threads subtitle reads: a
        // storyline with no documents should not need a tap to find that out.
        StorylineTab.files => widget.documents.isEmpty
            ? 'Files'
            : 'Files (${widget.documents.length})',
        StorylineTab.about => 'About',
      },
      onTab: (tab) => setState(() => _tab = tab),
    );
  }

  /// Roughly what two lines of body type hold at this pane's width. A
  /// character count and not a measured overflow: the toggle has to be there
  /// on the first frame, before anything has been laid out.
  static const int _recapClampChars = 160;

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
            Text(
              recap,
              style: BondType.body,
              maxLines: _recapExpanded ? null : 2,
              overflow: _recapExpanded ? null : TextOverflow.ellipsis,
            ),
            // Only where there is something behind the clamp. The idiom is the
            // counted headings' — a tappable line of label type — and not a
            // button, because unfolding a paragraph is reading rather than an
            // action on the storyline.
            if (recap.length > _recapClampChars || recap.contains('\n'))
              InkWell(
                onTap: () => setState(() => _recapExpanded = !_recapExpanded),
                borderRadius: BondRadii.smAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _recapExpanded ? 'Show less' : 'Show more',
                    style: BondType.label,
                  ),
                ),
              ),
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

    // No padding of its own: the About tab spends the margins, and a block that
    // also spent them would inset twice.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('CHARTER', style: BondType.label),
            const Spacer(),
            // The sentence below is tappable and always was, but a sentence
            // that reads as prose is not an invitation. This is the door that
            // says so.
            if (!_editingCharter)
              _quietButton(
                'Edit',
                () => _startEditingCharter(charter),
                key: StorylineTimelinePanel.charterEditKey,
              ),
          ],
        ),
        _editingCharter ? _charterField() : _charterText(charter),
        // What editing it is FOR. The field carries its own caption about
        // saving, so this one only stands while the sentence is being read.
        if (!_editingCharter)
          Text(
            'What belongs in this storyline, in a sentence. Edit it to narrow '
            'or widen the group — saving pins it and hunts for matching '
            'threads.',
            style: BondType.caption,
          ),
        // Not while the field is open: offering to replace a sentence the user
        // is in the middle of writing is offering to throw their work away, and
        // the field is where they would be typing the answer to this suggestion
        // anyway.
        if (!_editingCharter && suggestion.isNotEmpty)
          _suggestionBlock(suggestion),
      ],
    );
  }

  /// Opens the charter field on [charter]. Shared by the Edit button and the
  /// sentence's own tap: two doors, one action, and one place that decides
  /// what the field opens holding.
  void _startEditingCharter(String charter) {
    setState(() {
      _charter.text = charter;
      _editingCharter = true;
    });
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
      onTap: () => _startEditingCharter(charter),
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

  /// A null [onPressed] is the row's inert state — the button stays where it
  /// is and stops answering, which is what a label like 'Syncing…' needs.
  Widget _quietButton(String label, VoidCallback? onPressed, {Key? key}) {
    return TextButton(
      key: key,
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
