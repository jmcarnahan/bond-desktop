import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/internal/versioned_schema.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import 'database.steps.dart';
import 'progress_sql.dart';

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
  int get schemaVersion => 11;

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
              // v7 — a storyline remembers the cluster it came from as well as
              // who is in it now. `member_hash` is rewritten by every
              // membership write, so a suggestion whose membership drifted
              // before the user dismissed it stopped matching the cluster the
              // next sweep rebuilt — and the app asked again about a group
              // already refused. `cluster_hash` is written once at proposal
              // time and never touched after.
              //
              // The backfill reads what auto-created rows already hold: their
              // `member_hash` was written as the cluster's hash at insert. For
              // an undrifted row that is exactly right; for a drifted one it
              // is the same wrong value the check uses today, so nothing is
              // lost. User-made storylines stay NULL — no cluster proposed
              // them, and none will ever match them.
              from6To7: (m, schema) async {
                if (!await _columnExists('storylines', 'cluster_hash')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.clusterHash,
                  );
                }
                await customStatement(
                  'UPDATE storylines SET cluster_hash = member_hash '
                  "WHERE created_by = 'auto' AND cluster_hash IS NULL",
                );
              },
              // v8 — the pipeline becomes something a person can watch.
              // `message_progress` carries one row per message: which stage it
              // reached, what the app decided, and whether the user needed to
              // know. `message_vectors` ships in the same step although
              // nothing writes it yet — one migration over a large mailbox is
              // cheaper than two, and the table is inert until then.
              //
              // The backfill is what makes the first launch after this update
              // show a mailbox rather than an empty screen, and it is the
              // longest statement this app has ever migrated with. Its shape
              // is dictated by one constraint: SCALAR SUBQUERIES throughout,
              // never a join. `storyline_members` holds a row per
              // (storyline, thread), so joining it would offer a
              // multi-storyline thread's messages twice and the INSERT would
              // trip its own primary key.
              //
              // Stage timestamps stay NULL on purpose. This app did not watch
              // the history it is describing, and a stamped time would be a
              // claim about when something happened that nobody observed.
              from7To8: (m, schema) async {
                if (!await _tableExists('message_progress')) {
                  await m.createTable(schema.messageProgress);
                }
                if (!await _tableExists('message_vectors')) {
                  await m.createTable(schema.messageVectors);
                }
                // Hand-written with IF NOT EXISTS for the v6 reason: the
                // generated `Index` entities carry bare `CREATE INDEX`, which
                // throws on a replay over a torn state. Names and columns match
                // the generated entities exactly, which is what the
                // fresh-vs-migrated parity test compares.
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_message_progress_feed '
                  'ON message_progress(received_at DESC, '
                  'source_message_id DESC)',
                );
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_message_progress_visible '
                  'ON message_progress(dropped, received_at DESC, '
                  'source_message_id DESC)',
                );
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_message_progress_conv '
                  'ON message_progress(source, conversation_key)',
                );
                await customStatement(
                  'CREATE UNIQUE INDEX IF NOT EXISTS ix_message_vectors_message '
                  'ON message_vectors(source, source_message_id)',
                );
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_message_vectors_unindexed '
                  'ON message_vectors(indexed_at)',
                );
                await customStatement(_backfillProgress);
              },
              // v9 — a suggested reply belongs to the message it answers.
              // `drafts` is re-keyed from the thread to the message, and
              // `message_progress` grows the stage that says where that reply
              // got to.
              //
              // The re-key is a table recreate because sqlite cannot alter a
              // primary key, and it is guarded on the key itself rather than
              // on a column: every column here already exists, so the only
              // thing that tells a first run from a replay over a torn state
              // is which columns the table's pk is made of.
              //
              // `INSERT OR IGNORE` is the other half of that guard. Message
              // ids are unique within a source, so a mailbox holding one draft
              // per thread cannot collide on the new key — but a replay that
              // half-ran must not fail on rows it already copied.
              //
              // The backfill writes a terminal state for EVERY row, open ones
              // included. Nothing will ever queue draft work for a message
              // stored before this version, so 'pending' would park those bars
              // forever; 'done' where a draft answers the message and
              // 'skipped' where none does is what the rows themselves say.
              // `draft_at` stays NULL for the v8 reason: this app did not
              // watch the history it is describing.
              from8To9: (m, schema) async {
                final pk = await customSelect(
                  "SELECT name FROM pragma_table_info('drafts') WHERE pk > 0",
                ).get();
                final keyedByMessage = pk.any(
                  (row) => row.data['name'] == 'reply_to_message_id',
                );
                if (!keyedByMessage) {
                  await customStatement('''
CREATE TABLE drafts_new (
  source TEXT NOT NULL DEFAULT 'email',
  conversation_key TEXT NOT NULL,
  reply_to_message_id TEXT NOT NULL,
  body TEXT NOT NULL,
  evidence TEXT,
  status TEXT NOT NULL DEFAULT 'suggested',
  graph_draft_id TEXT,
  web_link TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  options_json TEXT,
  options_dismissed INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source, reply_to_message_id)
) STRICT''');
                  await customStatement('''
INSERT OR IGNORE INTO drafts_new (
  source, conversation_key, reply_to_message_id, body, evidence, status,
  graph_draft_id, web_link, created_at, updated_at, options_json,
  options_dismissed
)
SELECT
  source, conversation_key, reply_to_message_id, body, evidence, status,
  graph_draft_id, web_link, created_at, updated_at, options_json,
  options_dismissed
FROM drafts''');
                  await customStatement('DROP TABLE drafts');
                  await customStatement(
                    'ALTER TABLE drafts_new RENAME TO drafts',
                  );
                }
                // Hand-written with IF NOT EXISTS for the v6 reason: the
                // generated `Index` entities carry bare `CREATE INDEX`, which
                // throws on a replay over a torn state.
                await customStatement(
                  'CREATE INDEX IF NOT EXISTS ix_drafts_conv '
                  'ON drafts(source, conversation_key)',
                );
                // One guard per column, the v3–v5 discipline: a quit between
                // the two ALTERs must not leave a replay that skips the
                // second because the first already exists.
                if (!await _columnExists('message_progress', 'draft_state')) {
                  await m.addColumn(
                    schema.messageProgress,
                    schema.messageProgress.draftState,
                  );
                }
                if (!await _columnExists('message_progress', 'draft_at')) {
                  await m.addColumn(
                    schema.messageProgress,
                    schema.messageProgress.draftAt,
                  );
                }
                // Unguarded, because it is idempotent and a guard would be a
                // hole: between a torn run and its replay the app never
                // opened, so re-deriving every row's answer changes nothing —
                // while skipping it on a replay that got the columns in would
                // leave the default 'pending' parked forever.
                await customStatement('''
UPDATE message_progress SET draft_state = CASE
  WHEN EXISTS (
    SELECT 1 FROM drafts d
     WHERE d.source = message_progress.source
       AND d.reply_to_message_id = message_progress.source_message_id
  ) THEN 'done' ELSE 'skipped' END''');
              },
              // v10 — a storyline keeps growing after it is named. The refresh
              // pass re-describes one whose membership moved
              // (`refreshed_member_hash` / `_count`, and `charter_suggestion`
              // when the charter is the user's and must not be overwritten),
              // and the recap pass says where things stand across its threads.
              // Nothing reads these columns yet; they land a version early so
              // the passes that fill them are code alone.
              //
              // One guard per column, the v3–v5 discipline: a quit between the
              // ALTERs must not leave a replay that skips the rest because the
              // first already exists.
              from9To10: (m, schema) async {
                if (!await _columnExists(
                  'storylines',
                  'refreshed_member_hash',
                )) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.refreshedMemberHash,
                  );
                }
                if (!await _columnExists(
                  'storylines',
                  'refreshed_member_count',
                )) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.refreshedMemberCount,
                  );
                }
                if (!await _columnExists('storylines', 'charter_suggestion')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.charterSuggestion,
                  );
                }
                if (!await _columnExists('storylines', 'recap_text')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.recapText,
                  );
                }
                if (!await _columnExists('storylines', 'recap_open_json')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.recapOpenJson,
                  );
                }
                if (!await _columnExists(
                  'storylines',
                  'recap_decisions_json',
                )) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.recapDecisionsJson,
                  );
                }
                if (!await _columnExists('storylines', 'recap_through')) {
                  await m.addColumn(
                    schema.storylines,
                    schema.storylines.recapThrough,
                  );
                }
                // A storyline that already reads well is marked "described as
                // it stands", so the upgrade itself asks the model nothing: the
                // refresh gate is `refreshed_member_hash == member_hash`, and
                // stamping it here makes every settled storyline skip its first
                // pass. A row missing a summary or a charter is left NULL so it
                // still gets its one first draft — the convergence contract the
                // naming pass already keeps.
                //
                // Copying `member_hash` verbatim is right even though the hash
                // recipe changed this round: the gate is an equality test
                // against whatever that column holds now, not a claim about how
                // it was computed. `IS NULL` makes the statement idempotent, so
                // a replay over a torn state re-stamps nothing.
                await customStatement('''
UPDATE storylines
   SET refreshed_member_hash = member_hash,
       refreshed_member_count = (
         SELECT COUNT(*) FROM storyline_members m
          WHERE m.storyline_id = storylines.id
       )
 WHERE refreshed_member_hash IS NULL
   AND summary IS NOT NULL AND TRIM(summary) != ''
   AND charter IS NOT NULL AND TRIM(charter) != ''
''');
              },
              // v11 — the needs-you pass gets a place to put its answer.
              // `needs_you_verdict` is tri-state and `needs_you_reason` says
              // what stands behind it.
              //
              // No backfill, and that is the design rather than an omission:
              // NULL means nobody has judged this row, so every migrated
              // message is exactly what the pass is looking for. Writing a 0
              // here would claim a verdict this app never reached, and take
              // the whole stored mailbox out of the worklist on the way.
              //
              // One guard per column, the v3–v5 discipline: a quit between
              // the two ALTERs must not leave a replay that skips the second
              // because the first already exists.
              from10To11: (m, schema) async {
                if (!await _columnExists('messages', 'needs_you_verdict')) {
                  await m.addColumn(
                    schema.messages,
                    schema.messages.needsYouVerdict,
                  );
                }
                if (!await _columnExists('messages', 'needs_you_reason')) {
                  await m.addColumn(
                    schema.messages,
                    schema.messages.needsYouReason,
                  );
                }
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

/// The v8 backfill: one row of `message_progress` per stored message, with
/// every stage read back out of what the pipeline already wrote.
///
/// Three nested SELECTs rather than one, because sqlite cannot refer to an
/// output alias from the same SELECT list and the alternative is the same
/// dozen-line CASE spelled out four times. The innermost derives the per-stage
/// states from the tables that hold them, the middle turns those into the
/// settle verdict and the drop flags, and the outer composes the outcome.
///
/// The derivations worth stating:
/// - An ABSENT work row is a terminal state, not a missing one. A message the
///   extractor was never queued for is `skipped`, so its bar stops instead of
///   waiting forever on work nothing will ever enqueue.
/// - A gated message lands fully resolved and dropped, keyed on `gate_reason`
///   rather than on `triage_status` alone: `skipped` with no reason is the
///   legacy Teams tolerance, not a verdict about the message.
/// - `needs_you` is judged against a literal threshold ([needsYouSql]) because
///   a migration must not read preferences; rows still open when the app
///   launches are restated by the first settle sweep.
/// - That SQL is also frozen at its v8 SHAPE, which is what `verdict: false`
///   asks for. This migration replays whenever a v1..v7 database is opened by a
///   build at v10 or beyond, and `messages.needs_you_verdict` does not exist
///   until v10 — widening the predicate here would make `from7To8` throw
///   "no such column" on exactly those upgrades. `test/migration_test.dart` is
///   the detector.
final String _backfillProgress = '''
INSERT OR IGNORE INTO message_progress (
  source, source_message_id, conversation_key, received_at,
  ingest_state, triage_state, extract_state, storyline_state, settle_state,
  triage_at, extract_at, storyline_at, settle_at,
  outcome, dropped, drop_reason, storyline_id, needs_you, urgency,
  created_at, updated_at
)
SELECT
  e.source, e.source_message_id, e.conversation_key, e.received_at,
  'done', e.triage_state, e.extract_state, e.storyline_state, e.settle_state,
  NULL, NULL, NULL, NULL,
  CASE
    WHEN e.dropped = 1 THEN 'dropped'
    WHEN e.triage_state IN ('done', 'skipped', 'error')
     AND e.extract_state IN ('done', 'skipped', 'error')
     AND e.storyline_state IN ('done', 'skipped', 'error')
     AND e.settle_state IN ('done', 'skipped', 'error') THEN 'done'
    ELSE 'pending'
  END,
  e.dropped, e.drop_reason, e.storyline_id, e.needs_you, e.urgency,
  e.created_at, e.updated_at
FROM (
  SELECT d.*,
    CASE
      WHEN d.gated = 1 THEN 'done'
      WHEN d.notify_state IN ('notified', 'suppressed') THEN 'done'
      WHEN d.notify_state = 'pending' THEN 'pending'
      ELSE 'skipped'
    END AS settle_state,
    CASE
      WHEN d.gated = 1 THEN 1
      WHEN d.notify_state = 'suppressed'
       AND d.notify_reason IN ('gated', 'not_worthy') THEN 1
      ELSE 0
    END AS dropped,
    CASE
      WHEN d.gated = 1 THEN d.gate_reason
      WHEN d.notify_state = 'suppressed'
       AND d.notify_reason IN ('gated', 'not_worthy')
        THEN d.notify_reason
      ELSE NULL
    END AS drop_reason
  FROM (
    SELECT
      m.source AS source,
      m.source_message_id AS source_message_id,
      m.conversation_key AS conversation_key,
      COALESCE(m.received_at, m.created_at) AS received_at,
      m.urgency AS urgency,
      m.gate_reason AS gate_reason,
      m.created_at AS created_at,
      m.updated_at AS updated_at,
      CASE
        WHEN m.triage_status = 'skipped' AND m.gate_reason IS NOT NULL THEN 1
        ELSE 0
      END AS gated,
      CASE m.triage_status
        WHEN 'triaged' THEN 'done'
        WHEN 'skipped' THEN 'skipped'
        WHEN 'error' THEN 'error'
        WHEN 'processing' THEN 'running'
        ELSE 'pending'
      END AS triage_state,
      CASE
        WHEN EXISTS (SELECT 1 FROM message_ai a
                      WHERE a.source = m.source
                        AND a.source_message_id = m.source_message_id
                        AND a.extraction_json IS NOT NULL) THEN 'done'
        WHEN m.triage_status = 'skipped' THEN 'skipped'
        ELSE COALESCE((
          SELECT CASE w.status
                   WHEN 'done' THEN 'done'
                   WHEN 'error' THEN 'error'
                   WHEN 'processing' THEN 'running'
                   ELSE 'pending'
                 END
            FROM work_items w
           WHERE w.task_kind = 'extract' AND w.source = m.source
             AND w.entity_id = m.source_message_id), 'skipped')
      END AS extract_state,
      CASE
        WHEN EXISTS (SELECT 1 FROM storyline_members sm
                      WHERE sm.source = m.source
                        AND sm.conversation_key = m.conversation_key) THEN 'done'
        WHEN m.triage_status = 'skipped' THEN 'skipped'
        ELSE COALESCE((
          SELECT CASE w.status
                   WHEN 'done' THEN 'done'
                   WHEN 'error' THEN 'error'
                   WHEN 'processing' THEN 'running'
                   ELSE 'pending'
                 END
            FROM work_items w
           WHERE w.task_kind = 'storyline' AND w.source = m.source
             AND w.entity_id = m.conversation_key), 'skipped')
      END AS storyline_state,
      (SELECT sm.storyline_id
         FROM storyline_members sm
         JOIN storylines s ON s.id = sm.storyline_id
        WHERE sm.source = m.source AND sm.conversation_key = m.conversation_key
          AND s.status IN ('suggested', 'active')
        ORDER BY sm.added_at ASC LIMIT 1) AS storyline_id,
      (SELECT n.state FROM message_notify n
        WHERE n.source = m.source
          AND n.source_message_id = m.source_message_id) AS notify_state,
      (SELECT n.reason FROM message_notify n
        WHERE n.source = m.source
          AND n.source_message_id = m.source_message_id) AS notify_reason,
      ${needsYouSql(threshold: backfillNeedsYouThreshold, verdict: false)} AS needs_you
    FROM messages m
  ) d
) e
''';

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
