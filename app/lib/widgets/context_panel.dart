import 'package:flutter/material.dart';

import '../models/context_models.dart' show ContextFile, ContextFileDigest;
import '../providers/context_provider.dart' show ContextDirRow;
import '../theme/tokens.dart';
import 'time_format.dart' show relativeTime;

/// Which of the owner's registered directories THIS room reads.
///
/// Prop-only, like every other panel body: the switches call back and the
/// screen writes. What it draws is the whole library with a switch each,
/// rather than only the linked ones, because the question a person opens this
/// to answer is "should this room read that project?" — and a list of what is
/// already linked cannot be used to answer it.
///
/// A thread also lists what it inherits from its storylines, in muted type
/// and with no switch. That is not a directory this thread linked, and a
/// switch that turned it off would be unlinking somebody else's storyline
/// from inside a room that merely benefits from it.
class ContextPanelBody extends StatelessWidget {
  /// The library, newest walk and all, from `contextDirectoriesProvider`.
  final List<ContextDirRow> rows;

  /// The ids linked to THIS room. A subset of [rows] in every ordinary case;
  /// an id here with no row is a directory removed between the two reads, and
  /// it simply draws nothing.
  final Set<String> linked;

  /// Thread only: the storyline each inherited directory comes through. The
  /// id rides along unused here — the host needs it to decide what a room may
  /// consult, and one record serves both readers.
  final List<({String storyline, String dirId, String dirName})> inherited;

  final void Function(String dirId, bool on) onToggle;
  final VoidCallback onAddDirectory;
  final VoidCallback onManage;

  /// The directory ids whose `Files ›` disclosure is open. A preference of
  /// the panel rather than a panel of its own, which is why the host keeps it
  /// in plain state and does not clear it when the side panel closes.
  final Set<String> expanded;

  /// The files of each expanded directory, already in path order — the store
  /// reads them that way, and re-sorting here would be a second opinion about
  /// an order the query already has.
  final Map<String, List<ContextFile>> files;

  /// Opens or closes one disclosure. Null draws no button at all: a host that
  /// cannot fetch the files has nothing to disclose.
  final void Function(String dirId)? onToggleFiles;

  /// Opens one file beside. Null makes each row a statement rather than a
  /// control, the way a chip with nowhere to go is.
  final void Function(int fileId)? onOpenFile;

  /// Passed rather than read from the clock, so `read 4m ago` is pinnable in
  /// a test — [relativeTime]'s rule wherever it is used.
  final DateTime now;

  const ContextPanelBody({
    super.key,
    required this.rows,
    required this.linked,
    this.inherited = const [],
    required this.onToggle,
    required this.onAddDirectory,
    required this.onManage,
    this.expanded = const {},
    this.files = const {},
    this.onToggleFiles,
    this.onOpenFile,
    required this.now,
  });

  static Key toggleKeyFor(String dirId) => Key('context-toggle-$dirId');
  static Key filesKeyFor(String dirId) => Key('context-files-$dirId');
  static Key fileKeyFor(int fileId) => Key('context-file-$fileId');
  static const Key addKey = Key('context-panel-add');
  static const Key manageKey = Key('context-panel-manage');

  /// How many file rows a disclosure draws before it starts counting them.
  ///
  /// A panel is not a file browser: a registered project runs to thousands of
  /// files, and a list of them is neither readable nor the way anybody finds
  /// anything. Search is — which is what the line under the cap says.
  static const int maxFilesShown = 200;

  static const String caption = 'Use these directories when replying here';
  static const String emptyLine =
      'No directories yet. Add one and every reply here can read it.';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(BondSpacing.s16),
      children: [
        Text(caption, style: BondType.caption),
        const SizedBox(height: BondSpacing.s12),
        if (rows.isEmpty)
          Text(emptyLine, style: BondType.small)
        else
          for (final row in rows) _row(row),
        if (inherited.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Also from storylines',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
          const SizedBox(height: BondSpacing.s4),
          // The heading already said "also from", so each line under it says
          // only which storyline and which directory — a list whose every
          // row repeats its own heading reads as three separate sentences
          // rather than as one list.
          for (final entry in inherited)
            Padding(
              padding: const EdgeInsets.only(bottom: BondSpacing.s4),
              child: Text(
                '«${entry.storyline}»: ${entry.dirName}',
                style: BondType.small.copyWith(color: BondColors.inkMuted),
              ),
            ),
        ],
        const SizedBox(height: BondSpacing.s16),
        const Divider(height: 1, color: BondColors.border),
        const SizedBox(height: BondSpacing.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: addKey,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add directory…'),
            onPressed: onAddDirectory,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: manageKey,
            onPressed: onManage,
            child: const Text('Manage directories in Settings ›'),
          ),
        ),
      ],
    );
  }

  /// One directory: what it is called, what it is about, how much of it there
  /// is, and whether this room reads it.
  Widget _row(ContextDirRow row) {
    final dir = row.dir;
    final about = row.about;
    final read = relativeTime(dir.walkedAt, now);
    final counts = [
      '${dir.filesCount} ${dir.filesCount == 1 ? 'file' : 'files'}',
      if (read != null) 'read $read',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  dir.displayName,
                  style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (about != null && about.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  // Two lines and no more: this is the sentence the brief
                  // opens with, and it is here to tell one project from
                  // another rather than to be read through.
                  Text(
                    about,
                    style: BondType.small,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  counts,
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
                if (onToggleFiles != null) _filesDisclosure(dir.id),
              ],
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          Switch(
            key: toggleKeyFor(dir.id),
            value: linked.contains(dir.id),
            onChanged: (on) => onToggle(dir.id, on),
          ),
        ],
      ),
    );
  }

  /// `Files ›`, and the list under it when it is open.
  Widget _filesDisclosure(String dirId) {
    final open = expanded.contains(dirId);
    final rows = files[dirId] ?? const <ContextFile>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: filesKeyFor(dirId),
            onPressed: () => onToggleFiles!(dirId),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(open ? 'Files ⌄' : 'Files ›', style: BondType.caption),
          ),
        ),
        if (open)
          for (final file in rows.take(maxFilesShown)) _fileRow(file),
        if (open && rows.length > maxFilesShown)
          Padding(
            padding: const EdgeInsets.only(top: BondSpacing.s4),
            child: Text(
              '+${rows.length - maxFilesShown} more — search finds them',
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
          ),
      ],
    );
  }

  /// One file: what it is called, what kind of thing it is, and what a model
  /// made of it.
  Widget _fileRow(ContextFile file) {
    final purpose = ContextFileDigest.decode(file.digestJson)?.purpose ?? '';
    final caption =
        purpose.isEmpty ? file.kind : '${file.kind} · $purpose';

    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            file.relPath,
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            caption,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // Nowhere to go, no control — [AttachmentSearchTile]'s rule.
    if (onOpenFile == null) return body;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: fileKeyFor(file.id),
        onTap: () => onOpenFile!(file.id),
        borderRadius: BondRadii.smAll,
        child: body,
      ),
    );
  }
}
