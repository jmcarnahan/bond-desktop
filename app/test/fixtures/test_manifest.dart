import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/server/router_preset.dart';

/// A manifest with the REAL ids, repos and file names and fictional
/// everything else.
///
/// The three names are real because they are what `modelPath`, the INI and
/// every Phase 2 assertion are written against — a fixture that renamed them
/// would test a layout the app does not use. The sizes and digests are the
/// test's to choose, which is what lets a downloader test build a 4 KiB
/// "27B model".
/// `minRamBytes` is 0 on every entry, so nothing here refuses to run on the
/// machine the suite is on. Nothing reads it any more either: the wizard's
/// low-memory sentence asks the TIER, and the tier is read off the machine's
/// memory rather than off a checkpoint's appetite.
///
/// The TIERS are the real ones: the same two rungs and the same floors the
/// committed manifest carries, so a test that resolves a tier is resolving
/// the ladder the app ships. The entries' own arguments stay fictional.
/// [proseSidecar] is OPT-IN and null by default, so the fixture every other
/// suite builds still describes three files and one INI line per model.
/// [withDecide] is opt-in for the same reason: the decision model (the
/// registry entry, real repo and file names, a heads record) is a fourth INI
/// section, and only the suites about it want one; [decide] hands in another
/// decide entry instead, such as [testLocalDecideFile]. A
/// sidecar changes the preset's text, the download count, the ledger's rows
/// and the total, and only the suites that are about those want it.
///
/// The DEFAULT embed entry is a Hugging Face one, although the committed
/// manifest's embedding model comes from the model registry: the 4B and the
/// 27B still ship from Hugging Face, the hub machinery needs a small hub
/// fixture, and flipping it would rewrite dozens of suites that are not about
/// where the embedding model comes from (decision D8 of the embed-registry
/// round). [embed] hands in another embed entry instead, such as
/// [testEmbedFile], the registry shape the committed manifest ships.
ModelManifest testManifest({
  Map<String, int>? sizes,
  Map<String, String>? sha256s,
  String revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ModelSidecar? proseSidecar,
  bool withDecide = false,
  ModelFile? decide,
  ModelFile? embed,
}) {
  final defaultSha = '0' * 64;
  ModelFile file({
    required String id,
    required ModelRole role,
    required String displayName,
    required String repo,
    required String name,
    required int size,
    required Map<String, String> args,
    ModelSidecar? sidecar,
  }) =>
      ModelFile(
        id: id,
        role: role,
        displayName: displayName,
        repo: repo,
        file: name,
        revision: revision,
        sizeBytes: sizes?[id] ?? size,
        sha256: sha256s?[id] ?? defaultSha,
        minRamBytes: 0,
        license: 'Fictional-1.0',
        licenseUrl: 'https://example.invalid/licence',
        serverArgs: args,
        sidecar: sidecar,
      );

  return ModelManifest(
      version: ModelManifest.manifestVersion, tiers: testTiers, models: [
    embed ??
        file(
          id: routerEmbedId,
          role: ModelRole.embed,
          displayName: 'Test Embed',
          repo: 'ggml-org/embeddinggemma-300M-GGUF',
          name: 'embeddinggemma-300M-Q8_0.gguf',
          size: 1024,
          args: const {
            'embedding': 'true',
            'pooling': 'mean',
            'load-on-startup': 'true',
          },
        ),
    if (withDecide || decide != null) decide ?? testDecideFile(),
    file(
      id: routerBulkId,
      role: ModelRole.bulk,
      displayName: 'Test Bulk',
      repo: 'ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF',
      name: 'qwen3-4b-instruct-2507-q8_0.gguf',
      size: 4096,
      args: const {'c': '32768', 'parallel': '4', 'load-on-startup': 'true'},
    ),
    file(
      id: routerProseId,
      role: ModelRole.prose,
      displayName: 'Test Prose',
      repo: 'ggml-org/Qwen3.8-27B-GGUF',
      name: 'Qwen3.8-27B-Q4_K_M.gguf',
      size: 16384,
      args: const {'c': '32768', 'parallel': '1', 'load-on-startup': 'true'},
      sidecar: proseSidecar,
    ),
  ]);
}

/// The decision model as the committed manifest ships it, a REGISTRY entry
/// (`source: artifactory`), with the REAL repo, bundle, remote and on-disk
/// file and heads names (what the paths, the registry URLs and the parity
/// with `make decide-fetch` are written against) and fictional sizes and
/// digests. A downloader test hands in the digests of the bytes its fake
/// registry serves, so the sha checks pass, as the other fixtures do.
ModelFile testDecideFile({
  int sizeBytes = 2048,
  String? sha256,
  int headsSizeBytes = 512,
  String? headsSha256,
}) =>
    ModelFile(
      id: routerDecideId,
      role: ModelRole.decide,
      displayName: 'Test Decide',
      repo: 'artifactory/bond-decide-mbl-v3swap',
      file: 'bond-decide-mbl-v3-f16.gguf',
      revision: '',
      sizeBytes: sizeBytes,
      sha256: sha256 ?? 'e' * 64,
      minRamBytes: 0,
      license: 'Fictional-1.0',
      licenseUrl: 'https://example.invalid/licence',
      source: sourceArtifactory,
      bundle: 'bond-decide-mbl-v3swap',
      remoteFile: 'model-f16.gguf',
      heads: ModelHeads(
        file: 'decide-heads.json',
        remoteFile: 'heads.json',
        sha256: headsSha256 ?? 'f' * 64,
        sizeBytes: headsSizeBytes,
      ),
      serverArgs: _decideArgs,
    );

