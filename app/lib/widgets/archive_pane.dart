import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'conversation_list_pane.dart';
import 'home_feed_row.dart';
import 'home_search.dart';
import 'inline_alert.dart';
import 'later_digest.dart';

/// The three piles Archive holds, in the order they are offered.
enum ArchiveTab { later, done, dropped }

extension ArchiveTabLabel on ArchiveTab {
  String get label => switch (this) {
        ArchiveTab.later => 'Later',
        ArchiveTab.done => 'Done',
        ArchiveTab.dropped => 'Dropped',
      };
}

/// Everything that left the working inbox, and where it went: deferred to a
/// quieter moment, closed, or dropped before it ever asked for anything.
///
/// One section rather than three, because the question a user brings here is
/// "where did that thread go" and they do not know which pile answered it. The
/// tabs are how they look in each without leaving the question.
///
/// The piles do not overlap on screen even though the states do: a thread that
/// was deferred and then closed appears under Done ONLY. `laterRows` — the
/// predicate the Later tab and the rail's day rows share — excludes done
/// threads on purpose, so the same thread is never two answers to the same
/// question. Later is what is still waiting for a quieter moment; a closed
/// thread is not waiting for anything.
///
/// Search cuts across all three: the reader who cannot find a thread does not
/// know which pile swallowed it, so one query answers over the whole history —
/// dropped mail included — and takes the place of the tabs while it is up.
///
/// Dumb by construction: props and callbacks only, no `ref` and no provider
/// reads. The screen owns the tab, the selection and every write. Stateful for
/// one thing only — the search box's controller, which holds text nobody has
/// submitted yet and so belongs to the view.
class ArchivePane extends StatefulWidget {
  /// The whole inbox. Each tab picks its own rows out, so the caller never has
  /// to keep three filters in agreement.
  final List<Conversation> conversations;

  /// Which connectors the Done list shows, handed straight to
  /// [ConversationListPane]. The Later tab needs none — its digest re-derives
  /// from what it is given.
  final List<String> sources;

  final ArchiveTab tab;
  final ValueChanged<ArchiveTab> onTab;

  /// A `yyyy-mm-dd` key narrowing the Later tab to one day, or null for every
  /// day. Only the Later tab reads it — a day is a deferral, not a closure.
  final String? dayFilter;

  /// The row's source travels with its id: the host cannot resolve one from
  /// the other, because both connectors mint keys with no knowledge of each
  /// other and a shared key would otherwise open whichever thread the host
  /// happened to scan first.
  final void Function(String source, String conversationId) onOpen;

  /// "This sender belongs in my inbox", by address — the standing correction.
  final void Function(String address, String source) onKeepSender;

  /// "This one thread belongs in my inbox", by `(source, key)`.
  final void Function(String source, String conversationKey) onKeepThread;

  /// Puts a closed thread back into the working inbox.
  final void Function(String source, String conversationKey) onReopen;

  /// The Dropped pile, newest first. Messages rather than threads: a gate
  /// throws out one message, and the thread it belongs to may be perfectly
  /// alive — so this pile is the only part of Archive that is not
  /// conversation-shaped.
  final List<HomeFeedRow> droppedRows;

  /// Whether a first page has come back at all. False is what keeps the empty
  /// line off the screen during the read that is about to fill it.
  final bool droppedLoaded;

  final bool droppedLoadingMore;

  /// Non-null when the newest dropped read failed. Whatever rows are below it
  /// are still real.
  final String? droppedError;

  final VoidCallback onLoadMoreDropped;

  /// Opens the storyline a dropped message was filed under, from its chip.
  final void Function(String storylineId) onOpenStoryline;

  /// The owner pulling one filtered message back through the pipeline. Keyed
  /// by `(source, sourceMessageId)` and not by thread, because a gate takes
  /// one message and a restore gives back exactly that one.
  final void Function(String source, String sourceMessageId) onRestore;

  /// What a query came back with, or null for the tabs.
  final ArchiveSearch? search;

  /// A query is out and no answer has landed yet.
  final bool searching;

  /// Non-null when a search could not run at all. The notice for a search that
  /// ran on text alone rides on [ArchiveSearch] instead, next to the rows it
  /// is a statement about.
  final String? searchNotice;

  final ValueChanged<String> onSearch;
  final VoidCallback onExitSearch;

  /// The clock, injected so a test pins what "3h ago" means — the same reason
  /// [HomeFeedRowTile] takes one.
  final DateTime now;

