import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// `--dart-define=BOND_PERF_LOG` (Makefile: `BOND_PERF_LOG=1`) turns on the
/// app's own measurement: the UI-stall heartbeat and the slow-statement log,
/// both printed to the run's console.
///
/// The BUILD decides, not a preference, because this is a developer's
/// instrument for one run and never something a user is shown. Off by
/// default, so a shipped build carries neither the timer nor the interceptor.
/// See `docs/performance.md` for how to read the lines.
const String perfLogDefine = String.fromEnvironment('BOND_PERF_LOG');

/// Whether this build prints the perf lines.
///
/// Any value but the three ways a build script says no turns it on, exactly as
/// `handServersBuild` reads its own define — somebody who wrote `=0` to turn
/// it back off gets no log rather than the opposite of what they typed.
/// `length > 0` rather than `isNotEmpty` because a constant expression may
/// read a string's length and may not call a getter on it.
const bool perfLogOn = perfLogDefine.length > 0 &&
    perfLogDefine != '0' &&
    perfLogDefine != 'false' &&
    perfLogDefine != 'no';

/// The monotonic clock both classes here read when no test hands one in: a
/// stopwatch started when the instance is made, read in microseconds.
int Function() _stopwatchMicros() {
  final watch = Stopwatch()..start();
  return () => watch.elapsedMicroseconds;
}

/// What a [UiStallMonitor] saw over one window.
///
/// Two bands, because they are two different complaints: a [janks] count is
/// frames visibly dropped (a heartbeat late by two frames or more), and a
/// [stalls] count is the app not answering (late by a tenth of a second or
/// more). [blockedMs] adds up every lateness of at least a jank, which is the
/// one number that says how much of the window the isolate was not there for.
class UiStallSummary {
  const UiStallSummary({
    required this.ticks,
    required this.janks,
    required this.stalls,
    required this.maxMs,
    required this.blockedMs,
  });

  /// Heartbeats that fired in the window. Zero means the monitor never ran.
  final int ticks;

  /// Heartbeats late by at least [UiStallMonitor.jank].
  final int janks;

  /// Heartbeats late by at least [UiStallMonitor.threshold].
  final int stalls;

  /// The worst lateness in the window, in milliseconds.
  final int maxMs;

  /// The sum of every lateness of at least a jank, in milliseconds.
  final int blockedMs;
}

/// A heartbeat on the UI isolate that says how long that isolate was blocked.
///
/// A periodic timer's callback runs on the event loop of the isolate that made
/// it, so when the UI isolate is busy — stepping a statement, laying out a long
/// list, decoding a body — the tick cannot run until it is free again. How
/// late the tick fires, past its [interval], is how long the isolate was
/// blocked, to within one interval: the timer keeps to a fixed grid, so a
/// block that begins part-way between two ticks is read short by however much
/// of that gap had already passed. That is why the interval is ten
/// milliseconds and not fifty. At fifty a hundred-millisecond freeze read as
/// anything from 54 to 99 and never reached a hundred-millisecond line; at
/// ten the reading is at most ten short.
///
/// A lateness of at least [threshold] is logged as `ui-stall <ms>ms`, and
/// every [summaryEvery] a summary line gives the window's two counts, its
/// worst and its total — printed even when everything is zero, so a quiet
/// minute is visible rather than indistinguishable from a monitor that never
/// started.
class UiStallMonitor {
  UiStallMonitor({
    this.interval = const Duration(milliseconds: 10),
    this.jank = const Duration(milliseconds: 33),
    this.threshold = const Duration(milliseconds: 100),
    this.summaryEvery = const Duration(seconds: 60),
    int Function()? nowMicros,
    void Function(String line)? log,
  })  : _nowMicros = nowMicros ?? _stopwatchMicros(),
        _log = log ?? debugPrint;

  /// How often the heartbeat is asked to tick, and so the most a reading can
  /// fall short of the block it measures.
  final Duration interval;

  /// The least lateness counted as a jank: two frames at sixty a second, the
  /// first a person can see.
  final Duration jank;

  /// The least lateness worth a line of its own, and counted as a stall.
  final Duration threshold;

  /// How long each summary window lasts.
  final Duration summaryEvery;

  final int Function() _nowMicros;
  final void Function(String line) _log;

  Timer? _timer;
  int _previousTick = 0;
  int _windowStart = 0;
  int _ticks = 0;
  int _janks = 0;
  int _stalls = 0;
  int _maxMs = 0;
  int _blockedMs = 0;

