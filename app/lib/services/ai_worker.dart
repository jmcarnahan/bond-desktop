import 'dart:async';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'drain_gate.dart';
import 'backend/backend_types.dart';
import 'llm/llm_client.dart';

/// How much work of one kind is left, as of the last item the worker
/// finished.
///
/// Built from the store's own counts rather than a counter the worker keeps,
/// so it is correct across a restart and cannot drift: the numbers are the
/// rows.
class WorkProgress {
  /// Which queue this is about — `extract` today.
  final String kind;

  /// `status` → row count. Statuses with no rows are absent.
  final Map<String, int> counts;

  const WorkProgress(this.kind, this.counts);

  int get remaining => (counts['pending'] ?? 0) + (counts['processing'] ?? 0);

  int get total => counts.values.fold(0, (sum, n) => sum + n);

  int get done => total - remaining;
}

/// One kind of AI work, and how to do one item of it.
///
/// [run] signals failure by throwing, and what it throws decides what happens
/// next — see [AiWorker.pump]. In particular a handler that swallows an
/// [LlmUnavailableException] would keep the drain grinding through a hundred
/// items against a server that is not running.
abstract class WorkHandler {
  /// Matches `work_items.task_kind`.
  String get kind;

  /// How many items of this kind may be at the server at once.
  ///
  /// One by default, and that default is the safe answer rather than a
  /// performance oversight: a handler whose items touch shared state has to
  /// see them one at a time — a storyline assignment changes the clusters the
  /// next candidate is measured against, so two at once would each decide
  /// against a mailbox the other is mid-way through changing. A handler raises
  /// this only when its items are genuinely independent of each other, and
  /// then no higher than the server it calls has slots for.
  int get concurrency => 1;

  /// One row from `work_items`. `entity_id` names what to work on.
  Future<void> run(Map<String, Object?> item);
}

/// What one item's outcome means for the rest of the drain.
///
/// Three cases and not two, because since phase 3 the kinds do not share a
/// model server: "extraction's server is down" and "the session is over" used
/// to imply each other and no longer do.
enum _RunOutcome {
  /// Done, or failed in a way that is about this item. Carry on.
  ok,

  /// This KIND's server is not answering. Every item of this kind behind it
  /// would fail identically — but another kind on another server would not.
  parkKind,

  /// The session is gone. Every kind's Graph-dependent work fails the same
  /// way, so the whole drain stops.
  parkDrain,
}

/// Drains the `work_items` queue through its handlers, a few items of one kind
/// at a time.
///
/// This is `TriageQueue`'s protocol, generalised over a task kind — the same
/// atomic claim, the same failure policy, the same park-on-unavailable — and
/// it is a COPY rather than a shared base class on purpose. Triage is
/// hard-wired to the `messages` table by decision: its queue, its gates and
/// its fold-up are one thing, and the seam that would let them be shared is
/// not worth the coupling.
///
/// Bounded-concurrent within one kind, at [WorkHandler.concurrency]. The GPU
/// reads the model's weights once per decode step no matter how many sequences
/// share it, so K requests in flight at one llama-server come back in nothing
/// like K times the wall clock of one — the aggregate is worth roughly 2.5-3x
/// a serial drain. K is small and per handler because the trade runs the other
/// way past a point: each individual request gets slower as the batch grows,
/// and both the client's 120-second timeout and the person watching for the
/// first result care about one request's latency, not the aggregate.
///
/// The kinds still drain in handler ORDER rather than interleaved, and that
/// has never been about the server: extraction writes the embeddings both
/// storyline passes compare, and a draft reads the storyline summary. The
/// caller chains this worker's [pump] after triage's, and the shared
/// [DrainGate] is what actually holds the two drains apart.
///
/// A park is per KIND when it is the model server that went away, because
/// since phase 3 the kinds do not share one: extraction runs against the fast
/// server and drafting against the 27B, so "extraction's server is not
/// running" says nothing about drafting's. A dead SESSION is the opposite —
/// every kind's Graph-dependent work fails identically — and parks the whole
/// drain.
///
/// The worker owns no timer. [pump] is called after each sync, is a no-op
/// while a drain is running, and stops on its own when nothing is pending.
class AiWorker {
  /// Every source whose work this worker drains. Handlers are already
  /// per-item source-aware (they read `item['source']`), so widening this
  /// list is all a new connector needs.
  static const List<String> _sources = ['email', 'teams'];

