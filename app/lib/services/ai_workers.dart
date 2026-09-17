import 'dart:async';

import 'ai_worker.dart';

/// The app's three AI drains, and the order anything that wants "all of it"
/// pumps them in.
///
/// A value rather than a fourth queue: it owns no claims, no timer and no
/// state beyond the merge below. What it exists for is the two facts a caller
/// outside the pipeline needs and cannot get from one worker — that the lanes
/// are pumped in the right order, and that their progress can be listened to
/// as one stream.
///
/// Why each lane holds what it holds is documented once, on [AiWorker].
class AiWorkers {
  /// Triage's neighbour: the kinds a new message's first seconds run through,
  /// on the fast server, behind the same gate the triage drain takes.
  final AiWorker fast;

  /// The six storyline passes, in one worker because their ORDER is the
  /// argument — see `docs/pipeline/06-storylines.md`.
  final AiWorker storyline;

  /// `DraftHandler` alone, at the prose server's width.
  final AiWorker draft;

  final StreamController<WorkProgress> _progress =
      StreamController<WorkProgress>.broadcast();

  final List<StreamSubscription<WorkProgress>> _subscriptions = [];

  AiWorkers({
    required this.fast,
    required this.storyline,
    required this.draft,
  }) {
    for (final worker in [fast, storyline, draft]) {
      _subscriptions.add(
        worker.progress.listen(
          (event) {
            if (!_progress.isClosed) _progress.add(event);
          },
          // Forwarded rather than swallowed: a listener that reloads a list on
          // progress is entitled to the same failure the worker saw. Errors on
          // a broadcast stream with no listener are dropped, which is what a
          // build with nobody watching already gets.
          onError: (Object error, StackTrace stack) {
            if (!_progress.isClosed) _progress.addError(error, stack);
          },
        ),
      );
    }
  }

  /// Every lane's `WorkProgress`, on one broadcast stream.
  ///
  /// One listener in the app wants every kind — the inbox reloads on any
  /// progress, and a CTA arriving from extraction, a thread joining a
  /// storyline and a draft landing are three lanes' news about the same list.
  /// A merge here rather than three subscriptions there, because "which lane
  /// is this kind on" is this file's fact and not the list's.
  Stream<WorkProgress> get progress => _progress.stream;

  /// Drains the fast lane, then the two lanes it feeds.
  ///
  /// CHAINED and not a three-way wait, and the reason is what the rows are:
  /// the `storyline*` and `draft` rows this pass will drain are written BY the
  /// fast drain — by extraction, by the needs-you verdict — so a draft pump
  /// started beside it would resolve against an empty queue seconds before
  /// anything was queued at all. The chain is what keeps "the sync's pump
  /// completed" meaning "and the drafts are done", which the rail's pending
  /// count reads.
  ///
  /// The two behind it run TOGETHER, because they are the two servers: a
  /// recap on the 27B and a membership confirm on the 4B have no reason to
  /// wait for each other, and where they do contend (both lanes' prose) the
  /// server queues them.
  ///
  /// In the app those two drains are usually ALREADY RUNNING by the time this
  /// reaches them: `AiWorker.onDrained` fires before the fast pump's future
  /// completes, and that callback pumps these two. So both calls below
  /// normally join a drain in flight and set its repump flag, which costs one
  /// extra pass per lane — and a pass over an empty queue is one claim query
  /// per handler, six and one. That is the trade rather than an oversight:
  /// what this future has to mean is "and the drafts are done", and only a
  /// join can give the caller that. Skipping the pump because a drain is
  /// already running would hand back a future about the PREVIOUS drain, which
  /// the rail's pending-draft badge would read as finished.
  Future<void> pumpAll() async {
    await fast.pump();
    await Future.wait([storyline.pump(), draft.pump()]);
  }

  /// Drops the merge. The workers are disposed by their own providers — this
  /// owns the subscriptions and the controller and nothing else.
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _progress.close();
  }
}

/// Triage first, then the worker lanes — chained rather than merely ordered.
///
/// Launching the two back to back is not enough to get triage in first:
/// `AiWorker.pump` takes its `DrainGate` synchronously while
/// `TriageQueue.pump` awaits an `_emit()` before it reaches the gate, so on
/// the shared FAST gate the worker would win the FIFO and the extract handler
/// would read a row that is still untriaged — no urgency, no reply cue, and so
/// no draft chained for it. Every caller that wakes both queues owes that
/// order, which is why it is written here once instead of at each of them.
///
/// It imposes no failure policy of its own: [triage] and [workers] are called
/// in order and whatever they throw reaches the caller, because the four
/// callers do NOT agree about that — a restore swallows each half separately
/// so a parked triage drain cannot cost the worker its pump, and the sync path
/// logs the whole chain once. Each site keeps its own.
Future<void> pumpTriageThenWorkers({
  required Future<void> Function() triage,
  required Future<void> Function() workers,
}) async {
  await triage();
  await workers();
}

/// [pumpTriageThenWorkers] for a caller that owns neither queue and must
/// survive both: each half swallows its OWN failure, so a triage drain parked
/// on a dead session cannot cost the worker lanes their pump.
///
/// That is what `RestoreService` and `PipelineRepairService` both need, and
/// for the same reason: the screen fires them from a button and never awaits
/// the result, so an exception escaping here would be an unhandled error in
/// whatever zone the button happened to be in. Null means "this caller has no
/// such queue", which is every test that builds one of those services with the
/// store alone.
Future<void> pumpTriageThenWorkersQuietly({
  required Future<void> Function()? triage,
  required Future<void> Function()? workers,
}) =>
    pumpTriageThenWorkers(
      triage: () async {
        try {
          await triage?.call();
        } catch (_) {}
      },
      workers: () async {
        try {
          await workers?.call();
        } catch (_) {}
      },
    );
