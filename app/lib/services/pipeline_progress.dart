import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import 'progress_bus.dart';

/// Writes down where each message is in the pipeline, and says so out loud.
///
/// Every method is the same two steps: one targeted UPDATE on
/// `message_progress`, then one tick on the [ProgressBus]. The split is the
/// house rule — [MessageStore] holds the SQL and knows nothing about streams,
/// this holds the pairing and knows nothing about SQL — and it is what keeps
/// a live screen from reaching into the store's contract.
///
/// It cannot break the pipeline it records. Every method swallows its own
/// failures to a [debugPrint], for [ActivityLog]'s reason: a stage that ran
/// and was not written down is a bar that fills late, and that is never worth
/// failing the work over.
///
/// [PipelineProgress.disabled] is the default every instrumented constructor
/// takes, so the several hundred existing tests that build a queue without
/// caring about the home screen compile and run unchanged.
class PipelineProgress {
  final MessageStore? _store;
  final ProgressBus _bus;

  PipelineProgress(MessageStore store, {ProgressBus? bus})
      : _store = store,
        _bus = bus ?? const ProgressBus.disabled();

  /// A recorder that writes nothing and emits nothing.
  const PipelineProgress.disabled()
      : _store = null,
        _bus = const ProgressBus.disabled();

  /// Which live storyline a thread landed in, or null.
  ///
  /// Here rather than on the caller because the assignment handler is thin by
  /// design — it holds a service and no store — and because this recorder
  /// already has one. `AssignOutcome` deliberately did not grow a field to
  /// carry it: the id matters to this row and to nothing else in the queue.
  Future<String?> assignedStorylineId(
    String source,
    String conversationKey,
  ) async {
    final store = _store;
    if (store == null) return null;
    try {
      final ids = await store.storylineIdsFor(source, conversationKey);
      return ids.isEmpty ? null : ids.first;
    } catch (e) {
      debugPrint('progress: storyline lookup for $conversationKey failed: $e');
      return null;
    }
  }

  /// The tick that says a new message exists.
  ///
  /// Publish only, and the one method here that writes nothing: the ingest
  /// stage's row is composed inside [MessageStore.upsertMessage]'s own
  /// transaction, so by the time a caller can say the message is new the write
  /// has already happened. [receivedAt] is that call's answer.
  ///
  /// Without it the screen would never see the messages it most needs to show:
  /// a gate-dropped newsletter is finished at ingest and no later stage runs
  /// for it, and everything else waits on triage before it says a word.
  void noteIngest(
    String source,
    String sourceMessageId, {
    required String receivedAt,
  }) {
    _bus.publish(
      ProgressTick(
        source: source,
        sourceMessageId: sourceMessageId,
        stage: 'ingest',
        state: 'done',
        receivedAt: receivedAt,
      ),
    );
  }

  Future<void> noteTriage(
    String source,
    String sourceMessageId, {
    required String state,
    String? urgency,
    String? gateReason,
  }) =>
      _one(
        source,
        sourceMessageId,
        'triage',
        state,
        (store) => store.writeTriageProgress(
          source,
          sourceMessageId,
          state: state,
          urgency: urgency,
          gateReason: gateReason,
        ),
      );

  Future<void> noteExtract(
    String source,
    String sourceMessageId, {
    required String state,
  }) =>
      _one(
        source,
        sourceMessageId,
        'extract',
        state,
        (store) => store.writeExtractProgress(
          source,
          sourceMessageId,
          state: state,
        ),
      );

  /// One outcome for a whole thread — the grain the storyline queue works at.
  /// Ticks once per message it actually moved.
  Future<void> noteStoryline(
    String source,
    String conversationKey, {
    required String state,
    String? storylineId,
  }) async {
    final store = _store;
    if (store == null) return;
    try {
      final touched = await store.writeStorylineProgress(
        source,
        conversationKey,
        state: state,
        storylineId: storylineId,
      );
      for (final row in touched) {
        _bus.publish(
          ProgressTick(
            source: source,
            sourceMessageId: row.sourceMessageId,
            stage: 'storyline',
            state: state,
            receivedAt: row.receivedAt,
          ),
        );
      }
    } catch (e) {
      debugPrint('progress: storyline $source/$conversationKey failed: $e');
    }
  }

  Future<void> noteSettled(
    String source,
    String sourceMessageId, {
    required bool needsYou,
    required String reason,
    required bool dropped,
  }) =>
      _one(
        source,
        sourceMessageId,
        'settle',
        'done',
        (store) => store.writeSettledProgress(
          source,
          sourceMessageId,
          needsYou: needsYou,
          reason: reason,
          dropped: dropped,
        ),
      );

  /// Closes out every row the coordinator was never going to settle. Returns
  /// how many that was — nothing reads it in the app, and the tests do.
  Future<int> sweepSettled({required double threshold}) async {
    final store = _store;
    if (store == null) return 0;
    try {
      final closed = await store.sweepSettledProgress(threshold: threshold);
      for (final row in closed) {
        _bus.publish(
          ProgressTick(
            source: row.source,
            sourceMessageId: row.sourceMessageId,
            stage: 'settle',
            state: 'done',
            receivedAt: row.receivedAt,
          ),
        );
      }
      return closed.length;
    } catch (e) {
      debugPrint('progress: settle sweep failed: $e');
      return 0;
    }
  }

  /// One message's stage write and the tick that follows it. The write hands
  /// back the message's `received_at` — null when there is no progress row to
  /// update, which costs the tick and nothing else.
  Future<void> _one(
    String source,
    String sourceMessageId,
    String stage,
    String state,
    Future<String?> Function(MessageStore store) write,
  ) async {
    final store = _store;
    if (store == null) return;
    try {
      final receivedAt = await write(store);
      if (receivedAt == null) return;
      _bus.publish(
        ProgressTick(
          source: source,
          sourceMessageId: sourceMessageId,
          stage: stage,
          state: state,
          receivedAt: receivedAt,
        ),
      );
    } catch (e) {
      debugPrint('progress: $stage $source/$sourceMessageId failed: $e');
    }
  }
}