  /// The tabs⇄results body swap. The home pane's duration, because it is the
  /// same gesture: one body replacing another rather than a page load.
  static const Duration searchSwap = Duration(milliseconds: 160);

  const ArchivePane({
    super.key,
    required this.conversations,
    required this.sources,
    required this.tab,
    required this.onTab,
    required this.dayFilter,
    required this.onOpen,
    required this.onKeepSender,
    required this.onKeepThread,
    required this.onReopen,
    required this.droppedRows,
    required this.droppedLoaded,
    required this.droppedLoadingMore,
    required this.droppedError,
    required this.onLoadMoreDropped,
    required this.onOpenStoryline,
    required this.onRestore,
    required this.search,
    required this.searching,
    required this.searchNotice,
    required this.onSearch,
    required this.onExitSearch,
    required this.now,
  });

  @override
  State<ArchivePane> createState() => _ArchivePaneState();
}

class _ArchivePaneState extends State<ArchivePane> {
  /// The typed query. View state exactly as a scroll position is: the question
  /// belongs to the box, the answer belongs to the notifier.
  final TextEditingController _searchText = TextEditingController();

  @override
  void dispose() {
    _searchText.dispose();
    super.dispose();
  }

  /// The one way out, whichever affordance asked for it: the box empties and
  /// the piles come back.
  void _exitSearch() {
    _searchText.clear();
    widget.onExitSearch();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Hidden while results are up: a search answers across all three
            // piles, and a pill still looking selected over it would claim the
            // rows below belong to one of them.
            if (widget.search == null)
              for (final option in ArchiveTab.values) ...[
                BondFilterPill(
                  label: option.label,
                  selected: option == widget.tab,
                  onTap: () => widget.onTab(option),
                ),
                const SizedBox(width: BondSpacing.s8),
              ],
            // Always present, which is also what holds the row's height steady
            // across the swap.
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: HomeSearchField(
                  controller: _searchText,
                  active: widget.search != null || widget.searching,
                  onSubmit: widget.onSearch,
                  onClear: _exitSearch,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: BondSpacing.s16),
        // Attention rather than error: the piles under it are all still there,
        // and one way of looking through them is off.
        if (widget.searchNotice != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: widget.searchNotice!,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s12),
        ],
        // A line, never a spinner, and never in place of the body: whatever
        // was on screen stays there until the answer lands.
        if (widget.searching) ...[
          Text('Searching…', style: BondType.caption),
          const SizedBox(height: BondSpacing.s8),
        ],
        Expanded(
          child: AnimatedSwitcher(
            duration: ArchivePane.searchSwap,
            child: widget.search == null
                ? KeyedSubtree(
                    key: const ValueKey<String>('archive-tabs'),
                    child: _body(),
                  )
                : KeyedSubtree(
                    key: const ValueKey<String>('archive-search'),
                    child: _searchBody(widget.search!),
                  ),
          ),
        ),
      ],
    );
  }

  /// What a query came back with: how many, for what, and the way back.
  Widget _searchBody(ArchiveSearch search) {
    final count = search.rows.length;
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
                    'Back to archive',
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
        // Between the count and the rows, because it qualifies THEM: these are
        // the text matches, and whatever only the index could have found is
        // missing from the list below.
        if (notice != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: notice,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s12),
        ],
        if (search.rows.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'Nothing in your history matches that.',
                style: BondType.small.copyWith(color: BondColors.inkMuted),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else ...[
          const HomeFeedHeaderRow(),
          Expanded(
            child: ListView.builder(
              itemCount: search.rows.length,
              itemBuilder: (context, index) {
                final row = search.rows[index];
                final tile = HomeFeedRowTile(
                  key: ValueKey<String>('archive-search-${row.feedKey}'),
                  row: row,
                  now: widget.now,
                  muteBar: true,
                  onOpenThread: widget.onOpen,
                  onOpenStoryline: widget.onOpenStoryline,
                );
                // A search spans the piles, so only the rows the gates took
                // get the way back: a hit that was never dropped has nothing
                // to be restored from.
                if (!row.dropped) return tile;
                return _withRestore(tile, row, widget.onRestore);
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _body() => switch (widget.tab) {
        ArchiveTab.later => LaterDigestPanel(
            conversations: widget.conversations,
            dayFilter: widget.dayFilter,
            onOpen: widget.onOpen,
            onKeepSender: widget.onKeepSender,
            onKeepThread: widget.onKeepThread,
          ),
        ArchiveTab.done => ConversationListPane(
            sources: widget.sources,
            filter: InboxFilter.done,
            conversations: widget.conversations,
            selectedId: null,
            onSelect: widget.onOpen,
            onReopen: widget.onReopen,
          ),
        ArchiveTab.dropped => _DroppedList(
            rows: widget.droppedRows,
            loaded: widget.droppedLoaded,
            loadingMore: widget.droppedLoadingMore,
            error: widget.droppedError,
            now: widget.now,
            onLoadMore: widget.onLoadMoreDropped,
            onOpenThread: widget.onOpen,
            onOpenStoryline: widget.onOpenStoryline,
            onRestore: widget.onRestore,
          ),
      };
}

/// One dropped row's tile, with Restore beside it.
///
/// The button sits OUTSIDE the tile for [ConversationListPane]'s reason:
/// [HomeFeedRowTile] is the same row on the home feed and in both of Archive's
/// lists, and a tile that grows an action in one place is a tile that reads
/// differently in the others. Shared by the Dropped pile and the search
/// results so the two cannot drift apart.
Widget _withRestore(
  Widget tile,
  HomeFeedRow row,
  void Function(String source, String sourceMessageId) onRestore,
) =>
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: tile),
        const SizedBox(width: BondSpacing.s8),
        TextButton(
          onPressed: () => onRestore(row.source, row.sourceMessageId),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Restore'),
        ),
      ],
    );

/// The Dropped pile as the home feed's table, because it is the home feed's
/// rows: same columns, same drop-reason chips, same words for what happened.
///
/// Stateful for one reason — the scroll controller. Paging is a property of
/// the viewport rather than of the data, so it lives with the list and not
/// with the pane above it.
class _DroppedList extends StatefulWidget {
  final List<HomeFeedRow> rows;
  final bool loaded;
  final bool loadingMore;
  final String? error;
  final DateTime now;
  final VoidCallback onLoadMore;
  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;
  final void Function(String source, String sourceMessageId) onRestore;

  const _DroppedList({
    required this.rows,
    required this.loaded,
    required this.loadingMore,
    required this.error,
    required this.now,
    required this.onLoadMore,
    required this.onOpenThread,
    required this.onOpenStoryline,
    required this.onRestore,
  });

  /// How close to the bottom the viewport has to get before the next page is
  /// asked for. The home pane's slack, spelled again rather than imported:
  /// this is a screenful of rows ahead of the reader, and the rows are the
  /// same height.
  static const double loadMoreSlack = 600;

  @override
  State<_DroppedList> createState() => _DroppedListState();
}

class _DroppedListState extends State<_DroppedList> {
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
  /// in-flight guard is what makes a repeat call free, which is why there is
  /// no second guard here to disagree with it.
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels >=
        position.maxScrollExtent - _DroppedList.loadMoreSlack) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the rows, never in place of them: a failed page does not
        // unsay the pile already read.
        if (error != null) ...[
          Text(error, style: BondType.small.copyWith(color: BondColors.error)),
          const SizedBox(height: BondSpacing.s12),
        ],
        Expanded(child: widget.rows.isEmpty ? _empty() : _list()),
      ],
    );
  }

  /// Nothing yet reads differently before and after the first page: only one
  /// of them is a claim about the pile.
  Widget _empty() {
    if (!widget.loaded) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(BondSpacing.s32),
        child: Text(
          'Nothing filtered out yet.',
          style: BondType.small,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _list() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HomeFeedHeaderRow(),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: widget.rows.length + (widget.loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == widget.rows.length) {
                  // Words, never a spinner: this is a pile someone leaves
                  // open, and an indeterminate bar on it would never stop.
                  return Padding(
                    padding: const EdgeInsets.all(BondSpacing.s12),
                    child:
                        Text('Loading older messages…', style: BondType.caption),
                  );
                }
                final row = widget.rows[index];
                final tile = HomeFeedRowTile(
                  key: ValueKey<String>('dropped-${row.feedKey}'),
                  row: row,
                  now: widget.now,
                  // These bars are context for mail that was filtered, not
                  // progress anybody is watching.
                  muteBar: true,
                  onOpenThread: widget.onOpenThread,
                  onOpenStoryline: widget.onOpenStoryline,
                );
                return _withRestore(tile, row, widget.onRestore);
              },
            ),
          ),
        ],
      );
}
