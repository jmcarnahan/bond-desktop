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

/// A heartbeat on the UI isolate that says how long that isolate was blocked.
///
/// A periodic timer's callback runs on the event loop of the isolate that made
/// it, so when the UI isolate is busy — stepping a statement, laying out a long
/// list, decoding a body — the tick cannot run until it is free again. How
/// late the tick fires, past its [interval] since the tick before it, is how
/// long the isolate was blocked, to within the lateness that earlier tick
/// already carried. A lateness of at least [threshold] is logged as
/// `ui-stall <ms>ms`,
/// and every [summaryEvery] a summary line counts the window's stalls, its
/// worst and their total — printed even when the count is zero, so a quiet
/// minute is visible rather than indistinguishable from a monitor that never
/// started.
class UiStallMonitor {
  UiStallMonitor({
    this.interval = const Duration(milliseconds: 50),
    this.threshold = const Duration(milliseconds: 100),
    this.summaryEvery = const Duration(seconds: 60),
    int Function()? nowMicros,
    void Function(String line)? log,
  })  : _nowMicros = nowMicros ?? _stopwatchMicros(),
        _log = log ?? debugPrint;

  /// How often the heartbeat is asked to tick.
  final Duration interval;

  /// The least lateness worth a line of its own.
  final Duration threshold;

  /// How long each summary window lasts.
  final Duration summaryEvery;

  final int Function() _nowMicros;
  final void Function(String line) _log;

  Timer? _timer;
  int _previousTick = 0;
  int _windowStart = 0;
  int _count = 0;
  int _maxMs = 0;
  int _totalMs = 0;

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

  void _tick() {
    final now = _nowMicros();
    var lateMicros = (now - _previousTick) - interval.inMicroseconds;
    if (lateMicros < 0) lateMicros = 0;
    final lateness = Duration(microseconds: lateMicros);
    if (lateness >= threshold) {
      final ms = lateness.inMilliseconds;
      _log('ui-stall ${ms}ms');
      _count += 1;
      if (ms > _maxMs) _maxMs = ms;
      _totalMs += ms;
    }
    _previousTick = now;
    if (now - _windowStart >= summaryEvery.inMicroseconds) {
      _log('ui-stalls ${summaryEvery.inSeconds}s: '
          'n=$_count max=${_maxMs}ms total=${_totalMs}ms');
      _resetWindow();
      _windowStart = now;
    }
  }

  void _resetWindow() {
    _count = 0;
    _maxMs = 0;
    _totalMs = 0;
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
