import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// The on-disk store. One sqlite file under the app support directory; the
/// schema is applied on every open (all DDL is IF NOT EXISTS), so there is no
/// separate migration step yet.
///
/// Every table is STRICT: a value whose storage class does not match its
/// column type is rejected at write time rather than coerced, so a TEXT
/// timestamp landing in an INTEGER count fails loudly here instead of
/// surfacing as a wrong number three screens away.

/// Opens a database at [path] and applies the schema. `':memory:'` gets a
/// private in-memory database — the synchronous entry point tests use.
Database openDbAt(String path) {
  final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
  applySchema(db);
  return db;
}

/// The app's real database: `bond_inbox.db` in the platform application
/// support directory. Async only because locating that directory is.
Future<Database> openAppDb() async {
  final dir = await getApplicationSupportDirectory();
  return openDbAt(p.join(dir.path, 'bond_inbox.db'));
}

/// Pragmas + DDL. Idempotent; safe to call on an already-populated database.
void applySchema(Database db) {
  // WAL is a no-op on an in-memory database (sqlite reports back "memory"),
  // which is why this is not conditional on the path.
  db.execute('PRAGMA journal_mode=WAL;');
  db.execute('PRAGMA foreign_keys=ON;');
  db.execute(_ddl);
}

const String _ddl = '''
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
''';
