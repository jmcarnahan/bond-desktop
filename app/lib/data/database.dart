import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/internal/versioned_schema.dart';
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
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        // One transaction around the whole step walk. The bare `stepByStep`
        // helper runs the steps outside any transaction and drift stamps
        // `user_version` afterwards in a statement of its own — so a process
        // killed mid-migration (force-quit during the category remap of a
        // large mailbox) would leave columns added but the version unstamped,
        // and every later open would replay the ALTER into "duplicate column"
        // and never launch again. The transaction shrinks that exposure to
        // the COMMIT-to-stamp gap, and the column guards make a replay across
        // that residual gap a no-op instead of a crash.
        onUpgrade: (m, from, to) => transaction(
          () => VersionedSchema.runMigrationSteps(
            migrator: m,
            from: from,
            to: to,
            steps: migrationSteps(
              // v2 — the generalize round: triage gains a free-text `label`,
              // and the category taxonomy narrows from the eight
              // domain-specific buckets to work|personal|notification|other.
              // `personal` and `other` carry over; every other old value
              // described the same thing — mail about the user's work — so it
              // becomes `work`. `notification` only ever comes from fresh
              // triage. NULL (never triaged, or gated) stays NULL. The remap
              // is idempotent by construction, so only the ALTER is guarded.
              from1To2: (m, schema) async {
                if (!await _columnExists('messages', 'label')) {
                  await m.addColumn(schema.messages, schema.messages.label);
                }
                for (final table in ['messages', 'conversations']) {
                  await customStatement(
                    "UPDATE $table SET category = 'work' "
                    'WHERE category IS NOT NULL '
                    "AND category NOT IN ('personal', 'other')",
                  );
                }
              },
              // v3 — storylines gain a charter: one or two sentences of
              // membership criteria the confirm task judges candidates
              // against. `charter_locked` is set when the user edits it, so
              // later naming passes keep their hands off.
              from2To3: (m, schema) async {
                if (!await _columnExists('storylines', 'charter')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.charter,
                  );
                }
                if (!await _columnExists('storylines', 'charter_locked')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.charterLocked,
                  );
                }
              },
              // v4 — a draft carries the short answers as well as the long
              // one: up to two ready-to-send replies in `options_json`, and
              // `options_dismissed` so closing them keeps the row instead of
              // handing the auto-enqueue an excuse to write them again.
              from3To4: (m, schema) async {
                if (!await _columnExists('drafts', 'options_json')) {
                  await m.addColumn(schema.drafts, schema.drafts.optionsJson);
                }
                if (!await _columnExists('drafts', 'options_dismissed')) {
                  await m.addColumn(
                    schema.drafts,
                    schema.drafts.optionsDismissed,
                  );
                }
              },
              // v5 — triage v2 asks about the person, not just the text: was
              // the reader singled out (`addressed_me`, written at ingest by
              // each connector), does the sender expect an answer
              // (`reply_expected`), and by when (`deadline`). Every migrated
              // row reads "nobody singled me out, never judged, no date",
              // which is what the re-judgement pass in each sync looks for.
              from4To5: (m, schema) async {
                if (!await _columnExists('messages', 'addressed_me')) {
                  await m.addColumn(
                    schema.messages,
                    schema.messages.addressedMe,
                  );
                }
                if (!await _columnExists('messages', 'reply_expected')) {
                  await m.addColumn(
                    schema.messages,
                    schema.messages.replyExpected,
                  );
                }
                if (!await _columnExists('messages', 'deadline')) {
                  await m.addColumn(schema.messages, schema.messages.deadline);
                }
              },
              // v6 — every message settles: an eligible inbound message gets a
              // `message_notify` row the moment it lands, and that row moves
              // from 'pending' to 'notified' or 'suppressed' exactly once,
              // inside a deadline. The state lives on disk rather than in the
              // notifier so a crash between "the model is still thinking" and
              // "tell the user" cannot lose the message or announce it twice.
              //
              // `ix_messages_created` is on the OLD messages table — admission
              // filters on `created_at`, which nothing indexed before.
              from5To6: (m, schema) async {
                if (!await _tableExists('message_notify')) {
                  await m.createTable(schema.messageNotify);
                }
                // The generated `Index` entities carry bare `CREATE INDEX`,
                // which throws on a replay over a torn state; `m.createIndex`
                // has no guarded form, so the DDL is written out here with
                // IF NOT EXISTS. The names and columns match the generated
                // entities exactly, which is what the fresh-vs-migrated parity
                // test compares.
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_message_notify_open '
                  'ON message_notify(state, deadline_at)',
                );
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_messages_created '
                  'ON messages(created_at DESC)',
                );
              },
            ),
          ),
        ),
        beforeOpen: (details) async {
          // WAL is a no-op on an in-memory database (sqlite reports back
          // "memory"), which is why this is not conditional on the path.
          await customStatement('PRAGMA journal_mode=WAL;');
          await customStatement('PRAGMA foreign_keys=ON;');
        },
      );

  /// Whether [table] already carries [column] — how a migration step tells a
  /// first run from a replay over a torn state (steps committed, version
  /// stamp lost).
  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect(
      'SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2',
      variables: [Variable<String>(table), Variable<String>(column)],
    ).get();
    return rows.isNotEmpty;
  }

  /// Whether [table] exists at all — the same replay guard as [_columnExists],
  /// for a step that adds a whole table rather than a column.
  Future<bool> _tableExists(String table) async {
    final rows = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
      variables: [Variable<String>(table)],
    ).get();
    return rows.isNotEmpty;
  }
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
