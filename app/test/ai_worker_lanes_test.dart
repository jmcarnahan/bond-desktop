import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_handlers.dart';
import 'fixtures/test_db.dart';

/// What two workers on two gates buy, and what the callback that joins them
/// promises.
///
/// `ai_worker_test.dart` covers one worker's decisions; this file is about the
/// property the whole three-lane split exists for — that a slow item on the
/// prose lane cannot delay a fast item on the fast one — plus the two
/// mechanisms that replace list position now that the lanes are separate:
/// `onDrained`, and a concurrency read through a closure.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> queue(String kind, List<String> ids) async {
    for (final id in ids) {
      await store.enqueueWork(kind, 'email', id);
    }
  }

  test('a slow prose item does not delay the fast lane', () async {
    // The shape the targets rest on: one 300 ms draft against ten 1 ms
    // extractions, on their own gates. Under the old single gate — one worker,
    // one list — the drain reached drafting last and every one of these would
    // have been behind it; the failure this pins is the reverse, a fast item
    // waiting on prose.
    final slow = ScriptedHandler(
      'draft',
      duration: const Duration(milliseconds: 300),
    );
    final fast = ScriptedHandler(
      'extract',
      duration: const Duration(milliseconds: 1),
    );

    await queue('draft', ['d1']);
    await queue('extract', [for (var i = 1; i <= 10; i++) 'm$i']);

    final draftWorker =
        AiWorker(store, handlers: [slow], gate: DrainGate());
    final fastWorker = AiWorker(store, handlers: [fast], gate: DrainGate());
    addTearDown(draftWorker.dispose);
    addTearDown(fastWorker.dispose);

    await Future.wait([draftWorker.pump(), fastWorker.pump()]);

    expect(fast.seen, hasLength(10));
    expect(slow.seen, ['d1']);
    // Every fast item finished before the prose one did. Read off the
    // handlers' own clocks rather than a wall-clock assertion, so a loaded CI
    // machine cannot fail this for a reason that is not the lanes.
    for (final finished in fast.finishedAt) {
      expect(finished, lessThan(slow.finishedAt.single));
    }
  });

  test('two lanes sharing ONE gate serialise, which is the control', () async {
    // The same two handlers behind one gate: the drafts win the FIFO and the
    // ten fast items wait. Here so the test above is read as a property of the
    // gates rather than of the durations.
    final slow = ScriptedHandler(
      'draft',
      duration: const Duration(milliseconds: 300),
    );
    final fast = ScriptedHandler(
      'extract',
      duration: const Duration(milliseconds: 1),
    );

    await queue('draft', ['d1']);
    await queue('extract', [for (var i = 1; i <= 10; i++) 'm$i']);

    final gate = DrainGate();
    final draftWorker = AiWorker(store, handlers: [slow], gate: gate);
    final fastWorker = AiWorker(store, handlers: [fast], gate: gate);
    addTearDown(draftWorker.dispose);
    addTearDown(fastWorker.dispose);

    final drafting = draftWorker.pump();
    final fastDrain = fastWorker.pump();
    await Future.wait([drafting, fastDrain]);

    for (final finished in fast.finishedAt) {
      expect(finished, greaterThan(slow.finishedAt.single));
    }
  });

  group('onDrained', () {
    test('fires once per completed drain, empty ones included', () async {
      var fired = 0;
      final handler = ScriptedHandler('extract');
      final worker = AiWorker(
        store,
        handlers: [handler],
        onDrained: () => fired++,
      );
      addTearDown(worker.dispose);

      // Nothing queued at all: the case that matters most, because a Restore
      // or a Regenerate enqueues a row on ANOTHER lane and this callback is
      // the only thing that would wake it.
      await worker.pump();
      expect(fired, 1);
      expect(handler.seen, isEmpty);

      await queue('extract', ['m1']);
      await worker.pump();
      expect(fired, 2);
      expect(handler.seen, ['m1']);
    });

    test('runs once the drain is finished, and may take the gate', () async {
      // Two things at once, because they are the same fact: the callback sees
      // every item of this drain already done, and a worker it wakes on the
      // SAME gate actually drains. A callback fired from inside `_drainAll`
      // would fail the first and, on the shared fast gate, queue the second
      // behind the drain that started it.
      final gate = DrainGate();
      final handler = ScriptedHandler('extract');
      final otherHandler = ScriptedHandler('draft');
      final otherWorker =
          AiWorker(store, handlers: [otherHandler], gate: gate);
      addTearDown(otherWorker.dispose);

      Future<void>? woken;
      int? seenWhenDrained;
      final worker = AiWorker(
        store,
        handlers: [handler],
        gate: gate,
        onDrained: () {
          seenWhenDrained = handler.seen.length;
          woken = otherWorker.pump();
        },
      );
      addTearDown(worker.dispose);

      await queue('extract', ['m1', 'm2']);
      await queue('draft', ['d1']);
      await worker.pump();

      expect(seenWhenDrained, 2);
      expect(handler.inFlight, 0);
      await woken;
      expect(otherHandler.seen, ['d1']);
    });

    test('a callback that throws does not fail the drain', () async {
      final handler = ScriptedHandler('extract');
      final worker = AiWorker(
        store,
        handlers: [handler],
        onDrained: () => throw StateError('the other lane went away'),
      );
      addTearDown(worker.dispose);

      await queue('extract', ['m1']);
      // The work is already written by the time the callback runs; a throw
      // must not turn a completed drain into a failed future.
      await expectLater(worker.pump(), completes);
      expect(handler.seen, ['m1']);
    });

    test('a stopped drain wakes nothing', () async {
      var fired = 0;
      final handler = HeldHandler('extract');
      final worker = AiWorker(
        store,
        handlers: [handler],
        onDrained: () => fired++,
      );

      await queue('extract', ['m1']);
      final drain = worker.pump();
      await handler.started.future;
      // A dispose mid-drain: the lanes this one feeds are being torn down
      // beside it, and waking them is how a test suite gets an unhandled
      // error out of a closed database. `dispose` sets the stop flag
      // synchronously, so it goes first and the held item is released after.
      final disposed = worker.dispose();
      handler.release();
      await drain;
      await disposed;

      expect(fired, 0);
    });
  });

  test('a width closure is re-read on every launch decision', () async {
    // What makes Settings › Drafts in flight live: `AiWorker._drainAll` asks
    // the handler for its concurrency before each launch, so a width raised
    // mid-drain moves the NEXT item rather than the next launch of the app.
    var width = 1;
    final handler = ScriptedHandler(
      'draft',
      duration: const Duration(milliseconds: 20),
      width: () => width,
    );
    final worker = AiWorker(store, handlers: [handler]);
    addTearDown(worker.dispose);

    await queue('draft', ['d1', 'd2', 'd3', 'd4']);
    final first = worker.pump();
    // While the first item is in flight, at a width of one.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(handler.maxInFlight, 1);
    width = 2;
    await first;

    expect(handler.seen, hasLength(4));
    expect(handler.maxInFlight, 2);
  });
}
