import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/setup_provider.dart'
    show setupRestartProvider;
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// What the Managed block's three rows are made of: the resolved manifest, the
/// download ledger and the disk.
///
/// A `test` rather than a `testWidgets`, because the subject is a future over
/// a real folder and real files, and a fake-async zone would hang on the first
/// of them. The LIVE half of a row — whether the router has the model loaded —
/// is deliberately not here: it moves while somebody is looking at the page,
/// and the widget joins it from `serverStateProvider`.
void main() {
  late BondDatabase db;
  late Directory support;
  late Directory models;
  late SetupStore setup;

  /// A ledger row saying this file landed, at the digest the fixture names.
  FileDownloadState done(ModelFile file) => FileDownloadState(
        id: file.id,
        status: DownloadStatus.done,
        receivedBytes: file.sizeBytes,
        totalBytes: file.sizeBytes,
        sha256: file.sha256,
      );

  Future<void> write(ModelFile file) async {
    final path = File(p.join(models.path, file.relativePath));
    await path.parent.create(recursive: true);
    await path.writeAsString('gguf');
  }

  ProviderContainer containerFor(
    ModelManifest manifest, {
    AppPrefs prefs = const AppPrefs(modelPlacement: ModelPlacement.local),
    int memoryBytes = 64 * 1024 * 1024 * 1024,
  }) {
    final system = FakeSystemInfo()
      ..hardwareInfo = HardwareInfo(
        chip: 'Apple M2 Max',
        memoryBytes: memoryBytes,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      );
    final made = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      systemInfoProvider.overrideWithValue(system),
      // The prefs are handed over rather than read, so this test needs no
      // preference rows: the placements are what decide the served set.
      initialAppPrefsProvider.overrideWithValue(prefs),
    ]);
    addTearDown(made.dispose);
    return made;
  }

  setUp(() async {
    db = testDb();
    support = await Directory.systemTemp.createTemp('managed-status');
    models = Directory(p.join(support.path, 'models'));
    await models.create(recursive: true);
    setup = SetupStore(db);
  });

  tearDown(() async {
    await db.close();
    await support.delete(recursive: true);
  });

  test('three rows on a full Mac: decision, generative, embed', () async {
    final manifest = testManifest(withDecide: true);
    final embed = manifest.byRole(ModelRole.embed);
    final prose = manifest.byRole(ModelRole.prose);
    final decide = manifest.byRole(ModelRole.decide);
    await setup.recordDownload(DownloadLedger({embed.id: done(embed)}));
    await write(embed);

    final rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);

    expect([for (final row in rows) row.roleId],
        ['decision', 'generative', 'embed']);
    expect([for (final row in rows) row.routerId],
        [routerDecideId, routerProseId, routerEmbedId]);
    // The full tier's managed generative model is the 27B.
    expect(rows[1].displayName, prose.displayName);
    expect(rows[1].bytes, prose.downloadBytes);
    // The writing model is in the manifest and not on this disk, which is
    // what a download that has not finished looks like.
    expect(rows[1].onDisk, isFalse);
    expect(rows[2].onDisk, isTrue);
    expect(rows[2].displayName, embed.displayName);
    // The decision model is hand-installed: its size is the weights and the
    // heads, and it is not on disk until both are.
    expect(rows[0].local, isTrue);
    expect(rows[1].local, isFalse);
    expect(rows[0].bytes, decide.sizeBytes + decide.heads!.sizeBytes);
    expect(rows[0].onDisk, isFalse);
    // Managed serves all three roles here.
    expect([for (final row in rows) row.inUse], [true, true, true]);
  });

  test('the decision model is on disk when its GGUF AND heads are, with no '
      'ledger', () async {
    final manifest = testManifest(withDecide: true);
    final decide = manifest.byRole(ModelRole.decide);

    await write(decide);
    var rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);
    expect(rows.first.roleId, 'decision');
    expect(rows.first.onDisk, isFalse, reason: 'the heads are missing');
    expect(rows.first.headsOnDisk, isFalse);

    final heads = File(p.join(models.path, decide.headsRelativePath!));
    await heads.writeAsString('{}');
    rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);
    expect(rows.first.onDisk, isTrue);
    expect(rows.first.headsOnDisk, isTrue);
  });

  test('a ledger row over a file somebody deleted is not on disk', () async {
    final manifest = testManifest();
    final embed = manifest.byRole(ModelRole.embed);
    // The ledger says done, at today's digest, and the file is gone: a row is
    // not evidence, which is why the provider stats the path as well.
    await setup.recordDownload(DownloadLedger({embed.id: done(embed)}));

    final rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);

    expect(rows.last.roleId, 'embed');
    expect(rows.last.onDisk, isFalse);
  });

  test('a stale digest is not current, whatever the disk says', () async {
    final manifest = testManifest(sha256s: {routerEmbedId: 'b' * 64});
    final embed = manifest.byRole(ModelRole.embed);
    await write(embed);
    // The row the PREVIOUS manifest wrote: done, and against a digest this
    // build no longer asks for.
    await setup.recordDownload(DownloadLedger({
      embed.id: FileDownloadState(
        id: embed.id,
        status: DownloadStatus.done,
        sha256: 'a' * 64,
      ),
    }));

    final rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);

    expect(rows.last.onDisk, isFalse);
  });

  test('a small Mac\'s generative row is the 4B', () async {
    final manifest = testManifest();
    final bulk = manifest.byRole(ModelRole.bulk);

    final rows = await containerFor(
      manifest,
      memoryBytes: 16 * 1024 * 1024 * 1024,
    ).read(managedModelsStatusProvider.future);

    // No decide entry in this fixture, so two rows.
    expect([for (final row in rows) row.roleId], ['generative', 'embed']);
    expect(rows[0].displayName, bulk.displayName);
    // The router id is the FILE's, so the row finds its own loaded flag.
    expect(rows[0].routerId, bulk.id);
    expect([for (final row in rows) row.inUse], [true, true]);
  });

  test('the owner\'s choice of the 4B on a full Mac is the generative row',
      () async {
    final rows = await containerFor(
      testManifest(),
      prefs: const AppPrefs(
        modelPlacement: ModelPlacement.local,
        generativeManagedModel: routerBulkId,
      ),
    ).read(managedModelsStatusProvider.future);

    expect(rows.first.roleId, 'generative');
    expect(rows.first.routerId, routerBulkId);
  });

  test('a role on your server keeps its row and is not in use', () async {
    final rows = await containerFor(
      testManifest(withDecide: true),
      prefs: const AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxBigUrl: 'https://box.example.com/prose/v1/chat/completions',
        decisionPlacement: ModelPlacement.box,
        decisionUrl: 'https://box.example.com/decide/v1/embeddings',
      ),
    ).read(managedModelsStatusProvider.future);

    // The two models run on somebody's server there, and their weights are
    // still on this disk: the rows stay, and `inUse` is what says the router
    // is not asked to hold them.
    expect([for (final row in rows) row.roleId],
        ['decision', 'generative', 'embed']);
    expect([for (final row in rows) row.inUse], [false, false, true]);
    expect(rows.last.routerId, routerEmbedId);
  });

  test('your server with no address to dial is NOT this Mac', () async {
    // The placement cannot be honoured, and since the default-setup round
    // (decision D9) the role parks with a sentence rather than coming home:
    // the row stays, and the router is not asked to hold the model.
    final rows = await containerFor(
      testManifest(),
      prefs: const AppPrefs(modelPlacement: ModelPlacement.box),
    ).read(managedModelsStatusProvider.future);

    expect(rows.first.roleId, 'generative');
    expect(rows.first.inUse, isFalse);
  });

  test('Set up again re-reads it', () async {
    final manifest = testManifest();
    final embed = manifest.byRole(ModelRole.embed);
    final container = containerFor(manifest);

    final before = await container.read(managedModelsStatusProvider.future);
    expect(before.last.onDisk, isFalse);

    await setup.recordDownload(DownloadLedger({embed.id: done(embed)}));
    await write(embed);
    container.read(setupRestartProvider.notifier).state++;

    final after = await container.read(managedModelsStatusProvider.future);
    expect(after.last.onDisk, isTrue);
  });

  test('the served preset leaves out a chosen model that is not on disk, and '
      'embed and decide stay', () async {
    // A full Mac that downloaded embed + 27B and installed the decision
    // model, then chose the 4B: the preset the supervisor builds (the roles'
    // manifest through `withPresentFiles`) must not name the missing 4B, or
    // the router's preflight would stop embed and decide with it.
    final manifest = testManifest(withDecide: true);
    final decide = manifest.byRole(ModelRole.decide);
    await write(manifest.byRole(ModelRole.embed));
    await write(manifest.byRole(ModelRole.prose));
    await write(decide);
    await File(p.join(models.path, decide.headsRelativePath!))
        .writeAsString('{}');

    final container = containerFor(
      manifest,
      prefs: const AppPrefs(
        modelPlacement: ModelPlacement.local,
        generativeManagedModel: routerBulkId,
      ),
    );
    final served = await container.read(managedManifestProvider.future);
    expect([for (final m in served.models) m.id], contains(routerBulkId));

    final present = served.withPresentFiles(models.path);
    expect([for (final m in present.models) m.id],
        unorderedEquals([routerEmbedId, routerDecideId]));
    expect(present.toPreset(models.path).missingFiles(), isEmpty);

    // And the row the Models page reads still says the 4B is not here.
    final rows = await container.read(managedModelsStatusProvider.future);
    final generative = rows.firstWhere((r) => r.roleId == 'generative');
    expect(generative.routerId, routerBulkId);
    expect(generative.onDisk, isFalse);
    // A file with no heads record never reads as missing its heads.
    expect(generative.headsOnDisk, isTrue);
  });
}
