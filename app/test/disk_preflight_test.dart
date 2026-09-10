import 'dart:io';

import 'package:bond_inbox/services/models/disk_preflight.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_system_info.dart';
import 'fixtures/test_manifest.dart';

void main() {
  late FakeSystemInfo system;
  late Directory root;
  late ModelManifest manifest;

  // 1 KiB + 4 KiB + 16 KiB, from the fixture.
  const int wholeSet = 1024 + 4096 + 16384;

  setUp(() async {
    system = FakeSystemInfo();
    root = await Directory.systemTemp.createTemp('disk-preflight');
    manifest = testManifest();
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  String folder() => p.join(root.path, 'models');

  Future<void> writePart(String id, int length) async {
    final file = manifest.byId(id);
    final path = '${p.join(folder(), file.relativePath)}.part';
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(List.filled(length, 0));
  }

  test('a fresh install needs the whole manifest plus the headroom', () async {
    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet);
    expect(check.headroomBytes, downloadHeadroomBytes);
    expect(check.requiredBytes, wholeSet + downloadHeadroomBytes);
  });

  test('a file the ledger calls done costs nothing', () async {
    final ledger = DownloadLedger.empty.record(FileDownloadState(
      id: manifest.byRole(ModelRole.prose).id,
      status: DownloadStatus.done,
      sha256: manifest.byRole(ModelRole.prose).sha256,
    ));

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: ledger,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet - 16384);
  });

  test('a half-written part only costs its remainder', () async {
    await writePart('bond-bulk', 1000);

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet - 1000);
  });

  test('free space that cannot be asked is not a refusal', () async {
    system.free = null;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    // The download hits ENOSPC and keeps its part, which is a recoverable
    // failure with a sentence attached. Refusing on ignorance would block a
    // volume that simply cannot be asked.
    expect(check.known, isFalse);
    expect(check.ok, isTrue);
    expect(check.shortfallBytes, 0);
  });

  test('room for the weights but not the headroom is a refusal', () async {
    system.free = wholeSet + 1024;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(check.known, isTrue);
    expect(check.ok, isFalse);
    expect(check.shortfallBytes, downloadHeadroomBytes - 1024);
  });

  test('enough room passes with no shortfall', () async {
    system.free = wholeSet + downloadHeadroomBytes;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(check.ok, isTrue);
    expect(check.shortfallBytes, 0);
  });

  test('nothing left to download passes on a volume with nothing left',
      () async {
    final ledger = DownloadLedger(Map.fromEntries([
      for (final model in manifest.models)
        MapEntry(
          model.id,
          FileDownloadState(
            id: model.id,
            status: DownloadStatus.done,
            sha256: model.sha256,
          ),
        ),
    ]));
    system.free = 0;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: ledger,
      folder: folder(),
    );

    // The headroom is what this download would need on TOP of the weights,
    // and there is no download. Asking for it here would refuse a set that is
    // already entirely on disk.
    expect(check.neededBytes, 0);
    expect(check.ok, isTrue);
    expect(check.shortfallBytes, 0);
    expect(check.requiredBytes, downloadHeadroomBytes);
  });

  test('the volume is asked about the nearest EXISTING ancestor', () async {
    final missing = p.join(root.path, 'not', 'made', 'yet', 'models');

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: missing,
    );

    // The models folder does not exist before the first download, and the
    // platform call wants a real path. The volume is the same either way.
    expect(system.freeBytesPaths, [root.path]);
    expect(check.folder, missing);
    expect(Directory(missing).existsSync(), isFalse);
  });

  test('a folder that exists is asked about directly', () async {
    await Directory(folder()).create(recursive: true);

    await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(system.freeBytesPaths, [folder()]);
  });

  test('the headroom is overridable, for a test and for nothing else', () async {
    system.free = wholeSet;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
      headroomBytes: 0,
    );

    expect(check.ok, isTrue);
    expect(check.requiredBytes, wholeSet);
  });
}
