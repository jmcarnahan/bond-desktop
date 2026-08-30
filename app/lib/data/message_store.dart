import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';

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

  /// One message row as stored, or null.
  ///
  /// The triage worker re-reads through this after it fetches a message's
  /// detail: the row it was handed predates that fetch, and the body and
  /// headers it is about to gate and classify on only exist on the new one.
  Map<String, Object?>? getMessageRow(String source, String sourceMessageId) {
    final result = db.select(
      'SELECT * FROM messages WHERE source = ? AND source_message_id = ?',
      [source, sourceMessageId],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
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
      // The tie-break matters now that one thread can hold two sources: two
      // messages sharing a second must render in ONE order, not whichever the
      // query plan felt like — same rule as storylineTimeline.
      'ORDER BY received_at ASC, source_message_id ASC',
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
  ///
  /// The LEFT JOIN is what lets one read answer both "what mail is there" and
  /// "where has the app filed it": bucket and attention score live on
  /// `conversation_ai` (see [upsertConversationAi] for why they are not columns
  /// on `conversations`), and a second query per thread to fetch them would be
  /// a query per row on a list that renders thousands. LEFT, not inner — a
  /// thread the AI has never looked at still belongs in the inbox, with both
  /// columns null.
  List<Conversation> loadConversations({
    List<String> sources = const ['email'],
    ConversationState? state,
  }) {
    if (sources.isEmpty) return const [];
    final where =
        StringBuffer('c.source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...sources];
    if (state != null) {
      where.write(' AND c.state = ?');
      args.add(state.wire);
    }
    final result = db.select(
      'SELECT c.*, ai.bucket AS bucket, ai.attention_score AS attention_score '
      'FROM conversations c '
      'LEFT JOIN conversation_ai ai '
      '  ON ai.source = c.source AND ai.conversation_key = c.conversation_key '
      'WHERE $where ORDER BY c.last_message_at DESC',
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

  /// Stamps when a source last finished a sync, without touching its cursor.
  ///
  /// [setDeltaLink] also writes `synced_at`, and for the mail drains that is
  /// the right shape: the cursor and the stamp advance together. A connector
  /// with no cursor at all — Teams walks the chat list from the top every time
  /// — has nothing to hand that method but null, and passing null would erase
  /// a cursor rather than record a sync. Hence a write that says only what it
  /// means.
  ///
  /// [iso] is passed rather than taken from the clock so the caller can stamp
  /// the moment the sync actually reached, and so a test can pin it.
  void setSyncedAt(String folder, String iso, {String source = 'email'}) {
    db.execute(
      'INSERT INTO sync_state (source, folder, delta_link, synced_at) '
      'VALUES (?, ?, NULL, ?) '
      'ON CONFLICT(source, folder) DO UPDATE SET '
      'synced_at = excluded.synced_at',
      [source, folder, iso],
    );
  }

  /// When this source last finished a sync, or null when it never has.
  String? getSyncedAt(String folder, {String source = 'email'}) {
    final result = db.select(
      'SELECT synced_at FROM sync_state WHERE source = ? AND folder = ?',
      [source, folder],
    );
    if (result.isEmpty) return null;
    return result.first['synced_at'] as String?;
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

  /// Flips every message the last run left mid-flight back to `pending`.
  ///
  /// `processing` is a claim the worker takes before it calls the model and
  /// clears when it writes a result. Nothing else clears it, so a message the
  /// app was triaging when it quit would otherwise sit claimed forever —
  /// never retried, never surfaced. Called once at startup, before any worker
  /// can take a new claim.
  void resetInterruptedTriage({String source = 'email'}) {
    db.execute(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      'WHERE source = ? AND triage_status = ?',
      [_nowIso(), source, 'processing'],
    );
  }

  /// Folds one message's triage result up onto its conversation.
  ///
  /// A targeted UPDATE rather than [upsertConversation] on purpose: that
  /// statement's conflict clause overwrites participants, state and every
  /// count unconditionally, so reaching it from the triage worker would mean
  /// carrying a whole conversation row through just to write three fields —
  /// and getting one of them wrong would quietly reset a thread.
  ///
  /// `cta_text` is written unconditionally, null included: when the newest
  /// inbound message asks for nothing, the thread's ask is gone, and leaving
  /// the previous one on screen would be worse than showing none.
  void updateConversationTriage(
    String source,
    String conversationKey, {
    String? ctaText,
    required String ctaUrgency,
    String? category,
  }) {
    db.execute(
      'UPDATE conversations SET cta_text = ?, cta_urgency = ?, '
      'category = COALESCE(?, category), updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      [ctaText, ctaUrgency, category, _nowIso(), source, conversationKey],
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

  // ── work queue ───────────────────────────────────────────────────────

  /// Distinguishes "this argument was not passed" from "this argument was
  /// passed as null" on the targeted upserts below, where the two mean
  /// opposite things: leave the column alone, versus clear it.
  static const Object _unset = Object();

  /// Queues one unit of AI work. Idempotent on `(kind, source, entityId)`:
  /// re-queueing something already pending, already running, or already done
  /// changes nothing, which is what lets every caller enqueue freely rather
  /// than track what it has enqueued before.
  void enqueueWork(
    String kind,
    String source,
    String entityId, {
    String? payloadJson,
  }) {
    final now = _nowIso();
    db.execute(
      'INSERT OR IGNORE INTO work_items '
      '(task_kind, source, entity_id, status, attempts, error, payload_json, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, 'pending', 0, NULL, ?, ?, ?)",
      [kind, source, entityId, payloadJson, now, now],
    );
  }

  /// Queues extraction for the newest [cap] inbound messages received since
  /// [sinceIso], and returns how many rows that actually added.
  ///
  /// The ONLY enqueue path for extraction. It is idempotent — `OR IGNORE`
  /// against the primary key means finished work stays finished and in-flight
  /// work is not re-queued — so calling it after every sync both picks up new
  /// mail and self-heals a queue that a crash or an old build left short.
  ///
  /// Messages that triage skipped (outbound, bulk senders, backlog) are
  /// deliberately absent: extraction costs the same model time triage does,
  /// and mail not worth classifying is not worth extracting facts from.
  ///
  /// Rows queued here carry the MESSAGE's `received_at` as their
  /// `created_at`, so the worker's `created_at DESC` drain order means
  /// newest mail first — the same promise triage makes. (One-off
  /// [enqueueWork] rows stamp wall-clock time instead; for freshly synced
  /// mail the two orderings agree.)
  ///
  /// [triageStatuses] and [gateReasons] exist for the second connector, and
  /// their defaults are exactly the email behaviour described above. Teams
  /// messages never enter triage at all — they are stored `skipped` with a
  /// `teams_source` reason — so the mail filter would exclude every one of
  /// them. A caller that widens the statuses should narrow the reasons to
  /// match, or a `skipped` status would also drag in the bulk senders and
  /// backlog the mail path deliberately leaves out.
  int enqueueExtractBacklog({
    int cap = 150,
    required String sinceIso,
    String source = 'email',
    List<String> triageStatuses = const ['pending', 'processing', 'triaged'],
    List<String>? gateReasons,
  }) {
    // An empty list would render as `IN ()`, which sqlite rejects. Nothing is
    // queued because nothing was asked for.
    if (triageStatuses.isEmpty) return 0;
    if (gateReasons != null && gateReasons.isEmpty) return 0;

    final now = _nowIso();
    db.execute(
      '''
INSERT OR IGNORE INTO work_items (
  task_kind, source, entity_id, status, attempts, error, payload_json,
  created_at, updated_at
)
SELECT 'extract', source, source_message_id, 'pending', 0, NULL, NULL,
  COALESCE(received_at, ?), ?
FROM messages
WHERE source = ? AND direction = 'inbound'
  AND triage_status IN (${_placeholders(triageStatuses.length)})
  ${gateReasons == null ? '' : 'AND gate_reason IN (${_placeholders(gateReasons.length)})'}
  AND received_at >= ?
ORDER BY received_at DESC
LIMIT ?
''',
      [
        now,
        now,
        source,
        ...triageStatuses,
        ...?gateReasons,
        sinceIso,
        cap,
      ],
    );
    return db.updatedRows;
  }

  /// The next item of one [kind] for the worker.
  ///
  /// Newest first, like triage — and with `entity_id` behind it purely as a
  /// tie-break, since a batch enqueue stamps every row it inserts with the
  /// same `created_at` and an unordered LIMIT 1 would be free to hand the same
  /// drain a different row on every call.
  Map<String, Object?>? nextPendingWork(
    String kind, {
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return null;
    final result = db.select(
      'SELECT * FROM work_items '
      "WHERE task_kind = ? AND status = 'pending' "
      'AND source IN (${_placeholders(sources.length)}) '
      'ORDER BY created_at DESC, entity_id DESC LIMIT 1',
      [kind, ...sources],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// Records the outcome of one work item. Like [writeTriage], only the
  /// fields this call carries are written, so claiming an item does not blank
  /// the error a previous attempt left behind.
  void writeWork(
    String kind,
    String source,
    String entityId, {
    required String status,
    String? error,
    int? attempts,
  }) {
    final sets = <String>['status = ?', 'updated_at = ?'];
    final args = <Object?>[status, _nowIso()];

    if (error != null) {
      sets.add('error = ?');
      args.add(error);
    }
    if (attempts != null) {
      sets.add('attempts = ?');
      args.add(attempts);
    }

    args.addAll([kind, source, entityId]);
    db.execute(
      'UPDATE work_items SET ${sets.join(', ')} '
      'WHERE task_kind = ? AND source = ? AND entity_id = ?',
      args,
    );
  }

  /// `status` → count for one kind. Statuses with no rows are simply absent.
  Map<String, int> workCounts(
    String kind, {
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const {};
    final result = db.select(
      'SELECT status, COUNT(*) AS n FROM work_items '
      'WHERE task_kind = ? AND source IN (${_placeholders(sources.length)}) '
      'GROUP BY status',
      [kind, ...sources],
    );
    return {
      for (final row in result)
        (row['status'] as String? ?? 'pending'): (row['n'] as num?)?.toInt() ?? 0,
    };
  }

  /// Frees every claim a previous run left behind, across every kind.
  ///
  /// `processing` is taken before the worker's first await and cleared when it
  /// writes a result; nothing else clears it, so an item the app was working
  /// on when it quit would sit claimed forever. Startup only — running this
  /// while a worker holds a claim would hand its item to a second drain.
  void resetInterruptedWork() {
    db.execute(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'processing'",
      [_nowIso()],
    );
  }

  /// Flips errored work rows back to `pending` so a transient failure heals
  /// on a later sync instead of removing the item from the pipeline forever.
  ///
  /// Attempts are deliberately NOT reset: the drain errors a row again at its
  /// next failed attempt, so each revival buys exactly one more try, and the
  /// [maxAttempts] ceiling is where a genuinely bad item stays down for good.
  int reviveErroredWork({int maxAttempts = 6}) {
    db.execute(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'error' AND attempts < ?",
      [_nowIso(), maxAttempts],
    );
    return db.updatedRows;
  }

  /// The triage half of [reviveErroredWork], with the same one-more-try
  /// semantics per revival and the same permanent ceiling.
  int reviveErroredTriage({String source = 'email', int maxAttempts = 6}) {
    db.execute(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND triage_status = 'error' AND triage_attempts < ?",
      [_nowIso(), source, maxAttempts],
    );
    return db.updatedRows;
  }

  /// Empties every table, in one transaction. Sign-out calls this: the rows
  /// are one account's mailbox, and a different account signing in must not
  /// find them — mail, AI output, drafts, feedback, sender rules, and the
  /// delta cursors that would otherwise resume the OLD account's sync
  /// position against the new account's mailbox.
  ///
  /// `app_prefs` goes too. Its rows (attention threshold, volume slider) are
  /// the previous user's calibration, and stale cursors hiding in a kept
  /// table is exactly the class of bug this method exists to rule out —
  /// everything or nothing is the only policy that stays correct as tables
  /// are added.
  void wipeAll() {
    const tables = [
      'messages',
      'conversations',
      'sync_state',
      'work_items',
      'message_ai',
      'conversation_ai',
      'storylines',
      'storyline_members',
      'storyline_member_blocks',
      'feedback_events',
      'sender_prefs',
      'app_prefs',
      'drafts',
    ];
    db.execute('BEGIN');
    try {
      for (final table in tables) {
        db.execute('DELETE FROM $table');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── per-message AI output ────────────────────────────────────────────

  /// Stores one message's extraction as JSON.
  ///
  /// A separate table rather than columns on `messages`: the shape of what the
  /// model extracts is still moving, and a JSON blob absorbs a new field
  /// without a migration. Nothing queries inside it.
  void writeExtraction(
    String source,
    String sourceMessageId,
    String extractionJson,
  ) {
    db.execute(
      'INSERT INTO message_ai '
      '(source, source_message_id, extraction_json, extracted_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(source, source_message_id) DO UPDATE SET '
      'extraction_json = excluded.extraction_json, '
      'extracted_at = excluded.extracted_at',
      [source, sourceMessageId, extractionJson, _nowIso()],
    );
  }

  String? getExtraction(String source, String sourceMessageId) {
    final result = db.select(
      'SELECT extraction_json FROM message_ai '
      'WHERE source = ? AND source_message_id = ?',
      [source, sourceMessageId],
    );
    if (result.isEmpty) return null;
    return result.first['extraction_json'] as String?;
  }

  // ── per-conversation AI state ────────────────────────────────────────

  /// Writes only the AI columns this call actually names, inserting the row
  /// first when the thread has none yet.
  ///
  /// Targeted for the same reason [updateConversationTriage] is: this table
  /// will hold a bucket, a reason and an attention score written by a
  /// different task on a different schedule, and an embedding write that
  /// carried a whole row through would quietly reset all three.
  ///
  /// [embedding] takes a [Uint8List] to store, null to clear, and is left
  /// alone when omitted. [embeddedHash] and [embedModel] are left alone when
  /// null — there is no "clear the hash" case, since a row with an embedding
  /// and no hash would re-embed on every pass.
  void upsertConversationAi(
    String source,
    String conversationKey, {
    Object? embedding = _unset,
    String? embeddedHash,
    String? embedModel,
  }) {
    final now = _nowIso();
    db.execute(
      'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(source, conversation_key) DO NOTHING',
      [source, conversationKey, now],
    );

    final sets = <String>['updated_at = ?'];
    final args = <Object?>[now];
    if (!identical(embedding, _unset)) {
      sets.add('embedding = ?');
      args.add(embedding as Uint8List?);
    }
    if (embeddedHash != null) {
      sets.add('embedded_hash = ?');
      args.add(embeddedHash);
    }
    if (embedModel != null) {
      sets.add('embed_model = ?');
      args.add(embedModel);
    }

    args.addAll([source, conversationKey]);
    db.execute(
      'UPDATE conversation_ai SET ${sets.join(', ')} '
      'WHERE source = ? AND conversation_key = ?',
      args,
    );
  }

  Map<String, Object?>? getConversationAi(String source, String conversationKey) {
    final result = db.select(
      'SELECT * FROM conversation_ai WHERE source = ? AND conversation_key = ?',
      [source, conversationKey],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// Files one thread into a bucket, or takes it out of every bucket.
  ///
  /// Targeted like [upsertConversationAi], and inserting the row first for the
  /// same reason: a thread the embedder has never reached has no
  /// `conversation_ai` row, and a bucket decision must not depend on whether
  /// some other task got there first.
  ///
  /// The two columns move together, always, and either may be null.
  ///
  /// `bucket` is WHERE the thread went; `bucket_reason` is WHO decided. They
  /// are independent because "a person decided this thread belongs in the
  /// inbox" is a real decision that has to survive the next sweep, and it has
  /// no bucket to hang off. `(null, 'user')` is exactly that state — see
  /// `AttentionService`, which skips any thread carrying a `user` reason in
  /// both directions.
  ///
  /// Passing neither returns the thread to "nobody has ever ruled on this",
  /// which is what the sweep writes when it withdraws its own guess.
  void setConversationBucket(
    String source,
    String conversationKey, {
    required String? bucket,
    String? reason,
  }) {
    final now = _nowIso();
    db.execute(
      'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(source, conversation_key) DO NOTHING',
      [source, conversationKey, now],
    );
    db.execute(
      'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      [bucket, reason, now, source, conversationKey],
    );
  }

  /// Stores one thread's ranking score. Same targeted insert-then-update as
  /// [setConversationBucket]: the score is recomputed on every list load and
  /// must never disturb an embedding or a bucket sitting on the same row.
  void writeAttentionScore(
    String source,
    String conversationKey,
    double score,
  ) {
    final now = _nowIso();
    db.execute(
      'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(source, conversation_key) DO NOTHING',
      [source, conversationKey, now],
    );
    db.execute(
      'UPDATE conversation_ai SET attention_score = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      [score, now, source, conversationKey],
    );
  }

  /// `conversation_key` → who last decided where it goes, for every thread
  /// anyone has decided about.
  ///
  /// Threads nobody has ruled on are absent. Note that a thread can be here
  /// with no bucket: `(null, 'user')` means someone deliberately put it back in
  /// the inbox, which the sweep must respect exactly as much as a deliberate
  /// deferral — see [setConversationBucket].
  Map<String, String?> bucketReasons({
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const {};
    final result = db.select(
      'SELECT conversation_key, bucket_reason FROM conversation_ai '
      'WHERE bucket_reason IS NOT NULL '
      'AND source IN (${_placeholders(sources.length)})',
      [...sources],
    );
    return {
      for (final row in result)
        (row['conversation_key'] as String? ?? ''):
            row['bucket_reason'] as String?,
    };
  }

  /// One row per conversation for its NEWEST INBOUND message, with that
  /// message's extraction alongside it.
  ///
  /// "Newest" is `received_at DESC` with `source_message_id DESC` behind it as
  /// a tie-break. Two messages stamped the same second are common in a mailbox,
  /// and without the tie-break sqlite would be free to pick a different one on
  /// every read — which would show up as a sender rule applying to a thread on
  /// one pass and not the next.
  ///
  /// Keyed by `conversation_key` alone. Conversation keys are handed out by the
  /// connector and are unique within a source; with two sources in play a key
  /// that collided across them would keep only the row read last.
  ///
  /// The LEFT JOIN onto `message_ai` is what makes this one query rather than
  /// two: the scorer needs the intent the extraction found, and a per-thread
  /// lookup would be a query per row.
  Map<String, Map<String, Object?>> latestInboundMeta({
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const {};
    final result = db.select(
      'SELECT conversation_key, source, source_message_id, from_address, '
      '  received_at, extraction_json FROM ('
      '  SELECT m.conversation_key AS conversation_key, m.source AS source, '
      '    m.source_message_id AS source_message_id, '
      '    m.from_address AS from_address, m.received_at AS received_at, '
      '    a.extraction_json AS extraction_json, '
      '    ROW_NUMBER() OVER ('
      '      PARTITION BY m.source, m.conversation_key '
      '      ORDER BY m.received_at DESC, m.source_message_id DESC'
      '    ) AS rn '
      '  FROM messages m '
      '  LEFT JOIN message_ai a '
      '    ON a.source = m.source AND a.source_message_id = m.source_message_id '
      "  WHERE m.direction = 'inbound' "
      '    AND m.source IN (${_placeholders(sources.length)})'
      ') WHERE rn = 1',
      [...sources],
    );
    return {
      for (final row in result)
        (row['conversation_key'] as String? ?? ''):
            Map<String, Object?>.from(row),
    };
  }

  /// How often each sender gets answered, as a 0..1 fraction.
  ///
  /// A cheap approximation, and deliberately so: "replied" means the thread
  /// contains at least one outbound message, not that the LO replied to THIS
  /// message. A thread the LO started and a thread they answered look the same
  /// here. The scorer uses it as a small nudge (see
  /// `AttentionTuning.replyRateMax`), never as a decision, so the approximation
  /// costs a fraction of a point on a thread rather than a wrong bucket.
  ///
  /// Computed in SQL rather than by loading messages: on a real mailbox this is
  /// hundreds of thousands of rows, and it runs on every list load.
  Map<String, double> senderReplyRates({String source = 'email'}) {
    final result = db.select(
      'SELECT LOWER(m.from_address) AS addr, '
      '  COUNT(DISTINCT m.conversation_key) AS threads, '
      '  COUNT(DISTINCT CASE WHEN EXISTS ('
      '    SELECT 1 FROM messages o WHERE o.source = m.source '
      '      AND o.conversation_key = m.conversation_key '
      "      AND o.direction = 'outbound'"
      '  ) THEN m.conversation_key END) AS replied '
      'FROM messages m '
      "WHERE m.source = ? AND m.direction = 'inbound' "
      "  AND m.from_address IS NOT NULL AND m.from_address <> '' "
      'GROUP BY LOWER(m.from_address)',
      [source],
    );
    final rates = <String, double>{};
    for (final row in result) {
      final address = row['addr'] as String? ?? '';
      if (address.isEmpty) continue;
      final threads = (row['threads'] as num?)?.toInt() ?? 0;
      if (threads == 0) continue;
      final replied = (row['replied'] as num?)?.toInt() ?? 0;
      rates[address] = replied / threads;
    }
    return rates;
  }

  /// Applies one sender-scoped decision to every thread that sender owns.
  ///
  /// **The latest inbound sender owns the thread.** A thread's sender is
  /// whoever wrote its newest inbound message, not whoever started it: a
  /// newsletter the LO forwarded to a colleague who replied is that colleague's
  /// thread now, and "never show me mail from this newsletter again" must not
  /// bury the colleague's answer. Ties break the same way [latestInboundMeta]
  /// breaks them, so the two always agree on who that is.
  ///
  /// [bucket] null clears the bucket and its reason; a non-null bucket is
  /// always written with reason `sender_pref`, which is what marks it as a
  /// human's decision the automatic sweep may not undo.
  ///
  /// Returns how many conversation rows the rule touched — every thread that
  /// sender owns, whether or not the write actually changed the value. It is
  /// the number the UI reports back ("moved 12 threads"), and a user who does
  /// this twice should see the same count both times.
  int rebucketSender(
    String address, {
    required String? bucket,
    String source = 'email',
  }) {
    final lowered = address.toLowerCase();
    final now = _nowIso();

    // The threads themselves. Repeated rather than factored into a CTE because
    // the INSERT and the UPDATE need it in different positions, and a bucket
    // has nowhere to live until the row exists.
    const String owned = '''
SELECT conversation_key FROM (
  SELECT conversation_key, from_address,
    ROW_NUMBER() OVER (
      PARTITION BY source, conversation_key
      ORDER BY received_at DESC, source_message_id DESC
    ) AS rn
  FROM messages WHERE source = ? AND direction = 'inbound'
) WHERE rn = 1 AND LOWER(from_address) = ?''';

    db.execute(
      'INSERT OR IGNORE INTO conversation_ai '
      '(source, conversation_key, updated_at) '
      'SELECT ?, conversation_key, ? FROM ($owned)',
      [source, now, source, lowered],
    );
    db.execute(
      'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key IN ($owned)',
      [
        bucket,
        bucket == null ? null : 'sender_pref',
        now,
        source,
        source,
        lowered,
      ],
    );
    return db.updatedRows;
  }

  // ── feedback, sender rules, app preferences ──────────────────────────

  /// Appends one correction to the permanent record. INSERT only — there is no
  /// update and no delete anywhere in this class.
  ///
  /// The events are the history and [sender_prefs] is the current answer
  /// materialized from it. Keeping both means a rule can be re-derived, and a
  /// later phase can weigh "corrected this sender down four times this month"
  /// differently from "corrected once, a year ago" — neither of which survives
  /// in a table that only remembers the latest value.
  ///
  /// [origin] separates `explicit` (a button the LO pressed) from `implicit`
  /// (opening a thread, marking one done). Implicit signals are far noisier and
  /// far more numerous, and anything that learns from these has to be able to
  /// tell them apart.
  void recordFeedback({
    required String scope,
    required String scopeKey,
    required String direction,
    required String origin,
  }) {
    db.execute(
      'INSERT INTO feedback_events '
      '(scope, scope_key, direction, origin, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [scope, scopeKey, direction, origin, _nowIso()],
    );
  }

  /// Sets, or with a null [disposition] removes, one sender's standing rule.
  ///
  /// Deleting rather than storing a third "no opinion" value: absent is
  /// already the natural state of a sender nobody has ruled on, and two ways to
  /// spell it would mean every reader has to handle both.
  ///
  /// Addresses are stored lowercased. Mail systems vary on whether they
  /// preserve the case a sender typed, so the same person can arrive as
  /// `Eric@x.com` and `eric@x.com`, and a rule that applied to only one of
  /// those would look like it silently stopped working.
  void setSenderPref(String address, String? disposition) {
    final lowered = address.toLowerCase();
    if (disposition == null) {
      db.execute('DELETE FROM sender_prefs WHERE address = ?', [lowered]);
      return;
    }
    db.execute(
      'INSERT INTO sender_prefs (address, disposition, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(address) DO UPDATE SET '
      'disposition = excluded.disposition, updated_at = excluded.updated_at',
      [lowered, disposition, _nowIso()],
    );
  }

  /// One sender's rule, or null when there is none. Lowercases first, so a
  /// caller may pass whatever casing the message carried.
  String? getSenderPref(String address) {
    final result = db.select(
      'SELECT disposition FROM sender_prefs WHERE address = ?',
      [address.toLowerCase()],
    );
    if (result.isEmpty) return null;
    return result.first['disposition'] as String?;
  }

  /// Every sender rule at once — what the scoring pass wants, since it asks
  /// about a rule for every thread in the inbox.
  Map<String, String> allSenderPrefs() {
    final result = db.select('SELECT address, disposition FROM sender_prefs');
    return {
      for (final row in result)
        (row['address'] as String? ?? ''): (row['disposition'] as String? ?? ''),
    };
  }

  /// One app-level setting, or null when it has never been set. Values are TEXT
  /// whatever they mean — a threshold is stored as its `toString()` and parsed
  /// back by the one reader that knows what it is.
  String? getPref(String key) {
    final result = db.select('SELECT value FROM app_prefs WHERE key = ?', [key]);
    if (result.isEmpty) return null;
    return result.first['value'] as String?;
  }

  void setPref(String key, String value) {
    db.execute(
      'INSERT INTO app_prefs (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  // ── storylines ───────────────────────────────────────────────────────

  /// The storyline row plus its two derived counts.
  ///
  /// Correlated subqueries rather than two GROUP BY joins: `open_count` counts
  /// a strict subset of what `member_count` counts, and expressing that as one
  /// join would need a conditional aggregate over an outer join whose empty
  /// case reads as one member rather than none.
  static const String _storylineSelect = '''
SELECT s.*,
  (SELECT COUNT(*) FROM storyline_members m WHERE m.storyline_id = s.id)
    AS member_count,
  (SELECT COUNT(*) FROM storyline_members m
     JOIN conversations c
       ON c.source = m.source AND c.conversation_key = m.conversation_key
     WHERE m.storyline_id = s.id AND c.state = 'needs_reply')
    AS open_count
FROM storylines s''';

  void insertStoryline({
    required String id,
    required String title,
    String? summary,
    required String status,
    required String createdBy,
    String? memberHash,
  }) {
    final now = _nowIso();
    db.execute(
      'INSERT INTO storylines '
      '(id, title, summary, status, created_by, title_locked, pinned, '
      'member_hash, last_activity_at, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, 0, 0, ?, NULL, ?, ?)',
      [id, title, summary, status, createdBy, memberHash, now, now],
    );
  }

  /// Writes only the fields this call actually names.
  ///
  /// Targeted for the reason [upsertConversationAi] is: the columns here are
  /// written by four different callers — the sweep names it, the user renames
  /// it, the keep/dismiss buttons move its status, an assignment touches its
  /// activity — and a whole-row write from any one of them would quietly
  /// reset the other three.
  ///
  /// [summary] uses the [_unset] sentinel because null means something: a
  /// storyline whose summary should be cleared is a different write from one
  /// whose summary is simply not this call's business.
  void updateStoryline(
    String id, {
    String? title,
    Object? summary = _unset,
    String? status,
    bool? titleLocked,
    bool? pinned,
    String? lastActivityAt,
    String? memberHash,
  }) {
    final sets = <String>['updated_at = ?'];
    final args = <Object?>[_nowIso()];

    if (title != null) {
      sets.add('title = ?');
      args.add(title);
    }
    if (!identical(summary, _unset)) {
      sets.add('summary = ?');
      args.add(summary as String?);
    }
    if (status != null) {
      sets.add('status = ?');
      args.add(status);
    }
    if (titleLocked != null) {
      sets.add('title_locked = ?');
      args.add(titleLocked ? 1 : 0);
    }
    if (pinned != null) {
      sets.add('pinned = ?');
      args.add(pinned ? 1 : 0);
    }
    if (lastActivityAt != null) {
      sets.add('last_activity_at = ?');
      args.add(lastActivityAt);
    }
    if (memberHash != null) {
      sets.add('member_hash = ?');
      args.add(memberHash);
    }

    args.add(id);
    db.execute('UPDATE storylines SET ${sets.join(', ')} WHERE id = ?', args);
  }

  /// The rail's list: suggestions first, newest proposal at the top, then
  /// everything live by how recently it moved.
  ///
  /// Suggestions lead because they are the only rows that ask the user for
  /// something. `rowid DESC` is the final tie-break — two storylines written in
  /// the same microsecond would otherwise be free to swap places between
  /// reads, which reads on screen as the list shuffling itself.
  List<Storyline> loadStorylines({
    List<String> statuses = const ['suggested', 'active'],
  }) {
    if (statuses.isEmpty) return const [];
    final result = db.select(
      '$_storylineSelect '
      'WHERE s.status IN (${_placeholders(statuses.length)}) '
      "ORDER BY (CASE WHEN s.status = 'suggested' THEN 0 ELSE 1 END), "
      "CASE WHEN s.status = 'suggested' THEN s.created_at END DESC, "
      "CASE WHEN s.status = 'suggested' THEN NULL ELSE s.last_activity_at END DESC, "
      's.rowid DESC',
      [...statuses],
    );
    return [for (final row in result) Storyline.fromRow(row)];
  }

  Storyline? getStoryline(String id) {
    final result = db.select('$_storylineSelect WHERE s.id = ?', [id]);
    if (result.isEmpty) return null;
    return Storyline.fromRow(result.first);
  }

  /// Adds a thread to a storyline, and un-blocks it.
  ///
  /// The un-block is the point: a block is a record of "the user took this out
  /// of here", and putting it back explicitly is the user changing their mind.
  /// Leaving the block behind would let the assignment pass silently refuse a
  /// membership a person just asked for.
  void addStorylineMember(
    String storylineId,
    String source,
    String conversationKey, {
    required String addedBy,
    String? evidence,
  }) {
    db.execute(
      'INSERT OR IGNORE INTO storyline_members '
      '(storyline_id, source, conversation_key, added_by, evidence, added_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [storylineId, source, conversationKey, addedBy, evidence, _nowIso()],
    );
    db.execute(
      'DELETE FROM storyline_member_blocks '
      'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
      [storylineId, source, conversationKey],
    );
  }

  /// Takes a thread out of a storyline. [block] records that the user meant
  /// it, so the next clustering pass cannot put it straight back — the model
  /// is not allowed to overrule a person by being confident twice.
  void removeStorylineMember(
    String storylineId,
    String source,
    String conversationKey, {
    required bool block,
  }) {
    db.execute(
      'DELETE FROM storyline_members '
      'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
      [storylineId, source, conversationKey],
    );
    if (!block) return;
    db.execute(
      'INSERT OR IGNORE INTO storyline_member_blocks '
      '(storyline_id, source, conversation_key, blocked_at) '
      'VALUES (?, ?, ?, ?)',
      [storylineId, source, conversationKey, _nowIso()],
    );
  }

  bool isMemberBlocked(
    String storylineId,
    String source,
    String conversationKey,
  ) {
    final result = db.select(
      'SELECT 1 FROM storyline_member_blocks '
      'WHERE storyline_id = ? AND source = ? AND conversation_key = ? LIMIT 1',
      [storylineId, source, conversationKey],
    );
    return result.isNotEmpty;
  }

  List<StorylineMember> membersOf(String storylineId) {
    final result = db.select(
      'SELECT * FROM storyline_members WHERE storyline_id = ? '
      'ORDER BY added_at ASC, conversation_key ASC',
      [storylineId],
    );
    return [for (final row in result) StorylineMember.fromRow(row)];
  }

  /// Which live storylines one thread belongs to. Dismissed and archived ones
  /// are excluded: their member rows survive only as the record behind
  /// [dismissedMemberHashExists], and a thread is not "in" a suggestion the
  /// user threw away.
  List<String> storylineIdsFor(String source, String conversationKey) {
    final result = db.select(
      'SELECT m.storyline_id FROM storyline_members m '
      'JOIN storylines s ON s.id = m.storyline_id '
      'WHERE m.source = ? AND m.conversation_key = ? '
      "AND s.status IN ('suggested', 'active') "
      'ORDER BY m.added_at ASC',
      [source, conversationKey],
    );
    return [
      for (final row in result) row['storyline_id'] as String? ?? '',
    ];
  }

  /// Every conversation with a comparable vector.
  ///
  /// [embedModel] is required rather than defaulted: two vectors are only
  /// comparable when they came from the same model under the same task prefix,
  /// and a query that quietly mixed generations would return cosines that mean
  /// nothing. The caller passes `EmbeddingsClient.modelTag`.
  List<Map<String, Object?>> conversationsWithEmbeddings({
    required String embedModel,
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const [];
    final result = db.select(
      'SELECT a.source AS source, a.conversation_key AS conversation_key, '
      'a.embedding AS embedding, c.subject AS subject, '
      'c.participants_json AS participants_json, c.state AS state, '
      'c.last_message_at AS last_message_at '
      'FROM conversation_ai a '
      'JOIN conversations c '
      '  ON c.source = a.source AND c.conversation_key = a.conversation_key '
      'WHERE a.embedding IS NOT NULL AND a.embed_model = ? '
      'AND a.source IN (${_placeholders(sources.length)}) '
      'ORDER BY c.last_message_at DESC, a.conversation_key ASC',
      [embedModel, ...sources],
    );
    return [for (final row in result) Map<String, Object?>.from(row)];
  }

  /// Every thread the sweep must leave alone: already in a live storyline, or
  /// explicitly kept out of one. Blocks count because a thread the user pulled
  /// out of a group is not a thread to propose a new group around.
  Set<String> assignedOrBlockedKeys(String source) {
    final result = db.select(
      'SELECT m.conversation_key AS conversation_key FROM storyline_members m '
      'JOIN storylines s ON s.id = m.storyline_id '
      "WHERE m.source = ? AND s.status IN ('suggested', 'active') "
      'UNION '
      'SELECT b.conversation_key AS conversation_key '
      'FROM storyline_member_blocks b '
      'JOIN storylines s ON s.id = b.storyline_id '
      "WHERE b.source = ? AND s.status IN ('suggested', 'active')",
      [source, source],
    );
    return {
      for (final row in result) row['conversation_key'] as String? ?? '',
    };
  }

  /// Whether this exact set of threads has already been proposed and thrown
  /// away. The sweep is deterministic, so without this a dismissed suggestion
  /// would be re-proposed identically on the very next sync.
  bool dismissedMemberHashExists(String memberHash) {
    final result = db.select(
      "SELECT 1 FROM storylines WHERE status = 'dismissed' "
      'AND member_hash = ? LIMIT 1',
      [memberHash],
    );
    return result.isNotEmpty;
  }

  /// Moves a storyline's activity stamp forward, never back. Threads are
  /// assigned in whatever order the queue drains them, so an older thread
  /// joining must not make a live storyline look stale.
  void touchStorylineActivity(String id, String lastMessageAt) {
    db.execute(
      'UPDATE storylines SET last_activity_at = ?, updated_at = ? '
      'WHERE id = ? AND (last_activity_at IS NULL OR last_activity_at < ?)',
      [lastMessageAt, _nowIso(), id, lastMessageAt],
    );
  }

  /// Queues work, and revives it when it has already run.
  ///
  /// The difference from [enqueueWork] is the whole reason this exists:
  /// storyline assignment must run AGAIN every time a thread's embedding
  /// changes, and `INSERT OR IGNORE` against a row already marked `done` would
  /// mean a thread is only ever considered once, on the first message that
  /// ever reached it.
  ///
  /// The `WHERE` clause is what keeps that safe. Only `done` and `error` rows
  /// are revived: resetting a `pending` row would lose its place in the drain
  /// order, and resetting a `processing` one would hand an item a worker is
  /// holding to a second drain.
  void requeueWork(String kind, String source, String entityId) {
    final now = _nowIso();
    db.execute(
      'INSERT INTO work_items '
      '(task_kind, source, entity_id, status, attempts, error, payload_json, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, 'pending', 0, NULL, NULL, ?, ?) "
      'ON CONFLICT(task_kind, source, entity_id) DO UPDATE SET '
      "status = 'pending', updated_at = excluded.updated_at "
      "WHERE work_items.status IN ('done', 'error')",
      [kind, source, entityId, now, now],
    );
  }

  // ── drafts ───────────────────────────────────────────────────────────

  /// Writes the one draft a conversation is allowed, replacing whatever was
  /// there.
  ///
  /// A full replace rather than a merge because that is what regenerating
  /// means: the new draft answers a possibly different message, and keeping
  /// the old `graph_draft_id` would leave the Send button pointing at an
  /// Outlook draft holding text nobody can see any more. `created_at` survives
  /// — it says when this conversation first got a suggestion, which is the one
  /// fact a regenerate does not change.
  void upsertDraft({
    required String source,
    required String conversationKey,
    required String replyToMessageId,
    required String body,
    String? evidence,
    String status = 'suggested',
  }) {
    final now = _nowIso();
    db.execute(
      '''
INSERT INTO drafts (
  source, conversation_key, reply_to_message_id, body, evidence, status,
  graph_draft_id, web_link, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
ON CONFLICT(source, conversation_key) DO UPDATE SET
  reply_to_message_id = excluded.reply_to_message_id,
  body = excluded.body,
  evidence = excluded.evidence,
  status = excluded.status,
  graph_draft_id = NULL,
  web_link = NULL,
  updated_at = excluded.updated_at
''',
      [
        source,
        conversationKey,
        replyToMessageId,
        body,
        evidence,
        status,
        now,
        now,
      ],
    );
  }

  Map<String, Object?>? getDraft(String source, String conversationKey) {
    final result = db.select(
      'SELECT * FROM drafts WHERE source = ? AND conversation_key = ?',
      [source, conversationKey],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// Moves a draft along its lifecycle — `suggested` → `edited` → `sent`, or
  /// `dismissed` — writing only the fields this call carries.
  ///
  /// Targeted like [writeTriage]: the edit that marks a draft touched must not
  /// blank the Outlook ids a save-to-drafts wrote, and a send must not rewrite
  /// the body the user is looking at.
  void updateDraftStatus(
    String source,
    String conversationKey, {
    required String status,
    String? body,
    String? graphDraftId,
    String? webLink,
  }) {
    final sets = <String>['status = ?', 'updated_at = ?'];
    final args = <Object?>[status, _nowIso()];

    if (body != null) {
      sets.add('body = ?');
      args.add(body);
    }
    if (graphDraftId != null) {
      sets.add('graph_draft_id = ?');
      args.add(graphDraftId);
    }
    if (webLink != null) {
      sets.add('web_link = ?');
      args.add(webLink);
    }

    args.addAll([source, conversationKey]);
    db.execute(
      'UPDATE drafts SET ${sets.join(', ')} '
      'WHERE source = ? AND conversation_key = ?',
      args,
    );
  }

  void deleteDraft(String source, String conversationKey) {
    db.execute(
      'DELETE FROM drafts WHERE source = ? AND conversation_key = ?',
      [source, conversationKey],
    );
  }

  /// The message a reply would answer: the thread's newest inbound one.
  ///
  /// Ties break on `source_message_id DESC`, the same way [latestInboundMeta]
  /// breaks them, so the draft is written against the message the rest of the
  /// app agrees is the latest.
  Map<String, Object?>? newestInboundMessage(
    String source,
    String conversationKey,
  ) {
    final result = db.select(
      'SELECT * FROM messages '
      "WHERE source = ? AND conversation_key = ? AND direction = 'inbound' "
      'ORDER BY received_at DESC, source_message_id DESC LIMIT 1',
      [source, conversationKey],
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  /// The LO's own recent replies to one address, newest first — the tone the
  /// draft model is asked to match.
  ///
  /// `to_json LIKE '%address%'` is an APPROXIMATION and knowingly so. The
  /// recipients are a JSON array in a TEXT column, so this can match an address
  /// that merely contains the one asked for (`eric@x.com` inside
  /// `noteric@x.com`) and it matches a message the address was CC'd on as
  /// readily as one addressed to them. Both are fine for what this feeds: a
  /// handful of the LO's own sentences shown to the model as a writing sample.
  /// A wrong sample costs a slightly-off tone, never a wrong recipient — the
  /// address a reply actually goes to comes from Graph's own `createReply`.
  List<Map<String, Object?>> recentOutboundToSender(
    String source,
    String senderAddress, {
    int limit = 2,
  }) {
    if (senderAddress.isEmpty) return const [];
    final result = db.select(
      'SELECT * FROM messages '
      "WHERE source = ? AND direction = 'outbound' AND to_json LIKE ? "
      'ORDER BY received_at DESC, source_message_id DESC LIMIT ?',
      [source, '%${senderAddress.toLowerCase()}%', limit],
    );
    return [for (final row in result) Map<String, Object?>.from(row)];
  }

  /// The threads worth spending a model call drafting a reply for.
  ///
  /// Four filters, and each one is there to stop a specific waste: the thread
  /// must actually be waiting on the LO, it must not be filed away in Later, it
  /// must have scored high enough to be worth answering, and it must not have a
  /// draft already. That last one is what makes this safe to call on every list
  /// load — a thread drops out of the list the moment it has a suggestion, so
  /// the queue fills once rather than on every pass.
  ///
  /// A thread with no attention score at all is excluded: `NULL >= ?` is NULL,
  /// which is not true. That is the wanted behaviour — a thread the scorer has
  /// never reached has not earned a model call yet.
  List<String> needsDraftKeys({
    required double threshold,
    int limit = 7,
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const [];
    final result = db.select(
      'SELECT c.conversation_key AS conversation_key FROM conversations c '
      'LEFT JOIN conversation_ai ai '
      '  ON ai.source = c.source AND ai.conversation_key = c.conversation_key '
      'LEFT JOIN drafts d '
      '  ON d.source = c.source AND d.conversation_key = c.conversation_key '
      "WHERE c.state = 'needs_reply' "
      'AND c.source IN (${_placeholders(sources.length)}) '
      // `IS NOT`, not `<>`: a thread with no bucket at all belongs here, and
      // `NULL <> 'later'` would drop every one of them.
      "AND ai.bucket IS NOT 'later' "
      'AND ai.attention_score >= ? '
      'AND d.conversation_key IS NULL '
      'ORDER BY ai.attention_score DESC, c.conversation_key ASC LIMIT ?',
      [...sources, threshold, limit],
    );
    return [
      for (final row in result) row['conversation_key'] as String? ?? '',
    ];
  }

  /// Every message of every member thread, merged into one chronology.
  ///
  /// Rows come back as raw `messages` rows — `conversation_key` and `subject`
  /// included — because the timeline needs both: the key to know when the
  /// transcript crosses from one thread into another, and the subject to name
  /// the thread it crossed into.
  List<Map<String, Object?>> storylineTimeline(
    String storylineId, {
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return const [];
    final result = db.select(
      'SELECT m.* FROM messages m '
      'JOIN storyline_members sm '
      '  ON sm.source = m.source AND sm.conversation_key = m.conversation_key '
      'WHERE sm.storyline_id = ? '
      'AND m.source IN (${_placeholders(sources.length)}) '
      'ORDER BY m.received_at ASC, m.source_message_id ASC',
      [storylineId, ...sources],
    );
    return [for (final row in result) Map<String, Object?>.from(row)];
  }
}
