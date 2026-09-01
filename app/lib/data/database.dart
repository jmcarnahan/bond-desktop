import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import 'database.steps.dart';

part 'database.g.dart';

/// The on-disk store. One sqlite file under the app support directory, with
/// its shape declared in `schema.drift` and its version tracked by drift, so
/// a schema change from here on is a numbered migration rather than a set of
/// `IF NOT EXISTS` statements re-run on every open.
///
/// Every table is STRICT: a value whose storage class does not match its
/// column type is rejected at write time rather than coerced, so a TEXT
/// timestamp landing in an INTEGER count fails loudly here instead of
/// surfacing as a wrong number three screens away.
///
/// The executor is the same-isolate [NativeDatabase], not
/// `NativeDatabase.createInBackground`: the store this backs was synchronous
/// until now, and moving the work to a second isolate at the same time as
/// making the calls async would change two things at once.
@DriftDatabase(include: {'schema.drift'})
class BondDatabase extends _$BondDatabase {
  BondDatabase.open(String path) : super(NativeDatabase(File(path)));

  /// A private in-memory database — what tests open.
  BondDatabase.memory() : super(NativeDatabase.memory());

  /// Any executor the caller hands over — what the generated migration test
  /// in `test/drift/bond/` opens (it verifies each step against the schema
  /// snapshots in `drift_schemas/bond/`).
  BondDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: stepByStep(
          // v2 — the generalize round: triage gains a free-text `label`, and
          // the category taxonomy narrows from the eight domain-specific
          // buckets to work|personal|notification|other. `personal` and
          // `other` carry over; every other old value described the same
          // thing — mail about the user's work — so it becomes `work`.
          // `notification` only ever comes from fresh triage. NULL (never
          // triaged, or gated) stays NULL.
          from1To2: (m, schema) async {
            await m.addColumn(schema.messages, schema.messages.label);
            for (final table in ['messages', 'conversations']) {
              await customStatement(
                "UPDATE $table SET category = 'work' "
                'WHERE category IS NOT NULL '
                "AND category NOT IN ('personal', 'other')",
              );
            }
          },
        ),
        beforeOpen: (details) async {
          // WAL is a no-op on an in-memory database (sqlite reports back
          // "memory"), which is why this is not conditional on the path.
          await customStatement('PRAGMA journal_mode=WAL;');
          await customStatement('PRAGMA foreign_keys=ON;');
        },
      );
}

/// Claims a pre-drift database as schema version 1.
///
/// Every install that shipped before drift has all fourteen tables and a
/// `user_version` of 0 — the DDL was applied on every open and the pragma was
/// never written. A fresh file reads 0 as well, and drift can only tell those
/// two apart by the version, so left alone it would take an existing mailbox
/// for a new one and run `onCreate` against tables that already exist.
///
/// Stamping the version is the whole migration: the file already has exactly
/// the shape `schema.drift` describes. Must run BEFORE [BondDatabase.open]
/// touches the file.
Future<void> adoptLegacyDatabase(String path) async {
  if (!File(path).existsSync()) return;
  final db = raw.sqlite3.open(path);
  try {
    final version = db.select('PRAGMA user_version').first.values.first;
    if ((version as int?) != 0) return;
    // `messages` stands in for the whole schema: the old DDL was one
    // statement batch, so a file that has this table has all of them.
    final adopted = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages' "
      'LIMIT 1',
    );
    if (adopted.isEmpty) return;
    db.execute('PRAGMA user_version = 1');
  } finally {
    db.close();
  }
}