  /// Starts the heartbeat. A second call while it runs does nothing, so two
  /// callers cannot double the ticks and halve every reading.
  void start() {
    if (_timer != null) return;
    final now = _nowMicros();
    _previousTick = now;
    _windowStart = now;
    _resetWindow();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// Stops the heartbeat. Safe to call when it never started.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The window so far, and a new window from now.
  ///
  /// What a caller that measures one piece of work reads when the work is
  /// done; the once-a-[summaryEvery] line is this, printed.
  UiStallSummary take() {
    final summary = UiStallSummary(
      ticks: _ticks,
      janks: _janks,
      stalls: _stalls,
      maxMs: _maxMs,
      blockedMs: _blockedMs,
    );
    _resetWindow();
    _windowStart = _nowMicros();
    return summary;
  }

  void _tick() {
    final now = _nowMicros();
    var lateMicros = (now - _previousTick) - interval.inMicroseconds;
    if (lateMicros < 0) lateMicros = 0;
    final lateness = Duration(microseconds: lateMicros);
    final ms = lateness.inMilliseconds;
    _ticks += 1;
    if (ms > _maxMs) _maxMs = ms;
    if (lateness >= jank) {
      _janks += 1;
      _blockedMs += ms;
    }
    if (lateness >= threshold) {
      _stalls += 1;
      _log('ui-stall ${ms}ms');
    }
    _previousTick = now;
    if (now - _windowStart >= summaryEvery.inMicroseconds) {
      final window = take();
      _log('ui-stalls ${summaryEvery.inSeconds}s: '
          'janks=${window.janks} stalls=${window.stalls} '
          'max=${window.maxMs}ms blocked=${window.blockedMs}ms');
    }
  }

  void _resetWindow() {
    _ticks = 0;
    _janks = 0;
    _stalls = 0;
    _maxMs = 0;
    _blockedMs = 0;
  }
}

/// The SQL a perf line shows: every whitespace run collapsed to one space,
/// trimmed, and cut to its first 120 characters.
///
/// The statements in this app are written across many indented lines, and a
/// log line is read one per row; 120 characters is enough to say which
/// statement it was.
String perfSqlLabel(String sql) {
  final flat = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 120 ? flat : flat.substring(0, 120);
}

/// Logs statements that took at least [threshold], as the UI isolate saw them
/// (queue wait + isolate hop + execution).
///
/// It wraps the executor on the UI side, so the time it measures is what a
/// caller waited for, not what SQLite spent: a quick read queued behind a long
/// write shows up here as slow, and that is the point — it is the wait the
/// screen felt. Each line is `db-slow <ms>ms <kind> <sql>`.
///
/// Three kinds carry no SQL because drift issues them itself: `open` (the
/// first open with its migration, and every transaction's BEGIN — which is
/// where a transaction waits its turn behind another one on the single
/// connection), `commit` and `rollback`. Leaving them untimed would hide
/// exactly the wait a long write causes.
///
/// The SQL text only, NEVER the arguments: every statement is parameterised
/// and the arguments are the user's mail.
class SlowStatementLog extends QueryInterceptor {
  SlowStatementLog({
    this.threshold = const Duration(milliseconds: 50),
    int Function()? nowMicros,
    void Function(String line)? log,
  })  : _nowMicros = nowMicros ?? _stopwatchMicros(),
        _log = log ?? debugPrint;

  /// The least elapsed time worth a line.
  final Duration threshold;

  final int Function() _nowMicros;
  final void Function(String line) _log;

  /// Times [run] — in a `finally`, so a statement that throws is still timed —
  /// and logs it when it took at least [threshold]. [label] is only built
  /// when a line is written.
  Future<T> _timed<T>(
    String kind,
    String Function() label,
    Future<T> Function() run,
  ) async {
    final start = _nowMicros();
    try {
      return await run();
    } finally {
      final elapsed = Duration(microseconds: _nowMicros() - start);
      if (elapsed >= threshold) {
        _log('db-slow ${elapsed.inMilliseconds}ms $kind ${label()}');
      }
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      _timed('open', () => '-', () => executor.ensureOpen(user));

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _timed('commit', () => '-', () => inner.send());

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _timed('rollback', () => '-', () => inner.rollback());

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _timed(
        'select',
        () => perfSqlLabel(statement),
        () => executor.runSelect(statement, args),
      );

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _timed(
        'insert',
        () => perfSqlLabel(statement),
        () => executor.runInsert(statement, args),
      );

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _timed(
        'update',
        () => perfSqlLabel(statement),
        () => executor.runUpdate(statement, args),
      );

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _timed(
        'delete',
        () => perfSqlLabel(statement),
        () => executor.runDelete(statement, args),
      );

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _timed(
        'custom',
        () => perfSqlLabel(statement),
        () => executor.runCustom(statement, args),
      );

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) =>
      _timed(
        'batch',
        () {
          final sql = statements.statements;
          final first = sql.isEmpty ? '' : perfSqlLabel(sql.first);
          return '${sql.length} statements: $first';
        },
        () => executor.runBatched(statements),
      );
}
