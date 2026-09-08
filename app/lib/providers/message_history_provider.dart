import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/home_models.dart';
import '../models/message_history.dart';
import '../services/progress_bus.dart';
import 'app_providers.dart';

/// One message's whole story, kept current while somebody is reading it.
///
/// The rules are `home_provider.dart`'s, minus the paging. **Stamp before the
/// first await**: eight reads make one answer, and a slow one that finally
/// landed must not overwrite a newer one that already did. **Once loaded,
/// never blank**: a read that fails keeps whatever is on screen and says so to
/// the console, because a screen someone opened to find out what went wrong is
/// the last place to show them a spinner instead.
///
/// Live for the reason the feed is: the stages this screen renders are still
/// running while it is open — a retry the reader just pressed, a draft landing
/// behind them — and a rail that froze the moment it was drawn would be a
/// worse answer than no rail.

/// One message's history, re-read behind the ticks its own stages publish.
class MessageHistoryNotifier extends StateNotifier<AsyncValue<MessageHistory>> {
  /// How long a burst of ticks is collected before the row is re-read. The
  /// feed's number, for the feed's reason: under the eye's patience, and over
  /// the gap between two stage writes about the same message.
  static const Duration tickDebounce = Duration(milliseconds: 250);

  final MessageStore _store;

  /// The keys this notifier is about. Public because the screen holding it
  /// needs them for the levers beside the story — Retry, Ignore, Restore all
  /// take the same pair.
  final String source;
  final String sourceMessageId;

  /// The attention bar, read live on every load rather than captured once: it
  /// is a preference the owner can move, and a score shown against a stale
  /// threshold explains the wrong decision.
  final Future<double> Function() threshold;

  StreamSubscription<ProgressTick>? _ticks;
  Timer? _debounce;

  /// Incremented per [load]; anything that comes back stale writes nothing.
  int _fetchSeq = 0;

  MessageHistoryNotifier(
    this._store, {
    required this.source,
    required this.sourceMessageId,
    ProgressBus bus = const ProgressBus.disabled(),
    required this.threshold,
  }) : super(const AsyncValue.loading()) {
    _ticks = bus.ticks.listen(_onTick);
  }

  /// Reads everything at once and folds it into one answer.
  ///
  /// The thread-keyed reads wait on the message row for their key, which is
  /// why this is a chain rather than a `Future.wait`: the conversation, its AI
  /// state, the memberships and the blocks are all questions about a thread
  /// this message has not named yet.
  Future<void> load() async {
    final seq = ++_fetchSeq;
    try {
      final message = await _store.getMessageRow(source, sourceMessageId);
      final progress = await _store.getProgressRow(source, sourceMessageId);
      final conversationKey = (message?['conversation_key'] as String?) ??
          (progress?['conversation_key'] as String?) ??
          '';

      final rows = await _store.progressRowsFor([
        (source: source, id: sourceMessageId),
      ]);
      final HomeFeedRow? row = rows.isEmpty ? null : rows.first;

      final conversation = conversationKey.isEmpty
          ? null
          : await _store.getConversationRow(source, conversationKey);
      final conversationAi = conversationKey.isEmpty
          ? null
          : await _store.getConversationAi(source, conversationKey);
      final work = await _store.workItemsFor(
        source,
        sourceMessageId,
        conversationKey,
      );
      final memberships = conversationKey.isEmpty
          ? const <Map<String, Object?>>[]
          : await _store.membershipsForThread(source, conversationKey);
      final blocks = conversationKey.isEmpty
          ? const <Map<String, Object?>>[]
          : await _store.blocksForThread(source, conversationKey);
      final activity = await _store.activityForEntity(
        sourceMessageId: sourceMessageId,
        conversationKey: conversationKey,
      );
      final bar = await threshold();

      if (seq != _fetchSeq || !mounted) return;
      state = AsyncValue.data(
        MessageHistory.assemble(
          source: source,
          sourceMessageId: sourceMessageId,
          message: message,
          conversation: conversation,
          conversationAi: conversationAi,
          progress: progress,
          row: row,
          work: work,
          memberships: memberships,
          blocks: blocks,
          activity: activity,
          threshold: bar,
        ),
      );
    } catch (e, stack) {
      if (seq != _fetchSeq || !mounted) return;
      debugPrint('history: $source/$sourceMessageId failed: $e');
      // Once loaded, never blank: the story already on screen is still true of
      // everything up to the moment it was read.
      if (!state.hasValue) state = AsyncValue.error(e, stack);
    }
  }

  /// The same read, for the changes that tick nothing.
  ///
  /// A thread-level decision — filing the thread into a storyline, lifting a
  /// block — moves rows this screen renders without moving any stage, so
  /// nothing is published for [_onTick] to hear. The screen calls this itself
  /// after an action it took.
  Future<void> reload() => load();

  /// Coalesces a burst into one re-read, the way the feed does.
  ///
  /// A per-message filter is enough: the storyline stage ticks once per
  /// message it moved, and the needs-you flag does too, so every write this
  /// screen cares about arrives under this message's own keys.
  void _onTick(ProgressTick tick) {
    if (tick.source != source) return;
    if (tick.sourceMessageId != sourceMessageId) return;
    _debounce ??= Timer(tickDebounce, () {
      _debounce = null;
      unawaited(load());
    });
  }

  @override
  void dispose() {
    _ticks?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}

/// The screen's door onto one message. `autoDispose` because the reader leaves
/// and the subscription must go with them.
final messageHistoryProvider = StateNotifierProvider.autoDispose.family<
    MessageHistoryNotifier,
    AsyncValue<MessageHistory>,
    ({String source, String id})>(
  (ref, key) {
    final store = ref.watch(messageStoreProvider);
    final notifier = MessageHistoryNotifier(
      store,
      source: key.source,
      sourceMessageId: key.id,
      bus: ref.watch(progressBusProvider),
      threshold: attentionThresholdReader(store),
    );
    unawaited(notifier.load());
    return notifier;
  },
);
