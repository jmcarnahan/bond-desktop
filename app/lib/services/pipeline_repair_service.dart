import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import 'activity_log.dart';
import 'attention.dart';
import 'pipeline_progress.dart';

/// Every per-message lever that is not Restore: retry, ignore, re-judge.
///
/// The sibling of `RestoreService`, and deliberately not the same thing. A
/// dropped message is one the gates refused and Restore is how the owner
/// overrules them. A STALLED message is one nothing refused — it was admitted,
/// and then a stage errored, or a queue row was never written, or a drain died
/// holding nothing. There is no verdict to overrule there; what is owed is the
/// work itself.
///
/// So this requeues exactly the stages a row still owes and nothing else. A
/// stage that finished stays finished: re-running a `done` extraction would
/// spend the model on an answer the app already has, and re-running a
/// `skipped` one would undo a decision the pipeline made on purpose. What the
/// caller gets back is the list of what was actually put back on a queue,
/// which is the only honest thing to tell a person who pressed Retry.
///
/// [ignore] and [rejudgeNeedsYou] arrived with the history screen and belong
/// beside it rather than in `RestoreService`: all three are the owner reaching
/// into ONE message's pipeline, and all three have to say truthfully whether
/// anything moved. Restore stayed where it is because it is the only one that
/// overrules a verdict; these two work with the pipeline rather than against
/// it.
class PipelineRepairService {
  final MessageStore _store;
  final PipelineProgress _progress;
  final Future<void> Function()? _pumpTriage;
  final Future<void> Function()? _pumpWork;
  final ActivityLog _log;

  /// The attention floor the settle backstop judges against, so a row this
  /// service closes out is closed on the same number the coordinator would
  /// have used.
  final Future<double> Function()? _threshold;

