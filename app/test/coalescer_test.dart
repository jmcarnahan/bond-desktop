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
}
