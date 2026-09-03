import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/home_models.dart';
import '../services/progress_bus.dart';
import 'app_providers.dart';
import 'prefs_provider.dart';

/// The home feed's read model: one page of the pipeline table at a time,
/// newest first, kept current by the bus the stages tick on.
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
/// newer one that already landed. The live patch obeys the same stamp: a batch
/// that comes back after a reload belongs to a list that no longer exists.
///
/// The liveness is three more rules on top of those.
///
/// **A burst is read once.** The bus carries keys rather than rows, so ticks
/// pile into a window and one batch read turns the window into a patch.
///
/// **The table never moves under a reader.** Arrivals go to the top only while
/// the viewport is anchored there; otherwise they wait behind a count the
/// reader spends when they choose.
///
/// **A row that leaves says why first.** A message the app drops grays where
/// it stands, sits there long enough to read, and then collapses.

/// Shown when a page read failed but there is still a feed to look at.
const String homeFeedStaleMessage =
    "Couldn't read the feed just now — showing what was already here.";

/// The row key the live sets are keyed by — [HomeFeedRow.feedKey], which the
/// pane's list items are keyed by too.
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

  /// Rows that arrived while the user was scrolled away from the top, held
  /// back so the table never moves under a reader.
  final int pendingNewCount;

  /// Keys mid entry animation, mid fade-out, and mid collapse — the drop
  /// sequence in three sets: gray, linger, collapse, gone.
  final Set<String> entering;
  final Set<String> fading;
  final Set<String> collapsing;

  /// Bumped once per settled burst of ticks. The tiles and the hot strip watch
  /// this and nothing else about this state, so a patch that moved one row
  /// does not re-run two aggregate queries per tick.
  final int metricsEpoch;

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
    this.metricsEpoch = 0,
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
    int? metricsEpoch,
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
        metricsEpoch: metricsEpoch ?? this.metricsEpoch,
      );
}

class HomeFeedNotifier extends StateNotifier<HomeFeedState> {
  /// One screen of history per read. Big enough that the first page fills a
  /// tall window without a second round trip, small enough that the keyset
  /// walk stays cheap.
  static const int pageSize = 50;

  /// How long the ticks of one burst are collected before they are read. Under
  /// the eye's patience, and over the gap between two stage writes on the same
  /// message — so a message that moved twice is read once.
  static const Duration tickDebounce = Duration(milliseconds: 250);

  /// The tiles are aggregate queries over a whole day. They can afford to be a
  /// beat behind the table, and cannot afford to run per tick.
  static const Duration metricsDebounce = Duration(milliseconds: 800);

  /// Longer than the row's own entrance, so the mark outlives the animation it
  /// starts and nothing else.
  static const Duration entryClear = Duration(milliseconds: 400);

  /// A screen left open through a week of syncs would otherwise grow a list
  /// nobody is ever going to scroll to the bottom of.
  static const int trimThreshold = 500;
  static const int trimTo = 300;

  /// How many held-back rows are worth holding. Past this the buffer is not a
  /// page in waiting, it is a second copy of the feed.
  static const int bufferCap = 200;

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

  StreamSubscription<ProgressTick>? _ticks;

  /// What this window has seen, deduplicated: three stages moving the same
  /// message is one row to re-read.
  final Map<String, ({String source, String id})> _pendingTicks = {};

  Timer? _debounce;
  Timer? _metricsTimer;

  /// One timer per row on its way out, keyed so a reload can cancel them all
  /// and so a second drop of the same row cannot start two shows.
  final Map<String, Timer> _dropTimers = {};

  /// The timers that take keys back out of [HomeFeedState.entering].
  final Set<Timer> _entryTimers = {};

  /// Arrivals held back while the reader is scrolled away, newest first.
  final List<HomeFeedRow> _buffer = [];

  /// Set when the buffer hit [bufferCap]. From then on the count keeps
  /// climbing but the rows are gone, and releasing re-reads page one.
  bool _bufferOverflowed = false;

  /// What [HomeFeedState.pendingNewCount] is written from. Counted rather than
  /// measured off the buffer, because past the cap there are more messages
  /// waiting than there are rows kept.
  int _pendingCount = 0;

  /// Whether the viewport is at the top. See [setAnchored].
  bool _anchored = true;

  HomeFeedNotifier(
    this._store, {
    bool includeDropped = false,
    Future<void> Function(bool value)? persistIncludeDropped,
    ProgressBus? bus,
  })  : _persistIncludeDropped = persistIncludeDropped ?? _forget,
        super(HomeFeedState(includeDropped: includeDropped)) {
    if (bus != null) _ticks = bus.ticks.listen(_onTick);
  }

