import 'dart:async';

import 'package:bond_inbox/services/ai_worker.dart';

/// The stand-in [WorkHandler]s the lane tests are written with.
///
/// One file rather than a sixth private copy. Existing tests keep the fakes
/// they already have — moving them would be churn for nothing, and each of
/// them is pinned to assertions written around it — but nothing NEW needs a
/// seventh `class ScriptedHandler`.

/// Answers from a script, records what it saw, and counts how many of its
/// items are in flight at once.
///
/// "One item in flight, ever" is the worker's central promise for a handler
/// that declares no concurrency, and a fake that only counted calls could not
/// tell a serial drain from a parallel one.
class ScriptedHandler extends WorkHandler {
  @override
  final String kind;

  /// How long one item takes. The whole point of a lane test is that a slow
  /// item in one lane does not delay a fast one in another, and the only way
  /// to say "slow" to a fake is a duration.
  final Duration duration;

  /// Consumed in order. An `Exception` or an `Error` is thrown; anything else
  /// is a success. The last entry repeats once the script runs out.
  final List<Object?> script;

  /// What [concurrency] answers, read on every launch decision — so a test can
  /// move it mid-drain, which is the property a closure-backed width rests on.
  int Function()? width;

  /// Run at the START of each item, before the delay: for assertions about
  /// what is true WHILE an item is being worked on.
  final FutureOr<void> Function(Map<String, Object?> item)? onRun;

  /// Every `entity_id` this handler was given, in the order it got them.
  final List<String> seen = [];

  /// When each item finished, on the clock the test starts. What a lane test
  /// asserts about is ORDER ACROSS lanes, and order is a timestamp.
  final List<Duration> finishedAt = [];

  int inFlight = 0;
  int maxInFlight = 0;

  final Stopwatch _clock = Stopwatch()..start();

  ScriptedHandler(
    this.kind, {
    this.duration = const Duration(milliseconds: 1),
    List<Object?> script = const [null],
    this.width,
    this.onRun,
  }) : script = [...script];

  @override
  int get concurrency => width?.call() ?? 1;

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await onRun?.call(item);
      // A real handler suspends. Without one here two overlapping pumps could
      // interleave in a way this fake would never see.
      await Future<void>.delayed(duration);
      final step = script.length > 1 ? script.removeAt(0) : script.first;
      if (step is Exception) throw step;
      if (step is Error) throw step;
    } finally {
      inFlight--;
      finishedAt.add(_clock.elapsed);
    }
  }
}

/// Holds every item until the test lets it go.
///
/// For the assertions about what a drain does while it is BUSY — a repair
/// issued mid-sweep, a second pump landing on a running drain — where a
/// duration would be a race and a completer is a fact.
class HeldHandler extends WorkHandler {
  @override
  final String kind;

  final List<String> seen = [];

  /// Completes the first time an item enters [run], so a test can await "the
  /// drain has actually started" instead of pumping and hoping.
  final Completer<void> started = Completer<void>();

  final Completer<void> _release = Completer<void>();

  HeldHandler(this.kind);

  /// Lets every held item finish.
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    if (!started.isCompleted) started.complete();
    await _release.future;
  }
}
