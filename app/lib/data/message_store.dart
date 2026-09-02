import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import 'database.dart' show BondDatabase;

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
  Future<void> upsertMessage(Map<String, Object?> row) async {
    final now = _nowIso();
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
        row['addressed_me'] ?? 0,
        row['created_at'] ?? now,
        row['updated_at'] ?? now,
      ]),
    );
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
  Future<List<Message>> loadThread(
    String conversationKey, {
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          'WHERE conversation_key = ? AND source IN (${_placeholders(sources.length)}) '
          // The tie-break matters now that one thread can hold two sources: two
          // messages sharing a second must render in ONE order, not whichever the
          // query plan felt like — same rule as storylineTimeline.
          'ORDER BY received_at ASC, source_message_id ASC',
          variables: _args([conversationKey, ...sources]),
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
          "     AND m.direction = 'inbound' AND m.is_read = 0) AS unread_count "
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
      variables: _args([
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
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT INTO storylines '
      '(id, title, summary, charter, status, created_by, title_locked, '
      'charter_locked, pinned, member_hash, last_activity_at, created_at, '
      'updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, ?, NULL, ?, ?)',
      variables: _args(
        [id, title, summary, charter, status, createdBy, memberHash, now, now],
      ),
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
  /// [dismissedMemberHashExists], and a thread is not "in" a suggestion the
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
  Future<bool> dismissedMemberHashExists(String memberHash) async {
    final result = await db
        .customSelect(
          "SELECT 1 FROM storylines WHERE status = 'dismissed' "
          'AND member_hash = ? LIMIT 1',
          variables: _args([memberHash]),
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

  /// Writes the one draft a conversation is allowed, replacing whatever was
  /// there.
  ///
  /// A full replace rather than a merge because that is what regenerating
  /// means: the new draft answers a possibly different message, and keeping
  /// the old `graph_draft_id` would leave the Send button pointing at an
  /// Outlook draft holding text nobody can see any more. `created_at` survives
  /// — it says when this conversation first got a suggestion, which is the one
  /// fact a regenerate does not change.
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
ON CONFLICT(source, conversation_key) DO UPDATE SET
  reply_to_message_id = excluded.reply_to_message_id,
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
  /// same reason `status = 'dismissed'` keeps it — so the auto-enqueue does not
  /// immediately write the identical options back.
  Future<void> dismissDraftOptions(
    String source,
    String conversationKey,
  ) async {
    await db.customUpdate(
      'UPDATE drafts SET options_dismissed = 1, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      variables: _args([_nowIso(), source, conversationKey]),
    );
  }

  Future<Map<String, Object?>?> getDraft(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM drafts WHERE source = ? AND conversation_key = ?',
          variables: _args([source, conversationKey]),
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
  Future<void> updateDraftStatus(
    String source,
    String conversationKey, {
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

    args.addAll([source, conversationKey]);
    await db.customUpdate(
      'UPDATE drafts SET ${sets.join(', ')} '
      'WHERE source = ? AND conversation_key = ?',
      variables: _args(args),
    );
  }

  Future<void> deleteDraft(String source, String conversationKey) async {
    await db.customUpdate(
      'DELETE FROM drafts WHERE source = ? AND conversation_key = ?',
      variables: _args([source, conversationKey]),
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

  /// The threads worth spending a model call drafting a reply for.
  ///
  /// Four filters, and each one is there to stop a specific waste: the thread
  /// must actually be waiting on the user, it must not be filed away in Later, it
  /// must have scored high enough to be worth answering, and it must not have a
  /// draft already. That last one is what makes this safe to call on every list
  /// load — a thread drops out of the list the moment it has a suggestion, so
  /// the queue fills once rather than on every pass.
  ///
  /// A thread with no attention score at all is excluded: `NULL >= ?` is NULL,
  /// which is not true. That is the wanted behaviour — a thread the scorer has
  /// never reached has not earned a model call yet.
  ///
  /// ONE list across every source, ranked purely by score. A chat and a mail
  /// compete for the same seven slots on equal terms — there is no per-source
  /// quota, because "which thread most deserves a suggestion" is a question
  /// about the thread, not about the connector it arrived through. Each row
  /// carries its own source, since that is what the work item is written
  /// against.
  Future<List<({String source, String conversationKey})>> needsDraftKeys({
    required double threshold,
    int limit = 7,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT c.source AS source, '
          'c.conversation_key AS conversation_key FROM conversations c '
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
          variables: _args([...sources, threshold, limit]),
        )
        .get();
    return [
      for (final row in result)
        (
          source: row.data['source'] as String? ?? '',
          conversationKey: row.data['conversation_key'] as String? ?? '',
        ),
    ];
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
}
