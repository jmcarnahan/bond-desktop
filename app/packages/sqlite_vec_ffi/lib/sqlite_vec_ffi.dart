// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:sqlite3/sqlite3.dart';

/// sqlite-vec's entrypoint, in the shape SQLite's extension loader expects.
///
/// The name has to match the symbol the C file exports exactly — `@Native`
/// resolves it out of the bundled `libsqlite_vec_ffi.dylib` this package's
/// build hook produced.
@Native<Int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>()
external int sqlite3_vec_init(
  Pointer<Void> db,
  Pointer<Void> pzErrMsg,
  Pointer<Void> pApi,
);

bool? _loaded;

/// Registers sqlite-vec as a SQLite auto-extension, once per process.
///
/// Two things about this are easy to get wrong, so they are worth stating
/// plainly:
///
/// It is PROCESS-GLOBAL, and it only reaches connections opened AFTER the
/// call. A database that was already open when this ran does not gain
/// `vec_version()` or `vec0` — which is why the app calls this before it
/// opens anything (`openAppDb`), and why `MessageVectorIndex.ensureReady`
/// probes the live connection rather than trusting this return value.
///
/// It returns false instead of throwing when the native asset is missing —
/// a build without the code asset surfaces that as an `ArgumentError` from
/// `Native.addressOf`, and semantic search being unavailable is a degraded
/// feature, not a reason to take the app's database down with it. Callers
/// read false as "search is off".
bool ensureSqliteVecLoaded() {
  final cached = _loaded;
  if (cached != null) return cached;
  try {
    sqlite3.ensureExtensionLoaded(
      SqliteExtension(
        Native.addressOf<
              NativeFunction<
                Int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
              >
            >(sqlite3_vec_init)
            .cast(),
      ),
    );
    return _loaded = true;
  } catch (_) {
    // Object, not Exception: a missing code asset arrives as an Error.
    return _loaded = false;
  }
}
