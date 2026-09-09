import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../models/home_sort.dart';
import '../providers/activity_provider.dart' show SyncStamps;
import '../theme/tokens.dart';
import 'attachment_search_tile.dart';
import 'home_feed_row.dart';
import 'home_metrics.dart';
import 'home_pulse.dart';
import 'home_search.dart';
import 'hot_storylines.dart';
import 'inline_alert.dart';
import 'sort_menu.dart';

/// The Inbox: what the app has been doing, as a table you can leave open.
///
/// Dumb by construction, like the activity panel and the Later digest: every
/// value and every callback is a prop, nothing is read from a provider, and the
/// clock is injected. The one thing it owns is the scroll controller, because
/// paging is a property of the viewport rather than of the data.
///
/// The class keeps its name where the stop keeps its enum — see
/// `RailSectionLabel`. What moved is the word a reader sees.
class HomePane extends StatefulWidget {
  /// In [sort]'s order.
  final List<HomeFeedRow> rows;

  /// The tiles' numbers, or null while the first read is in flight. Null
  /// renders nothing rather than zeros — six noughts is a claim, and "not read
  /// yet" is not that claim.
  final HomeMetrics? metrics;

  final List<HotStoryline> hotStorylines;

  /// Which rows the table is keeping, and the way to change it. The tiles are
  /// the control — see [HomeMetricsBar].
  final HomeFilter filter;
  final ValueChanged<HomeFilter> onFilter;

  /// Which way the table runs, and the menu beside the search box that turns
  /// it around.
  final HomeSort sort;
  final ValueChanged<HomeSort> onSort;

  /// The list column's source chip, or null for both — the one source
  /// selection the app has; the Emails / Teams tiles set it.
  final String? sourceFilter;
  final ValueChanged<String?> onSelectSource;

  /// What the pipeline is doing, or null before the first read. The tiles above
  /// it are a filter now, and this is what tells a reader whose table looks
  /// empty whether the filter is hiding the work.
  final PipelinePulse? pulse;

  /// Whether a pull is out on either connector. Words on the strip, never a
  /// spinner.
  final bool mailSyncing;
  final bool teamsSyncing;

  /// When each pass last finished, or null before the first read.
  final SyncStamps? stamps;

  /// Whether a first page has come back at all. False is what keeps the empty
  /// line off the screen during the read that is about to fill it.
  final bool loaded;

  final bool loadingMore;
  final bool atEnd;

  /// Non-null when the newest read failed. Whatever rows are below it are
  /// still real.
  final String? loadError;

  final DateTime now;

  /// How many rows are waiting above the table because the reader is not at
  /// the top of it. Zero shows nothing.
  final int pendingNewCount;

  /// Keys mid entrance, mid fade-out and mid collapse, in
  /// [HomeFeedRow.feedKey] spelling — the one the list items are keyed by.
  final Set<String> entering;
  final Set<String> fading;
  final Set<String> collapsing;

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;
  final VoidCallback onLoadMore;

  /// Lets the held-back rows onto the table.
  final VoidCallback? onReleasePending;

  /// Whether the viewport is at the top, reported only when it changes. What
  /// decides whether the next arrival lands on the table or waits above it.
  final void Function(bool anchored)? onAnchoredChanged;

  /// The results to show in place of the table, or null for the live one.
  final HomeSearch? search;

  /// Whether a submitted query is still out. Says so in words over a body that
  /// does not move.
  final bool searching;

  /// Why a search could not run. An alert over whichever body is up, never a
  /// body of its own.
  final String? searchNotice;

  final ValueChanged<String>? onSearch;
  final VoidCallback? onExitSearch;

  /// Requeues the stages a stalled or failed row still owes. Null hides the
  /// Retry link on every row — the pane is dumb about whether a repair is
  /// wired up, it just does not offer one.
  final void Function(String source, String sourceMessageId)? onRetry;

  /// Opens one message's whole story — the door the stage bar and the Result
  /// cell become. Null leaves both as part of the row's own tap, exactly as
  /// [onRetry] null leaves the Retry link undrawn.
  final void Function(String source, String sourceMessageId)? onOpenHistory;

  const HomePane({
    super.key,
    required this.rows,
    required this.metrics,
    required this.now,
    required this.onOpenThread,
    required this.onOpenStoryline,
    required this.onLoadMore,
    required this.filter,
    required this.onFilter,
    required this.sort,
    required this.onSort,
    required this.sourceFilter,
    required this.onSelectSource,
    this.pulse,
    this.mailSyncing = false,
    this.teamsSyncing = false,
    this.stamps,
    this.hotStorylines = const [],
    this.loaded = true,
    this.loadingMore = false,
    this.atEnd = false,
    this.loadError,
    this.pendingNewCount = 0,
    this.entering = const {},
    this.fading = const {},
    this.collapsing = const {},
    this.onReleasePending,
    this.onAnchoredChanged,
    this.search,
    this.searching = false,
    this.searchNotice,
    this.onSearch,
    this.onExitSearch,
    this.onRetry,
    this.onOpenHistory,
  });

