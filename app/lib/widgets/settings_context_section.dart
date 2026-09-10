import 'package:flutter/material.dart';

import '../providers/context_provider.dart' show ContextDirRow;
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'settings_section.dart';
import 'time_format.dart' show relativeTime;

/// The library of local directories the model may read, as one section of the
/// settings screen.
///
/// Its own widget in the [MicrosoftConnectionSection] shape rather than
/// another `_section(...)` on a screen that is already thirteen hundred
/// lines: it owns state of its own — which row is asking a second time about
/// Remove, and whether the open panel is out — and its collapsed summary is
/// built from the rows it renders, so the summary lives beside them.
///
/// Prop-only, reaching for no providers itself. Every write goes back out
/// through a callback to `ContextDirectoriesActions`, so a test drives the
/// whole section with a list of records and six closures.
class ContextDirectoriesSection extends StatefulWidget {
  /// The section's name, as the screen's open-set and every test spell it.
  static const String title = 'Context directories';

  /// One row per registered directory, in the store's order.
  final List<ContextDirRow> rows;

  /// Whether the first read of the library is still out. The rows keep
  /// rendering while it is — Riverpod carries the previous value through a
  /// reload, and a section that emptied itself on every recorded activity
  /// event would flicker once a second during a sync.
  final bool loading;

  /// A sentence about a library that could not be read at all. Null is the
  /// ordinary case.
  final String? error;

  /// Opens the folder panel and registers what comes back. Awaited by the
  /// button, which reads `Adding…` and goes inert until the panel is closed
  /// and the row is in the database — the same contract Refresh now keeps on
  /// Sync & data. Null hides the button.
  final Future<void> Function()? onAdd;

  /// Forces a read of one directory now.
  final void Function(String id) onReread;

  /// Forgets one directory — its index and its links, never the folder.
  final void Function(String id) onRemove;

  /// Whether each changed file in this directory earns a digest.
  final void Function(String id, bool on) onDigestsChanged;

  /// The stored `honor_gitignore` value, NOT the switch position. The control
  /// is labelled **Read ignored files**, which is the opposite question, and
  /// this widget does that inversion so nothing above it has to remember to.
  final void Function(String id, bool on) onHonorGitignoreChanged;

  /// The clock the relative times are measured against. Passed rather than
  /// read from [DateTime.now] so a test can pin it and assert an exact
  /// string.
  final DateTime Function() now;

  /// Whether a draft that reads one of these directories may spend one extra
  /// fast call picking two sections to read in full first.
  ///
  /// A prop and no local state: the host watches the preference and rebuilds,
  /// so what this switch shows is always what is stored rather than what was
  /// last tapped.
  final bool selectExpand;

  /// Null hides the switch — a host that cannot write the preference must not
  /// offer a control that does nothing.
  final void Function(bool on)? onSelectExpandChanged;

  /// Whether the screen currently has this section open. The screen owns the
  /// open-set — see the [SettingsSection] doc — so this arrives as a prop.
  final bool expanded;

  final VoidCallback onToggle;

  const ContextDirectoriesSection({
    super.key,
    required this.rows,
    required this.expanded,
    required this.onToggle,
    required this.onReread,
    required this.onRemove,
    required this.onDigestsChanged,
    required this.onHonorGitignoreChanged,
    required this.now,
    this.loading = false,
    this.error,
    this.onAdd,
    this.selectExpand = true,
    this.onSelectExpandChanged,
  });

  static const Key addKey = ValueKey('context-dirs-add');

  static const Key selectExpandKey = ValueKey('context-dirs-select-expand');

  static ValueKey<String> rowKeyFor(String id) => ValueKey('context-dir-$id');

  static ValueKey<String> aboutKeyFor(String id) =>
      ValueKey('context-dir-about-$id');

  static ValueKey<String> rereadKeyFor(String id) =>
      ValueKey('context-dir-reread-$id');

  static ValueKey<String> digestsKeyFor(String id) =>
      ValueKey('context-dir-digests-$id');

  static ValueKey<String> ignoredKeyFor(String id) =>
      ValueKey('context-dir-ignored-$id');

  static ValueKey<String> removeKeyFor(String id) =>
      ValueKey('context-dir-remove-$id');

  static ValueKey<String> confirmRemoveKeyFor(String id) =>
      ValueKey('context-dir-remove-confirm-$id');

  static ValueKey<String> keepKeyFor(String id) =>
      ValueKey('context-dir-keep-$id');

