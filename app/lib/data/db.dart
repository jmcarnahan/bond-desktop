import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import '../services/perf/perf_log.dart';
import '../services/sample/sample_env.dart' show sampleModeOn;
import 'database.dart';

export 'database.dart' show BondDatabase, adoptLegacyDatabase;

/// `--dart-define=BOND_DB_UI_ISOLATE` (Makefile: `BOND_DB_UI_ISOLATE=1`) puts
/// the app's SQLite connection back on the UI isolate.
///
/// The app's database runs on a background isolate (see [openAppDb]). This
/// define exists for two reasons and only these two: a before/after
/// measurement taken on ONE build, so the only thing that differs between the
/// two halves is where the statements step; and a way out, without a code
/// change, if the background executor misbehaves on somebody's machine.
const String dbUiIsolateDefine = String.fromEnvironment('BOND_DB_UI_ISOLATE');

/// Whether this build runs the database on the UI isolate.
///
/// Any value but the three ways a build script says no turns it on, exactly as
/// `handServersBuild` reads its own define — somebody who wrote `=0` to turn
/// it back off gets the background connection rather than the opposite of
/// what they typed. `length > 0` rather than `isNotEmpty` because a constant
/// expression may read a string's length and may not call a getter on it.
const bool dbOnUiIsolate = dbUiIsolateDefine.length > 0 &&
    dbUiIsolateDefine != '0' &&
    dbUiIsolateDefine != 'false' &&
    dbUiIsolateDefine != 'no';

/// Registers sqlite-vec inside the database isolate, before drift opens the
/// connection there.
///
/// Top-level because it is SENT to the database isolate and runs there: drift
/// hands it to the spawned isolate as `isolateSetup`, and a function that
/// crosses an isolate boundary must capture nothing. The registration it
/// repeats is process-global, so the main isolate's call in [openAppDb] has
/// already done the work; this one exists because the loader's once-only
/// guard is a Dart top-level, which every isolate starts with empty, and
/// SQLite treats a second registration of the same entry point as a no-op.
/// It makes the background connection's `vec0` independent of what the main
/// isolate happened to do first.
void loadSqliteVecInIsolate() {
  ensureSqliteVecLoaded();
}

/// Makes the app's connection wait for a lock instead of failing on it.
///
/// The app has one connection and so nobody to wait for, with one exception:
/// a debug hot restart ends the old isolate, and its connection is only
/// closed when the runtime gets round to finalising it. A new connection that
/// met its lock in that gap failed at once with "database is locked"; with a
/// timeout it waits the moment out. Five seconds, because past that the other
/// holder is not on its way out and failing is the honest answer.
///
/// Set on the connection as it opens, not in the database's `beforeOpen`:
/// drift reads the schema version and runs a pending migration BEFORE that
/// callback, and a migration is the write most likely to meet the lock.
/// Top-level because, like [loadSqliteVecInIsolate], it is sent to the
/// database isolate. On the `BOND_DB_UI_ISOLATE` build the wait is on the UI
/// isolate, which is one more reason that build is for measuring only.
void waitOutLocks(Database database) {
  database.execute('PRAGMA busy_timeout = 5000;');
}

/// The executor the app's database runs on.
///
/// By default a background isolate, spawned as this executor is built, with
/// the one connection opened there at first use, so no statement steps on the
/// UI isolate. With
/// [onUiIsolate] (the `BOND_DB_UI_ISOLATE` build) the same-isolate
/// [NativeDatabase] the app ran on before. With [perfLog] (the
/// `BOND_PERF_LOG` build) either one is wrapped in [SlowStatementLog], which
/// times every statement as the UI isolate waits for it.
///
/// A function of its arguments rather than of the defines so a test can open
/// every combination; the defines are compile-time and cannot be set from a
/// test.
QueryExecutor appExecutor(
  String path, {
  required bool onUiIsolate,
  required bool perfLog,
}) {
  final QueryExecutor executor = onUiIsolate
      ? NativeDatabase(File(path), setup: waitOutLocks)
      : NativeDatabase.createInBackground(
          File(path),
          setup: waitOutLocks,
          isolateSetup: loadSqliteVecInIsolate,
        );
  return perfLog ? executor.interceptWith(SlowStatementLog()) : executor;
}

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
/// of consistent about which handles know what `vec0` is. The connection the
/// app then uses is opened after both, on the background isolate, and
/// [loadSqliteVecInIsolate] repeats the registration there because that
/// isolate's own once-only guard starts empty; SQLite treats the second
/// registration of the same entry point as a no-op.
///
/// [adoptLegacyDatabase] runs next, and has to: drift decides whether to
/// create the schema from `user_version`, which every pre-drift install still
/// reports as 0.
///
/// The connection itself lives on a background isolate ([appExecutor]: the
/// isolate is spawned as the executor is built, the connection opens there at
/// first use), so no statement steps on the UI isolate and a burst of SQL is
/// no longer a frozen frame. The trade: there is still one connection,
/// so a UI read now queues behind a long write on it — the screen stays live
/// and the data arrives later, instead of the frame freezing.
/// `BOND_DB_UI_ISOLATE` ([dbOnUiIsolate]) puts the same-isolate executor back,
/// for a before/after measurement on one build and as the way out if the
/// background executor misbehaves.
///
/// The `vec_version()` probe at the end is not decoration. It is the launch-log
/// line that says whether semantic search will work in this build, asked of the
/// connection that will actually serve it rather than of the loader's return
/// value — and that connection is now the BACKGROUND one, so the line proves
/// the isolate's connection knows `vec0`.
Future<BondDatabase> openAppDb() async {
  if (!ensureSqliteVecLoaded()) {
    debugPrint('sqlite-vec: native extension unavailable — '
        'semantic search will be off');
  }
  final path = await appDatabasePath();
  await adoptLegacyDatabase(path);
  final db = BondDatabase(
    appExecutor(path, onUiIsolate: dbOnUiIsolate, perfLog: perfLogOn),
  );
  try {
    final v = await db.customSelect('SELECT vec_version() AS v').getSingle();
    debugPrint('sqlite-vec ${v.data['v']}');
  } catch (e) {
    debugPrint('sqlite-vec: unavailable on this connection — $e');
  }
  return db;
}

/// Where the app's database file is, without opening it.
///
/// It exists so the About section can show the user where their data actually
/// lives, and so that answer and [openAppDb] can never disagree about the file
/// name: the literals this file uses are written once, in [databaseFileName],
/// and both callers go through this.
///
/// Locating a directory opens no connection, so this is safe to call on its
/// own — a settings screen asking where the file is must not be a second
/// database handle.
Future<String> appDatabasePath() async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, databaseFileName(sampleMode: sampleModeOn));
}

/// The database file's name: `bond_inbox.db`, or `bond_inbox-sample.db` for a
/// sample sandbox build (`BOND_SAMPLE_DIR`, see `sample_env.dart`).
///
/// The sandbox gets a file of its own because nothing else would keep the
/// two mailboxes apart: the identity guard runs only on a sign-in, and the
/// sandbox never signs in, so on the shared file the sample's rows would land
/// beside the real account's. With its own file, dropping the define puts the
/// owner straight back on the real account with nothing to clean up.
/// Attachment cache and model folders stay shared: the sandbox fetches no
/// bytes, so none of the sample reaches the cache.
///
/// A pure function of its argument so a test can pin both names; the define
/// itself is compile-time and cannot be set from a test.
String databaseFileName({required bool sampleMode}) =>
    sampleMode ? 'bond_inbox-sample.db' : 'bond_inbox.db';
