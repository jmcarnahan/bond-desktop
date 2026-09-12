import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:bond_inbox/screens/setup/setup_flow.dart';
import 'package:bond_inbox/screens/setup/setup_gate.dart';
import 'package:bond_inbox/screens/setup/setup_welcome_body.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// "Set up again", and what it is careful NOT to throw away.
///
/// Starting the wizard over must not re-copy a mailbox that is already here
/// or re-download twenty-three gigabytes that already are: the migration
/// record and the download ledger both describe work that HAPPENED, and both
/// are still true on the way back through the flow.
void main() {
  late BondDatabase db;
  late SetupStore store;
  late Directory support;
  late ModelManifest manifest;
  late FakeSystemInfo system;
  late FakeAuthSession auth;
  late FakeDesktopNotifier notifier;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late StreamController<MessageSettled> settles;
  late DesktopNotificationService notifications;
  late ProviderContainer container;

  String folder() => p.join(support.path, 'models');

  /// The wizard's world, with the models already here — a ledger at this
  /// manifest's digests and three files on disk — so the walk is about the
  /// way back rather than about the downloader.
  void makeContainer() {
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      systemInfoProvider.overrideWithValue(system),
      modelServerSupervisorProvider.overrideWithValue(supervisor),
      authSessionProvider.overrideWithValue(auth),
      desktopNotifierProvider.overrideWithValue(notifier),
      desktopNotificationServiceProvider.overrideWithValue(notifications),
    ]);
    addTearDown(container.dispose);
  }

  setUp(() async {
    db = testDb();
    store = SetupStore(db);
    support = await Directory.systemTemp.createTemp('bond-reentry');
    manifest = testManifest();
    system = FakeSystemInfo()
      ..hardwareInfo = const HardwareInfo(
        chip: 'Apple M3 Max',
        memoryBytes: 68719476736,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      )
      ..free = 200 * 1024 * 1024 * 1024;
    auth = FakeAuthSession(signedIn: true);
    notifier = FakeDesktopNotifier();
    runner = FakeProcessRunner();
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
      buildPreset: () => manifest.toPreset(folder()),
      routerPort: () => 8080,
      managed: () => false,
    );

    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      final file = File(p.join(folder(), model.relativePath));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(model.sizeBytes, 7));
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256: model.sha256,
      ));
    }
    await store.recordDownload(ledger);
    makeContainer();
  });

  tearDown(() async {
    notifications.dispose();
    await settles.close();
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  /// Three bare pumps — the idiom wherever an indeterminate indicator can be
  /// on screen and `pumpAndSettle` would never return.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: SetupGate(child: Text('the inbox')),
      ),
    ));
    await settle(tester);
  }

  Future<void> setUpAgain(WidgetTester tester) async {
    await restartSetupWith(
      store: store,
      restart: container.read(setupRestartProvider.notifier),
    );
    await settle(tester);
  }

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(SetupFlow.continueKey));
    await tester.tap(find.byKey(SetupFlow.continueKey));
    await settle(tester);
  }

  test('the wizard bookkeeping goes, the expensive facts stay', () async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await store.set(SetupStore.containerMigrationKey, '{"migrated":true}');
    await store.set(SetupStore.downloadKey, '{"version":1,"files":{}}');
    await store.set('something_else', 'x');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);

    await restartSetupWith(store: store, restart: restart);

    final left = await store.all();
    expect(left.keys.toSet(), SetupStore.keptOnRestart);
    expect(left[SetupStore.containerMigrationKey], '{"migrated":true}');
    expect(left[SetupStore.downloadKey], '{"version":1,"files":{}}');
    // The third kept key is the one this press just wrote: the `done` it took
    // away, held so the welcome step can offer it back.
    expect(left[SetupStore.previousSetupKey], SetupStep.done.name);
    expect(left.containsKey(SetupStore.setupKey), isFalse);
    expect(left.containsKey('something_else'), isFalse);
  });

  test('the key is already gone by the time the counter moves', () async {
    // The ORDER is the point. The gate re-reads the store the moment the
    // counter changes, so a bump before the clear would race it and find the
    // key still saying `done` — the app on screen and no wizard.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);

    String? whenBumped = SetupStep.done.name;
    var bumps = 0;
    final remove = restart.addListener((_) async {
      bumps++;
      // Read from INSIDE the listener, which is where the gate reads it.
      whenBumped = await store.get(SetupStore.setupKey);
    }, fireImmediately: false);
    addTearDown(remove);

    await restartSetupWith(store: store, restart: restart);
    // The listener's own read is a future; let it land.
    await Future<void>.delayed(Duration.zero);

    expect(bumps, 1);
    expect(whenBumped, isNull);
  });

  test('the counter moves, which is what the gate is listening to', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);
    expect(container.read(setupRestartProvider), 0);

    await restartSetupWith(store: store, restart: restart);
    expect(container.read(setupRestartProvider), 1);

    // A counter rather than a flag: the interesting event is the CHANGE, and
    // a second restart has to be a second signal.
    await restartSetupWith(store: store, restart: restart);
    expect(container.read(setupRestartProvider), 2);
  });

  test('the widget-side entry point reaches the same two effects', () async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    await restartSetupWith(
      store: container.read(setupStoreProvider),
      restart: container.read(setupRestartProvider.notifier),
    );

    expect(await store.get(SetupStore.setupKey), isNull);
    expect(container.read(setupRestartProvider), 1);
  });

  testWidgets('Set up again stashes the done it took away, and offers it back',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await mount(tester);
    expect(find.text('the inbox'), findsOneWidget);

    await setUpAgain(tester);

    // The word the gate reads is gone, and the one the welcome step reads is
    // there in its place.
    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(await store.get(SetupStore.setupKey), isNull);
    expect(await store.get(SetupStore.previousSetupKey), SetupStep.done.name);
    expect(find.text('Back to the inbox'), findsOneWidget);

    await tester.tap(find.byKey(SetupWelcomeBody.returnToInboxKey));
    await settle(tester);

    // Put back rather than invented: the value this writes is the one the
    // store already held, and the offer is not standing next time.
    expect(await store.get(SetupStore.setupKey), SetupStep.done.name);
    expect(await store.get(SetupStore.previousSetupKey), isNull);
    expect(find.text('the inbox'), findsOneWidget);
  });

  testWidgets('a first run has no inbox behind it and no button to it',
      (tester) async {
    await mount(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('Back to the inbox'), findsNothing);
    expect(find.byKey(SetupWelcomeBody.returnToInboxKey), findsNothing);
    expect(await store.get(SetupStore.previousSetupKey), isNull);
  });

  testWidgets('a wizard that was never finished stashes nothing',
      (tester) async {
    // Half way through a first run, "Set up again" is a restart and not a
    // detour: there is no inbox behind it to go back to.
    await store.set(SetupStore.setupKey, SetupStep.storage.name);
    await mount(tester);

    await setUpAgain(tester);

    expect(await store.get(SetupStore.previousSetupKey), isNull);
    expect(find.text('Back to the inbox'), findsNothing);
  });

  testWidgets('finishing the second run leaves no stash behind',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await mount(tester);
    await setUpAgain(tester);
    expect(find.text('Back to the inbox'), findsOneWidget);

    // Welcome, Your Mac, Models, Storage, Download, Sign in, Notifications,
    // All set — eight presses, the last of them Finish.
    for (var step = 0; step < 8; step++) {
      await tapContinue(tester);
    }

    expect(find.text('the inbox'), findsOneWidget);
    expect(await store.get(SetupStore.setupKey), SetupStep.done.name);
    // A leftover would have the NEXT first run think it had an inbox behind
    // it.
    expect(await store.get(SetupStore.previousSetupKey), isNull);
  });
}
