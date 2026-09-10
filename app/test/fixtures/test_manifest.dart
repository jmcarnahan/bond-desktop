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
ModelManifest testManifest({
  Map<String, int>? sizes,
  Map<String, String>? sha256s,
  String revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
      );

  return ModelManifest(version: 1, models: [
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
    ),
  ]);
}

/// The preset [testManifest] writes, pointed at [folder].
RouterPreset testPreset(String folder) => testManifest().toPreset(folder);

/// A manifest holding exactly [files] — for the parser's refusals and for a
/// downloader test that wants one model rather than three.
ModelManifest manifestFor(List<ModelFile> files) =>
    ModelManifest(version: 1, models: List.unmodifiable(files));
