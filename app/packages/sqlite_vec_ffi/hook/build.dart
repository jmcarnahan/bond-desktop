import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Compiles the vendored `src/sqlite-vec.c` into a bundled dylib.
///
/// This rides the same native-assets pipeline the `sqlite3` package's own
/// hook uses, which is the whole reason the extension is a source build
/// rather than a prebuilt `vec0.dylib`: the asset lands wherever Dart puts
/// them, so `flutter test` and the signed `.app` bundle both find it with no
/// Xcode edits and nothing extra to codesign.
///
/// Deliberately NOT compiled with `-DSQLITE_CORE`. Without it sqlite-vec
/// builds in its loadable-extension shape, where every SQLite call goes
/// through the `sqlite3_api_routines` pointer handed to `sqlite3_vec_init`.
/// The dylib therefore has no undefined `sqlite3_*` symbols to resolve at
/// load time — which matters here, because the SQLite it will run against is
/// the one the sqlite3 package compiled, not one this build can link to.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final library = CBuilder.library(
      name: 'sqlite_vec_ffi',
      packageName: 'sqlite_vec_ffi',
      assetName: 'sqlite_vec_ffi.dart',
      sources: ['src/sqlite-vec.c'],
      // `sqlite3.h` / `sqlite3ext.h` are vendored next to it — the sqlite-vec
      // amalgamation does not ship the headers it includes.
      includes: ['src'],
      flags: [
        '-O2',
        if (input.config.code.targetOS case OS.iOS || OS.macOS) ...[
          '-headerpad_max_install_names',
          // Otherwise clang stamps native_toolchain_c's temp directory into
          // the install name, which makes the build irreproducible.
          '-install_name',
          '@rpath/libsqlite_vec_ffi.dylib',
        ],
      ],
    );

    await library.run(input: input, output: output);
  });
}