  PipelineRepairService(
    this._store, {
    this._progress = const PipelineProgress.disabled(),
    this._pumpTriage,
    this._pumpWork,
    this._threshold,
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  /// Requeues exactly the stages [source]/[sourceMessageId] still owes, and
  /// returns their names in pipeline order. Never re-runs a terminal stage.
  ///
  /// An empty list is a real answer and has two shapes behind it: the row owes
  /// nothing, or every stage it owes is already queued and simply not
  /// draining. Both still get the pumps — a queue nobody is turning is the
  /// commonest way a row stops — and neither writes an activity row, because
  /// nothing happened that a log of what the app did should claim.
  ///
  /// Swallows its own failures, for `RestoreService`'s reason: the screen
  /// fires this from a button and a store write failing here would otherwise
  /// surface as an unhandled error nobody can catch.
  Future<List<String>> retryOwed(String source, String sourceMessageId) async {
    try {
      return await _retryOwed(source, sourceMessageId);
    } catch (e) {
      debugPrint('retry: $source/$sourceMessageId failed: $e');
      return const [];
    }
  }

  Future<List<String>> _retryOwed(
    String source,
    String sourceMessageId,
  ) async {
    final rows = await _store.progressRowsFor([
      (source: source, id: sourceMessageId),
    ]);
    if (rows.isEmpty) return const [];
    final row = rows.first;

    final message = await _store.getMessageRow(source, sourceMessageId);
    if (message == null) return const [];

    // A dropped row is Restore's business and not this one's. Requeueing its
    // stages would put a gated message back through a pipeline that is going
    // to refuse it again at the first gate, and the owner would have been
    // shown a retry that could never have worked.
    if (row.dropped) return const [];

    final stages = <String>[];

    // Triage first, and off `messages` rather than the queue: it is the one
    // stage with no work row of its own. A row already `pending` has nothing
    // to write — the pump at the end IS its retry — so only an errored one is
    // moved, and only a stage that actually moved is claimed.
    final triageErrored = row.triageState == 'error' ||
        message['triage_status'] == 'error';
    if (triageErrored) {
      final moved = await _store.reviveTriageFor(source, sourceMessageId);
      // Only what it MOVED. An error left on the progress row over a
      // `triaged` message is history, not owed work, and claiming it would
      // tell the owner a stage was retried that was never re-queued.
      if (moved > 0) stages.add('triage');
    }

    if (row.extractState == 'pending' || row.extractState == 'error') {
      await _requeue('extract', source, sourceMessageId, stages);
    }

    // The verdict and not the stage state, because needs-you has no column on
    // `message_progress`: a null verdict IS the stage still being owed.
    if (message['needs_you_verdict'] == null) {
      await _requeue('needs_you', source, sourceMessageId, stages);
    }

    // Keyed by the CONVERSATION, because storyline assignment is a question
    // about a thread and the queue files it that way.
    if (row.storylineState == 'pending' || row.storylineState == 'error') {
      await _requeue('storyline', source, row.conversationKey, stages);
    }

    // `enqueueWork` and not `requeueWork`: a draft that finished is a draft
    // the app has, and a draft the extract tail's pre-gate decided against is
    // a decision rather than a failure. Only a message that has never been
    // offered to the queue is queued here, and the pre-gate is free to skip
    // it again.
    if (row.draftState == 'pending') {
      final before =
          await _store.workStatusOf('draft', source, sourceMessageId);
      if (before == null) {
        await _store.enqueueWork('draft', source, sourceMessageId);
        stages.add('draft');
      }
    }

    if (stages.isNotEmpty) {
      await _progress.noteRetry(source, sourceMessageId, stage: stages.first);
      await _log.record(
        'retry',
        source: source,
        entityId: sourceMessageId,
        count: stages.length,
        detail: {'stages': stages},
      );
    } else if (row.outcome == 'pending') {
      // Every stage is terminal and the row never closed out — it is stalled
      // at the settle, which owns no queue and so appears in nothing above.
      // The backstop sweep is what closes a row the coordinator was never
      // going to settle, and running it here is the only thing Retry can
      // honestly do about that state.
      await _progress.sweepSettled(threshold: await _thresholdOrDefault());
    }

    // Fire-and-forget, and CHAINED rather than merely ordered — the same
    // shape and the same reason as `RestoreService`: `AiWorker.pump` takes the
    // shared DrainGate synchronously while `TriageQueue.pump` awaits an
    // `_emit()` before it reaches the gate, so launching both back to back
    // would let the worker win the FIFO and hand the extract handler a row
    // that is still untriaged.
    //
    // It runs even when nothing was requeued, because a row can be stalled on
    // a queue that is simply not draining, and turning that queue is the whole
    // repair.
    unawaited(_pumpBoth());

    return stages;
  }

  /// Ignore: the owner throwing one message out, and the tick that shows it.
  ///
  /// The write is [MessageStore.dropMessage]'s single transaction; what is
  /// here is the announcement and the record. False when nothing is stored
  /// under the keys — and then nothing is logged either, for [retryOwed]'s
  /// reason: a log of what the app did must not claim something that did not
  /// happen.
  ///
  /// No pump, because an Ignore queues nothing. Whatever was already queued
  /// for the message drains as a skip, since the extract and needs-you
  /// handlers both refuse a gated row.
  ///
  /// Swallows its own failures, like everything else here: the screen fires
  /// this from a button.
  Future<bool> ignore(String source, String sourceMessageId) async {
    try {
      final dropped = await _store.dropMessage(source, sourceMessageId);
      if (!dropped) return false;
      await _progress.noteIgnored(source, sourceMessageId);
      await _log.record('ignore', source: source, entityId: sourceMessageId);
      return true;
    } catch (e) {
      debugPrint('ignore: $source/$sourceMessageId failed: $e');
      return false;
    }
  }

  /// Asks the needs-you stage the question again, on a message that has
  /// already been judged.
  ///
  /// Distinct from [retryOwed], which only ever requeues a stage a row still
  /// OWES: this deliberately re-runs one that finished, because the owner has
  /// seen the verdict and disagrees with the reasoning behind it — a rules
  /// edit, a document that has landed since, a thread that reads differently
  /// now. `requeueWork` revives a `done` or `error` row and leaves anything
  /// else alone, which is exactly the semantics wanted.
  ///
  /// False rather than a re-judge in three cases, each an honest "nothing to
  /// do": the item is already queued or in a worker's hands, nothing is stored
  /// under the keys, or the message is gated — a gated row is never judged, so
  /// queueing one would spend a slot on a handler that will refuse it.
  Future<bool> rejudgeNeedsYou(String source, String sourceMessageId) async {
    try {
      final queued =
          await _store.workStatusOf('needs_you', source, sourceMessageId);
      if (queued == 'pending' || queued == 'processing') return false;

      final message = await _store.getMessageRow(source, sourceMessageId);
      if (message == null) return false;
      // The handlers' own guard, spelled the same way: a Teams message is
      // `skipped` by the gate that admits it, and it IS judged.
      if (message['triage_status'] == 'skipped' &&
          message['gate_reason'] != 'teams_source') {
        return false;
      }

      await _store.requeueWork('needs_you', source, sourceMessageId);
      await _log.record(
        'needs_you_rejudge',
        source: source,
        entityId: sourceMessageId,
        count: 1,
      );
      unawaited(_pumpBoth());
      return true;
    } catch (e) {
      debugPrint('re-judge: $source/$sourceMessageId failed: $e');
      return false;
    }
  }

  /// Requeues one stage and claims it only if it was not already in flight.
  ///
  /// [MessageStore.requeueWork] leaves a `pending` or `processing` row exactly
  /// where it is, which is right — resetting it would lose its place in the
  /// drain order — but it means the call cannot be read as "this stage was
  /// retried". The status BEFORE the call is what settles that.
  Future<void> _requeue(
    String kind,
    String source,
    String entityId,
    List<String> stages,
  ) async {
    final before = await _store.workStatusOf(kind, source, entityId);
    if (before == 'pending' || before == 'processing') return;
    await _store.requeueWork(kind, source, entityId);
    stages.add(kind);
  }

  /// The settle machine's own reader, degraded the same way — see
  /// `NotificationCoordinator._attentionThreshold`. A preference that cannot be
  /// read is a default, never a failed repair.
  Future<double> _thresholdOrDefault() async {
    final read = _threshold;
    if (read == null) return AttentionTuning.defaultThreshold;
    try {
      return await read();
    } catch (e) {
      debugPrint('retry: reading the attention threshold failed: $e');
      return AttentionTuning.defaultThreshold;
    }
  }

  /// Each half swallows its own failure: a triage drain parked on a dead
  /// session must not take the AI worker's pump down with it.
  Future<void> _pumpBoth() async {
    try {
      await _pumpTriage?.call();
    } catch (_) {}
    try {
      await _pumpWork?.call();
    } catch (_) {}
  }
}
