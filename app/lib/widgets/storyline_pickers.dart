import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// The two panes that stand where a storyline picker dialog would.
///
/// The house rule is screens with a way back, never popups: a choice made out
/// of a whole mailbox needs room, a filter and somewhere to look, and none of
/// that fits in a menu. Both panes borrow the timeline panel's surface so they
/// read as the main pane changing rather than as something laid over it.
///
/// Pure widgets: everything they show and everything they do arrives through
/// the constructor, so the screen stays the only layer that knows what a
/// provider is.

/// Which conversation joins this storyline.
class AddThreadToStorylinePane extends StatefulWidget {
  final String storylineTitle;

  /// The threads that could join, already stripped of members and of the ones
  /// the user removed before, and already in the order to show them in.
  final List<Conversation> candidates;

  final VoidCallback onBack;
  final void Function(Conversation conversation) onPick;

  const AddThreadToStorylinePane({
    super.key,
    required this.storylineTitle,
    required this.candidates,
    required this.onBack,
    required this.onPick,
  });

  @override
  State<AddThreadToStorylinePane> createState() =>
      _AddThreadToStorylinePaneState();
}

class _AddThreadToStorylinePaneState extends State<AddThreadToStorylinePane> {
  final TextEditingController _filter = TextEditingController();

  String _query = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Subject OR any participant: the user looking for a thread remembers one
  /// or the other, and rarely which.
  List<Conversation> _matches() {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.candidates;
    return [
      for (final c in widget.candidates)
        if ((c.subject ?? '').toLowerCase().contains(query) ||
            c.participants
                .any((p) => p.display.toLowerCase().contains(query)))
          c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches();

    return _PaneSurface(
      title: 'Add a thread to ${widget.storylineTitle}',
      onBack: widget.onBack,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              BondSpacing.s16,
              BondSpacing.s12,
              BondSpacing.s16,
              BondSpacing.s8,
            ),
            child: TextField(
              controller: _filter,
              style: BondType.small,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Filter by subject or person',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? Center(
                    child: Text('No threads to add.', style: BondType.small),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: BondSpacing.s12),
                    children: [
                      for (final conversation in matches)
                        _candidateRow(conversation),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _candidateRow(Conversation conversation) {
    final subject = conversation.subject?.isNotEmpty == true
        ? conversation.subject!
        : '(no subject)';
    final participants = conversation.participants
        .map((p) => p.display)
        .where((d) => d.isNotEmpty)
        .join(', ');
    final when = relativeTime(conversation.lastMessageAt, DateTime.now());

    return InkWell(
      onTap: () => widget.onPick(conversation),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s16,
          vertical: BondSpacing.s8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // A storyline holds chats and mail together, so a row that
                    // did not say which is which would leave the reader
                    // guessing — the same convention the seam chips use.
                    '${sourceChipPrefix(conversation.source)}$subject',
                    style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (participants.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      participants,
                      style: BondType.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (when != null) ...[
              const SizedBox(width: BondSpacing.s12),
              Text(when, style: BondType.caption),
            ],
          ],
        ),
      ),
    );
  }
}

/// Which storyline this thread joins — or the one it starts.
class AddToStorylinePane extends StatefulWidget {
  /// The storylines that can take the thread, stripped only of the ones it is
  /// already in. Suggestions are on offer here: filing a thread into one is
  /// accepting it.
  final List<Storyline> choices;

  final VoidCallback onBack;
  final void Function(String storylineId) onPick;
  final void Function(String title) onCreate;

  const AddToStorylinePane({
    super.key,
    required this.choices,
    required this.onBack,
    required this.onPick,
    required this.onCreate,
  });

  @override
  State<AddToStorylinePane> createState() => _AddToStorylinePaneState();
}

class _AddToStorylinePaneState extends State<AddToStorylinePane> {
  final TextEditingController _title = TextEditingController();

  String _typed = '';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _typed.trim();

    return _PaneSurface(
      title: 'Add to storyline',
      onBack: widget.onBack,
      child: ListView(
        padding: const EdgeInsets.only(bottom: BondSpacing.s12),
        children: [
          // The naming field lives in the pane rather than behind a dialog of
          // its own: this pane already IS the screen the house rule asks for,
          // and a second surface over it would be the popup it replaced.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              BondSpacing.s16,
              BondSpacing.s12,
              BondSpacing.s16,
              BondSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _title,
                    style: BondType.small,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Name a new storyline',
                    ),
                    onChanged: (value) => setState(() => _typed = value),
                  ),
                ),
                const SizedBox(width: BondSpacing.s8),
                TextButton(
                  onPressed:
                      trimmed.isEmpty ? null : () => widget.onCreate(trimmed),
                  child: const Text('Create'),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: BondColors.border),
          for (final storyline in widget.choices) _choiceRow(storyline),
        ],
      ),
    );
  }

  Widget _choiceRow(Storyline storyline) {
    final summary = storyline.summary ?? '';

    return InkWell(
      onTap: () => widget.onPick(storyline.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s16,
          vertical: BondSpacing.s8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              storyline.title.isEmpty ? '(untitled)' : storyline.title,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
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
    );
  }
}

/// The bordered surface and titled header both panes share with the timeline
/// panel, so a pane reads as the main pane changing rather than as an overlay.
class _PaneSurface extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final Widget child;

  const _PaneSurface({
    required this.title,
    required this.onBack,
    required this.child,
  });

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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BondSpacing.s16,
              vertical: BondSpacing.s12,
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                  iconSize: 20,
                  tooltip: 'Back',
                ),
                const SizedBox(width: BondSpacing.s4),
                Expanded(
                  child: Text(
                    title,
                    style: BondType.titleSm,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: BondColors.border),
          Expanded(child: child),
        ],
      ),
    );
  }
}