  static Future<void> _forget(bool value) async {}

  /// The newest page. Also what a filter change and a failed read come back
  /// through — there is one first-page path, not three.
  ///
  /// A fresh first page owes nothing to the list it replaces: every animation
  /// in flight is cancelled and every held-back row dropped, because the rows
  /// they were about are not necessarily the rows about to arrive.
  Future<void> load() async {
    final seq = ++_fetchSeq;
    _cancelRowTimers();
    _buffer.clear();
    _bufferOverflowed = false;
    _pendingCount = 0;
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
        pendingNewCount: 0,
        entering: const {},
        fading: const {},
        collapsing: const {},
      );
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('home feed read failed: $e');
      state = state.copyWith(
        loaded: true,
        loadingMore: false,
        loadError: homeFeedStaleMessage,
        pendingNewCount: 0,
        entering: const {},
        fading: const {},
        collapsing: const {},
      );
    }
  }

  /// The next page back, cursored on the row at the bottom of the list.
  ///
  /// Keyset rather than an offset, and the cursor is the TAIL: arrivals are
  /// prepended at the head, and an offset would make every one of those shift
  /// a row past the reader's next page.
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

  /// Whether the viewport is at the top of the table.
  ///
  /// A field and not state, deliberately: it decides where the next arrival
  /// goes and nothing renders it, so a scroll must never rebuild the list
  /// being scrolled.
  void setAnchored(bool value) => _anchored = value;

  /// Lets the held-back rows onto the table, newest first, above what is
  /// already there.
  Future<void> releasePending() async {
    if (_bufferOverflowed) {
      // More arrived than were kept, so prepending what survived would show a
      // feed with a hole in it. The newest page IS the newest fifty.
      _buffer.clear();
      _bufferOverflowed = false;
      _pendingCount = 0;
      await load();
      return;
    }
    if (_buffer.isEmpty) {
      if (_pendingCount != 0 || state.pendingNewCount != 0) {
        _pendingCount = 0;
        state = state.copyWith(pendingNewCount: 0);
      }
      return;
    }
    final released = [..._buffer];
    _buffer.clear();
    _pendingCount = 0;
    // Filed in, not stacked on: rows can land on the table while the pill is
    // still up — the reader came back to the top and something newer arrived —
    // and a blind prepend would put these older rows above it. The key guard
    // is for the same table: two rows with one key is a crashed list.
    final rows = [...state.rows];
    final present = {for (final row in rows) row.feedKey};
    final keys = <String>{};
    for (final row in released) {
      if (!present.add(row.feedKey)) continue;
      rows.insert(_sortedIndex(rows, row), row);
      keys.add(row.feedKey);
    }
    state = state.copyWith(
      rows: rows,
      pendingNewCount: 0,
      entering: {...state.entering, ...keys},
    );
    if (keys.isNotEmpty) _clearEnteringLater(keys);
  }

  @override
  void dispose() {
    _ticks?.cancel();
    _debounce?.cancel();
    _metricsTimer?.cancel();
    _cancelRowTimers();
    super.dispose();
  }

  // ── the live path ───────────────────────────────────────────────────────

  /// The tick's key in [HomeFeedRow.feedKey]'s spelling, which is the master
  /// one: the sets above and the pane's list items are keyed by that getter,
  /// and a set keyed one way with widgets keyed another is an animation that
  /// never finds its row.
  String _tickKey(ProgressTick tick) =>
      '${tick.source}\n${tick.sourceMessageId}';

  /// Collects what a burst touched. The read happens once, when it settles.
  ///
  /// A coalescing window and not a restarting debounce: under a sync flood a
  /// restarting timer never fires at all, and the table would freeze at
  /// exactly the moment there is most to watch.
  void _onTick(ProgressTick tick) {
    _pendingTicks[_tickKey(tick)] =
        (source: tick.source, id: tick.sourceMessageId);
    _debounce ??= Timer(tickDebounce, _drainTicks);
  }

  Future<void> _drainTicks() async {
    _debounce = null;
    if (_pendingTicks.isEmpty) return;
    final keys = _pendingTicks.values.toList();
    _pendingTicks.clear();

    final seq = _fetchSeq;
    final List<HomeFeedRow> patch;
    try {
      patch = await _store.progressRowsFor(keys);
    } catch (e) {
      // Nothing to say to the user about this: the next stage write ticks the
      // same rows and the read runs again. A table one beat behind is not
      // worth a banner.
      debugPrint('home feed patch read failed: $e');
      return;
    }
    if (seq != _fetchSeq || !mounted) return;

    _apply(patch);
    _scheduleMetricsBump();
  }

  /// Turns one batch of read-back rows into one new list and one state write.
  void _apply(List<HomeFeedRow> patch) {
    final rows = [...state.rows];
    var index = _indexOf(rows);
    final entered = <String>{};
    final dropping = <String>[];

    // Oldest first, so a run of arrivals reaches the head one after another
    // and every one is marked as arriving. Newest first, only the first would
    // be: each later row would find a newer head above it and be filed under
    // it as history.
    final incoming = [...patch]..sort(_compare);

    for (final row in incoming) {
      final key = row.feedKey;

      // Already on its way out. A patch must not resurrect a row whose removal
      // the reader is watching.
      if (state.fading.contains(key) || state.collapsing.contains(key)) {
        continue;
      }

      final at = index[key];
      if (at != null) {
        // In place, at the same index, never reordered: a bar that filled is
        // not a message that arrived, and a table that resorted itself every
        // time a stage finished would be unreadable.
        rows[at] = row;
        if (row.dropped && !state.includeDropped) dropping.add(key);
        continue;
      }

      final held = _buffer.indexWhere((waiting) => waiting.feedKey == key);
      if (held >= 0) {
        if (row.dropped && !state.includeDropped) {
          // Nobody ever saw it, so there is nothing to show leaving: it just
          // stops being one of the messages the count is promising.
          _buffer.removeAt(held);
          if (_pendingCount > 0) _pendingCount--;
        } else {
          _buffer[held] = row;
        }
        continue;
      }

      if (row.dropped && !state.includeDropped) {
        // The gate's own show: a newsletter appears, grays, and is gone — the
        // one way a reader ever sees what the app is throwing away. Only for a
        // reader who is at the top and can watch it happen; anywhere else it
        // would be a row that flickered past the corner of their eye.
        if (!_anchored) continue;
        if (rows.isNotEmpty && _compare(row, rows.first) <= 0) continue;
        rows.insert(0, row);
        index = _indexOf(rows);
        entered.add(key);
        dropping.add(key);
        continue;
      }

      if (rows.isEmpty) {
        rows.add(row);
        index[key] = 0;
        entered.add(key);
        continue;
      }

      if (_compare(row, rows.first) > 0) {
        if (_anchored) {
          rows.insert(0, row);
          index = _indexOf(rows);
          entered.add(key);
        } else {
          _hold(row);
        }
        continue;
      }

      if (_compare(row, rows.last) < 0) {
        // Older than everything on screen. Only real once the walk has reached
        // the end — otherwise the page that covers it simply has not been read
        // yet, and appending would put it under rows that belong below it.
        if (!state.atEnd) continue;
        rows.add(row);
        index[key] = rows.length - 1;
        continue;
      }

      // Between the two ends: it belongs at a place the reader can already
      // see. No entry mark — a row that slid into the middle of a table did
      // not arrive, the app has only just heard about it.
      rows.insert(_sortedIndex(rows, row), row);
      index = _indexOf(rows);
    }

    var atEnd = state.atEnd;
    if (rows.length > trimThreshold && _anchored) {
      // Only while anchored: cutting the tail off under a reader who walked
      // down to it is the one way this could lose their place.
      rows.removeRange(trimTo, rows.length);
      atEnd = false;
    }

    final present = {for (final row in rows) row.feedKey};
    for (final key in _dropTimers.keys.toList()) {
      if (present.contains(key)) continue;
      _dropTimers.remove(key)!.cancel();
    }

    state = state.copyWith(
      rows: rows,
      atEnd: atEnd,
      pendingNewCount: _pendingCount,
      entering: {...state.entering, ...entered}..retainWhere(present.contains),
      // The gray is written here rather than inside [_beginRemoval], so a
      // batch that drops twenty rows is one rebuild instead of twenty.
      fading: {...state.fading, ...dropping}..retainWhere(present.contains),
      collapsing: {...state.collapsing}..retainWhere(present.contains),
    );

    if (entered.isNotEmpty) _clearEnteringLater(entered);
    for (final key in dropping) {
      if (present.contains(key)) _beginRemoval(key);
    }
  }

  /// Holds an arrival back from a reader who is not at the top.
  void _hold(HomeFeedRow row) {
    _pendingCount++;
    if (_bufferOverflowed) return;
    if (_buffer.length + 1 > bufferCap) {
      _buffer.clear();
      _bufferOverflowed = true;
      return;
    }
    _buffer.insert(_sortedIndex(_buffer, row), row);
  }

  /// The rest of the drop show, once the gray is on screen: linger, collapse,
  /// gone. The second wait is [homeDropCollapse] because that is exactly how
  /// long the row's own height animation takes.
  void _beginRemoval(String key) {
    _dropTimers.remove(key)?.cancel();
    _dropTimers[key] = Timer(homeDropLinger, () {
      _dropTimers.remove(key);
      if (!mounted) return;
      state = state.copyWith(
        fading: {...state.fading}..remove(key),
        collapsing: {...state.collapsing, key},
      );
      _dropTimers[key] = Timer(homeDropCollapse, () {
        _dropTimers.remove(key);
        if (!mounted) return;
        state = state.copyWith(
          rows: [
            for (final row in state.rows)
              if (row.feedKey != key) row,
          ],
          collapsing: {...state.collapsing}..remove(key),
        );
      });
    });
  }

  /// Takes keys back out of [HomeFeedState.entering] once their entrance has
  /// played.
  ///
  /// A key left there would replay its slide every time the row scrolled back
  /// into view: a list item rebuilt after being scrolled off gets fresh state,
  /// and it reads this set to decide whether it is arriving.
  void _clearEnteringLater(Set<String> keys) {
    late final Timer timer;
    timer = Timer(entryClear, () {
      _entryTimers.remove(timer);
      if (!mounted) return;
      final entering = {...state.entering}..removeAll(keys);
      if (entering.length == state.entering.length) return;
      state = state.copyWith(entering: entering);
    });
    _entryTimers.add(timer);
  }

  /// One epoch bump per burst, and at most one per [metricsDebounce] under a
  /// flood. Coalescing rather than restarting, for [_onTick]'s reason.
  void _scheduleMetricsBump() {
    _metricsTimer ??= Timer(metricsDebounce, () {
      _metricsTimer = null;
      if (!mounted) return;
      state = state.copyWith(metricsEpoch: state.metricsEpoch + 1);
    });
  }

  void _cancelRowTimers() {
    for (final timer in _dropTimers.values) {
      timer.cancel();
    }
    _dropTimers.clear();
    for (final timer in _entryTimers) {
      timer.cancel();
    }
    _entryTimers.clear();
  }

  static Map<String, int> _indexOf(List<HomeFeedRow> rows) =>
      {for (var i = 0; i < rows.length; i++) rows[i].feedKey: i};

  /// The feed's order, ascending — so a POSITIVE answer means [a] is newer,
  /// and the list itself runs the other way. Text comparison on the timestamp,
  /// because ISO-8601 sorts as text and that is the order the store's keyset
  /// SQL walks in; the id breaks the ties a busy second produces.
  static int _compare(HomeFeedRow a, HomeFeedRow b) {
    final byTime = a.receivedAt.compareTo(b.receivedAt);
    if (byTime != 0) return byTime;
    return a.sourceMessageId.compareTo(b.sourceMessageId);
  }

  /// Where [row] belongs in a newest-first list: above the first row it is
  /// newer than.
  static int _sortedIndex(List<HomeFeedRow> rows, HomeFeedRow row) {
    for (var i = 0; i < rows.length; i++) {
      if (_compare(row, rows[i]) > 0) return i;
    }
    return rows.length;
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
    bus: ref.watch(progressBusProvider),
  );
});

/// How far back the tiles and the hot strip look. A day, because the question
/// they answer is "what has the app been doing today".
const Duration homeMetricsWindow = Duration(hours: 24);

String _windowStart() =>
    DateTime.now().toUtc().subtract(homeMetricsWindow).toIso8601String();

/// The six numbers over the feed. autoDispose because they are cheap to
/// re-read and stale the moment the pane is closed.
final homeMetricsProvider = FutureProvider.autoDispose<HomeMetrics>((ref) {
  // The live phase's pulse: a settled burst re-reads the tiles. Riverpod
  // carries the previous value through the rebuild, so the numbers change
  // without the tiles ever blinking blank.
  ref.watch(homeFeedProvider.select((s) => s.metricsEpoch));
  return ref.watch(messageStoreProvider).homeMetrics(sinceIso: _windowStart());
});

final hotStorylinesProvider =
    FutureProvider.autoDispose<List<HotStoryline>>((ref) {
  ref.watch(homeFeedProvider.select((s) => s.metricsEpoch));
  return ref
      .watch(messageStoreProvider)
      .hotStorylines(sinceIso: _windowStart());
});
