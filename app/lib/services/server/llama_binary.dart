import 'dart:io';

import 'package:path/path.dart' as p;

/// Where this build's `llama-server` is.
///
/// Three answers in a fixed order, because the three situations they cover
/// are all real and only one of them is the shipped app. A developer points
/// the app at Homebrew's binary with an environment variable; a packaging
/// experiment bakes a path in at compile time; the built `.app` carries its
/// own copy in `Contents/MacOS`, beside the executable. Null is the fourth
/// answer and it is not an error to be thrown — a build with no runtime is a
/// state the settings screen reports, not a crash on launch.
///
/// The sidecar sits BESIDE the executable and nowhere else, and that is a
/// requirement rather than a convention: llama.cpp's ggml backend modules are
/// `.so` files loaded from the executable's own directory, so a binary moved
/// to `Contents/Resources` finds no Metal backend and runs on the CPU with no
/// warning. The supervisor's choice of working directory follows from the
/// same fact.
class LlamaBinary {
  /// Compile-time override: `--dart-define=BOND_LLAMA_SERVER=/path`.
  static const String define = String.fromEnvironment('BOND_LLAMA_SERVER');

  /// The resolved path, or null when this build has no runtime.
  ///
  /// Every input is injectable so the precedence can be tested as itself.
  /// The defaults are the real ones — the process environment, this
  /// executable, the filesystem — so production callers pass nothing.
  ///
  /// The compile-time define wins only when it is NON-EMPTY:
  /// [String.fromEnvironment] answers `''` rather than null when the define
  /// was not given, so an emptiness check is the only way to tell "not set"
  /// from "set to something".
  static String? resolve({
    Map<String, String>? environment,
    String? resolvedExecutable,
    bool Function(String path)? exists,
  }) {
    if (define.isNotEmpty) return define;

    final env = environment ?? Platform.environment;
    final fromEnv = env['BOND_LLAMA_SERVER'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

    final executable = resolvedExecutable ?? Platform.resolvedExecutable;
    // Windows (unimplemented): `llama-server.exe`, in this same directory,
    // and the `ggml-*.dll` backends beside it for the same reason the `.so`
    // modules are here — ggml scans the running executable's own directory.
    // See `dist/windows/README.md` → What the app needs.
    final beside = p.join(p.dirname(executable), 'llama-server');
    final check = exists ?? (path) => File(path).existsSync();
    return check(beside) ? beside : null;
  }

  /// What a null [resolve] means, said once so every caller says it the same.
  static const String missingReason =
      'The model runtime is missing from this build';
}
