import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';

/// One headline number and what it counts.
///
/// The one stat tile in the app: the home metrics bar below and
/// `ActivityLogPanel`'s row of stamps and averages both render it. Two rows of
/// numbers that read as the same thing have to BE the same widget — otherwise
/// a change to the chrome lands on one screen and silently misses the other.
class BondStatTile extends StatelessWidget {
  final String value;
  final String label;

  /// Only ever set for a number that has earned it. A red nought is an alarm
  /// about the absence of a problem.
  final Color? valueColor;

  /// A second line under the label, for the part of the number that is worse
  /// than the rest of it — "3 stalled" inside eleven in flight. Null is the
  /// ordinary case and draws nothing: a caption that said "0 stalled" would
  /// be the same false alarm as a red nought.
  final String? caption;

  static const Duration switchDuration = Duration(milliseconds: 180);

  const BondStatTile({
    super.key,
    required this.value,
    required this.label,
    this.valueColor,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s12,
        vertical: BondSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Keyed by the value, so a number that changed crosses to the new
          // one and a number that did not is left alone — a tile that blinked
          // on every re-read would be motion carrying no information.
          AnimatedSwitcher(
            duration: switchDuration,
            child: Text(
              value,
              key: ValueKey<String>(value),
              style: BondType.mono.copyWith(color: valueColor),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: BondType.caption),
          if (caption != null)
            Text(
              caption!,
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
        ],
      ),
    );
  }
}

/// The numbers over the feed, all from one read so they agree with each other.
///
/// A [Wrap] rather than a Row: eight tiles do not fit a narrow pane, and a
/// tile that has wrapped still reads correctly while a squeezed one does not.
///
/// The last three are the ones a reader is looking for when something is
/// wrong: what is still moving, how much of that has stopped moving, and what
/// failed outright. Each is coloured only when it is non-zero — a red nought
/// is an alarm about the absence of a problem.
class HomeMetricsBar extends StatelessWidget {
  final HomeMetrics metrics;

  /// How far back the numbers reach. A parameter rather than the constant
  /// read here, so a test can pin the caption's wording without a week's
  /// worth of fixtures.
  final Duration window;

  const HomeMetricsBar({
    super.key,
    required this.metrics,
    this.window = homeMetricsWindow,
  });

  /// The caption naming the window, at the end of the tiles.
  static const Key windowKey = ValueKey('home-metrics-window');

  @override
  Widget build(BuildContext context) {
    // Derived rather than counted: "processed" is everything the pipeline is
    // no longer holding, and the store already knows how much is still moving.
    final processed = metrics.total - metrics.inFlight;
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BondStatTile(value: '${metrics.emails}', label: 'Emails'),
        BondStatTile(value: '${metrics.teams}', label: 'Teams'),
        BondStatTile(value: '$processed', label: 'Processed'),
        BondStatTile(value: '${metrics.needsYou}', label: 'Needs You'),
        BondStatTile(value: '${metrics.dropped}', label: 'Dropped'),
        BondStatTile(
          value: '${metrics.urgent}',
          label: 'Urgent',
          valueColor: metrics.urgent > 0 ? BondColors.error : null,
        ),
        BondStatTile(
          value: '${metrics.inFlight}',
          label: 'In flight',
          valueColor: metrics.stalled > 0 ? BondColors.error : null,
          caption: metrics.stalled > 0 ? '${metrics.stalled} stalled' : null,
        ),
        BondStatTile(
          value: '${metrics.errored}',
          label: 'Errors',
          valueColor: metrics.errored > 0 ? BondColors.error : null,
        ),
        // The window, said once beside the numbers: eight counts with no
        // stated period are eight counts of nothing in particular, and eight
        // zeros with no stated period look like a broken pipeline rather
        // than a quiet week.
        Padding(
          padding: const EdgeInsets.only(left: BondSpacing.s4),
          child: Text(
            homeMetricsWindowLabel(window),
            key: windowKey,
            style: BondType.caption,
          ),
        ),
      ],
    );
  }
}
