import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../models/message_models.dart';

/// Every SQL statement in the app except the schema itself lives here. Screens
/// and providers call methods; they never build a query.
///
/// Two conventions every write below follows:
/// - booleans bind as explicit `0`/`1` integers. The sqlite3 package would
///   coerce a Dart `bool` for us, but the reads compare against `1`, and a
///   write that says what it stores is one less thing to hold in your head.
/// - `created_at` / `updated_at` are NOT NULL, so a caller that omits them
///   gets "now" rather than a constraint failure.
class MessageStore {
  final Database db;

  MessageStore(this.db);

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// `?, ?, ?` for an IN clause of [n] values.
  static String _placeholders(int n) => List.filled(n, '?').join(', ');

  // ── messages ─────────────────────────────────────────────────────────

  /// Inserts a message, or folds a re-sync of one already stored.
  ///
  /// The conflict branch updates only what a re-fetch can legitimately know
  /// better: read state and the text fields. It COALESCEs the text so a
  /// lighter payload (a delta that carries no body) cannot erase a body
  /// already stored, and it never touches the triage columns — those belong
  /// to [writeTriage], and a re-sync must not undo a completed triage.
  ///
  /// `triage_status` / `gate_reason` are honoured on INSERT only, which is
  /// what makes the sync's backlog rule ("everything older than a week
  /// arrives already skipped") safe to evaluate on every page: a message
  /// seen again — or already triaged — keeps whatever it has.
  void upsertMessage(Map<String, Object?> row) {
    final now = _nowIso();
    db.execute(
      '''
INSERT INTO messages (
  source, source_message_id, internet_message_id, conversation_key, direction,
  subject, from_name, from_address, to_json, received_at, is_read,
  body_preview, body_text, has_attachments, source_meta_json,
  triage_status, gate_reason,
  created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(source, source_message_id) DO UPDATE SET
  is_read = excluded.is_read,
  subject = COALESCE(excluded.subject, messages.subject),
  body_preview = COALESCE(excluded.body_preview, messages.body_preview),
  body_text = COALESCE(excluded.body_text, messages.body_text),
  updated_at = excluded.updated_at
''',
      [
        row['source'] ?? 'email',
        row['source_message_id'],
        row['internet_message_id'],
        row['conversation_key'],
        row['direction'],
        row['subject'],
        row['from_name'],
        row['from_address'],
        row['to_json'] ?? '[]',
        row['received_at'],
        row['is_read'] ?? 0,
        row['body_preview'],
        row['body_text'],
        row['has_attachments'] ?? 0,
        row['source_meta_json'],
        row['triage_status'] ?? 'pending',
        row['gate_reason'],
        row['created_at'] ?? now,
        row['updated_at'] ?? now,
      ],
    );
  }

  /// Whether this `(source, id)` is already stored.
  ///
  /// Asked BEFORE the upsert, because afterwards there is no way to tell an
  /// insert from a conflict — and the sync needs to know, since a message
  /// must be folded into its conversation exactly once no matter how many
  /// times a delta feed replays it.
  bool hasMessage(String source, String sourceMessageId) {
    final result = db.select(
      'SELECT 1 FROM messages WHERE source = ? AND source_message_id = ? LIMIT 1',
      [source, sourceMessageId],
    );
    return result.isNotEmpty;
  }

  /// Writes what only the per-message detail fetch knows. Every column
  /// COALESCEs against itself, so a detail call that came back thin cannot
  /// blank a body, a header set, or an attachment flag already stored.
  void updateMessageDetail(
    String source,
    String sourceMessageId, {
    String? bodyText,
    bool? hasAttachments,
    String? sourceMetaJson,
  }) {
    db.execute(
      'UPDATE messages SET '
      'body_text = COALESCE(?, body_text), '
      'has_attachments = COALESCE(?, has_attachments), '
      'source_meta_json = COALESCE(?, source_meta_json), '
      'updated_at = ? '
      'WHERE source = ? AND source_message_id = ?',
      [
        bodyText,
        hasAttachments == null ? null : (hasAttachments ? 1 : 0),
        sourceMetaJson,
        _nowIso(),
        source,
        sourceMessageId,
      ],
    );
  }

