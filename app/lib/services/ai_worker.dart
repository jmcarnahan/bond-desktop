import 'dart:async';

import '../data/message_store.dart';
import 'graph_auth.dart';
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
  static const String _source = 'email';

  /// One retry, then the item is left alone. Same trade triage makes: a local
  /// model that answered unparseably often gets it right on a second pass, and
  /// an item that fails twice will fail every time.
  static const int _maxAttempts = 2;

  final MessageStore _store;
  final List<WorkHandler> _handlers;

  final StreamController<WorkProgress> _progress =
      StreamController<WorkProgress>.broadcast();

  bool _running = false;
  bool _stopped = false;

  AiWorker(this._store, {required List<WorkHandler> handlers})
      : _handlers = List.unmodifiable(handlers);

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
  /// every item behind the current one. Idempotent: a second call while a
  /// drain is running returns immediately rather than starting a racing one.
  Future<void> pump() async {
    if (_running) return;
    _running = true;
    _stopped = false;
    try {
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
            sources: const [_source],
          );
          if (item == null) break;
          carryOn = await _runOne(handler, item);
          if (!carryOn) break;
        }
        // A park is about the model server or the session, not about this
        // kind, so the kinds behind it stop too.
        if (!carryOn) break;
      }
    } finally {
      _running = false;
    }
  }

  /// One item. Returns false when the whole drain should stop rather than move
  /// on.
  Future<bool> _runOne(WorkHandler handler, Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    // Claimed before the first await. A crash mid-model-call therefore leaves
    // the row in `processing`, which is exactly what [resetInterrupted] looks
    // for at the next launch — and what keeps a re-entrant pump from handing
    // the same item to two drains.
    _store.writeWork(handler.kind, source, id, status: 'processing');

    try {
      await handler.run(item);
      _store.writeWork(handler.kind, source, id, status: 'done');
      _emit(handler.kind);
      return true;
    } on LlmUnavailableException {
      // Nothing about this item failed, so it does not spend an attempt. The
      // drain stops too: every item behind it would fail identically, and
      // marking a hundred of them is just noise on a laptop where the model
      // server is not running.
      return _park(handler.kind, source, id);
    } on NotSignedIn {
      return _park(handler.kind, source, id);
    } on ReconsentRequired {
      return _park(handler.kind, source, id);
    } on LlmException catch (e) {
      return _recordFailure(handler.kind, item, e, e.statusCode);
    } catch (e) {
      return _recordFailure(handler.kind, item, e, null);
    }
  }

  /// Back to `pending` without spending an attempt, and the drain parks. The
  /// session ending or the server being down says nothing about this item.
  bool _park(String kind, String source, String id) {
    _store.writeWork(kind, source, id, status: 'pending');
    _emit(kind);
    return false;
  }

  bool _recordFailure(
    String kind,
    Map<String, Object?> item,
    Object error,
    int? statusCode,
  ) {
    final source = item['source'] as String? ?? _source;
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
    return true;
  }

  void _emit(String kind) {
    if (_progress.isClosed) return;
    _progress.add(
      WorkProgress(kind, _store.workCounts(kind, sources: const [_source])),
    );
  }
}
