import 'dart:io';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

/// The schema exactly as the pre-drift app wrote it, kept here verbatim so
/// these tests build a real legacy file rather than one drift produced. This
/// const is the only copy left; `lib/data/db.dart` no longer holds DDL.
const String legacyDdl = '''
CREATE TABLE IF NOT EXISTS messages (
  source TEXT NOT NULL DEFAULT 'email',
  source_message_id TEXT NOT NULL,
  internet_message_id TEXT,
  conversation_key TEXT NOT NULL,
  direction TEXT NOT NULL,
  subject TEXT,
  from_name TEXT,
  from_address TEXT,
  to_json TEXT NOT NULL DEFAULT '[]',
  received_at TEXT,
  is_read INTEGER NOT NULL DEFAULT 0,
  body_preview TEXT,
  body_text TEXT,
  has_attachments INTEGER NOT NULL DEFAULT 0,
  source_meta_json TEXT,
  triage_status TEXT NOT NULL DEFAULT 'pending',
  triage_attempts INTEGER NOT NULL DEFAULT 0,
  triage_error TEXT,
  gate_reason TEXT,
  urgency TEXT,
  category TEXT,
  summary TEXT,
  needs_action INTEGER,
  action_items_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (source, source_message_id)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_messages_conv ON messages(source, conversation_key, received_at);
CREATE INDEX IF NOT EXISTS ix_messages_triage ON messages(triage_status, received_at DESC);
CREATE TABLE IF NOT EXISTS conversations (
  source TEXT NOT NULL DEFAULT 'email',
  conversation_key TEXT NOT NULL,
  subject TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  state TEXT NOT NULL DEFAULT 'done',
  category TEXT,
  cta_text TEXT,
  cta_urgency TEXT NOT NULL DEFAULT 'normal',
  message_count INTEGER NOT NULL DEFAULT 0,
  inbound_count INTEGER NOT NULL DEFAULT 0,
  last_inbound_at TEXT,
  last_outbound_at TEXT,
  last_message_at TEXT,
  last_message_preview TEXT,
  state_changed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (source, conversation_key)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_conv_last ON conversations(last_message_at DESC);
CREATE TABLE IF NOT EXISTS sync_state (
  source TEXT NOT NULL DEFAULT 'email',
  folder TEXT NOT NULL,
  delta_link TEXT,
  synced_at TEXT,
  PRIMARY KEY (source, folder)
) STRICT;
CREATE TABLE IF NOT EXISTS work_items (
  task_kind TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'email',
  entity_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  payload_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (task_kind, source, entity_id)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_work_pending ON work_items(task_kind, status, created_at DESC);
CREATE TABLE IF NOT EXISTS message_ai (
  source TEXT NOT NULL DEFAULT 'email',
  source_message_id TEXT NOT NULL,
  extraction_json TEXT,
  extracted_at TEXT,
  PRIMARY KEY (source, source_message_id)
) STRICT;
CREATE TABLE IF NOT EXISTS conversation_ai (
  source TEXT NOT NULL DEFAULT 'email',
  conversation_key TEXT NOT NULL,
  embedding BLOB,
  embedded_hash TEXT,
  embed_model TEXT,
  bucket TEXT,
  bucket_reason TEXT,
  attention_score REAL,
  snoozed_until TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (source, conversation_key)
) STRICT;
CREATE TABLE IF NOT EXISTS storylines (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  summary TEXT,
  status TEXT NOT NULL DEFAULT 'suggested',
  created_by TEXT NOT NULL DEFAULT 'auto',
  title_locked INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  member_hash TEXT,
  last_activity_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS ix_storylines_status ON storylines(status, last_activity_at DESC);
CREATE TABLE IF NOT EXISTS storyline_members (
  storyline_id TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'email',
  conversation_key TEXT NOT NULL,
  added_by TEXT NOT NULL DEFAULT 'auto',
  evidence TEXT,
  added_at TEXT NOT NULL,
  PRIMARY KEY (storyline_id, source, conversation_key)
) STRICT;
CREATE INDEX IF NOT EXISTS ix_storyline_members_conv
  ON storyline_members(source, conversation_key);
CREATE TABLE IF NOT EXISTS storyline_member_blocks (
  storyline_id TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'email',
  conversation_key TEXT NOT NULL,
  blocked_at TEXT NOT NULL,
  PRIMARY KEY (storyline_id, source, conversation_key)
) STRICT;
CREATE TABLE IF NOT EXISTS feedback_events (
  id INTEGER PRIMARY KEY,
  scope TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  direction TEXT NOT NULL,
  origin TEXT NOT NULL,
  created_at TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS ix_feedback_scope
  ON feedback_events(scope, scope_key, created_at DESC);
CREATE TABLE IF NOT EXISTS activity_events (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  source TEXT,
  status TEXT NOT NULL,
  entity_id TEXT,
  count INTEGER,
  duration_ms INTEGER,
  detail_json TEXT,
  created_at TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS ix_activity_created
  ON activity_events(created_at DESC);
CREATE INDEX IF NOT EXISTS ix_activity_kind
  ON activity_events(kind, created_at DESC);
CREATE TABLE IF NOT EXISTS sender_prefs (
  address TEXT PRIMARY KEY,
  disposition TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS app_prefs (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS drafts (
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
  PRIMARY KEY (source, conversation_key)
) STRICT;
''';

