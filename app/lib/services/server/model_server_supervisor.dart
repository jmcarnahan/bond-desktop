import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'llama_binary.dart';
import 'process_runner.dart';
import 'router_preset.dart';
import 'server_log.dart';
import 'server_state.dart';

/// The app's own llama-server: started, watched, restarted and killed.
///
/// ONE server in router mode rather than the three hand-started processes the
/// old workflow needed. That is the whole reason this class exists: a person
/// who has just installed the app cannot be asked to run three commands in
/// three terminals, and a person who has can still turn this off and keep
/// doing it — which is what the `managed` callback decides.
///
/// Everything it needs from the world is injected. Processes, ports and
/// signals come through [ProcessRunner]; the clock comes through the four
/// durations; HTTP comes through an [http.Client]. That is not test
/// decoration: the behaviour worth pinning here is all in the failures — a
/// port already held, a child that ignores SIGTERM, a server that answers
/// `/health` for a minute and then stops — and none of those can be provoked
/// on demand against a real one.
///
/// NO PUBLIC METHOD THROWS. Every failure becomes a [ServerState], because
/// the caller is a provider feeding a status line and there is no useful
/// place above this class for an exception to be caught.
class ModelServerSupervisor {
  ModelServerSupervisor({
    required this.runner,
    required this.supportDir,
    required this.binaryPath,
    required this.buildPreset,
    required this.routerPort,
    required this.managed,
    http.Client? httpClient,
    this.onReady,
    this.beginActivity,
    this.endActivity,
    this.healthInterval = const Duration(seconds: 2),
    this.terminateGrace = const Duration(seconds: 2),
    this.startTimeout = const Duration(seconds: 30),
    this.restartBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 4),
      Duration(seconds: 16),
    ],
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  final ProcessRunner runner;

  /// The unsandboxed application support directory — everything this class
  /// writes is under it.
  final Directory supportDir;

  /// Where `llama-server` is, asked freshly each start so a developer can
  /// change `BOND_LLAMA_SERVER` without relaunching the supervisor.
  final String? Function() binaryPath;

  /// The preset to serve, asked freshly each start for the same reason and
  /// one more: it is what an adopted server's recorded hash is compared
  /// against.
  final RouterPreset Function() buildPreset;

  final int Function() routerPort;

  /// Whether the app owns the servers at all. A callback rather than a flag
  /// so the preference can change under a live supervisor.
  final bool Function() managed;

  /// Called once each time the server reaches ready — which is where the
  /// clients get re-pointed at the port that was actually bound.
  final void Function()? onReady;

  /// `NSProcessInfo` activity, so App Nap cannot suspend the app while a
  /// twenty-seven-billion-parameter model is being mapped. Optional because
  /// nothing about supervision depends on it.
  final Future<int?> Function(String reason)? beginActivity;
  final Future<void> Function(int token)? endActivity;

  final Duration healthInterval;
  final Duration terminateGrace;

  /// From spawn to the `listening on` line. Generous, because it covers a
  /// cold `mmap` of several gigabytes off a slow disk.
  final Duration startTimeout;

  /// How long to wait before each restart, and — by its length — how many
  /// restarts there are before the app stops trying and says so.
  final List<Duration> restartBackoff;

  final http.Client _http;
  final bool _ownsHttp;

  /// The line llama-server prints once the socket is bound, on stdout or
  /// stderr depending on the build. The PORT IS PARSED OUT OF IT rather than
  /// assumed: this is the only statement of where the server actually is.
  static final RegExp _listening =
      RegExp(r'listening on http://127\.0\.0\.1:(\d+)');

  ServerState _state = const ServerStopped();
  final StreamController<ServerState> _changes =
      StreamController<ServerState>.broadcast();

  /// Bumped on every launch, stop, crash and adoption.
  ///
  /// A process exit arrives as a `Future` that cannot be cancelled, and a
  /// health poll is in flight across an await. Both check this number before
  /// acting, so a callback belonging to a server that has already been
  /// replaced is dropped instead of reporting a crash the user would see as
  /// their fresh server dying on arrival.
  int _generation = 0;

