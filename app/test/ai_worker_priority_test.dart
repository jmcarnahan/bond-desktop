import 'dart:async';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The priority lane: what a message that arrives mid-backlog costs.
///
/// Two halves, and they are separate mechanisms. The YIELD is what ends the
/// worker's pass so the triage drain waiting on the shared gate gets in. The
/// PRIORITY PASS is what the worker does first when it comes back: the pairs
/// triage just wrote verdicts for, handler by handler, ahead of the backlog.

/// A [WorkHandler] that records the order it saw items in and can reach into
/// the test while an item is at the "server".
class ScriptedHandler extends WorkHandler {
  @override
  final String kind;

  @override
  final int concurrency;

  /// Consumed in order; an `Exception` or an `Error` is thrown. The last entry
  /// repeats once the script runs out.
  final List<Object?> script;

  /// Run inside [run], before the suspension — for the assertions that are
  /// about what is true WHILE an item is being worked on.
  final FutureOr<void> Function(Map<String, Object?> item)? onRun;

  /// Every item this handler saw, as `kind:entity_id`, appended to a list the
  /// whole worker shares so the ORDER across handlers is readable.
  final List<String> order;

  /// How many items this handler had at the "server" at once, at its highest.
  /// The priority pass honours [WorkHandler.concurrency] exactly as the walk
  /// does, and a fake that only recorded order could not tell the two apart.
  int inFlight = 0;
  int maxInFlight = 0;

  ScriptedHandler(
    this.kind,
    this.order, {
    List<Object?> script = const [null],
    this.onRun,
    this.concurrency = 1,
  }) : script = [...script];

  @override
  Future<void> run(Map<String, Object?> item) async {
    order.add('$kind:${item['entity_id'] as String? ?? ''}');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await onRun?.call(item);
      // A real handler suspends; without a suspension here the drains could
      // never interleave in a way the fake would see.
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
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// A message row with a triage verdict already written, plus the two work
  /// items the sync enqueues beside it. [triageStatus] `pending` is the fresh
  /// state the untriaged guard exists for.
  Future<void> seed(
    String id, {
    String source = 'email',
    String triageStatus = 'triaged',
    String receivedAt = '2026-08-29T10:00:00Z',
    List<String> kinds = const ['needs_you', 'extract'],
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': 'Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': receivedAt,
      'body_text': 'Can we still ship on Thursday?',
    });
    if (triageStatus != 'pending') {
      await store.writeTriage(source, id, status: triageStatus);
    }
    for (final kind in kinds) {
      await store.enqueueWork(kind, source, id);
    }
  }

  Future<String?> statusOf(String kind, String id,
          {String source = 'email'}) async =>
      (await db.customSelect(
        'SELECT status FROM work_items '
        'WHERE task_kind = ? AND source = ? AND entity_id = ?',
        variables: [Variable(kind), Variable(source), Variable(id)],
      ).getSingle())
          .data['status'] as String?;