/// The embedding model as the committed manifest ships it, a REGISTRY entry
/// (`source: artifactory`) that keeps its upstream repo as its folder, with
/// the REAL repo, bundle, remote and on-disk file names (the path is the one
/// an install that fetched it from Hugging Face already has, and the registry
/// URL is what `make embed-fetch` asks for) and a fictional size and digest.
/// No heads file: the downloader fetches it as one leg. A downloader test
/// hands in the digest of the bytes its fake registry serves.
ModelFile testEmbedFile({int sizeBytes = 1024, String? sha256}) => ModelFile(
      id: routerEmbedId,
      role: ModelRole.embed,
      displayName: 'Test Embed',
      repo: 'Qwen/Qwen3-Embedding-0.6B-GGUF',
      file: 'Qwen3-Embedding-0.6B-Q8_0.gguf',
      revision: '',
      sizeBytes: sizeBytes,
      sha256: sha256 ?? 'd' * 64,
      minRamBytes: 0,
      license: 'Fictional-1.0',
      licenseUrl: 'https://example.invalid/licence',
      source: sourceArtifactory,
      bundle: 'bond-embed-qwen3-0.6b',
      remoteFile: 'model-q8_0.gguf',
      serverArgs: const {
        'embedding': 'true',
        'pooling': 'last',
        'load-on-startup': 'true',
      },
    );

/// A HAND-INSTALLED decision model (`source: local`, repo
/// `local/bond-decide`): never downloaded, never ledgered, installed when
/// its GGUF and heads file are both in the folder. The committed manifest no
/// longer ships one, and the `local` source is still supported, so the
/// suites about that branch build it from here.
ModelFile testLocalDecideFile() => ModelFile(
      id: routerDecideId,
      role: ModelRole.decide,
      displayName: 'Test Decide',
      repo: 'local/bond-decide',
      file: 'bond-decide-mbl-v3-f16.gguf',
      revision: '',
      sizeBytes: 2048,
      sha256: 'e' * 64,
      minRamBytes: 0,
      license: 'Fictional-1.0',
      licenseUrl: 'https://example.invalid/licence',
      source: sourceLocal,
      heads: ModelHeads(
        file: 'decide-heads.json',
        sha256: 'f' * 64,
        sizeBytes: 512,
      ),
      serverArgs: _decideArgs,
    );

const Map<String, String> _decideArgs = {
  'embedding': 'true',
  'pooling': 'mean',
  'c': '2048',
  'ub': '2048',
  'b': '2048',
  'parallel': '1',
  'load-on-startup': 'true',
};

/// The fictional MTP head for the prose entry — the real file NAME, because
/// the path and the INI line are what the assertions are written against, and
/// a size and digest the test chooses.
ModelSidecar testSidecar({
  int sizeBytes = 2048,
  String? sha256,
  String revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) =>
    ModelSidecar(
      file: 'mtp-Qwen3.8-27B-Q4_0.gguf',
      revision: revision,
      sha256: sha256 ?? 'd' * 64,
      sizeBytes: sizeBytes,
    );

/// The two the committed manifest declares: the full tier takes every
/// checkpoint, the inbox tier takes all but the 27B and halves the 4B's slots.
/// Both list the decision model, which a fixture built without [withDecide]
/// simply does not carry.
final List<ManifestTier> testTiers = List.unmodifiable([
  ManifestTier(
    tier: MachineTier.full,
    minRamBytes: fullTierMinBytes,
    models: const [routerEmbedId, routerDecideId, routerBulkId, routerProseId],
  ),
  const ManifestTier(
    tier: MachineTier.inbox,
    minRamBytes: 0,
    models: [routerEmbedId, routerDecideId, routerBulkId],
    serverArgs: {
      routerBulkId: {'c': '16384', 'parallel': '2'},
    },
  ),
]);

/// The preset [testManifest] writes, pointed at [folder].
RouterPreset testPreset(String folder) => testManifest().toPreset(folder);

/// A manifest holding exactly [files] — for the parser's refusals and for a
/// downloader test that wants one model rather than three.
ModelManifest manifestFor(List<ModelFile> files) =>
    ModelManifest(
      version: ModelManifest.manifestVersion,
      models: List.unmodifiable(files),
    );
