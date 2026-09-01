import 'package:bond_inbox/data/database.dart';
import 'package:drift/drift.dart';

/// A private in-memory database with the schema already created.
///
/// Every test that opens one must `await db.close()` in `tearDown`: drift
/// holds the connection open, and a suite that leaks them exhausts the
/// process rather than failing on the test that leaked.
BondDatabase testDb() {
  // A suite opens one database per test, and several open a second one inside
  // a test. Drift's warning about that is aimed at an app holding two
  // connections to the same file; here every instance is its own private
  // in-memory database, so the warning is only noise in the test output.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return BondDatabase.memory();
}
