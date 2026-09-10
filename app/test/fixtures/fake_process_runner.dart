import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/server/process_runner.dart';

/// One recorded call to [FakeProcessRunner.start].
class FakeStart {
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;

  const FakeStart({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
  });

  @override
  String toString() => 'FakeStart($executable ${arguments.join(' ')} '
      'in $workingDirectory)';
}

/// The operating system, scripted.
///
/// Every interesting thing the supervisor does is a reaction to something
/// only the OS can do: a port already held, a child that ignores SIGTERM, a
/// pid that outlived its parent, a server that exits three seconds after it
/// started listening. None of those can be provoked on demand against a real
/// process, so they are provoked here instead.
class FakeProcessRunner implements ProcessRunner {
  /// Every call to [start], in order.
  final List<FakeStart> starts = [];

  /// What each [start] hands back. Set by the test; the default is a process
  /// that says nothing and never exits.
  FakeRunningProcess Function(FakeStart start)? onStart;

  /// Every process this runner has handed out, for a test that wants to make
  /// one of them talk after the fact.
  final List<FakeRunningProcess> processes = [];

  final Map<int, bool> alive = {};
  final Map<int, String?> commandLines = {};
  final Set<int> busyPorts = {};
  final Map<int, String?> listeners = {};

  int nextFreePort = 45000;
  int nextPid = 4242;

  /// Every signal sent, whether through [kill] or through a handle's own
  /// `kill` — so a test can assert the TERM-then-KILL escalation in one list.
  final List<(int pid, ProcessSignal signal)> kills = [];

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final record = FakeStart(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      environment: Map.unmodifiable(environment),
    );
    starts.add(record);
    final process = (onStart ?? _default)(record);
    process.onKill = (pid, signal) => kills.add((pid, signal));
    processes.add(process);
    alive[process.pid] = true;
    return process;
  }

  FakeRunningProcess _default(FakeStart start) =>
      FakeRunningProcess(pid: nextPid++);

  @override
  Future<bool> isAlive(int pid) async => alive[pid] ?? false;

  @override
  Future<String?> commandLineOf(int pid) async => commandLines[pid];

  @override
  Future<bool> isPortFree(int port) async => !busyPorts.contains(port);

  @override
  Future<int> freePort() async => nextFreePort;

  @override
  Future<String?> listenerOn(int port) async => listeners[port];

  @override
  bool kill(int pid, ProcessSignal signal) {
    kills.add((pid, signal));
    for (final process in processes) {
      if (process.pid == pid) process.deliver(signal);
    }
    if (signal != ProcessSignal.sigterm ||
        !processes.any((p) => p.pid == pid && p.ignoreTerm)) {
      alive[pid] = false;
    }
    return true;
  }
}

/// A child process that never was.
class FakeRunningProcess implements RunningProcess {
  FakeRunningProcess({required this.pid, this.ignoreTerm = false});

  @override
  final int pid;

  /// A child that will not die politely — what forces the SIGKILL rung.
  final bool ignoreTerm;

  final StreamController<List<int>> stdoutCtl = StreamController<List<int>>();
  final StreamController<List<int>> stderrCtl = StreamController<List<int>>();
  final Completer<int> exit = Completer<int>();

  /// Every signal this process was sent, in order.
  final List<ProcessSignal> signals = [];

  /// Set by [FakeProcessRunner] so both kill paths land in one list.
  void Function(int pid, ProcessSignal signal)? onKill;

  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;

  @override
  Stream<List<int>> get stderr => stderrCtl.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    onKill?.call(pid, signal);
    deliver(signal);
    return true;
  }

  /// Applies a signal without recording it as a caller's kill — how
  /// [FakeProcessRunner.kill] reaches a process it only knows by pid.
  void deliver(ProcessSignal signal) {
    signals.add(signal);
    if (signal == ProcessSignal.sigterm && ignoreTerm) return;
    finish(signal == ProcessSignal.sigkill ? -9 : -15);
  }

  /// One line on stdout, with the newline the [LineSplitter] wants.
  void emit(String line) {
    if (stdoutCtl.isClosed) return;
    stdoutCtl.add(utf8.encode('$line\n'));
  }

  void emitErr(String line) {
    if (stderrCtl.isClosed) return;
    stderrCtl.add(utf8.encode('$line\n'));
  }

  void finish(int code) {
    if (!exit.isCompleted) exit.complete(code);
  }

  Future<void> dispose() async {
    if (!stdoutCtl.isClosed) await stdoutCtl.close();
    if (!stderrCtl.isClosed) await stderrCtl.close();
    finish(0);
  }
}
