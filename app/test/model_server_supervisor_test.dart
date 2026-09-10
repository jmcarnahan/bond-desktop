import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/server/llama_binary.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/server/router_preset.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_router_server.dart';

/// The two-model preset every test here runs against.
///
/// Two rather than the shipping three, and named for their roles rather than
/// their checkpoints, because nothing below cares which weights they are —
/// only that the supervisor waits for ALL of them.
RouterPreset presetIn(String folder) => RouterPreset(
      modelsFolder: folder,
      models: const [
        RouterModelSpec(id: 'bond-embed', repo: 'org/embed', file: 'embed.gguf'),
        RouterModelSpec(id: 'bond-bulk', repo: 'org/bulk', file: 'bulk.gguf'),
      ],
    );

void main() {
  late Directory root;
  late Directory models;
  late String binary;
  late FakeProcessRunner runner;
  late FakeRouterServer server;
  late RouterPreset preset;
  late ModelServerSupervisor supervisor;
  late List<String> activities;
  late int readyCalls;
  bool managed = true;
  String? binaryOverride;

  /// Waits for the first state matching [matches], with a real timeout so a
  /// supervisor that never gets there fails here rather than hanging the run.
  Future<ServerState> waitFor(bool Function(ServerState) matches) =>
      supervisor.states.firstWhere(matches).timeout(const Duration(seconds: 5));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('supervisor');
    models = Directory(p.join(root.path, 'models'));
    final bin = Directory(p.join(root.path, 'runtime', 'MacOS'));
    await bin.create(recursive: true);
    binary = p.join(bin.path, 'llama-server');
    await File(binary).writeAsString('#!/bin/sh\n');

    preset = presetIn(models.path);
    for (final model in preset.models) {
      final path = preset.modelPath(model);
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString('gguf');
    }

    runner = FakeProcessRunner();
    server = await FakeRouterServer.start();
    server.loaded = {for (final id in preset.modelIds) id: true};
    server.healthy = true;

    activities = [];
    readyCalls = 0;
    managed = true;
    binaryOverride = binary;

    // The default child: it announces the socket the fake router is actually
    // on, so the supervisor's health polling reaches a real server. The port
    // is PARSED out of this line, which is what makes that possible.
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: 5150);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on '
            'http://127.0.0.1:${server.port} - starting the main loop');
      });
      return process;
    };

    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      binaryPath: () => binaryOverride,
      buildPreset: () => preset,
      routerPort: () => server.port,
      managed: () => managed,
      onReady: () => readyCalls++,
      beginActivity: (reason) async {
        activities.add('begin:$reason');
        return 7;
      },
      endActivity: (token) async => activities.add('end:$token'),
      healthInterval: const Duration(milliseconds: 10),
      terminateGrace: const Duration(milliseconds: 60),
      startTimeout: const Duration(milliseconds: 800),
      restartBackoff: const [
        Duration(milliseconds: 5),
        Duration(milliseconds: 10),
        Duration(milliseconds: 15),
      ],
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    for (final process in runner.processes) {
      await process.dispose();
    }
    await server.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a clean start goes stopped, starting, loading, ready', () async {
    final seen = <ServerState>[];
    final sub = supervisor.states.listen(seen.add);
    addTearDown(sub.cancel);

    await supervisor.start();
    final ready = await waitFor((s) => s is ServerReady);

    expect((ready as ServerReady).port, server.port);
    expect(ready.pid, 5150);
    expect(
      seen.map((s) => s.runtimeType).toList(),
      containsAllInOrder(<Type>[
        ServerStopped,
        ServerStarting,
        ServerLoading,
        ServerReady,
      ]),
    );

    // Once per start, and it stays once while the health watcher keeps
    // polling — re-pointing the clients on every tick would be a storm.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(readyCalls, 1);
    expect(activities, ['begin:Starting the model server', 'end:7']);
  });

  test('the child is spawned in router mode, beside its backends', () async {
    await supervisor.start();
    await waitFor((s) => s is ServerReady);

    final start = runner.starts.single;
    expect(start.executable, binary);
    expect(start.arguments, [
      '--models-preset',
      supervisor.presetFile.path,
      // The preset's own length, not a literal: a preset with a fourth model
      // would otherwise get a ceiling of three and never load it.
      '--models-max',
      '${preset.models.length}',
      '--no-models-autoload',
      '--host',
      '127.0.0.1',
      '--port',
      '${server.port}',
      '--offline',
    ]);
    // The executable's own directory: ggml's backend modules are `.so` files
    // loaded relative to it, and there is no environment variable for this.
    expect(start.workingDirectory, p.dirname(binary));
    // An empty directory, so `/models` lists the preset and nothing else.
    expect(start.environment['LLAMA_CACHE'], supervisor.emptyCacheDir.path);
    expect(await supervisor.emptyCacheDir.exists(), isTrue);
  });

  test('the preset and the pid file record what was started', () async {
    await supervisor.start();
    await waitFor((s) => s is ServerReady);

    expect(await supervisor.presetFile.readAsString(), preset.toIni());
    // The staging file is renamed, never left behind: a torn preset is a
    // server that serves the wrong models.
    expect(await File('${supervisor.presetFile.path}.tmp').exists(), isFalse);

    final record = jsonDecode(await supervisor.pidFile.readAsString())
        as Map<String, dynamic>;
    expect(record['pid'], 5150);
    expect(record['port'], server.port);
    expect(record['presetHash'], preset.hash);
    expect(record['binaryPath'], binary);
    expect(record['startedAt'], isA<String>());
  });

  test('a port somebody else holds is named, and nothing is spawned',
      () async {
    runner.busyPorts.add(server.port);
    runner.listeners[server.port] = 'llama-server (pid 999)';

    await supervisor.start();

    expect(supervisor.state, isA<ServerPortInUse>());
    final state = supervisor.state as ServerPortInUse;
    expect(state.port, server.port);
    expect(state.holder, 'llama-server (pid 999)');
    expect(state.summary, 'Port ${server.port} is in use by llama-server (pid 999)');
    expect(runner.starts, isEmpty);
  });

  test('a build with no runtime fails before anything else', () async {
    binaryOverride = null;

    await supervisor.start();

    expect(supervisor.state, const ServerFailed(LlamaBinary.missingReason));
    expect(runner.starts, isEmpty);
  });

  test('missing model files are named by basename', () async {
    preset = presetIn(p.join(root.path, 'not-downloaded'));

    await supervisor.start();

    expect(supervisor.state, isA<ServerFailed>());
    final failed = supervisor.state as ServerFailed;
    // Basenames, not paths: the user is being told which downloads did not
    // finish, not where the folder is.
    expect(failed.reason, 'Model files are missing: embed.gguf, bulk.gguf');
    expect(runner.starts, isEmpty);
  });

  test('a crashing server is restarted on the backoff, then given up on',
      () async {
    server.loaded = {for (final id in preset.modelIds) id: false};
    server.healthy = false;
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: runner.nextPid++);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on '
            'http://127.0.0.1:${server.port} - starting the main loop');
        Future<void>.delayed(
          const Duration(milliseconds: 5),
          () => process.finish(1),
        );
      });
      return process;
    };

    await supervisor.start();
    final failed = await waitFor((s) => s is ServerFailed) as ServerFailed;

    expect(failed.reason, 'The model server exited (code 1)');
    // The reason alone never explains a crash; the last lines are what do.
    expect(failed.logTail, isNotEmpty);
    // The first attempt plus one per backoff entry, and then it stops.
    expect(runner.starts, hasLength(4));
    expect(readyCalls, 0);
  });

  test("couldn't bind is a port problem, and is never retried", () async {
    runner.listeners[server.port] = 'llama-server (pid 4242)';
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: runner.nextPid++);
      Future<void>.delayed(Duration.zero, () {
        process.emit("main: couldn't bind HTTP server socket, "
            'hostname: 127.0.0.1, port: ${server.port}');
        Future<void>.delayed(
          const Duration(milliseconds: 5),
          () => process.finish(1),
        );
      });
      return process;
    };

    await supervisor.start();
    final state = await waitFor((s) => s is ServerPortInUse) as ServerPortInUse;

    expect(state.port, server.port);
    expect(state.holder, 'llama-server (pid 4242)');
    // Nothing about waiting frees a port somebody else is holding.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(runner.starts, hasLength(1));
  });

  /// The bind sniff reads THIS launch's lines, not the session's.
  ///
  /// The log is opened once and its tail spans every attempt, so a
  /// `couldn't bind` printed by the first child is still sitting there while
  /// the second one runs. A crash that read it there would report an
  /// unrelated failure as a port problem — and, worse, would never retry it,
  /// because a port problem is the one crash no backoff is spent on.
  test('a bind failure in one attempt does not explain the next one', () async {
    runner.listeners[server.port] = 'llama-server (pid 4242)';
    var attempt = 0;
    runner.onStart = (start) {
      attempt++;
      final binds = attempt == 1;
      final process = FakeRunningProcess(pid: runner.nextPid++);
      Future<void>.delayed(Duration.zero, () {
        process.emit(binds
            ? "main: couldn't bind HTTP server socket, hostname: 127.0.0.1, "
                'port: ${server.port}'
            : 'main: server is listening on '
                'http://127.0.0.1:${server.port} - starting the main loop');
        Future<void>.delayed(
          const Duration(milliseconds: 5),
          () => process.finish(1),
        );
      });
      return process;
    };

    await supervisor.start();
    await waitFor((s) => s is ServerPortInUse);

    await supervisor.start();
    final failed = await waitFor((s) => s is ServerFailed) as ServerFailed;

    // A plain exit, retried on the backoff like any other — not the port
    // report the stale line would have produced.
    expect(failed.reason, 'The model server exited (code 1)');
    // The bind attempt, then the second run's first attempt and one per
    // backoff entry.
    expect(runner.starts, hasLength(5));
  });

  /// The start timeout is the only thing that can end a child which binds
  /// nothing and never exits, so it has to actually kill it: there is no pid
  /// file yet on this path, and a child left here would hold the port and its
  /// mapped weights for as long as the app runs.
  test('a start that never listens kills the child before retrying', () async {
    runner.onStart = (start) => FakeRunningProcess(pid: runner.nextPid++);

    await supervisor.start();
    final first = runner.processes.single.pid;

    // The 800 ms timeout, then the 5 ms backoff.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(runner.kills, contains((first, ProcessSignal.sigterm)));
    expect(runner.starts.length, greaterThanOrEqualTo(2));
  });

  /// A wedged server is the case no exit code reports: the socket still
  /// accepts, `/health` answers 503 forever, and the process sits there with
  /// the models mapped. The supervisor's own poll is what notices, so the
  /// supervisor is what has to reap it.
  test('a server that stops answering is killed and restarted', () async {
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: runner.nextPid++);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on '
            'http://127.0.0.1:${server.port} - starting the main loop');
      });
      return process;
    };

    await supervisor.start();
    await waitFor((s) => s is ServerReady);
    final first = runner.processes.single.pid;

    server.healthy = false;

    // Three failed polls at 10 ms, the crash, then the 5 ms backoff.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(runner.kills, contains((first, ProcessSignal.sigterm)));
    expect(runner.starts.length, greaterThanOrEqualTo(2));
  });

  test('stop escalates to SIGKILL when the child ignores SIGTERM', () async {
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: 7777, ignoreTerm: true);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on '
            'http://127.0.0.1:${server.port}');
      });
      return process;
    };

    await supervisor.start();
    await waitFor((s) => s is ServerReady);
    await supervisor.stop();

    expect(runner.kills, [
      (7777, ProcessSignal.sigterm),
      (7777, ProcessSignal.sigkill),
    ]);
    // The pid file is the handoff to the next launch; a stale one would send
    // it hunting a process that is gone.
    expect(await supervisor.pidFile.exists(), isFalse);
    expect(supervisor.state, const ServerStopped());
  });

  test('a stop while starting is not reported as a crash', () async {
    runner.onStart = (start) => FakeRunningProcess(pid: 3131);

    await supervisor.start();
    expect(supervisor.state, isA<ServerStarting>());
    await supervisor.stop();

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(supervisor.state, const ServerStopped());
    expect(runner.starts, hasLength(1));
  });

  test('an unmanaged supervisor starts nothing', () async {
    managed = false;

    await supervisor.ensureRunning();

    expect(supervisor.state, const ServerDisabled());
    expect(supervisor.state.summary, 'Off — servers are started by hand');
    expect(runner.starts, isEmpty);
  });

  test('a late subscriber is told the current state first', () async {
    await supervisor.start();
    await waitFor((s) => s is ServerReady);

    final first = await supervisor.states.first;
    expect(first, supervisor.state);
    expect(first, isA<ServerReady>());
  });

  test('pickFreePort asks the runner', () async {
    runner.nextFreePort = 51234;
    expect(await supervisor.pickFreePort(), 51234);
  });
}
