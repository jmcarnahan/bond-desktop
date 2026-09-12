import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/server/router_preset.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_router_server.dart';

/// Adopting the server a previous launch left running.
///
/// Worth its own file because the interesting cases are all about EVIDENCE:
/// a pid number on its own proves nothing (they are reused within hours on a
/// machine that stays up), so the supervisor cross-checks the recorded preset
/// hash, the router's own listing and the process's command line before it
/// either attaches to a stranger or kills one.
void main() {
  late Directory root;
  late String binary;
  late FakeProcessRunner runner;
  late FakeRouterServer server;
  late RouterPreset preset;
  late ModelServerSupervisor supervisor;
  late int readyCalls;

  Future<void> writePidFile({
    required int pid,
    required int port,
    required String presetHash,
    String? binaryPath,
  }) async {
    await supervisor.pidFile.parent.create(recursive: true);
    await supervisor.pidFile.writeAsString(jsonEncode({
      'pid': pid,
      'port': port,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'presetHash': presetHash,
      'binaryPath': binaryPath ?? binary,
    }));
  }

  Future<ServerState> waitFor(bool Function(ServerState) matches) =>
      supervisor.states.firstWhere(matches).timeout(const Duration(seconds: 5));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adoption');
    final bin = Directory(p.join(root.path, 'runtime', 'MacOS'));
    await bin.create(recursive: true);
    binary = p.join(bin.path, 'llama-server');
    await File(binary).writeAsString('#!/bin/sh\n');

    preset = RouterPreset(
      modelsFolder: p.join(root.path, 'models'),
      models: const [
        RouterModelSpec(id: 'bond-embed', repo: 'org/embed', file: 'embed.gguf'),
        RouterModelSpec(id: 'bond-bulk', repo: 'org/bulk', file: 'bulk.gguf'),
      ],
    );
    for (final model in preset.models) {
      final path = preset.modelPath(model);
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString('gguf');
    }

    runner = FakeProcessRunner();
    server = await FakeRouterServer.start();
    server.loaded = {for (final id in preset.modelIds) id: true};
    server.healthy = true;
    readyCalls = 0;

    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: 5150);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on '
            'http://127.0.0.1:${server.port}');
      });
      return process;
    };

    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      binaryPath: () => binary,
      buildPreset: () => preset,
      routerPort: () => server.port,
      managed: () => true,
      onReady: () => readyCalls++,
      healthInterval: const Duration(milliseconds: 10),
      terminateGrace: const Duration(milliseconds: 60),
      startTimeout: const Duration(milliseconds: 800),
      restartBackoff: const [Duration(milliseconds: 5)],
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

  test('a live server with our preset hash is attached to, not restarted',
      () async {
    await writePidFile(pid: 9001, port: server.port, presetHash: preset.hash);
    runner.alive[9001] = true;

    await supervisor.ensureRunning();
    final ready = await waitFor((s) => s is ServerReady) as ServerReady;

    expect(ready.pid, 9001);
    expect(ready.port, server.port);
    // The whole point: reloading three models costs the better part of a
    // minute, and a hot restart would pay it every time.
    expect(runner.starts, isEmpty);
    expect(runner.kills, isEmpty);
    expect(readyCalls, 1);
  });

  test('a live server still loading is adopted as loading', () async {
    server.loaded = {'bond-embed': true, 'bond-bulk': false};
    server.healthy = false;
    await writePidFile(pid: 9002, port: server.port, presetHash: preset.hash);
    runner.alive[9002] = true;

    await supervisor.ensureRunning();
    final loading = await waitFor(
      (s) => s is ServerLoading && s.loaded['bond-embed'] == true,
    ) as ServerLoading;

    expect(loading.pid, 9002);
    expect(loading.loaded, {'bond-embed': true, 'bond-bulk': false});
    expect(loading.summary, 'Loading models (1 of 2) on port ${server.port}');
    expect(runner.starts, isEmpty);
    expect(readyCalls, 0);
  });

  test('our own server on a stale preset is killed and replaced', () async {
    await writePidFile(
      pid: 9003,
      port: server.port,
      presetHash: 'a hash from a preset this build no longer writes',
    );
    runner.alive[9003] = true;
    // Both halves have to match before anything is signalled: the program,
    // and the preset file THIS app wrote.
    runner.commandLines[9003] =
        '$binary --models-preset ${supervisor.presetFile.path} --port 8080';

    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    expect(runner.kills.map((k) => k.$1), contains(9003));
    expect(runner.starts, hasLength(1));
    final record = jsonDecode(await supervisor.pidFile.readAsString())
        as Map<String, dynamic>;
    expect(record['pid'], 5150);
    expect(record['presetHash'], preset.hash);
  });

  test('a pid that is no longer alive is simply replaced', () async {
    await writePidFile(pid: 9004, port: server.port, presetHash: preset.hash);
    runner.alive[9004] = false;

    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    expect(runner.kills, isEmpty);
    expect(runner.starts, hasLength(1));
    final record = jsonDecode(await supervisor.pidFile.readAsString())
        as Map<String, dynamic>;
    expect(record['pid'], 5150);
  });

  test('a reused pid running somebody else is left strictly alone', () async {
    await writePidFile(
      pid: 9005,
      port: server.port,
      presetHash: 'stale, so the command line is what decides',
    );
    runner.alive[9005] = true;
    runner.commandLines[9005] = '/Applications/Safari.app/Contents/MacOS/Safari';

    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    // Signalling a stranger's process because the kernel reused an integer
    // would be unforgivable.
    expect(runner.kills, isEmpty);
    expect(runner.starts, hasLength(1));
  });

  /// The hash says which MODELS a server serves; it says nothing about which
  /// BUILD is serving them.
  ///
  /// A developer's session with `BOND_LLAMA_SERVER` pointed at the Homebrew
  /// binary, ended without the exit hooks, leaves a live server and a record
  /// the packaged app would happily adopt — and then report Ready for a
  /// program it did not build, ship or sign. Which is a false pass on exactly
  /// the check a release is verified with.
  test('a pid file naming another binary is not adopted (and is reaped only '
      'when the command line is ours)', () async {
    await writePidFile(
      pid: 9006,
      port: server.port,
      presetHash: preset.hash,
      binaryPath: '/opt/homebrew/bin/llama-server',
    );
    runner.alive[9006] = true;
    // Ours by both halves — the program and the preset file this app wrote —
    // which is the only thing that licenses the kill.
    runner.commandLines[9006] =
        '/opt/homebrew/bin/llama-server --models-preset '
        '${supervisor.presetFile.path} --port ${server.port}';

    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    expect(runner.kills.map((k) => k.$1), contains(9006));
    expect(runner.starts, hasLength(1));
    final record = jsonDecode(await supervisor.pidFile.readAsString())
        as Map<String, dynamic>;
    expect(record['binaryPath'], binary);
  });

  /// A record on the old port is a Ready state nothing can talk to.
  ///
  /// The port moves in Settings and the restart follows, but a crash between
  /// those two writes leaves the pid file naming the port the server was
  /// bound to while every client is already dialling the new one.
  test('a pid file on a port other than the preference is replaced', () async {
    await writePidFile(
      pid: 9007,
      port: server.port + 1,
      presetHash: preset.hash,
    );
    runner.alive[9007] = true;
    runner.commandLines[9007] =
        '$binary --models-preset ${supervisor.presetFile.path} '
        '--port ${server.port + 1}';

    await supervisor.ensureRunning();
    final ready = await waitFor((s) => s is ServerReady) as ServerReady;

    expect(ready.port, server.port);
    expect(runner.kills.map((k) => k.$1), contains(9007));
    expect(runner.starts, hasLength(1));
    final record = jsonDecode(await supervisor.pidFile.readAsString())
        as Map<String, dynamic>;
    expect(record['port'], server.port);
  });

  test('a malformed pid file is discarded and a server started', () async {
    await supervisor.pidFile.parent.create(recursive: true);
    await supervisor.pidFile.writeAsString('{not json at all');

    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    expect(runner.starts, hasLength(1));
  });

  test('no pid file at all is a plain start', () async {
    await supervisor.ensureRunning();
    await waitFor((s) => s is ServerReady);

    expect(runner.starts, hasLength(1));
    expect(await supervisor.pidFile.exists(), isTrue);
  });
}
