import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../providers/activity_provider.dart' show SyncStamps;
import '../theme/tokens.dart';
import 'time_format.dart';

/// One line under the tiles that says what the machine is doing.
///
/// The tiles above are a filter now, and a filter hides rows — so a reader who
/// has narrowed the Inbox to Needs You and finds three rows under it has no way
/// to tell "that is all there is" from "fifty more are still being triaged".
/// This strip is what tells them, and it is deliberately not part of the table:
/// it narrates the pipeline, not the selection.
///
/// Words and one dot, never a spinner and never a bar. The stage bar's rule,
/// for the stage bar's reason: this screen is left open all day, and an
/// indeterminate animation on it would be a perpetual one.

/// Stage word → present participle, the app narrating itself.
///
/// The same keys [PipelinePulse.stages] is written in, because the map is what
/// turns a column value into something a person reads and a stage with no entry
/// here would be narrated by its raw column name.
const Map<String, String> pulseStageLabels = {
  'triage': 'triaging',
  'extract': 'extracting',
  'needs_you': 'judging',
  'storyline': 'grouping',
  'draft': 'drafting',
  'embed': 'indexing',
  'files': 'reading files',
};

/// What is moving, as `triaging 2 · grouping 1` — pipeline order, and only the
/// stages with something under them.
///
/// Null when nothing is queued or running anywhere, which is what lets the
/// caller say `Idle` in one word rather than printing seven zeros.
String? pulseWorkLine(PipelinePulse pulse) {
  final parts = <String>[];
  for (final stage in PipelinePulse.stages) {
    final count = pulse.countFor(stage);
    if (count == 0) continue;
    parts.add('${pulseStageLabels[stage] ?? stage} $count');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// What just finished, as `5 settled · 2 dropped · 1 needs you`.
///
/// Zeros are left out rather than printed: "0 dropped" is a claim about an
/// absence, and three of them would make a quiet ten minutes read as a report.
/// Null when all three are zero, so a caller can leave the segment off
/// entirely.
String? pulseRecentLine(PipelinePulse pulse) {
  final parts = <String>[
    if (pulse.recentSettled > 0) '${pulse.recentSettled} settled',
    if (pulse.recentDropped > 0) '${pulse.recentDropped} dropped',
    if (pulse.recentNeedsYou > 0) '${pulse.recentNeedsYou} needs you',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Where the mail is coming from, in one clause.
///
/// A pull that is OUT outranks the stamps, because "Mail 4m ago" while a sync
/// is running is the app reporting the last answer as though it were the
/// current one. Once nothing is out it is the three stamps, and a stamp that
/// was never written reads as `never` rather than as a blank — an install whose
/// sweep has not run yet is a fact worth stating.
///
/// [now] is a parameter for [relativeTime]'s reason: the whole line is
/// pinnable, and a clock read in here would not be.
String syncLine({
  required bool mailSyncing,
  required bool teamsSyncing,
  SyncStamps? stamps,
  required DateTime now,
}) {
  if (mailSyncing && teamsSyncing) return 'Syncing mail and Teams…';
  if (mailSyncing) return 'Syncing mail…';
  if (teamsSyncing) return 'Syncing Teams…';
  String age(String? iso) => relativeTime(iso, now) ?? 'never';
  return 'Mail ${age(stamps?.mailIso)} · '
      'Teams ${age(stamps?.teamsIso)} · '
      'Sweep ${age(stamps?.sweepIso)}';
}

/// The strip itself: a dot, what is moving, what just finished, and the sync.
///
/// Dumb like the pane around it — every value is a prop and the clock is
/// injected — so the three sentences above can be pinned without a pump and
/// this widget only has to place them.
class PipelinePulseStrip extends StatelessWidget {
  /// Null before the first read has landed. Draws `Idle` and the sync line: the
  /// stamps are already known at that point, and a strip that rendered nothing
  /// for a frame would make the header jump.
  final PipelinePulse? pulse;

  final bool mailSyncing;
  final bool teamsSyncing;
  final SyncStamps? stamps;
  final DateTime now;

  const PipelinePulseStrip({
    super.key,
    required this.pulse,
    required this.now,
    this.mailSyncing = false,
    this.teamsSyncing = false,
    this.stamps,
  });

  static const Key stripKey = ValueKey('home-pulse');
  static const Key workKey = ValueKey('home-pulse-work');
  static const Key recentKey = ValueKey('home-pulse-recent');
  static const Key syncKey = ValueKey('home-pulse-sync');

  /// The dot's diameter. Small enough to read as punctuation rather than as a
  /// status light somebody has to interpret.
  static const double dotSize = 6;

  @override
  Widget build(BuildContext context) {
    final pulse = this.pulse;
    final work = pulse == null ? null : pulseWorkLine(pulse);
    final recent = pulse == null ? null : pulseRecentLine(pulse);
    // The dot is lit for anything at all in motion — a stage with work on it or
    // a pull that is out. Anything else is grey, which is the honest reading of
    // an app that has finished.
    final live = (pulse?.busy ?? false) || mailSyncing || teamsSyncing;

    final segments = <Widget>[
      Tooltip(
        message: pulse == null
            ? 'Nothing has been read yet.'
            : '${pulse.working} being worked · ${pulse.waiting} waiting',
        child: Text(
          work ?? 'Idle',
          key: workKey,
          style: BondType.caption,
        ),
      ),
      if (recent != null)
        Text(
          'Last ${homePulseWindow.inMinutes} min: $recent',
          key: recentKey,
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
      Text(
        syncLine(
          mailSyncing: mailSyncing,
          teamsSyncing: teamsSyncing,
          stamps: stamps,
          now: now,
        ),
        key: syncKey,
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      ),
    ];

    return Row(
      key: stripKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Nudged down onto the first line's baseline rather than centred on a
          // Wrap that may be two lines tall.
          padding: const EdgeInsets.only(top: BondSpacing.s4 + 1),
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: live ? BondColors.primary : BondColors.inkMuted,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: BondSpacing.s8),
        // A Wrap and not a Row: three clauses do not fit a pane with a thread
        // beside it, and a squeezed line would ellipsise the sync stamps —
        // which are the half a reader is most often checking.
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < segments.length; i++) ...[
                if (i > 0)
                  Text(
                    ' · ',
                    style: BondType.caption.copyWith(
                      color: BondColors.inkMuted,
                    ),
                  ),
                segments[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