/// Writes a pre-drift database: the old DDL, the old pragmas, and
/// `user_version` left at its default 0 — the state every shipped install is
/// in.
void writeLegacyDb(String path, {int messageCount = 1}) {
  final db = raw.sqlite3.open(path);
  db.execute('PRAGMA journal_mode=WAL;');
  db.execute('PRAGMA foreign_keys=ON;');
  db.execute(legacyDdl);
  for (var i = 0; i < messageCount; i++) {
    db.execute(
      'INSERT INTO messages (source, source_message_id, conversation_key, '
      'direction, subject, body_text, received_at, triage_status, '
      'created_at, updated_at) '
      "VALUES ('email', ?, 'conv-1', 'inbound', ?, 'body', "
      "'2026-01-0${i + 1}T00:00:00Z', 'pending', "
      "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
      ['msg-$i', 'Subject $i'],
    );
  }
  db.close();
}

int userVersionOf(String path) {
  final db = raw.sqlite3.open(path);
  final v = db.select('PRAGMA user_version').first.values.first as int;
  db.close();
  return v;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bond_adopt_');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a pre-drift database is adopted, not recreated', () async {
    final path = '${dir.path}/bond_inbox.db';
    writeLegacyDb(path, messageCount: 3);
    expect(userVersionOf(path), 0, reason: 'the legacy file starts unversioned');

    await adoptLegacyDatabase(path);
    expect(userVersionOf(path), 1);

    final db = BondDatabase.open(path);
    final store = MessageStore(db);
    addTearDown(db.close);

    // The seeded rows survive: nothing was dropped and recreated.
    final count = await db
        .customSelect('SELECT COUNT(*) AS n FROM messages')
        .getSingle();
    expect(count.data['n'], 3);

    final row = await store.getMessageRow('email', 'msg-1');
    expect(row, isNotNull);
    expect(row!['subject'], 'Subject 1');
    expect(row['body_text'], 'body');

    // And the adopted file takes writes.
    await store.writeTriage('email', 'msg-1', status: 'triaged');
    expect((await store.getMessageRow('email', 'msg-1'))!['triage_status'],
        'triaged');

    // The version survives the open — drift must not have run onCreate.
    expect(userVersionOf(path), 1);
  });

  test('a fresh path is created by drift and round-trips', () async {
    final path = '${dir.path}/fresh.db';
    expect(File(path).existsSync(), isFalse);

    // A no-op on a file that is not there; openAppDb calls it unconditionally.
    await adoptLegacyDatabase(path);

    final db = BondDatabase.open(path);
    final store = MessageStore(db);
    addTearDown(db.close);

    await store.upsertMessage({
      'source_message_id': 'm1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Hello',
      'body_text': 'world',
      'received_at': '2026-02-01T00:00:00Z',
    });
    final row = await store.getMessageRow('email', 'm1');
    expect(row!['subject'], 'Hello');
    expect(row['triage_status'], 'pending');
    expect(userVersionOf(path), 1);
  });

  test('drift creates the same tables, columns and indexes as the old DDL',
      () async {
    // The hard constraint of the whole port: an install created by drift and
    // one created by the pre-drift DDL must be the same database. Compared on
    // `table_info` and the index list rather than the stored SQL text, which
    // differs harmlessly in quoting and whitespace.
    final legacyPath = '${dir.path}/legacy.db';
    writeLegacyDb(legacyPath, messageCount: 0);
    final legacy = raw.sqlite3.open(legacyPath);
    addTearDown(legacy.close);

    final freshPath = '${dir.path}/drift.db';
    final drift = BondDatabase.open(freshPath);
    await drift.customSelect('SELECT 1').get(); // force the schema to be built
    await drift.close();
    final fresh = raw.sqlite3.open(freshPath);
    addTearDown(fresh.close);

    List<String> tablesOf(raw.Database db) => [
          for (final r in db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name",
          ))
            r['name'] as String,
        ];
    expect(tablesOf(fresh), tablesOf(legacy));
    expect(tablesOf(fresh).length, 14);

    for (final table in tablesOf(legacy)) {
      List<String> columnsOf(raw.Database db) => [
            for (final r in db.select('PRAGMA table_info($table)'))
              '${r['name']}|${r['type']}|${r['notnull']}|${r['dflt_value']}|${r['pk']}',
          ];
      expect(columnsOf(fresh), columnsOf(legacy), reason: 'columns of $table');

      // STRICT is not in table_info; it shows up as a rejected write.
      expect(
        fresh.select("SELECT sql FROM sqlite_master WHERE name = '$table'").first['sql'],
        contains('STRICT'),
        reason: '$table must stay STRICT',
      );
    }

    List<String> indexesOf(raw.Database db) => [
          for (final r in db.select(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND sql IS NOT NULL ORDER BY name",
          ))
            r['name'] as String,
        ];
    expect(indexesOf(fresh), indexesOf(legacy));
  });

  test('sqlite is at least 3.35, which UPDATE ... RETURNING needs', () async {
    final db = BondDatabase.memory();
    addTearDown(db.close);
    final row =
        await db.customSelect('SELECT sqlite_version() AS v').getSingle();
    final version = row.data['v'] as String;

    final parts = version.split('.').map(int.parse).toList();
    expect(parts.length, greaterThanOrEqualTo(3), reason: 'version $version');
    final numeric = parts[0] * 1000000 + parts[1] * 1000 + parts[2];
    expect(
      numeric,
      greaterThanOrEqualTo(3 * 1000000 + 35 * 1000),
      reason: 'sqlite $version is older than 3.35.0',
    );
  });
}
