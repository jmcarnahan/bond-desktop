import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/home_models.dart';
import '../services/message_search.dart';
import 'app_providers.dart';

/// What the Archive's Dropped tab is looking at: every message the pipeline
/// filtered out, newest first, one keyset page at a time.
///
/// A list and not a search. A gate-dropped message never reached the embedder,
/// so there is nothing indexed to ask a question of — the only way to see this
/// pile is to read it off `message_progress` in received order.
///
/// The tab the pane is showing is NOT here: `InboxScreen` owns that, the way
/// it owns the day filter. This notifier holds the dropped list and nothing
/// else, so the two piles that are still conversation-shaped keep answering
/// from `conversationsProvider` exactly as they did.
///
/// The two rules are the home feed's, for the same reasons. **Once loaded,
/// never blank**: a read that fails keeps whatever rows are on screen and
/// hangs a sentence off them. **Stamp before the first await**: every read
/// numbers itself and re-checks on the way back, on the failure path as much
/// as the success one.

/// Shown when a page read failed but there is still a list to look at.
const String _droppedStaleMessage =
    "Couldn't read the dropped pile just now — showing what was already here.";

/// How the pane asks its question. A callback rather than a [MessageSearch],
/// on the home feed's precedent: the notifier owes nothing to the embedding
/// server or the index, so a test can hand it an answer without either.
typedef ArchiveSearchRunner = Future<ArchiveSearchResult> Function(String query);

@immutable
class ArchiveState {
  /// Newest first, the order the store hands them over.
  final List<HomeFeedRow> droppedRows;

  /// Whether a first page has come back at all — success or failure. What
  /// separates "nothing has been read yet" from "nothing was filtered out",
  /// which are the same empty list and very different sentences.
  final bool droppedLoaded;

  final bool droppedLoadingMore;

  /// True once a page came back shorter than it asked for: there is no older
  /// history left to walk.
  final bool droppedAtEnd;

  /// Non-null when the newest read failed. The rows above it are still real.
  final String? droppedError;

  /// The results a query came back with, or null for the tabs. Cross-tab by
  /// nature: one search spans all three piles, because the reader asking it
  /// does not know which one holds the answer.
  final ArchiveSearch? search;

  /// A query is out and no answer has landed yet.
  final bool searching;

  /// Only ever the sentence for a search that could not be RUN. A search that
  /// ran on text alone carries its own notice on [ArchiveSearch] instead,
  /// because that one is a fact about the results underneath it.
  final String? searchNotice;

  const ArchiveState({
    this.droppedRows = const [],
    this.droppedLoaded = false,
    this.droppedLoadingMore = false,
    this.droppedAtEnd = false,
    this.droppedError,
    this.search,
    this.searching = false,
    this.searchNotice,
  });

  /// [clearDroppedError] rather than a nullable-means-keep [droppedError]: a
  /// banner that could only be set and never cleared would outlive the failure
  /// it described. [clearSearch] and [clearSearchNotice] are the same rule —
  /// leaving search is the whole point of having entered it.
  ArchiveState copyWith({
    List<HomeFeedRow>? droppedRows,
    bool? droppedLoaded,
    bool? droppedLoadingMore,
    bool? droppedAtEnd,
    String? droppedError,
    bool clearDroppedError = false,
    ArchiveSearch? search,
    bool? searching,
    String? searchNotice,
    bool clearSearch = false,
    bool clearSearchNotice = false,
  }) =>
      ArchiveState(
        droppedRows: droppedRows ?? this.droppedRows,
        droppedLoaded: droppedLoaded ?? this.droppedLoaded,
        droppedLoadingMore: droppedLoadingMore ?? this.droppedLoadingMore,
        droppedAtEnd: droppedAtEnd ?? this.droppedAtEnd,
        droppedError:
            clearDroppedError ? null : (droppedError ?? this.droppedError),
        search: clearSearch ? null : (search ?? this.search),
        searching: searching ?? this.searching,
        searchNotice:
            clearSearchNotice ? null : (searchNotice ?? this.searchNotice),
      );
}

class ArchiveNotifier extends StateNotifier<ArchiveState> {
  /// One screen of history per read, the home feed's page size: this walks the
  /// same index over the same table, and a reader scrolling one pile has the
  /// same patience as a reader scrolling the other.
  static const int pageSize = 50;

  final MessageStore _store;

  /// Null in the tests that only walk the dropped pile: a notifier with no
  /// runner simply has no search, rather than half of one.
  final ArchiveSearchRunner? _searchRunner;

  /// Incremented per [refreshDropped]; anything that comes back stale writes
  /// nothing. [loadMoreDropped] reads it without incrementing — an older page
  /// must never win over a newer first page, and must never invalidate one.
  int _fetchSeq = 0;

  /// The guard that makes a repeated scroll-to-bottom free. The pane's scroll
  /// listener fires on every pixel, so this is load-bearing rather than
  /// defensive.
  bool _loadingMore = false;

