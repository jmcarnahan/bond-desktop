import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// ONE registry address and ONE token serve both models this Mac downloads
/// from the registry, through the app's own wiring.
///
/// The pieces are each pinned elsewhere: `default_setup_test` reads the
/// provider's two lookups, `model_downloader_test` hands a downloader its
/// lookups by hand, and `make registry-verify` takes the downloader to a real
/// registry. This is the join nothing else makes: the REAL
/// `modelDownloaderProvider` over the real `AppPrefsNotifier`, given only
/// what `local.mk` compiles in (`BOND_REGISTRY_URL`, `BOND_REGISTRY_TOKEN`),
/// fetches the embedding model and the decision model with its heads file
/// from that one address with that one token. And a registry saved later
/// under Settings is the one the next download asks, with its own token.
///
/// Plain `test()`s on real loopback HTTP: nothing here is a widget. The
/// tokens are fixture strings.
void main() {
  const buildToken = 'test-registry-token-456';
  const typedToken = 'test-typed-token-321';
  const embedKey = 'bond-embed-qwen3-0.6b/model-q8_0.gguf';
  const decideKey = 'bond-decide-mbl-v3swap/model-f16.gguf';
  const headsKey = 'bond-decide-mbl-v3swap/heads.json';

  late BondDatabase db;
  late Directory support;
  late FakeHubServer hub;
  late FakeHubServer other;
  late ModelFile embed;
  late ModelFile decide;

  /// Puts the three files both registries serve on [server], behind [token].
  void publish(FakeHubServer server, String token) {
    server.registryContents[embedKey] = fakeWeights(4096, seed: 41);
    server.registryContents[decideKey] = fakeWeights(6144, seed: 42);
    server.registryContents[headsKey] = fakeWeights(512, seed: 43);
    server.registryBearer = token;
  }

  setUp(() async {
    db = testDb();
    support = await Directory.systemTemp.createTemp('registry-one-address');
    hub = await FakeHubServer.start();
    other = await FakeHubServer.start();
    publish(hub, buildToken);
    publish(other, typedToken);
    embed = testEmbedFile(
      sizeBytes: hub.registryContents[embedKey]!.length,
      sha256: sha256Hex(hub.registryContents[embedKey]!),
    );
    decide = testDecideFile(
      sizeBytes: hub.registryContents[decideKey]!.length,
      sha256: sha256Hex(hub.registryContents[decideKey]!),
      headsSizeBytes: hub.registryContents[headsKey]!.length,
      headsSha256: sha256Hex(hub.registryContents[headsKey]!),
    );
  });

  tearDown(() async {
    await hub.close();
    await other.close();
    await db.close();
    await support.delete(recursive: true);
  });

  /// The app's own providers over a build that compiled in [hub]'s address
  /// and its token, and nothing else about the registry.
  Future<ProviderContainer> build() async {
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(
        testManifest(embed: embed, decide: decide),
      ),
      systemInfoProvider.overrideWithValue(FakeSystemInfo()),
      appPrefsProvider.overrideWith(
        (ref) => AppPrefsNotifier(
          MessageStore(db),
          tokens: MemoryTokenStore(),
          compiledRegistryUrl: hub.registryBase,
          compiledRegistryToken: buildToken,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await container.read(appPrefsProvider.notifier).ready;
    return container;
  }

  String pathOf(ProviderContainer container, String relative) => p.join(
        container
            .read(appPrefsProvider)
            .effectiveModelsFolder(AppPaths(support)),
        relative,
      );

  test('the build\'s one address and one token fetch the embedding model and '
      'the decision model', () async {
    final container = await build();
    final downloader = container.read(modelDownloaderProvider);

    final events = await downloader.run([embed, decide]).toList();

    for (final id in [routerEmbedId, routerDecideId]) {
      expect(
        events.lastWhere((e) => e.id == id).status,
        DownloadStatus.done,
        reason: '$id did not land',
      );
    }
    // Three files, three requests, all to the one address and each with the
    // one token: nothing about the registry is per model.
    expect(hub.registryCount, 3);
    expect(hub.registryAuth, everyElement('Bearer $buildToken'));
    expect(other.registryCount, 0);
    expect(File(pathOf(container, embed.relativePath)).readAsBytesSync(),
        hub.registryContents[embedKey]);
    expect(File(pathOf(container, decide.relativePath)).readAsBytesSync(),
        hub.registryContents[decideKey]);
    expect(File(pathOf(container, decide.headsRelativePath!)).readAsBytesSync(),
        hub.registryContents[headsKey]);
    // The embedding model sits in its upstream repo's folder, the decision
    // model in its bundle's.
    expect(embed.relativePath,
        'Qwen_Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf');
    final ledger = await container.read(setupStoreProvider).downloadLedger();
    expect(ledger.isCurrent(embed), isTrue);
    expect(ledger.isCurrent(decide), isTrue);
  });

  test('a registry saved later is the one the next download asks, with its '
      'own token, for either model', () async {
    final container = await build();
    final prefs = container.read(appPrefsProvider.notifier);
    final downloader = container.read(modelDownloaderProvider);
    await downloader.run([embed, decide]).toList();
    expect(hub.registryCount, 3);

    // Settings, Models, Model registry: another address and its token.
    await prefs.useRegistry(url: other.registryBase, token: typedToken);
    // Both models gone from disk, as after a folder emptied by hand.
    for (final relative in [
      embed.relativePath,
      decide.relativePath,
      decide.headsRelativePath!,
    ]) {
      File(pathOf(container, relative)).deleteSync();
    }

    final events = await downloader.run([embed, decide]).toList();

    for (final id in [routerEmbedId, routerDecideId]) {
      expect(events.lastWhere((e) => e.id == id).status, DownloadStatus.done);
    }
    expect(other.registryCount, 3);
    expect(other.registryAuth, everyElement('Bearer $typedToken'));
    // The build's registry was not asked again, and never saw the new token.
    expect(hub.registryCount, 3);
    expect(hub.registryAuth, everyElement('Bearer $buildToken'));
    expect(File(pathOf(container, embed.relativePath)).existsSync(), isTrue);
    expect(File(pathOf(container, decide.relativePath)).existsSync(), isTrue);
  });

  test('with the stored token removed, the build\'s token is used again on '
      'the build\'s address, for either model', () async {
    final container = await build();
    final prefs = container.read(appPrefsProvider.notifier);
    final downloader = container.read(modelDownloaderProvider);

    // A wrong token typed for the build's own registry: both models refused.
    await prefs.useRegistry(url: hub.registryBase, token: typedToken);
    final refused = await downloader.run([embed, decide]).toList();
    for (final id in [routerEmbedId, routerDecideId]) {
      final last = refused.lastWhere((e) => e.id == id);
      expect(last.status, DownloadStatus.failed);
      expect(last.error, DownloadError.unauthorized);
    }

    // Remove token: back to the one `local.mk` compiled in.
    await prefs.clearRegistryToken();
    final events = await downloader.run([embed, decide]).toList();
    for (final id in [routerEmbedId, routerDecideId]) {
      expect(events.lastWhere((e) => e.id == id).status, DownloadStatus.done);
    }
    expect(hub.registryAuth.last, 'Bearer $buildToken');
  });
}
