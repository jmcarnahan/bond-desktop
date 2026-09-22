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
    ModelPlacement placement = ModelPlacement.local,
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
      // preference rows: the placement is what decides the effective tier.
      initialAppPrefsProvider
          .overrideWithValue(AppPrefs(modelPlacement: placement)),
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

  test('three rows on a full Mac, each saying what it costs and where it is',
      () async {
    final manifest = testManifest();
    final embed = manifest.byRole(ModelRole.embed);
    final bulk = manifest.byRole(ModelRole.bulk);
    final prose = manifest.byRole(ModelRole.prose);
    await setup.recordDownload(
      DownloadLedger({embed.id: done(embed), bulk.id: done(bulk)}),
    );
    await write(embed);
    await write(bulk);

    final rows =
        await containerFor(manifest).read(managedModelsStatusProvider.future);

    expect([for (final row in rows) row.roleId], ['big', 'small', 'embed']);
    expect([for (final row in rows) row.routerId],
        [routerProseId, routerBulkId, routerEmbedId]);
    expect(rows[0].displayName, prose.displayName);
    expect(rows[0].bytes, prose.downloadBytes);
    // The writing model is in the manifest and not on this disk, which is what
    // a download that has not finished looks like.
    expect(rows[0].onDisk, isFalse);
    expect(rows[1].onDisk, isTrue);
    expect(rows[2].onDisk, isTrue);
    expect(rows[2].displayName, embed.displayName);
    // Managed serves everything this Mac's tier resolved.
    expect([for (final row in rows) row.inUse], [true, true, true]);
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

  test('a small Mac has two rows, and the big one names the model that writes',
      () async {
    final manifest = testManifest();
    final bulk = manifest.byRole(ModelRole.bulk);

    final rows = await containerFor(
      manifest,
      memoryBytes: 16 * 1024 * 1024 * 1024,
    ).read(managedModelsStatusProvider.future);

    expect([for (final row in rows) row.roleId], ['big', 'small', 'embed']);
    // The inbox tier downloads no writing model, so the big row describes the
    // model that does the writing there — the small one.
    expect(rows[0].displayName, bulk.displayName);
    expect(rows[1].displayName, bulk.displayName);
    // And the router id is the FILE's, not the role's: the preset for this
    // tier declares no writing model, so a big row keyed on the prose id
    // would never read as loaded.
    expect(rows[0].routerId, bulk.id);
    expect(rows[1].routerId, bulk.id);
    expect(rows[0].routerId, isNot(routerProseId));
    expect([for (final row in rows) row.inUse], [true, true, true]);
  });

  test('the user-defined placement lists all three and marks only the '
      'embedding row in use', () async {
    final manifest = testManifest();

    final rows = await containerFor(
      manifest,
      placement: ModelPlacement.box,
    ).read(managedModelsStatusProvider.future);

    // The two chat models run on somebody's server there, and their weights
    // are still on this disk: the rows stay, and `inUse` is what says the
    // router is not asked to hold them.
    expect([for (final row in rows) row.roleId], ['big', 'small', 'embed']);
    expect([for (final row in rows) row.inUse], [false, false, true]);
    expect(rows.last.routerId, routerEmbedId);
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
}
