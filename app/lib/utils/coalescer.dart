import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// Turns a stream of "something changed" pokes into as few runs of one job as
/// still keeps up with them: one run after the pokes go quiet, one at a time.
///
/// Two bounds, because either alone is wrong. A restarting debounce alone
/// never fires under a steady stream: the drains report an item every few
/// hundred milliseconds for minutes on end, and a quiet window that every
/// report restarts holds the job back until the whole backlog is through. A
/// fixed window alone runs too eagerly for a burst of two: two reports a
/// moment apart would each start a run. So a run starts [quiet] after the
/// last poke, or [maxWait] after the first poke of the burst, whichever comes
/// first.
///
/// Single-flight on top of that: a run that is due while the previous one is
/// still going is not started beside it. It is remembered, and once the run
/// in flight finishes the pokes that arrived meanwhile get one more run,
/// after a quiet window of their own. The price of that is that a run which
/// never completes holds back every run after it; the job here is a database
/// read, which completes or throws.
///
/// Clock-free on purpose: two [Timer]s and no stopwatch or wall clock, so a
/// test drives it with `tester.pump(Duration)` like every other timer here.
class Coalescer {
  Coalescer({
    required this.quiet,
    required this.maxWait,
    required this._run,
  });

  /// How long the pokes must go quiet before a run starts.
  final Duration quiet;

  /// How long after the first poke of a burst a run starts however busy the
  /// burst still is.
  final Duration maxWait;

  /// The job. Called as `run:`.
  final Future<void> Function() _run;

  /// Restarted by every poke.
  Timer? _quietTimer;

  /// Started by the first poke of a burst and NOT restarted by later ones —
  /// that is the whole of the max-wait bound.
  Timer? _maxWaitTimer;

  bool _running = false;

  /// A run came due while another was in flight.
  bool _again = false;

  /// Asks for a run. It starts [quiet] after the last poke, or [maxWait]
  /// after the first poke of this burst, whichever comes first; a poke while
  /// a run is in flight earns exactly one more run after it.
  void poke() {
    _quietTimer?.cancel();
    _quietTimer = Timer(quiet, _fire);
    _maxWaitTimer ??= Timer(maxWait, _fire);
  }

  /// Drops a pending run and a queued re-run. A run already in flight
  /// finishes. A later poke starts afresh.
  void cancel() {
    _quietTimer?.cancel();
    _quietTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
    _again = false;
  }

  Future<void> _fire() async {
    _quietTimer?.cancel();
    _quietTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      await _run();
    } catch (e) {
      // A run that throws must not wedge the coalescer in flight or leak an
      // unhandled error into the timer's zone; the next poke runs again.
      debugPrint('coalesced run failed: $e');
    } finally {
      _running = false;
    }
    if (_again) {
      _again = false;
      poke();
    }
  }
}
