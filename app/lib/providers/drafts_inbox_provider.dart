import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/drafts_models.dart';
import 'app_providers.dart';
import 'conversations_provider.dart' show inboxSources;

/// What the Drafts & sent pane is looking at: every suggestion still waiting,
/// and what the user has already sent.
///
/// Two indexed reads and no paging. Both lists are bounded by what a person
/// can plausibly have — a mailbox has a handful of live suggestions, and the
/// sent list is capped — so the notifier reads them together and holds them,
/// rather than walking pages nobody scrolls.
///
/// The one rule it shares with the home feed: **stamp before the first await**.
/// A reload started before a dismiss can land after it, and an answer from a
/// question that is no longer standing must write nothing.

@immutable
class DraftsInboxState {
  /// Suggestions waiting, newest-written first.
  final List<PendingDraft> drafts;

  /// Outbound messages, newest first.
  final List<SentRow> sent;

  /// Whether a read has come back at all — success or failure. What separates
  /// "nothing has been read yet" from "nothing is waiting", which are the same
  /// empty list and very different sentences.
  final bool loaded;

  /// Non-null when the newest read failed. Whatever rows are already on screen
  /// stay there: a pane that blanked on a failed re-read would throw away a
  /// list that is still perfectly true.
  final String? error;

  const DraftsInboxState({
    this.drafts = const [],
    this.sent = const [],
    this.loaded = false,
    this.error,
  });

  /// [clearError] rather than a nullable-means-keep [error]: a banner that
  /// could only be set and never cleared would outlive the failure it
  /// described.
  DraftsInboxState copyWith({
    List<PendingDraft>? drafts,
    List<SentRow>? sent,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) =>
      DraftsInboxState(
        drafts: drafts ?? this.drafts,
        sent: sent ?? this.sent,
        loaded: loaded ?? this.loaded,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Shown when a read failed but there is still a list to look at.
const String _staleMessage =
    "Couldn't read your drafts just now — showing what was already here.";

class DraftsInboxNotifier extends StateNotifier<DraftsInboxState> {
  final MessageStore _store;

  /// Which connectors both reads are scoped to. Held rather than defaulted per
  /// call so the two lists can never come back from different mailboxes.
  final List<String> sources;

  /// Numbers every read, so a slow one that lands after a newer one writes
  /// nothing. The same guard `HomeFeedNotifier` uses, and for the same reason:
  /// Dismiss reloads, and the reload it started must not be overtaken by the
  /// one that was already out when the button was pressed.
  int _seq = 0;

  DraftsInboxNotifier(this._store, {required this.sources})
      : super(const DraftsInboxState());

  /// Both lists, together.
  ///
  /// One `loaded: true` at the end rather than one per list: the pane draws
  /// two sections and a state where one is real and the other is still empty
  /// would read as "nothing sent yet" for as long as the second read took.
  Future<void> load() async {
    final seq = ++_seq;
    try {
      final drafts = await _store.pendingDrafts(sources: sources);
      final sent = await _store.recentOutbound(sources: sources);
      if (seq != _seq || !mounted) return;
      state = state.copyWith(
        drafts: drafts,
        sent: sent,
        loaded: true,
        clearError: true,
      );
    } catch (e) {
      if (seq != _seq || !mounted) return;
      debugPrint('drafts inbox read failed: $e');
      state = state.copyWith(loaded: true, error: _staleMessage);
    }
  }

  /// Throws one suggestion away and re-reads.
  ///
  /// The write is `status = 'dismissed'` rather than a delete, which is the
  /// contract the whole `drafts` table is written against: the row survives so
  /// the next enqueue does not immediately write the identical suggestion back.
  ///
  /// Keyed on the MESSAGE, like every other draft write — a thread-scoped one
  /// would dismiss every suggestion the thread ever collected.
  Future<void> dismiss(String source, String replyToMessageId) async {
    try {
      await _store.updateDraftStatus(
        source,
        replyToMessageId,
        status: 'dismissed',
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('dismiss from the drafts pane failed: $e');
      state = state.copyWith(error: _staleMessage);
      return;
    }
    await load();
  }
}

/// NOT autoDispose, on `archiveProvider`'s precedent: the list belongs to the
/// session rather than to the frame, so leaving for a thread and coming back
/// lands on what was there. The screen re-reads it on arrival and after every
/// send, which is what keeps that list honest.
final draftsInboxProvider =
    StateNotifierProvider<DraftsInboxNotifier, DraftsInboxState>((ref) {
  return DraftsInboxNotifier(
    ref.watch(messageStoreProvider),
    sources: inboxSources,
  );
});
