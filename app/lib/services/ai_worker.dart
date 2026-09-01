import 'dart:async';

import '../data/message_store.dart';
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
/// claim-before-await, the same failure policy, the same park-on-unavailable —
/// and it is a COPY rather than a shared base class on purpose. Triage is
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

  bool _stopped = false;

  AiWorker(this._store, {required List<WorkHandler> handlers, DrainGate? gate})
      : _handlers = List.unmodifiable(handlers),
        _gate = gate ?? DrainGate();

  Stream<WorkProgress> get progress => _progress.stream;

  /// Ends the current drain after the items already in flight finish. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

  /// Clears claims a previous run left behind, across every kind. Startup only
  /// — it must not run while a worker holds a claim, or it would hand that
  /// item to a second drain.
  void resetInterrupted() => _store.resetInterruptedWork();

  void dispose() {
    _stopped = true;
    _progress.close();
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
        _emit(handler.kind);

        // Up to [WorkHandler.concurrency] items of this kind at the server at
        // once. What makes that safe is the claim: [_runOne] writes
        // `processing` SYNCHRONOUSLY before its first await, and there is no
        // await between [nextPendingWork] and the call to it, so the row is
        // off the pending list before this loop can ask for another one. An
        // item can never be handed to two futures. Do not put an await
        // between those two statements.
        final inFlight = <Future<void>>{};
        var parkedKind = false;
        var parkedDrain = false;
        while (!_stopped && !parkedKind && !parkedDrain) {
          while (inFlight.length < handler.concurrency &&
              !_stopped &&
              !parkedKind &&
              !parkedDrain) {
            final item = _store.nextPendingWork(
              handler.kind,
              sources: _sources,
            );
            if (item == null) break;
            late final Future<void> future;
            future = _runOne(handler, item).then((outcome) {
              parkedKind |= outcome == _RunOutcome.parkKind;
              parkedDrain |= outcome == _RunOutcome.parkDrain;
            }).whenComplete(() => inFlight.remove(future));
            inFlight.add(future);
          }
          if (inFlight.isEmpty) break;
          // Over a COPY: `whenComplete` mutates the set as each item lands.
          await Future.any(inFlight.toList());
        }
        // A park stops new launches, never the work already at the server:
        // those answers are paid for and their results are kept.
        await Future.wait(inFlight.toList());

        // A dead session fails every kind identically, so nothing behind this
        // one is worth trying — and neither is a repump, which would park on
        // the same dead session all over again. A server that is down is not
        // that: it is one kind's server, and the next kind may be on another.
        if (parkedDrain) return;
      }
    } while (_repump && !_stopped);
  }

  /// One item, and what its outcome means for the rest of the drain.
  Future<_RunOutcome> _runOne(
    WorkHandler handler,
    Map<String, Object?> item,
  ) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';

    // Claimed before the first await. A crash mid-model-call therefore leaves
    // the row in `processing`, which is exactly what [resetInterrupted] looks
    // for at the next launch — and what keeps a re-entrant pump, or the
    // sibling futures of this same drain, from handing the same item out
    // twice.
    _store.writeWork(handler.kind, source, id, status: 'processing');

    try {
      await handler.run(item);
      _store.writeWork(handler.kind, source, id, status: 'done');
      _emit(handler.kind);
      return _RunOutcome.ok;
    } on LlmUnavailableException {
      // Nothing about this item failed, so it does not spend an attempt. This
      // kind stops too: every item of it behind this one would fail
      // identically, and marking a hundred of them is just noise on a laptop
      // where that model server is not running.
      return _park(handler.kind, source, id, _RunOutcome.parkKind);
    } on NotSignedIn {
      return _park(handler.kind, source, id, _RunOutcome.parkDrain);
    } on ReconsentRequired {
      return _park(handler.kind, source, id, _RunOutcome.parkDrain);
    } on LlmException catch (e) {
      return _recordFailure(handler.kind, item, e, e.statusCode);
    } catch (e) {
      return _recordFailure(handler.kind, item, e, null);
    }
  }

  /// Back to `pending` without spending an attempt. The session ending or the
  /// server being down says nothing about this item.
  _RunOutcome _park(
    String kind,
    String source,
    String id,
    _RunOutcome outcome,
  ) {
    _store.writeWork(kind, source, id, status: 'pending');
    _emit(kind);
    return outcome;
  }

  _RunOutcome _recordFailure(
    String kind,
    Map<String, Object?> item,
    Object error,
    int? statusCode,
  ) {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final attempts = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
    // A 400 from a json_schema request is this app's schema being wrong, not
    // the model's answer. It is identical on every retry, so retrying it
    // burns model time to reproduce a bug.
    final fatal = statusCode == 400 || attempts >= _maxAttempts;
    _store.writeWork(
      kind,
      source,
      id,
      status: fatal ? 'error' : 'pending',
      error: '$error',
      attempts: attempts,
    );
    _emit(kind);
    return _RunOutcome.ok;
  }

  void _emit(String kind) {
    if (_progress.isClosed) return;
    _progress.add(
      WorkProgress(kind, _store.workCounts(kind, sources: _sources)),
    );
  }
}
