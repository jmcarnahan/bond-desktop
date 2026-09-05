import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import 'activity_log.dart';
import 'pipeline_progress.dart';

/// Restore: the owner's hand outranking the gates.
///
/// A gate-dropped message is not wrong, it is unasked-for — and the one thing
/// the pipeline cannot know is which newsletter the owner actually wanted.
/// Restore is how they say so. It stamps `messages.gate_override = 'user'`,
/// which is durable and outranks every later re-derivation, then puts the
/// message back through everything the gate cost it: the mail detail fetch,
/// triage, extraction, the embedding, and the needs-you verdict. The draft is
/// not queued here — it is chained from the extract handler, as it is for
/// every other message.
///
/// A restored message never toasts, and that is deliberate rather than
/// incidental: `admitNotifyCandidates` is floored on recency and inserts with
/// `INSERT OR IGNORE`, so a message from last month cannot become a
/// notification no matter what runs on it. Restore is the user pulling history
/// back, not new mail arriving — they are already looking at it.
class RestoreService {
  final MessageStore _store;
  final PipelineProgress _progress;

  /// Fetches a mail message's body and headers. Optional because a store-only
  /// caller (and every test that does not care) has nothing to fetch with.
  final Future<void> Function(String sourceMessageId)? _ensureBody;

  final Future<void> Function()? _pumpTriage;
  final Future<void> Function()? _pumpWork;
  final ActivityLog _log;

  RestoreService(
    this._store, {
    PipelineProgress progress = const PipelineProgress.disabled(),
    Future<void> Function(String sourceMessageId)? ensureBody,
    Future<void> Function()? pumpTriage,
    Future<void> Function()? pumpWork,
    ActivityLog? activityLog,
  })  : _progress = progress,
        _ensureBody = ensureBody,
        _pumpTriage = pumpTriage,
        _pumpWork = pumpWork,
        _log = activityLog ?? ActivityLog.disabled();

  /// Puts one dropped message back through the pipeline.
  ///
  /// The order below is the contract, not an accident of writing:
  /// the stamp lands before anything else so a drain already running cannot
  /// claim the row and re-gate it mid-restore, and the pumps go last so
  /// everything they might find is already written.
  ///
  /// Swallows its own failures, for [PipelineProgress]'s reason: the screen
  /// fires this unawaited, so a store write failing here — a database already
  /// torn down under a quit, most likely — would otherwise surface as an
  /// unhandled error nobody can catch. The cost is one restore that silently
  /// did not happen, and the optimistic row returning on the next read is
  /// what tells the user so.
  Future<void> restore(String source, String sourceMessageId) async {
    try {
      await _restore(source, sourceMessageId);
    } catch (e) {
      debugPrint('restore: $source/$sourceMessageId failed: $e');
    }
  }

  Future<void> _restore(String source, String sourceMessageId) async {
    await _store.restoreMessage(source, sourceMessageId);

    // Resets the progress row and ticks the bus, so the home feed sheds the
    // dropped row live rather than at the next read.
    await _progress.noteRestored(source, sourceMessageId);

    // Mail only: a gated message was skipped before tier two ever fetched, so
    // its body and headers are the preview and nothing more. Teams bodies
    // arrive whole at ingest — no second call would improve one.
    //
    // A failed fetch DEGRADES rather than aborting: triage classifies from the
    // preview, and the queue's own tier-two fetch tries again on the claim.
    // Losing a body is not a reason to leave the message dropped.
    final fetch = _ensureBody;
    if (fetch != null && source == 'email') {
      try {
        await fetch(sourceMessageId);
      } catch (_) {}
    }

    // `requeueWork` and not `enqueueWork`: a message may have carried these
    // rows before the gate closed on it, and `INSERT OR IGNORE` against a
    // `done` row would mean the work is never offered again. `draft` is
    // absent on purpose — the extract handler chains it.
    for (final kind in const ['extract', 'needs_you', 'embed_message']) {
      await _store.requeueWork(kind, source, sourceMessageId);
    }

    await _log.record('restore', source: source, entityId: sourceMessageId);

    // Fire-and-forget, and CHAINED rather than merely ordered. Launching both
    // back to back is not enough to get triage in first: `AiWorker.pump` takes
    // the shared DrainGate synchronously while `TriageQueue.pump` awaits an
    // `_emit()` before it reaches the gate, so the worker would win the FIFO
    // and the extract handler would read the row while it was still untriaged
    // — no urgency, no reply cue, and so no draft chained for a message the
    // owner asked to see. The sync path chains the two for the same reason
    // (see `DrainGate`'s own comment).
    //
    // The app's queue drains `TriageQueue.sources` — email AND teams — so a
    // restored chat message drains here too. (`claimPendingTriage` on its own
    // defaults to email, which is why this is worth saying.)
    //
    // Each half swallows its own failure: a triage drain that parked on a dead
    // session must not take the AI worker's pump down with it.
    unawaited(_pumpBoth());
  }

  Future<void> _pumpBoth() async {
    try {
      await _pumpTriage?.call();
    } catch (_) {}
    try {
      await _pumpWork?.call();
    } catch (_) {}
  }
}
