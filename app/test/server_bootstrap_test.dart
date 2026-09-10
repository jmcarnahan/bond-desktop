import 'dart:io';

import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/server/router_preset.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/widgets/server_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_process_runner.dart';

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
      buildPreset: () => RouterPreset.defaults(support.path),
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
}
