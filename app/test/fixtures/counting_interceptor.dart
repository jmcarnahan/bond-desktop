import 'package:bond_inbox/data/database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// Counts what reaches the database, by kind of call: how a test proves a
/// pass made ONE batch and no single-statement write, or that a read did not
/// happen at all.
///
/// [reset] after the seeding, so only the calls under test are counted.
class CountingInterceptor extends QueryInterceptor {
  int batched = 0;
  int inserts = 0;
  int updates = 0;
  int deletes = 0;
  int customs = 0;

  /// Every SELECT's text, in order.
  final List<String> selects = [];

  /// Every write that is not a batch.
  int get singleWrites => inserts + updates + deletes + customs;

  void reset() {
    batched = 0;
    inserts = 0;
    updates = 0;
    deletes = 0;
    customs = 0;
    selects.clear();
  }

  @override
  Future<void> runBatched(QueryExecutor executor, BatchedStatements statements) {
    batched++;
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    inserts++;
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    updates++;
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    deletes++;
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    customs++;
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add(statement);
    return super.runSelect(executor, statement, args);
  }
}

/// A private in-memory database, as `testDb()` opens, whose every call goes
/// through [counter]. Close it in `tearDown` like any other.
BondDatabase countingTestDb(CountingInterceptor counter) {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return BondDatabase(NativeDatabase.memory().interceptWith(counter));
}
