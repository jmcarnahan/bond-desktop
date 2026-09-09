import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../models/home_sort.dart';
import '../theme/tokens.dart';

/// One headline number and what it counts.
///
/// The one stat tile in the app: the Inbox metrics bar below and
/// `ActivityLogPanel`'s row of stamps and averages both render it. Two rows of
/// numbers that read as the same thing have to BE the same widget — otherwise
/// a change to the chrome lands on one screen and silently misses the other.
///
/// A tile that can be PRESSED is a filter, and a filter that is on has to look
/// held down — otherwise the reader is left to infer, from a table they have
/// never seen unfiltered, that a narrowing is in force at all. The activity
/// panel's tiles pass neither [onTap] nor [selected] and are unchanged: they
/// are a readout, and nothing there is a control.
class BondStatTile extends StatelessWidget {
  final String value;
  final String label;

  /// Whether this tile's filter is the one in force. Only meaningful with
  /// [onTap] — a tile nobody can press has nothing to be selected about.
  final bool selected;

  /// Turns the tile into a filter. Null leaves it a number.
  final VoidCallback? onTap;

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
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s12,
        vertical: BondSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: selected ? BondColors.primaryTint : BondColors.faintGround,
        borderRadius: BondRadii.mdAll,
        border: Border.all(
          color: selected ? BondColors.primary : BondColors.border,
        ),
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
              // The selected tile draws its number in the deep primary, so the
              // fill is not the only thing carrying the state — a tint alone
              // is a difference somebody has to be looking for.
              style: BondType.mono.copyWith(
                color: selected ? BondColors.primaryDeep : valueColor,
              ),
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

    final tap = onTap;
    if (tap == null) return tile;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: tap,
        borderRadius: BondRadii.mdAll,
        child: tile,
      ),
    );
  }
}

/// The numbers over the feed, all from one read so they agree with each other
/// — and the Inbox's filter.
///
/// A [Wrap] rather than a Row: eight tiles do not fit a narrow pane, and a
/// tile that has wrapped still reads correctly while a squeezed one does not.
///
/// The last three are the ones a reader is looking for when something is
/// wrong: what is still moving, how much of that has stopped moving, and what
/// failed outright. Each is coloured only when it is non-zero — a red nought
/// is an alarm about the absence of a problem.
///
/// Needs You stands APART: first, then a divider, then the other seven and the
/// caption naming their week. It is a pile to burn down to zero and the seven
/// are a readout of what the app has been doing — two different kinds of
/// number, and a row of eight that read as one kind would invite the reader to
/// compare them. It counts all time for the same reason, and draws its count
/// in [BondColors.attention] when there is one, because that is the tile the
/// screen is asking the reader to act on.
///
/// EVERY tile is a filter, and one at a time: pressing a tile narrows the
/// table to what that tile counted, and pressing it again widens back to
/// everyone else's messages. That is the whole control — there is no pill and
/// no menu of filters, because the numbers were already on screen and a reader
/// who wants to see the twelve dropped messages is already pointing at the
/// twelve.
///
/// Emails and Teams are the exception, and only in where they write: they move
/// the list column's source chips rather than [HomeFilter], because a
/// connector is the ONE selection this app makes once and applies everywhere,
/// and a second copy of it living on this bar would put two answers on screen
/// to the question of which mailbox is being read.
class HomeMetricsBar extends StatelessWidget {
  final HomeMetrics metrics;

  /// How far back the seven windowed numbers reach. A parameter rather than
  /// the constant read here, so a test can pin the caption's wording without a
  /// week's worth of fixtures. Needs You does not read it.
  final Duration window;

  /// The filter in force, and the way to change it. Every tile but Emails and
  /// Teams reports through here.
  final HomeFilter filter;
  final ValueChanged<HomeFilter> onFilter;

  /// The list column's source chip, or null for both. Emails and Teams report
  /// through here instead.
  final String? sourceFilter;
  final ValueChanged<String?> onSelectSource;