  /// One retry, then the item is left alone. Same trade triage makes: a local
  /// model that answered unparseably often gets it right on a second pass, and
  /// an item that fails twice will fail every time.
  static const int _maxAttempts = 2;

  final MessageStore _store;
  final List<WorkHandler> _handlers;
  final DrainGate _gate;
  final ActivityLog _log;

  final StreamController<WorkProgress> _progress =
      StreamController<WorkProgress>.broadcast();

  /// The drain in flight, or null. Doubles as the "already running" guard and
  /// as what a second [pump] returns, so a caller that pumped mid-drain still
  /// awaits real completion instead of an instant no-op.
  Future<void>? _draining;

  /// Set when [pump] lands mid-drain: the active drain makes one more full
  /// handler pass before finishing, picking up whatever that pump was for —
  /// a kind it had already moved past would otherwise wait for the next sync.
  bool _repump = false;

  /// The items this worker currently holds claims on, as `(kind, source,
  /// entityId)` — the work table's primary key. See `TriageQueue` for why a
  /// queue has to know what it is holding: a worker rebuilt mid-drain, which
  /// is what a backend switch does, used to leave every claimed row
  /// `processing` until the next launch.
  final Set<(String, String, String)> _claimed = {};

  /// The items actually at a model server, so [dispose] can wait for their
  /// results before deciding what is still claimed.
  final Set<Future<void>> _inFlight = {};

  bool _stopped = false;

  AiWorker(
    this._store, {
    required List<WorkHandler> handlers,
    DrainGate? gate,
    ActivityLog? activityLog,
  })  : _handlers = List.unmodifiable(handlers),
        _gate = gate ?? DrainGate(),
        _log = activityLog ?? ActivityLog.disabled();

  Stream<WorkProgress> get progress => _progress.stream;

  /// Ends the current drain after the items already in flight finish. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

  /// Clears claims a previous run left behind, across every kind. Startup only
  /// — it must not run while a worker holds a claim, or it would hand that
  /// item to a second drain.
  Future<void> resetInterrupted() => _store.resetInterruptedWork();

