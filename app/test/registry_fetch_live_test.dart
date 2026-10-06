@Skip('live — downloads every registry model. Run: make registry-verify')
library;

import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Whether the configured model registry really serves what this build pins,
/// checked with the app's own downloader.
///
/// The one registry check that ASSERTS, on `bench-verify`'s rule: nothing here
/// is a judgement. Each expectation is a fact about how a server is
/// CONFIGURED: that every registry entry in the committed manifest (the
/// embedding model and the decision model) is published under the bundle and
/// the remote name the manifest gives it, that the token opens it, and that
/// the bytes the real `ModelDownloader` lands are the bytes the manifest pins.
/// Every offline test of the registry path runs against `FakeHubServer`; this
/// is the run that takes the same code to the real Artifactory.
///
/// LIVE, and never part of the gate: it downloads about 1.4 GB, and it needs
/// an address and a token that a checkout does not carry. `make
/// registry-verify` runs it with both in the ENVIRONMENT
/// (`BOND_REGISTRY_URL`, `BOND_REGISTRY_TOKEN`), never as a define, so the
/// token is never in a command line. It prints counts and milliseconds only,
/// never the token; the address is not printed here either, though the
/// downloader's own debug line for an unexpected failure can name the URL.
void main() {
  test('registry fetch', () async {
    final base = (Platform.environment['BOND_REGISTRY_URL'] ?? '').trim();
    final token = (Platform.environment['BOND_REGISTRY_TOKEN'] ?? '').trim();
    if (base.isEmpty) {
      fail('BOND_REGISTRY_URL is empty. Set it in local.mk, or pass it to '
          'make registry-verify.');
    }

    final manifest = ModelManifest.parse(
      File(ModelManifest.assetPath).readAsStringSync(),
    );
    final entries = [
      for (final model in manifest.models)
        if (model.isRegistry) model,
    ];
    expect(
      [for (final model in entries) model.id],
      containsAll([routerEmbedId, routerDecideId]),
      reason: 'the committed manifest should list both local models as '
          'registry entries',
    );

    final folder = await Directory.systemTemp.createTemp('bond-registry');
    addTearDown(() async {
      if (folder.existsSync()) await folder.delete(recursive: true);
    });

    var ledger = DownloadLedger.empty;
    final downloader = ModelDownloader(
      manifest: manifest,
      modelsFolder: () => folder.path,
      readLedger: () async => ledger,
      writeLedger: (updated) async => ledger = updated,
      registryBase: () => base,
      registryToken: (_) => token.isEmpty ? null : token,
    );
    addTearDown(downloader.dispose);

    // When each entry's first and last event arrived, for the timing lines.
    final clock = Stopwatch()..start();
    final firstAt = <String, int>{};
    final lastAt = <String, int>{};
    final last = <String, DownloadProgress>{};
    await for (final event in downloader.run(entries)) {
      firstAt.putIfAbsent(event.id, () => clock.elapsedMilliseconds);
      lastAt[event.id] = clock.elapsedMilliseconds;
      last[event.id] = event;
    }

    for (final entry in entries) {
      final ms = (lastAt[entry.id] ?? 0) - (firstAt[entry.id] ?? 0);
      expect(last[entry.id]?.status, DownloadStatus.done,
          reason: '${entry.id} ended ${last[entry.id]?.status} with '
              '${last[entry.id]?.error}');
      expect(ledger.isCurrent(entry), isTrue,
          reason: 'the ledger does not call ${entry.id} current');

      final files = <(String, String, int, String)>[
        (entry.id, entry.relativePath, entry.sizeBytes, entry.sha256),
        if (entry.heads case final heads?)
          (
            DownloadLedger.headsId(entry.id),
            entry.headsRelativePath!,
            heads.sizeBytes,
            heads.sha256,
          ),
      ];
      for (final (id, relative, size, digest) in files) {
        final file = File(p.join(folder.path, relative));
        expect(file.existsSync(), isTrue, reason: '$id did not land at '
            '$relative');
        expect(file.lengthSync(), size, reason: '$id is not the size the '
            'manifest pins');
        // Hashed here, independently of the downloader's own check.
        final hashed = (await sha256.bind(file.openRead()).first).toString();
        expect(hashed, digest, reason: '$id is not the bytes the manifest '
            'pins');
        // ignore: avoid_print
        print('registry fetch: $id  ${file.lengthSync()} B  $ms ms');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
