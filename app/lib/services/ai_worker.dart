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

  /// One row from `work_items`. `entity_id` names what to work on.
  Future<void> run(Map<String, Object?> item);
}

/// Drains the `work_items` queue through its handlers, one item at a time.
///
/// This is `TriageQueue`'s protocol, generalised over a task kind — the same
/// claim-before-await, the same failure policy, the same park-on-unavailable —
/// and it is a COPY rather than a shared base class on purpose. Triage is
/// hard-wired to the `messages` table by decision: its queue, its gates and
/// its fold-up are one thing, and the seam that would let them be shared is
/// not worth the coupling.
///
/// Strictly serial for the reason triage is: the model generates at about
/// twelve tokens a second, so a second concurrent request does not go twice as
/// fast, it makes both take twice as long and throws away llama-server's
/// prompt cache between them. The kinds drain in handler order rather than
/// interleaved, for the same reason — and the caller chains this worker's
/// [pump] AFTER triage's so the two queues never reach the one server at once.
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

  /// Ends the current drain after the item in flight finishes. Not permanent:
  /// the next [pump] starts a fresh drain.
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

        var carryOn = true;
        while (!_stopped) {
          final item = _store.nextPendingWork(
            handler.kind,
            sources: _sources,
          );
          if (item == null) break;
          carryOn = await _runOne(handler, item);
          if (!carryOn) break;
        }
        // A park is about the model server or the session, not about this
        // kind, so the kinds behind it stop too — and so does any repump: it
        // would park on the same server or the same session all over again.
        if (!carryOn) return;
      }
    } while (_repump && !_stopped);
  }

  /// One item. Returns false when the whole drain should stop rather than move
  /// on.
  Future<bool> _runOne(WorkHandler handler, Map<String, Object?> item) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';

    // Claimed before the first await. A crash mid-model-call therefore leaves
    // the row in `processing`, which is exactly what [resetInterrupted] looks
    // for at the next launch — and what keeps a re-entrant pump from handing
    // the same item to two drains.
    _store.writeWork(handler.kind, source, id, status: 'processing');
    final sw = Stopwatch()..start();

    try {
      await handler.run(item);
      _store.writeWork(handler.kind, source, id, status: 'done');
      // The work row is `done` either way; the activity row is where a
      // handler that early-returned gets to say so. [ActivityLog.note] and
      // [ActivityLog.noteStatus] are how it does that without throwing, and
      // both are folded in and cleared by this one call.
      _log.record(
        handler.kind,
        status: _log.pendingStatusOr('ok'),
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
      );
      _emit(handler.kind);
      return true;
    } on LlmUnavailableException {
      // Nothing about this item failed, so it does not spend an attempt. The
      // drain stops too: every item behind it would fail identically, and
      // marking a hundred of them is just noise on a laptop where the model
      // server is not running.
      return _park(
        handler.kind,
        source,
        id,
        'model_unavailable',
        sw.elapsedMilliseconds,
      );
    } on NotSignedIn {
      return _park(handler.kind, source, id, 'session', sw.elapsedMilliseconds);
    } on ReconsentRequired {
      return _park(handler.kind, source, id, 'session', sw.elapsedMilliseconds);
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

  /// Back to `pending` without spending an attempt, and the drain parks. The
  /// session ending or the server being down says nothing about this item.
  bool _park(
    String kind,
    String source,
    String id,
    String reason,
    int durationMs,
  ) {
    _store.writeWork(kind, source, id, status: 'pending');
    _log.record(
      kind,
      status: 'parked',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {'reason': reason},
    );
    _emit(kind);
    return false;
  }

  bool _recordFailure(
    String kind,
    Map<String, Object?> item,
    Object error,
    int? statusCode,
    int durationMs,
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
    // `retry` while the item still has an attempt left, `error` once it does
    // not — the work row's `pending` cannot tell those apart after the fact.
    _log.record(
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
    _emit(kind);
    return true;
  }

  void _emit(String kind) {
    if (_progress.isClosed) return;
    _progress.add(
      WorkProgress(kind, _store.workCounts(kind, sources: _sources)),
    );
  }
}
