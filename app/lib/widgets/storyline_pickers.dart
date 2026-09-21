import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../theme/tokens.dart';
import 'pane_surface.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// The two panes that stand where a storyline picker dialog would.
///
/// The house rule is screens with a way back, never popups: a choice made out
/// of a whole mailbox needs room, a filter and somewhere to look, and none of
/// that fits in a menu. Both panes wear [PaneSurface], the header every full
/// pane shares, so they read as the main pane changing rather than as
/// something laid over it.
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

    // No Home link: this pane is one click deep from the storyline it serves,
    // and Back is the whole way out. See [PaneSurface.onHome].
    return PaneSurface(
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
  static const Key titleKey = ValueKey('storyline-create-title');
  static const Key charterKey = ValueKey('storyline-create-charter');
  static const Key createKey = ValueKey('storyline-create');

  /// The storylines that can take the thread, stripped only of the ones it is
  /// already in. Suggestions are on offer here: filing a thread into one is
  /// accepting it.
  final List<Storyline> choices;

  final VoidCallback onBack;
  final void Function(String storylineId) onPick;
  final void Function(String title) onCreate;

  /// The same create with the charter the user typed beside the name. Separate
  /// from [onCreate] rather than widening it, so every caller that has no
  /// charter to give keeps the ending it had; when this is null the pane still
  /// creates, it just creates without one.
  final void Function(String title, String charter)? onCreateWithCharter;

  const AddToStorylinePane({
    super.key,
    required this.choices,
    required this.onBack,
    required this.onPick,
    required this.onCreate,
    this.onCreateWithCharter,
  });

  @override
  State<AddToStorylinePane> createState() => _AddToStorylinePaneState();
}

class _AddToStorylinePaneState extends State<AddToStorylinePane> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _charter = TextEditingController();

  String _typed = '';
  String _typedCharter = '';

  @override
  void dispose() {
    _title.dispose();
    _charter.dispose();
    super.dispose();
  }

  /// The name alone is enough. A charter makes the new storyline go hunting for
  /// the threads this one is only the first of, but a person who just wants a
  /// place to put this thread should not have to describe it first.
  void _create(String title, String charter) {
    final withCharter = widget.onCreateWithCharter;
    if (charter.isNotEmpty && withCharter != null) {
      withCharter(title, charter);
      return;
    }
    widget.onCreate(title);
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _typed.trim();
    final trimmedCharter = _typedCharter.trim();

    return PaneSurface(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: AddToStorylinePane.titleKey,
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
                      key: AddToStorylinePane.createKey,
                      onPressed: trimmed.isEmpty
                          ? null
                          : () => _create(trimmed, trimmedCharter),
                      child: const Text('Create'),
                    ),
                  ],
                ),
                const SizedBox(height: BondSpacing.s8),
                // Dead when the host gave no charter door. A field that took
                // the text and then dropped it on Create would be worse than
                // no field: the user would believe they had said what belongs
                // here, and nothing would ever hunt on it.
                TextField(
                  key: AddToStorylinePane.charterKey,
                  controller: _charter,
                  style: BondType.small,
                  maxLines: 2,
                  enabled: widget.onCreateWithCharter != null,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'What belongs here',
                  ),
                  onChanged: (value) =>
                      setState(() => _typedCharter = value),
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

/// A storyline declared out of nothing: a name and a description of what
/// belongs in it, with no thread to hang it on.
///
/// The charter is required here and optional on [AddToStorylinePane], and the
/// difference is what each pane starts with. A create from a thread already
/// has a member, so it is a storyline whether or not anything is ever recruited
/// into it. A declared one has nothing at all, and the charter is the only
/// thing the recruit can hunt with, so a declared storyline with no charter
/// would be an empty list that stays empty.
class NewStorylinePane extends StatefulWidget {
  static const Key titleKey = ValueKey('storyline-new-title');
  static const Key charterKey = ValueKey('storyline-new-charter');
  static const Key createKey = ValueKey('storyline-new-create');

  /// The pane's own key, which is how a caller scopes [PaneSurface]'s Back
  /// arrow to this pane. The arrow is built inside the surface and carries no
  /// key of its own; the house idiom finds it by its `Back` tooltip, and this
  /// says which pane's.
  static const Key paneKey = ValueKey('storyline-new-back');

  final VoidCallback onBack;
  final void Function(String title, String charter) onCreate;

  const NewStorylinePane({
    super.key,
    required this.onBack,
    required this.onCreate,
  });

  @override
  State<NewStorylinePane> createState() => _NewStorylinePaneState();
}

class _NewStorylinePaneState extends State<NewStorylinePane> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _charter = TextEditingController();

  String _typedTitle = '';
  String _typedCharter = '';

  @override
  void dispose() {
    _title.dispose();
    _charter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _typedTitle.trim();
    final charter = _typedCharter.trim();
    final ready = title.isNotEmpty && charter.isNotEmpty;

    return PaneSurface(
      key: NewStorylinePane.paneKey,
      title: 'New storyline',
      onBack: widget.onBack,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          BondSpacing.s16,
          BondSpacing.s12,
          BondSpacing.s16,
          BondSpacing.s12,
        ),
        children: [
          Text('Title', style: BondType.caption),
          const SizedBox(height: BondSpacing.s4),
          TextField(
            key: NewStorylinePane.titleKey,
            controller: _title,
            style: BondType.small,
            decoration: const InputDecoration(isDense: true),
            onChanged: (value) => setState(() => _typedTitle = value),
          ),
          const SizedBox(height: BondSpacing.s12),
          Text('What belongs here', style: BondType.caption),
          const SizedBox(height: BondSpacing.s4),
          TextField(
            key: NewStorylinePane.charterKey,
            controller: _charter,
            style: BondType.small,
            maxLines: 3,
            decoration: const InputDecoration(isDense: true),
            onChanged: (value) => setState(() => _typedCharter = value),
          ),
          const SizedBox(height: BondSpacing.s12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: NewStorylinePane.createKey,
              onPressed: ready ? () => widget.onCreate(title, charter) : null,
              child: const Text('Create'),
            ),
          ),
        ],
      ),
    );
  }
}

