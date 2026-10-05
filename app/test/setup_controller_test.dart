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

/// A platform that refuses to describe the machine — the throw the startup
/// probe has to survive without costing the first frame.
class _RefusingSystemInfo extends FakeSystemInfo {
  @override
  Future<HardwareInfo> hardware() async => throw StateError('no channel');
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

  /// What `useGenerative(placement: box)` was called with, KEYS INCLUDED —
  /// this is a fake, the "keys" are the fictional strings the test typed,
  /// and nothing real is here.
  late List<
      ({
        String? url,
        String? model,
        String? key,
        bool clearKey,
        MachineTier hardwareTier,
      })> boxUses;

  /// What `useGenerative(placement: local)` was called with.
  late List<({ModelPlacement placement, MachineTier hardwareTier})>
      placementUses;

  /// The managed model each local generative write carried.
  late List<String?> managedUses;

  /// What `useDecision` was called with.
  late List<({ModelPlacement placement, String? url, String? model})>
      decisionUses;

  /// Set, and the generative box fake refuses with an `ArgumentError` instead
  /// of recording: the write the form would draw a sentence for.
  late bool boxRefuses;

  String folder() => p.join(root.path, 'models');

  String destOf(ModelFile file) => p.join(folder(), file.relativePath);

  /// Fills the hub with deterministic bytes and returns a manifest whose
  /// sizes and digests describe exactly those bytes — `model_downloader_test`'s
  /// `publish()`, because this file downloads through the same seam.
  ModelManifest publish({
    int embed = 2048,
    int bulk = 4096,
    int prose = 8192,
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
    return testManifest(sizes: sizes, sha256s: digests);
  }

  /// Serves the decision model's two files from the fake REGISTRY, puts the
  /// registry entry describing them into [manifest] beside what [publish]
  /// made, and returns it.
  ModelFile publishDecide() {
    const bundle = 'bond-decide-mbl-v3swap';
    final weights = fakeWeights(3072, seed: 31);
    final heads = fakeWeights(1024, seed: 32);
    hub.registryContents['$bundle/model-f16.gguf'] = weights;
    hub.registryContents['$bundle/heads.json'] = heads;
    final decide = testDecideFile(
      sizeBytes: weights.length,
      sha256: sha256Hex(weights),
      headsSizeBytes: heads.length,
      headsSha256: sha256Hex(heads),
    );
    manifest = testManifest(
      sizes: {for (final m in manifest.models) m.id: m.sizeBytes},
      sha256s: {for (final m in manifest.models) m.id: m.sha256},
      decide: decide,
    );
    return decide;
  }

  ModelDownloader buildDownloader({String Function()? registryBase}) {
    final downloader = ModelDownloader(
      manifest: manifest,
      modelsFolder: folder,
      registryBase: registryBase,
      registryToken: () => 'test-token-123',
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

  SetupController build({
    SetupStore? over,
    ModelDownloader? downloader,
    Future<void> Function(ModelServersPayload server)? checkDecision,
  }) {
    final controller = SetupController(
      store: over ?? store,
      system: system,
      manifest: manifest,
      downloader: downloader ?? buildDownloader(),
      supervisor: supervisor,
      paths: AppPaths(root),
      readPrefs: () => prefs,
      setModelsFolder: (path) async {
        foldersSet.add(path);
        prefs = prefs.copyWith(modelsFolder: path);
      },
      useGenerative: ({
        required placement,
        managedModel,
        url,
        model,
        key,
        clearKey = false,
        required hardwareTier,
      }) async {
        if (placement == ModelPlacement.box) {
          if (boxRefuses) throw ArgumentError('refused');
          boxUses.add((
            url: url,
            model: model,
            key: key,
            clearKey: clearKey,
            hardwareTier: hardwareTier,
          ));
        } else {
          placementUses.add((placement: placement, hardwareTier: hardwareTier));
          managedUses.add(managedModel);
        }
        prefs = prefs.copyWith(modelPlacement: placement);
      },
      useDecision: ({
        required placement,
        url,
        model,
        key,
        clearKey = false,
      }) async {
        decisionUses.add((placement: placement, url: url, model: model));
        prefs = prefs.copyWith(decisionPlacement: placement);
      },
      checkDecision: checkDecision,
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

  /// A ledger and the files that say THIS MACHINE's hub set is already here
  /// — three on the full tier, two on the inbox one. A registry entry is
  /// left out: the cases about it seed it themselves.
  Future<void> seedComplete() async {
    var ledger = DownloadLedger.empty;
    // Every file this Mac's TIER holds, the unchosen generative model
    // included: a set that is complete for any choice.
    final wanted =
        manifest.forTier(machineTierFor(system.hardwareInfo.memoryBytes));
    for (final model in wanted.models) {
      if (model.isRegistry) continue;
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
    boxUses = [];
    placementUses = [];
    managedUses = [];
    decisionUses = [];
    boxRefuses = false;
    manifest = publish();
    // This Mac, said out loud: the generative placement defaults to Your
    // server since the default-setup round, and most of this file is about
    // what this Mac downloads. The defaults test below reads the bare one.
    prefs = AppPrefs(
      modelsFolder: folder(),
      modelPlacement: ModelPlacement.local,
    );
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      // A binary that resolves, so a spawn that DID happen happened because
      // finish asked for it rather than because nothing was in the way.
      binaryPath: () => '/usr/bin/true',
      // What the app's own supervisor serves: the roles' manifest on this
      // Mac's tier, both roles here.
      buildPreset: () {
        final tier = machineTierFor(system.hardwareInfo.memoryBytes);
        return manifest
            .forRoles(
              hardwareTier: tier,
              decisionManaged: true,
              generativeManagedId: managedGenerativeIdFor(tier, ''),
            )
            .toPreset(folder());
      },
      routerPort: () => 8080,
      onPortMoved: (_) async {},
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
    expect(controller.tier, MachineTier.inbox);
    // 16 GiB is the floor itself, not below it.
    expect(controller.underMeasuredFloor, isFalse);

    // `HardwareInfo.unknown` reports zero bytes. A size check against zero
    // must not read as "this Mac is too small".
    system.hardwareInfo = HardwareInfo.unknown;
    await controller.probeHardware();
    expect(controller.lowMemory, isFalse);
    expect(controller.tier, MachineTier.full);
    expect(controller.underMeasuredFloor, isFalse);
  });

  test('a platform that refuses to answer leaves the wizard on the full tier',
      () async {
    // `init` awaits the machine before it reads the ledger, so this await is
    // on the path to the first frame. It neither throws nor waits: a channel
    // that refuses is the same answer as one that reports nothing, which is
    // `HardwareInfo.unknown` and therefore the full tier.
    system = _RefusingSystemInfo();
    final controller = build();

    await controller.init();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.step, SetupStep.welcome);
    expect(controller.state.hardware, HardwareInfo.unknown);
    expect(controller.tier, MachineTier.full);
    expect(controller.deviceBlocked, isFalse);
    expect(controller.lowMemory, isFalse);
  });

  test('the tier follows the memory, and the manifest follows the tier',
      () async {
    final controller = build();
    await controller.init();

    // Unknown memory is the full tier: nothing is refused for a fact the app
    // could not read, and the 27B is the managed generative model. The 4B is
    // not downloaded beside it: one generative model runs, and the files are
    // the roles' (the embedding model and the chosen generative one).
    expect(controller.tier, MachineTier.full);
    expect(
      [for (final m in controller.resolvedManifest.models) m.id],
      [routerEmbedId, routerProseId],
    );

    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 8589934592,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    await controller.probeHardware();

    expect(controller.tier, MachineTier.inbox);
    expect(controller.underMeasuredFloor, isTrue);
    expect(
      [for (final m in controller.resolvedManifest.models) m.id],
      [routerEmbedId, routerBulkId],
    );
    // The inbox tier's own arguments, merged onto the entry's.
    expect(
      controller.resolvedManifest.byId(routerBulkId).serverArgs['parallel'],
      '2',
    );
  });

  test('an inbox Mac is preflighted, downloaded and gated on two files',
      () async {
    system.free = 500 * 1024 * 1024 * 1024;
    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    await store.set(SetupStore.setupKey, SetupStep.storage.name);
    final controller = build();
    await controller.init();

    // The writing model is not in the number the storage step quotes.
    final inbox = manifest.forTier(MachineTier.inbox);
    expect(controller.state.disk!.neededBytes, inbox.totalBytes);
    expect(inbox.totalBytes, lessThan(manifest.totalBytes));

    await controller.next();
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the inbox set to arrive',
    );

    // Two bars, two files on disk, and Continue granted without the third.
    expect(controller.state.downloads.keys.toSet(),
        {routerEmbedId, routerBulkId});
    expect(controller.state.downloadsComplete, isTrue);
    expect(File(destOf(manifest.byRole(ModelRole.prose))).existsSync(),
        isFalse);
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
    // Nothing is downloaded yet, so every file this install downloads is
    // still to come: the embedding model and the 27B on the full tier.
    expect(controller.state.disk!.neededBytes,
        controller.resolvedManifest.totalBytes);
    expect(
      controller.resolvedManifest.totalBytes,
      manifest.byId(routerEmbedId).downloadBytes +
          manifest.byId(routerProseId).downloadBytes,
    );
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
    for (final model in controller.resolvedManifest.models) {
      expect(
        controller.state.downloads[model.id]?.status,
        DownloadStatus.done,
        reason: model.id,
      );
      expect(File(destOf(model)).existsSync(), isTrue, reason: model.id);
    }
    // The generative model this Mac does not run is not fetched.
    expect(controller.state.downloads[routerBulkId], isNull);
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

  test('the download step fetches the registry decision model with its heads, '
      'and the set is complete only once both are here', () async {
    final decide = publishDecide();
    await store.set(SetupStore.setupKey, SetupStep.download.name);

    final controller = build(
      downloader: buildDownloader(registryBase: () => hub.registryBase),
    );
    await controller.init();
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the run to finish',
    );

    expect(controller.state.downloads[routerDecideId]?.status,
        DownloadStatus.done);
    expect(File(destOf(decide)).existsSync(), isTrue);
    final heads = File(p.join(folder(), decide.headsRelativePath!));
    expect(heads.existsSync(), isTrue);
    expect(controller.state.downloadsComplete, isTrue);
    expect(hub.registryAuth, everyElement('Bearer test-token-123'));

    // The heads file is part of "every file here": gone, the set is not
    // complete, though the ledger still vouches for it.
    await heads.delete();
    await controller.setFolder(folder());
    expect(controller.state.downloadsComplete, isFalse);
  });

  // Phase 2 records today's wizard rule rather than D7's: a FAILED registry
  // file leaves `downloadsComplete` false, which is what holds the download
  // step's Continue. Phase 3 makes Continue wait only for gating rows.
  test('today a failed registry file leaves the set incomplete', () async {
    publishDecide();
    await store.set(SetupStore.setupKey, SetupStep.download.name);

    final controller = build(
      downloader: buildDownloader(registryBase: () => ''),
    );
    await controller.init();
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the run to finish',
    );

    final decide = controller.state.downloads[routerDecideId];
    expect(decide?.status, DownloadStatus.failed);
    expect(decide?.error, DownloadError.registryNotConfigured);
    expect(controller.state.downloads[routerEmbedId]?.status,
        DownloadStatus.done);
    expect(hub.registryCount, 0);
    expect(controller.state.downloadsComplete, isFalse);
  });

  test('a stored done whose only gap is the registry decision model resumes '
      'at the top, not on the download step', () async {
    // Decision D7: the ledger check that sends a finished install back to
    // the download step reads the GATING entries only.
    publishDecide();
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.done.name);

    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.welcome);
    expect(hub.registryCount, 0);
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

  test('a stored done on an inbox Mac is not sent back for the third file',
      () async {
    // The machine is asked BEFORE the ledger is read. A resume that assumed
    // the full tier would compare a two-file ledger against three checkpoints,
    // decide the set was stale and open the download step for a writing model
    // this Mac is never going to start.
    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.done.name);

    final controller = build();
    await controller.init();

    expect(controller.state.hardware, isNotNull);
    expect(controller.tier, MachineTier.inbox);
    expect(controller.state.step, SetupStep.welcome);
    expect(controller.state.downloadsComplete, isTrue);
  });

  test('Finish writes this machine tier defaults before the server starts',
      () async {
    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();
    await controller.next();

    expect(await controller.finish(), isTrue);

    // The generative model comes home on this Mac's tier, written once,
    // before the stored word that lets the gate past.
    expect(placementUses,
        [(placement: ModelPlacement.local, hardwareTier: MachineTier.inbox)]);
  });

  test('Finish on a full Mac applies the full tier', () async {
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();
    await controller.next();

    expect(await controller.finish(), isTrue);

    expect(placementUses,
        [(placement: ModelPlacement.local, hardwareTier: MachineTier.full)]);
  });

  group('Where the models run', () {
    test('the box placement drops the chat model from the downloads', () async {
      // A big Mac, so the tier is `full` whatever the placement. What the
      // placement moves is what this Mac SERVES: with the generative model
      // on the owner's server, the models, storage and download steps are
      // about the embedding model (and a hand-installed decision model, which
      // is never downloaded and so never listed).
      final controller = build();
      await controller.init();
      expect(controller.tier, MachineTier.full);
      expect([for (final m in controller.resolvedManifest.models) m.id],
          [routerEmbedId, routerProseId]);

      controller.chooseBox();

      expect(controller.tier, MachineTier.full);
      expect([for (final m in controller.resolvedManifest.models) m.id],
          [routerEmbedId]);
      // And `lowMemory` still answers about the MACHINE, which is what the
      // device step's sentence is about.
      expect(controller.lowMemory, isFalse);
    });

    test('a small Mac on the box is still a small Mac to the device step',
        () async {
      system.hardwareInfo = const HardwareInfo(
        chip: 'Apple M2',
        memoryBytes: 17179869184,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      );
      final controller = build();
      await controller.init();
      await controller.probeHardware();
      expect(controller.lowMemory, isTrue);

      controller.chooseBox();

      expect(controller.tier, MachineTier.inbox);
      // Unchanged: the writing model is still one this Mac could not run.
      expect(controller.lowMemory, isTrue);
    });

    test('Continue on Your server hands the server and the key to '
        'useGenerative with this Mac\'s tier and moves on', () async {
      final controller = build();
      await controller.init();
      controller.chooseBox();

      // The form is what refuses, probes and discovers; a press that reaches
      // here with nothing to write is a bug rather than a state.
      await controller.continueFromWhere();
      expect(boxUses, isEmpty);
      expect(controller.state.step, SetupStep.welcome);

      await controller.continueFromWhere(
        generative: (
          url: 'https://box.example.com/prose/v1/chat/completions',
          model: 'qwen3.8',
          key: 'sk-fixture-not-a-real-box-key',
          clearKey: false,
        ),
      );

      expect(boxUses, [
        (
          url: 'https://box.example.com/prose/v1/chat/completions',
          model: 'qwen3.8',
          key: 'sk-fixture-not-a-real-box-key',
          clearKey: false,
          hardwareTier: MachineTier.full,
        )
      ]);
      // The decision model stays on this Mac, and that is written too.
      expect(decisionUses.single.placement, ModelPlacement.local);
      expect(controller.state.step, SetupStep.models);
      expect(await store.get(SetupStore.setupKey), 'models');
    });

    test('Continue on this Mac uses the LOCAL placement and moves on',
        () async {
      final controller = build();
      await controller.init();

      controller.chooseLocal();
      await controller.continueFromWhere();

      expect(boxUses, isEmpty);
      // Not nothing: the write is what moves a box install back here, and on
      // a first run it is the same no-op `finish()` was going to make anyway.
      expect(placementUses,
          [(placement: ModelPlacement.local, hardwareTier: MachineTier.full)]);
      expect(decisionUses.single.placement, ModelPlacement.local);
      expect(controller.state.step, SetupStep.models);
    });

    test('the defaults are the stored answers: decision here, generative on '
        'Your server', () async {
      // Nothing stored: the decision model on this Mac, the generative model
      // on Your server whatever the build (decision D9).
      prefs = AppPrefs(modelsFolder: folder());
      final controller = build();
      await controller.init();
      expect(controller.state.decisionPlacement, ModelPlacement.local);
      expect(controller.placement, ModelPlacement.box);

      prefs = prefs.copyWith(
        modelPlacement: ModelPlacement.local,
        decisionPlacement: ModelPlacement.box,
      );
      final again = build();
      await again.init();
      expect(again.placement, ModelPlacement.local);
      expect(again.state.decisionPlacement, ModelPlacement.box);
    });

    test('the managed choice rides the local write, and the 27B is refused '
        'on the inbox tier', () async {
      final controller = build();
      await controller.init();
      controller.chooseLocal();
      controller.chooseGenerativeManaged(routerBulkId);
      expect([for (final m in controller.resolvedManifest.models) m.id],
          [routerEmbedId, routerBulkId]);

      await controller.continueFromWhere();
      expect(managedUses, [routerBulkId]);

      system.hardwareInfo = const HardwareInfo(
        chip: 'Apple M2',
        memoryBytes: 17179869184,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      );
      final small = build();
      await small.init();
      await small.probeHardware();
      small.chooseGenerativeManaged(routerProseId);
      expect(small.state.generativeManaged, '');
    });

    test('a newly chosen managed model is downloaded', () async {
      // A full Mac whose 27B is already here chooses the 4B: the download
      // set now names the 4B, so the download step fetches it.
      final controller = build();
      await controller.init();
      controller.chooseGenerativeManaged(routerBulkId);
      expect(
        controller.resolvedManifest.models.map((m) => m.id),
        contains(routerBulkId),
      );
      expect(
        controller.resolvedManifest.models.map((m) => m.id),
        isNot(contains(routerProseId)),
      );
    });

    test('the decision form connects its role at once and stays', () async {
      final controller = build();
      await controller.init();
      controller.chooseDecision(ModelPlacement.box);

      await controller.connectDecision((
        url: 'https://box.example.com/decide/v1/embeddings',
        model: 'bond-decide-x',
        key: null,
        clearKey: false,
      ));

      expect(decisionUses, [
        (
          placement: ModelPlacement.box,
          url: 'https://box.example.com/decide/v1/embeddings',
          model: 'bond-decide-x',
        )
      ]);
      expect(controller.state.step, SetupStep.welcome);

      controller.chooseLocal();
      await controller.continueFromWhere();
      // Your server stays: no local decision write on the way forward.
      expect(decisionUses, hasLength(1));
      expect(controller.state.step, SetupStep.models);
    });

    test('a decision server that is not the decision model is refused before '
        'anything is written', () async {
      final checked = <ModelServersPayload>[];
      final controller = build(checkDecision: (server) async {
        checked.add(server);
        throw ArgumentError('not the decision model');
      });
      await controller.init();
      controller.chooseDecision(ModelPlacement.box);

      await expectLater(
        controller.connectDecision((
          url: 'http://127.0.0.1:8081/v1/embeddings',
          model: 'bond-embed',
          key: null,
          clearKey: false,
        )),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', 'not the decision model')),
      );
      expect(checked.single.model, 'bond-embed');
      expect(decisionUses, isEmpty);
    });

    test('Your server for the decision model, not yet connected, refuses the '
        'way forward and writes nothing', () async {
      final controller = build();
      await controller.init();
      controller.chooseDecision(ModelPlacement.box);
      controller.chooseLocal();

      await expectLater(
        controller.continueFromWhere(),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          SetupController.decisionFirstText,
        )),
      );
      expect(placementUses, isEmpty);
      expect(decisionUses, isEmpty);
      expect(controller.state.step, SetupStep.welcome);
    });

    test('a hand-installed decision model on this Mac is listed apart from '
        'the downloads', () async {
      manifest = testManifest(
        sizes: {for (final m in manifest.models) m.id: m.sizeBytes},
        sha256s: {for (final m in manifest.models) m.id: m.sha256},
        decide: testLocalDecideFile(),
      );
      final controller = build();
      await controller.init();
      expect(
        controller.resolvedManifest.models.map((m) => m.role),
        isNot(contains(ModelRole.decide)),
      );
      expect(controller.localDecisionModel?.isLocal, isTrue);
      expect(controller.decisionInstalled, isFalse);
      final decide = controller.localDecisionModel!;
      for (final relative in [decide.relativePath, decide.headsRelativePath!]) {
        final file = File(p.join(folder(), relative));
        await file.parent.create(recursive: true);
        await file.writeAsString('x');
      }
      expect(controller.decisionInstalled, isTrue);
      // On Your server it is not listed at all.
      controller.chooseDecision(ModelPlacement.box);
      expect(controller.localDecisionModel, isNull);
      expect(controller.decisionInstalled, isFalse);
    });

    test('the registry decision model on this Mac is an ordinary download, '
        'counted in the total', () async {
      final decide = publishDecide();
      final controller = build();
      await controller.init();

      // Not listed apart: it is in the downloads.
      expect(controller.localDecisionModel, isNull);
      expect(controller.resolvedManifest.byId(routerDecideId), decide);
      expect(
        controller.resolvedManifest.totalBytes,
        greaterThanOrEqualTo(decide.sizeBytes + decide.heads!.sizeBytes),
      );
      final withoutDecide = controller.resolvedManifest.totalBytes -
          decide.downloadBytes;
      controller.chooseDecision(ModelPlacement.box);
      expect(controller.resolvedManifest.totalBytes, withoutDecide);
      expect(controller.localDecisionModel, isNull);
    });

    test('a user-defined install re-run choosing This Mac ends up local',
        () async {
      prefs = prefs.copyWith(modelPlacement: ModelPlacement.box);
      await store.set(SetupStore.setupKey, SetupStep.notifications.name);
      final controller = build();
      await controller.init();

      expect(controller.placement, ModelPlacement.box);
      expect(controller.tier, MachineTier.full);

      controller.chooseLocal();
      await controller.continueFromWhere();

      expect(placementUses,
          [(placement: ModelPlacement.local, hardwareTier: MachineTier.full)]);
      expect(controller.placement, ModelPlacement.local);
      expect(controller.state.step, SetupStep.models);
    });

    test('the tier the local write is given is the HARDWARE tier', () async {
      system.hardwareInfo = const HardwareInfo(
        chip: 'Apple M2',
        memoryBytes: 17179869184,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      );
      prefs = prefs.copyWith(modelPlacement: ModelPlacement.box);
      final controller = build();
      await controller.init();

      controller.chooseLocal();
      await controller.continueFromWhere();

      expect(placementUses,
          [(placement: ModelPlacement.local, hardwareTier: MachineTier.inbox)]);
    });

    test('a null key passes through as null, which the writer reads as keep, '
        'and clearKey rides along', () async {
      final controller = build();
      await controller.init();
      controller.chooseBox();

      await controller.continueFromWhere(
        generative: (
          url: 'https://other.example.com/v1/chat/completions',
          model: 'qwen3.8',
          key: null,
          clearKey: true,
        ),
      );

      expect(boxUses.single.key, isNull);
      expect(boxUses.single.clearKey, isTrue);
      expect(controller.state.step, SetupStep.models);
    });

    test('a generative write that throws leaves the step where it is',
        () async {
      boxRefuses = true;
      final controller = build();
      await controller.init();
      controller.chooseBox();

      await expectLater(
        controller.continueFromWhere(
          generative: (
            url: 'https://box.example.com/prose/v1/chat/completions',
            model: 'qwen3.8',
            key: null,
            clearKey: false,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(boxUses, isEmpty);
      expect(controller.state.step, SetupStep.welcome);
      expect(await store.get(SetupStore.setupKey), isNull);
    });

    test('Finish on the box placement leaves the generative placement alone',
        () async {
      await seedComplete();
      await store.set(SetupStore.setupKey, SetupStep.notifications.name);
      final controller = build();
      await controller.init();
      controller.chooseBox();
      await controller.next();

      expect(await controller.finish(), isTrue);

      // The form's own press wrote the user-defined adoption; Finish must not
      // move the generative model back to this Mac on top of it.
      expect(placementUses, isEmpty);
    });
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

  test('Finish after a placement change restarts the server onto the new set',
      () async {
    // The other half of the same rule: the folder did not move and nothing
    // was downloaded, but the PLACEMENT did, and the router is still holding
    // the two chat models a user-defined install has no use for.
    await seedComplete();
    managed = true;
    var generativeHere = true;
    final earlier = supervisor;
    addTearDown(earlier.dispose);
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      binaryPath: () => '/usr/bin/true',
      // What the placement asks this Mac for, which is what the wizard's box
      // step moves.
      buildPreset: () => manifest
          .forRoles(
            hardwareTier: MachineTier.full,
            decisionManaged: true,
            generativeManagedId: generativeHere ? routerProseId : null,
          )
          .toPreset(folder()),
      routerPort: () => 8080,
      onPortMoved: (_) async {},
      managed: () => managed,
    );
    await store.set(SetupStore.setupKey, SetupStep.notifications.name);
    final controller = build();
    await controller.init();
    await supervisor.ensureRunning();
    expect(runner.starts.length, 1);

    controller.chooseBox();
    generativeHere = false;
    await controller.finish();

    await waitUntil(
      () => runner.starts.length == 2,
      reason: 'the server to be restarted onto the embedding model alone',
    );
    // Onto the RIGHT set: the preset the second start wrote names the
    // embedding model and neither chat model.
    final written = await supervisor.presetFile.readAsString();
    expect(written, contains('[$routerEmbedId]'));
    expect(written, isNot(contains('[$routerProseId]')));
    expect(written, isNot(contains('[$routerBulkId]')));
  });

  test('Finish records done and starts the server', () async {
    // The weights have to be there: the supervisor refuses to launch while
    // any file the preset names is missing, which is the same rule that makes
    // the download step wait for all three.
    await seedComplete();
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    // On in a normal build: the define decides, and the supervisor's closure
    // is how this suite says so.
    managed = true;
    final controller = build();
    await controller.init();

    await controller.finish();

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
