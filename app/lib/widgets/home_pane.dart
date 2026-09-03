import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'home_feed_row.dart';
import 'home_metrics.dart';
import 'hot_storylines.dart';
import 'inline_alert.dart';

/// The home screen: what the app has been doing, as a table you can leave open.
///
/// Dumb by construction, like the activity panel and the Later digest: every
/// value and every callback is a prop, nothing is read from a provider, and the
/// clock is injected. The one thing it owns is the scroll controller, because
/// paging is a property of the viewport rather than of the data.
class HomePane extends StatefulWidget {
  /// Newest first.
  final List<HomeFeedRow> rows;

  /// The tiles' numbers, or null while the first read is in flight. Null
  /// renders nothing rather than zeros — six noughts is a claim, and "not read
  /// yet" is not that claim.
  final HomeMetrics? metrics;

  final List<HotStoryline> hotStorylines;

  final bool includeDropped;

  /// Whether a first page has come back at all. False is what keeps the empty
  /// line off the screen during the read that is about to fill it.
  final bool loaded;

  final bool loadingMore;
  final bool atEnd;

  /// Non-null when the newest read failed. Whatever rows are below it are
  /// still real.
  final String? loadError;

  final DateTime now;

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;
  final VoidCallback onLoadMore;
  final VoidCallback onToggleDropped;

  const HomePane({
    super.key,
    required this.rows,
    required this.metrics,
    required this.now,
    required this.onOpenThread,
    required this.onOpenStoryline,
    required this.onLoadMore,
    required this.onToggleDropped,
    this.hotStorylines = const [],
    this.includeDropped = false,
    this.loaded = true,
    this.loadingMore = false,
    this.atEnd = false,
    this.loadError,
  });

  /// How close to the bottom the viewport has to get before the next page is
  /// asked for. Roughly a screenful of rows ahead of the reader, so the page
  /// lands before they arrive at it.
  static const double loadMoreSlack = 600;

  @override
  State<HomePane> createState() => _HomePaneState();
}

class _HomePaneState extends State<HomePane> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  /// Fires on every pixel of scroll and asks freely: the notifier's own
  /// in-flight guard is what makes a repeat call free, which is why there is no
  /// second guard here to disagree with it.
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels >= position.maxScrollExtent - HomePane.loadMoreSlack) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Home', style: BondType.title),
              const Spacer(),
              BondFilterPill(
                label: 'Show dropped',
                selected: widget.includeDropped,
                onTap: widget.onToggleDropped,
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s16),
          if (metrics != null) HomeMetricsBar(metrics: metrics),
          const SizedBox(height: BondSpacing.s12),
          HotStorylinesStrip(
            items: widget.hotStorylines,
            onOpen: widget.onOpenStoryline,
          ),
          const SizedBox(height: BondSpacing.s16),
          if (widget.loadError != null) ...[
            InlineAlert(
              severity: InlineAlertSeverity.error,
              text: widget.loadError!,
              maxLines: 2,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          Expanded(child: _feed()),
        ],
      ),
    );
  }

  Widget _feed() {
    if (widget.rows.isEmpty && widget.loaded) {
      return Center(
        child: Text(
          'Nothing yet — messages appear here as they arrive.',
          style: BondType.small.copyWith(color: BondColors.inkMuted),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HomeFeedHeaderRow(),
        Expanded(
          child: ListView.builder(
            // Named, so the place a reader scrolled to survives swapping to a
            // thread and back.
            key: const PageStorageKey<String>('home-feed'),
            controller: _scroll,
            // No itemExtent: a subject can take two lines and a bar can carry a
            // caption, so the rows are not one height.
            itemCount: widget.rows.length + 1,
            itemBuilder: (context, index) {
              if (index == widget.rows.length) return _footer();
              final row = widget.rows[index];
              return HomeFeedRowTile(
                key: ValueKey<String>(row.feedKey),
                row: row,
                now: widget.now,
                onOpenThread: widget.onOpenThread,
                onOpenStoryline: widget.onOpenStoryline,
              );
            },
          ),
        ),
      ],
    );
  }

  /// The end of the list, in words. Never a spinner: this screen is left open,
  /// and an indeterminate bar on it would be a perpetual animation.
  Widget _footer() {
    if (widget.loadingMore) {
      return Padding(
        padding: const EdgeInsets.all(BondSpacing.s12),
        child: Text('Loading older messages…', style: BondType.caption),
      );
    }
    if (widget.atEnd) {
      return Padding(
        padding: const EdgeInsets.all(BondSpacing.s12),
        child: Text("That's everything.", style: BondType.caption),
      );
    }
    return const SizedBox(height: BondSpacing.s24);
  }
}