  @override
  State<ContextDirectoriesSection> createState() =>
      _ContextDirectoriesSectionState();
}

class _ContextDirectoriesSectionState extends State<ContextDirectoriesSection> {
  /// Which row is asking a second time about Remove, by directory id — never
  /// an index, which moves the moment the library is re-read.
  String? _confirming;

  /// Whether the open panel is out. One flag for the whole section: the
  /// panel is modal to the app, so two Adds cannot be in flight at once.
  bool _adding = false;

  @override
  void didUpdateWidget(ContextDirectoriesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A row that has gone — removed here, or dropped by a re-read that found
    // it deleted — must not leave the section holding an armed confirmation
    // for an id nothing renders. The next Remove would then arrive already
    // confirmed.
    final confirming = _confirming;
    if (confirming != null &&
        !widget.rows.any((row) => row.dir.id == confirming)) {
      _confirming = null;
    }
  }

  @override
  Widget build(BuildContext context) => SettingsSection(
        title: ContextDirectoriesSection.title,
        summary: summaryOf(widget.rows),
        expanded: widget.expanded,
        onToggle: widget.onToggle,
        body: _body(),
      );

  /// `No directories yet` / `1 directory · 12 files` / `2 directories · 40
  /// files`.
  ///
  /// The file count is summed over the rows rather than counted from the
  /// index, because it is the answer to "how much of my project is in here"
  /// and a directory still reading contributes the files its last walk found.
  static String summaryOf(List<ContextDirRow> rows) {
    if (rows.isEmpty) return 'No directories yet';
    final files = rows.fold<int>(0, (sum, row) => sum + row.dir.filesCount);
    final dirs = rows.length == 1 ? '1 directory' : '${rows.length} directories';
    return '$dirs · ${_plural(files, 'file')}';
  }

  static String _plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

