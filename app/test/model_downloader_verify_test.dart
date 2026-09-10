import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_manifest.dart';

/// What happens when the bytes that arrive are not the bytes the manifest
/// asked for — and which of the two hashers answered.
void main() {
  late FakeHubServer hub;
  late Directory root;
  late FakeSystemInfo system;
  late ModelManifest manifest;
  late DownloadLedger ledger;

  String folder() => p.join(root.path, 'models');
  String destOf(ModelFile file) => p.join(folder(), file.relativePath);
  String partOf(ModelFile file) =>
      '${destOf(file)}${ModelDownloader.partSuffix}';

  ModelManifest publish({int embed = 2048}) {
    final base = testManifest();
    final file = base.byId(routerEmbedId);
    final data = fakeWeights(embed, seed: 3);
    hub.contents['${file.repo}/${file.file}'] = data;
    return testManifest(
      sizes: {routerEmbedId: data.length},
      sha256s: {routerEmbedId: sha256Hex(data)},
    );
  }

  ModelDownloader build() {
    final downloader = ModelDownloader(
      manifest: manifest,
      modelsFolder: folder,
      readLedger: () async => ledger,
      writeLedger: (updated) async => ledger = updated,
      sha256: system.sha256,
      resolveUri: hub.resolveUriFor,
      sleep: (_) async {},
      progressInterval: const Duration(milliseconds: 1),
      ledgerInterval: Duration.zero,
    );
    addTearDown(downloader.dispose);
    return downloader;
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    root = await Directory.systemTemp.createTemp('model-verify');
    system = FakeSystemInfo();
    system.digest = null;
    ledger = DownloadLedger.empty;
    manifest = publish();
  });

  tearDown(() async {
    await hub.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('one corrupt body is retried from scratch and then succeeds', () async {
    hub.corruptFirst = true;
    final embed = manifest.byId(routerEmbedId);

    final events = await build().run([embed]).toList();

    // A flipped bit in flight is worth one more try; nothing is resumed into,
    // because the part is known to be wrong.
    expect(hub.resolveCount, 2);
    expect(hub.cdnRanges, [null, null]);
    expect(events.last.status, DownloadStatus.done);
    expect(File(partOf(embed)).existsSync(), isFalse);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a second bad digest is the wrong file, and leaves nothing behind',
      () async {
    hub.corruptAlways = true;
    final embed = manifest.byId(routerEmbedId);

    final events = await build().run([embed]).toList();

    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.checksum);
    // Exactly twice, not ten times: this is not a network fault.
    expect(hub.cdnCount, 2);
    expect(File(partOf(embed)).existsSync(), isFalse);
    expect(File(destOf(embed)).existsSync(), isFalse);
    expect(ledger[embed.id]?.error, DownloadError.checksum);
  });

  test('the platform hash is what decides, when the platform answers',
      () async {
    final embed = manifest.byId(routerEmbedId);
    // Corrupt bytes that the platform vouches for: only an implementation
    // that ASKED the platform, and believed it, accepts this download.
    hub.corruptAlways = true;
    system.digest = embed.sha256;

    final events = await build().run([embed]).toList();

    expect(events.last.status, DownloadStatus.done);
    expect(system.sha256Paths, contains(partOf(embed)));
    expect(File(destOf(embed)).existsSync(), isTrue);
    expect(File(destOf(embed)).readAsBytesSync().first,
        isNot(hub.contents['${embed.repo}/${embed.file}']!.first));
  });

  test('a platform that cannot answer falls through to the Dart digest',
      () async {
    final embed = manifest.byId(routerEmbedId);
    system.digest = null;

    final events = await build().run([embed]).toList();

    // Asked first, every time — the fallback is the answer to a null, not a
    // reason to skip the channel.
    expect(system.sha256Paths, contains(partOf(embed)));
    expect(events.last.status, DownloadStatus.done);
  });

  test('a platform digest in upper case is still the same digest', () async {
    final embed = manifest.byId(routerEmbedId);
    system.digest = embed.sha256.toUpperCase();

    final events = await build().run([embed]).toList();

    expect(events.last.status, DownloadStatus.done);
  });

  test('verify answers for a finished file, both ways', () async {
    final embed = manifest.byId(routerEmbedId);
    final downloader = build();

    // Nothing on disk at all.
    expect(await downloader.verify(embed), isFalse);

    await Directory(p.dirname(destOf(embed))).create(recursive: true);
    await File(destOf(embed)).writeAsBytes(utf8.encode('not a gguf'));
    expect(await downloader.verify(embed), isFalse);

    await File(destOf(embed))
        .writeAsBytes(hub.contents['${embed.repo}/${embed.file}']!);
    expect(await downloader.verify(embed), isTrue);
  });
}
