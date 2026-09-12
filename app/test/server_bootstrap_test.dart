import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/widgets/server_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show JSONMethodCodec, MethodCall;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_process_runner.dart';
import 'fixtures/test_manifest.dart';

/// A supervisor whose [stop] never comes back.
///
/// The child this stands in for is one inside a multi-gigabyte `mmap` that
/// will not answer a signal, and the question is what the QUIT does about it:
/// a window that refuses to close because a server is busy is a far worse
/// failure than a process the operating system reaps a moment later.
class _WedgedSupervisor extends ModelServerSupervisor {
  _WedgedSupervisor({
    required super.runner,
    required super.supportDir,
    required super.binaryPath,
    required super.buildPreset,
    required super.routerPort,
    required super.managed,
  });

  @override
  Future<void> stop() => Completer<void>().future;
}

/// What launch does about the model server when nobody has asked for one.
///
/// The default matters more than the feature: every existing install arrives
/// with the managed preference off, and mounting the app must not spawn a
/// process, take three gigabytes of memory, or touch the port the hand-started
/// `make model` workflow is already using. Nothing else here is the
/// bootstrap's — adoption, backoff and the health poll are the supervisor's
/// own tests.
///
/// The temp directory is made in `setUp` rather than inside the test body, and
/// that is not tidiness: a `testWidgets` body runs inside a fake-async zone
/// where a real filesystem future never completes, so awaiting one there hangs
/// the run instead of failing it.
void main() {
  late Directory support;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;

  /// The preference every existing install is on. Said here rather than read
  /// out of prefs so this file is about the bootstrap and not about the prefs.
  bool managed = false;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('bond-bootstrap');
    runner = FakeProcessRunner();
    managed = false;
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: support,
      // A binary that resolves, so a spawn that DID happen would happen —
      // "nothing started" has to be the preference's doing rather than a
      // missing executable's.
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => testPreset(support.path),
      routerPort: () => 8080,
      managed: () => managed,
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    await support.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {Widget child = const SizedBox.shrink()}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        modelServerSupervisorProvider.overrideWithValue(supervisor),
      ],
      child: MaterialApp(home: ServerBootstrap(child: child)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('mounting spawns nothing while the preference is off',
      (tester) async {
    await mount(tester);

    expect(runner.starts, isEmpty);
    expect(supervisor.state, const ServerDisabled());
  });

  testWidgets('the child is rendered untouched', (tester) async {
    await mount(tester, child: const Text('the app'));

    expect(find.text('the app'), findsOneWidget);
  });

  /// The quit, as the engine asks it: a method call on the platform channel,
  /// answered by whatever `AppLifecycleListener.onExitRequested` returns.
  ///
  /// `flutter/platform` speaks JSON rather than the standard binary codec —
  /// encoding this call the other way gets it rejected before any handler
  /// sees it.
  Future<Object?> requestAppExit(WidgetTester tester) async {
    const codec = JSONMethodCodec();
    Object? decoded;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/platform',
      codec.encodeMethodCall(const MethodCall('System.requestAppExit')),
      (reply) => decoded = reply == null ? null : codec.decodeEnvelope(reply),
    );
    return decoded;
  }

  /// The quit hook is the app's FIRST line of defence against an orphaned
  /// server — and it must never become a reason the app cannot be quit.
  testWidgets('a stop that never finishes still lets the app exit',
      (tester) async {
    final idle = supervisor;
    addTearDown(idle.dispose);
    supervisor = _WedgedSupervisor(
      runner: runner,
      supportDir: support,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => testPreset(support.path),
      routerPort: () => 8080,
      managed: () => managed,
    );
    await mount(tester);

    final replied = requestAppExit(tester);
    // Past the four-second grace the hook gives the server, and no further:
    // the answer has to be the timeout's, not a stop that finally returned.
    await tester.pump(const Duration(seconds: 5));

    expect(await replied, {'response': 'exit'});
  });

  /// The ordinary quit: the child is signalled and the pid file — the handoff
  /// to the Swift reaper and to the next launch — is gone with it.
  ///
  /// The server is started inside [WidgetTester.runAsync] because starting one
  /// is real filesystem work, and a real future never completes inside the
  /// fake-async zone a `testWidgets` body runs in.
  testWidgets('quitting stops the server and clears the pid file',
      (tester) async {
    managed = true;
    // A port nothing listens on: the supervisor parses it out of the line and
    // the health poll that follows is refused at once, which is all this test
    // wants — the pid file is written the moment the port is known.
    runner.onStart = (start) {
      final process = FakeRunningProcess(pid: 6120);
      Future<void>.delayed(Duration.zero, () {
        process.emit('main: server is listening on http://127.0.0.1:1');
      });
      return process;
    };
    await tester.runAsync(() async {
      // The preflight refuses to spawn while a file the preset names is
      // missing, so the three the fixture declares are put on disk first.
      final preset = testPreset(support.path);
      for (final model in preset.models) {
        final path = preset.modelPath(model);
        await Directory(p.dirname(path)).create(recursive: true);
        await File(path).writeAsString('gguf');
      }
      await supervisor.start();
      for (var i = 0; i < 100 && !supervisor.pidFile.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(supervisor.pidFile.existsSync(), isTrue);

    await mount(tester);

    // The reply is not awaited before the pumps: the hook's own grace is a
    // timer, and a body that waited here would be waiting for a clock only it
    // can advance. Bare pumps, the house idiom, and then the answer.
    final replied = requestAppExit(tester);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(runner.kills, contains((6120, ProcessSignal.sigterm)));
    await tester.pump(const Duration(seconds: 5));
    expect(await replied, {'response': 'exit'});
    // The delete is real filesystem work, and finishing it takes BOTH halves:
    // `runAsync` lets the real event loop deliver the result, and the pump
    // flushes the continuation waiting for it in the test's fake-async queue.
    // Neither alone gets there.
    for (var i = 0; i < 50 && supervisor.pidFile.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(supervisor.pidFile.existsSync(), isFalse);
  });
}