  Widget _body() {
    final now = widget.now();
    final error = widget.error;
    final onAdd = widget.onAdd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'A folder the model may read when it drafts a reply — a Claude Code '
          'project, notes, documents. It is re-read on every sync, so what you '
          'change shows up in the next suggestion.',
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
        if (widget.onSelectExpandChanged case final onChanged?)
          SwitchListTile(
            key: ContextDirectoriesSection.selectExpandKey,
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: widget.selectExpand,
            title: Text(
              'Let the model pick two sections to read in full before '
              'drafting',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'One extra fast call per suggestion that reads a directory. '
              'Off, a reply sees only the nearest passages.',
              style: BondType.caption,
            ),
            onChanged: onChanged,
          ),
        if (error != null) ...[
          const SizedBox(height: BondSpacing.s12),
          InlineAlert(severity: InlineAlertSeverity.error, text: error),
        ],
        if (widget.loading) ...[
          const SizedBox(height: BondSpacing.s12),
          Text(
            'Loading…',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
        for (final row in widget.rows) _row(row, now),
        const SizedBox(height: BondSpacing.s16),
        if (onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: ContextDirectoriesSection.addKey,
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: Text(_adding ? 'Adding…' : 'Add directory…'),
              onPressed: _adding ? null : () => _add(onAdd),
            ),
          ),
      ],
    );
  }

  /// Held rather than fired and forgotten, so the button can say the panel is
  /// out. The `mounted` check is the one every awaited callback on this
  /// screen keeps: the pane can be closed while the panel is still open.
  Future<void> _add(Future<void> Function() onAdd) async {
    setState(() => _adding = true);
    try {
      await onAdd();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Widget _row(ContextDirRow row, DateTime now) {
    final dir = row.dir;
    final about = row.about;
    final failed = dir.status == 'error' || dir.status == 'unavailable';
    return Padding(
      key: ContextDirectoriesSection.rowKeyFor(dir.id),
      padding: const EdgeInsets.only(top: BondSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dir.displayName,
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            dir.path,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // What the app made of the folder, in the model's own words. Three
          // lines at most: this is the row of a settings list, not the brief
          // itself, and a project whose `about` runs long must not push the
          // controls of the directory below it off the pane.
          if (about != null && about.isNotEmpty)
            Text(
              about,
              key: ContextDirectoriesSection.aboutKeyFor(dir.id),
              style: BondType.caption.copyWith(color: BondColors.inkSecondary),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: BondSpacing.s4),
          Text(
            _statusLine(row, now),
            style: BondType.caption.copyWith(
              color: failed ? BondColors.error : BondColors.inkSecondary,
            ),
          ),
          Text(
            row.links == 0
                ? 'Not linked to any thread yet'
                : 'Links: ${row.links}',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
          const SizedBox(height: BondSpacing.s4),
          _controls(row),
        ],
      ),
    );
  }

  /// One line about where this directory stands, in the order a person asks:
  /// what happened, how much of it there is, and how long ago.
  ///
  /// A failure replaces the counts rather than joining them — the stored
  /// sentence is the only thing worth reading on a folder the app cannot
  /// open, and a `12 files` beside it would describe a walk from before the
  /// folder went away.
  String _statusLine(ContextDirRow row, DateTime now) {
    final dir = row.dir;
    if (dir.status == 'unavailable') {
      return dir.error ?? 'The folder could not be opened.';
    }
    if (dir.status == 'error') return dir.error ?? 'The last read failed.';

    final parts = <String>[];
    switch (dir.status) {
      case 'pending':
        parts.add('not read yet');
      case 'reading':
        parts.add('reading…');
      default:
        parts.add(_plural(dir.filesCount, 'file'));
        parts.add(_plural(row.chunks, 'passage'));
        final read = relativeTime(dir.walkedAt, now);
        if (read != null) parts.add('read $read');
    }
    // The embedding tail is its own clause and shown under every status: a
    // parked embedding server is exactly the case where the directory reads
    // `ready` and the vectors are still arriving.
    if (row.embedded < row.chunks) {
      parts.add('embedding ${row.embedded} of ${row.chunks}');
    }
    // The summary tail, on the same terms and for the same reason: a fast
    // server that is off is exactly the case where the directory reads
    // `ready` and the per-file summaries are still arriving. Hidden when the
    // switch is off, because a progress line towards a total nothing is
    // working on would never move.
    if (dir.digests && row.digestsDone < row.digestsEligible) {
      parts.add('summaries ${row.digestsDone} of ${row.digestsEligible}');
    }
    return parts.join(' · ');
  }

  Widget _controls(ContextDirRow row) {
    final id = row.dir.id;
    // A Wrap, not a Row: four controls and a path are wider than the settings
    // column at a large text scale, and a control row that overflows its own
    // section is a Remove nobody can reach.
    return Wrap(
      spacing: BondSpacing.s12,
      runSpacing: BondSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: ContextDirectoriesSection.rereadKeyFor(id),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Re-read now'),
          onPressed: () => widget.onReread(id),
        ),
        _switch(
          key: ContextDirectoriesSection.digestsKeyFor(id),
          label: 'Summaries',
          value: row.dir.digests,
          onChanged: (on) => widget.onDigestsChanged(id, on),
        ),
        _switch(
          key: ContextDirectoriesSection.ignoredKeyFor(id),
          label: 'Read ignored files',
          // INVERTED, and this is the only place the inversion lives. The
          // stored column asks "is .gitignore honoured"; the switch asks the
          // question a person actually has — "read the files git is ignoring"
          // — which is the same question with the answer flipped.
          value: !row.dir.honorGitignore,
          onChanged: (on) => widget.onHonorGitignoreChanged(id, !on),
        ),
        _removeControls(row),
      ],
    );
  }

  Widget _switch({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: BondType.caption),
          const SizedBox(width: BondSpacing.s4),
          Switch(
            key: key,
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      );

  /// The two-tap Remove, copied from `attachment_documents_strip.dart` for
  /// the reason the house rule gives: there is no confirmation dialog, so the
  /// protection is that the second click lands on a DIFFERENT button, in a
  /// different place, that did not exist a moment ago.
  Widget _removeControls(ContextDirRow row) {
    final id = row.dir.id;
    if (_confirming != id) {
      return TextButton(
        key: ContextDirectoriesSection.removeKeyFor(id),
        onPressed: () => setState(() => _confirming = id),
        child: const Text('Remove'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: BondSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: ContextDirectoriesSection.confirmRemoveKeyFor(id),
              style: TextButton.styleFrom(foregroundColor: BondColors.error),
              onPressed: () {
                setState(() => _confirming = null);
                widget.onRemove(id);
              },
              child: const Text('Remove directory'),
            ),
            TextButton(
              key: ContextDirectoriesSection.keepKeyFor(id),
              onPressed: () => setState(() => _confirming = null),
              child: const Text('Keep'),
            ),
          ],
        ),
        Text(
          'Removes its index and ${_plural(row.links, 'link')}; the folder '
          'itself is untouched.',
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
    );
  }
}
