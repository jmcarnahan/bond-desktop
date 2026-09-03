import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/home_models.dart';
import 'app_providers.dart';
import 'prefs_provider.dart';

/// The home feed's read model: one page of the pipeline table at a time,
/// newest first.
///
/// Two rules shape it, both borrowed from `conversations_provider.dart`.
///
/// **Once loaded, never blank.** A read that fails keeps the rows already on
/// screen and hangs a sentence off them; a screen someone leaves open all day
/// must not empty itself because one query lost a race with a sync.
///
/// **Stamp before the first await.** Every read numbers itself and re-checks
/// on the way back, on the failure path as much as the success one — without
/// it a slow first page that eventually failed would stamp its error over a
/// newer one that already landed.
///
/// Deliberately timer-free and stream-free: liveness is its own phase, and the
/// state below already carries the fields it will fill.

/// Shown when a page read failed but there is still a feed to look at.
const String homeFeedStaleMessage =
    "Couldn't read the feed just now — showing what was already here.";

/// The row key the live phase's sets are keyed by — [HomeFeedRow.feedKey],
/// which the pane's list items are keyed by too.
String homeRowKey(HomeFeedRow row) => row.feedKey;

@immutable
class HomeFeedState {
  /// Newest first, the order the store hands them over.
  final List<HomeFeedRow> rows;

  /// Whether a first page has come back at all — success or failure. What
  /// separates "nothing has arrived yet" from "nothing is here", which are the
  /// same empty list and very different sentences.
  final bool loaded;

  final bool loadingMore;

  /// True once a page came back shorter than it asked for: there is no older
  /// history left to walk.
  final bool atEnd;

  /// Non-null when the newest read failed. The rows above it are still real,
  /// just older than the user asked for.
  final String? loadError;

  final bool includeDropped;

  // ── the live phase's fields, present and inert ──────────────────────────
  //
  // Defaulted empty and written by nothing here. They live in this state now
  // rather than later so the phase that fills them extends this class instead
  // of reshaping it under the widgets already reading it.

  /// Rows that arrived while the user was scrolled away from the top, held
  /// back so the table never moves under a reader.
  final int pendingNewCount;

  /// Keys mid entry animation, mid fade-out, and mid collapse. See the drop
  /// sequence in the plan: gray, linger, collapse, gone.
  final Set<String> entering;
  final Set<String> fading;
  final Set<String> collapsing;

  const HomeFeedState({
    this.rows = const [],
    this.loaded = false,
    this.loadingMore = false,
    this.atEnd = false,
    this.loadError,
    this.includeDropped = false,
    this.pendingNewCount = 0,
    this.entering = const {},
    this.fading = const {},
    this.collapsing = const {},
  });

  /// [clearLoadError] rather than a nullable-means-keep [loadError]: a banner
  /// that could only be set and never cleared would outlive the failure it
  /// described.
  HomeFeedState copyWith({
    List<HomeFeedRow>? rows,
    bool? loaded,
    bool? loadingMore,
    bool? atEnd,
    String? loadError,
    bool clearLoadError = false,
    bool? includeDropped,
    int? pendingNewCount,
    Set<String>? entering,
    Set<String>? fading,
    Set<String>? collapsing,
  }) =>
      HomeFeedState(
        rows: rows ?? this.rows,
        loaded: loaded ?? this.loaded,
        loadingMore: loadingMore ?? this.loadingMore,
        atEnd: atEnd ?? this.atEnd,
        loadError: clearLoadError ? null : (loadError ?? this.loadError),
        includeDropped: includeDropped ?? this.includeDropped,
        pendingNewCount: pendingNewCount ?? this.pendingNewCount,
        entering: entering ?? this.entering,
        fading: fading ?? this.fading,
        collapsing: collapsing ?? this.collapsing,
      );
}

class HomeFeedNotifier extends StateNotifier<HomeFeedState> {
  /// One screen of history per read. Big enough that the first page fills a
  /// tall window without a second round trip, small enough that the keyset
  /// walk stays cheap.
  static const int pageSize = 50;

  final MessageStore _store;

  /// Where the "Show dropped" choice is written down. A callback rather than
  /// the prefs notifier itself, so this class can be built in a test with no
  /// provider container around it.
  final Future<void> Function(bool value) _persistIncludeDropped;

  /// Incremented per [load]; anything that comes back stale writes nothing.
  /// [loadMore] reads it without incrementing — an older page must never win
  /// over a newer first page, and it must never invalidate one either.
  int _fetchSeq = 0;

