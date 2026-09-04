import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../models/home_models.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import 'database.dart' show BondDatabase;
import 'progress_sql.dart';
import 'vec_index.dart';

/// Which Microsoft identity the mail rows in this database belong to, stored in
/// `app_prefs` alongside the settings but emphatically not one of them: it is
/// ownership metadata, written by `IdentityGuard` and cleared by [wipeAll],
/// never something a user sets. Declared here because [wipeAll] is what has to
/// clear it, and this layer imports nothing above itself.
const String dbOwnerKey = 'db_owner';

/// The user's own words about who they are, fed to the AI on their behalf.
/// A user setting like any other — except it is one PERSON'S text, not the
/// machine's configuration, so [wipeAll] clears it along with their mail.
/// Declared here beside [dbOwnerKey] for the same reason: the wipe is what
/// has to name it, and this layer imports nothing above itself.
/// `prefs_provider.dart` re-exports it for everything that reads or writes
/// the setting normally.
const String aboutMeKey = 'about_me';

/// When each background pass last completed, ISO-8601 UTC.
///
/// They live in `app_prefs` rather than being derived from `activity_events`
/// because the events they describe are the ones that DO NOT get written: a
/// sync that brought nothing in records no row (see `ActivityLog.record`), and
/// "nothing has arrived for three hours" is exactly the fact the activity panel
/// has to be able to state. Written on every `ok` pass, suppressed or not, and
/// wiped by [MessageStore.wipeAll] along with everything else about this
/// mailbox — a fresh identity has not synced yet.
const String activityLastSyncMailKey = 'activity_last_sync_mail';
const String activityLastSyncTeamsKey = 'activity_last_sync_teams';
const String activityLastSweepKey = 'activity_last_sweep';

/// How often a worker holding a claim says it is still alive, by bumping the
/// row's `updated_at`.
///
/// One UPDATE by primary key per minute per in-flight item, against a drain
/// that is at most a handful wide — next to a model call it costs nothing,
/// and it is the whole reason [MessageStore.reclaimStaleTriage] can run while
/// a drain is live. Declared here rather than beside the queues because the
/// watchdog's window below is only correct in relation to it.
const Duration pipelineHeartbeatInterval = Duration(seconds: 60);

/// How long a claim may go unheard from before the watchdog takes it back.
///
/// Five heartbeats. A claim that is genuinely alive misses four of them and
/// still keeps its work; a claim whose process is gone — a crash, a killed
/// app, a queue torn down mid-item without a dispose — is back in the queue
/// within five minutes instead of waiting for the next launch.
const Duration staleClaimAfter = Duration(minutes: 5);

/// How long a row that has exhausted its retries is left alone before it is
/// given one more.
///
/// A day, because the failures that survive six attempts are the ones that
/// heal on a timescale a person changes something on: a model server left
/// off, a disk that filled, a build with a bad schema. One retry per row per
/// day self-schedules — the failing write restamps `updated_at`, so the row
/// falls out of reach until the next day — which is what keeps a genuinely
/// poisoned row from costing more than one model call a day.
const Duration terminalRetryAfter = Duration(hours: 24);

/// Where a row stops being retried at all.
///
/// A permanent ceiling is permanent data loss, so this is the number at which
/// a poisoned row stops COSTING anything rather than the number at which it
/// stops mattering: twelve attempts is six days of daily revivals, by which
/// point nothing transient is still failing.
const int terminalMaxAttempts = 12;

/// What the pipeline looks like right now: how much is queued, how much is
/// claimed, how much failed, and how much has been given up on.
///
/// `dead` is the subset of `error` past [terminalMaxAttempts] — the rows
/// nothing will retry again — which is the one number worth surfacing to a
/// person, because it is the only one that never resolves on its own.
typedef PipelineHealth = ({
  int triagePending,
  int triageProcessing,
  int triageError,
  int triageDead,
  int workPending,
  int workProcessing,
  int workError,
  int workDead,

  /// The oldest live claim's `updated_at`, or null when nothing is claimed. A
  /// value older than [staleClaimAfter] means the watchdog has not run.
  String? oldestClaimIso,
});

/// Every SQL statement in the app except the schema itself lives here. Screens
/// and providers call methods; they never build a query.
///
/// Two conventions every write below follows:
/// - booleans bind as explicit `0`/`1` integers. The database layer would
///   coerce a Dart `bool` for us, but the reads compare against `1`, and a
///   write that says what it stores is one less thing to hold in your head.
/// - `created_at` / `updated_at` are NOT NULL, so a caller that omits them
///   gets "now" rather than a constraint failure.
///
/// Every method is asynchronous because drift's executor is. The statements
/// are unchanged, but the gaps between them are real now: a method that
/// issues more than one runs them in a transaction, which is the atomicity
/// the synchronous store used to get for free.
class MessageStore {
  final BondDatabase db;

  MessageStore(this.db);

  /// The nearest-neighbour index over `message_vectors`, owned here.
  ///
  /// The store owns it because everything that touches it — [semanticSearch]
  /// reading, [indexPendingVectors] filing — has to be looking at the SAME
  /// connection the durable vectors were written down. `late final` rather
  /// than a constructor argument because the index's lifetime is exactly this
  /// store's, which is exactly the database's: [MessageVectorIndex.ensureReady]
  /// memoizes its answer per connection, so one that outlived a database swap
  /// would keep reporting on a connection nobody is using any more.
  late final MessageVectorIndex _vecIndex = MessageVectorIndex(db);

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// `?, ?, ?` for an IN clause of [n] values.
  static String _placeholders(int n) => List.filled(n, '?').join(', ');

