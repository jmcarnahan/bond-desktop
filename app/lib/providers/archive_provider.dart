import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/home_models.dart';
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

  const ArchiveState({
    this.droppedRows = const [],
    this.droppedLoaded = false,
    this.droppedLoadingMore = false,
    this.droppedAtEnd = false,
    this.droppedError,
  });

  /// [clearDroppedError] rather than a nullable-means-keep [droppedError]: a
  /// banner that could only be set and never cleared would outlive the failure
  /// it described.
  ArchiveState copyWith({
    List<HomeFeedRow>? droppedRows,
    bool? droppedLoaded,
    bool? droppedLoadingMore,
    bool? droppedAtEnd,
    String? droppedError,
    bool clearDroppedError = false,
  }) =>
      ArchiveState(
        droppedRows: droppedRows ?? this.droppedRows,
        droppedLoaded: droppedLoaded ?? this.droppedLoaded,
        droppedLoadingMore: droppedLoadingMore ?? this.droppedLoadingMore,
        droppedAtEnd: droppedAtEnd ?? this.droppedAtEnd,
        droppedError:
            clearDroppedError ? null : (droppedError ?? this.droppedError),
      );
}

class ArchiveNotifier extends StateNotifier<ArchiveState> {
  /// One screen of history per read, the home feed's page size: this walks the
  /// same index over the same table, and a reader scrolling one pile has the
  /// same patience as a reader scrolling the other.
  static const int pageSize = 50;

  final MessageStore _store;

  /// Incremented per [refreshDropped]; anything that comes back stale writes
  /// nothing. [loadMoreDropped] reads it without incrementing — an older page
  /// must never win over a newer first page, and must never invalidate one.
  int _fetchSeq = 0;

  /// The guard that makes a repeated scroll-to-bottom free. The pane's scroll
  /// listener fires on every pixel, so this is load-bearing rather than
  /// defensive.
  bool _loadingMore = false;

  ArchiveNotifier(this._store) : super(const ArchiveState());

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
}

/// NOT autoDispose: the pages walked belong to the session, not to the frame,
/// so leaving for a thread and coming back lands on the list that was there.
/// Entering the tab re-reads page one, which is what keeps that list honest.
final archiveProvider =
    StateNotifierProvider<ArchiveNotifier, ArchiveState>((ref) {
  return ArchiveNotifier(ref.watch(messageStoreProvider));
});
