import 'package:flutter/material.dart';

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

  /// Thread only: the storyline each inherited directory comes through.
  final List<({String storyline, String dirName})> inherited;

  final void Function(String dirId, bool on) onToggle;
  final VoidCallback onAddDirectory;
  final VoidCallback onManage;

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
    required this.now,
  });

  static Key toggleKeyFor(String dirId) => Key('context-toggle-$dirId');
  static const Key addKey = Key('context-panel-add');
  static const Key manageKey = Key('context-panel-manage');

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
          for (final entry in inherited)
            Padding(
              padding: const EdgeInsets.only(bottom: BondSpacing.s4),
              child: Text(
                'Also from ${entry.storyline}: ${entry.dirName}',
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
}
