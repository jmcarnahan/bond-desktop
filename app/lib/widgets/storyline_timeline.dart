import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
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

  const StorylineTimelinePanel({
    super.key,
    required this.storyline,
    required this.episodes,
    required this.members,
    required this.onBack,
    required this.onRename,
    required this.onSetCharter,
    required this.onRemoveThread,
    required this.onOpenThread,
    required this.onAddThread,
    required this.newestFirst,
    required this.onToggleSort,
    required this.onDismiss,
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
  bool _editingTitle = false;
  bool _editingCharter = false;
  bool _confirmingDismiss = false;

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
                children: _run(episode),
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
                  if (summary.isNotEmpty) ...[
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
              onPressed: () => widget.onRemoveThread(
                episode.source,
                episode.conversationKey,
              ),
              icon: const Icon(Icons.close),
              iconSize: 14,
              tooltip: 'Remove from storyline',
              padding: const EdgeInsets.all(BondSpacing.s4),
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
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

    for (final message in episode.messages) {
      final day = dayKeyOf(message);
      final label = formatDayLabel(message.receivedAt);
      if (label != null && (first || day != previousDay)) {
        items.add(DayDivider(label: label));
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

  Widget _header() {
    final storyline = widget.storyline;
    final summary = storyline.summary ?? '';

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
                if (summary.isNotEmpty) ...[
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
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        0,
        BondSpacing.s16,
        BondSpacing.s12,
      ),
      child: _editingCharter ? _charterField() : _charterText(charter),
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

  Widget _quietButton(String label, VoidCallback onPressed) {
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
