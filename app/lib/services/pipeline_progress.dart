import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import 'notify_worthy.dart';
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

  Future<void> noteDraft(
    String source,
    String sourceMessageId, {
    required String state,
  }) =>
      _one(
        source,
        sourceMessageId,
        'draft',
        state,
        (store) => store.writeDraftProgress(
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

  /// The same thread-wide tick, for the membership a person decided.
  ///
  /// Publish only, and the second method here that writes nothing — for
  /// [noteIngest]'s reason turned around. Filing a thread by hand moves the
  /// storyline POINTER and no stage, so the write is
  /// [MessageStore.stampStorylineId] and it belongs to the user action, not to
  /// the recorder: a stamp that only happened when somebody was watching would
  /// be an observer breaking the thing it observes, and every test and every
  /// caller holding the disabled recorder would file threads that never
  /// reached the home feed. [StorylineService] does the write and hands over
  /// the rows it touched.
  ///
  /// The ticks go out under `storyline`/`done`, which is honest — the column
  /// the listeners re-read behind a tick is the one that changed — and it
  /// means the feed patches a hand-filed thread's rows the moment the user
  /// files it, rather than whenever the next pass happens to touch them.
  void noteStorylineLink(
    String source,
    List<({String sourceMessageId, String receivedAt})> touched,
  ) {
    for (final row in touched) {
      _bus.publish(
        ProgressTick(
          source: source,
          sourceMessageId: row.sourceMessageId,
          stage: 'storyline',
          state: 'done',
          receivedAt: row.receivedAt,
        ),
      );
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

  /// The whole-row reset behind Restore: every stage back to `pending`, the
  /// drop undone.
  ///
  /// The tick goes out under `triage`/`pending`, which is honest rather than
  /// nominal — triage is the first thing about to run on this message. As with
  /// [clearNeedsYou], the live screen re-reads the whole row behind any tick,
  /// so one tick carries the other four stages with it.
  Future<void> noteRestored(String source, String sourceMessageId) => _one(
        source,
        sourceMessageId,
        'triage',
        'pending',
        (store) => store.restoreProgress(source, sourceMessageId),
      );

  /// Ignore: the tick behind the owner's hand, and nothing more.
  ///
  /// The whole cascade an Ignore writes — the skip on `messages`, the pending
  /// stages closed out, the drop, the cleared chips — is one transaction
  /// inside [MessageStore.dropMessage], where it belongs: it must not be
  /// half-written, and half of it is not a progress write at all. What is left
  /// for here is the announcement, so the live feed re-reads the row and grays
  /// it where it stands.
  ///
  /// The tick goes out under `triage`/`skipped`, which is honest — that is
  /// precisely what the transaction wrote — and [touchProgress] is the write
  /// under it because there is nothing left to change: the stage states are
  /// already correct, and only the stalled clock still needs restarting.
  Future<void> noteIgnored(String source, String sourceMessageId) => _one(
        source,
        sourceMessageId,
        'triage',
        'skipped',
        (store) => store.touchProgress(source, sourceMessageId),
      );

  /// A retry is a progress write.
  ///
  /// Nothing about the row's stage states changes here — the stages are put
  /// back on their queues by [PipelineRepairService], and each will record
  /// itself when it runs. What this does is restart the stalled clock, so a
  /// row the owner has just asked for again stops accusing the pipeline of
  /// having abandoned it, and give the live screen a tick to re-read behind.
  ///
  /// The tick goes out under [stage] and `pending`, which is honest rather
  /// than nominal: [stage] is the first thing owed and the first thing about
  /// to run. As with [noteRestored], the live screen re-reads the whole row
  /// behind any tick, so one tick carries the other stages with it.
  Future<void> noteRetry(
    String source,
    String sourceMessageId, {
    required String stage,
  }) =>
      _one(
        source,
        sourceMessageId,
        stage,
        'pending',
        (store) => store.touchProgress(source, sourceMessageId),
      );

  /// Takes the Needs You chip off a thread the user has answered or finished,
  /// and says so per message.
  ///
  /// The chip is earned at settle time and survives being read; what clears it
  /// is the user actually doing something about the thread — a reply synced
  /// back from anywhere, or a thread marked done.
  ///
  /// The ticks go out under `settle`, which is nominal: the stage did not move
  /// and there is no stage for "the user answered". The live screen re-reads
  /// the whole row behind any tick, so the label only has to be one the
  /// listeners already know.
  Future<void> clearNeedsYou(String source, String conversationKey) async {
    final store = _store;
    if (store == null) return;
    try {
      final cleared = await store.clearNeedsYou(source, conversationKey);
      for (final row in cleared) {
        _bus.publish(
          ProgressTick(
            source: source,
            sourceMessageId: row.sourceMessageId,
            stage: 'settle',
            state: 'done',
            receivedAt: row.receivedAt,
          ),
        );
      }
    } catch (e) {
      debugPrint('progress: needs-you clear $source/$conversationKey '
          'failed: $e');
    }
  }

  /// Moves a settled row's Needs You chip to match a verdict that has since
  /// changed, and says so.
  ///
  /// The snapshot in `message_progress.needs_you` is taken once, at settle
  /// time, from the same [notifyWorthy] call that decided whether to interrupt
  /// the user. That is right for the moment it is taken and wrong afterwards:
  /// a re-judge — a document that landed an ask, the owner editing their Needs
  /// You rules — writes a new verdict onto `messages` and the chip beside it
  /// goes on showing the old one.
  ///
  /// Two things make this safe to run after the fact. The first is that the
  /// store refuses to write unless the value actually differs, so a re-verdict
  /// that returned the same answer is silent and a chip cleared by a reply or
  /// a Done stays cleared. The second is the `answered` guard below:
  /// [notifyWorthy] has no outbound clause, because the coordinator settles
  /// long before any reply can exist, and a false→true re-verdict months later
  /// must not put a chip back on a thread the user has answered.
  ///
  /// Reading is deliberately NOT a clearing condition, exactly as
  /// [MessageStore.sweepSettledProgress] argues: a chip once earned survives
  /// being read, and clears when the user replies or marks the thread done.
  Future<void> refreshNeedsYou(
    String source,
    String sourceMessageId, {
    required double threshold,
  }) async {
    final store = _store;
    if (store == null) return;
    Map<String, Object?>? row;
    try {
      row = await store.notifyRowFor(source, sourceMessageId);
    } catch (e) {
      debugPrint('progress: needs-you row $source/$sourceMessageId failed: $e');
      return;
    }
    if (row == null) return;
    final answered = row['conversation_state'] == 'done' ||
        (row['last_outbound_at'] as String? ?? '')
                .compareTo(row['received_at'] as String? ?? '') >
            0;
    final needsYou = !answered && notifyWorthy(row, threshold: threshold);
    await _one(
      source,
      sourceMessageId,
      'settle',
      'done',
      (store) => store.refreshNeedsYouFlag(
        source,
        sourceMessageId,
        needsYou: needsYou,
      ),
    );
  }

  /// The one-shot catch-up for rows that settled before the verdict column
  /// existed. Returns how many chips it raised.
  Future<int> backfillNeedsYou({required double threshold}) async {
    final store = _store;
    if (store == null) return 0;
    try {
      return _tickRaised(
        await store.backfillNeedsYouFromVerdicts(threshold: threshold),
      );
    } catch (e) {
      debugPrint('progress: needs-you backfill failed: $e');
      return 0;
    }
  }

  /// Raises the chips one thread's messages lost while it sat in Later, and
  /// ticks each row so the live screen re-reads it. Returns how many.
  ///
  /// Called by whatever lifts the bucket — the user's Keep in inbox, a
  /// deferral whose date arrived — because the chip otherwise follows the
  /// verdict only, and no verdict moves when a thread comes back.
  Future<int> raiseNeedsYouForThread(
    String source,
    String conversationKey, {
    required double threshold,
  }) async {
    final store = _store;
    if (store == null) return 0;
    try {
      return _tickRaised(await store.raiseNeedsYouForThread(
        source,
        conversationKey,
        threshold: threshold,
      ));
    } catch (e) {
      debugPrint(
        'progress: needs-you raise $source/$conversationKey failed: $e',
      );
      return 0;
    }
  }

  int _tickRaised(
    List<({String source, String sourceMessageId, String receivedAt})> raised,
  ) {
    for (final row in raised) {
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
    return raised.length;
  }

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
