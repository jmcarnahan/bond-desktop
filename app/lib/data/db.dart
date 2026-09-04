import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'database.dart';

export 'database.dart' show BondDatabase, adoptLegacyDatabase;

/// The app's real database: `bond_inbox.db` in the platform application
/// support directory. Async only because locating that directory is.
///
/// The order of the three calls below is the whole content of this function.
///
/// [ensureSqliteVecLoaded] runs FIRST, before anything opens a connection.
/// Registering sqlite-vec is a process-global auto-extension registration, and
/// SQLite applies auto-extensions when a connection is created — never
/// retroactively. [adoptLegacyDatabase] opens a raw connection of its own, so
/// even that one has to come after, or the app would be one connection short
/// of consistent about which handles know what `vec0` is.
///
/// [adoptLegacyDatabase] runs next, and has to: drift decides whether to
/// create the schema from `user_version`, which every pre-drift install still
/// reports as 0.
///
/// The `vec_version()` probe at the end is not decoration. It is the launch-log
/// line that says whether semantic search will work in this build, asked of the
/// connection that will actually serve it rather than of the loader's return
/// value.
Future<BondDatabase> openAppDb() async {
  if (!ensureSqliteVecLoaded()) {
    debugPrint('sqlite-vec: native extension unavailable — '
        'semantic search will be off');
  }
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'bond_inbox.db');
  await adoptLegacyDatabase(path);
  final db = BondDatabase.open(path);
  try {
    final v = await db.customSelect('SELECT vec_version() AS v').getSingle();
    debugPrint('sqlite-vec ${v.data['v']}');
  } catch (e) {
    debugPrint('sqlite-vec: unavailable on this connection — $e');
  }
  return db;
}
