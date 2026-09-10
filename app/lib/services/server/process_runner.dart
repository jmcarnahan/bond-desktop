import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// A child process the supervisor is holding.
///
/// The subset of `dart:io`'s [Process] this app actually uses, named as an
/// interface so a test can script a crash, a hung SIGTERM or a line of log
/// output without spawning anything. Nothing below is a convenience wrapper:
/// every member is one the supervisor calls.
abstract interface class RunningProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

/// Everything the supervisor needs from the operating system.
///
/// The seam exists because the supervisor's interesting behaviour is all in
/// the failures — a port already held, a pid that outlived its parent, a
/// child that ignores SIGTERM — and none of those can be provoked reliably
/// against a real process. Ports and processes are both in here rather than
/// split across two interfaces because they answer one question together:
/// whether this machine can host the server right now.
abstract interface class ProcessRunner {
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  });

  /// Whether [pid] is a live process — `kill -0` semantics.
  Future<bool> isAlive(int pid);

  /// The command line [pid] was started with, or null when it is gone.
  Future<String?> commandLineOf(int pid);

  /// Whether 127.0.0.1:[port] can be bound right now.
  Future<bool> isPortFree(int port);

  /// A port the kernel says is free at this instant.
  Future<int> freePort();

  /// What is listening on [port], as `'<COMMAND> (pid <PID>)'`, or null.
  Future<String?> listenerOn(int port);

  bool kill(int pid, ProcessSignal signal);
}

/// The real one.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  /// [ProcessStartMode.normal], never [ProcessStartMode.detached].
  ///
  /// A detached child has no exit code to await and no pipes to read, which
  /// costs both halves of supervision: the app could not tell a crash from a
  /// slow load, and the log would be empty exactly when it is wanted. The
  /// child outliving a dead parent is handled by killing it deliberately —
  /// from Dart on exit, from `applicationWillTerminate` in the Runner, and by
  /// reaping the pid file on the next launch — not by never holding it.
  ///
  /// `runInShell: false` because there is no shell syntax in the argv and a
  /// shell in between would give us the shell's pid, not the server's.
  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    return _SystemRunningProcess(process);
  }

  /// Signal 0 through `kill(1)`: it delivers nothing and reports whether the
  /// process exists and is ours. `Process.killPid` cannot express it — its
  /// signal enum has no zero — so this shells out.
  ///
  // Windows (Phase 7): no `kill`; ask `tasklist /FI "PID eq <pid>"` instead.
  @override
  Future<bool> isAlive(int pid) async {
    try {
      final result = await Process.run('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('server: kill -0 $pid failed: $e');
      return false;
    }
  }

  /// The full argv of [pid], which is how a pid file is checked for
  /// plausibility before anything is killed: a pid is reused within hours on
  /// a busy machine, and the number alone is not evidence.
  ///
  // Windows (Phase 7): `wmic process where processid=<pid> get commandline`,
  // or the CIM equivalent on newer builds.
  @override
  Future<String?> commandLineOf(int pid) async {
    try {
      final result = await Process.run('ps', ['-o', 'command=', '-p', '$pid']);
      if (result.exitCode != 0) return null;
      final line = (result.stdout as String).trim();
      return line.isEmpty ? null : line;
    } catch (e) {
      debugPrint('server: ps -p $pid failed: $e');
      return null;
    }
  }

  /// Asked by binding it, not by reading a table: the only answer that
  /// matters is whether THIS process can have the socket, and a table can be
  /// stale by the time the child gets there.
  @override
  Future<bool> isPortFree(int port) async {
    try {
      final socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  @override
  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Who holds a port, for the one error message the user can act on.
  ///
  /// Best effort by design: `lsof` may be missing, slow or refused, and the
  /// state it feeds is already correct without it — the holder is the extra
  /// half-sentence, never the finding.
  ///
  // Windows (Phase 7): `netstat -ano -p TCP` filtered to LISTENING, then the
  // pid through `tasklist` for the image name.
  @override
  Future<String?> listenerOn(int port) async {
    try {
      final result = await Process.run(
        'lsof',
        ['-nP', '-iTCP:$port', '-sTCP:LISTEN'],
      );
      final lines = (result.stdout as String)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      // The first line is lsof's header; the first data row is the answer.
      if (lines.length < 2) return null;
      final fields =
          lines[1].split(RegExp(r'\s+')).where((f) => f.isNotEmpty).toList();
      if (fields.length < 2) return null;
      return '${fields[0]} (pid ${fields[1]})';
    } catch (e) {
      debugPrint('server: lsof on $port failed: $e');
      return null;
    }
  }

  /// Signals a process this app may no longer hold a handle to — the pid
  /// read out of the pid file after a relaunch.
  ///
  // Windows (Phase 7): `taskkill /PID <pid>` and `/PID <pid> /F` for the
  // two rungs; there are no POSIX signals to send.
  @override
  bool kill(int pid, ProcessSignal signal) {
    try {
      return Process.killPid(pid, signal);
    } catch (e) {
      debugPrint('server: kill $signal $pid failed: $e');
      return false;
    }
  }
}

/// [Process] behind the [RunningProcess] interface. No behaviour of its own.
class _SystemRunningProcess implements RunningProcess {
  _SystemRunningProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}
