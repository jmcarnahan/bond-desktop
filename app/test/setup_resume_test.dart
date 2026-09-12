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
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// What a relaunch mid-setup does.
///
/// The download is the case that matters: it runs for an hour, the user is
/// told they may quit, and the promise only holds if the next launch lands on
/// the same screen and picks the same file up. Plain `test`, for
/// `setup_controller_test`'s reason — real sockets, real files.
void main() {
  late FakeHubServer hub;
  late Directory root;
  late BondDatabase db;
  late SetupStore store;
  late ModelManifest manifest;
  late ModelServerSupervisor supervisor;
  late FakeProcessRunner runner;

  String folder() => p.join(root.path, 'models');

  String destOf(ModelFile file) => p.join(folder(), file.relativePath);

  ModelManifest publish() {
    final base = testManifest();
    final sizes = <String, int>{};
    final digests = <String, String>{};
    var seed = 1;
    for (final entry in <String, int>{
      routerEmbedId: 2048,
      routerBulkId: 4096,
      routerProseId: 8192,
    }.entries) {
      final file = base.byId(entry.key);
      final data = fakeWeights(entry.value, seed: seed++);
      hub.contents['${file.repo}/${file.file}'] = data;
      sizes[entry.key] = data.length;
      digests[entry.key] = sha256Hex(data);
    }
    return testManifest(sizes: sizes, sha256s: digests);
  }

  SetupController build({FakeAuthSession? auth}) {
    final downloader = ModelDownloader(
      manifest: manifest,
      modelsFolder: folder,
      readLedger: store.downloadLedger,
      writeLedger: store.recordDownload,
      sha256: (_) async => null,
      resolveUri: hub.resolveUriFor,
      sleep: (_) async {},
      progressInterval: const Duration(milliseconds: 1),
      ledgerInterval: Duration.zero,
    );
    addTearDown(downloader.dispose);
    final controller = SetupController(
      store: store,
      system: FakeSystemInfo(),
      manifest: manifest,
      downloader: downloader,
      supervisor: supervisor,
      paths: AppPaths(root),
      readPrefs: () => AppPrefs(modelsFolder: folder()),
      setManagedServer: (_) async {},
      setModelsFolder: (_) async {},
      auth: () => auth ?? FakeAuthSession(),
      notifier: FakeDesktopNotifier(),
      seedAuthorization: (_) {},
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> waitUntil(bool Function() ready, {String reason = ''}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    root = await Directory.systemTemp.createTemp('bond-resume');
    db = testDb();
    store = SetupStore(db);
    manifest = publish();
    runner = FakeProcessRunner();
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: root,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => manifest.toPreset(folder()),
      routerPort: () => 8080,
      managed: () => false,
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    await hub.close();
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('a launch mid-download resumes the step and fetches only what is left',
      () async {
    // One file already here, ledger and all — the state a quit halfway
    // through leaves behind.
    final embed = manifest.byId(routerEmbedId);
    final file = File(destOf(embed));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(hub.contents['${embed.repo}/${embed.file}']!);
    await store.recordDownload(DownloadLedger.empty.record(FileDownloadState(
      id: embed.id,
      status: DownloadStatus.done,
      receivedBytes: embed.sizeBytes,
      totalBytes: embed.sizeBytes,
      sha256: embed.sha256,
    )));
    await store.set(SetupStore.setupKey, SetupStep.download.name);

    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.download);
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the resumed run to finish',
    );

    expect(controller.state.downloadsComplete, isTrue);
    // The finished file was never asked for again: two resolves, not three.
    expect(hub.resolveCount, 2);
    for (final model in manifest.models) {
      expect(File(destOf(model)).existsSync(), isTrue, reason: model.id);
    }
  });

  test('a quit mid-FILE resumes at the byte the part stopped on', () async {
    // The promise the download step makes out loud — "you can quit" — is
    // about a file that was half here, not about a file that was finished.
    // A `.part` and a paused row are what that really leaves behind.
    const partLen = 700;
    final embed = manifest.byId(routerEmbedId);
    final part = File('${destOf(embed)}${ModelDownloader.partSuffix}');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(
      hub.contents['${embed.repo}/${embed.file}']!.sublist(0, partLen),
    );
    await store.recordDownload(DownloadLedger.empty.record(FileDownloadState(
      id: embed.id,
      status: DownloadStatus.paused,
      receivedBytes: partLen,
      totalBytes: embed.sizeBytes,
      sha256: embed.sha256,
    )));
    await store.set(SetupStore.setupKey, SetupStep.download.name);

    final controller = build();
    await controller.init();

    expect(controller.state.step, SetupStep.download);
    await waitUntil(
      () => !controller.state.downloadRunning,
      reason: 'the resumed run to finish',
    );

    expect(controller.state.downloadsComplete, isTrue);
    // Exactly one ranged request, for exactly the bytes that were missing:
    // the other two files are fresh and ask for no range at all.
    expect(hub.cdnRanges.where((r) => r != null).toList(), ['bytes=$partLen-']);
    expect(
      File(destOf(embed)).readAsBytesSync(),
      hub.contents['${embed.repo}/${embed.file}'],
    );
  });

  test('a launch on the sign-in step lands there with the session probed',
      () async {
    await store.set(SetupStore.setupKey, SetupStep.signIn.name);

    final auth = FakeAuthSession(signedIn: true);
    final controller = build(auth: auth);
    await controller.init();

    expect(controller.state.step, SetupStep.signIn);
    expect(controller.state.signedIn, isTrue);
    expect(auth.signInProbes, 1);
  });
}
