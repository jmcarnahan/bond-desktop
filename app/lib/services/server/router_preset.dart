import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

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
///
/// The SECTIONS come from `ModelManifest.toPreset` — the committed
/// `assets/models/manifest.json` is the only place the three checkpoints are
/// named. This class knows how to write an INI and nothing about which models
/// belong in one, which is what lets a model bump be a JSON edit; the
/// dependency runs manifest → preset and never the other way.
@immutable
class RouterPreset {
  /// Where the GGUF files live — the folder the downloader fills.
  final String modelsFolder;

  final List<RouterModelSpec> models;

  const RouterPreset({required this.modelsFolder, required this.models});

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
