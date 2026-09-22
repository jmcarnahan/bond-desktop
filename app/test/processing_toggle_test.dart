import 'dart:async';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/ai_workers.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The processing switch, at the two drains it gates.
///
/// The subject is one promise: while the switch is off NOTHING dials a model —
/// no claim, no gate, no wake — and the item already at the server still
/// lands. It is a closure rather than a flag because the switch moves while a
/// drain is running, and the drains have to read it on every launch decision
/// rather than at the rebuild that never comes.
///
/// A worker built with no `enabled` argument is ON. Every other test in this
/// suite builds one that way, and this file is the reason that has to stay
/// true.

/// A [WorkHandler] that counts, and optionally does something on the way in —
/// which is how the switch gets moved while an item is at the server.
class _Handler extends WorkHandler {
  @override
  final String kind;

  @override
  final int concurrency;

  final FutureOr<void> Function(Map<String, Object?> item)? onRun;

  final List<String> seen = [];

  _Handler(this.kind, {this.onRun, this.concurrency = 1});

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    await onRun?.call(item);
    // A real handler suspends.
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A [DrainGate] that records how many drains it let through. The gate is the
/// last thing before a model server, so "never taken" is the strongest form of
/// "nothing ran".
class _CountingGate extends DrainGate {
  int runs = 0;