  RouterPreset? _preset;
  RunningProcess? _process;
  int? _pid;
  int? _port;
  ServerLog? _log;

  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  Timer? _startTimer;
  Timer? _healthTimer;
  Timer? _restartTimer;

  /// This launch's output, and only this launch's.
  ///
  /// Separate from [ServerLog]'s ring, which spans the session because the log
  /// is opened once and never reopened. A `couldn't bind` line from the first
  /// attempt is still in that ring while the second attempt is running, and
  /// reading it there would report the second attempt's unrelated crash as a
  /// port problem. What a crash needs to know is what THIS child said, so this
  /// list is cleared at the top of every launch.
  final List<String> _recent = [];

  /// How many of those lines are kept — the same order of magnitude as the
  /// log's own tail, and far more than the handful a bind failure prints.
  static const int _recentMax = 200;

  bool _listeningSeen = false;
  bool _stopping = false;
  bool _disposed = false;
  bool _polling = false;
  bool _readyCalled = false;
  int _restarts = 0;
  int _healthFailures = 0;
  int? _activityToken;

  ServerState get state => _state;

  /// The current state, then every change.
  ///
  /// Built by hand rather than with `async*` on purpose: a generator yields
  /// its first value and only then subscribes to the underlying broadcast
  /// stream, and a change emitted in that microtask gap is lost. Here the
  /// current state is pushed and the subscription taken inside one
  /// `onListen`, with nothing between them.
  Stream<ServerState> get states {
    late StreamController<ServerState> out;
    StreamSubscription<ServerState>? sub;
    out = StreamController<ServerState>(
      onListen: () {
        out.add(_state);
        sub = _changes.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  File get logFile => File(p.join(supportDir.path, 'logs', 'llama-server.log'));

  /// What the next launch reaps, and what the Runner's terminate handler
  /// reads. JSON rather than a bare pid because a pid alone is not evidence:
  /// numbers are reused, and the port, the preset hash and the binary path
  /// are what make "this is ours" checkable.
  File get pidFile => File(p.join(supportDir.path, 'servers', 'router.json'));

  File get presetFile => File(p.join(supportDir.path, 'servers', 'router.ini'));

  /// An empty directory handed to the child as `LLAMA_CACHE`.
  ///
  /// Not a cache and never filled. `--no-models-autoload` stops the router
  /// LOADING models it was not asked for, but it still LISTS everything in
  /// the Hugging Face cache — so a developer with a dozen GGUFs downloaded
  /// would see a dozen entries in `/models` and the readiness check would
  /// wait forever for models this app never asked for. Pointing the child at
  /// an empty directory makes the listing exactly the preset.
  Directory get emptyCacheDir =>
      Directory(p.join(supportDir.path, 'servers', 'empty-cache'));

  /// The entry point on launch: adopt the server this app left running, or
  /// start a new one.
  Future<void> ensureRunning() async {
    if (!managed()) {
      _emit(const ServerDisabled());
      return;
    }
    if (_state is ServerStarting ||
        _state is ServerLoading ||
        _state is ServerReady) {
      return;
    }
    if (await _adopt()) return;
    await start();
  }

  Future<void> start() async {
    // Asked here as well as in [ensureRunning], because the only thing keeping
    // an unmanaged app from spawning a server today is a disabled control on
    // the settings card. A second caller — a retry button, a first-run step —
    // would make that a bug rather than a near miss.
    if (!managed()) {
      _emit(const ServerDisabled());
      return;
    }
    if (_state is ServerStarting ||
        _state is ServerLoading ||
        _state is ServerReady) {
      return;
    }
    _restarts = 0;
    await _launch(preflight: true);
  }

  /// SIGTERM, then SIGKILL if the grace elapses.
  ///
  /// The escalation is not paranoia: llama-server can be inside a several
  /// gigabyte `mmap` when the signal lands, and a child that has not finished
  /// with the file will not die politely. What must never happen is the app
  /// quitting with the child still holding the port, because the next launch
  /// then finds its own server in the way.
  Future<void> stop() async {
    _stopping = true;
    _generation++;
    _restartTimer?.cancel();
    _restartTimer = null;
    _restarts = 0;
    _cancelTimers();
    await _terminate();
    await _cancelPipes();
    await _deletePidFile();
    await _endActivity();
    _emit(managed() ? const ServerStopped() : const ServerDisabled());
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<int> pickFreePort() => runner.freePort();

  /// Lets the supervisor go without killing the child.
  ///
  /// Deliberately asymmetric with [stop]. Disposing is what a provider does
  /// when it is rebuilt, and killing a loaded twenty-seven-billion-parameter
  /// model because a widget tree changed would cost a minute of reloading.
  /// The child is killed where quitting is actually meant: the Dart exit hook
  /// and `applicationWillTerminate`, both of which call [stop].
  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _cancelTimers();
    _restartTimer?.cancel();
    _restartTimer = null;
    await _cancelPipes();
    // The activity assertion is ended even though the child is not killed: a
    // provider disposed mid-start would otherwise leave an `NSProcessInfo`
    // activity live for the rest of the process, and App Nap would never get
    // the app back.
    await _endActivity();
    await _log?.close();
    _log = null;
    if (_ownsHttp) _http.close();
    if (!_changes.isClosed) await _changes.close();
  }

  // ── the start sequence ───────────────────────────────────────────────

  /// One attempt. [preflight] is false on a restart, because the binary and
  /// the model files were checked when the first attempt was made and
  /// re-`stat`ing a dozen gigabytes of GGUF between backoffs buys nothing.
  Future<void> _launch({required bool preflight}) async {
    if (_disposed) return;
    _stopping = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _generation++;
    final generation = _generation;
    _listeningSeen = false;
    _readyCalled = false;
    _healthFailures = 0;
    _recent.clear();

    final binary = binaryPath();
    if (binary == null) {
      _emit(const ServerFailed(LlamaBinary.missingReason));
      await _endActivity();
      return;
    }

    final preset = buildPreset();
    _preset = preset;
    if (preflight) {
      final missing = preset.missingFiles();
      if (missing.isNotEmpty) {
        // Basenames, not paths: the user is being told which downloads did
        // not finish, and the folder they share is not part of the answer.
        _emit(ServerFailed(
          'Model files are missing: ${missing.map(p.basename).join(', ')}',
        ));
        await _endActivity();
        return;
      }
    }

    final port = routerPort();
    if (!await runner.isPortFree(port)) {
      if (generation != _generation) return;
      _emit(ServerPortInUse(port, holder: await runner.listenerOn(port)));
      await _endActivity();
      return;
    }
    if (generation != _generation) return;

    _port = port;
    _emit(ServerStarting(port: port));
    _activityToken ??= await beginActivity?.call('Starting the model server');
    if (generation != _generation) return;

    try {
      await Directory(p.join(supportDir.path, 'servers')).create(recursive: true);
      await Directory(p.join(supportDir.path, 'logs')).create(recursive: true);
      await emptyCacheDir.create(recursive: true);

      // Written to a temp name and renamed, because the child reads this file
      // moments after it is written: a torn preset is a server that starts
      // and serves the wrong models, which is far worse than one that does
      // not start.
      final staging = File('${presetFile.path}.tmp');
      await staging.writeAsString(preset.toIni(), flush: true);
      await staging.rename(presetFile.path);

      await _ensureLog();

      final process = await runner.start(
        binary,
        [
          '--models-preset', presetFile.path,
          // The preset's own length, not a literal: the ceiling has to move
          // with the number of models the preset asks the router to hold, or a
          // fourth model would be listed and never loaded.
          '--models-max', '${preset.models.length}',
          '--no-models-autoload',
          '--host', '127.0.0.1',
          '--port', '$port',
          // Nothing is fetched at run time. Every weight was downloaded by the
          // first-run flow, and a server that would reach the network on a
          // cache miss is one that hangs on a plane instead of failing.
          '--offline',
        ],
        // The executable's own directory, and it has to be: llama.cpp's ggml
        // backend modules are `.so` files loaded relative to it, so a child
        // started anywhere else silently loses the Metal backend and runs on
        // the CPU. There is no environment variable for this.
        workingDirectory: p.dirname(binary),
        environment: {
          ...Platform.environment,
          'LLAMA_CACHE': emptyCacheDir.path,
        },
      );
      if (generation != _generation) {
        process.kill();
        return;
      }
      _process = process;
      _pid = process.pid;

      _outSub = _lines(process.stdout)
          .listen((line) => _onLine(line, generation, preset, binary));
      _errSub = _lines(process.stderr)
          .listen((line) => _onLine(line, generation, preset, binary));
      unawaited(process.exitCode.then((code) => _onExit(code, generation)));

      _startTimer = Timer(startTimeout, () {
        if (generation != _generation || _listeningSeen) return;
        unawaited(_crash('The model server did not start listening'));
      });
    } catch (e) {
      if (generation != _generation) return;
      _emit(ServerFailed(
        'The model server could not be started: $e',
        logTail: _log?.tail ?? const [],
      ));
      await _endActivity();
    }
  }

  /// `allowMalformed`, because a model's own output can land in the log and a
  /// bad byte must not tear the pipe down mid-load.
  Stream<String> _lines(Stream<List<int>> bytes) => bytes
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  void _onLine(String line, int generation, RouterPreset preset, String binary) {
    if (generation != _generation) return;
    _log?.write(line);
    _recent.add(line);
    if (_recent.length > _recentMax) {
      _recent.removeRange(0, _recent.length - _recentMax);
    }
    if (_listeningSeen) return;
    final match = _listening.firstMatch(line);
    if (match == null) return;
    _listeningSeen = true;
    unawaited(_onListening(
      int.parse(match.group(1)!),
      generation,
      preset,
      binary,
    ));
  }

  Future<void> _onListening(
    int port,
    int generation,
    RouterPreset preset,
    String binary,
  ) async {
    if (generation != _generation) return;
    _startTimer?.cancel();
    _startTimer = null;
    _port = port;
    final pid = _pid;
    if (pid == null) return;

    try {
      await pidFile.writeAsString(
        jsonEncode({
          'pid': pid,
          'port': port,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'presetHash': preset.hash,
          'binaryPath': binary,
        }),
        flush: true,
      );
    } catch (e) {
      // A pid file that could not be written costs reaping on the next
      // launch, not this run: the supervisor holds the handle either way.
      debugPrint('server: could not write ${pidFile.path}: $e');
    }
    if (generation != _generation) return;

    _emit(ServerLoading(
      port: port,
      pid: pid,
      loaded: {for (final id in preset.modelIds) id: false},
    ));
    _startWatcher();
  }

  void _startWatcher() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(healthInterval, (_) => unawaited(_tick()));
    // One poll now rather than after the first interval: a server that was
    // adopted is usually already ready, and waiting an interval to say so
    // shows the user a loading line for no reason.
    unawaited(_tick());
  }

  /// One health pass. Which question it asks depends on where the server is:
  /// while loading, `/models` is the progress report; once ready, `/health`
  /// alone is enough and is far cheaper.
  Future<void> _tick() async {
    if (_polling || _disposed || _stopping) return;
    _polling = true;
    final generation = _generation;
    try {
      final port = _port;
      final pid = _pid;
      final preset = _preset;
      if (port == null || pid == null || preset == null) return;

      if (_state is ServerReady) {
        final ok = await _healthOk(port);
        if (generation != _generation) return;
        if (ok) {
          _healthFailures = 0;
          return;
        }
        _healthFailures++;
        // Three in a row, not one: a single miss is a request that arrived
        // while the router was swapping a model in, and killing a working
        // server over it would be the app's own fault.
        if (_healthFailures >= 3) {
          await _crash('The model server stopped answering');
        }
        return;
      }

      final listing = await _models(port);
      if (generation != _generation) return;
      if (listing == null) return;

      final loaded = {
        for (final id in preset.modelIds) id: listing[id] ?? false,
      };
      if (loaded.values.every((v) => v) && await _healthOk(port)) {
        if (generation != _generation) return;
        _healthFailures = 0;
        _emit(ServerReady(port: port, pid: pid));
        await _endActivity();
        if (!_readyCalled) {
          _readyCalled = true;
          onReady?.call();
        }
        return;
      }
      if (generation != _generation) return;
      _emit(ServerLoading(port: port, pid: pid, loaded: loaded));
    } finally {
      _polling = false;
    }
  }

  /// Model id → whether the router says its weights are resident. Null means
  /// the question could not be asked at all, which is not the same as "no
  /// models" and must not be read as progress.
  Future<Map<String, bool>?> _models(int port) async {
    try {
      final response = await _http
          .get(Uri.parse('http://127.0.0.1:$port/models'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! List) return null;
      final out = <String, bool>{};
      for (final entry in data) {
        if (entry is! Map) continue;
        final id = entry['id'];
        if (id is! String) continue;
        final status = entry['status'];
        final value = status is Map ? status['value'] : null;
        out[id] = value == 'loaded';
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  /// 503 while models are loading, 200 when the router will take work.
  Future<bool> _healthOk(int port) async {
    try {
      final response = await _http
          .get(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  void _onExit(int code, int generation) {
    if (generation != _generation) return;
    if (_stopping) return;
    unawaited(_crash('The model server exited (code $code)'));
  }

  /// The one path out of every unexpected ending.
  ///
  /// Backoff rather than an immediate retry, and a bounded number of them:
  /// a server that dies on a corrupt GGUF dies the same way every time, and
  /// a tight loop would fill the log and hold the CPU while saying nothing
  /// new. When the attempts run out the state carries the log tail, because
  /// the reason alone never explains a crash.
  ///
  /// EVERY branch below reaps the child before letting go of it. Only one of
  /// the three callers arrives here with a process that has already exited:
  /// the start timeout and the health loss are both a LIVE process holding the
  /// port and the weights, and nothing else in the app would ever kill it —
  /// there is no pid file yet on the timeout path, and the pid file on the
  /// health path is overwritten by the very next launch. Forgetting the handle
  /// without signalling it is how a machine ends up with a stack of orphaned
  /// servers, each with a model mapped.
  Future<void> _crash(String reason) async {
    if (_stopping || _disposed) return;
    _cancelTimers();
    final tail = _log?.tail ?? const <String>[];
    // Read before [_terminate], which clears the pid but deliberately leaves
    // [_port] alone: the port that was bound is the whole content of the
    // report below, and of the next attempt's own preflight.
    final port = _port;
    // THIS launch's lines, not the session's: a `couldn't bind` from an
    // earlier attempt is still in the log's tail and would misread an
    // unrelated crash as a port problem.
    final bindFailure = _recent.any((l) => l.contains("couldn't bind"));

    // A bind failure is not retried at any backoff, because nothing about
    // waiting frees a port somebody else is holding, and the user can only
    // act on it if the app names it.
    if (port != null && bindFailure) {
      _generation++;
      await _terminate();
      await _cancelPipes();
      final holder = await runner.listenerOn(port);
      _emit(ServerPortInUse(port, holder: holder));
      await _endActivity();
      return;
    }

    if (_restarts < restartBackoff.length) {
      final wait = restartBackoff[_restarts];
      _restarts++;
      _generation++;
      await _terminate();
      await _cancelPipes();
      _restartTimer = Timer(wait, () => unawaited(_launch(preflight: false)));
      return;
    }

    _generation++;
    await _terminate();
    await _cancelPipes();
    // The whole session's tail, not [_recent]: a final failure is what someone
    // reads to find out why, and the attempt that actually explains it is
    // often not the last one.
    _emit(ServerFailed(reason, logTail: tail));
    await _endActivity();
  }

  // ── adoption ─────────────────────────────────────────────────────────

  /// Attaches to the server this app left behind, or clears the way for a new
  /// one. True means there is nothing more to start.
  ///
  /// Adoption exists because a reload of three models costs the better part
  /// of a minute, and a hot-restart during development would pay it every
  /// time. It is deliberately suspicious: a live pid whose command line is
  /// somebody else's program is left strictly alone, because a reused pid
  /// number is the normal case on a machine that has been up for a week and
  /// killing a stranger's process would be unforgivable.
  Future<bool> _adopt() async {
    Map<String, Object?> record;
    try {
      if (!await pidFile.exists()) return false;
      final decoded = jsonDecode(await pidFile.readAsString());
      if (decoded is! Map) {
        await _deletePidFile();
        return false;
      }
      record = decoded.cast<String, Object?>();
    } catch (e) {
      debugPrint('server: unreadable ${pidFile.path} ($e) — starting fresh');
      await _deletePidFile();
      return false;
    }

    final pid = (record['pid'] as num?)?.toInt();
    final port = (record['port'] as num?)?.toInt();
    final recordedHash = record['presetHash'] as String?;
    if (pid == null || port == null) {
      await _deletePidFile();
      return false;
    }

    if (!await runner.isAlive(pid)) {
      await _deletePidFile();
      return false;
    }

    final preset = buildPreset();
    if (recordedHash == preset.hash) {
      final listing = await _models(port);
      if (listing != null && preset.modelIds.every(listing.containsKey)) {
        _generation++;
        _stopping = false;
        _preset = preset;
        _process = null;
        _pid = pid;
        _port = port;
        _readyCalled = false;
        _healthFailures = 0;
        _restarts = 0;
        await _ensureLog();
        _emit(ServerLoading(
          port: port,
          pid: pid,
          loaded: {for (final id in preset.modelIds) id: listing[id] ?? false},
        ));
        _startWatcher();
        return true;
      }
    }

    // Alive, but not a server this build can use — a stale preset, or a
    // listing that no longer matches. Ours to kill only if its command line
    // says so on both counts: the program AND the preset file this app wrote.
    final command = await runner.commandLineOf(pid);
    if (command != null &&
        command.contains('llama-server') &&
        command.contains(presetFile.path)) {
      await _killPid(pid);
    } else {
      debugPrint('server: pid $pid is alive but its command line is not ours '
          '($command) — leaving it and starting a new server');
    }
    await _deletePidFile();
    return false;
  }

  // ── plumbing ─────────────────────────────────────────────────────────

  Future<void> _ensureLog() async {
    if (_log != null) return;
    final log = ServerLog(logFile);
    await log.open();
    _log = log;
  }

  void _emit(ServerState next) {
    if (_state == next) return;
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  void _cancelTimers() {
    _startTimer?.cancel();
    _startTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  Future<void> _cancelPipes() async {
    final out = _outSub;
    final err = _errSub;
    _outSub = null;
    _errSub = null;
    await out?.cancel();
    await err?.cancel();
  }

  /// Terminates whatever child this supervisor is responsible for — the one
  /// it holds a handle to, or the one it only knows by pid because it was
  /// adopted after a relaunch.
  Future<void> _terminate() async {
    final process = _process;
    final pid = _pid;
    _process = null;
    _pid = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      if (!await _exited(process, terminateGrace)) {
        process.kill(ProcessSignal.sigkill);
        await _exited(process, terminateGrace);
      }
      return;
    }
    if (pid != null) await _killPid(pid);
  }

  Future<bool> _exited(RunningProcess process, Duration grace) async {
    try {
      await process.exitCode.timeout(grace);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _killPid(int pid) async {
    runner.kill(pid, ProcessSignal.sigterm);
    final deadline = DateTime.now().add(terminateGrace);
    while (DateTime.now().isBefore(deadline)) {
      if (!await runner.isAlive(pid)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (await runner.isAlive(pid)) runner.kill(pid, ProcessSignal.sigkill);
  }

  Future<void> _deletePidFile() async {
    try {
      if (await pidFile.exists()) await pidFile.delete();
    } catch (e) {
      debugPrint('server: could not remove ${pidFile.path}: $e');
    }
  }

  Future<void> _endActivity() async {
    final token = _activityToken;
    _activityToken = null;
    if (token == null) return;
    try {
      await endActivity?.call(token);
    } catch (e) {
      debugPrint('server: endActivity($token) failed: $e');
    }
  }
}
