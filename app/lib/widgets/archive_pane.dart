import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'conversation_list_pane.dart';
import 'home_feed_row.dart';
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
/// Dumb by construction: props and callbacks only, no `ref` and no provider
/// reads. The screen owns the tab, the selection and every write.
class ArchivePane extends StatelessWidget {
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

  /// The clock, injected so a test pins what "3h ago" means — the same reason
  /// [HomeFeedRowTile] takes one.
  final DateTime now;

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
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final option in ArchiveTab.values) ...[
              BondFilterPill(
                label: option.label,
                selected: option == tab,
                onTap: () => onTab(option),
              ),
              const SizedBox(width: BondSpacing.s8),
            ],
          ],
        ),
        const SizedBox(height: BondSpacing.s16),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() => switch (tab) {
        ArchiveTab.later => LaterDigestPanel(
            conversations: conversations,
            dayFilter: dayFilter,
            onOpen: onOpen,
            onKeepSender: onKeepSender,
            onKeepThread: onKeepThread,
          ),
        ArchiveTab.done => ConversationListPane(
            sources: sources,
            filter: InboxFilter.done,
            conversations: conversations,
            selectedId: null,
            onSelect: onOpen,
            onReopen: onReopen,
          ),
        ArchiveTab.dropped => _DroppedList(
            rows: droppedRows,
            loaded: droppedLoaded,
            loadingMore: droppedLoadingMore,
            error: droppedError,
            now: now,
            onLoadMore: onLoadMoreDropped,
            onOpenThread: onOpen,
            onOpenStoryline: onOpenStoryline,
          ),
      };
}

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

  const _DroppedList({
    required this.rows,
    required this.loaded,
    required this.loadingMore,
    required this.error,
    required this.now,
    required this.onLoadMore,
    required this.onOpenThread,
    required this.onOpenStoryline,
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
                return HomeFeedRowTile(
                  key: ValueKey<String>('dropped-${row.feedKey}'),
                  row: row,
                  now: widget.now,
                  // These bars are context for mail that was filtered, not
                  // progress anybody is watching.
                  muteBar: true,
                  onOpenThread: widget.onOpenThread,
                  onOpenStoryline: widget.onOpenStoryline,
                );
              },
            ),
          ),
        ],
      );
}
