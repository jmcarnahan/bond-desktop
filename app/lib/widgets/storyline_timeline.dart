import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'message_row.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// One storyline as a single merged transcript.
///
/// The layout deliberately mirrors `thread_detail_panel.dart` — same bordered
/// surface, same header-then-divider-then-transcript column, same day dividers
/// and collapsed runs — because a storyline is meant to read as a thread that
/// happens to span several. The one thing it adds is a chip at each seam,
/// naming the thread the conversation just crossed into and offering a way
/// back to it.
class StorylineTimelinePanel extends StatefulWidget {
  final Storyline storyline;

  /// Every member thread's messages, already merged oldest-first.
  final List<Message> messages;

  /// `source_message_id` → `conversation_key`.
  ///
  /// A side table rather than a field on [Message]: the transcript has to know
  /// where one thread ends and the next begins, and the message model does not
  /// carry its thread's key. Keyed on the message id, which is unique within a
  /// source.
  final Map<String, String> keyByMessageId;

  /// `conversation_key` → the thread's stripped subject, for the seam chips
  /// and the member strip.
  final Map<String, String> subjectByKey;

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

  const StorylineTimelinePanel({
    super.key,
    required this.storyline,
    required this.messages,
    required this.keyByMessageId,
    required this.subjectByKey,
    required this.members,
    required this.onBack,
    required this.onRename,
    required this.onSetCharter,
    required this.onRemoveThread,
    required this.onOpenThread,
    required this.onAddThread,
  });

  /// Matches the thread panel: wide enough for a long paragraph, narrow enough
  /// that an ultrawide window does not turn every message into one line.
  static const double _maxContentWidth = 900;

  /// A seam chip carries a whole subject line, which can be arbitrarily long.
  static const double _chipMaxWidth = 320;

  @override
  State<StorylineTimelinePanel> createState() => _StorylineTimelinePanelState();
}

class _StorylineTimelinePanelState extends State<StorylineTimelinePanel> {
  /// Threads the user has un-ticked in the member strip. A local view filter
  /// only — nothing is written, and re-opening the storyline shows all of it
  /// again. Hiding a thread is how you read a storyline; removing one is how
  /// you correct it, and the two must not be the same gesture.
  final Set<String> _hidden = {};

  bool _showMembers = false;
  bool _showAbout = false;
  bool _editingTitle = false;
  bool _editingCharter = false;

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

  String _labelFor(String conversationKey) {
    final subject = widget.subjectByKey[conversationKey];
    if (subject != null && subject.isNotEmpty) return subject;
    return '(no subject)';
  }

  /// The transcript: day dividers, runs collapsed under one header, and a chip
  /// at every point the conversation crosses from one thread into another.
  ///
  /// A seam ALWAYS breaks the run, however close in time the two messages were
  /// and whoever sent them. Two threads a minute apart from the same person
  /// are the case this view exists to make legible, and collapsing them under
  /// one header would hide exactly that.
  List<Widget> _transcript() {
    final items = <Widget>[];
    String? previousDay;
    String? previousKey;
    Message? previous;
    var first = true;

    for (final message in widget.messages) {
      final key = widget.keyByMessageId[message.id] ?? '';
      if (_hidden.contains(key)) continue;

      final day = dayKeyOf(message);
      final label = formatDayLabel(message.receivedAt);
      if (label != null && (first || day != previousDay)) {
        items.add(DayDivider(label: label));
        previous = null;
      }
      previousDay = day;

      if (first || key != previousKey) {
        items.add(_seamChip(message.source, key));
        previous = null;
      }
      previousKey = key;
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

  /// Which thread the messages below came from, and a way into it. A filter
  /// pill rather than a heading: it is a target, and it should look like one.
  Widget _seamChip(String source, String conversationKey) {
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: StorylineTimelinePanel._chipMaxWidth,
          ),
          child: BondFilterPill(
            // Both sources are marked here, mail included: a storyline merges
            // threads and chats into one transcript, and a seam that only
            // named the exception would leave the reader guessing what the
            // unmarked ones were.
            label: '${sourceChipPrefix(source)}${_labelFor(conversationKey)}',
            selected: false,
            onTap: () => widget.onOpenThread(source, conversationKey),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            child: widget.messages.isEmpty
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

  /// The member threads, each with a visibility tick, the reason it is here
  /// and a way out of the storyline. Collapsed by default: it is a correction
  /// surface, and the transcript is what the user came for.
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
    final key = member.conversationKey;
    final visible = !_hidden.contains(key);

    return Container(
      constraints: const BoxConstraints(
        maxWidth: StorylineTimelinePanel._chipMaxWidth,
      ),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      padding: const EdgeInsets.only(left: BondSpacing.s4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: visible,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => setState(() {
                if (!_hidden.remove(key)) _hidden.add(key);
              }),
            ),
          ),
          const SizedBox(width: BondSpacing.s4),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _labelFor(key),
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
          ),
          IconButton(
            onPressed: () => widget.onRemoveThread(member.source, key),
            icon: const Icon(Icons.close),
            iconSize: 14,
            tooltip: 'Remove from storyline',
            padding: const EdgeInsets.all(BondSpacing.s4),
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
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
