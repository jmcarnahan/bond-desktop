import 'package:bond_inbox/data/database.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'test_db.dart';

/// A [testDb] whose connection knows what `vec0` is.
///
/// Only the tests that exercise `MessageVectorIndex` need this. Registering
/// sqlite-vec is process-global and applies to every connection opened
/// afterwards, so it is the kind of thing that quietly changes the world for
/// suites that never asked — which is exactly why it lives in a fixture with a
/// name on it rather than inside [testDb]. What it changes is harmless (a few
/// SQL functions and a virtual-table module come into existence; nothing
/// creates a table, and no query that worked before behaves differently), but
/// a test that depends on it should have to say so.
BondDatabase vecTestDb() {
  ensureSqliteVecLoaded();
  return testDb();
}
