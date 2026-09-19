import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/ai_workers.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_handlers.dart';
import 'fixtures/test_db.dart';

/// The three lanes as one value: what `pumpAll` promises, and what the merged
/// progress stream carries.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  test('pumpAll waits for work the fast drain queued while it ran', () async {
    // The whole reason the shape is chained rather than a three-way wait: the
    // draft row does not exist when `pumpAll` is called. A draft pump started
    // beside the fast one would resolve against an empty queue seconds before
    // extraction wrote anything, and "the sync's pump completed" would stop
    // meaning "and the drafts are done".
    final drafts = ScriptedHandler('draft');
    final fast = ScriptedHandler(
      'extract',
      onRun: (item) async {
        await store.enqueueWork('draft', 'email', 'd1');
        await store.enqueueWork('storyline_recap', 'email', 's1');
      },
    );
    final recaps = ScriptedHandler('storyline_recap');

    await store.enqueueWork('extract', 'email', 'm1');

    final workers = AiWorkers(
      fast: AiWorker(store, handlers: [fast], gate: DrainGate()),
      storyline: AiWorker(store, handlers: [recaps], gate: DrainGate()),
      draft: AiWorker(store, handlers: [drafts], gate: DrainGate()),
    );
    addTearDown(workers.dispose);
    addTearDown(workers.fast.dispose);
    addTearDown(workers.storyline.dispose);
    addTearDown(workers.draft.dispose);

    await workers.pumpAll();

    expect(fast.seen, ['m1']);
    expect(drafts.seen, ['d1']);
    expect(recaps.seen, ['s1']);
  });

  test('progress carries every lane\'s kinds on one stream', () async {
    final workers = AiWorkers(
      fast: AiWorker(
        store,
        handlers: [ScriptedHandler('extract')],
        gate: DrainGate(),
      ),
      storyline: AiWorker(
        store,
        handlers: [ScriptedHandler('storyline_recap')],
        gate: DrainGate(),
      ),
      draft: AiWorker(
        store,
        handlers: [ScriptedHandler('draft')],
        gate: DrainGate(),
      ),
    );
    addTearDown(workers.dispose);
    addTearDown(workers.fast.dispose);
    addTearDown(workers.storyline.dispose);
    addTearDown(workers.draft.dispose);

    final kinds = <String>{};
    final subscription = workers.progress.listen((p) => kinds.add(p.kind));
    addTearDown(subscription.cancel);

    await store.enqueueWork('extract', 'email', 'm1');
    await store.enqueueWork('storyline_recap', 'email', 's1');
    await store.enqueueWork('draft', 'email', 'd1');
    await workers.pumpAll();

    // One listener in the app wants all of them — the inbox reloads on any
    // progress, and three lanes are three sources of news about one list.
    expect(kinds, containsAll(['extract', 'storyline_recap', 'draft']));
  });

  test('the fast lane wakes the other two on its own', () async {
    // What replaces list position. The fast handlers write the `storyline*`
    // and `draft` rows; the workers that drain them have no idea they were
    // written, so the end of the fast drain is where they are told.
    final drafts = ScriptedHandler('draft');
    final recaps = ScriptedHandler('storyline_recap');
    final fast = ScriptedHandler(
      'extract',
      onRun: (item) async {
        await store.enqueueWork('draft', 'email', 'd1');
        await store.enqueueWork('storyline_recap', 'email', 's1');
      },
    );

    final storylineWorker =
        AiWorker(store, handlers: [recaps], gate: DrainGate());
    final draftWorker = AiWorker(store, handlers: [drafts], gate: DrainGate());
    addTearDown(storylineWorker.dispose);
    addTearDown(draftWorker.dispose);

    final woken = <Future<void>>[];
    final fastWorker = AiWorker(
      store,
      handlers: [fast],
      gate: DrainGate(),
      onDrained: () {
        woken
          ..add(storylineWorker.pump())
          ..add(draftWorker.pump());
      },
    );
    addTearDown(fastWorker.dispose);

    await store.enqueueWork('extract', 'email', 'm1');
    // The fast lane alone — no `pumpAll`, and no second external pump. This is
    // the path a triage drain's own `onDrained` takes.
    await fastWorker.pump();
    await Future.wait(woken);

    expect(drafts.seen, ['d1']);
    expect(recaps.seen, ['s1']);
  });

  group('the fast lane re-arms the storyline sweep', () {
    /// A fast worker wired the way `_lane` wires the real one: the sweep row
    /// is re-armed before the storyline lane is woken, and only when the drain
    /// actually processed something.
    AiWorker fastLane(
      ScriptedHandler handler,
      AiWorker storylineWorker,
      List<Future<void>> woken,
    ) {
      late final AiWorker fast;
      fast = AiWorker(
        store,
        handlers: [handler],
        gate: DrainGate(),
        onDrained: () {
          woken.add(() async {
            if (fast.lastDrainCount > 0) await store.requeueSweep();
            await storylineWorker.pump();
          }());
        },
      );
      return fast;
    }

    test('a drain that did work queues a sweep, and the lane runs it',
        () async {
      final sweeps = ScriptedHandler('storyline_sweep');
      final storylineWorker =
          AiWorker(store, handlers: [sweeps], gate: DrainGate());
      addTearDown(storylineWorker.dispose);
      final woken = <Future<void>>[];
      final fast = fastLane(ScriptedHandler('extract'), storylineWorker, woken);
      addTearDown(fast.dispose);

      // The sweep row as it is on a machine that has synced before: already
      // run, already closed. A requeue is what brings it back; an enqueue
      // would find it and do nothing.
      await store.requeueSweep();
      await store.writeWork('storyline_sweep', 'email', 'sweep',
          status: 'done');
      await store.enqueueWork('extract', 'email', 'm1');

      await fast.pump();
      await Future.wait(woken);

      expect(sweeps.seen, ['sweep']);
    });

    test('an empty drain leaves the sweep where it is', () async {
      final sweeps = ScriptedHandler('storyline_sweep');
      final storylineWorker =
          AiWorker(store, handlers: [sweeps], gate: DrainGate());
      addTearDown(storylineWorker.dispose);
      final woken = <Future<void>>[];
      final fast = fastLane(ScriptedHandler('extract'), storylineWorker, woken);
      addTearDown(fast.dispose);

      await store.requeueSweep();
      await store.writeWork('storyline_sweep', 'email', 'sweep',
          status: 'done');

      // Nothing queued for the fast lane at all. `onDrained` still fires, and
      // an ungated requeue here would spend a whole sweep after every idle
      // pump the app makes.
      await fast.pump();
      await Future.wait(woken);

      expect(sweeps.seen, isEmpty);
      expect(await store.workCounts('storyline_sweep'), {'done': 1});
    });

    test('a sweep already at the server is not doubled', () async {
      final sweeps = ScriptedHandler('storyline_sweep');
      final storylineWorker =
          AiWorker(store, handlers: [sweeps], gate: DrainGate());
      addTearDown(storylineWorker.dispose);
      final woken = <Future<void>>[];
      final fast = fastLane(ScriptedHandler('extract'), storylineWorker, woken);
      addTearDown(fast.dispose);

      await store.requeueSweep();
      await store.writeWork('storyline_sweep', 'email', 'sweep',
          status: 'processing');
      await store.enqueueWork('extract', 'email', 'm1');

      await fast.pump();
      await Future.wait(woken);

      // A sweep is one item that takes minutes; flipping its claim back to
      // pending would hand the same pass to a second drain.
      expect(await store.workCounts('storyline_sweep'), {'processing': 1});
      expect(sweeps.seen, isEmpty);
    });
  });

  test('dispose drops the merge and leaves the workers alone', () async {
    final fast =
        AiWorker(store, handlers: [ScriptedHandler('extract')], gate: DrainGate());
    final workers = AiWorkers(
      fast: fast,
      storyline: AiWorker(store, handlers: const [], gate: DrainGate()),
      draft: AiWorker(store, handlers: const [], gate: DrainGate()),
    );
    addTearDown(fast.dispose);
    addTearDown(workers.storyline.dispose);
    addTearDown(workers.draft.dispose);

    var seen = 0;
    final subscription = workers.progress.listen((_) => seen++);
    addTearDown(subscription.cancel);

    await store.enqueueWork('extract', 'email', 'm1');
    await fast.pump();
    expect(seen, greaterThan(0));

    await workers.dispose();
    final before = seen;

    // The workers outlive the merge — their own providers dispose them — so a
    // pump after this still drains and simply reaches no listener here.
    await store.enqueueWork('extract', 'email', 'm2');
    await fast.pump();
    expect(seen, before);
  });
}