  @override
  Future<T> run<T>(Future<T> Function() body) {
    runs++;
    return super.run(body);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> enqueueThree() async {
    for (final id in ['a', 'b', 'c']) {
      await store.enqueueWork('extract', 'email', id);
    }
  }

  group('the work drain', () {
    test('a worker whose enabled flag is false drains nothing', () async {
      await enqueueThree();
      final handler = _Handler('extract');
      var drained = 0;
      final worker = AiWorker(
        store,
        handlers: [handler],
        enabled: () => false,
        onDrained: () => drained++,
      );

      await worker.pump();

      expect(handler.seen, isEmpty);
      expect(await store.workCounts('extract'), {'pending': 3});
      // The wake matters as much as the work: `onDrained` re-arms the
      // storyline sweep, and a drain that fired it on every sixty-second poll
      // would keep queueing passes nothing is allowed to run.
      expect(drained, 0);
    });

    test('the flag flipping off mid-drain finishes the item in flight and '
        'stops', () async {
      await enqueueThree();
      var on = true;
      // The switch moves while the first item is at the server — which is what
      // a person pressing the toggle mid-backlog does.
      final handler = _Handler('extract', onRun: (_) => on = false);
      final worker = AiWorker(store, handlers: [handler], enabled: () => on);

      await worker.pump();

      expect(handler.seen.length, 1);
      // The one that ran is finished and written, and the rest are untouched:
      // the answer already paid for is kept, and nothing new is launched.
      expect(await store.workCounts('extract'), {'done': 1, 'pending': 2});
    });

    test('the gate is never taken while off', () async {
      await enqueueThree();
      final gate = _CountingGate();
      final worker = AiWorker(
        store,
        handlers: [_Handler('extract')],
        gate: gate,
        enabled: () => false,
      );

      await worker.pump();

      expect(gate.runs, 0);
    });

    test('turning the flag back on drains', () async {
      await enqueueThree();
      var on = false;
      final handler = _Handler('extract');
      final worker = AiWorker(store, handlers: [handler], enabled: () => on);

      await worker.pump();
      expect(handler.seen, isEmpty);

      on = true;
      await worker.pump();

      // A fresh drain, not a resumed one: the stop the switch wrote is per
      // drain, and the next pump clears it.
      expect(handler.seen.length, 3);
      expect(await store.workCounts('extract'), {'done': 3});
    });

    test('turning it back on mid-drain finishes that drain rather than the '
        'next one', () async {
      // The reversal that is easy to lose: the switch latches the stop, and a
      // drain still waiting on its last item would drop the repump and go
      // quiet until the next sixty-second poll — a person who flicked the
      // switch twice would watch a full mailbox do nothing.
      await enqueueThree();
      final held = Completer<void>();
      var on = true;
      var drained = 0;
      // Two at a time, so one item can finish and flip the switch while
      // another is still at the server holding the drain open.
      late final _Handler handler;
      handler = _Handler(
        'extract',
        concurrency: 2,
        onRun: (_) async {
          if (handler.seen.length == 1) {
            on = false;
          } else if (handler.seen.length == 2) {
            await held.future;
          }
        },
      );
      final worker = AiWorker(
        store,
        handlers: [handler],
        enabled: () => on,
        onDrained: () => drained++,
      );

      final drain = worker.pump();
      // Long enough for the first item to land and the drain to read the
      // switch: it is now halted, with the second item still in flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      on = true;
      final second = worker.pump();
      held.complete();
      await Future.wait([drain, second]);

      expect(handler.seen.length, 3);
      expect(await store.workCounts('extract'), {'done': 3});
      // Once, for the drain that finished — not once per pump.
      expect(drained, 1);
    });

    test('an off drain does not wake the lanes it feeds', () async {
      await enqueueThree();
      await store.enqueueWork('draft', 'email', 'd1');
      final downstream = _Handler('draft');
      // ON, and holding work: the only reason it could stay idle is that
      // nothing knocked on its door.
      final lane = AiWorker(store, handlers: [downstream]);
      final upstream = AiWorker(
        store,
        handlers: [_Handler('extract')],
        enabled: () => false,
        onDrained: () => unawaited(lane.pump()),
      );

      await upstream.pump();
      await pumpEventQueue();

      expect(downstream.seen, isEmpty);
      expect(await store.workCounts('draft'), {'pending': 1});
    });
  });

  group('AiWorkers.stopAll', () {
    test('stops all three lanes after the item each has in flight', () async {
      final held = <String, Completer<void>>{
        'extract': Completer<void>(),
        'storyline': Completer<void>(),
        'draft': Completer<void>(),
      };
      final handlers = <String, _Handler>{
        for (final kind in held.keys)
          kind: _Handler(kind, onRun: (_) => held[kind]!.future),
      };
      for (final kind in held.keys) {
        await store.enqueueWork(kind, 'email', '$kind-1');
        await store.enqueueWork(kind, 'email', '$kind-2');
      }
      final workers = AiWorkers(
        fast: AiWorker(store, handlers: [handlers['extract']!]),
        storyline: AiWorker(store, handlers: [handlers['storyline']!]),
        draft: AiWorker(store, handlers: [handlers['draft']!]),
      );
      addTearDown(workers.dispose);

      final drains = [
        workers.fast.pump(),
        workers.storyline.pump(),
        workers.draft.pump(),
      ];
      // Until each lane has an item at the server, rather than a fixed wait
      // that a slow machine could beat.
      while (handlers.values.any((h) => h.seen.isEmpty)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      workers.stopAll();
      for (final c in held.values) {
        c.complete();
      }
      await Future.wait(drains);

      // One item landed per lane, the second of each is still waiting: a
      // stop is "finish what is at the server, then end", on all three at
      // once, which is the promise the processing switch's OFF rests on.
      for (final kind in held.keys) {
        // Which of the two landed is the claim order's business (newest
        // first); that exactly one did is this test's.
        expect(handlers[kind]!.seen, hasLength(1), reason: kind);
        expect(await store.workCounts(kind), {'done': 1, 'pending': 1},
            reason: kind);
      }
    });
  });

  group('the triage drain', () {
    Future<void> seedMessage(String id) => store.upsertMessage({
          'source': 'email',
          'source_message_id': id,
          'conversation_key': 'conv-1',
          'direction': 'inbound',
          'subject': 'Launch date',
          'from_name': 'Sarah',
          'from_address': 'sarah@example.com',
          'received_at': '2026-08-29T10:00:00Z',
          'body_text': 'Body of $id',
          'triage_status': 'pending',
        });

    test('a triage queue whose enabled flag is false claims nothing',
        () async {
      await seedMessage('m1');
      await seedMessage('m2');
      final llm = ScriptedLlm.never();
      final gate = _CountingGate();
      final queue = TriageQueue(store, llm, gate: gate, enabled: () => false);
      addTearDown(queue.dispose);

      await queue.pump();

      expect(llm.calls.length, 0);
      expect(gate.runs, 0);
      // Still pending rather than claimed: a `processing` row left behind by a
      // drain that never ran would sit there until the next launch.
      expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
          'pending');
      expect((await store.getMessageRow('email', 'm2'))!['triage_status'],
          'pending');
    });

    test('an off queue still says how many are waiting', () async {
      // The count is the one thing an off pump owes the screen: the rail's
      // "Processing is off · N waiting" reads this stream, and nothing else
      // ever puts a first snapshot on it — a silent return would leave that
      // caption blank on exactly the launch it was written for.
      await seedMessage('m1');
      await seedMessage('m2');
      await seedMessage('m3');
      final queue =
          TriageQueue(store, ScriptedLlm.never(), enabled: () => false);
      addTearDown(queue.dispose);
      final seen = <TriageProgress>[];
      final sub = queue.progress.listen(seen.add);
      addTearDown(sub.cancel);

      await queue.pump();
      // The controller is a broadcast one: the add reaches a listener on the
      // next microtask, not inside the pump.
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.remaining, 3);
    });

    test('turning the flag back on lets the queue claim', () async {
      await seedMessage('m1');
      var on = false;
      final llm = ScriptedLlm.never();
      final queue = TriageQueue(store, llm, enabled: () => on);
      addTearDown(queue.dispose);

      await queue.pump();
      expect(llm.calls.length, 0);

      on = true;
      await queue.pump();

      // The model is dialled, which is all this asserts: the fake throws, and
      // what the queue does with a failure — the retry, the attempt count — is
      // `triage_queue_test`'s subject, not this file's.
      expect(llm.calls.length, greaterThan(0));
    });
  });
}