  /// Incremented per [submitSearch] and again on the way out, so an answer
  /// that lands late writes nothing. Separate from [_fetchSeq]: a page read
  /// and a query are different questions and neither invalidates the other.
  int _searchSeq = 0;

  ArchiveNotifier(this._store, {ArchiveSearchRunner? searchRunner})
      : _searchRunner = searchRunner,
        super(const ArchiveState());

  /// The newest page, read fresh.
  ///
  /// Deliberately not source-filtered: the Dropped tab speaks the home feed's
  /// message-shaped vocabulary, and Home never filters by connector either. A
  /// pile of filtered mail that hid half of itself behind a rail toggle would
  /// answer "where did that go" with silence.
  ///
  /// No bus subscription this phase. The pile only grows behind a sweep, and
  /// the screen re-asks on every entry to the tab, so a live patch would buy a
  /// row landing under a reader who is not watching for it.
  Future<void> refreshDropped() async {
    final seq = ++_fetchSeq;
    try {
      final rows = await _store.pageHomeFeed(
        limit: pageSize,
        onlyDropped: true,
      );
      if (seq != _fetchSeq || !mounted) return;
      state = state.copyWith(
        droppedRows: rows,
        droppedLoaded: true,
        droppedLoadingMore: false,
        droppedAtEnd: rows.length < pageSize,
        clearDroppedError: true,
      );
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('dropped pile read failed: $e');
      state = state.copyWith(
        droppedLoaded: true,
        droppedLoadingMore: false,
        droppedError: _droppedStaleMessage,
      );
    }
  }

  /// The next page back, cursored on the row at the bottom of the list.
  Future<void> loadMoreDropped() async {
    if (_loadingMore || state.droppedAtEnd || state.droppedRows.isEmpty) return;
    final tail = state.droppedRows.last;
    final seq = _fetchSeq;
    _loadingMore = true;
    state = state.copyWith(droppedLoadingMore: true);
    try {
      final rows = await _store.pageHomeFeed(
        beforeReceivedAt: tail.receivedAt,
        beforeSourceMessageId: tail.sourceMessageId,
        limit: pageSize,
        onlyDropped: true,
      );
      if (seq != _fetchSeq || !mounted) return;
      state = state.copyWith(
        droppedRows: [...state.droppedRows, ...rows],
        droppedLoadingMore: false,
        droppedAtEnd: rows.length < pageSize,
      );
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('dropped pile page read failed: $e');
      state = state.copyWith(
        droppedLoadingMore: false,
        droppedError: _droppedStaleMessage,
      );
    } finally {
      _loadingMore = false;
    }
  }

  /// Asks the history a sentence and shows what comes back.
  ///
  /// Submission is the whole gate, the home feed's reason: a query costs an
  /// embedding call, so this runs on Enter and never on a keystroke.
  ///
  /// Unlike Home, a result ALWAYS swaps the body in. Home refuses when the
  /// index is down because it would be trading a working feed for an empty
  /// list; here the search still ran — the text pass answered — so a result
  /// carrying a notice is still a result, and the notice rides on it.
  /// [ArchiveState.searchNotice] is left for the one case that is not an
  /// answer at all: the runner throwing.
  Future<void> submitSearch(String query) async {
    final text = query.trim();
    if (text.isEmpty) return;
    final runner = _searchRunner;
    if (runner == null) return;

    final seq = ++_searchSeq;
    state = state.copyWith(searching: true, clearSearchNotice: true);

    final ArchiveSearchResult result;
    try {
      result = await runner(text);
    } catch (e) {
      // [MessageSearch] answers rather than throws, by contract — but the
      // runner crosses the database on its way there, and a screen left
      // searching forever is the one outcome this must not have.
      if (seq != _searchSeq || !mounted) return;
      debugPrint('archive search failed: $e');
      state = state.copyWith(
        searching: false,
        searchNotice: "Search failed — couldn't read the index.",
      );
      return;
    }
    if (seq != _searchSeq || !mounted) return;
    state = state.copyWith(
      search: ArchiveSearch(result.query, result.rows, result.notice),
      searching: false,
    );
  }

  /// Back to the three piles.
  ///
  /// The stamp moves first: an answer still in flight belongs to a search that
  /// no longer exists, and it must not land on the tabs the reader just
  /// returned to.
  void exitSearch() {
    _searchSeq++;
    state = state.copyWith(
      clearSearch: true,
      searching: false,
      clearSearchNotice: true,
    );
  }
}

/// NOT autoDispose: the pages walked belong to the session, not to the frame,
/// so leaving for a thread and coming back lands on the list that was there.
/// Entering the tab re-reads page one, which is what keeps that list honest.
final archiveProvider =
    StateNotifierProvider<ArchiveNotifier, ArchiveState>((ref) {
  return ArchiveNotifier(
    ref.watch(messageStoreProvider),
    searchRunner: (query) =>
        ref.read(messageSearchProvider).searchArchive(query),
  );
});
