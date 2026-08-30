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
  int enqueueExtractBacklog({
    int cap = 150,
    required String sinceIso,
    String source = 'email',
  }) {
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
  AND triage_status IN ('pending', 'processing', 'triaged')
  AND received_at >= ?
ORDER BY received_at DESC
LIMIT ?
''',
      [now, now, source, sinceIso, cap],
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
