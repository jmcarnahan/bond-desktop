import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import '../llm/model_slots.dart';

/// One model in the router's preset: what it is called, where its weights
/// came from, and the flags it is loaded with.
///
/// [repo] and [file] are kept apart rather than joined into a path because
/// the download in Phase 3 needs both halves — the repo names the Hugging
/// Face source, the file names the artefact — and because the on-disk layout
/// is derived from them by [RouterPreset.modelPath] in exactly one place.
///
/// [args] are llama-server's own long flags with the leading dashes stripped,
/// which is the spelling the preset INI wants (`c`, `parallel`, `embedding`).
/// They are a map rather than a typed record because the set differs per
/// model and the server owns the vocabulary; this file is not the place to
/// re-declare it.
@immutable
class RouterModelSpec {
  final String id;
  final String repo;
  final String file;
  final Map<String, String> args;

  const RouterModelSpec({
    required this.id,
    required this.repo,
    required this.file,
    this.args = const {},
  });
}

/// The whole `--models-preset` file, as a value.
///
/// The app runs ONE llama-server in router mode rather than the three
/// hand-started processes the old workflow needed. That server is told what
/// to serve by an INI file, so this class is the app's model configuration:
/// change it and the next start serves something different. [hash] is what
/// makes that safe across a relaunch — an adopted server whose preset hash
/// does not match the one the app would write now is serving the wrong
/// models, and gets replaced rather than reused.
@immutable
class RouterPreset {
  /// Where the GGUF files live — the folder the downloader fills.
  final String modelsFolder;

  final List<RouterModelSpec> models;

  const RouterPreset({required this.modelsFolder, required this.models});

  /// The default trio (Phase 3 replaces this source with the manifest).
  ///
  /// Ordered smallest first, and that order reaches the INI: the router loads
  /// the sections in file order at startup, so the embedding model — the one
  /// the ingestion pipeline blocks on first — is resident while the
  /// twenty-seven-billion-parameter prose model is still being mapped.
  static const List<RouterModelSpec> defaultTrio = [
    RouterModelSpec(
      id: routerEmbedId,
      repo: 'ggml-org/embeddinggemma-300M-GGUF',
      file: 'embeddinggemma-300M-Q8_0.gguf',
      // `pooling = mean` is not a preference: the stored vectors were written
      // under mean pooling, and a server that pooled differently would answer
      // plausible numbers in a different space.
      args: {
        'embedding': 'true',
        'pooling': 'mean',
        'load-on-startup': 'true',
      },
    ),
    RouterModelSpec(
      id: routerBulkId,
      repo: 'ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF',
      file: 'qwen3-4b-instruct-2507-q8_0.gguf',
      // Four parallel slots because the bulk slot is what the drain hammers:
      // triage, needs-you, extraction and the digests all queue against it.
      args: {'c': '32768', 'parallel': '4', 'load-on-startup': 'true'},
    ),
    RouterModelSpec(
      id: routerProseId,
      repo: 'ggml-org/Qwen3.8-27B-GGUF',
      file: 'Qwen3.8-27B-Q4_K_M.gguf',
      // One slot, not four: the prose model is the memory ceiling on this
      // machine and a second concurrent context would double its KV cache.
      args: {'c': '32768', 'parallel': '1', 'load-on-startup': 'true'},
    ),
  ];

  factory RouterPreset.defaults(String modelsFolder) =>
      RouterPreset(modelsFolder: modelsFolder, models: defaultTrio);

  /// `<modelsFolder>/<repo with '/' → '_'>/<file>`.
  ///
  /// The repo's slash becomes an underscore so one download lands in one flat
  /// folder per repo, which is what makes a half-finished download obvious to
  /// a person looking at the directory and easy for Phase 3 to delete.
  String modelPath(RouterModelSpec m) =>
      p.join(modelsFolder, m.repo.replaceAll('/', '_'), m.file);

  List<String> get modelIds => [for (final m in models) m.id];

  /// The preset file's text.
  ///
  /// Paths are written UNQUOTED even when they contain spaces, because that
  /// is what llama-server's INI parser wants: it reads to end of line, and a
  /// quoted path arrives with the quotes still in it and fails to open.
  String toIni() {
    final out = StringBuffer();
    out.writeln('version = 1');
    out.writeln();
    out.writeln('[*]');
    // Globals, in the order the server documents them. `jinja` is what makes
    // the chat template — and therefore the tool-call and thinking syntax —
    // come from the GGUF rather than from a guess; `mmap+mlock` keeps the
    // weights resident so the first request after an idle hour is not a
    // re-read from disk.
    out.writeln('jinja = true');
    out.writeln('flash-attn = on');
    out.writeln('load-mode = mmap+mlock');
    for (final m in models) {
      out.writeln();
      out.writeln('[${m.id}]');
      out.writeln('model = ${modelPath(m)}');
      m.args.forEach((key, value) => out.writeln('$key = $value'));
    }
    return out.toString();
  }

  /// sha256 of [toIni], hex.
  ///
  /// Over the TEXT rather than the fields, so anything that would change the
  /// file the server reads — a path, a flag, the order of two sections —
  /// changes the hash, and an adopted server can be compared against the
  /// preset this build would write without re-deriving what "the same" means.
  String get hash => sha256.convert(utf8.encode(toIni())).toString();

  /// Which model files are not on disk, as full paths.
  ///
  /// Asked before spawning: llama-server's answer to a missing model is to
  /// exit with a code and a line in a log the user is not reading, and
  /// "Model files are missing" is a sentence the first-run screen can act on.
  List<String> missingFiles() => [
        for (final m in models)
          if (!File(modelPath(m)).existsSync()) modelPath(m),
      ];
}
