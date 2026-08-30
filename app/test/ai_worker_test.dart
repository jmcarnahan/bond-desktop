import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// A [WorkHandler] that answers from a script and does no work.
///
/// It records concurrency as well as calls: "one item in flight, ever" is the
/// worker's central promise, and a fake that only counted calls could not tell
/// a serial drain from a parallel one.
class ScriptedHandler implements WorkHandler {
  @override
  final String kind;

  /// Consumed in order. An `Exception` or an `Error` is thrown, anything else
  /// is a success. The last entry repeats once the script runs out.
  final List<Object?> script;

  /// Run inside [run], before the suspension — for the assertions that are
  /// about what is true WHILE an item is being worked on.
  final void Function(Map<String, Object?> item)? onRun;

  final List<String> seen = [];
  int inFlight = 0;
  int maxInFlight = 0;

  ScriptedHandler(
    this.kind, {
    List<Object?> script = const [null],
    this.onRun,
  }) : script = [...script];

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      onRun?.call(item);
      // A real handler suspends; without a suspension here two overlapping
      // pumps could interleave in a way the fake would never see.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final step = script.length > 1 ? script.removeAt(0) : script.first;
      if (step is Exception) throw step;
      if (step is Error) throw step;
    } finally {
      inFlight--;
    }
  }
}

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Map<String, Object?> workRow(String kind, String entityId) =>
      Map<String, Object?>.from(
        db.select(
          'SELECT * FROM work_items WHERE task_kind = ? AND entity_id = ?',
          [kind, entityId],
        ).single,
      );

  group('drain', () {
    test('runs strictly one item at a time', () async {
      for (final id in ['a', 'b', 'c']) {
        store.enqueueWork('extract', 'email', id);
      }
      final handler = ScriptedHandler('extract');
      final worker = AiWorker(store, handlers: [handler]);

      // Two pumps started together: the second must find the first running and
      // return rather than race it.
      await Future.wait([worker.pump(), worker.pump()]);

      expect(handler.maxInFlight, 1);
      expect(handler.seen.length, 3);
      expect(store.workCounts('extract'), {'done': 3});
    });

    test('stops when nothing is pending, having called nothing', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.writeWork('extract', 'email', 'a', status: 'done');
      final handler = ScriptedHandler('extract');

      await AiWorker(store, handlers: [handler]).pump();

      expect(handler.seen, isEmpty);
    });

    test('drains the handlers in list order', () async {
      store.enqueueWork('second', 'email', 'b');
      store.enqueueWork('first', 'email', 'a');
      final order = <String>[];
      final first = ScriptedHandler('first', onRun: (_) => order.add('first'));
      final second = ScriptedHandler('second', onRun: (_) => order.add('second'));

      await AiWorker(store, handlers: [first, second]).pump();

      expect(order, ['first', 'second']);
    });

    test('a queued kind with no handler is left alone', () async {
      store.enqueueWork('extract', 'email', 'mine');
      store.enqueueWork('unknown', 'email', 'theirs');
      final handler = ScriptedHandler('extract');

      await AiWorker(store, handlers: [handler]).pump();

      expect(handler.seen, ['mine']);
      expect(workRow('unknown', 'theirs')['status'], 'pending');
    });

    test('an item is claimed before the handler suspends', () async {
      store.enqueueWork('extract', 'email', 'm1');
      var statusDuringRun = '';
      final handler = ScriptedHandler(
        'extract',
        onRun: (_) {
          statusDuringRun = workRow('extract', 'm1')['status'] as String;
        },
      );

      await AiWorker(store, handlers: [handler]).pump();

      // The claim is what keeps a re-entrant pump — or a crash — from handing
      // the same item to a second drain.
      expect(statusDuringRun, 'processing');
      expect(workRow('extract', 'm1')['status'], 'done');
    });
  });

  group('parking', () {
    test('a model server that is down costs the item nothing', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmUnavailableException('not reachable')],
      );

      await AiWorker(store, handlers: [handler]).pump();

      // One call, then the drain gives up: the item behind it would have
      // failed identically.
      expect(handler.seen.length, 1);
      expect(store.workCounts('extract'), {'pending': 2});
      expect(workRow('extract', handler.seen.single)['attempts'], 0);
    });

    test('a park stops the kinds behind it too', () async {
      store.enqueueWork('first', 'email', 'a');
      store.enqueueWork('second', 'email', 'b');
      final first = ScriptedHandler(
        'first',
        script: [const LlmUnavailableException('not reachable')],
      );
      final second = ScriptedHandler('second');

      await AiWorker(store, handlers: [first, second]).pump();

      // Both queues run against the same server. Marching on to the next kind
      // would be a hundred more failures for the same reason.
      expect(second.seen, isEmpty);
      expect(workRow('second', 'b')['status'], 'pending');
    });

    test('a dead session parks the drain', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      final handler = ScriptedHandler('extract', script: [const NotSignedIn()]);

      await AiWorker(store, handlers: [handler]).pump();

      expect(handler.seen.length, 1);
      expect(store.workCounts('extract'), {'pending': 2});
    });

    test('missing consent parks the drain the same way', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler =
          ScriptedHandler('extract', script: [const ReconsentRequired()]);

      await AiWorker(store, handlers: [handler]).pump();

      expect(workRow('extract', 'a')['status'], 'pending');
      expect(workRow('extract', 'a')['attempts'], 0);
    });

    test('the next pump picks up where a downed server left off', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmUnavailableException('not reachable'), null],
      );
      final worker = AiWorker(store, handlers: [handler]);

      await worker.pump();
      expect(workRow('extract', 'a')['status'], 'pending');

      await worker.pump();
      expect(workRow('extract', 'a')['status'], 'done');
    });
  });

  group('failure', () {
    test('a schema 400 is this app\'s bug and is never retried', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmException('JSON schema conversion failed', 400)],
      );

      await AiWorker(store, handlers: [handler]).pump();

      expect(handler.seen.length, 1);
      final row = workRow('extract', 'a');
      expect(row['status'], 'error');
      expect(row['attempts'], 1);
      expect(row['error'], contains('JSON schema conversion failed'));
    });

    test('any other failure is retried once, then left as an error', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmFormatException('not json')],
      );

      await AiWorker(store, handlers: [handler]).pump();

      expect(handler.seen.length, 2);
      final row = workRow('extract', 'a');
      expect(row['status'], 'error');
      expect(row['attempts'], 2);
    });

    test('a retry that succeeds stores the result', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmFormatException('not json'), null],
      );

      await AiWorker(store, handlers: [handler]).pump();

      final row = workRow('extract', 'a');
      expect(row['status'], 'done');
      expect(row['attempts'], 1);
    });

    test('a thrown Error is caught like any other failure', () async {
      store.enqueueWork('extract', 'email', 'a');
      final handler = ScriptedHandler(
        'extract',
        script: [StateError('the database moved')],
      );

      await AiWorker(store, handlers: [handler]).pump();

      // A StateError is an Error, not an Exception. Nothing about it should
      // escape the drain and take the whole pump down with it.
      final row = workRow('extract', 'a');
      expect(row['status'], 'error');
      expect(row['attempts'], 2);
      expect(row['error'], contains('the database moved'));
    });

    test('a failure does not stop the drain behind it', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmException('boom', 400), null],
      );

      await AiWorker(store, handlers: [handler]).pump();

      expect(store.workCounts('extract'), {'error': 1, 'done': 1});
    });
  });

  group('interruption', () {
    test('resetInterrupted returns a claimed item to the queue', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.writeWork('extract', 'email', 'a', status: 'processing');
      final handler = ScriptedHandler('extract');
      final worker = AiWorker(store, handlers: [handler]);

      expect(store.nextPendingWork('extract'), isNull);
      worker.resetInterrupted();
      expect(store.nextPendingWork('extract'), isNotNull);

      await worker.pump();

      expect(workRow('extract', 'a')['status'], 'done');
    });
  });

  group('progress', () {
    test('emits before the first item and after every one', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      final worker = AiWorker(store, handlers: [ScriptedHandler('extract')]);
      final seen = <int>[];
      final subscription = worker.progress.listen((p) => seen.add(p.remaining));

      await worker.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      // Two pending before the first call, then one, then none — the leading
      // emit is what puts a count on screen before the first long wait.
      expect(seen, [2, 1, 0]);
    });

    test('counts are the rows, so done and total add up', () async {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      final handler = ScriptedHandler(
        'extract',
        script: [const LlmException('boom', 400), null],
      );
      final worker = AiWorker(store, handlers: [handler]);
      WorkProgress? last;
      final subscription = worker.progress.listen((p) => last = p);

      await worker.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(last!.kind, 'extract');
      expect(last!.total, 2);
      expect(last!.done, 2);
      expect(last!.remaining, 0);
      expect(last!.counts, {'error': 1, 'done': 1});
    });
  });

  test('stop ends the drain after the item in flight', () async {
    store.enqueueWork('extract', 'email', 'a');
    store.enqueueWork('extract', 'email', 'b');
    late AiWorker worker;
    final handler = ScriptedHandler('extract', onRun: (_) => worker.stop());
    worker = AiWorker(store, handlers: [handler]);

    await worker.pump();

    expect(handler.seen.length, 1);
    expect(store.workCounts('extract'), {'done': 1, 'pending': 1});
  });
}
