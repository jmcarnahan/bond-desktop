import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:bond_inbox/screens/setup/setup_gate.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// A store whose reads fail — the unreadable-database case the gate has to
/// survive.
class _UnreadableStore extends SetupStore {
  _UnreadableStore(super.db);

  @override
  Future<String?> get(String key) async => throw StateError('no database');
}

/// Which screen a launch gets, and when that answer is allowed to change.
///
/// The gate answers ONCE, on `AuthGate`'s pattern: a gate that re-decided on
/// every rebuild would swap the whole screen out from under a download. The
/// two things that may change its mind are the flow reporting itself finished
/// and "Set up again" bumping the counter.
///
/// Everything is created in `setUp` — the temp directory, the supervisor, the
/// database — because a `testWidgets` body runs in a fake-async zone where a
/// real filesystem future never completes.
void main() {
  late Directory support;
  late BondDatabase db;
  late SetupStore store;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late StreamController<MessageSettled> settles;
  late DesktopNotificationService notifications;
  late FakeDesktopNotifier notifier;
  late ProviderContainer container;
  late FakeHubServer hub;

  /// A ledger saying the whole manifest is here, at the digests this build
  /// names — what a machine the gate is allowed to let through really has.
  /// [bump] moves one model's sha, which is the manifest-bump case.
  Future<void> seedLedger({bool bump = false}) async {
    final manifest = testManifest();
    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256:
            bump && model.role == ModelRole.prose ? 'f' * 64 : model.sha256,
      ));
    }
    await store.recordDownload(ledger);
  }

  Future<void> makeContainer({SetupStore? overStore}) async {
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(testManifest()),
      // A downloader pointed at the loopback hub with nothing published on
      // it: the model-bump case opens the wizard ON the download step, and a
      // run against the real Hugging Face is not a thing a test may start.
      modelDownloaderProvider.overrideWithValue(ModelDownloader(
        manifest: testManifest(),
        modelsFolder: () => support.path,
        readLedger: (overStore ?? store).downloadLedger,
        writeLedger: (overStore ?? store).recordDownload,
        sha256: (_) async => null,
        resolveUri: hub.resolveUriFor,
        sleep: (_) async {},
        maxAttempts: 1,
      )),
      systemInfoProvider.overrideWithValue(FakeSystemInfo()),
      modelServerSupervisorProvider.overrideWithValue(supervisor),
      authSessionProvider.overrideWithValue(FakeAuthSession()),
      desktopNotifierProvider.overrideWithValue(notifier),
      desktopNotificationServiceProvider.overrideWithValue(notifications),
      if (overStore != null) setupStoreProvider.overrideWithValue(overStore),
    ]);
    addTearDown(container.dispose);
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    support = await Directory.systemTemp.createTemp('bond-gate');
    db = testDb();
    store = SetupStore(db);
    runner = FakeProcessRunner();
    notifier = FakeDesktopNotifier();
    settles = StreamController<MessageSettled>.broadcast();
    notifications = DesktopNotificationService(
      events: settles.stream,
      notifier: notifier,
      enabled: () => false,
    );
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: support,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => testManifest().toPreset(support.path),
      routerPort: () => 8080,
      managed: () => false,
    );
  });

  tearDown(() async {
    await hub.close();
    notifications.dispose();
    await settles.close();
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: SetupGate(child: Text('the app')),
      ),
    ));
    // Three bare pumps, not `pumpAndSettle`: the flow builds a downloader and
    // the first frame is a spinner, and settling on an indeterminate
    // indicator never returns.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a machine that has been set up goes straight through',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
    expect(find.text('Welcome to Bond'), findsNothing);
  });

  testWidgets('an empty store opens the wizard instead of the app',
      (tester) async {
    await makeContainer();

    await mount(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('Step 1 of 8'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('a database that cannot be read shows the wizard',
      (tester) async {
    // The recoverable answer, exactly as `AuthGate` treats an unreadable
    // keychain: the first step costs a click, and a launch that refused to
    // draw anything costs the app.
    await makeContainer(overStore: _UnreadableStore(db));

    await mount(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('a manifest bump reopens the wizard on the download step',
      (tester) async {
    // The stored word still says `done` and the file names have not changed,
    // so nothing downstream would ever notice that the weights on disk are
    // the previous checkpoint. The ledger is what notices.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger(bump: true);
    await makeContainer();

    await mount(tester);

    expect(find.text('the app'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Step 5 of 8'), findsOneWidget);
  });

  testWidgets('"Set up again" brings the wizard back over a running app',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();
    await mount(tester);
    expect(find.text('the app'), findsOneWidget);

    // What `restartSetup` does, in the order it does it: the key goes first,
    // because the gate re-reads the store the moment the counter moves.
    await restartSetupWith(
      store: store,
      restart: container.read(setupRestartProvider.notifier),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('a second run gets a fresh controller, not the first one\'s state',
      (tester) async {
    await makeContainer();
    await mount(tester);
    expect(find.text('Welcome to Bond'), findsOneWidget);

    // The LIVE controller: the mounted flow built it, so this is the instance
    // the wizard is running on rather than one this test woke up.
    final first = container.read(setupControllerProvider.notifier);

    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);

    await store.clearExcept(SetupStore.keptOnRestart);
    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Back at the top, on a controller of its own: a second run over the first
    // one's `SetupState` would open at the step the last run finished on.
    expect(find.text('Welcome to Bond'), findsOneWidget);
    final second = container.read(setupControllerProvider.notifier);
    expect(identical(first, second), isFalse);
    expect(container.read(setupControllerProvider).loaded, isTrue);
    expect(container.read(setupControllerProvider).step, SetupStep.welcome);
  });

  test('the skip define reads a value, not merely a presence', () {
    // QUICKSTART says `=1`, which is what nearly everybody writes. The three
    // refusals are here so that somebody turning the skip back OFF with `=0`
    // gets the wizard rather than the opposite of what they typed.
    expect(SetupGate.skipsSetup(''), isFalse);
    expect(SetupGate.skipsSetup('0'), isFalse);
    expect(SetupGate.skipsSetup('false'), isFalse);
    expect(SetupGate.skipsSetup('No'), isFalse);
    expect(SetupGate.skipsSetup(' FALSE '), isFalse);
    expect(SetupGate.skipsSetup('1'), isTrue);
    expect(SetupGate.skipsSetup('yes'), isTrue);
  });

  testWidgets('the counter alone does not un-set-up a machine',
      (tester) async {
    // The gate re-DECIDES on the counter; it does not assume the answer. A
    // bump with the key still saying `done` has to leave the app on screen.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();
    await mount(tester);

    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);
  });
}