  group('the yield', () {
    test('ends the pass, lets the waiter in, and resumes the backlog',
        () async {
      for (final id in ['m1', 'm2', 'm3']) {
        await seed(id, kinds: const ['extract']);
      }
      final gate = DrainGate();
      final order = <String>[];
      var asked = false;
      final handler = ScriptedHandler(
        'extract',
        order,
        onRun: (item) {
          if (asked) return;
          asked = true;
          // Exactly what `TriageQueue.pump` does: ask, then enqueue its own
          // run in the same synchronous step, so this run holds the ticket
          // that clears the flag.
          gate.requestYield();
          unawaited(gate.run(() async => order.add('the waiting drain')));
        },
      );
      final worker = AiWorker(store, gate: gate, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      // The item already at the server finished — a yield costs the waiter
      // one item, never a whole pass. Which item that is belongs to the
      // claim's own newest-first order, so it is read by shape.
      expect(order.first, startsWith('extract:'));
      expect(order[1], 'the waiting drain',
          reason: 'the pass ended and the gate went back to the FIFO');
      // And the backlog resumed, on the repump, rather than waiting for the
      // next sync.
      expect(order.length, 4);
      expect(order.where((e) => e.startsWith('extract:')).toSet(),
          {'extract:m1', 'extract:m2', 'extract:m3'});
      for (final id in ['m1', 'm2', 'm3']) {
        expect(await statusOf('extract', id), 'done');
      }
    });

    test('is read at the claim boundary, so the item in flight is kept',
        () async {
      for (final id in ['m1', 'm2']) {
        await seed(id, kinds: const ['extract']);
      }
      final gate = DrainGate();
      final order = <String>[];
      // Two slots, so the second claim of the same launch loop is where the
      // ask is read — and the item already launched is never abandoned.
      final handler = ScriptedHandler(
        'extract',
        order,
        concurrency: 2,
        onRun: (item) {
          if (gate.yieldRequested) return;
          gate.requestYield();
          unawaited(gate.run(() async => order.add('the waiting drain')));
        },
      );
      final worker = AiWorker(store, gate: gate, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      expect(order[1], 'the waiting drain',
          reason: 'the second slot was given up rather than filled');
      expect(order.where((e) => e.startsWith('extract:')).toSet(),
          {'extract:m1', 'extract:m2'});
      expect(await statusOf('extract', 'm1'), 'done');
      expect(await statusOf('extract', 'm2'), 'done');
    });

    test('a parked drain beats a yield: no repump', () async {
      for (final id in ['m1', 'm2', 'm3']) {
        await seed(id, kinds: const ['extract']);
      }
      final gate = DrainGate();
      final order = <String>[];
      final handler = ScriptedHandler(
        'extract',
        order,
        // The session is gone, so every kind behind this one fails the same
        // way and a repump would park on the same dead session again.
        script: [const NotSignedIn()],
        onRun: (item) {
          if (gate.yieldRequested) return;
          gate.requestYield();
          unawaited(gate.run(() async => order.add('the waiting drain')));
        },
      );
      final worker = AiWorker(store, gate: gate, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      expect(order.where((e) => e.startsWith('extract:')).length, 1,
          reason: 'the park returned before any repump could walk again');
      // Put back exactly as it was found: a park processes nothing.
      expect(await statusOf('extract', 'm1'), 'pending');
      expect(await statusOf('extract', 'm2'), 'pending');
      expect(worker.lastDrainCount, 0);
    });
  });

  group('the priority pass', () {
    test('runs a named message through every handler ahead of the backlog',
        () async {
      // A backlog of three, and a fourth message named as urgent. The refs go
      // first, and they go through the handlers in the walk's own order.
      for (final id in ['old1', 'old2', 'old3']) {
        await seed(id);
      }
      await seed('fresh');
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler('needs_you', order),
          ScriptedHandler('extract', order),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'fresh')]);

      expect(order.take(2), ['needs_you:fresh', 'extract:fresh'],
          reason: 'needs-you then extraction, before anybody else');
      expect(order.length, 8);
      for (final id in ['old1', 'old2', 'old3', 'fresh']) {
        expect(await statusOf('needs_you', id), 'done');
        expect(await statusOf('extract', id), 'done');
      }
    });

    test('does not hand the backlog walk an item it already claimed',
        () async {
      await seed('m1');
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler('needs_you', order),
          ScriptedHandler('extract', order),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'm1')]);

      expect(order, ['needs_you:m1', 'extract:m1']);
      expect(worker.lastDrainCount, 2);
    });

    test('a ref for an untriaged message is refused, and taken later',
        () async {
      await seed('m1', triageStatus: 'pending');
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler('needs_you', order),
          ScriptedHandler('extract', order),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'm1')]);

      // The guard is repeated verbatim inside `claimWorkItem`, so the
      // priority lane is not a hole in the ordering invariant.
      expect(order, isEmpty);
      expect(await statusOf('needs_you', 'm1'), 'pending');
      expect(await statusOf('extract', 'm1'), 'pending');

      // The verdict lands, and the ordinary walk takes the rows.
      await store.writeTriage('email', 'm1', status: 'triaged');
      await worker.pump();

      expect(order, ['needs_you:m1', 'extract:m1']);
      expect(await statusOf('needs_you', 'm1'), 'done');
      expect(await statusOf('extract', 'm1'), 'done');
    });

    test('an already-claimed row comes back null rather than twice', () async {
      await seed('m1', kinds: const ['extract']);
      // Someone else is mid-way through it.
      final held = await store.claimPendingWork('extract',
          sources: AiWorker.sources);
      expect(held, isNotNull);

      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'm1')]);

      expect(order, isEmpty);
      expect(await statusOf('extract', 'm1'), 'processing');
    });

    test('a ref for a source this worker does not drain is dropped', () async {
      await seed('m1', source: 'slack', kinds: const ['extract']);
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'slack', id: 'm1')]);

      // Dropped by `pump`, and the backlog walk does not reach it either: the
      // claim is scoped to the worker's own sources.
      expect(order, isEmpty);
      expect(await statusOf('extract', 'm1', source: 'slack'), 'pending');
    });

    test('caps the queue at maxPriorityRefs, and the rest ride the walk',
        () async {
      expect(AiWorker.maxPriorityRefs, 8);
      final ids = [for (var i = 1; i <= 12; i++) 'm$i'];
      for (final id in ids) {
        await seed(id, kinds: const ['extract']);
      }
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
      );
      addTearDown(worker.dispose);

      await worker.pump(
        first: [for (final id in ids) (source: 'email', id: id)],
      );

      // The first eight named refs ran in the order they were named; the last
      // four were dropped from the lane and picked up by the walk, which
      // claims newest first.
      expect(
        order.take(8),
        [for (final id in ids.take(8)) 'extract:$id'],
      );
      expect(order.length, 12);
      for (final id in ids) {
        expect(await statusOf('extract', id), 'done');
      }
    });

    test('a duplicate ref is ignored rather than run twice', () async {
      await seed('m1', kinds: const ['extract']);
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
      );
      addTearDown(worker.dispose);

      await worker.pump(
        first: const [
          (source: 'email', id: 'm1'),
          (source: 'email', id: 'm1'),
        ],
      );

      expect(order, ['extract:m1']);
    });

    test('no yield is read inside the pass', () async {
      // The pass is what the yield exists to let through, so reading one here
      // would starve exactly the message the ask was made for.
      await seed('m1', kinds: const ['extract']);
      await seed('m2', kinds: const ['extract']);
      final gate = DrainGate();
      final order = <String>[];
      final handler = ScriptedHandler(
        'extract',
        order,
        onRun: (item) {
          if (gate.yieldRequested) return;
          gate.requestYield();
          unawaited(gate.run(() async => order.add('the waiting drain')));
        },
      );
      final worker = AiWorker(store, gate: gate, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump(
        first: const [
          (source: 'email', id: 'm1'),
          (source: 'email', id: 'm2'),
        ],
      );
      await pumpEventQueue();

      expect(order.take(2), ['extract:m1', 'extract:m2']);
      expect(order[2], 'the waiting drain');
    });

    test('an off worker keeps its refs for the pump that turns it back on',
        () async {
      await seed('m1', kinds: const ['extract']);
      var on = false;
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
        enabled: () => on,
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'm1')]);
      expect(order, isEmpty);

      on = true;
      await worker.pump();

      expect(order, ['extract:m1']);
    });

    test('honours the handler width across the refs', () async {
      for (final id in ['m1', 'm2', 'm3']) {
        await seed(id, kinds: const ['extract']);
      }
      final order = <String>[];
      final handler = ScriptedHandler('extract', order, concurrency: 2);
      final worker = AiWorker(store, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump(
        first: const [
          (source: 'email', id: 'm1'),
          (source: 'email', id: 'm2'),
          (source: 'email', id: 'm3'),
        ],
      );

      // Two at the server, never three: the pass waits on the in-flight set
      // exactly as the walk's launch loop does.
      expect(handler.maxInFlight, 2);
      expect(order.toSet(), {'extract:m1', 'extract:m2', 'extract:m3'});
      for (final id in ['m1', 'm2', 'm3']) {
        expect(await statusOf('extract', id), 'done');
      }
    });

    test('refs named mid-drain ride the yield repump', () async {
      // The ref is the OLDEST row, so the walk claiming newest first would
      // reach it LAST. Only the priority lane can bring it forward, which is
      // what makes the order below an assertion about the lane.
      await seed('fresh', kinds: const ['extract']);
      for (final id in ['m1', 'm2', 'm3']) {
        await seed(id, kinds: const ['extract']);
      }
      final gate = DrainGate();
      final order = <String>[];
      late AiWorker worker;
      var asked = false;
      final handler = ScriptedHandler(
        'extract',
        order,
        onRun: (item) {
          if (asked) return;
          asked = true;
          // A triage drain finishing beside this one: it asks for the gate,
          // queues its own run, and knocks on the worker's door naming what
          // it just decided. The pump lands MID-DRAIN, so it merges the ref
          // and raises the repump rather than starting a second drain.
          gate.requestYield();
          unawaited(gate.run(() async => order.add('the waiting drain')));
          unawaited(
            worker.pump(first: const [(source: 'email', id: 'fresh')]),
          );
        },
      );
      worker = AiWorker(store, gate: gate, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      expect(order, [
        'extract:m3',
        'the waiting drain',
        'extract:fresh',
        'extract:m2',
        'extract:m1',
      ]);
    });

    test('refs landing mid-kind are served at the next claim, not next pass',
        () async {
      // The shape the box measured: a backlog under way, and a message named
      // while the walk is part way through the FIRST kind. Ten messages, two
      // kinds each. `fresh` is seeded first, so it is the OLDEST row and the
      // walk claiming newest first would reach it last of all.
      await seed('fresh');
      for (var i = 1; i <= 10; i++) {
        await seed('b$i');
      }
      final order = <String>[];
      late AiWorker worker;
      var pumped = false;
      worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler('needs_you', order, onRun: (_) {
            if (pumped) return;
            pumped = true;
            // Triage finished beside this drain and knocks, naming what it
            // just decided. The walk is mid-kind with nine rows to go.
            unawaited(
              worker.pump(first: const [(source: 'email', id: 'fresh')]),
            );
          }),
          ScriptedHandler('extract', order),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      final firstWalked = order.first;
      expect(firstWalked, startsWith('needs_you:'));
      expect(firstWalked, isNot('needs_you:fresh'));
      // Both of the named message's kinds ran at the very next claim
      // boundary, before the walk took its second backlog row.
      expect(order[1], 'needs_you:fresh');
      expect(order[2], 'extract:fresh');
      expect(order[3], startsWith('needs_you:'));

      final secondWalkedNeedsYou = order.indexWhere((e) =>
          e.startsWith('needs_you:') &&
          e != 'needs_you:fresh' &&
          e != firstWalked);
      expect(
        order.indexOf('extract:fresh'),
        lessThan(secondWalkedNeedsYou),
        reason: 'the extraction did not wait behind the needs-you backlog',
      );
      // And the walk carried on with the kind it was part way through.
      expect(order.where((e) => e.startsWith('needs_you:')).length, 11);
      expect(order.where((e) => e.startsWith('extract:')).length, 11);
    });

    test('refs landing during a later kind still run the earlier kind first',
        () async {
      // Same drain, but the message arrives while the walk is on the SECOND
      // kind, with its own needs-you still pending. The pass runs that first,
      // because the order across kinds is an argument and not a preference.
      for (var i = 1; i <= 10; i++) {
        await seed('b$i');
      }
      final order = <String>[];
      late AiWorker worker;
      var arrived = false;
      worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler('needs_you', order),
          ScriptedHandler('extract', order, onRun: (_) async {
            if (arrived) return;
            arrived = true;
            // The message lands now, after the needs-you kind has been walked
            // past entirely.
            await seed('fresh');
            unawaited(
              worker.pump(first: const [(source: 'email', id: 'fresh')]),
            );
          }),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      // Ten needs-you, then the first extraction, then the newcomer's two in
      // handler order, then the extraction backlog resumes.
      expect(order.take(10).every((e) => e.startsWith('needs_you:')), isTrue);
      expect(order[10], startsWith('extract:'));
      expect(order[11], 'needs_you:fresh');
      expect(order[12], 'extract:fresh');
      expect(order[13], startsWith('extract:'));
      expect(order[13], isNot('extract:fresh'));
      expect(await statusOf('needs_you', 'fresh'), 'done');
      expect(await statusOf('extract', 'fresh'), 'done');
    });

    test('a kind parked in the pass is not dialled again by the walk',
        () async {
      for (final id in ['b1', 'b2']) {
        await seed(id, kinds: const ['extract']);
      }
      await seed('p1', kinds: const ['extract']);
      final order = <String>[];
      final worker = AiWorker(
        store,
        handlers: [
          ScriptedHandler(
            'extract',
            order,
            script: [const LlmUnavailableException('off')],
          ),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'p1')]);

      // One dial, not two: the pass reported the kind as parked and the walk
      // skipped it for the rest of the pass.
      expect(order, ['extract:p1']);
      for (final id in ['b1', 'b2', 'p1']) {
        expect(await statusOf('extract', id), 'pending');
      }
      expect(worker.lastDrainCount, 0);
    });

    test('a second serve in one pass skips the kind the first parked',
        () async {
      // Two serves, one pass. The first finds needs-you's server down; the
      // second must not dial it again for a different message over the same
      // seconds.
      await seed('ref1');
      await seed('ref2');
      for (final id in ['b1', 'b2', 'b3']) {
        await seed(id);
      }
      final order = <String>[];
      late AiWorker worker;
      var arrived = false;
      worker = AiWorker(
        store,
        handlers: [
          // Down for the first item, answering for every one after it — so a
          // second dial would be visible rather than silently parking again.
          ScriptedHandler(
            'needs_you',
            order,
            script: [const LlmUnavailableException('off'), null],
          ),
          ScriptedHandler('extract', order, onRun: (_) {
            if (arrived) return;
            arrived = true;
            unawaited(
              worker.pump(first: const [(source: 'email', id: 'ref2')]),
            );
          }),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'ref1')]);
      await pumpEventQueue();

      // The second serve ran the extraction and skipped the parked kind, so
      // ref2's needs-you comes later, on the repump, rather than inside the
      // serve that ran its extraction.
      final secondServe = order.indexOf('extract:ref2');
      expect(secondServe, greaterThan(0));
      expect(
        order.take(secondServe).where((e) => e.startsWith('needs_you:')),
        ['needs_you:ref1'],
        reason: 'one dial at the down server in the whole pass, not two',
      );
      expect(order.indexOf('needs_you:ref2'), greaterThan(secondServe));
    });

    test('a halt mid-pass keeps the refs it had not reached yet', () async {
      // Again the ref is the oldest row, so its place at the front is the
      // only thing that could put it ahead of the backlog on the resume.
      await seed('m1');
      await seed('b1');
      await seed('b2');
      final order = <String>[];
      var on = true;
      var cut = false;
      final worker = AiWorker(
        store,
        handlers: [
          // The switch goes off while the FIRST handler's item is at the
          // server, so the pass never reaches the second handler. Once only:
          // a second cut would halt the resume this test is about.
          ScriptedHandler('needs_you', order, onRun: (_) {
            if (cut) return;
            cut = true;
            on = false;
          }),
          ScriptedHandler('extract', order),
        ],
        enabled: () => on,
      );
      addTearDown(worker.dispose);

      await worker.pump(first: const [(source: 'email', id: 'm1')]);

      expect(order, ['needs_you:m1']);
      expect(await statusOf('extract', 'm1'), 'pending');

      on = true;
      // No `first:` this time: the refs the cut pass put back are what makes
      // the extraction run before anybody else's needs-you.
      await worker.pump();

      expect(order[1], 'extract:m1');
      for (final id in ['m1', 'b1', 'b2']) {
        expect(await statusOf('needs_you', id), 'done');
        expect(await statusOf('extract', id), 'done');
      }
    });
  });

  group('a quiesce and the refs', () {
    test('a pump landing during a quiesce claims nothing', () async {
      await seed('m1', kinds: const ['extract']);
      await seed('m2', kinds: const ['extract']);
      final order = <String>[];
      late AiWorker worker;
      Future<void>? quiesced;
      final handler = ScriptedHandler(
        'extract',
        order,
        onRun: (item) {
          if (quiesced != null) return;
          // Torn down while this item is at the server — the reset that is
          // about to delete these rows — and a pump lands in the same moment
          // naming the other message.
          quiesced = worker.quiesce();
          unawaited(
            worker.pump(first: const [(source: 'email', id: 'm1')]),
          );
        },
      );
      worker = AiWorker(store, handlers: [handler]);
      addTearDown(worker.dispose);

      await worker.pump();
      await quiesced;
      await pumpEventQueue();

      // Only the item already at the server ran. A priority pass opened under
      // a quiesce would be taking fresh claims while `_claimed` was being
      // handed back.
      expect(order, ['extract:m2']);
      expect(await statusOf('extract', 'm1'), 'pending');
    });

    test('a quiesce drops the refs it was holding', () async {
      await seed('ref', kinds: const ['extract']);
      await seed('b1', kinds: const ['extract']);
      await seed('b2', kinds: const ['extract']);
      final order = <String>[];
      var on = false;
      final worker = AiWorker(
        store,
        handlers: [ScriptedHandler('extract', order)],
        enabled: () => on,
      );
      addTearDown(worker.dispose);

      // Off, so the ref is merged and kept rather than run.
      await worker.pump(first: const [(source: 'email', id: 'ref')]);
      expect(order, isEmpty);

      await worker.quiesce();

      on = true;
      await worker.pump();

      // Newest first, the ordinary walk: a ref that survived a reset would
      // name a row the reset was about to delete.
      expect(order, ['extract:b2', 'extract:b1', 'extract:ref']);
    });
  });
}