  const HomeMetricsBar({
    super.key,
    required this.metrics,
    required this.filter,
    required this.onFilter,
    required this.sourceFilter,
    required this.onSelectSource,
    this.window = homeMetricsWindow,
  });

  /// The caption naming the window, after the seven tiles it belongs to.
  static const Key windowKey = ValueKey('home-metrics-window');

  /// The rule between the pile and the readout.
  static const Key dividerKey = ValueKey('home-metrics-divider');

  /// One tile by name, so a test taps the filter rather than the number on it
  /// — the numbers are fixture values and the slugs are the columns.
  static Key tileKey(String slug) => ValueKey('home-tile-$slug');

  @override
  Widget build(BuildContext context) {
    // Derived rather than counted: "processed" is everything the pipeline is
    // no longer holding, and the store already knows how much is still moving.
    final processed = metrics.total - metrics.inFlight;

    /// A tile that turns its own filter on, and off again when it is already
    /// the one in force. One at a time, so the tile a reader is looking at is
    /// always the tile the table is showing.
    BondStatTile tile(
      String slug,
      String value,
      String label,
      HomeFilter own, {
      Color? valueColor,
      String? caption,
    }) =>
        BondStatTile(
          key: tileKey(slug),
          value: value,
          label: label,
          valueColor: valueColor,
          caption: caption,
          selected: filter == own,
          onTap: () =>
              onFilter(filter == own ? HomeFilter.fromOthers : own),
        );

    /// A connector tile, which writes the source chips instead. Its [slug] is
    /// the key's, and [source] is the store's name for the connector — the two
    /// are spelled apart because the label is plural and the column is not.
    BondStatTile sourceTile(
      String slug,
      String source,
      String value,
      String label,
    ) =>
        BondStatTile(
          key: tileKey(slug),
          value: value,
          label: label,
          selected: sourceFilter == source,
          onTap: () => onSelectSource(sourceFilter == source ? null : source),
        );

    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // First, and alone on its side of the rule: the one number here that
        // is work rather than a reading of work.
        tile(
          'needs-you',
          '${metrics.needsYou}',
          'Needs You',
          HomeFilter.needsYou,
          valueColor: metrics.needsYou > 0 ? BondColors.attention : null,
        ),
        // Sized to a tile rather than stretched, because a Wrap hands its
        // children unbounded height and a rule as tall as the row would be a
        // rule as tall as whatever wrapped beside it.
        const SizedBox(
          key: dividerKey,
          width: 1,
          height: 40,
          child: ColoredBox(color: BondColors.border),
        ),
        sourceTile('emails', 'email', '${metrics.emails}', 'Emails'),
        sourceTile('teams', 'teams', '${metrics.teams}', 'Teams'),
        tile('processed', '$processed', 'Processed', HomeFilter.processed),
        tile('dropped', '${metrics.dropped}', 'Dropped', HomeFilter.dropped),
        tile(
          'urgent',
          '${metrics.urgent}',
          'Urgent',
          HomeFilter.urgent,
          valueColor: metrics.urgent > 0 ? BondColors.error : null,
        ),
        tile(
          'in-flight',
          '${metrics.inFlight}',
          'In flight',
          HomeFilter.inFlight,
          valueColor: metrics.stalled > 0 ? BondColors.error : null,
          caption: metrics.stalled > 0 ? '${metrics.stalled} stalled' : null,
        ),
        tile(
          'errors',
          '${metrics.errored}',
          'Errors',
          HomeFilter.errors,
          valueColor: metrics.errored > 0 ? BondColors.error : null,
        ),
        // The window, said once after the tiles it bounds: seven counts with
        // no stated period are seven counts of nothing in particular, and
        // seven zeros with no stated period look like a broken pipeline rather
        // than a quiet week. It bounds those seven FILTERS too — each reads
        // over the week its tile counted, so the number is the number of rows
        // under it. Needs You is on the other side of the rule and outside
        // this sentence: it is all time.
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