  /// Positional arguments for the `?` placeholders every statement here is
  /// written against.
  static List<Variable> _args(List<Object?> values) => [
        for (final value in values) Variable(value),
      ];

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
  ///
  /// `addressed_me` is the one exception to that rule, and it moves on
  /// conflict — but only UP. A richer re-pull may raise it (the wire starts
  /// carrying mentions, and an already-stored chat message gains its @mention
  /// flag), while a thinner one must not lower it: a backend switched before
  /// the server sends mentions, or a sync whose keychain read failed, hands
  /// this exact code a payload that honestly computed 0 for a message that
  /// honestly earned its 1. The only real downgrade — an edit that removes an
  /// @mention — is rare, and keeping the flag errs toward attention, which is
  /// the direction this column exists to err in.
  ///
  /// Two statements now, in one transaction: every stored message also gets a
  /// `message_progress` row, `INSERT OR IGNORE` so a delta feed replaying the
  /// same page cannot reset a bar that has since filled in. This is the
  /// hottest write in the app — once per row of every delta page — so the
  /// progress row is composed here in Dart from what the caller already
  /// passed rather than re-derived in SQL.
  ///
  /// Returns the row's `received_at` when this call CREATED the progress row —
  /// the message is new to the pipeline — and null when it did not, which is
  /// every replay a delta feed makes. Non-null is what a live screen turns
  /// into its ingest tick: a message the gate throws out at ingest is finished
  /// by the time this returns, and no later stage will ever announce it.
  Future<String?> upsertMessage(Map<String, Object?> row) async {
    final now = _nowIso();
    final source = row['source'] ?? 'email';
    final id = row['source_message_id'];
    final createdAt = row['created_at'] ?? now;
    final triageStatus = row['triage_status'] ?? 'pending';
    final gateReason = row['gate_reason'] as String?;

    // The progress row's sort key, read once so the value bound below and the
    // value handed back are the same string.
    final receivedAt = (row['received_at'] ?? createdAt).toString();

    // A message the gate already threw out at ingest never enters the
    // pipeline, so its row lands finished rather than waiting on four stages
    // nothing will ever run. Keyed on the reason and not on `skipped` alone:
    // `skipped` with no reason is the legacy Teams tolerance, not a verdict.
    final gated = triageStatus == 'skipped' && gateReason != null;
    final triageState = switch (triageStatus) {
      'triaged' => 'done',
      'skipped' => 'skipped',
      'error' => 'error',
      'processing' => 'running',
      _ => 'pending',
    };

    final created = await db.transaction(() async {
      await db.customUpdate(
        '''
INSERT INTO messages (
  source, source_message_id, internet_message_id, conversation_key, direction,
  subject, from_name, from_address, to_json, received_at, is_read,
  body_preview, body_text, has_attachments, source_meta_json,
  triage_status, gate_reason, addressed_me,
  created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(source, source_message_id) DO UPDATE SET
  is_read = excluded.is_read,
  subject = COALESCE(excluded.subject, messages.subject),
  body_preview = COALESCE(excluded.body_preview, messages.body_preview),
  body_text = COALESCE(excluded.body_text, messages.body_text),
  addressed_me = MAX(messages.addressed_me, excluded.addressed_me),
  updated_at = excluded.updated_at
''',
        variables: _args([
          source,
          id,
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
          triageStatus,
          gateReason,
          row['addressed_me'] ?? 0,
          createdAt,
          row['updated_at'] ?? now,
        ]),
      );

      // The affected-row count is how an insert is told from an ignore: after
      // the fact there is nothing in the row itself that says which happened.
      return db.customUpdate(
        '''
INSERT OR IGNORE INTO message_progress (
  source, source_message_id, conversation_key, received_at,
  ingest_state, triage_state, extract_state, storyline_state, draft_state,
  settle_state, outcome, dropped, drop_reason, created_at, updated_at
) VALUES (?, ?, ?, ?, 'done', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
        variables: _args([
          source,
          id,
          row['conversation_key'],
          receivedAt,
          gated ? 'skipped' : triageState,
          gated ? 'skipped' : 'pending',
          gated ? 'skipped' : 'pending',
          // Every stage the gate closes, drafting included: nothing will ever
          // queue a reply for mail the gate threw out, and a stage left
          // `pending` on a row that is already finished is a bar that never
          // fills.
          gated ? 'skipped' : 'pending',
          gated ? 'done' : 'pending',
          gated ? 'dropped' : 'pending',
          gated ? 1 : 0,
          gated ? gateReason : null,
          createdAt,
          now,
        ]),
      );
    });
    return created > 0 ? receivedAt : null;
  }

  /// Whether this `(source, id)` is already stored.
  ///
  /// Asked BEFORE the upsert, because afterwards there is no way to tell an
  /// insert from a conflict — and the sync needs to know, since a message
  /// must be folded into its conversation exactly once no matter how many
  /// times a delta feed replays it.
  Future<bool> hasMessage(String source, String sourceMessageId) async {
    final result = await db
        .customSelect(
          'SELECT 1 FROM messages WHERE source = ? AND source_message_id = ? LIMIT 1',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    return result.isNotEmpty;
  }

  /// Writes what only the per-message detail fetch knows. Every column
  /// COALESCEs against itself, so a detail call that came back thin cannot
  /// blank a body, a header set, or an attachment flag already stored.
  Future<void> updateMessageDetail(
    String source,
    String sourceMessageId, {
    String? bodyText,
    bool? hasAttachments,
    String? sourceMetaJson,
  }) async {
    await db.customUpdate(
      'UPDATE messages SET '
      'body_text = COALESCE(?, body_text), '
      'has_attachments = COALESCE(?, has_attachments), '
      'source_meta_json = COALESCE(?, source_meta_json), '
      'updated_at = ? '
      'WHERE source = ? AND source_message_id = ?',
      variables: _args([
        bodyText,
        hasAttachments == null ? null : (hasAttachments ? 1 : 0),
        sourceMetaJson,
        _nowIso(),
        source,
        sourceMessageId,
      ]),
    );
  }

  /// One message row as stored, or null.
  ///
  /// The triage worker re-reads through this after it fetches a message's
  /// detail: the row it was handed predates that fetch, and the body and
  /// headers it is about to gate and classify on only exist on the new one.
  Future<Map<String, Object?>?> getMessageRow(
    String source,
    String sourceMessageId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM messages WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// One thread, oldest first — the order the chat transcript renders in.
  ///
  /// [untilIso] cuts the thread off at a moment, inclusive of it. That is what
  /// makes a per-message model call deterministic: the answer written for a
  /// message must be written from the thread AS IT WAS when that message
  /// landed, or the same message would be answered differently depending on
  /// how far behind the queue happened to be. `COALESCE(received_at,
  /// created_at)` because a message with no timestamp of its own is ordered by
  /// when it was stored everywhere else too.
  Future<List<Message>> loadThread(
    String conversationKey, {
    List<String> sources = const ['email'],
    String? untilIso,
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          'WHERE conversation_key = ? AND source IN (${_placeholders(sources.length)}) '
          '${untilIso == null ? '' : 'AND COALESCE(received_at, created_at) <= ? '}'
          // The tie-break matters now that one thread can hold two sources: two
          // messages sharing a second must render in ONE order, not whichever the
          // query plan felt like — same rule as storylineTimeline.
          'ORDER BY received_at ASC, source_message_id ASC',
          variables: _args([conversationKey, ...sources, ?untilIso]),
        )
        .get();
    return [for (final row in result) Message.fromRow(row.data)];
  }

  // ── conversations ────────────────────────────────────────────────────

  Future<void> upsertConversation(Map<String, Object?> row) async {
    final now = _nowIso();
    await db.customUpdate(
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
      variables: _args([
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
      ]),
    );
  }

  /// One conversation row as stored, or null. The sync reads this before it
  /// folds a message so the state machine can see the thread's own history —
  /// including a `done` a human set, which no incoming message may quietly
  /// overwrite.
  Future<Map<String, Object?>?> getConversationRow(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM conversations WHERE source = ? AND conversation_key = ?',
          variables: _args([source, conversationKey]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// Recounts one thread from the messages table.
  ///
  /// Counts are derived, never incremented: a delta page can replay messages
  /// already stored, and an incremented counter would drift a little further
  /// on every replay with nothing to correct it.
  Future<void> recomputeConversationCounts(
    String source,
    String conversationKey,
  ) async {
    await db.customUpdate(
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
      variables: _args([_nowIso(), source, conversationKey]),
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
  ///
  /// `unread_count` is counted here rather than kept on the thread's own row:
  /// the messages ARE the truth about what has been read, a read made in
  /// Outlook lands on them for free with the next delta page, and a maintained
  /// counter would drift with nothing to correct it. The subquery rides
  /// `ix_messages_conv`, which leads with the two columns it matches on.
  ///
  /// `ai_busy_messages` and `ai_busy_thread` count the pipeline steps still
  /// open against the thread — per-message ones (triage, extract) and
  /// thread-level ones (storyline, draft) — and are summed into
  /// `Conversation.aiPendingCount`. Two columns rather than one because they
  /// are keyed differently: message work is keyed by `source_message_id`,
  /// thread work by `conversation_key`.
  ///
  /// The `task_kind` allowlist on the second one is load-bearing. `mark_read`
  /// ack rows live in the same table under the SAME conversation key, and a
  /// count that included them would tell the user the model is thinking about
  /// a thread every time they opened one. (`storyline_sweep` is keyed to the
  /// singleton `'sweep'`, so it never matches a conversation key regardless.)
  ///
  /// Both are counted at read time and both default to zero where the columns
  /// are absent, because a read that cannot say must never claim the model is
  /// busy — an indicator that lies in that direction never turns off.
  Future<List<Conversation>> loadConversations({
    List<String> sources = const ['email'],
    ConversationState? state,
  }) async {
    if (sources.isEmpty) return const [];
    final where =
        StringBuffer('c.source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...sources];
    if (state != null) {
      where.write(' AND c.state = ?');
      args.add(state.wire);
    }
    final result = await db
        .customSelect(
          'SELECT c.*, ai.bucket AS bucket, ai.attention_score AS attention_score, '
          '  (SELECT COUNT(*) FROM messages m '
          '   WHERE m.source = c.source AND m.conversation_key = c.conversation_key '
          "     AND m.direction = 'inbound' AND m.is_read = 0) AS unread_count, "
          '  (SELECT COUNT(*) FROM messages m '
          '   WHERE m.source = c.source AND m.conversation_key = c.conversation_key '
          "     AND m.direction = 'inbound' "
          "     AND (m.triage_status IN ('pending','processing') "
          '          OR EXISTS (SELECT 1 FROM work_items w '
          "                      WHERE w.task_kind = 'extract' AND w.source = m.source "
          '                        AND w.entity_id = m.source_message_id '
          "                        AND w.status IN ('pending','processing')))) AS ai_busy_messages, "
          '  (SELECT COUNT(*) FROM work_items w '
          '   WHERE w.source = c.source AND w.entity_id = c.conversation_key '
          "     AND w.task_kind IN ('storyline','draft') "
          "     AND w.status IN ('pending','processing')) AS ai_busy_thread "
          'FROM conversations c '
          'LEFT JOIN conversation_ai ai '
          '  ON ai.source = c.source AND ai.conversation_key = c.conversation_key '
          'WHERE $where ORDER BY c.last_message_at DESC',
          variables: _args(args),
        )
        .get();
    return [for (final row in result) Conversation.fromRow(row.data)];
  }

  /// Flips a thread's state and stamps when it happened — "done 3 days ago"
  /// is a different row from "done just now", and only this write knows.
  Future<void> setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) async {
    final now = _nowIso();
    await db.customUpdate(
      'UPDATE conversations SET state = ?, state_changed_at = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      variables: _args([state.wire, now, now, source, conversationKey]),
    );
  }

  /// How many message ids one read-ack carries, newest first.
  static const int _readAckCap = 100;

  /// Marks every unread inbound message on one thread read, and queues the
  /// server the ack it is owed. Returns how many messages the flip touched.
  ///
  /// Reading the ids and flipping them is ONE transaction because the ack's
  /// payload is the set that WAS unread. Computed after the flip it would come
  /// back empty every time; computed before it in a separate statement it could
  /// name a message something else had already flipped in between.
  ///
  /// A thread with nothing unread returns 0 and writes nothing at all — no
  /// UPDATE, no work row — so reopening mail that was already read costs one
  /// indexed SELECT and queues no request.
  ///
  /// The flip is uncapped, the ack is capped: past [_readAckCap] the newest ids
  /// are the ones the server hears about, and the tail is simply never acked —
  /// it reads locally and stays unread on the server. Accepted: a single
  /// thread carrying a hundred unread messages is being cleared in bulk, and
  /// chunking requests to keep another client's badge exact is not worth it.
  ///
  /// The work row is hand-rolled rather than going through [requeueWork]
  /// because that method only revives `done` and `error` rows and NULLs the
  /// payload — and the payload is the whole point here. Ids merge into whatever
  /// is still pending, so a second read while the first ack is queued acks both.
  ///
  /// Nothing drains `mark_read` yet: the queue behind it lands with the server
  /// ack, and until then these rows accumulate at one per opened thread.
  Future<int> markConversationRead(
    String source,
    String conversationKey,
  ) async {
    const String unreadInbound =
        "source = ? AND conversation_key = ? AND direction = 'inbound' "
        'AND is_read = 0';

    return db.transaction(() async {
      final unread = await db
          .customSelect(
            'SELECT source_message_id FROM messages WHERE $unreadInbound '
            'ORDER BY received_at DESC LIMIT ?',
            variables: _args([source, conversationKey, _readAckCap]),
          )
          .get();
      if (unread.isEmpty) return 0;

      final now = _nowIso();
      final flipped = await db.customUpdate(
        'UPDATE messages SET is_read = 1, updated_at = ? WHERE $unreadInbound',
        variables: _args([now, source, conversationKey]),
      );

      final queued = await db
          .customSelect(
            'SELECT payload_json FROM work_items '
            "WHERE task_kind = 'mark_read' AND source = ? AND entity_id = ?",
            variables: _args([source, conversationKey]),
          )
          .get();
      final ids = <String>[
        for (final row in unread) row.data['source_message_id'] as String,
      ];
      if (queued.isNotEmpty) {
        for (final id in _decodeIds(queued.first.data['payload_json'])) {
          if (!ids.contains(id)) ids.add(id);
        }
      }

      await db.customUpdate(
        'INSERT INTO work_items '
        '(task_kind, source, entity_id, status, attempts, error, payload_json, '
        'created_at, updated_at) '
        "VALUES ('mark_read', ?, ?, 'pending', 0, NULL, ?, ?, ?) "
        'ON CONFLICT(task_kind, source, entity_id) DO UPDATE SET '
        "status = 'pending', attempts = 0, error = NULL, "
        'payload_json = excluded.payload_json, '
        'updated_at = excluded.updated_at',
        variables: _args([
          source,
          conversationKey,
          jsonEncode(ids.take(_readAckCap).toList()),
          now,
          now,
        ]),
      );

      return flipped;
    });
  }

  /// The ids a queued read-ack is already carrying. A row that has none, or one
  /// whose payload is not a JSON array of strings, carries nothing — a
  /// malformed payload must not cost the caller the ids it came to add.
  static List<String> _decodeIds(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final id in decoded)
          if (id is String) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Clears the model's ask off a thread. What "the CTA was answered" means.
  Future<void> clearCta(String source, String conversationKey) async {
    await db.customUpdate(
      "UPDATE conversations SET cta_text = NULL, cta_urgency = 'normal', "
      'updated_at = ? WHERE source = ? AND conversation_key = ?',
      variables: _args([_nowIso(), source, conversationKey]),
    );
  }

  // ── sync state ───────────────────────────────────────────────────────

  Future<String?> getDeltaLink(String folder, {String source = 'email'}) async {
    final result = await db
        .customSelect(
          'SELECT delta_link FROM sync_state WHERE source = ? AND folder = ?',
          variables: _args([source, folder]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['delta_link'] as String?;
  }

  Future<void> setDeltaLink(
    String folder,
    String? link, {
    String source = 'email',
  }) async {
    await db.customUpdate(
      'INSERT INTO sync_state (source, folder, delta_link, synced_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(source, folder) DO UPDATE SET '
      'delta_link = excluded.delta_link, synced_at = excluded.synced_at',
      variables: _args([source, folder, link, _nowIso()]),
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
  Future<void> setSyncedAt(
    String folder,
    String iso, {
    String source = 'email',
  }) async {
    await db.customUpdate(
      'INSERT INTO sync_state (source, folder, delta_link, synced_at) '
      'VALUES (?, ?, NULL, ?) '
      'ON CONFLICT(source, folder) DO UPDATE SET '
      'synced_at = excluded.synced_at',
      variables: _args([source, folder, iso]),
    );
  }

  /// When this source last finished a sync, or null when it never has.
  Future<String?> getSyncedAt(String folder, {String source = 'email'}) async {
    final result = await db
        .customSelect(
          'SELECT synced_at FROM sync_state WHERE source = ? AND folder = ?',
          variables: _args([source, folder]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['synced_at'] as String?;
  }

  // ── triage ───────────────────────────────────────────────────────────

  /// `triage_status` → count. Statuses with no rows are simply absent.
  Future<Map<String, int>> triageCounts({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT triage_status, COUNT(*) AS n FROM messages '
          'WHERE source IN (${_placeholders(sources.length)}) '
          'GROUP BY triage_status',
          variables: _args([...sources]),
        )
        .get();
    return {
      for (final row in result)
        (row.data['triage_status'] as String? ?? 'pending'):
            (row.data['n'] as num?)?.toInt() ?? 0,
    };
  }

  /// The next message for the triage worker: newest first, inbound only.
  ///
  /// Newest first, not oldest: the worker runs behind a live mailbox, so the
  /// mail worth classifying soonest is the mail that just landed. Outbound is
  /// excluded because triage answers "does this need me?" — the user's own sent
  /// mail never does.
  Future<Map<String, Object?>?> nextPendingTriage({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return null;
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          "WHERE triage_status = 'pending' AND direction = 'inbound' "
          'AND source IN (${_placeholders(sources.length)}) '
          'ORDER BY received_at DESC LIMIT 1',
          variables: _args([...sources]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// Takes the next message for the triage worker AND claims it, in one
  /// statement. The claimed row is returned as it now stands — `processing`,
  /// with a fresh `updated_at` — or null when there was nothing to claim.
  ///
  /// One statement rather than [nextPendingTriage] followed by a `processing`
  /// write, because between those two there is an await now, and a second
  /// drain reaching the same row inside that gap would be handed a message
  /// already spoken for. Here the pick and the claim are the same UPDATE:
  /// whichever of two concurrent claims lands second finds no pending row
  /// matching and gets null.
  ///
  /// The `rowid` subquery is what carries the ordering — `LIMIT` on the UPDATE
  /// itself needs a compile flag sqlite is not usually built with — and it
  /// mirrors [nextPendingTriage] exactly, so the two always pick the same row.
  Future<Map<String, Object?>?> claimPendingTriage({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return null;
    final claimed = await db.customWriteReturning(
      '''
UPDATE messages SET triage_status = 'processing', updated_at = ?
WHERE rowid IN (
  SELECT rowid FROM messages
  WHERE triage_status = 'pending' AND direction = 'inbound'
    AND source IN (${_placeholders(sources.length)})
  ORDER BY received_at DESC LIMIT 1
)
RETURNING *
''',
      variables: _args([_nowIso(), ...sources]),
    );
    if (claimed.isEmpty) return null;
    return Map<String, Object?>.from(claimed.first.data);
  }

  /// Demotes every pending inbound message except the newest [cap] to
  /// `skipped` / `backlog`.
  ///
  /// A first sync of a real mailbox lands thousands of messages at once.
  /// Triaging all of them would burn hours of model time on mail the user
  /// stopped caring about weeks ago, so only the freshest slice stays in the
  /// queue. Nothing is deleted — a skipped message still renders, it just
  /// never reaches the model.
  Future<void> capPendingTriage(int cap, {String source = 'email'}) async {
    await db.customUpdate(
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
      variables: _args([_nowIso(), source, source, cap]),
    );
  }

  /// Flips every message the last run left mid-flight back to `pending`.
  ///
  /// `processing` is a claim the worker takes before it calls the model and
  /// clears when it writes a result. Nothing else clears it, so a message the
  /// app was triaging when it quit would otherwise sit claimed forever —
  /// never retried, never surfaced. Called once at startup, before any worker
  /// can take a new claim.
  Future<void> resetInterruptedTriage({String source = 'email'}) async {
    await db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      'WHERE source = ? AND triage_status = ?',
      variables: _args([_nowIso(), source, 'processing']),
    );
  }

  /// Says the worker holding this claim is still alive, and nothing else.
  ///
  /// Only `updated_at` moves, which is what makes it safe to call from a timer
  /// while the item is mid-flight: nothing here can overwrite the result the
  /// worker is about to write.
  Future<void> touchTriage(String source, String sourceMessageId) async {
    await db.customUpdate(
      'UPDATE messages SET updated_at = ? '
      "WHERE source = ? AND source_message_id = ? AND triage_status = 'processing'",
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
  }

  /// Hands one claim back, if it is still a claim.
  ///
  /// Guarded on `processing` rather than written blind: a queue releasing what
  /// it thinks it holds must never be able to reopen a message that finished
  /// while the release was being decided — that would re-triage it, spend a
  /// model call, and resurrect the CTA an outbound reply had cleared.
  /// Attempts are untouched: releasing a claim is not a failed attempt.
  Future<void> releaseTriageClaim(String source, String sourceMessageId) async {
    await db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND source_message_id = ? AND triage_status = 'processing'",
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
  }

  /// Takes back every claim nothing has been heard from since
  /// [staleBeforeIso], and returns how many that was.
  ///
  /// Unlike [resetInterruptedTriage], this is safe to run DURING a live drain,
  /// and the heartbeat is why: a working claim restamps `updated_at` every
  /// [pipelineHeartbeatInterval], so a row can only fall behind a
  /// [staleClaimAfter] window if five beats in a row went missing — which
  /// means the worker that held it is gone. That is the difference that lets
  /// this run on every sync where the startup reset may only run before any
  /// worker exists.
  ///
  /// Attempts are untouched: nothing about the message failed.
  Future<int> reclaimStaleTriage({
    required String staleBeforeIso,
    List<String> sources = const ['email'],
  }) {
    if (sources.isEmpty) return Future.value(0);
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE triage_status = 'processing' "
      'AND source IN (${_placeholders(sources.length)}) '
      'AND updated_at < ?',
      variables: _args([_nowIso(), ...sources, staleBeforeIso]),
    );
  }

  /// Gives rows that exhausted [reviveErroredTriage]'s ceiling one more try,
  /// once a day, up to [maxAttempts].
  ///
  /// The alternative is a permanent ceiling, and a permanent ceiling is
  /// permanent data loss: the failures that reach six attempts are mostly
  /// local outages — a model server left off, a full disk — that heal on their
  /// own and take the message out of the pipeline forever anyway. The
  /// [olderThanIso] window is what bounds the cost: the failing write restamps
  /// `updated_at`, so each revival puts the row out of reach until the next
  /// day, and a genuinely poisoned row costs one model call a day until
  /// [terminalMaxAttempts] stops it for good.
  Future<int> reviveTerminalTriage({
    required String olderThanIso,
    int maxAttempts = terminalMaxAttempts,
    String source = 'email',
  }) {
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND triage_status = 'error' "
      // The 6 is [reviveErroredTriage]'s ceiling: below it that method already
      // revives the row on every sync, and the two must not both claim it.
      'AND triage_attempts >= 6 AND triage_attempts < ? '
      'AND updated_at < ?',
      variables: _args([_nowIso(), source, maxAttempts, olderThanIso]),
    );
  }

  /// Puts inbound messages a retired gate reason skipped back in the queue,
  /// and returns how many that was.
  ///
  /// For a gate this app has stopped writing: the rows it already wrote would
  /// otherwise stay `skipped` forever, because nothing re-examines a message
  /// triage has finished with. Scoped to [sinceIso] so a retired gate cannot
  /// hand the model a year of archive, and self-exhausting — once no code
  /// writes [gateReason], the second call matches nothing.
  Future<int> rependGatedTriage({
    required String source,
    required String gateReason,
    required String sinceIso,
  }) {
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', gate_reason = NULL, "
      'updated_at = ? '
      "WHERE source = ? AND direction = 'inbound' "
      "AND triage_status = 'skipped' AND gate_reason = ? "
      'AND received_at >= ?',
      variables: _args([_nowIso(), source, gateReason, sinceIso]),
    );
  }

  /// Puts the newest inbound message of each conversation back in the triage
  /// queue when triage v2 has never judged it, and returns how many that was.
  ///
  /// Three predicates, each carrying its own weight:
  /// - `reply_expected IS NULL` is what makes this self-exhausting. v2 writes
  ///   that column on every result, so a row it has judged — 0 included — is
  ///   out of reach on the next pass and the model is never asked twice.
  /// - only the NEWEST inbound per conversation, which bounds the spend: the
  ///   whole point is the standing ask on a thread, and the message that
  ///   carries it is the last one the other side sent. Ties break on
  ///   `source_message_id DESC`, the same way [latestInboundMeta] breaks them,
  ///   so both agree on which message that is.
  /// - `received_at >= sinceIso`, so a v1 archive cannot hand the model a year
  ///   of history to re-judge.
  Future<int> rejudgeStaleTriage({
    required String source,
    required String sinceIso,
  }) {
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND direction = 'inbound' "
      "AND triage_status = 'triaged' "
      'AND reply_expected IS NULL AND received_at >= ? '
      'AND NOT EXISTS ('
      '  SELECT 1 FROM messages m2 '
      '  WHERE m2.source = messages.source '
      '    AND m2.conversation_key = messages.conversation_key '
      "    AND m2.direction = 'inbound' "
      '    AND (m2.received_at > messages.received_at '
      '         OR (m2.received_at = messages.received_at '
      '             AND m2.source_message_id > messages.source_message_id)))',
      variables: _args([_nowIso(), source, sinceIso]),
    );
  }

  /// A JSON-encoded TEXT column as a list, tolerating null, empty string,
  /// malformed JSON and a payload that decodes to something else. The two
  /// backfills below read columns written by two different connectors, and
  /// neither may throw over a row it cannot parse.
  ///
  /// Not [_decodeIds], which is stricter on purpose: it drops everything that
  /// is not a string, and `participants_json` holds objects.
  static List<dynamic> _decodeJsonList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    } on FormatException {
      return const [];
    }
  }

  /// Marks the stored mail that was addressed to the user alone, and returns
  /// how many rows that was.
  ///
  /// The one-time catch-up for [addressed_me], which only exists from the sync
  /// that started writing it onward. Sole To: recipient and nothing else — CC
  /// never reaches `to_json`, which IS the rule the ingest applies.
  ///
  /// Decoded in Dart rather than matched in SQL: `to_json` is a JSON array, and
  /// a LIKE against its text would call `sarah@x.com` a match for a message to
  /// `not-sarah@x.com`.
  Future<int> backfillEmailAddressedMe({
    required String userAddress,
    required String sinceIso,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT source_message_id, to_json FROM messages '
          "WHERE source = 'email' AND direction = 'inbound' "
          'AND received_at >= ?',
          variables: _args([sinceIso]),
        )
        .get();

    final me = userAddress.toLowerCase();
    final ids = <String>[];
    for (final row in rows) {
      final recipients = _decodeJsonList(row.data['to_json']);
      if (recipients.length != 1) continue;
      if (recipients.first.toString().toLowerCase() != me) continue;
      final id = row.data['source_message_id'] as String?;
      if (id != null) ids.add(id);
    }
    if (ids.isEmpty) return 0;

    return db.customUpdate(
      'UPDATE messages SET addressed_me = 1, updated_at = ? '
      "WHERE source = 'email' "
      'AND source_message_id IN (${_placeholders(ids.length)})',
      variables: _args([_nowIso(), ...ids]),
    );
  }

  /// Marks the stored chat messages that arrived in a 1:1 chat, and returns how
  /// many rows that was.
  ///
  /// Only the 1:1 half of the signal: an @mention was never stored anywhere, so
  /// there is nothing on disk to read it back out of. Mentions start counting
  /// from the first sync that writes them, and the history stays quiet rather
  /// than being guessed at.
  ///
  /// A 1:1 chat is one whose stored participants number exactly one — the
  /// roster is written without the user themselves.
  Future<int> backfillTeamsAddressedMe({required String sinceIso}) async {
    final rows = await db
        .customSelect(
          "SELECT conversation_key, participants_json FROM conversations "
          "WHERE source = 'teams'",
        )
        .get();

    final keys = [
      for (final row in rows)
        if (_decodeJsonList(row.data['participants_json']).length == 1)
          if (row.data['conversation_key'] case final String key) key,
    ];
    if (keys.isEmpty) return 0;

    return db.customUpdate(
      'UPDATE messages SET addressed_me = 1, updated_at = ? '
      "WHERE source = 'teams' AND direction = 'inbound' "
      'AND received_at >= ? '
      'AND conversation_key IN (${_placeholders(keys.length)})',
      variables: _args([_nowIso(), sinceIso, ...keys]),
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
  Future<void> updateConversationTriage(
    String source,
    String conversationKey, {
    String? ctaText,
    required String ctaUrgency,
    String? category,
  }) async {
    await db.customUpdate(
      'UPDATE conversations SET cta_text = ?, cta_urgency = ?, '
      'category = COALESCE(?, category), updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      variables: _args(
        [ctaText, ctaUrgency, category, _nowIso(), source, conversationKey],
      ),
    );
  }

  /// Records the outcome of one triage attempt. Only the fields this call
  /// actually carries are written: a status-only call (e.g. marking a message
  /// `gated`) leaves any previous result columns alone rather than nulling
  /// them.
  Future<void> writeTriage(
    String source,
    String sourceMessageId, {
    required String status,
    TriageResult? result,
    String? error,
    String? gateReason,
    int? attempts,
  }) async {
    final sets = <String>['triage_status = ?', 'updated_at = ?'];
    final args = <Object?>[status, _nowIso()];

    if (result != null) {
      sets.addAll([
        'urgency = ?',
        'category = ?',
        'label = ?',
        'summary = ?',
        'needs_action = ?',
        'action_items_json = ?',
        'reply_expected = ?',
        'deadline = ?',
      ]);
      args.addAll([
        result.urgency,
        result.category,
        // NULL, not '': an empty label means the model offered none, and the
        // column reads the same as a message triage never reached.
        result.label.isEmpty ? null : result.label,
        result.summary,
        // An explicit int — `needs_action` is read back as `row != 0`.
        result.needsAction ? 1 : 0,
        jsonEncode(result.actionItems),
        // Writing this is what takes a row out of `rejudgeStaleTriage`'s
        // reach: NULL means v2 never looked, and 0 is a judgement it made.
        result.replyExpected ? 1 : 0,
        // NULL, not '': the same rule `label` takes, and it means the message
        // named no date rather than naming an empty one.
        result.deadline.isEmpty ? null : result.deadline,
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
    await db.customUpdate(
      'UPDATE messages SET ${sets.join(', ')} '
      'WHERE source = ? AND source_message_id = ?',
      variables: _args(args),
    );
  }

  /// Records what the needs-you pass decided about one message.
  ///
  /// Targeted like [writeTriage], and for the same reason: this stage owns
  /// exactly two columns, and a write that carried the rest of the row would
  /// be free to undo a triage that finished while the pass was thinking.
  ///
  /// [verdict] is tri-state, and the null arm is a real answer rather than a
  /// missing argument: it puts the row back on the worklist. `false` is a
  /// judgement that the message does not need the owner, which is a different
  /// fact from never having been judged, and nothing may read the two as one.
  Future<void> writeNeedsYouVerdict(
    String source,
    String sourceMessageId, {
    required bool? verdict,
    String? reason,
  }) async {
    await db.customUpdate(
      'UPDATE messages SET needs_you_verdict = ?, needs_you_reason = ?, '
      'updated_at = ? WHERE source = ? AND source_message_id = ?',
      variables: _args([
        verdict == null ? null : (verdict ? 1 : 0),
        // NULL, not '': the same rule `label` takes in [writeTriage] — an
        // empty reason is no reason, and it should read like one.
        (reason == null || reason.isEmpty) ? null : reason,
        _nowIso(),
        source,
        sourceMessageId,
      ]),
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
  Future<void> enqueueWork(
    String kind,
    String source,
    String entityId, {
    String? payloadJson,
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT OR IGNORE INTO work_items '
      '(task_kind, source, entity_id, status, attempts, error, payload_json, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, 'pending', 0, NULL, ?, ?, ?)",
      variables: _args([kind, source, entityId, payloadJson, now, now]),
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
  /// [triageStatuses] and [gateReasons] narrow that for a caller whose
  /// messages reach this table some other way; both connectors take the
  /// defaults, because both now put their inbound messages through triage. A
  /// caller that widens the statuses should narrow the reasons to match, or a
  /// `skipped` status would drag in the bulk senders and backlog the defaults
  /// deliberately leave out.
  Future<int> enqueueExtractBacklog({
    int cap = 150,
    required String sinceIso,
    String source = 'email',
    List<String> triageStatuses = const ['pending', 'processing', 'triaged'],
    List<String>? gateReasons,
  }) =>
      _enqueueMessageBacklog(
        kind: 'extract',
        cap: cap,
        sinceIso: sinceIso,
        source: source,
        triageStatuses: triageStatuses,
        gateReasons: gateReasons,
      );

  /// Queues the needs-you judgement for the same messages extraction gets, and
  /// returns how many rows that added.
  ///
  /// [enqueueExtractBacklog]'s twin, argument for argument, and the symmetry is
  /// load-bearing rather than convenient: the same filter and the same caps are
  /// what guarantee that every row extraction will read has been through this
  /// pass first. Two different windows here would leave extraction reading a
  /// verdict for some messages and NULL — "never judged" — for others, with
  /// nothing on the row to say which kind of NULL it was looking at.
  Future<int> enqueueNeedsYouBacklog({
    int cap = 150,
    required String sinceIso,
    String source = 'email',
    List<String> triageStatuses = const ['pending', 'processing', 'triaged'],
    List<String>? gateReasons,
  }) =>
      _enqueueMessageBacklog(
        kind: 'needs_you',
        cap: cap,
        sinceIso: sinceIso,
        source: source,
        triageStatuses: triageStatuses,
        gateReasons: gateReasons,
      );

  /// The backlog enqueue both per-message kinds run, with [kind] the only
  /// thing that differs — one statement, so the two queues cannot drift apart
  /// into covering different sets of messages.
  Future<int> _enqueueMessageBacklog({
    required String kind,
    required int cap,
    required String sinceIso,
    required String source,
    required List<String> triageStatuses,
    required List<String>? gateReasons,
  }) async {
    // An empty list would render as `IN ()`, which sqlite rejects. Nothing is
    // queued because nothing was asked for.
    if (triageStatuses.isEmpty) return 0;
    if (gateReasons != null && gateReasons.isEmpty) return 0;

    final now = _nowIso();
    return db.customUpdate(
      '''
INSERT OR IGNORE INTO work_items (
  task_kind, source, entity_id, status, attempts, error, payload_json,
  created_at, updated_at
)
SELECT ?, source, source_message_id, 'pending', 0, NULL, NULL,
  COALESCE(received_at, ?), ?
FROM messages
WHERE source = ? AND direction = 'inbound'
  AND triage_status IN (${_placeholders(triageStatuses.length)})
  ${gateReasons == null ? '' : 'AND gate_reason IN (${_placeholders(gateReasons.length)})'}
  AND received_at >= ?
ORDER BY received_at DESC
LIMIT ?
''',
      variables: _args([
        kind,
        now,
        now,
        source,
        ...triageStatuses,
        ...?gateReasons,
        sinceIso,
        cap,
      ]),
    );
  }

  /// The next item of one [kind] for the worker.
  ///
  /// Newest first, like triage — and with `entity_id` behind it purely as a
  /// tie-break, since a batch enqueue stamps every row it inserts with the
  /// same `created_at` and an unordered LIMIT 1 would be free to hand the same
  /// drain a different row on every call.
  Future<Map<String, Object?>?> nextPendingWork(
    String kind, {
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return null;
    final result = await db
        .customSelect(
          'SELECT * FROM work_items '
          "WHERE task_kind = ? AND status = 'pending' "
          'AND source IN (${_placeholders(sources.length)}) '
          'ORDER BY created_at DESC, entity_id DESC LIMIT 1',
          variables: _args([kind, ...sources]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// Takes the next item of one [kind] AND claims it, in one statement — the
  /// work queue's [claimPendingTriage], with the same guarantee for the same
  /// reason: two drains, or two iterations of one bounded-concurrent drain,
  /// can never be handed the same row, because the second UPDATE finds nothing
  /// pending to match.
  ///
  /// The returned row is the claimed one as it now stands: `processing`, with
  /// a fresh `updated_at`, and `attempts` untouched — which is what the
  /// worker's failure path counts from.
  Future<Map<String, Object?>?> claimPendingWork(
    String kind, {
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return null;
    final claimed = await db.customWriteReturning(
      '''
UPDATE work_items SET status = 'processing', updated_at = ?
WHERE rowid IN (
  SELECT rowid FROM work_items
  WHERE task_kind = ? AND status = 'pending'
    AND source IN (${_placeholders(sources.length)})
  ORDER BY created_at DESC, entity_id DESC LIMIT 1
)
RETURNING *
''',
      variables: _args([_nowIso(), kind, ...sources]),
    );
    if (claimed.isEmpty) return null;
    return Map<String, Object?>.from(claimed.first.data);
  }

  /// Records the outcome of one work item. Like [writeTriage], only the
  /// fields this call carries are written, so claiming an item does not blank
  /// the error a previous attempt left behind.
  Future<void> writeWork(
    String kind,
    String source,
    String entityId, {
    required String status,
    String? error,
    int? attempts,
  }) async {
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
    await db.customUpdate(
      'UPDATE work_items SET ${sets.join(', ')} '
      'WHERE task_kind = ? AND source = ? AND entity_id = ?',
      variables: _args(args),
    );
  }

  /// `status` → count for one kind. Statuses with no rows are simply absent.
  Future<Map<String, int>> workCounts(
    String kind, {
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT status, COUNT(*) AS n FROM work_items '
          'WHERE task_kind = ? AND source IN (${_placeholders(sources.length)}) '
          'GROUP BY status',
          variables: _args([kind, ...sources]),
        )
        .get();
    return {
      for (final row in result)
        (row.data['status'] as String? ?? 'pending'):
            (row.data['n'] as num?)?.toInt() ?? 0,
    };
  }

  /// Frees every claim a previous run left behind, across every kind.
  ///
  /// `processing` is taken before the worker's first await and cleared when it
  /// writes a result; nothing else clears it, so an item the app was working
  /// on when it quit would sit claimed forever. Startup only — running this
  /// while a worker holds a claim would hand its item to a second drain.
  Future<void> resetInterruptedWork() async {
    await db.customUpdate(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'processing'",
      variables: _args([_nowIso()]),
    );
  }

  /// Flips errored work rows back to `pending` so a transient failure heals
  /// on a later sync instead of removing the item from the pipeline forever.
  ///
  /// Attempts are deliberately NOT reset: the drain errors a row again at its
  /// next failed attempt, so each revival buys exactly one more try, and the
  /// [maxAttempts] ceiling is where a genuinely bad item stays down for good.
  ///
  /// [kind] narrows the revival to one queue. Absent it revives every kind,
  /// which is what the sync path wants; a queue that pumps on its own — the
  /// read-acks do, off a thread open — passes its own kind so that reviving
  /// its rows does not quietly hand a second chance to the model queues it
  /// shares the table with.
  Future<int> reviveErroredWork({int maxAttempts = 6, String? kind}) {
    return db.customUpdate(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'error' AND attempts < ?"
      '${kind == null ? '' : ' AND task_kind = ?'}',
      variables: _args([_nowIso(), maxAttempts, ?kind]),
    );
  }

  /// The triage half of [reviveErroredWork], with the same one-more-try
  /// semantics per revival and the same permanent ceiling.
  Future<int> reviveErroredTriage({
    String source = 'email',
    int maxAttempts = 6,
  }) {
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND triage_status = 'error' AND triage_attempts < ?",
      variables: _args([_nowIso(), source, maxAttempts]),
    );
  }

  /// [touchTriage] for the work queue, and for the same reason: only
  /// `updated_at` moves, so a heartbeat can never overwrite the result the
  /// worker is mid-way through producing.
  Future<void> touchWork(String kind, String source, String entityId) async {
    await db.customUpdate(
      'UPDATE work_items SET updated_at = ? '
      "WHERE task_kind = ? AND source = ? AND entity_id = ? "
      "AND status = 'processing'",
      variables: _args([_nowIso(), kind, source, entityId]),
    );
  }

  /// [releaseTriageClaim] for the work queue, guarded on `processing` for the
  /// same reason: a release must never reopen an item that finished while the
  /// release was being decided.
  Future<void> releaseWorkClaim(
    String kind,
    String source,
    String entityId,
  ) async {
    await db.customUpdate(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      'WHERE task_kind = ? AND source = ? AND entity_id = ? '
      "AND status = 'processing'",
      variables: _args([_nowIso(), kind, source, entityId]),
    );
  }

  /// [reclaimStaleTriage] for the work queue — same window, same heartbeat,
  /// same reason it is safe to run while a drain is live, and attempts
  /// likewise untouched.
  ///
  /// Every kind at once, deliberately: the claims this frees belong to a
  /// worker that no longer exists, and which queue they were in says nothing
  /// about that.
  Future<int> reclaimStaleWork({required String staleBeforeIso}) {
    return db.customUpdate(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'processing' AND updated_at < ?",
      variables: _args([_nowIso(), staleBeforeIso]),
    );
  }

  /// [reviveTerminalTriage] for the work queue, with the same daily budget and
  /// the same ceiling. [kind] narrows it to one queue, exactly as
  /// [reviveErroredWork]'s does.
  Future<int> reviveTerminalWork({
    required String olderThanIso,
    int maxAttempts = terminalMaxAttempts,
    String? kind,
  }) {
    return db.customUpdate(
      "UPDATE work_items SET status = 'pending', updated_at = ? "
      "WHERE status = 'error' "
      // The 6 is [reviveErroredWork]'s ceiling — see [reviveTerminalTriage].
      'AND attempts >= 6 AND attempts < ? AND updated_at < ?'
      '${kind == null ? '' : ' AND task_kind = ?'}',
      variables: _args([_nowIso(), maxAttempts, olderThanIso, ?kind]),
    );
  }

  /// Both queues in one read: what is waiting, what is claimed, what failed,
  /// and what has been given up on.
  ///
  /// The only read in this file that spans the two tables, because the
  /// question it answers — "is anything stuck?" — is not a question about
  /// either one of them. `error` counts every failed row and `dead` the subset
  /// past [terminalMaxAttempts], so `error - dead` is what a later sync will
  /// still retry on its own.
  Future<PipelineHealth> pipelineHealth({
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) {
      return (
        triagePending: 0,
        triageProcessing: 0,
        triageError: 0,
        triageDead: 0,
        workPending: 0,
        workProcessing: 0,
        workError: 0,
        workDead: 0,
        oldestClaimIso: null,
      );
    }
    final places = _placeholders(sources.length);

    final triage = await db
        .customSelect(
          'SELECT triage_status AS status, COUNT(*) AS n, '
          'SUM(CASE WHEN triage_attempts >= ? THEN 1 ELSE 0 END) AS dead '
          'FROM messages WHERE source IN ($places) GROUP BY triage_status',
          variables: _args([terminalMaxAttempts, ...sources]),
        )
        .get();
    final work = await db
        .customSelect(
          'SELECT status, COUNT(*) AS n, '
          'SUM(CASE WHEN attempts >= ? THEN 1 ELSE 0 END) AS dead '
          'FROM work_items WHERE source IN ($places) GROUP BY status',
          variables: _args([terminalMaxAttempts, ...sources]),
        )
        .get();
    // One claim age for the pipeline as a whole: whichever queue holds it, an
    // old claim means the same thing.
    final oldest = await db
        .customSelect(
          'SELECT MIN(updated_at) AS oldest FROM ('
          "SELECT updated_at FROM messages WHERE triage_status = 'processing' "
          'AND source IN ($places) '
          'UNION ALL '
          "SELECT updated_at FROM work_items WHERE status = 'processing' "
          'AND source IN ($places))',
          variables: _args([...sources, ...sources]),
        )
        .get();

    int countOf(List<QueryRow> rows, String status) => rows
        .where((row) => row.data['status'] == status)
        .fold(0, (sum, row) => sum + ((row.data['n'] as num?)?.toInt() ?? 0));
    int deadOf(List<QueryRow> rows) => rows
        .where((row) => row.data['status'] == 'error')
        .fold(0, (sum, row) => sum + ((row.data['dead'] as num?)?.toInt() ?? 0));

    return (
      triagePending: countOf(triage, 'pending'),
      triageProcessing: countOf(triage, 'processing'),
      triageError: countOf(triage, 'error'),
      triageDead: deadOf(triage),
      workPending: countOf(work, 'pending'),
      workProcessing: countOf(work, 'processing'),
      workError: countOf(work, 'error'),
      workDead: deadOf(work),
      oldestClaimIso:
          oldest.isEmpty ? null : oldest.first.data['oldest'] as String?,
    );
  }

  /// Empties every table, in one transaction. Sign-out calls this: the rows
  /// are one account's mailbox, and a different account signing in must not
  /// find them — mail, AI output, drafts, feedback, sender rules, and the
  /// delta cursors that would otherwise resume the OLD account's sync
  /// position against the new account's mailbox.
  ///
  /// `app_prefs` SURVIVES, with two exceptions. What this method isolates is
  /// one person's presence: which backend the app talks through, which server
  /// it points at, and where the slider sits are the machine's configuration,
  /// not the previous account's data, and wiping them turned every account
  /// switch into a re-setup. The exceptions are [dbOwnerKey] — the identity
  /// claim on these rows, which must not outlive the rows it describes, or
  /// the next sign-in would read the wiped mailbox as still owned — and
  /// [aboutMeKey], which is one person's self-description and would otherwise
  /// be inherited by the next identity and steer THEIR triage. Both callers
  /// depend on the first: sign-out leaves the database unclaimed, and
  /// `IdentityGuard` writes the new owner immediately after.
  Future<void> wipeAll() async {
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
      'activity_events',
      'sender_prefs',
      'drafts',
      'message_notify',
      'message_progress',
      'message_vectors',
    ];
    await db.transaction(() async {
      for (final table in tables) {
        await db.customUpdate('DELETE FROM $table');
      }
      await db.customUpdate(
        'DELETE FROM app_prefs WHERE key IN (?, ?)',
        variables: _args([dbOwnerKey, aboutMeKey]),
      );
    });
    // The vec0 index is derived from `message_vectors`, and the DELETE above
    // does not reach inside a virtual table: without this, the previous
    // mailbox's floats would survive the wipe in the index's shadow tables —
    // invisible to search (the hydrate join runs through the now-empty
    // durable table) but present on disk, which is not what a wipe means.
    // [MessageVectorIndex.rebuild] over an empty table is a drop and an empty
    // refill, and it fail-softs to nothing on a build without the extension.
    await _vecIndex.rebuild();
  }

  // ── per-message AI output ────────────────────────────────────────────

  /// Stores one message's extraction as JSON.
  ///
  /// A separate table rather than columns on `messages`: the shape of what the
  /// model extracts is still moving, and a JSON blob absorbs a new field
  /// without a migration. Nothing queries inside it.
  Future<void> writeExtraction(
    String source,
    String sourceMessageId,
    String extractionJson,
  ) async {
    await db.customUpdate(
      'INSERT INTO message_ai '
      '(source, source_message_id, extraction_json, extracted_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(source, source_message_id) DO UPDATE SET '
      'extraction_json = excluded.extraction_json, '
      'extracted_at = excluded.extracted_at',
      variables:
          _args([source, sourceMessageId, extractionJson, _nowIso()]),
    );
  }

  Future<String?> getExtraction(String source, String sourceMessageId) async {
    final result = await db
        .customSelect(
          'SELECT extraction_json FROM message_ai '
          'WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['extraction_json'] as String?;
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
  Future<void> upsertConversationAi(
    String source,
    String conversationKey, {
    Object? embedding = _unset,
    String? embeddedHash,
    String? embedModel,
  }) async {
    final now = _nowIso();

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

    // The insert and the update are one unit: the row this update targets is
    // the row the insert just guaranteed, and anything landing between them
    // would be writing to a thread whose AI state is half-written.
    await db.transaction(() async {
      await db.customUpdate(
        'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(source, conversation_key) DO NOTHING',
        variables: _args([source, conversationKey, now]),
      );
      await db.customUpdate(
        'UPDATE conversation_ai SET ${sets.join(', ')} '
        'WHERE source = ? AND conversation_key = ?',
        variables: _args(args),
      );
    });
  }

  Future<Map<String, Object?>?> getConversationAi(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM conversation_ai WHERE source = ? AND conversation_key = ?',
          variables: _args([source, conversationKey]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
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
  Future<void> setConversationBucket(
    String source,
    String conversationKey, {
    required String? bucket,
    String? reason,
  }) async {
    final now = _nowIso();
    await db.transaction(() async {
      await db.customUpdate(
        'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(source, conversation_key) DO NOTHING',
        variables: _args([source, conversationKey, now]),
      );
      await db.customUpdate(
        'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, updated_at = ? '
        'WHERE source = ? AND conversation_key = ?',
        variables: _args([bucket, reason, now, source, conversationKey]),
      );
    });
  }

  /// Stores one thread's ranking score. Same targeted insert-then-update as
  /// [setConversationBucket]: the score is recomputed on every list load and
  /// must never disturb an embedding or a bucket sitting on the same row.
  Future<void> writeAttentionScore(
    String source,
    String conversationKey,
    double score,
  ) async {
    final now = _nowIso();
    await db.transaction(() async {
      await db.customUpdate(
        'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(source, conversation_key) DO NOTHING',
        variables: _args([source, conversationKey, now]),
      );
      await db.customUpdate(
        'UPDATE conversation_ai SET attention_score = ?, updated_at = ? '
        'WHERE source = ? AND conversation_key = ?',
        variables: _args([score, now, source, conversationKey]),
      );
    });
  }

  /// `conversation_key` → who last decided where it goes, for every thread
  /// anyone has decided about.
  ///
  /// Threads nobody has ruled on are absent. Note that a thread can be here
  /// with no bucket: `(null, 'user')` means someone deliberately put it back in
  /// the inbox, which the sweep must respect exactly as much as a deliberate
  /// deferral — see [setConversationBucket].
  Future<Map<String, String?>> bucketReasons({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT conversation_key, bucket_reason FROM conversation_ai '
          'WHERE bucket_reason IS NOT NULL '
          'AND source IN (${_placeholders(sources.length)})',
          variables: _args([...sources]),
        )
        .get();
    return {
      for (final row in result)
        (row.data['conversation_key'] as String? ?? ''):
            row.data['bucket_reason'] as String?,
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
  ///
  /// The triage judgment columns ride along on the same row — `needs_action`,
  /// `reply_expected`, `deadline`, `addressed_me` — because the scorer reads
  /// them about exactly this message, the newest inbound one.
  Future<Map<String, Map<String, Object?>>> latestInboundMeta({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT conversation_key, source, source_message_id, from_address, '
          '  received_at, extraction_json, needs_action, reply_expected, '
          '  deadline, addressed_me FROM ('
          '  SELECT m.conversation_key AS conversation_key, m.source AS source, '
          '    m.source_message_id AS source_message_id, '
          '    m.from_address AS from_address, m.received_at AS received_at, '
          '    a.extraction_json AS extraction_json, '
          '    m.needs_action AS needs_action, '
          '    m.reply_expected AS reply_expected, '
          '    m.deadline AS deadline, m.addressed_me AS addressed_me, '
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
          variables: _args([...sources]),
        )
        .get();
    return {
      for (final row in result)
        (row.data['conversation_key'] as String? ?? ''):
            Map<String, Object?>.from(row.data),
    };
  }

  /// How often each sender gets answered, as a 0..1 fraction.
  ///
  /// A cheap approximation, and deliberately so: "replied" means the thread
  /// contains at least one outbound message, not that the user replied to THIS
  /// message. A thread the user started and a thread they answered look the same
  /// here. The scorer uses it as a small nudge (see
  /// `AttentionTuning.replyRateMax`), never as a decision, so the approximation
  /// costs a fraction of a point on a thread rather than a wrong bucket.
  ///
  /// Computed in SQL rather than by loading messages: on a real mailbox this is
  /// hundreds of thousands of rows, and it runs on every list load.
  Future<Map<String, double>> senderReplyRates({String source = 'email'}) async {
    final result = await db
        .customSelect(
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
          variables: _args([source]),
        )
        .get();
    final rates = <String, double>{};
    for (final row in result) {
      final address = row.data['addr'] as String? ?? '';
      if (address.isEmpty) continue;
      final threads = (row.data['threads'] as num?)?.toInt() ?? 0;
      if (threads == 0) continue;
      final replied = (row.data['replied'] as num?)?.toInt() ?? 0;
      rates[address] = replied / threads;
    }
    return rates;
  }

  /// Applies one sender-scoped decision to every thread that sender owns.
  ///
  /// **The latest inbound sender owns the thread.** A thread's sender is
  /// whoever wrote its newest inbound message, not whoever started it: a
  /// newsletter the user forwarded to a colleague who replied is that colleague's
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
  Future<int> rebucketSender(
    String address, {
    required String? bucket,
    String source = 'email',
  }) async {
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

    return db.transaction(() async {
      await db.customUpdate(
        'INSERT OR IGNORE INTO conversation_ai '
        '(source, conversation_key, updated_at) '
        'SELECT ?, conversation_key, ? FROM ($owned)',
        variables: _args([source, now, source, lowered]),
      );
      return db.customUpdate(
        'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, updated_at = ? '
        'WHERE source = ? AND conversation_key IN ($owned)',
        variables: _args([
          bucket,
          bucket == null ? null : 'sender_pref',
          now,
          source,
          source,
          lowered,
        ]),
      );
    });
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
  /// [origin] separates `explicit` (a button the user pressed) from `implicit`
  /// (opening a thread, marking one done). Implicit signals are far noisier and
  /// far more numerous, and anything that learns from these has to be able to
  /// tell them apart.
  Future<void> recordFeedback({
    required String scope,
    required String scopeKey,
    required String direction,
    required String origin,
  }) async {
    await db.customUpdate(
      'INSERT INTO feedback_events '
      '(scope, scope_key, direction, origin, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: _args([scope, scopeKey, direction, origin, _nowIso()]),
    );
  }

  // ── activity ─────────────────────────────────────────────────────────

  /// The AI work kinds [activityStats] aggregates. A module-level fact rather
  /// than inline strings so the stats queries and their tests agree on the set.
  static const List<String> activityWorkKinds = [
    'triage',
    'extract',
    'storyline',
    'storyline_sweep',
    'draft',
  ];

  /// Appends one thing the app did. INSERT only, like [recordFeedback] — the
  /// activity log is history, and history does not get edited.
  ///
  /// [count] and [durationMs] must be Dart ints: the table is STRICT and an
  /// INTEGER column rejects a double at write time.
  Future<void> recordActivity({
    required String kind,
    required String status,
    String? source,
    String? entityId,
    int? count,
    int? durationMs,
    String? detailJson,
    String? createdAt,
  }) async {
    await db.customUpdate(
      'INSERT INTO activity_events '
      '(kind, source, status, entity_id, count, duration_ms, detail_json, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: _args([
        kind,
        source,
        status,
        entityId,
        count,
        durationMs,
        detailJson,
        createdAt ?? _nowIso(),
      ]),
    );
  }

  /// The newest events first. Bounded by [limit] because the panel that reads
  /// this renders every row it is handed.
  Future<List<Map<String, Object?>>> recentActivity({
    int limit = 300,
    String? sinceIso,
  }) async {
    final result = sinceIso == null
        ? await db
            .customSelect(
              'SELECT * FROM activity_events ORDER BY id DESC LIMIT ?',
              variables: _args([limit]),
            )
            .get()
        : await db
            .customSelect(
              'SELECT * FROM activity_events WHERE created_at >= ? '
              'ORDER BY id DESC LIMIT ?',
              variables: _args([sinceIso, limit]),
            )
            .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Deletes what is older than [keepDays], then whatever is left beyond
  /// [maxRows]. Two rules rather than one: the age is what a user would
  /// expect "history" to mean, and the row cap is what stops a first sync of
  /// a large mailbox from filling the window with thousands of rows. Returns
  /// how many rows went.
  Future<int> pruneActivity({int keepDays = 30, int maxRows = 5000}) {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: keepDays))
        .toIso8601String();
    // One transaction because the returned total spans both deletes: a row
    // inserted between them would be counted against the cap it was never
    // measured against.
    return db.transaction(() async {
      var pruned = await db.customUpdate(
        'DELETE FROM activity_events WHERE created_at < ?',
        variables: _args([cutoff]),
      );
      pruned += await db.customUpdate(
        'DELETE FROM activity_events WHERE id NOT IN '
        '(SELECT id FROM activity_events ORDER BY id DESC LIMIT ?)',
        variables: _args([maxRows]),
      );
      return pruned;
    });
  }

  /// The activity panel's header numbers, over everything since [sinceIso].
  ///
  /// Three queries and a Dart finish: sqlite has no median, and under the
  /// prune cap the ordered read is a few thousand rows at worst. The three
  /// read one snapshot — a write landing between them would put an event in
  /// one number and not the others.
  Future<ActivityStats> activityStats({required String sinceIso}) {
    final kinds = _placeholders(activityWorkKinds.length);

    return db.transaction(() async {
      final ingested = <String, int>{};
      for (final row in await db
          .customSelect(
            'SELECT source, SUM(count) AS n FROM activity_events '
            "WHERE kind IN ('sync_mail', 'sync_teams') AND status = 'ok' "
            'AND created_at >= ? GROUP BY source',
            variables: _args([sinceIso]),
          )
          .get()) {
        final source = row.data['source'] as String?;
        final n = (row.data['n'] as num?)?.toInt() ?? 0;
        if (source != null && n > 0) ingested[source] = n;
      }

      final byKind = <String, Map<String, int>>{};
      var errorCount = 0;
      var aiItemCount = 0;
      for (final row in await db
          .customSelect(
            'SELECT kind, status, COUNT(*) AS n FROM activity_events '
            'WHERE kind IN ($kinds) AND created_at >= ? GROUP BY kind, status',
            variables: _args([...activityWorkKinds, sinceIso]),
          )
          .get()) {
        final kind = row.data['kind'] as String;
        final status = row.data['status'] as String;
        final n = (row.data['n'] as num).toInt();
        (byKind[kind] ??= {})[status] = n;
        aiItemCount += n;
        if (status == 'error') errorCount += n;
      }

      final durations = <String, List<int>>{};
      for (final row in await db
          .customSelect(
            'SELECT kind, duration_ms FROM activity_events '
            "WHERE kind IN ($kinds) AND duration_ms IS NOT NULL AND status = 'ok' "
            'AND created_at >= ? ORDER BY kind ASC, duration_ms ASC',
            variables: _args([...activityWorkKinds, sinceIso]),
          )
          .get()) {
        (durations[row.data['kind'] as String] ??= [])
            .add((row.data['duration_ms'] as num).toInt());
      }
      final avg = <String, int>{};
      final median = <String, int>{};
      durations.forEach((kind, sorted) {
        avg[kind] = (sorted.reduce((a, b) => a + b) / sorted.length).round();
        final mid = sorted.length ~/ 2;
        median[kind] = sorted.length.isOdd
            ? sorted[mid]
            : ((sorted[mid - 1] + sorted[mid]) / 2).round();
      });

      return ActivityStats(
        ingestedBySource: ingested,
        byKind: byKind,
        avgMsByKind: avg,
        medianMsByKind: median,
        errorCount: errorCount,
        aiItemCount: aiItemCount,
      );
    });
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
  Future<void> setSenderPref(String address, String? disposition) async {
    final lowered = address.toLowerCase();
    if (disposition == null) {
      await db.customUpdate(
        'DELETE FROM sender_prefs WHERE address = ?',
        variables: _args([lowered]),
      );
      return;
    }
    await db.customUpdate(
      'INSERT INTO sender_prefs (address, disposition, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(address) DO UPDATE SET '
      'disposition = excluded.disposition, updated_at = excluded.updated_at',
      variables: _args([lowered, disposition, _nowIso()]),
    );
  }

  /// One sender's rule, or null when there is none. Lowercases first, so a
  /// caller may pass whatever casing the message carried.
  Future<String?> getSenderPref(String address) async {
    final result = await db
        .customSelect(
          'SELECT disposition FROM sender_prefs WHERE address = ?',
          variables: _args([address.toLowerCase()]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['disposition'] as String?;
  }

  /// Every sender rule at once — what the scoring pass wants, since it asks
  /// about a rule for every thread in the inbox.
  Future<Map<String, String>> allSenderPrefs() async {
    final result = await db
        .customSelect('SELECT address, disposition FROM sender_prefs')
        .get();
    return {
      for (final row in result)
        (row.data['address'] as String? ?? ''):
            (row.data['disposition'] as String? ?? ''),
    };
  }

  /// One app-level setting, or null when it has never been set. Values are TEXT
  /// whatever they mean — a threshold is stored as its `toString()` and parsed
  /// back by the one reader that knows what it is.
  Future<String?> getPref(String key) async {
    final result = await db
        .customSelect(
          'SELECT value FROM app_prefs WHERE key = ?',
          variables: _args([key]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['value'] as String?;
  }

  Future<void> setPref(String key, String value) async {
    await db.customUpdate(
      'INSERT INTO app_prefs (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      variables: _args([key, value]),
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

  Future<void> insertStoryline({
    required String id,
    required String title,
    String? summary,
    String? charter,
    required String status,
    required String createdBy,
    String? memberHash,
    String? clusterHash,
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT INTO storylines '
      '(id, title, summary, charter, status, created_by, title_locked, '
      'charter_locked, pinned, member_hash, cluster_hash, last_activity_at, '
      'created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?, NULL, ?, ?)',
      variables: _args([
        id,
        title,
        summary,
        charter,
        status,
        createdBy,
        memberHash,
        clusterHash,
        now,
        now,
      ]),
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
  /// [summary] and [charter] use the [_unset] sentinel because null means
  /// something: a storyline whose summary should be cleared is a different
  /// write from one whose summary is simply not this call's business.
  ///
  /// There is deliberately no `clusterHash` here: `cluster_hash` is written
  /// once by [insertStoryline] and immutable after, which is the whole reason
  /// it can still name the group the user was asked about.
  Future<void> updateStoryline(
    String id, {
    String? title,
    Object? summary = _unset,
    Object? charter = _unset,
    String? status,
    bool? titleLocked,
    bool? charterLocked,
    bool? pinned,
    String? lastActivityAt,
    String? memberHash,
  }) async {
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
    if (!identical(charter, _unset)) {
      sets.add('charter = ?');
      args.add(charter as String?);
    }
    if (status != null) {
      sets.add('status = ?');
      args.add(status);
    }
    if (titleLocked != null) {
      sets.add('title_locked = ?');
      args.add(titleLocked ? 1 : 0);
    }
    if (charterLocked != null) {
      sets.add('charter_locked = ?');
      args.add(charterLocked ? 1 : 0);
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
    await db.customUpdate(
      'UPDATE storylines SET ${sets.join(', ')} WHERE id = ?',
      variables: _args(args),
    );
  }

  /// The rail's list: suggestions first, newest proposal at the top, then
  /// everything live by how recently it moved.
  ///
  /// Suggestions lead because they are the only rows that ask the user for
  /// something. `rowid DESC` is the final tie-break — two storylines written in
  /// the same microsecond would otherwise be free to swap places between
  /// reads, which reads on screen as the list shuffling itself.
  Future<List<Storyline>> loadStorylines({
    List<String> statuses = const ['suggested', 'active'],
  }) async {
    if (statuses.isEmpty) return const [];
    final result = await db
        .customSelect(
          '$_storylineSelect '
          'WHERE s.status IN (${_placeholders(statuses.length)}) '
          "ORDER BY (CASE WHEN s.status = 'suggested' THEN 0 ELSE 1 END), "
          "CASE WHEN s.status = 'suggested' THEN s.created_at END DESC, "
          "CASE WHEN s.status = 'suggested' THEN NULL ELSE s.last_activity_at END DESC, "
          's.rowid DESC',
          variables: _args([...statuses]),
        )
        .get();
    return [for (final row in result) Storyline.fromRow(row.data)];
  }

  Future<Storyline?> getStoryline(String id) async {
    final result = await db
        .customSelect('$_storylineSelect WHERE s.id = ?', variables: _args([id]))
        .get();
    if (result.isEmpty) return null;
    return Storyline.fromRow(result.first.data);
  }

  /// Adds a thread to a storyline, and un-blocks it.
  ///
  /// The un-block is the point: a block is a record of "the user took this out
  /// of here", and putting it back explicitly is the user changing their mind.
  /// Leaving the block behind would let the assignment pass silently refuse a
  /// membership a person just asked for.
  Future<void> addStorylineMember(
    String storylineId,
    String source,
    String conversationKey, {
    required String addedBy,
    String? evidence,
  }) async {
    // The membership and the un-block are the same decision; a reader that
    // caught only the insert would see a thread that is both a member and
    // blocked from being one.
    await db.transaction(() async {
      await db.customUpdate(
        'INSERT OR IGNORE INTO storyline_members '
        '(storyline_id, source, conversation_key, added_by, evidence, added_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: _args([
          storylineId,
          source,
          conversationKey,
          addedBy,
          evidence,
          _nowIso(),
        ]),
      );
      await db.customUpdate(
        'DELETE FROM storyline_member_blocks '
        'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
        variables: _args([storylineId, source, conversationKey]),
      );
    });
  }

  /// Takes a thread out of a storyline. [block] records that the user meant
  /// it, so the next clustering pass cannot put it straight back — the model
  /// is not allowed to overrule a person by being confident twice.
  Future<void> removeStorylineMember(
    String storylineId,
    String source,
    String conversationKey, {
    required bool block,
  }) async {
    if (!block) {
      await db.customUpdate(
        'DELETE FROM storyline_members '
        'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
        variables: _args([storylineId, source, conversationKey]),
      );
      return;
    }
    // Same unit as [addStorylineMember], for the mirror-image reason: a
    // removal that landed without its block would let the next sweep put the
    // thread straight back.
    await db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM storyline_members '
        'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
        variables: _args([storylineId, source, conversationKey]),
      );
      await db.customUpdate(
        'INSERT OR IGNORE INTO storyline_member_blocks '
        '(storyline_id, source, conversation_key, blocked_at) '
        'VALUES (?, ?, ?, ?)',
        variables: _args([storylineId, source, conversationKey, _nowIso()]),
      );
    });
  }

  Future<bool> isMemberBlocked(
    String storylineId,
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT 1 FROM storyline_member_blocks '
          'WHERE storyline_id = ? AND source = ? AND conversation_key = ? LIMIT 1',
          variables: _args([storylineId, source, conversationKey]),
        )
        .get();
    return result.isNotEmpty;
  }

  /// Every thread the user has removed from [storylineId], as
  /// `'<source>\n<conversation_key>'` composites — newline-joined because a
  /// newline can appear in neither half. The pane that offers threads to add
  /// leaves these out: a block is the user's own "no", and offering the
  /// thread back would invite them to overrule it by accident.
  Future<Set<String>> blockedThreadsOf(String storylineId) async {
    final result = await db
        .customSelect(
          'SELECT source, conversation_key FROM storyline_member_blocks '
          'WHERE storyline_id = ?',
          variables: _args([storylineId]),
        )
        .get();
    return {
      for (final row in result)
        '${row.data['source']}\n${row.data['conversation_key']}',
    };
  }

  Future<List<StorylineMember>> membersOf(String storylineId) async {
    final result = await db
        .customSelect(
          'SELECT * FROM storyline_members WHERE storyline_id = ? '
          'ORDER BY added_at ASC, conversation_key ASC',
          variables: _args([storylineId]),
        )
        .get();
    return [for (final row in result) StorylineMember.fromRow(row.data)];
  }

  /// Which live storylines one thread belongs to. Dismissed and archived ones
  /// are excluded: their member rows survive only as the record behind
  /// [dismissedHashExists], and a thread is not "in" a suggestion the
  /// user threw away.
  Future<List<String>> storylineIdsFor(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT m.storyline_id FROM storyline_members m '
          'JOIN storylines s ON s.id = m.storyline_id '
          'WHERE m.source = ? AND m.conversation_key = ? '
          "AND s.status IN ('suggested', 'active') "
          'ORDER BY m.added_at ASC',
          variables: _args([source, conversationKey]),
        )
        .get();
    return [
      for (final row in result) row.data['storyline_id'] as String? ?? '',
    ];
  }

  /// Every conversation with a comparable vector.
  ///
  /// [embedModel] is required rather than defaulted: two vectors are only
  /// comparable when they came from the same model under the same task prefix,
  /// and a query that quietly mixed generations would return cosines that mean
  /// nothing. The caller passes `EmbeddingsClient.modelTag`.
  Future<List<Map<String, Object?>>> conversationsWithEmbeddings({
    required String embedModel,
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
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
          variables: _args([embedModel, ...sources]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Every thread the sweep must leave alone: already in a live storyline, or
  /// explicitly kept out of one. Blocks count because a thread the user pulled
  /// out of a group is not a thread to propose a new group around.
  Future<Set<String>> assignedOrBlockedKeys(String source) async {
    final result = await db
        .customSelect(
          'SELECT m.conversation_key AS conversation_key FROM storyline_members m '
          'JOIN storylines s ON s.id = m.storyline_id '
          "WHERE m.source = ? AND s.status IN ('suggested', 'active') "
          'UNION '
          'SELECT b.conversation_key AS conversation_key '
          'FROM storyline_member_blocks b '
          'JOIN storylines s ON s.id = b.storyline_id '
          "WHERE b.source = ? AND s.status IN ('suggested', 'active')",
          variables: _args([source, source]),
        )
        .get();
    return {
      for (final row in result) row.data['conversation_key'] as String? ?? '',
    };
  }

  /// Whether this exact set of threads has already been proposed and thrown
  /// away. The sweep is deterministic, so without this a dismissed suggestion
  /// would be re-proposed identically on the very next sync.
  ///
  /// Both hashes answer, because a storyline can be dismissed under a set that
  /// is not the one it was proposed as. The `cluster_hash` arm recognises the
  /// proposal-time group — immutable, and exactly what the sweep rebuilds. The
  /// `member_hash` arm recognises the members as they stood at dismissal,
  /// maintained by every membership write, which is what catches a group the
  /// user pruned before saying no.
  Future<bool> dismissedHashExists(String hash) async {
    final result = await db
        .customSelect(
          "SELECT 1 FROM storylines WHERE status = 'dismissed' "
          'AND (cluster_hash = ? OR member_hash = ?) LIMIT 1',
          variables: _args([hash, hash]),
        )
        .get();
    return result.isNotEmpty;
  }

  /// Moves a storyline's activity stamp forward, never back. Threads are
  /// assigned in whatever order the queue drains them, so an older thread
  /// joining must not make a live storyline look stale.
  Future<void> touchStorylineActivity(String id, String lastMessageAt) async {
    await db.customUpdate(
      'UPDATE storylines SET last_activity_at = ?, updated_at = ? '
      'WHERE id = ? AND (last_activity_at IS NULL OR last_activity_at < ?)',
      variables: _args([lastMessageAt, _nowIso(), id, lastMessageAt]),
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
  Future<void> requeueWork(String kind, String source, String entityId) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT INTO work_items '
      '(task_kind, source, entity_id, status, attempts, error, payload_json, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, 'pending', 0, NULL, NULL, ?, ?) "
      'ON CONFLICT(task_kind, source, entity_id) DO UPDATE SET '
      "status = 'pending', updated_at = excluded.updated_at "
      "WHERE work_items.status IN ('done', 'error')",
      variables: _args([kind, source, entityId, now, now]),
    );
  }

  // ── drafts ───────────────────────────────────────────────────────────

  /// Writes the one draft a MESSAGE is allowed, replacing whatever was there.
  ///
  /// A full replace rather than a merge because that is what regenerating
  /// means: the second answer to a message supersedes the first, and keeping
  /// the old `graph_draft_id` would leave the Send button pointing at an
  /// Outlook draft holding text nobody can see any more. `created_at` survives
  /// — it says when this message first got a suggestion, which is the one fact
  /// a regenerate does not change.
  ///
  /// `options_dismissed` goes back to 0 for the same reason `graph_draft_id`
  /// is nulled: a regenerate is a FRESH suggestion, and the user closing the
  /// last set of short replies must not silence a set they have never seen.
  Future<void> upsertDraft({
    required String source,
    required String conversationKey,
    required String replyToMessageId,
    required String body,
    String? evidence,
    String? optionsJson,
    String status = 'suggested',
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      '''
INSERT INTO drafts (
  source, conversation_key, reply_to_message_id, body, evidence, status,
  graph_draft_id, web_link, created_at, updated_at, options_json,
  options_dismissed
) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, 0)
ON CONFLICT(source, reply_to_message_id) DO UPDATE SET
  conversation_key = excluded.conversation_key,
  body = excluded.body,
  evidence = excluded.evidence,
  status = excluded.status,
  graph_draft_id = NULL,
  web_link = NULL,
  updated_at = excluded.updated_at,
  options_json = excluded.options_json,
  options_dismissed = 0
''',
      variables: _args([
        source,
        conversationKey,
        replyToMessageId,
        body,
        evidence,
        status,
        now,
        now,
        optionsJson,
      ]),
    );
  }

  /// Closes the short replies without closing the draft. The row stays — the
  /// same reason `status = 'dismissed'` keeps it — so nothing writes the
  /// identical options straight back.
  Future<void> dismissDraftOptions(
    String source,
    String replyToMessageId,
  ) async {
    await db.customUpdate(
      'UPDATE drafts SET options_dismissed = 1, updated_at = ? '
      'WHERE source = ? AND reply_to_message_id = ?',
      variables: _args([_nowIso(), source, replyToMessageId]),
    );
  }

  /// The suggestion written against one message, or null.
  Future<Map<String, Object?>?> getDraftForMessage(
    String source,
    String messageId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM drafts WHERE source = ? AND reply_to_message_id = ?',
          variables: _args([source, messageId]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// Every suggestion stored against this conversation's messages, whatever
  /// their status — the thread view decides which are still showable.
  ///
  /// Unordered on purpose: the caller already holds the transcript, and the
  /// order that matters is the messages', not the drafts'. Keyed reads off the
  /// `(source, conversation_key)` index, so a thread with a long history of
  /// answered messages costs one indexed scan rather than one query per row.
  Future<List<Map<String, Object?>>> draftsForConversation(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM drafts WHERE source = ? AND conversation_key = ?',
          variables: _args([source, conversationKey]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// The suggestion a THREAD would show: the one answering its newest inbound
  /// message, and only that one.
  ///
  /// The subselect is what replaced the sync's delete-on-new-inbound. A draft
  /// written against an older message is still stored — it answers what was
  /// said then, and the history reads better with it — but it is not what this
  /// returns, so a thread whose newest message has not been drafted yet reads
  /// as having no suggestion rather than offering an answer to the
  /// second-to-last thing that was said. Nothing has to be deleted for that to
  /// be true.
  ///
  /// The subselect breaks ties on `source_message_id DESC`, the same way
  /// [newestInboundMessage] breaks them, so both agree on which message the
  /// thread is waiting on.
  Future<Map<String, Object?>?> getDraft(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT d.* FROM drafts d '
          'WHERE d.source = ? AND d.conversation_key = ? '
          'AND d.reply_to_message_id = ('
          '  SELECT m.source_message_id FROM messages m '
          '   WHERE m.source = ? AND m.conversation_key = ? '
          "     AND m.direction = 'inbound' "
          '   ORDER BY m.received_at DESC, m.source_message_id DESC LIMIT 1'
          ')',
          variables: _args([
            source,
            conversationKey,
            source,
            conversationKey,
          ]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// Moves a draft along its lifecycle — `suggested` → `edited` → `sent`, or
  /// `dismissed` — writing only the fields this call carries.
  ///
  /// Targeted like [writeTriage]: the edit that marks a draft touched must not
  /// blank the Outlook ids a save-to-drafts wrote, and a send must not rewrite
  /// the body the user is looking at.
  ///
  /// Keyed on the message, like every other write here. A thread-scoped UPDATE
  /// would mark every suggestion the thread ever collected as sent, including
  /// the answers to messages nobody sent anything about.
  Future<void> updateDraftStatus(
    String source,
    String replyToMessageId, {
    required String status,
    String? body,
    String? graphDraftId,
    String? webLink,
  }) async {
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

    args.addAll([source, replyToMessageId]);
    await db.customUpdate(
      'UPDATE drafts SET ${sets.join(', ')} '
      'WHERE source = ? AND reply_to_message_id = ?',
      variables: _args(args),
    );
  }

  /// Throws away the suggestion written against one message — what a
  /// regenerate does before it asks for another, since the handler returns
  /// early when this message already has one.
  Future<void> deleteDraftForMessage(String source, String messageId) async {
    await db.customUpdate(
      'DELETE FROM drafts WHERE source = ? AND reply_to_message_id = ?',
      variables: _args([source, messageId]),
    );
  }

  /// The message a reply would answer: the thread's newest inbound one.
  ///
  /// Ties break on `source_message_id DESC`, the same way [latestInboundMeta]
  /// breaks them, so the draft is written against the message the rest of the
  /// app agrees is the latest.
  Future<Map<String, Object?>?> newestInboundMessage(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          "WHERE source = ? AND conversation_key = ? AND direction = 'inbound' "
          'ORDER BY received_at DESC, source_message_id DESC LIMIT 1',
          variables: _args([source, conversationKey]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// The pieces of the embedding card that live on the message side: the
  /// newest inbound message's triage summary and its stored extraction.
  /// One query, LEFT JOIN, so a thread whose extraction has not run yet
  /// still answers with its summary. Ties break on `source_message_id
  /// DESC`, the same way [newestInboundMessage] breaks them.
  Future<Map<String, Object?>?> newestInboundCardData(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT m.summary, ai.extraction_json '
          'FROM messages m '
          'LEFT JOIN message_ai ai '
          '  ON ai.source = m.source '
          '  AND ai.source_message_id = m.source_message_id '
          "WHERE m.source = ? AND m.conversation_key = ? "
          "AND m.direction = 'inbound' "
          'ORDER BY m.received_at DESC, m.source_message_id DESC LIMIT 1',
          variables: _args([source, conversationKey]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// The user's own recent replies to one address, newest first — the tone the
  /// draft model is asked to match.
  ///
  /// `to_json LIKE '%address%'` is an APPROXIMATION and knowingly so. The
  /// recipients are a JSON array in a TEXT column, so this can match an address
  /// that merely contains the one asked for (`eric@x.com` inside
  /// `noteric@x.com`) and it matches a message the address was CC'd on as
  /// readily as one addressed to them. Both are fine for what this feeds: a
  /// handful of the user's own sentences shown to the model as a writing sample.
  /// A wrong sample costs a slightly-off tone, never a wrong recipient — the
  /// address a reply actually goes to comes from Graph's own `createReply`.
  Future<List<Map<String, Object?>>> recentOutboundToSender(
    String source,
    String senderAddress, {
    int limit = 2,
  }) async {
    if (senderAddress.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          "WHERE source = ? AND direction = 'outbound' AND to_json LIKE ? "
          'ORDER BY received_at DESC, source_message_id DESC LIMIT ?',
          variables:
              _args([source, '%${senderAddress.toLowerCase()}%', limit]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Every message of every member thread, merged into one chronology.
  ///
  /// Rows come back as raw `messages` rows — `conversation_key` and `subject`
  /// included — because the timeline needs both: the key to know when the
  /// transcript crosses from one thread into another, and the subject to name
  /// the thread it crossed into.
  Future<List<Map<String, Object?>>> storylineTimeline(
    String storylineId, {
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT m.* FROM messages m '
          'JOIN storyline_members sm '
          '  ON sm.source = m.source AND sm.conversation_key = m.conversation_key '
          'WHERE sm.storyline_id = ? '
          'AND m.source IN (${_placeholders(sources.length)}) '
          'ORDER BY m.received_at ASC, m.source_message_id ASC',
          variables: _args([storylineId, ...sources]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  // ── notifications ────────────────────────────────────────────────────

  /// Opens a notification row for every inbound message that could still earn
  /// a mention, and returns how many were opened.
  ///
  /// `INSERT OR IGNORE` on the message's own primary key is what makes this
  /// safe to call on every sweep: a message admitted once — and since settled
  /// — is not re-admitted, so a thread that keeps getting re-read cannot be
  /// announced twice.
  ///
  /// The two time bounds answer two different failure modes:
  /// - `created_at > armedAt` means "this row was written after the first
  ///   successful sync of THIS process". The first-run backlog was written
  ///   before that moment, so it admits nothing at all — the alternative is a
  ///   fresh install announcing a mailbox.
  /// - `received_at >= recencyFloorIso` is the guard `created_at` cannot give.
  ///   A first Teams connect stores weeks of chat history with a `created_at`
  ///   of right now; only the message's own timestamp says it is old. NULL
  ///   `received_at` fails the comparison and is excluded, deliberately: a
  ///   message with no time on it cannot be shown to be recent.
  ///
  /// `triage_status <> 'skipped'` is a pre-filter and nothing more — it saves
  /// opening a row for mail the gate already threw out. A message that becomes
  /// skipped AFTER admission is not deleted here; the sweep settles it
  /// `suppressed`/`gated`, because every admitted row settles exactly once.
  Future<int> admitNotifyCandidates({
    required String armedAtIso,
    required String recencyFloorIso,
    required String deadlineIso,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return 0;
    final now = _nowIso();
    final inserted = await db.customWriteReturning(
      '''
INSERT OR IGNORE INTO message_notify
  (source, source_message_id, conversation_key, state, reason, deadline_at,
   settled_at, created_at, updated_at)
SELECT m.source, m.source_message_id, m.conversation_key, 'pending', NULL, ?,
   NULL, ?, ?
FROM messages m
WHERE m.direction = 'inbound'
  AND m.source IN (${_placeholders(sources.length)})
  AND m.triage_status <> 'skipped'
  AND m.is_read = 0
  AND m.created_at > ?
  AND m.received_at >= ?
RETURNING source_message_id
''',
      variables: _args([
        deadlineIso,
        now,
        now,
        ...sources,
        armedAtIso,
        recencyFloorIso,
      ]),
    );
    return inserted.length;
  }

  /// Every still-open candidate with everything the sweep needs to decide it —
  /// one read, no per-row follow-up queries, because the sweep runs on a timer
  /// and a query per candidate would turn a quiet session into a busy one.
  ///
  /// The joins to `conversations` and `conversation_ai` are LEFT on purpose: a
  /// message can outrun its own conversation row, and a candidate with no
  /// attention score yet is not a candidate to drop — it is one to keep
  /// waiting on.
  ///
  /// `storyline_open` is keyed by CONVERSATION rather than by message, which
  /// over-waits when a sibling thread queued the work. That is the intended
  /// trade: announcing a message under the wrong storyline is worse than
  /// announcing it a few seconds late, and the deadline bounds how late.
  Future<List<Map<String, Object?>>> openNotifyCandidates({
    int limit = 50,
  }) async {
    final result = await db
        .customSelect(
          '''
SELECT n.source, n.source_message_id, n.conversation_key, n.deadline_at,
  m.subject, m.from_name, m.summary, m.urgency, m.deadline, m.needs_action,
  m.reply_expected, m.is_read, m.triage_status, m.received_at,
  m.updated_at AS message_updated_at,
  c.cta_text, c.cta_urgency, c.state AS conversation_state,
  ai.attention_score, ai.bucket, ai.updated_at AS ai_updated_at,
  EXISTS (SELECT 1 FROM work_items w
          WHERE w.task_kind = 'extract' AND w.source = n.source
            AND w.entity_id = n.source_message_id
            AND w.status IN ('pending','processing')) AS extract_open,
  EXISTS (SELECT 1 FROM work_items w
          WHERE w.task_kind = 'storyline' AND w.source = n.source
            AND w.entity_id = n.conversation_key
            AND w.status IN ('pending','processing')) AS storyline_open
FROM message_notify n
JOIN messages m ON m.source = n.source AND m.source_message_id = n.source_message_id
LEFT JOIN conversations c ON c.source = n.source AND c.conversation_key = n.conversation_key
LEFT JOIN conversation_ai ai ON ai.source = n.source AND ai.conversation_key = n.conversation_key
WHERE n.state = 'pending'
ORDER BY n.deadline_at ASC
LIMIT ?
''',
          variables: _args([limit]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Moves one candidate out of `pending`, and reports whether THIS call is
  /// the one that moved it.
  ///
  /// The `AND state = 'pending'` in the UPDATE is the exactly-once guard, the
  /// same trick [claimPendingTriage] plays: two settles racing for one row —
  /// two app instances on one file, or the sweep timer overlapping the drain
  /// hook — both run, but only the one that found the row still pending gets a
  /// row back. The emission is gated on that `true`, so the user is told once
  /// or not at all.
  Future<bool> settleNotify(
    String source,
    String sourceMessageId, {
    required String state,
    required String reason,
  }) async {
    final now = _nowIso();
    final rows = await db.customWriteReturning(
      'UPDATE message_notify SET state = ?, reason = ?, settled_at = ?, '
      'updated_at = ? '
      "WHERE source = ? AND source_message_id = ? AND state = 'pending' "
      'RETURNING source_message_id',
      variables: _args([
        state,
        reason,
        now,
        now,
        source,
        sourceMessageId,
      ]),
    );
    return rows.isNotEmpty;
  }

  /// Closes every row a dead process left open past its deadline, WITHOUT
  /// anything being emitted for them, and returns how many that was.
  ///
  /// Restart hygiene: the state machine lives on disk precisely so a crash
  /// cannot lose a message, but the flip side is that a row still `pending`
  /// from a session that ended hours ago is not news any more. A fresh process
  /// must not open with a burst of toasts about mail that settled while it was
  /// not running, so those rows are suppressed on the way in.
  Future<int> expireStaleNotify({required String nowIso}) {
    final now = _nowIso();
    return db.customUpdate(
      "UPDATE message_notify SET state = 'suppressed', reason = 'stale', "
      'settled_at = ?, updated_at = ? '
      "WHERE state = 'pending' AND deadline_at < ?",
      variables: _args([now, now, nowIso]),
    );
  }

  /// What was announced recently — the backing read for the "what did I miss"
  /// list, newest first.
  Future<List<Map<String, Object?>>> recentNotified({
    required String sinceIso,
    int limit = 20,
  }) async {
    final result = await db
        .customSelect(
          "SELECT * FROM message_notify WHERE state = 'notified' "
          'AND settled_at >= ? ORDER BY settled_at DESC LIMIT ?',
          variables: _args([sinceIso, limit]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  // ── pipeline progress ────────────────────────────────────────────────

  /// The states a stage stops at. `skipped` is one of them: a message the
  /// extractor was never going to look at has finished, and a bar that waited
  /// for it would wait forever.
  static const String _terminalStates = "('done', 'skipped', 'error')";

  /// Everything a home-feed row needs, in one projection.
  ///
  /// Shared by the two paging reads and the live patch read on purpose: they
  /// must return the same shape, or the notifier would be replacing complete
  /// rows with rows that have holes in them.
  /// The column list alone, so a read that needs the same row shape over a
  /// DIFFERENT set of joins — [semanticSearch] comes in through
  /// `message_vectors` — can have it without copying nineteen column names
  /// that [HomeFeedRow.fromRow] then has to keep agreeing with.
  static const String _homeFeedColumns = '''
p.source, p.source_message_id, p.conversation_key, p.received_at,
  p.triage_state, p.extract_state, p.storyline_state, p.draft_state,
  p.settle_state,
  p.outcome, p.dropped, p.drop_reason, p.storyline_id, p.needs_you, p.urgency,
  m.subject, m.from_name, m.from_address, s.title AS storyline_title''';

  static const String _homeFeedSelect = '''
SELECT $_homeFeedColumns
FROM message_progress p
JOIN messages m
  ON m.source = p.source AND m.source_message_id = p.source_message_id
LEFT JOIN storylines s ON s.id = p.storyline_id''';

  /// Records where triage got to, and returns the message's `received_at` so
  /// the caller can tick a live listener without a second read. Null when
  /// there is no progress row — a message stored before v8 that the backfill
  /// somehow missed, which costs the tick and nothing else.
  ///
  /// A gate skip is the one state that finishes the WHOLE row rather than one
  /// stage of it, and it has to be: the extract, storyline and draft queues
  /// honour the gate by never running, so nothing downstream is ever going to
  /// write those columns. Only stages still `pending` are closed out, so a
  /// re-gate after an extraction already landed does not erase what did
  /// happen.
  Future<String?> writeTriageProgress(
    String source,
    String sourceMessageId, {
    required String state,
    String? urgency,
    String? gateReason,
  }) async {
    final gated = state == 'skipped' && gateReason != null;
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  triage_state = ?1,
  triage_at = CASE WHEN ?1 IN $_terminalStates THEN ?2 ELSE triage_at END,
  urgency = COALESCE(?3, urgency),
  extract_state =
    CASE WHEN ?4 = 1 AND extract_state = 'pending' THEN 'skipped'
         ELSE extract_state END,
  storyline_state =
    CASE WHEN ?4 = 1 AND storyline_state = 'pending' THEN 'skipped'
         ELSE storyline_state END,
  draft_state =
    CASE WHEN ?4 = 1 AND draft_state = 'pending' THEN 'skipped'
         ELSE draft_state END,
  settle_state = CASE WHEN ?4 = 1 THEN 'done' ELSE settle_state END,
  settle_at = CASE WHEN ?4 = 1 THEN ?2 ELSE settle_at END,
  outcome = CASE WHEN ?4 = 1 THEN 'dropped' ELSE outcome END,
  dropped = CASE WHEN ?4 = 1 THEN 1 ELSE dropped END,
  drop_reason = CASE WHEN ?4 = 1 THEN ?5 ELSE drop_reason END,
  updated_at = ?2
WHERE source = ?6 AND source_message_id = ?7
RETURNING received_at
''',
      variables: _args([
        state,
        _nowIso(),
        urgency,
        gated ? 1 : 0,
        gateReason,
        source,
        sourceMessageId,
      ]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// Records where extraction got to. Same return contract as
  /// [writeTriageProgress].
  Future<String?> writeExtractProgress(
    String source,
    String sourceMessageId, {
    required String state,
  }) async {
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  extract_state = ?1,
  extract_at = CASE WHEN ?1 IN $_terminalStates THEN ?2 ELSE extract_at END,
  updated_at = ?2
WHERE source = ?3 AND source_message_id = ?4
RETURNING received_at
''',
      variables: _args([state, _nowIso(), source, sourceMessageId]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// Records where the reply suggestion got to, and closes the row when this
  /// was the last thing it was waiting on. Same return contract as
  /// [writeTriageProgress].
  ///
  /// The second half is why this is not just [writeExtractProgress] with
  /// another column name. Drafting is the last stage of the five, so on nearly
  /// every message this write is the one that finishes the pipeline — and
  /// closing the outcome here means the bar completes the moment the
  /// suggestion is in sqlite, rather than whenever the next settle sweep
  /// happens to run. Guarded on `outcome = 'pending'` so a row the coordinator
  /// already dropped keeps its verdict, and on every other stage being
  /// terminal so an out-of-order draft cannot close a row still being worked.
  Future<String?> writeDraftProgress(
    String source,
    String sourceMessageId, {
    required String state,
  }) async {
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  draft_state = ?1,
  draft_at = CASE WHEN ?1 IN $_terminalStates THEN ?2 ELSE draft_at END,
  outcome =
    CASE WHEN outcome = 'pending'
          AND ?1 IN $_terminalStates
          AND settle_state = 'done'
          AND triage_state IN $_terminalStates
          AND extract_state IN $_terminalStates
          AND storyline_state IN $_terminalStates
         THEN (CASE WHEN dropped = 1 THEN 'dropped' ELSE 'done' END)
         ELSE outcome END,
  updated_at = ?2
WHERE source = ?3 AND source_message_id = ?4
RETURNING received_at
''',
      variables: _args([state, _nowIso(), source, sourceMessageId]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// Records where the storyline pass got to, for every message of one
  /// conversation, and returns the ones it touched.
  ///
  /// Conversation-level because that is the grain the work is queued at: one
  /// assignment decides for the whole thread, so writing it per message would
  /// mean a read to find them and a statement each.
  ///
  /// Bounded by `settle_state <> 'done'`, which is what keeps a thread that
  /// keeps growing from rewriting the history above it — a message the user
  /// was told about last week must not gain a storyline column today, because
  /// the row they are scrolling past is a record of what they were told.
  ///
  /// [storylineId] null leaves whatever is stored alone: `noCandidate` and
  /// `rejected` are outcomes about this pass, not retractions of an earlier
  /// assignment.
  Future<List<({String sourceMessageId, String receivedAt})>>
      writeStorylineProgress(
    String source,
    String conversationKey, {
    required String state,
    String? storylineId,
  }) async {
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  storyline_state = ?1,
  storyline_at =
    CASE WHEN ?1 IN $_terminalStates THEN ?2 ELSE storyline_at END,
  storyline_id = COALESCE(?3, storyline_id),
  updated_at = ?2
WHERE source = ?4 AND conversation_key = ?5 AND settle_state <> 'done'
RETURNING source_message_id, received_at
''',
      variables: _args([state, _nowIso(), storylineId, source, conversationKey]),
    );
    return [
      for (final row in rows)
        (
          sourceMessageId: row.data['source_message_id'] as String? ?? '',
          receivedAt: row.data['received_at'] as String? ?? '',
        ),
    ];
  }

  /// Closes one message out, with the verdict the notification coordinator
  /// reached about it.
  ///
  /// Deliberately unguarded on `settle_state`: the sweep below may have closed
  /// this row as a backstop, and the coordinator's answer is the better one —
  /// it is the same call that decided whether to interrupt the user.
  ///
  /// `settle_state` and `needs_you` are written immediately and `outcome` is
  /// not, and that split is the whole point: a toast must never wait on a
  /// draft — the user is being told about mail, not about a suggestion — while
  /// the row is not FINISHED until the suggestion (or the decision that none
  /// is needed) is stored. [writeDraftProgress] closes it a moment later.
  Future<String?> writeSettledProgress(
    String source,
    String sourceMessageId, {
    required bool needsYou,
    required String reason,
    required bool dropped,
  }) async {
    final now = _nowIso();
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  settle_state = 'done',
  settle_at = ?1,
  outcome =
    CASE WHEN draft_state IN $_terminalStates
         THEN (CASE WHEN ?2 = 1 THEN 'dropped' ELSE 'done' END)
         ELSE 'pending' END,
  dropped = ?2,
  drop_reason = CASE WHEN ?2 = 1 THEN ?3 ELSE drop_reason END,
  needs_you = ?4,
  updated_at = ?1
WHERE source = ?5 AND source_message_id = ?6
RETURNING received_at
''',
      variables: _args([
        now,
        dropped ? 1 : 0,
        reason,
        needsYou ? 1 : 0,
        source,
        sourceMessageId,
      ]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// The backstop: closes every row whose stages have all finished and whose
  /// thread has an attention score, and returns the ones it closed.
  ///
  /// Most messages never reach the notification coordinator at all — outbound
  /// mail, anything read before the sweep, the whole backlog a first sync
  /// writes — so without this their bars would sit at "settling" forever. The
  /// attention score is the last thing the pipeline writes about a thread, and
  /// waiting for it is what stops this from closing a row the coordinator was
  /// still going to have an opinion about.
  ///
  /// [threshold] is the user's own attention floor, so the `needs_you` this
  /// writes means what the tiles elsewhere mean. It is the only place a
  /// verdict is reached in SQL rather than by `notifyWorthy` — see
  /// [needsYouSql] for why that is, and for the one clause that differs.
  ///
  /// It closes two shapes of row, which is what the WHERE says: one nothing
  /// ever settled, and one the coordinator settled while the draft was still
  /// being written — that second one has `settle_state = 'done'` and an
  /// `outcome` still `pending`, and without this it would never finish if the
  /// drafting queue never got back to it.
  ///
  /// A row the coordinator already settled keeps the `needs_you` it settled
  /// with. Recomputing it here would erase a Needs You the moment the user
  /// READ the message, and the decision is that a chip once earned survives
  /// reading — it clears when the user replies or marks the thread done, not
  /// when their eyes pass over it.
  Future<List<({String source, String sourceMessageId, String receivedAt})>>
      sweepSettledProgress({required double threshold}) async {
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET
  settle_at = CASE WHEN settle_state = 'done' THEN settle_at ELSE ?1 END,
  outcome = CASE WHEN dropped = 1 THEN 'dropped' ELSE 'done' END,
  needs_you =
    CASE WHEN settle_state = 'done' THEN needs_you
         ELSE COALESCE((
           SELECT ${needsYouSql(threshold: '?2')}
             FROM messages m
            WHERE m.source = message_progress.source
              AND m.source_message_id = message_progress.source_message_id
         ), 0) END,
  updated_at = ?1,
  -- Position is cosmetic: sqlite evaluates EVERY SET expression against the
  -- row as it was before the update, so the clauses above that ask whether
  -- the coordinator got here first read the old settle_state wherever this
  -- line sits. Stated so nobody reorders defensively.
  settle_state = 'done'
WHERE (settle_state <> 'done' OR outcome = 'pending')
  AND triage_state IN $_terminalStates
  AND extract_state IN $_terminalStates
  AND storyline_state IN $_terminalStates
  AND draft_state IN $_terminalStates
  AND EXISTS (
    SELECT 1 FROM conversation_ai ai
     WHERE ai.source = message_progress.source
       AND ai.conversation_key = message_progress.conversation_key
       AND ai.attention_score IS NOT NULL
  )
RETURNING source, source_message_id, received_at
''',
      variables: _args([_nowIso(), threshold]),
    );
    return [
      for (final row in rows)
        (
          source: row.data['source'] as String? ?? '',
          sourceMessageId: row.data['source_message_id'] as String? ?? '',
          receivedAt: row.data['received_at'] as String? ?? '',
        ),
    ];
  }

  /// Takes the Needs You chip off every message of one thread, and returns the
  /// ones it took it off.
  ///
  /// Thread-scoped because the exits are: a reply answers the whole
  /// conversation, and so does marking it done. Guarded on `needs_you = 1` so
  /// the RETURNING carries only rows that actually changed — the caller ticks
  /// the bus per row, and a thread of forty read messages must not produce
  /// forty ticks saying nothing happened.
  Future<List<({String sourceMessageId, String receivedAt})>> clearNeedsYou(
    String source,
    String conversationKey,
  ) async {
    final rows = await db.customWriteReturning(
      'UPDATE message_progress SET needs_you = 0, updated_at = ? '
      'WHERE source = ? AND conversation_key = ? AND needs_you = 1 '
      'RETURNING source_message_id, received_at',
      variables: _args([_nowIso(), source, conversationKey]),
    );
    return [
      for (final row in rows)
        (
          sourceMessageId: row.data['source_message_id'] as String? ?? '',
          receivedAt: row.data['received_at'] as String? ?? '',
        ),
    ];
  }

  /// The home screen's tiles, over everything received since [sinceIso].
  ///
  /// ONE statement, which is the whole point: read separately, a message
  /// settling between two queries would land in one number and not the other,
  /// and the tiles would disagree until something reloaded them.
  Future<HomeMetrics> homeMetrics({required String sinceIso}) async {
    final row = await db
        .customSelect(
          '''
SELECT
  COALESCE(SUM(CASE WHEN source = 'email' THEN 1 ELSE 0 END), 0) AS emails,
  COALESCE(SUM(CASE WHEN source = 'teams' THEN 1 ELSE 0 END), 0) AS teams,
  COALESCE(SUM(CASE WHEN urgency IN ('urgent', 'high') THEN 1 ELSE 0 END), 0)
    AS urgent,
  COALESCE(SUM(dropped), 0) AS dropped,
  COALESCE(SUM(needs_you), 0) AS needs_you,
  COALESCE(SUM(CASE WHEN storyline_id IS NOT NULL THEN 1 ELSE 0 END), 0)
    AS storylined,
  COALESCE(SUM(CASE WHEN outcome = 'pending' THEN 1 ELSE 0 END), 0)
    AS in_flight,
  COALESCE(SUM(CASE WHEN triage_state = 'error' OR extract_state = 'error'
                      OR storyline_state = 'error' THEN 1 ELSE 0 END), 0)
    AS errored,
  COUNT(*) AS total
FROM message_progress
WHERE received_at >= ?
''',
          variables: _args([sinceIso]),
        )
        .getSingle();
    return HomeMetrics.fromRow(row.data);
  }

  /// One page of the feed, newest first.
  ///
  /// Keyset rather than OFFSET, and two literal statements rather than one
  /// with a `? IS NULL OR` cursor: that form defeats the index range scan, and
  /// on a screen someone leaves open all day the difference is the whole
  /// table. The cursor is the previous page's last row — pass both halves or
  /// neither.
  ///
  /// [includeDropped] chooses which index the read walks:
  /// `ix_message_progress_visible` leads with `dropped`, so hiding dropped
  /// rows is an equality seek rather than a filter over everything.
  Future<List<HomeFeedRow>> pageHomeFeed({
    String? beforeReceivedAt,
    String? beforeSourceMessageId,
    int limit = 50,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const [];
    final places = _placeholders(sources.length);
    final visible = includeDropped ? '' : 'p.dropped = 0 AND ';
    final first = beforeReceivedAt == null || beforeSourceMessageId == null;

    final result = first
        ? await db
            .customSelect(
              '$_homeFeedSelect '
              'WHERE ${visible}p.source IN ($places) '
              'ORDER BY p.received_at DESC, p.source_message_id DESC '
              'LIMIT ?',
              variables: _args([...sources, limit]),
            )
            .get()
        : await db
            .customSelect(
              // The row-value compare is the cursor. sqlite has had it since
              // 3.15 (this app ships its own, and `db_adoption_test` pins
              // 3.35 for RETURNING); the portable spelling is
              //   p.received_at < ?a
              //   OR (p.received_at = ?a AND p.source_message_id < ?b)
              // which sqlite would not turn into one index range scan.
              '$_homeFeedSelect '
              'WHERE ${visible}p.source IN ($places) '
              'AND (p.received_at, p.source_message_id) < (?, ?) '
              'ORDER BY p.received_at DESC, p.source_message_id DESC '
              'LIMIT ?',
              variables: _args([
                ...sources,
                beforeReceivedAt,
                beforeSourceMessageId,
                limit,
              ]),
            )
            .get();
    return [for (final row in result) HomeFeedRow.fromRow(row.data)];
  }

  /// The rows behind a burst of live ticks, in one read per chunk.
  ///
  /// The bus carries keys rather than rows, so this is what turns a debounced
  /// burst into the patch the table applies. Chunked because a burst is
  /// unbounded and sqlite's parameter limit is not; 200 pairs is 400
  /// parameters, comfortably under the 999 an older build could be compiled
  /// with.
  Future<List<HomeFeedRow>> progressRowsFor(
    List<({String source, String id})> keys,
  ) async {
    if (keys.isEmpty) return const [];
    const chunkSize = 200;
    final rows = <HomeFeedRow>[];
    for (var start = 0; start < keys.length; start += chunkSize) {
      final chunk = keys.skip(start).take(chunkSize).toList();
      final tuples = List.filled(chunk.length, '(?, ?)').join(', ');
      final result = await db
          .customSelect(
            '$_homeFeedSelect '
            'WHERE (p.source, p.source_message_id) IN (VALUES $tuples)',
            variables: _args([
              for (final key in chunk) ...[key.source, key.id],
            ]),
          )
          .get();
      rows.addAll([for (final row in result) HomeFeedRow.fromRow(row.data)]);
    }
    return rows;
  }

  // ── message vectors & semantic search ────────────────────────────────

  /// Stores one message's embedding, replacing whatever was there.
  ///
  /// Both arms of the conflict clear `indexed_at`, and that is the whole point
  /// of writing it this way: `indexed_at IS NULL` IS the vec-index backfill's
  /// worklist, so a re-embedded message re-enters it automatically. A row that
  /// kept its old stamp would keep its old floats in the index forever while
  /// the durable table said otherwise, and search would answer from a vector
  /// nothing else in the app believes in.
  ///
  /// [dims] is stored truthfully — `vector.length`, never the constant — so a
  /// blob of the wrong width is a row the index can see and skip rather than a
  /// blob it feeds to vec0 and has refused.
  Future<int> upsertMessageVector({
    required String source,
    required String sourceMessageId,
    required Uint8List embedding,
    required int dims,
    required String embeddedHash,
    required String embedModel,
    String? receivedAt,
  }) async {
    final rows = await db.customWriteReturning(
      '''
INSERT INTO message_vectors (
  source, source_message_id, embedding, dims, embedded_hash, embed_model,
  received_at, embedded_at, indexed_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(source, source_message_id) DO UPDATE SET
  embedding = excluded.embedding,
  dims = excluded.dims,
  embedded_hash = excluded.embedded_hash,
  embed_model = excluded.embed_model,
  received_at = excluded.received_at,
  embedded_at = excluded.embedded_at,
  indexed_at = NULL
RETURNING id
''',
      variables: _args([
        source,
        sourceMessageId,
        embedding,
        dims,
        embeddedHash,
        embedModel,
        receivedAt,
        _nowIso(),
      ]),
    );
    return rows.first.data['id'] as int;
  }

  /// What a message was last embedded FROM, or null if it never was.
  ///
  /// The hash guard's read, and it returns the model tag beside the hash on
  /// purpose: a matching hash under an old tag is not a reason to skip the
  /// work, it is a reason to redo it.
  Future<Map<String, Object?>?> messageVectorMeta(
    String source,
    String sourceMessageId,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT embedded_hash, embed_model FROM message_vectors '
          'WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(rows.first.data);
  }

  /// Files every durable vector the nearest-neighbour index has not seen yet,
  /// and returns how many it attempted.
  ///
  /// Fail-soft by construction: 0 when the native index is unavailable, and no
  /// throw either way. The vector writers call it straight after landing a
  /// vector, which is what keeps search warm without anything in the app
  /// having to schedule an index pass — the index is derived, so the cheapest
  /// correct policy is to refill it the moment its source grows.
  Future<int> indexPendingVectors() => _vecIndex.backfill();

  /// Queues per-message embedding for the newest [cap] inbound messages
  /// received since [sinceIso], and returns how many rows that added.
  ///
  /// [enqueueExtractBacklog]'s twin, and idempotent for the same reason: `OR
  /// IGNORE` against the work table's primary key means finished work stays
  /// finished and in-flight work is not re-queued, so running it after every
  /// sync both picks up new mail and self-heals a queue a crash left short.
  ///
  /// The triage filter is fixed here rather than passed in, because unlike
  /// extraction there is no caller who wants it any other way. Gated mail is
  /// left out on the same reasoning that keeps it out of extraction, plus one
  /// of its own: junk is not worth a vector, and one sender's newsletters are
  /// so alike that they would fill every search's neighbourhood with the same
  /// twenty rows.
  ///
  /// Rows carry the MESSAGE's `received_at` as their `created_at`, so the
  /// worker's `created_at DESC` drain gives newest mail its vector first.
  Future<int> enqueueEmbedBacklog({
    int cap = 150,
    required String sinceIso,
    String source = 'email',
  }) async {
    final now = _nowIso();
    return db.customUpdate(
      '''
INSERT OR IGNORE INTO work_items (
  task_kind, source, entity_id, status, attempts, error, payload_json,
  created_at, updated_at
)
SELECT 'embed_message', source, source_message_id, 'pending', 0, NULL, NULL,
  COALESCE(received_at, ?), ?
FROM messages
WHERE source = ? AND direction = 'inbound'
  AND triage_status IN ('pending', 'processing', 'triaged')
  AND received_at >= ?
ORDER BY received_at DESC
LIMIT ?
''',
      variables: _args([now, now, source, sinceIso, cap]),
    );
  }

  /// The feed rows nearest [queryEmbedding], closest first.
  ///
  /// Returns NULL when the index is unavailable, and that is a third answer
  /// rather than an empty list on purpose: `const []` cannot tell "nothing in
  /// this mailbox matches" from "the native index is not loaded on this
  /// build", and the screen says something quite different for each — one is a
  /// result, the other is a feature being off.
  ///
  /// The pipeline is KNN first, filters second, because vec0 can only be asked
  /// for neighbours and not for neighbours-matching-a-predicate. So it
  /// over-fetches and lets the dropped, date, source and model filters run in
  /// SQL afterwards; [limit] is honoured on what survives.
  ///
  /// [embedModel] is required rather than defaulted, on
  /// [conversationsWithEmbeddings]' precedent and for its reason: two vectors
  /// are only comparable under one tag, the caller passes
  /// `EmbeddingsClient.documentModelTag`, and this layer imports nothing
  /// above itself.
  Future<List<SemanticHit>?> semanticSearch(
    Uint8List queryEmbedding, {
    required String embedModel,
    int limit = 50,
    bool includeDropped = false,
    String? sinceIso,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (!await _vecIndex.ensureReady()) return null;
    if (sources.isEmpty) return const [];

    // Heal before asking: a durable vector whose index write never landed — a
    // width-change rebuild emptied the index, or the extension was missing
    // for a moment — would otherwise stay unfindable until some unrelated
    // embed happened to run. On the ordinary search this is one indexed read
    // of an empty worklist.
    await _vecIndex.backfill();

    // Four times the ask, capped. The slack is what stops a filter from
    // emptying the page — a window where half the hits are dropped rows still
    // fills a screen — and the cap is what keeps the hydration query's
    // parameter count (400 ids plus a handful) well under the 999 an older
    // sqlite build could be compiled with.
    final k = math.min(limit * 4, 400);
    final hits = await _vecIndex.knn(queryEmbedding, k: k);
    if (hits.isEmpty) return const [];

    final ids = [for (final hit in hits) hit.id];
    final where = StringBuffer(
      'WHERE v.id IN (${_placeholders(ids.length)}) AND v.embed_model = ?',
    );
    final args = <Object?>[...ids, embedModel];
    if (!includeDropped) where.write(' AND p.dropped = 0');
    if (sinceIso != null) {
      where.write(' AND p.received_at >= ?');
      args.add(sinceIso);
    }
    where.write(' AND p.source IN (${_placeholders(sources.length)})');
    args.addAll(sources);

    final result = await db
        .customSelect(
          '''
SELECT v.id AS vector_id, $_homeFeedColumns
FROM message_vectors v
JOIN message_progress p
  ON p.source = v.source AND p.source_message_id = v.source_message_id
JOIN messages m
  ON m.source = p.source AND m.source_message_id = p.source_message_id
LEFT JOIN storylines s ON s.id = p.storyline_id
$where
''',
          variables: _args(args),
        )
        .get();

    // The model-tag filter above is the one that cannot be dropped for
    // tidiness: conversation vectors and vectors from an older prefix sit in
    // the same table, and a distance measured against one of those is not a
    // worse answer, it is a number with no meaning — which would still sort.
    final byVector = <int, HomeFeedRow>{
      for (final row in result)
        row.data['vector_id'] as int: HomeFeedRow.fromRow(row.data),
    };

    // Back into the index's order. SQL returned a set; the ranking lives in
    // [hits] and nowhere else.
    final ranked = <SemanticHit>[];
    for (final hit in hits) {
      final row = byVector[hit.id];
      if (row == null) continue;
      ranked.add(SemanticHit(row, hit.distance));
      if (ranked.length == limit) break;
    }
    return ranked;
  }

  /// The storylines the window was busiest with, most messages first.
  ///
  /// Counts messages that landed IN THE WINDOW rather than the storylines'
  /// lifetime sizes — "hot right now" is a statement about today, and a
  /// storyline that has been large since March is not news.
  ///
  /// Dropped rows are left out: they are hidden from the feed by default, and
  /// a strip that ranked a storyline on messages the user cannot see would
  /// send them looking for rows that are not there.
  Future<List<HotStoryline>> hotStorylines({
    required String sinceIso,
    int limit = 8,
  }) async {
    final result = await db
        .customSelect(
          '''
SELECT p.storyline_id AS id, s.title AS title,
  COUNT(*) AS message_count, MAX(p.received_at) AS last_at
FROM message_progress p
JOIN storylines s ON s.id = p.storyline_id
WHERE p.storyline_id IS NOT NULL AND p.dropped = 0 AND p.received_at >= ?
  AND s.status IN ('suggested', 'active')
GROUP BY p.storyline_id, s.title
ORDER BY message_count DESC, last_at DESC, id ASC
LIMIT ?
''',
          variables: _args([sinceIso, limit]),
        )
        .get();
    return [for (final row in result) HotStoryline.fromRow(row.data)];
  }
}
