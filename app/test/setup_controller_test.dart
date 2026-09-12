import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/prefs_provider.dart' show AppPrefs;
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// Every byte sitting under [dir], parts included — what a folder that was
/// left behind must stop gaining.
int _bytesUnder(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return 0;
  var total = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) total += entity.lengthSync();
  }
  return total;
}

/// A store whose writes fail, for the one case that must not throw.
class _UnwritableStore extends SetupStore {
  _UnwritableStore(super.db);

  @override
  Future<void> set(String key, String value) async =>
      throw StateError('disk is read-only');
}

/// The first run, driven through its controller and nothing else.
///
/// Plain `test`, never `testWidgets`: every case here awaits a real socket and
/// a real file, and a fake-async zone would hang the run rather than fail it.
/// The temp directory, the hub and the supervisor are made in `setUp` for the
/// same reason.
void main() {
  late FakeHubServer hub;
  late Directory root;
  late BondDatabase db;
  late SetupStore store;
  late FakeSystemInfo system;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late FakeAuthSession auth;
  late FakeDesktopNotifier notifier;
  late ModelManifest manifest;
  late AppPrefs prefs;
  late bool managed;
  late List<bool> seeded;
  late List<String> foldersSet;

  String folder() => p.join(root.path, 'models');

  String destOf(ModelFile file) => p.join(folder(), file.relativePath);

  /// Fills the hub with deterministic bytes and returns a manifest whose
  /// sizes and digests describe exactly those bytes — `model_downloader_test`'s
  /// `publish()`, because this file downloads through the same seam.
  ModelManifest publish({
    int embed = 2048,
    int bulk = 4096,
    int prose = 8192,
    Map<String, int>? minRams,
  }) {
    final sizes = <String, int>{};
    final digests = <String, String>{};
    final base = testManifest();
    var seed = 1;
    for (final entry in <String, int>{
      routerEmbedId: embed,
      routerBulkId: bulk,
      routerProseId: prose,
    }.entries) {
      final file = base.byId(entry.key);
      final data = fakeWeights(entry.value, seed: seed++);
      hub.contents['${file.repo}/${file.file}'] = data;
      sizes[entry.key] = data.length;
      digests[entry.key] = sha256Hex(data);
    }
    return testManifest(sizes: sizes, sha256s: digests, minRams: minRams);
  }

  ModelDownloader buildDownloader() {
    final downloader = ModelDownloader(
      manifest: manifest,
      modelsFolder: folder,
      readLedger: store.downloadLedger,
      writeLedger: store.recordDownload,
      // Null makes every verify fall through to the Dart digest, which is
      // what a `flutter test` binary really gets.
      sha256: (_) async => null,
      resolveUri: hub.resolveUriFor,
      sleep: (_) async {},
      progressInterval: const Duration(milliseconds: 1),
      ledgerInterval: Duration.zero,
    );
    addTearDown(downloader.dispose);
    return downloader;
  }

  SetupController build({SetupStore? over, ModelDownloader? downloader}) {
    final controller = SetupController(
      store: over ?? store,
      system: system,
      manifest: manifest,
      downloader: downloader ?? buildDownloader(),
      supervisor: supervisor,
      paths: AppPaths(root),
      readPrefs: () => prefs,
      setManagedServer: (on) async {
        managed = on;
        prefs = prefs.copyWith(managedServer: on);
      },
      setModelsFolder: (path) async {
        foldersSet.add(path);
        prefs = prefs.copyWith(modelsFolder: path);
      },
      auth: () => auth,
      notifier: notifier,
      seedAuthorization: seeded.add,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// Polls until [ready], or gives up loudly. The controller's work is real
  /// sockets and real files, so there is nothing to settle — only to wait for.
  Future<void> waitUntil(
    bool Function() ready, {
    Duration timeout = const Duration(seconds: 20),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $reason');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A ledger and three files that say the whole set is already here.
  Future<void> seedComplete() async {
    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      final file = File(destOf(model));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(hub.contents['${model.repo}/${model.file}']!);
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256: model.sha256,
      ));
    }
    await store.recordDownload(ledger);
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    root = await Directory.systemTemp.createTemp('bond-setup');
    db = testDb();
    store = SetupStore(db);
    system = FakeSystemInfo();
    runner = FakeProcessRunner();
    auth = FakeAuthSession();
    notifier = FakeDesktopNotifier();
    managed = false;
    seeded = [];
    foldersSet = [];
    manifest = publish();
    prefs = AppPrefs(modelsFolder: folder());
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      // A binary that resolves, so a spawn that DID happen happened because
      // finish asked for it rather than because nothing was in the way.
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => manifest.toPreset(folder()),
      routerPort: () => 8080,
      managed: () => managed,
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    await hub.close();
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('an empty store opens the wizard at the top', () async {
    final controller = build();
    await controller.init();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.step, SetupStep.welcome);
    expect(controller.state.modelsFolder, folder());
    expect(controller.state.routerPort, 8080);
    expect(controller.state.migration, isNull);
    expect(controller.state.downloadsComplete, isFalse);
  });

  test('the migration record reaches the welcome step', () async {
    await store.set(
      SetupStore.containerMigrationKey,
      jsonEncode(const MigrationReport(
        attempted: true,
        migrated: true,
        from: '/old',
        copied: ['bond_inbox.db'],
      ).toJson()),
    );

    final controller = build();
    await controller.init();

    expect(controller.state.migration?.migrated, isTrue);
  });

  test('Continue writes the next step down before entering it', () async {
    final controller = build();
    await controller.init();

    await controller.next();

    expect(await store.get(SetupStore.setupKey), 'device');
    expect(controller.state.step, SetupStep.device);
    // Entering the device step is what asks the platform about the machine.
    expect(controller.state.hardware, isNotNull);
  });

  test('a store that cannot be written still moves the wizard on', () async {
    // A failed write costs a wizard that starts one step earlier next launch.
    // Throwing out of a button press would cost the whole screen.
    final controller = build(over: _UnwritableStore(db));
    await controller.init();

    await controller.next();

    expect(controller.state.step, SetupStep.device);
    expect(await store.get(SetupStore.setupKey), isNull);
  });

  test('an Intel Mac is blocked; Rosetta on Apple silicon is too', () async {
    system.hardwareInfo = const HardwareInfo(
      chip: 'Intel Core i9',
      memoryBytes: 34359738368,
      appleSilicon: false,
      rosetta: false,
      osVersion: '13.6',
    );
    final controller = build();
    await controller.init();
    await controller.next();

    expect(controller.deviceBlocked, isTrue);

    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 34359738368,
      appleSilicon: true,
      rosetta: true,
      osVersion: '15.6',
    );
    await controller.probeHardware();
    expect(controller.deviceBlocked, isTrue,
        reason: 'an x86_64 build under Rosetta gets no Metal backend either');
  });

  test('too little memory for the prose model warns, unknown memory does not',
      () async {
    manifest = publish(minRams: {routerProseId: 34359738368});
    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    final controller = build();
    await controller.init();
    await controller.next();

    expect(controller.deviceBlocked, isFalse);
    expect(controller.lowMemory, isTrue);

    // `HardwareInfo.unknown` reports zero bytes. A size check against zero
    // must not read as "this Mac is too small".
    system.hardwareInfo = HardwareInfo.unknown;
    await controller.probeHardware();
    expect(controller.lowMemory, isFalse);
  });

  test('the storage step asks the volume about the models folder', () async {
    system.free = 500 * 1024 * 1024 * 1024;
    await store.set(SetupStore.setupKey, SetupStep.storage.name);

    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.storage);
    expect(controller.state.disk, isNotNull);
    expect(controller.state.disk!.ok, isTrue);
    expect(controller.state.disk!.freeBytes, system.free);
    // Nothing is downloaded yet, so everything in the manifest is still to
    // come.
    expect(controller.state.disk!.neededBytes, manifest.totalBytes);
  });

  test('choosing a folder writes the preference and re-checks the volume',
      () async {
    system.free = 500 * 1024 * 1024 * 1024;
    await store.set(SetupStore.setupKey, SetupStep.storage.name);
    final controller = build();
    await controller.init();

    final other = p.join(root.path, 'elsewhere');
    await controller.setFolder(other);

    expect(foldersSet, [other]);
    expect(controller.state.modelsFolder, other);
    expect(controller.state.disk!.folder, other);
  });

  test('choosing another folder mid-download ends the run it was filling',
      () async {
    // The downloader reads the folder ONCE per run, so a transfer left going
    // would keep filling the folder the user has just left — gigabytes
    // nobody will use, under progress bars describing somewhere else.
    manifest = publish(embed: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    system.free = 500 * 1024 * 1024 * 1024;
    await store.set(SetupStore.setupKey, SetupStep.download.name);
    final downloader = buildDownloader();
    final controller = build(downloader: downloader);

    await controller.init();
    await waitUntil(
      () => (controller.state.downloads[routerEmbedId]?.receivedBytes ?? 0) > 0,
      reason: 'the first bytes into the old folder',
    );

    hub.chunkDelay = null;
    await controller.setFolder(p.join(root.path, 'elsewhere'));

    expect(controller.state.downloadRunning, isFalse);
    expect(controller.state.downloadPaused, isFalse);
    await waitUntil(() => !downloader.running, reason: 'the run to end');

    // And nothing more arrives in the folder that was left behind.
    final settled = _bytesUnder(folder());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(_bytesUnder(folder()), settled);
  });

  test('entering the download step runs it, and every file lands', () async {
    await store.set(SetupStore.setupKey, SetupStep.download.name);
    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.download);
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the run to finish',
    );

    expect(controller.state.downloadsComplete, isTrue);
    for (final model in manifest.models) {
      expect(
        controller.state.downloads[model.id]?.status,
        DownloadStatus.done,
        reason: model.id,
      );
      expect(File(destOf(model)).existsSync(), isTrue, reason: model.id);
    }
  });

  test('a set already on disk starts no run at all', () async {
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.download.name);

    final controller = build();
    await controller.init();

    expect(controller.state.downloadsComplete, isTrue);
    expect(controller.state.downloadRunning, isFalse);
    // The whole point: a relaunch after the download finished must not go
    // back to the hub to find out what it already knows.
    expect(hub.resolveCount, 0);
  });

  test('pause holds the run and resume finishes it', () async {
    manifest = publish(embed: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    await store.set(SetupStore.setupKey, SetupStep.download.name);
    final controller = build();

    var asked = false;
    var resumed = false;
    final remove = controller.addListener((state) {
      final embed = state.downloads[routerEmbedId];
      if (embed == null) return;
      if (!asked &&
          embed.status == DownloadStatus.downloading &&
          embed.receivedBytes > 0) {
        asked = true;
        hub.chunkDelay = null;
        unawaited(controller.pauseDownload());
      } else if (asked && !resumed && embed.status == DownloadStatus.paused) {
        resumed = true;
        unawaited(controller.resumeDownload());
      }
    });
    addTearDown(remove);

    await controller.init();
    await waitUntil(() => asked, reason: 'the first bytes');
    await waitUntil(() => resumed, reason: 'the paused event');
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the resumed run to finish',
    );

    expect(controller.state.downloadPaused, isFalse);
    expect(controller.state.downloadsComplete, isTrue);
  });

  test('cancel ends the run, and starting again completes it', () async {
    manifest = publish(embed: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    await store.set(SetupStore.setupKey, SetupStep.download.name);
    final downloader = buildDownloader();
    final controller = build(downloader: downloader);

    var cancelled = false;
    final remove = controller.addListener((state) {
      final embed = state.downloads[routerEmbedId];
      if (embed == null) return;
      if (!cancelled &&
          embed.status == DownloadStatus.downloading &&
          embed.receivedBytes > 0) {
        cancelled = true;
        hub.chunkDelay = null;
        unawaited(controller.cancelDownload());
      }
    });
    addTearDown(remove);

    await controller.init();
    await waitUntil(() => cancelled, reason: 'the first bytes');
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the cancelled run to end',
    );

    // A cancel is a "not now": the parts stay, and the set is not complete.
    expect(controller.state.downloadsComplete, isFalse);
    expect(downloader.running, isFalse);

    await controller.startDownload();
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the second run to finish',
    );
    expect(controller.state.downloadsComplete, isTrue);
  });

  test('the sign-in step probes the session, and a throw reads as signed out',
      () async {
    auth = FakeAuthSession(signedIn: true);
    await store.set(SetupStore.setupKey, SetupStep.signIn.name);
    final controller = build();
    await controller.init();

    expect(controller.state.signedIn, isTrue);

    auth = FakeAuthSession(throwOnProbe: true);
    await controller.probeSignIn();
    expect(controller.state.signedIn, isFalse);
  });

  test('the notifications step asks once, seeds the answer, and advances',
      () async {
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();

    await controller.continueFromNotifications();

    expect(notifier.authorizeCalls, 1);
    expect(seeded, [true]);
    expect(controller.state.notificationsGranted, isTrue);
    expect(controller.state.step, SetupStep.done);
  });

  test('a denial stays on the step once, then continues without re-asking',
      () async {
    notifier.authorized = false;
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();

    await controller.continueFromNotifications();

    // Still here, so the sentence about System Settings is read at least
    // once.
    expect(controller.state.step, SetupStep.notifications);
    expect(controller.state.notificationsGranted, isFalse);
    expect(seeded, [false]);

    await controller.continueFromNotifications();

    expect(controller.state.step, SetupStep.done);
    expect(notifier.authorizeCalls, 1, reason: 'asked once, not twice');
  });

  test('a platform with no notification centre is a seeded denial', () async {
    notifier.supported = false;
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();

    await controller.continueFromNotifications();

    expect(notifier.authorizeCalls, 0);
    expect(seeded, [false]);
    expect(controller.state.step, SetupStep.done);
  });

  test('a stored done resumes at the top rather than at the last screen',
      () async {
    // The gate never shows the flow for a store that says `done` AND a ledger
    // that matches — so arriving here that way means something else wrote it,
    // and the beginning is the honest place to put somebody.
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.welcome);
    // And there is nothing before it.
    await controller.back();
    expect(controller.state.step, SetupStep.welcome);
  });

  test('a stored done over a bumped manifest opens on the download step',
      () async {
    // The model-bump path. The word says the machine finished; the ledger
    // describes the checkpoint BEFORE this build's, so the weights on disk
    // are the old ones and the download step is where that gets put right.
    await seedComplete();
    final prose = manifest.byRole(ModelRole.prose);
    var stale = await store.downloadLedger();
    stale = stale.record(stale[prose.id]!.copyWith(sha256: 'f' * 64));
    await store.recordDownload(stale);
    await store.set(SetupStore.setupKey, SetupStep.done.name);

    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.download);
    expect(controller.state.downloadsComplete, isFalse);
    // And `_onEnter` started the transfer for what has moved.
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the bumped file to be fetched',
    );
    expect(controller.state.downloadsComplete, isTrue);
  });

  test('the done step names who is signed in', () async {
    auth = FakeAuthSession(signedIn: true);
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();

    await controller.continueFromNotifications();

    expect(controller.state.step, SetupStep.done);
    expect(controller.state.accountName, 'Jared');
  });

  test('arriving at All set records the step BEFORE it', () async {
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();

    await controller.next();

    expect(controller.state.step, SetupStep.done);
    // `done` is the gate's sentinel and only Finish may write it: a quit on
    // the All set screen would otherwise let the next launch straight past the
    // gate with the managed server still off. Notifications is where a
    // relaunch lands instead, one Continue from here.
    expect(await store.get(SetupStore.setupKey), 'notifications');

    expect(await controller.finish(), isTrue);
    expect(await store.get(SetupStore.setupKey), 'done');
  });

  test('a Finish that cannot be recorded stays put and says so', () async {
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build(over: _UnwritableStore(db));
    await controller.init();
    await controller.next();

    expect(await controller.finish(), isFalse);

    // The preference took and the word did not, which is a machine the gate
    // would still show the wizard to — so the screen stays, with something to
    // press again, and no server is asked for on a setup that is not saved.
    expect(controller.state.finishFailed, isTrue);
    expect(controller.state.finishing, isFalse);
    expect(await store.get(SetupStore.setupKey), 'notifications');
    expect(runner.starts, isEmpty);
  });

  test('Finish after a folder change restarts the server', () async {
    // The managed server already on and already up: the "Set up again" walk,
    // which is the only way to reach Finish with a server to bounce.
    await seedComplete();
    managed = true;
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();
    await supervisor.ensureRunning();
    expect(runner.starts.length, 1);

    await controller.setFolder(p.join(root.path, 'elsewhere'));
    await controller.finish();

    // `ensureRunning` returns at once on a server that is already up, so a
    // folder that moved would leave the router mmap'ing the copies in the old
    // one.
    await waitUntil(
      () => runner.starts.length == 2,
      reason: 'the server to be restarted',
    );
  });

  test('Finish after weights landed in this run restarts the server',
      () async {
    // The preset hash the supervisor compares covers paths and arguments, not
    // digests: a server still running over the files this run replaced looks
    // healthy to `ensureRunning`, and would go on answering from them.
    managed = true;
    await store.set(SetupStore.setupKey, SetupStep.download.name);
    final controller = build();
    await controller.init();
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the run to finish',
    );
    await supervisor.ensureRunning();
    expect(runner.starts.length, 1);

    await controller.finish();

    await waitUntil(
      () => runner.starts.length == 2,
      reason: 'the server to be restarted over the new weights',
    );
  });

  test('Finish with the folder unchanged leaves the running server alone',
      () async {
    await seedComplete();
    managed = true;
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();
    await supervisor.ensureRunning();
    expect(runner.starts.length, 1);

    await controller.finish();
    // Long enough for a restart to have shown up if one had been asked for.
    // Nothing moved, and a model that took a minute to load must not be
    // bounced for a preference that did not change.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(runner.starts.length, 1);
  });

  test('Finish turns the managed server on, records done, and starts it',
      () async {
    // The weights have to be there: the supervisor refuses to launch while
    // any file the preset names is missing, which is the same rule that makes
    // the download step wait for all three.
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final controller = build();
    await controller.init();

    await controller.finish();

    expect(managed, isTrue);
    expect(await store.get(SetupStore.setupKey), 'done');
    expect(controller.state.finishing, isFalse);
    // Fire-and-forget on `ServerBootstrap`'s reasoning, so the spawn lands
    // after the call returns.
    await waitUntil(
      () => runner.starts.isNotEmpty,
      reason: 'the server to be started',
    );
  });
}
