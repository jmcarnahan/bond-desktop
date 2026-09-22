import 'dart:async';

import 'package:bond_inbox/services/drain_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DrainGate FIFO', () {
    test('runs bodies in enqueue order and survives an error', () async {
      final gate = DrainGate();
      final order = <String>[];

      final first = gate.run(() async {
        order.add('first');
        throw StateError('the first drain blew up');
      });
      final second = gate.run(() async => order.add('second'));

      await expectLater(first, throwsStateError);
      await second;

      expect(order, ['first', 'second']);
    });
  });

  group('DrainGate yield', () {
    test('is false when nothing has asked', () async {
      final gate = DrainGate();

      expect(gate.yieldRequested, isFalse);

      await gate.run(() async {});

      expect(gate.yieldRequested, isFalse);
    });

    test('a run queued BEFORE the ask does not clear it', () async {
      final gate = DrainGate();
      final release = Completer<void>();
      final seen = <bool>[];

      // Queued first, so its ticket is 0 and the ask below is 1.
      final running = gate.run(() async {
        await release.future;
        seen.add(gate.yieldRequested);
      });

      gate.requestYield();
      expect(gate.yieldRequested, isTrue);

      release.complete();
      await running;

      // The earlier run neither saw the flag down nor cleared it on the way
      // out: the ask is still standing for whoever comes next.
      expect(seen, [true]);
      expect(gate.yieldRequested, isTrue);
    });

    test('the run queued after the ask clears it, at body start', () async {
      final gate = DrainGate();
      final release = Completer<void>();
      var startedWith = true;

      final holding = gate.run(() => release.future);

      gate.requestYield();
      final asker = gate.run(() async {
        startedWith = gate.yieldRequested;
      });

      // Still standing while the earlier run holds the gate: the clearing run
      // has not started its body.
      expect(gate.yieldRequested, isTrue);

      release.complete();
      await holding;
      await asker;

      expect(startedWith, isFalse, reason: 'cleared before the body ran');
      expect(gate.yieldRequested, isFalse);
    });

    test('two asks with no run between them are one ask', () async {
      final gate = DrainGate();

      gate.requestYield();
      gate.requestYield();
      expect(gate.yieldRequested, isTrue);

      await gate.run(() async {});

      expect(gate.yieldRequested, isFalse);
    });

    test('an ask with no run of its own is cleared by the next run of anybody',
        () async {
      final gate = DrainGate();

      gate.requestYield();
      expect(gate.yieldRequested, isTrue);

      // Nobody enqueued a drain for this ask. The next run, whoever it
      // belongs to, is at or after it and takes the flag down, so the worker
      // cannot be left yielding forever.
      await gate.run(() async {});

      expect(gate.yieldRequested, isFalse);
    });

    test('an ask made while the asker is already queued still clears',
        () async {
      final gate = DrainGate();
      final release = Completer<void>();
      final saw = <bool>[];

      final holding = gate.run(() async {
        await release.future;
        saw.add(gate.yieldRequested);
      });

      // The real shape of the pump: ask and enqueue in one synchronous step.
      gate.requestYield();
      final asker = gate.run(() async => saw.add(gate.yieldRequested));

      release.complete();
      await holding;
      await asker;

      expect(saw, [true, false]);
      expect(gate.yieldRequested, isFalse);
    });
  });
}
