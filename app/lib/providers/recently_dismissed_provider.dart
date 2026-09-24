import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/dismissed_thread.dart';
import 'app_providers.dart';

/// What the Archive's Recently dismissed tab is looking at: every thread the
/// owner closed or a rule filed in the last [RecentlyDismissedNotifier.window],
/// newest first — requirement 12i, the view that lets an aggressive rule never
/// lose something silently.
///
/// `ArchiveNotifier`'s shape and its two rules. **Once loaded, never blank**: a
/// read that fails keeps whatever rows are on screen and hangs a sentence off
/// them. **Stamp before the first await**: a read that comes back after a newer
/// one started writes nothing.
///
/// One read rather than pages: seven days of dismissals is a screenful or two,
/// and `MessageStore.recentlyDismissed` is bounded by the window rather than a
/// cursor. No bus subscription either, on the Dropped tab's precedent — the
/// screen re-asks on every entry to the tab, which is when it is worth being
/// current.

const String _recentStaleMessage =
    "Couldn't read what was dismissed just now — showing what was already here.";

@immutable
class RecentlyDismissedState {
  /// Newest first, the order the store hands them over.
  final List<DismissedThread> rows;

  /// Whether a read has come back at all — success or failure. What separates
  /// "nothing has been read yet" from "nothing was dismissed".
  final bool loaded;

  /// Non-null when the newest read failed. The rows above it are still real.
  final String? error;

  const RecentlyDismissedState({
    this.rows = const [],
    this.loaded = false,
    this.error,
  });
}

class RecentlyDismissedNotifier extends StateNotifier<RecentlyDismissedState> {
  /// How far back the view looks. Seven days is requirement 12i's own number:
  /// long enough to notice a thread went missing over a weekend, short enough
  /// that the list is a check rather than a second archive.
  static const Duration window = Duration(days: 7);

  final MessageStore _store;

  /// The clock, injected so a test pins where the window starts.
  final DateTime Function() _now;

  /// Incremented per [refresh]; anything that comes back stale writes nothing.
  int _fetchSeq = 0;

  RecentlyDismissedNotifier(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(const RecentlyDismissedState());

  /// The whole window, read fresh.
  Future<void> refresh() async {
    final seq = ++_fetchSeq;
    try {
      final rows = await _store.recentlyDismissed(
        sinceIso: MessageStore.isoStamp(_now().toUtc().subtract(window)),
      );
      if (seq != _fetchSeq || !mounted) return;
      state = RecentlyDismissedState(rows: rows, loaded: true);
    } catch (e) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('recently dismissed read failed: $e');
      state = RecentlyDismissedState(
        rows: state.rows,
        loaded: true,
        error: _recentStaleMessage,
      );
    }
  }

  /// The optimistic half of Reopen and Show again: the row leaves now, and the
  /// next [refresh] is what makes it true rather than merely shown — the
  /// Dropped pile's `noteRestored` split, for its reason.
  void noteShown(String source, String conversationKey) {
    state = RecentlyDismissedState(
      rows: [
        for (final row in state.rows)
          if (row.conversation.source != source ||
              row.conversation.id != conversationKey)
            row,
      ],
      loaded: state.loaded,
      error: state.error,
    );
  }
}

/// NOT autoDispose, `archiveProvider`'s reason: the list belongs to the
/// session, and entering the tab re-reads it.
final recentlyDismissedProvider = StateNotifierProvider<
    RecentlyDismissedNotifier, RecentlyDismissedState>((ref) {
  return RecentlyDismissedNotifier(ref.watch(messageStoreProvider));
});