  /// The sort menu, and one key per order in it.
  static const Key sortKey = ValueKey('home-sort');

  static Key sortItemKeyFor(HomeSort s) => ValueKey('home-sort-${s.name}');

  /// The line that says a tile filter is on, and the way back out of it.
  static const Key filterNoticeKey = ValueKey('home-filter-notice');
  static const Key showEveryoneKey = ValueKey('home-show-everyone');

  /// Below this much table width the row folds onto two lines.
  ///
  /// 900 because of what sits beside this pane: with a thread open in the side
  /// panel the main pane is about 600px, and seven columns — sender, subject,
  /// a 200px bar, a verdict, an ask and a stamp — cannot line up in that. A
  /// table whose columns have stopped lining up is no longer a table, and the
  /// fold is what keeps the comparison this screen exists for.
  static const double compactBelow = 900;

  /// How close to the bottom the viewport has to get before the next page is
  /// asked for. Roughly a screenful of rows ahead of the reader, so the page
  /// lands before they arrive at it.
  static const double loadMoreSlack = 600;

  /// How far down from the top still counts as being at the top. A few pixels
  /// rather than none: a trackpad rests a list at 0.7px as readily as at 0,
  /// and a reader who has not scrolled has not scrolled.
  static const double anchorSlack = 4;

  /// The ride the pill's tap takes the reader on, and the only place this
  /// widget moves the viewport itself.
  static const Duration releaseScroll = Duration(milliseconds: 200);

  /// How long the waiting-rows pill takes to slide and fade in. The ribbon's
  /// duration, because it is the same gesture: a notice arriving over a page.
  static const Duration pillEntry = Duration(milliseconds: 180);

  /// The live⇄search body swap. Short enough to read as one body replacing
  /// another rather than as a page load.
  static const Duration searchSwap = Duration(milliseconds: 160);

  @override
  State<HomePane> createState() => _HomePaneState();
}

class _HomePaneState extends State<HomePane> {
  final ScrollController _scroll = ScrollController();

  /// The typed query. View state in exactly the way the scroll position is:
  /// the question belongs to the box, the answer belongs to the notifier.
  final TextEditingController _searchText = TextEditingController();