  /// Stops the drain and gives back every claim it is still holding — the
  /// work queue's `TriageQueue.dispose`, in the same order and for the same
  /// reasons.
  Future<void> dispose() async {
    _stopped = true;
    _progress.close();
    // A LOOP, not one wait — see `TriageQueue.dispose`: a claim already at
    // the store when [_stopped] flipped joins [_inFlight] after the first
    // snapshot, and releasing under a still-running item would hand it to a
    // second worker.
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList()).catchError((_) => const <void>[]);
    }
    for (final (kind, source, id) in _claimed.toList()) {
      // Guarded on `processing` in the statement itself, so a claim released
      // here cannot reopen an item that finished while this was deciding.
      await _store.releaseWorkClaim(kind, source, id);
    }
    _claimed.clear();
  }

  /// Drains every handler's queue in order until nothing is pending, the
  /// worker is stopped, or something happens that would fail identically for
  /// every item behind the current one.
  ///
  /// Serialized two ways. Against ITSELF: a call while a drain is running does
  /// not start a racing one — it schedules one more full pass on the active
  /// drain and returns that drain's future, so the caller still awaits the
  /// pass that will do its work. Against the OTHER queue: the whole drain runs
  /// under the shared [DrainGate], so it can never interleave model calls with
  /// a triage drain already at the server.
  Future<void> pump() {
    final inFlight = _draining;
    if (inFlight != null) {
      _repump = true;
      return inFlight;
    }
    final drain = _gate.run(_drainAll);
    _draining = drain.whenComplete(() => _draining = null);
    return _draining!;
  }

  Future<void> _drainAll() async {
    _stopped = false;
    do {
      _repump = false;
      for (final handler in _handlers) {
        if (_stopped) break;
        // Before the first item of each kind, not after it: a counter that
        // appears only once the first item lands is blank for exactly the
        // seconds someone would be looking at it.
        await _emit(handler.kind);

        // Up to [WorkHandler.concurrency] items of this kind at the server at
        // once. What makes that safe is the claim:
        // [MessageStore.claimPendingWork] is one UPDATE…RETURNING, so choosing
        // an item and taking it off the pending list are the same indivisible
        // step. Two concurrent drains — or two iterations of this loop, which
        // suspends on the claim now — can never see the same row: whichever
        // claim lands second finds nothing pending to match and comes back
        // null.
        var parkedKind = false;
        var parkedDrain = false;
        while (!_stopped && !parkedKind && !parkedDrain) {
          while (_inFlight.length < handler.concurrency &&
              !_stopped &&
              !parkedKind &&
              !parkedDrain) {
            final item = await _store.claimPendingWork(
              handler.kind,
              sources: _sources,
            );
            if (item == null) break;
            _claimed.add(_claimKey(handler.kind, item));
            late final Future<void> future;
            // [ActivityLog.inSpan] gives this item its own tally, so
            // concurrent items' notes and model calls land on their own
            // activity rows.
            future = _log.inSpan(() => _runOne(handler, item)).then((outcome) {
              parkedKind |= outcome == _RunOutcome.parkKind;
              parkedDrain |= outcome == _RunOutcome.parkDrain;
            }).whenComplete(() => _inFlight.remove(future));
            _inFlight.add(future);
          }
          if (_inFlight.isEmpty) break;
          // Over a COPY: `whenComplete` mutates the set as each item lands.
          await Future.any(_inFlight.toList());
        }
        // A park stops new launches, never the work already at the server:
        // those answers are paid for and their results are kept.
        await Future.wait(_inFlight.toList());

        // A dead session fails every kind identically, so nothing behind this
        // one is worth trying — and neither is a repump, which would park on
        // the same dead session all over again. A server that is down is not
        // that: it is one kind's server, and the next kind may be on another.
        if (parkedDrain) return;
      }
    } while (_repump && !_stopped);
  }

  static (String, String, String) _claimKey(
    String kind,
    Map<String, Object?> item,
  ) =>
      (
        kind,
        item['source'] as String? ?? 'email',
        item['entity_id'] as String? ?? '',
      );

  /// One item, with a heartbeat under it.
  ///
  /// The heartbeat is what makes [MessageStore.reclaimStaleWork] safe to run
  /// on every sync — and it matters more here than in triage, because a
  /// storyline sweep is one item that legitimately takes minutes. A claim
  /// that is still being worked says so once a minute, so the watchdog's
  /// five-minute window can only close on a worker that is gone.
  Future<_RunOutcome> _runOne(
    WorkHandler handler,
    Map<String, Object?> item,
  ) {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final beat = Timer.periodic(pipelineHeartbeatInterval, (_) {
      // A failed touch costs nothing: the window is five beats wide.
      _store.touchWork(handler.kind, source, id).catchError((_) {});
    });
    return _runClaimed(handler, item, source, id).whenComplete(beat.cancel);
  }

  /// Everything one claimed item does, and what its outcome means for the rest
  /// of the drain.
  Future<_RunOutcome> _runClaimed(
    WorkHandler handler,
    Map<String, Object?> item,
    String source,
    String id,
  ) async {
    // The item arrives already claimed — the statement that picked it is the
    // statement that wrote its `processing`. A crash mid-model-call therefore
    // leaves it claimed, which is exactly what [resetInterrupted] looks for at
    // the next launch.
    final sw = Stopwatch()..start();

    try {
      await handler.run(item);
      await _writeWork(handler.kind, source, id, status: 'done');
      // The work row is `done` either way; the activity row is where a
      // handler that early-returned gets to say so. [ActivityLog.note] and
      // [ActivityLog.noteStatus] are how it does that without throwing, and
      // both are folded in and cleared by this one call.
      await _log.record(
        handler.kind,
        status: _log.pendingStatusOr('ok'),
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
      );
      await _emit(handler.kind);
      return _RunOutcome.ok;
    } on LlmUnavailableException {
      // Nothing about this item failed, so it does not spend an attempt. This
      // kind stops too: every item of it behind this one would fail
      // identically, and marking a hundred of them is just noise on a laptop
      // where that model server is not running.
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkKind,
        'model_unavailable',
        sw.elapsedMilliseconds,
      );
    } on NotSignedIn {
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkDrain,
        'session',
        sw.elapsedMilliseconds,
      );
    } on ReconsentRequired {
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkDrain,
        'session',
        sw.elapsedMilliseconds,
      );
    } on LlmException catch (e) {
      return _recordFailure(
        handler.kind,
        item,
        e,
        e.statusCode,
        sw.elapsedMilliseconds,
      );
    } catch (e) {
      return _recordFailure(handler.kind, item, e, null, sw.elapsedMilliseconds);
    }
  }

  /// Every write that ends this worker's interest in an item, and the claim
  /// release that goes with it.
  ///
  /// One wrapper rather than a `_claimed.remove` beside each write site: a
  /// path that wrote a result and forgot to release would leave [dispose]
  /// holding a claim on an item that is already finished.
  Future<void> _writeWork(
    String kind,
    String source,
    String entityId, {
    required String status,
    String? error,
    int? attempts,
  }) async {
    await _store.writeWork(
      kind,
      source,
      entityId,
      status: status,
      error: error,
      attempts: attempts,
    );
    _claimed.remove((kind, source, entityId));
  }

  /// Back to `pending` without spending an attempt. The session ending or the
  /// server being down says nothing about this item; [outcome] says how far
  /// the park reaches and [reason] tells the activity row why.
  Future<_RunOutcome> _park(
    String kind,
    String source,
    String id,
    _RunOutcome outcome,
    String reason,
    int durationMs,
  ) async {
    await _writeWork(kind, source, id, status: 'pending');
    await _log.record(
      kind,
      status: 'parked',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {'reason': reason},
    );
    await _emit(kind);
    return outcome;
  }

  Future<_RunOutcome> _recordFailure(
    String kind,
    Map<String, Object?> item,
    Object error,
    int? statusCode,
    int durationMs,
  ) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final attempts = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
    // A 400 from a json_schema request is this app's schema being wrong, not
    // the model's answer. It is identical on every retry, so retrying it
    // burns model time to reproduce a bug.
    final fatal = statusCode == 400 || attempts >= _maxAttempts;
    await _writeWork(
      kind,
      source,
      id,
      status: fatal ? 'error' : 'pending',
      error: '$error',
      attempts: attempts,
    );
    // `retry` while the item still has an attempt left, `error` once it does
    // not — the work row's `pending` cannot tell those apart after the fact.
    await _log.record(
      kind,
      status: fatal ? 'error' : 'retry',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {
        'error': '$error',
        'attempts': attempts,
        'status_code': ?statusCode,
      },
    );
    await _emit(kind);
    return _RunOutcome.ok;
  }

  /// Awaited by every caller, never fired and forgotten: the counts are read
  /// from the rows, so an unawaited emit would be free to report a queue that
  /// has already moved on.
  Future<void> _emit(String kind) async {
    if (_progress.isClosed) return;
    final counts = await _store.workCounts(kind, sources: _sources);
    if (_progress.isClosed) return;
    _progress.add(WorkProgress(kind, counts));
  }
}