  /// One thread, oldest first — the order the chat transcript renders in.
  List<Message> loadThread(
    String conversationKey, {
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const [];
    final result = db.select(
      'SELECT * FROM messages '
      'WHERE conversation_key = ? AND source IN (${_placeholders(sources.length)}) '
      'ORDER BY received_at ASC',
      [conversationKey, ...sources],
    );
    return [for (final row in result) Message.fromRow(row)];
  }

  // ── conversations ────────────────────────────────────────────────────

  void upsertConversation(Map<String, Object?> row) {
    final now = _nowIso();
    db.execute(
      '''
INSERT INTO conversations (
  source, conversation_key, subject, participants_json, state, category,
  cta_text, cta_urgency, message_count, inbound_count, last_inbound_at,
  last_outbound_at, last_message_at, last_message_preview, state_changed_at,
  created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(source, conversation_key) DO UPDATE SET
  subject = COALESCE(excluded.subject, conversations.subject),
  participants_json = excluded.participants_json,
  state = excluded.state,
  category = COALESCE(excluded.category, conversations.category),
  cta_text = excluded.cta_text,
  cta_urgency = excluded.cta_urgency,
  message_count = excluded.message_count,
  inbound_count = excluded.inbound_count,
  last_inbound_at = COALESCE(excluded.last_inbound_at, conversations.last_inbound_at),
  last_outbound_at = COALESCE(excluded.last_outbound_at, conversations.last_outbound_at),
  last_message_at = COALESCE(excluded.last_message_at, conversations.last_message_at),
  last_message_preview = COALESCE(excluded.last_message_preview, conversations.last_message_preview),
  updated_at = excluded.updated_at
''',
      [
        row['source'] ?? 'email',
        row['conversation_key'],
        row['subject'],
        row['participants_json'] ?? '[]',
        row['state'] ?? 'done',
        row['category'],
        row['cta_text'],
        row['cta_urgency'] ?? 'normal',
        row['message_count'] ?? 0,
        row['inbound_count'] ?? 0,
        row['last_inbound_at'],
        row['last_outbound_at'],
        row['last_message_at'],
        row['last_message_preview'],
        row['state_changed_at'],
        row['created_at'] ?? now,
        row['updated_at'] ?? now,
      ],
    );
  }

  /// One conversation row as stored, or null. The sync reads this before it
  /// folds a message so the state machine can see the thread's own history —
  /// including a `done` a human set, which no incoming message may quietly
  /// overwrite.
  Map<String, Object?>? getConversationRow(String source, String conversationKey) {
    final result = db.select(
      'SELECT * FROM conversations WHERE source = ? AND conversation_key = ?',
      [source, conversationKey],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// Recounts one thread from the messages table.
  ///
  /// Counts are derived, never incremented: a delta page can replay messages
  /// already stored, and an incremented counter would drift a little further
  /// on every replay with nothing to correct it.
  void recomputeConversationCounts(String source, String conversationKey) {
    db.execute(
      '''
UPDATE conversations SET
  message_count = (
    SELECT COUNT(*) FROM messages
    WHERE messages.source = conversations.source
      AND messages.conversation_key = conversations.conversation_key
  ),
  inbound_count = (
    SELECT COUNT(*) FROM messages
    WHERE messages.source = conversations.source
      AND messages.conversation_key = conversations.conversation_key
      AND messages.direction = 'inbound'
  ),
  updated_at = ?
WHERE source = ? AND conversation_key = ?
''',
      [_nowIso(), source, conversationKey],
    );
  }

  /// The inbox list, newest thread first.
  List<Conversation> loadConversations({
    List<String> sources = const ['email'],
    ConversationState? state,
  }) {
    if (sources.isEmpty) return const [];
    final where = StringBuffer('source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...sources];
    if (state != null) {
      where.write(' AND state = ?');
      args.add(state.wire);
    }
    final result = db.select(
      'SELECT * FROM conversations WHERE $where ORDER BY last_message_at DESC',
      args,
    );
    return [for (final row in result) Conversation.fromRow(row)];
  }

  /// Flips a thread's state and stamps when it happened — "done 3 days ago"
  /// is a different row from "done just now", and only this write knows.
  void setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) {
    final now = _nowIso();
    db.execute(
      'UPDATE conversations SET state = ?, state_changed_at = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      [state.wire, now, now, source, conversationKey],
    );
  }

  // ── sync state ───────────────────────────────────────────────────────

  String? getDeltaLink(String folder, {String source = 'email'}) {
    final result = db.select(
      'SELECT delta_link FROM sync_state WHERE source = ? AND folder = ?',
      [source, folder],
    );
    if (result.isEmpty) return null;
    return result.first['delta_link'] as String?;
  }

  void setDeltaLink(String folder, String? link, {String source = 'email'}) {
    db.execute(
      'INSERT INTO sync_state (source, folder, delta_link, synced_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(source, folder) DO UPDATE SET '
      'delta_link = excluded.delta_link, synced_at = excluded.synced_at',
      [source, folder, link, _nowIso()],
    );
  }

  // ── triage ───────────────────────────────────────────────────────────

  /// `triage_status` → count. Statuses with no rows are simply absent.
  Map<String, int> triageCounts({List<String> sources = const ['email']}) {
    if (sources.isEmpty) return const {};
    final result = db.select(
      'SELECT triage_status, COUNT(*) AS n FROM messages '
      'WHERE source IN (${_placeholders(sources.length)}) '
      'GROUP BY triage_status',
      [...sources],
    );
    return {
      for (final row in result)
        (row['triage_status'] as String? ?? 'pending'):
            (row['n'] as num?)?.toInt() ?? 0,
    };
  }

  /// The next message for the triage worker: newest first, inbound only.
  ///
  /// Newest first, not oldest: the worker runs behind a live mailbox, so the
  /// mail worth classifying soonest is the mail that just landed. Outbound is
  /// excluded because triage answers "does this need me?" — the LO's own sent
  /// mail never does.
  Map<String, Object?>? nextPendingTriage({
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return null;
    final result = db.select(
      'SELECT * FROM messages '
      "WHERE triage_status = 'pending' AND direction = 'inbound' "
      'AND source IN (${_placeholders(sources.length)}) '
      'ORDER BY received_at DESC LIMIT 1',
      [...sources],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// Demotes every pending inbound message except the newest [cap] to
  /// `skipped` / `backlog`.
  ///
  /// A first sync of a real mailbox lands thousands of messages at once.
  /// Triaging all of them would burn hours of model time on mail the LO
  /// stopped caring about weeks ago, so only the freshest slice stays in the
  /// queue. Nothing is deleted — a skipped message still renders, it just
  /// never reaches the model.
  void capPendingTriage(int cap, {String source = 'email'}) {
    db.execute(
      '''
UPDATE messages SET triage_status = 'skipped', gate_reason = 'backlog',
  updated_at = ?
WHERE source = ? AND triage_status = 'pending' AND direction = 'inbound'
  AND source_message_id NOT IN (
    SELECT source_message_id FROM messages
    WHERE source = ? AND triage_status = 'pending' AND direction = 'inbound'
    ORDER BY received_at DESC LIMIT ?
  )
''',
      [_nowIso(), source, source, cap],
    );
  }

  /// Records the outcome of one triage attempt. Only the fields this call
  /// actually carries are written: a status-only call (e.g. marking a message
  /// `gated`) leaves any previous result columns alone rather than nulling
  /// them.
  void writeTriage(
    String source,
    String sourceMessageId, {
    required String status,
    TriageResult? result,
    String? error,
    String? gateReason,
    int? attempts,
  }) {
    final sets = <String>['triage_status = ?', 'updated_at = ?'];
    final args = <Object?>[status, _nowIso()];

    if (result != null) {
      sets.addAll([
        'urgency = ?',
        'category = ?',
        'summary = ?',
        'needs_action = ?',
        'action_items_json = ?',
      ]);
      args.addAll([
        result.urgency,
        result.category,
        result.summary,
        // An explicit int — `needs_action` is read back as `row != 0`.
        result.needsAction ? 1 : 0,
        jsonEncode(result.actionItems),
      ]);
    }
    if (error != null) {
      sets.add('triage_error = ?');
      args.add(error);
    }
    if (gateReason != null) {
      sets.add('gate_reason = ?');
      args.add(gateReason);
    }
    if (attempts != null) {
      sets.add('triage_attempts = ?');
      args.add(attempts);
    }

    args.addAll([source, sourceMessageId]);
    db.execute(
      'UPDATE messages SET ${sets.join(', ')} '
      'WHERE source = ? AND source_message_id = ?',
      args,
    );
  }
}
