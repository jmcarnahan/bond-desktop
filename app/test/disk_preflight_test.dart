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

  /// A file where the preset will look for it — what a ledger row calling a
  /// model done is supposed to be describing.
  Future<void> writeDone(String id) async {
    final file = manifest.byId(id);
    final path = p.join(folder(), file.relativePath);
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(List.filled(file.sizeBytes, 0));
  }

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

  test('a file the ledger calls done, and that is here, costs nothing',
      () async {
    await writeDone(manifest.byRole(ModelRole.prose).id);
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

  test('a done row whose file is not in this folder is counted again',
      () async {
    // The ledger survives "Set up again" and it survives a change of folder,
    // so a done row can describe a file that lives in the OLD one. A preflight
    // that trusted it would have the storage step tell somebody pointing Bond
    // at an empty disk that everything was already there.
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

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: ledger,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet);
    // Which is what keeps `SetupStorageBody` off its "All models are already
    // in this folder." branch.
    expect(check.neededBytes, isNot(0));
  });

  test('nothing left to download passes on a volume with nothing left',
      () async {
    for (final model in manifest.models) {
      await writeDone(model.id);
    }
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
    // platform call wants a real path. The volume is the same either way —
    // and the question is asked BEFORE the write probe, so the answer comes
    // from the volume rather than from the folder the probe then makes.
    expect(system.freeBytesPaths, [root.path]);
    expect(check.folder, missing);
    // Which the probe did make: knowing whether Bond may write there costs
    // exactly the folder the very next step fills.
    expect(Directory(missing).existsSync(), isTrue);
  });

  test('a done row against another digest is counted all over again',
      () async {
    // A manifest bump that kept the file name. The bytes on disk are the
    // PREVIOUS checkpoint, the download step is going to fetch the whole file
    // again, and the storage step has to ask for room for it.
    final prose = manifest.byRole(ModelRole.prose);
    await writeDone(prose.id);
    final ledger = DownloadLedger.empty.record(FileDownloadState(
      id: prose.id,
      status: DownloadStatus.done,
      sha256: 'f' * 64,
    ));

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: ledger,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet);
  });

  test('a part left over from the previous checkpoint saves nothing',
      () async {
    // The downloader deletes a part whose ledger row disagrees with the
    // manifest rather than resuming into it, so counting those bytes here
    // would promise room the download does not have.
    final bulk = manifest.byId('bond-bulk');
    await writePart(bulk.id, 1000);
    final ledger = DownloadLedger.empty.record(FileDownloadState(
      id: bulk.id,
      status: DownloadStatus.paused,
      receivedBytes: 1000,
      totalBytes: bulk.sizeBytes,
      sha256: 'f' * 64,
    ));

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: ledger,
      folder: folder(),
    );

    expect(check.neededBytes, wholeSet);
  });

  test('a folder that can be written passes and keeps no probe', () async {
    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: folder(),
    );

    expect(check.writable, isTrue);
    expect(check.ok, isTrue);
    expect(Directory(folder()).existsSync(), isTrue);
    expect(File(p.join(folder(), '.bond-write-probe')).existsSync(), isFalse);
  });

  test('a folder Bond cannot write to is a refusal whatever the volume says',
      () async {
    // Free space is not permission: a read-only mount, a locked external
    // disk or somebody else's home all report gigabytes and refuse the first
    // byte. The download would fail file by file with a network-shaped error
    // to show for it, so the storage step asks now.
    final locked = Directory(p.join(root.path, 'locked'))
      ..createSync(recursive: true);
    Process.runSync('chmod', ['500', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['700', locked.path]));
    system.free = 500 * 1024 * 1024 * 1024;

    final check = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: DownloadLedger.empty,
      folder: p.join(locked.path, 'models'),
    );

    expect(check.writable, isFalse);
    expect(check.known, isTrue);
    expect(check.ok, isFalse);
  },
      skip: Platform.environment['USER'] == 'root'
          ? 'root writes to a mode-500 folder'
          : null);

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
