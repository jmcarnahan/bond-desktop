import 'dart:async';

import 'package:bond_inbox/utils/coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The progress-driven reload's rate limiter: a quiet window, a max-wait
/// bound, and one run at a time.
///
/// Driven with `testWidgets` + `tester.pump(Duration)`, the house idiom for a
/// timer: the coalescer reads no clock, so the fake one moves it.
void main() {
  const quiet = Duration(milliseconds: 400);
  const maxWait = Duration(seconds: 2);
  const step = Duration(milliseconds: 100);

  testWidgets('one poke runs once, after the quiet window and not before',
      (tester) async {
    var runs = 0;
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async => runs++,
    );

    c.poke();
    await tester.pump(const Duration(milliseconds: 399));
    expect(runs, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(runs, 1);

    // The max-wait timer went with the run: nothing more is owed.
    await tester.pump(maxWait);
    expect(runs, 1);
  });

  testWidgets('two pokes inside the quiet window are one run', (tester) async {
    var runs = 0;
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async => runs++,
    );

    c.poke();
    await tester.pump(step);
    c.poke();
    await tester.pump(const Duration(milliseconds: 399));
    expect(runs, 0, reason: 'the second poke restarted the quiet window');
    await tester.pump(const Duration(milliseconds: 1));
    expect(runs, 1);
    await tester.pump(maxWait);
    expect(runs, 1);
  });

  testWidgets('a steady stream is not starved: a run at the max wait, and the '
      'tail gets its own', (tester) async {
    final runAt = <Duration>[];
    var elapsed = Duration.zero;
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async => runAt.add(elapsed),
    );

    // The fake clock in 100 ms steps, with [elapsed] moved BEFORE each pump
    // so a run that fires inside a step records the step's end.
    Future<void> advance(int steps) async {
      for (var i = 0; i < steps; i++) {
        elapsed += step;
        await tester.pump(step);
      }
    }

    // A poke every 100 ms for three seconds: the quiet window never opens.
    for (var i = 0; i < 30; i++) {
      c.poke();
      await advance(1);
    }
    expect(runAt.first, maxWait,
        reason: 'the first run starts two seconds into the burst');

    // The last poke was at 2.9 s; its run is the quiet window after it.
    await advance(4);
    expect(runAt, [maxWait, const Duration(milliseconds: 3300)]);

    await advance(20);
    expect(runAt.length, 2);
  });

  testWidgets('single-flight: pokes during a run earn exactly one more run, '
      'after it', (tester) async {
    var started = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    final holds = <Completer<void>>[];
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async {
        started++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        final hold = Completer<void>();
        holds.add(hold);
        await hold.future;
        inFlight--;
      },
    );

    c.poke();
    await tester.pump(quiet);
    expect(started, 1);

    // Pokes while the first run is held open, long enough for their own
    // timers to fire.
    for (var i = 0; i < 5; i++) {
      c.poke();
      await tester.pump(step);
    }
    await tester.pump(maxWait);
    expect(started, 1, reason: 'no second run beside the first');

    holds[0].complete();
    await tester.pump();
    expect(started, 1, reason: 'the re-run waits a quiet window');
    await tester.pump(quiet);
    expect(started, 2);
    expect(maxInFlight, 1);

    holds[1].complete();
    await tester.pump();
    await tester.pump(maxWait);
    expect(started, 2, reason: 'one re-run, not one per poke');
  });

  testWidgets('cancel before the timer: no run', (tester) async {
    var runs = 0;
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async => runs++,
    );

    c.poke();
    await tester.pump(step);
    c.cancel();
    await tester.pump(maxWait);
    expect(runs, 0);
  });

  testWidgets('cancel during a run drops its queued re-run', (tester) async {
    var started = 0;
    final hold = Completer<void>();
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async {
        started++;
        await hold.future;
      },
    );

    c.poke();
    await tester.pump(quiet);
    expect(started, 1);
    c.poke();
    await tester.pump(quiet);
    // The re-run is queued now. Cancel, then let the run finish.
    c.cancel();
    hold.complete();
    await tester.pump();
    await tester.pump(maxWait);
    expect(started, 1);
  });

  testWidgets('a run that throws does not wedge it', (tester) async {
    var runs = 0;
    final c = Coalescer(
      quiet: quiet,
      maxWait: maxWait,
      run: () async {
        runs++;
        if (runs == 1) throw StateError('the database is closed');
      },
    );

    c.poke();
    await tester.pump(quiet);
    expect(runs, 1);

    c.poke();
    await tester.pump(quiet);
    expect(runs, 2);
    await tester.pump(maxWait);
  });

  /// The activity tick's thinner: a fixed window that hands on the latest
  /// event it saw, and nothing that outlives its listener.
  group('coalesceLatest', () {
    const window = Duration(milliseconds: 250);

    /// Cancels and lets the cancel land on a frame. Never `await
    /// sub.cancel()` in a `testWidgets` body: the cancel future resolves
    /// outside the fake zone's microtask flush, and the test never reports.
    Future<void> cancel(WidgetTester tester, StreamSubscription<int> sub) async {
      unawaited(sub.cancel());
      await tester.pump();
    }

    testWidgets('three events inside one window are one emission, the last, '
        'at the window\'s end', (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final sub = coalesceLatest(source.stream, window).listen(seen.add);

      source.add(1);
      await tester.pump(const Duration(milliseconds: 100));
      source.add(2);
      await tester.pump(const Duration(milliseconds: 100));
      source.add(3);
      await tester.pump(const Duration(milliseconds: 49));
      expect(seen, isEmpty, reason: 'the window has not closed yet');
      await tester.pump(const Duration(milliseconds: 1));
      expect(seen, [3]);

      await tester.pump(window);
      expect(seen, [3], reason: 'nothing more was owed');
      await cancel(tester, sub);
    });

    testWidgets('events spanning two windows are two emissions',
        (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final sub = coalesceLatest(source.stream, window).listen(seen.add);

      source.add(1);
      await tester.pump(window);
      expect(seen, [1]);
      source.add(2);
      await tester.pump(window);
      expect(seen, [1, 2]);
      await cancel(tester, sub);
    });

    testWidgets('a steady stream still ticks, once per window',
        (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final at = <Duration>[];
      var elapsed = Duration.zero;
      final sub = coalesceLatest(source.stream, window).listen((value) {
        seen.add(value);
        at.add(elapsed);
      });

      // An event every 50 ms for a second: a restarting window would never
      // close under this.
      const step = Duration(milliseconds: 50);
      for (var i = 0; i < 20; i++) {
        source.add(i);
        elapsed += step;
        await tester.pump(step);
      }

      expect(seen, hasLength(4));
      expect(at, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 500),
        Duration(milliseconds: 750),
        Duration(milliseconds: 1000),
      ]);
      // Each emission is the latest event of its window.
      expect(seen, [4, 9, 14, 19]);
      await cancel(tester, sub);
    });

    testWidgets('nothing in is nothing out', (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final sub = coalesceLatest(source.stream, window).listen(seen.add);

      await tester.pump(const Duration(seconds: 1));
      expect(seen, isEmpty);
      await cancel(tester, sub);
    });

    testWidgets('cancelling with an event pending emits nothing and leaves no '
        'timer', (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final sub = coalesceLatest(source.stream, window).listen(seen.add);

      source.add(1);
      await tester.pump(const Duration(milliseconds: 100));
      await cancel(tester, sub);
      await tester.pump(const Duration(milliseconds: 500));

      expect(seen, isEmpty);
      expect(source.hasListener, isFalse);
      // And the test binding's pending-timer check at the end of this test is
      // the proof that the window's timer went with the subscription.
    });

    testWidgets('an error is passed on at once and the stream stays open',
        (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      final errors = <Object>[];
      var done = false;
      final sub = coalesceLatest(source.stream, window).listen(
        seen.add,
        onError: errors.add,
        onDone: () => done = true,
      );

      source.addError(StateError('the database is closed'));
      await tester.pump();
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());

      source.add(5);
      await tester.pump(window);
      expect(seen, [5]);
      expect(done, isFalse);
      await cancel(tester, sub);
    });

    testWidgets('a source that finishes hands on its pending event at once',
        (tester) async {
      final source = StreamController<int>();
      final seen = <int>[];
      coalesceLatest(source.stream, window).listen(seen.add);

      source.add(7);
      await tester.pump(const Duration(milliseconds: 10));
      unawaited(source.close());
      await tester.pump();

      expect(seen, [7], reason: 'emitted on done, not at the window\'s end');
      // And the window's timer went with it: the test binding's pending-timer
      // check at the end of this test fails otherwise.
    });

    // The two `done` claims run on the real event loop rather than the fake
    // clock: a done event chained through two controllers does not reach the
    // listener inside a `testWidgets` frame, and neither claim needs a timer
    // to fire, because the window's timer is cancelled by the done itself.
    test('a source that finishes is done after its pending event', () async {
      final source = StreamController<int>();
      final out = coalesceLatest(source.stream, window).toList();

      source.add(7);
      await source.close();

      expect(await out, [7]);
    });

    test('an empty source is done with nothing emitted', () async {
      expect(
        await coalesceLatest(const Stream<int>.empty(), window).toList(),
        isEmpty,
      );
    });

    testWidgets('a broadcast source works and is let go on cancel',
        (tester) async {
      final source = StreamController<int>.broadcast();
      final seen = <int>[];
      final sub = coalesceLatest(source.stream, window).listen(seen.add);
      await tester.pump();
      expect(source.hasListener, isTrue);

      source.add(1);
      source.add(2);
      await tester.pump(window);
      expect(seen, [2]);

      await cancel(tester, sub);
      expect(source.hasListener, isFalse);
      unawaited(source.close());
    });
  });
}