  /// Mirrors what was last reported upward, so a scroll that stays at the top
  /// — or stays away from it — costs nothing.
  bool _anchored = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _scroll.addListener(_maybeAnchor);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.removeListener(_maybeAnchor);
    _scroll.dispose();
    _searchText.dispose();
    super.dispose();
  }

  /// The one way out, whichever affordance asked for it: the box empties and
  /// the live table comes back.
  void _exitSearch() {
    _searchText.clear();
    widget.onExitSearch?.call();
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

  /// Reports the top only on the edge. This fires on every pixel and what it
  /// drives is a field on the notifier, so saying the same thing sixty times a
  /// second would make this the one scroll in the app that costs rebuilds.
  void _maybeAnchor() {
    if (!_scroll.hasClients) return;
    final anchored = _scroll.position.pixels <= HomePane.anchorSlack;
    if (anchored == _anchored) return;
    _anchored = anchored;
    widget.onAnchoredChanged?.call(anchored);
  }

  /// Puts the waiting rows on the table and takes the reader to them — in that
  /// order, so they are there by the time the scroll arrives.
  void _release() {
    widget.onReleasePending?.call();
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: HomePane.releaseScroll,
      curve: Curves.easeOut,
    );
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
              Text('Inbox', style: BondType.title),
              const SizedBox(width: BondSpacing.s16),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: HomeSearchField(
                    controller: _searchText,
                    active: widget.search != null || widget.searching,
                    onSubmit: (query) => widget.onSearch?.call(query),
                    onClear: _exitSearch,
                  ),
                ),
              ),
              const SizedBox(width: BondSpacing.s16),
              // Beside the box rather than over the table, because it is a
              // property of the whole list and not of the results in it — the
              // shape every other list in the app wears.
              SortMenu<HomeSort>(
                key: HomePane.sortKey,
                value: widget.sort,
                options: HomeSort.values,
                labelOf: (order) => order.label,
                onChanged: widget.onSort,
                itemKeyFor: HomePane.sortItemKeyFor,
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s16),
          if (metrics != null)
            HomeMetricsBar(
              metrics: metrics,
              filter: widget.filter,
              sourceFilter: widget.sourceFilter,
              onFilter: widget.onFilter,
              onSelectSource: widget.onSelectSource,
            ),
          if (widget.filter != HomeFilter.fromOthers) ...[
            const SizedBox(height: BondSpacing.s8),
            _filterNotice(),
          ],
          const SizedBox(height: BondSpacing.s8),
          PipelinePulseStrip(
            pulse: widget.pulse,
            mailSyncing: widget.mailSyncing,
            teamsSyncing: widget.teamsSyncing,
            stamps: widget.stamps,
            now: widget.now,
          ),
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
          // Attention rather than error: the feed under it is working, and one
          // feature of it is off.
          if (widget.searchNotice != null) ...[
            InlineAlert(
              severity: InlineAlertSeverity.attention,
              text: widget.searchNotice!,
              maxLines: 2,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          // A line, never a spinner, and never in place of the body: the table
          // the reader was looking at stays under it until the answer lands.
          if (widget.searching) ...[
            Text('Searching…', style: BondType.caption),
            const SizedBox(height: BondSpacing.s8),
          ],
          // The fold is decided on the width the TABLE actually gets, not on
          // the window's: this pane sits beside a thread as often as not, and
          // the two are hundreds of pixels apart.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < HomePane.compactBelow;
                return AnimatedSwitcher(
                  duration: HomePane.searchSwap,
                  child: widget.search == null
                      ? KeyedSubtree(
                          key: const ValueKey<String>('home-live'),
                          child: _feed(compact),
                        )
                      : KeyedSubtree(
                          key: const ValueKey<String>('home-search'),
                          child: _searchBody(widget.search!, compact),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// What a tile filter is hiding, and the way out of it.
  ///
  /// A filter with no visible control saying so is how a reader comes to
  /// believe their mail has gone missing — and the tile that set it may have
  /// wrapped onto a line they are not looking at. It names the window too,
  /// because a tile filter is bounded by the week the tile counted and a
  /// message older than that is genuinely not in the answer.
  ///
  /// A text link and not a button, the way `Back to live` is: this is a way
  /// out inside a body, and a raised control here would outrank the table.
  Widget _filterNotice() {
    return Row(
      key: HomePane.filterNoticeKey,
      children: [
        Flexible(
          child: Text(
            'Showing ${widget.filter.label} · '
            '${homeMetricsWindowLabel(homeMetricsWindow).toLowerCase()}',
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: BondSpacing.s8),
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: HomePane.showEveryoneKey,
            onTap: () => widget.onFilter(HomeFilter.fromOthers),
            borderRadius: BondRadii.smAll,
            child: Text(
              'Show everyone',
              style: BondType.small.copyWith(
                fontWeight: FontWeight.w600,
                color: BondColors.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// What a query came back with: how many, for what, and the way back.
  ///
  /// One list of messages in score order under a count of itself, with the
  /// document passages above it. Its own list, with no controller and no
  /// [PageStorageKey]: a result set's scroll position is disposable, and the
  /// live table keeps its own through the swap precisely because that key
  /// stays on the list that owns it.
  Widget _searchBody(HomeSearch search, bool compact) {
    // The rows on screen and nothing else — one fused list means the header
    // can simply count it. Documents are not in the number; see below.
    final count = search.hits.length;
    final notice = search.notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s4,
            vertical: BondSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$count result${count == 1 ? '' : 's'} for “${search.query}”',
                  style: BondType.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: BondSpacing.s12),
              // The row's storyline link, not a Material button: this is a way
              // back inside a body, and a raised control here would outrank
              // the results it sits over.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _exitSearch,
                  borderRadius: BondRadii.smAll,
                  child: Text(
                    'Back to live',
                    style: BondType.small.copyWith(
                      fontWeight: FontWeight.w600,
                      color: BondColors.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Between the count and the rows, because it qualifies THEM: one
        // half of the search could not run, so what is listed below is
        // narrower than it looks. The service writes the sentence — this only
        // places it, and the archive pane places its own the same way.
        if (notice != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: notice,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s8),
        ],
        // Documents first, above the messages. A passage that ANSWERS the
        // query is a better answer than a message that merely mentions it, and
        // the reader who typed a phrase from inside a spreadsheet is looking
        // for the spreadsheet.
        //
        // The header count above stays a count of MESSAGES: it labels the
        // list under it, and a number that silently included documents would
        // never match the rows a person can count on screen.
        //
        // A plain [Column], not a list: the store caps `documents` at six, so
        // this is bounded by construction, and a scroller here would fight the
        // one below it for the same gesture.
        if (search.documents.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              left: BondSpacing.s4,
              right: BondSpacing.s4,
              top: BondSpacing.s4,
              bottom: BondSpacing.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'In documents',
                  style:
                      BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
                const SizedBox(height: BondSpacing.s4),
                for (final hit in search.documents)
                  AttachmentSearchTile(
                    key: AttachmentSearchTile.keyFor(hit.ref),
                    hit: hit,
                    now: widget.now,
                    onOpenThread: widget.onOpenThread,
                  ),
              ],
            ),
          ),
        // Two ways to have no message rows, and they are not the same
        // sentence. With nothing above it either, the search found nothing at
        // all. With documents above it, the mailbox HAS an answer and it is
        // sitting on screen — the relevance floor makes that combination
        // ordinary rather than rare, and "Nothing matches that." over a named
        // file is the screen contradicting itself.
        if (search.hits.isEmpty && search.documents.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'Nothing matches that.',
                style: BondType.small.copyWith(color: BondColors.inkMuted),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else if (search.hits.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No messages match that.',
                style: BondType.small.copyWith(color: BondColors.inkMuted),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else ...[
          HomeFeedHeaderRow(compact: compact),
          Expanded(child: _resultList(search, compact)),
        ],
      ],
    );
  }

  /// Every result, in score order, under one scroller.
  ///
  /// One list and one order, because a row found by its words and a row found
  /// by its meaning are answers to the same question — the fusion already
  /// weighed them against each other, and a heading splitting them apart
  /// would file the row that matched BOTH ways under one of them.
  Widget _resultList(HomeSearch search, bool compact) {
    return ListView.builder(
      itemCount: search.hits.length,
      itemBuilder: (context, index) {
        final row = search.hits[index].row;
        return HomeFeedRowTile(
          key: ValueKey<String>('search-${row.feedKey}'),
          row: row,
          now: widget.now,
          compact: compact,
          muteBar: true,
          onOpenThread: widget.onOpenThread,
          onOpenStoryline: widget.onOpenStoryline,
          onRetry: widget.onRetry,
          onOpenHistory: widget.onOpenHistory,
        );
      },
    );
  }

  Widget _feed(bool compact) {
    if (widget.rows.isEmpty && widget.loaded) {
      return Center(
        child: Text(
          'Nothing yet — messages appear here as they arrive.',
          style: BondType.small.copyWith(color: BondColors.inkMuted),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HomeFeedHeaderRow(compact: compact),
            Expanded(
              child: ListView.builder(
                // Named, so the place a reader scrolled to survives swapping
                // to a thread and back.
                key: const PageStorageKey<String>('home-feed'),
                controller: _scroll,
                // No itemExtent: a subject can take two lines and a bar can
                // carry a caption, so the rows are not one height.
                itemCount: widget.rows.length + 1,
                itemBuilder: (context, index) {
                  if (index == widget.rows.length) return _footer();
                  final row = widget.rows[index];
                  final key = row.feedKey;
                  return HomeFeedRowTile(
                    key: ValueKey<String>(key),
                    row: row,
                    now: widget.now,
                    compact: compact,
                    animateIn: widget.entering.contains(key),
                    fading: widget.fading.contains(key),
                    collapsing: widget.collapsing.contains(key),
                    onOpenThread: widget.onOpenThread,
                    onOpenStoryline: widget.onOpenStoryline,
                    onRetry: widget.onRetry,
                    onOpenHistory: widget.onOpenHistory,
                  );
                },
              ),
            ),
          ],
        ),
        // Over the table rather than above it: a bar that took a row's worth of
        // height would push the feed down every time a sync landed.
        if (widget.pendingNewCount > 0)
          Positioned(
            top: BondSpacing.s12,
            left: 0,
            right: 0,
            child: Center(
              child: _PendingPill(
                key: const ValueKey<String>('pending-pill'),
                count: widget.pendingNewCount,
                onTap: _release,
              ),
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

/// What arrived while the reader was somewhere else in the table, as a count
/// they can spend.
///
/// A number and a word — never a spinner and never a loop: it says how much is
/// waiting and then holds still. It slides and fades in the way the
/// notification ribbon does, off one post-frame rebuild so the implicit
/// animations have a start value to move from, and it is mounted only while
/// there is something to say.
class _PendingPill extends StatefulWidget {
  final int count;
  final VoidCallback onTap;

  const _PendingPill({super.key, required this.count, required this.onTap});

  @override
  State<_PendingPill> createState() => _PendingPillState();
}

class _PendingPillState extends State<_PendingPill> {
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _settled = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: HomePane.pillEntry,
      curve: Curves.easeOut,
      offset: _settled ? Offset.zero : const Offset(0, -0.8),
      child: AnimatedOpacity(
        duration: HomePane.pillEntry,
        curve: Curves.easeOut,
        opacity: _settled ? 1 : 0,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            boxShadow: BondShadows.overlay,
            borderRadius: BondRadii.fullAll,
          ),
          child: Material(
            color: BondColors.primary,
            borderRadius: BondRadii.fullAll,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BondRadii.fullAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: BondSpacing.s12,
                  vertical: BondSpacing.s8,
                ),
                child: Text(
                  '${widget.count} new',
                  style: BondType.small.copyWith(
                    color: BondColors.onDarkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