  /// The guard that makes a repeated scroll-to-bottom free. The scroll
  /// listener fires on every pixel, so this is load-bearing rather than
  /// defensive.
  bool _loadingMore = false;

  HomeFeedNotifier(
    this._store, {
    bool includeDropped = false,
    Future<void> Function(bool value)? persistIncludeDropped,
  })  : _persistIncludeDropped = persistIncludeDropped ?? _forget,
        super(HomeFeedState(includeDropped: includeDropped));

  static Future<void> _forget(bool value) async {}

  /// The newest page. Also what a filter change and a failed read come back
  /// through — there is one first-page path, not three.
  Future<void> load() async {
    final seq = ++_fetchSeq;
    try {
      final rows = await _store.pageHomeFeed(
        limit: pageSize,
        includeDropped: state.includeDropped,
      );
      if (seq != _fetchSeq || !mounted) return;
      state = state.copyWith(
        rows: rows,
        loaded: true,
        loadingMore: false,
        atEnd: rows.length < pageSize,
        clearLoadError: true,
      );
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('home feed read failed: $e');
      state = state.copyWith(
        loaded: true,
        loadingMore: false,
        loadError: homeFeedStaleMessage,
      );
    }
  }

  /// The next page back, cursored on the row at the bottom of the list.
  ///
  /// Keyset rather than an offset, and the cursor is the TAIL: the live phase
  /// prepends rows at the head, and an offset would make every one of those
  /// shift a row past the reader's next page.
  Future<void> loadMore() async {
    if (_loadingMore || state.atEnd || state.rows.isEmpty) return;
    final tail = state.rows.last;
    final seq = _fetchSeq;
    _loadingMore = true;
    state = state.copyWith(loadingMore: true);
    try {
      final rows = await _store.pageHomeFeed(
        beforeReceivedAt: tail.receivedAt,
        beforeSourceMessageId: tail.sourceMessageId,
        limit: pageSize,
        includeDropped: state.includeDropped,
      );
      if (seq != _fetchSeq || !mounted) return;
      state = state.copyWith(
        rows: [...state.rows, ...rows],
        loadingMore: false,
        atEnd: rows.length < pageSize,
      );
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('home feed page read failed: $e');
      state = state.copyWith(
        loadingMore: false,
        loadError: homeFeedStaleMessage,
      );
    } finally {
      _loadingMore = false;
    }
  }

  /// Shows or hides what the app decided the user did not need.
  ///
  /// The pages already walked are the wrong pages the moment this flips — they
  /// were read against the other index — so this goes back to page one rather
  /// than trying to merge dropped rows into what is on screen. The rows stay
  /// up until the new first page lands: once loaded, never blank.
  Future<void> setIncludeDropped(bool value) async {
    state = state.copyWith(includeDropped: value, atEnd: false);
    try {
      await _persistIncludeDropped(value);
    } catch (e) {
      // The toggle is what the user asked for; a failed write costs them the
      // setting next launch and must not cost them the reload now.
      debugPrint('storing the home dropped filter failed: $e');
    }
    await load();
  }
}

/// NOT autoDispose: the pages walked and the place scrolled to belong to the
/// session, not to the frame. Swapping to a thread and back must come back to
/// the same table rather than to a re-read first page.
final homeFeedProvider =
    StateNotifierProvider<HomeFeedNotifier, HomeFeedState>((ref) {
  return HomeFeedNotifier(
    ref.watch(messageStoreProvider),
    // Read, not watched: this seeds the notifier, and watching it would
    // rebuild the whole feed — pages, scroll and all — every time the toggle
    // it writes came back round.
    includeDropped: ref.read(appPrefsProvider).homeShowDropped,
    persistIncludeDropped: (value) =>
        ref.read(appPrefsProvider.notifier).setHomeShowDropped(value),
  );
});

/// How far back the tiles and the hot strip look. A day, because the question
/// they answer is "what has the app been doing today".
const Duration homeMetricsWindow = Duration(hours: 24);

String _windowStart() =>
    DateTime.now().toUtc().subtract(homeMetricsWindow).toIso8601String();

/// The six numbers over the feed. autoDispose because they are cheap to
/// re-read and stale the moment the pane is closed; the live phase gives them
/// an epoch to watch so a settle refreshes them.
final homeMetricsProvider = FutureProvider.autoDispose<HomeMetrics>(
  (ref) => ref.watch(messageStoreProvider).homeMetrics(sinceIso: _windowStart()),
);

final hotStorylinesProvider = FutureProvider.autoDispose<List<HotStoryline>>(
  (ref) =>
      ref.watch(messageStoreProvider).hotStorylines(sinceIso: _windowStart()),
);
