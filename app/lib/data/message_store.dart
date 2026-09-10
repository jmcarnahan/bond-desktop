import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../models/attachment_models.dart';
import '../models/drafts_models.dart';
import '../models/files_models.dart';
import '../models/home_models.dart';
import '../models/home_sort.dart';
import '../models/message_models.dart';
import '../models/person.dart';
import '../models/storyline_models.dart';
// The second thing this layer reads out of `services/`, on the same licence as
// `conversation_state.dart` below: `chat_roster.dart` is arithmetic over rows
// with no I/O and no imports above `models/`. [recentPeople] needs the query
// match, and a second copy of it here would be the compose field and the
// recipients list disagreeing about who a typed word names.
import '../services/chat_roster.dart';
// The one thing this layer reads out of `services/`, and it is not a service:
// `conversation_state.dart` is the fold's arithmetic with no I/O in it and no
// imports of its own. [foldOutboundSend] needs the fold rules, and a second
// copy of the "an outbound may go quiet, but never off `done`" asymmetry is
// exactly how a send would start disagreeing with the sync about a thread.
import '../services/conversation_state.dart';
// The third read out of `services/`, on the same licence as the two above:
// `extract_task.dart` imports `models/` and nothing else, and [extractionFor]
// needs `ExtractionResult.fromJson` to be the same decoder the handler wrote
// through — a second copy of it here is how a stored blob and its reader come
// to disagree about a field name.
import '../services/llm/extract_task.dart' show ExtractionResult;
// The third, on the same licence as the two above: `search_fusion.dart` is
// arithmetic and string work over the models with no I/O. The keyword reads
// need the query BUILT — quoted, stopworded, capped — and a second copy of
// that here would be the coverage count and the search itself disagreeing
// about what a term is.
import '../services/search_fusion.dart';
// The fourth, on the same licence: `mail_text.dart` is one regular expression
// over a string. The one-off below has to strip a stored body exactly the way
// the ingest strips a fresh one, and a second spelling of the pattern here is
// how the two would come to disagree about what the tip looks like.
import '../services/mail_text.dart';
import 'attachment_chunk_index.dart';
import 'conversation_vec_index.dart';
import 'database.dart' show BondDatabase;
import 'keyword_index.dart';
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

/// The owner's own criteria for the needs-you judgement, added to the rules
/// the prompt already carries. One person's text like [aboutMeKey], and
/// cleared by [wipeAll] for the same reason: inherited by the next identity it
/// would decide what THEIR inbox interrupts them about. Declared here beside
/// [aboutMeKey] because the wipe is what has to name it, and re-exported by
/// `prefs_provider.dart` for everything that reads or writes the setting.
const String needsYouRulesKey = 'needs_you_rules';

/// The oldest floor a bootstrap ever deliberately drained this source back to,
/// one key per connector, ISO-8601 UTC.
///
/// Monotone: it only ever moves OLDER. That is what makes a widened lookback
/// detectable at all — a configured floor older than the marker is history
/// nobody has fetched yet, and the sync answers by re-draining from it; a
/// narrower one is a preference about how much to keep, and changes nothing
/// that already happened.
///
/// Declared here beside [aboutMeKey] because [wipeAll] is what has to name
/// them, and that is not incidental: a marker that survived a sign-out would
/// make the next account's very first bootstrap look like a floor no older
/// than one already drained, and its legitimate first drain would be read as
/// "no widen needed" and suppressed. Written and read only by the sync
/// services; `prefs_provider.dart` never learns them, because this is
/// bookkeeping about a drain rather than anything a user chose.
const String mailBootstrapFloorKey = 'mail_bootstrap_floor';
const String teamsBootstrapFloorKey = 'teams_bootstrap_floor';

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

  /// [keywordSearch] is the seam for "the word index is not available on this
  /// build" — the one state a test cannot reach any other way, because FTS5 is
  /// compiled into every SQLite this suite can open. Off, the two keyword
  /// reads answer null and a search narrows to meaning alone, which is exactly
  /// what a SQLite without FTS5 would produce.
  /// The field it sets is private and the parameter is not, so an
  /// initializing formal cannot spell both.
  MessageStore(this.db, {bool keywordSearch = true})
      // ignore: prefer_initializing_formals
      : _keywordSearch = keywordSearch;

  final bool _keywordSearch;

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

  /// The nearest-neighbour index over the clustering corpus, owned here for
  /// [_vecIndex]'s reasons and held separately because it is a different
  /// corpus answering a different question — the sweep's "which threads are
  /// near this one", not search's "which messages are near this query".
  late final ConversationVectorIndex _conversationIndex =
      ConversationVectorIndex(db);

  /// The nearest-neighbour index over document passages, owned here on the
  /// same terms as the two above. A third corpus because it answers a third
  /// question — "which passage of which attached file says this" — and mixing
  /// a fifty-chunk contract into either of the others would crowd out the
  /// messages they exist to rank.
  late final AttachmentChunkIndex _chunkIndex = AttachmentChunkIndex(db);

  /// The word index over `messages`, owned here for [_vecIndex]'s reasons
  /// exactly: it is derived from this connection's rows and its readiness is
  /// memoized per connection.
  late final MessageKeywordIndex _keywordIndex =
      _keywordSearch ? MessageKeywordIndex(db) : MessageKeywordIndex.disabled();

  /// The word index over `attachment_chunks`, the second corpus a search asks
  /// about and therefore a second table, on [_chunkIndex]'s argument.
  late final ChunkKeywordIndex _chunkKeywordIndex =
      _keywordSearch ? ChunkKeywordIndex(db) : ChunkKeywordIndex.disabled();

  static String _nowIso() => isoStamp(DateTime.now());

  /// Every timestamp this store writes, and the one shape they all have:
  /// UTC, `Z`-suffixed, and exactly SIX fractional digits.
  ///
  /// The store and the notification coordinator compare these stamps as
  /// strings — `ai_updated_at` against `message_updated_at`, a deadline
  /// against now, `ORDER BY updated_at` — on the promise that ISO-8601 UTC
  /// sorts lexicographically. It does, at one precision. `toIso8601String`
  /// prints three fractional digits when the microsecond part happens to be
  /// zero and six otherwise, so two stamps a few hundred microseconds apart
  /// can come out as `…01.123Z` and `…01.123456Z` — and `Z` sorts after `4`,
  /// which puts the EARLIER stamp later. That is a settle that never
  /// completes, one time in a thousand, with no error anywhere.
  ///
  /// Six digits rather than three, because the precision is real and the
  /// stage depends on it: two writes in the same millisecond — a score and
  /// then the message it scores, two rows notified back to back — must still
  /// say which came second. Rounding them into a tie would settle the first
  /// and reorder the second.
  static String isoStamp(DateTime t) {
    final iso = t.toUtc().toIso8601String();
    // 'yyyy-MM-ddTHH:mm:ss.mmmZ' is 24 characters; pad the microseconds Dart
    // left off because they were zero. Anything else is already full width.
    return iso.length == 24 ? '${iso.substring(0, 23)}000Z' : iso;
  }

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
  ///
  /// `row['updated_at']` must never be a PAST value. It is the escape hatch on
  /// a column the word index treats as a watermark, and a row filed under a
  /// stamp it then backdates is text `MessageKeywordIndex.backfill` would go on
  /// serving stale forever. Every caller today omits it and takes the `now`
  /// below, which is the shape to keep.
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

  /// Writes a `local:` echo of a message this app just sent, unless the real
  /// copy has already landed. True when the row was written.
  ///
  /// The check is the whole method. The mail poll has no re-entrancy guard and
  /// the Sent Items copy can turn up on the very first poll after a send, so a
  /// sync already in flight can ingest the real row BEFORE this call runs.
  /// [deleteLocalEcho] would then have nothing to remove, and the echo written
  /// after it would sit in the thread forever as a duplicate that nothing is
  /// ever going to reconcile. One transaction, so the check and the write
  /// cannot straddle that ingest.
  ///
  /// A row with no `internet_message_id` skips the check: there is nothing to
  /// match the real copy on, so there is nothing to be second to either.
  Future<bool> insertLocalEcho(Map<String, Object?> row) async {
    final source = row['source'] ?? 'email';
    final internetMessageId = row['internet_message_id'];
    return db.transaction(() async {
      if (internetMessageId != null) {
        final landed = await db
            .customSelect(
              'SELECT 1 FROM messages '
              'WHERE source = ? AND internet_message_id = ? '
              "AND source_message_id NOT LIKE '$localEchoPrefix%' LIMIT 1",
              variables: _args([source, internetMessageId]),
            )
            .get();
        if (landed.isNotEmpty) return false;
      }
      await upsertMessage(row);
      return true;
    });
  }

  /// The key just past every `local:` id, so `>= 'local:' AND < 'local;'`
  /// is exactly "starts with `local:`" — and, unlike `LIKE 'local:%'`, a
  /// range the primary key can serve. SQLite will not use a BINARY index for
  /// a case-insensitive LIKE, and the guard below runs once per Sent Items
  /// message on every drain, so as a LIKE it was a scan of the whole source
  /// per message: minutes on a first sync of a mailbox with years of sent
  /// mail behind it.
  static final String _localEchoPrefixEnd = _keyAfterPrefix(localEchoPrefix);

  /// [prefix] with its last character stepped up by one: the smallest key
  /// that no string starting with [prefix] can reach.
  static String _keyAfterPrefix(String prefix) {
    final last = prefix.length - 1;
    return prefix.substring(0, last) +
        String.fromCharCode(prefix.codeUnitAt(last) + 1);
  }

  /// The internet message ids of every `local:` echo [source] is holding —
  /// what the drain asks once per page, so the reconciliation below costs a
  /// page nothing when there is nothing to reconcile, which is every page
  /// but the one right after a send.
  ///
  /// Echoes are always few: one per message sent from this app and not yet
  /// folded, and the next drain takes them. An echo with no internet message
  /// id is not listed, because nothing could ever match it.
  Future<Set<String>> pendingEchoInternetMessageIds(String source) async {
    final rows = await db
        .customSelect(
          'SELECT internet_message_id FROM messages '
          'WHERE source = ? '
          '  AND source_message_id >= ? AND source_message_id < ? '
          '  AND internet_message_id IS NOT NULL',
          variables: _args([source, localEchoPrefix, _localEchoPrefixEnd]),
        )
        .get();
    return {
      for (final row in rows)
        if (row.data['internet_message_id'] case final String id
            when id.isNotEmpty)
          id,
    };
  }

  /// Removes the local echo of the message [internetMessageId] names, and its
  /// progress row with it. Returns how many message rows went.
  ///
  /// **The only DELETE on `messages` in this app**, and it may only ever reach
  /// a `local:` row — hence the key range on both statements rather than on
  /// the first alone (a range rather than a LIKE for the planner's sake; see
  /// [_localEchoPrefixEnd]). Everything else in the pipeline treats a stored
  /// message as permanent, so a widening of this predicate would be a
  /// widening of what the app can destroy.
  ///
  /// Called from inside the Sent Items page transaction, immediately before
  /// the real row is written: the echo and the copy that replaces it are never
  /// both visible to a reader.
  Future<int> deleteLocalEcho(String source, String internetMessageId) async {
    return db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM message_progress '
        'WHERE source = ? AND source_message_id IN ('
        '  SELECT source_message_id FROM messages '
        '  WHERE source = ? '
        '    AND source_message_id >= ? AND source_message_id < ? '
        '    AND internet_message_id = ?'
        ')',
        variables: _args([
          source,
          source,
          localEchoPrefix,
          _localEchoPrefixEnd,
          internetMessageId,
        ]),
      );
      return db.customUpdate(
        'DELETE FROM messages '
        'WHERE source = ? '
        '  AND source_message_id >= ? AND source_message_id < ? '
        '  AND internet_message_id = ?',
        variables: _args([
          source,
          localEchoPrefix,
          _localEchoPrefixEnd,
          internetMessageId,
        ]),
      );
    });
  }

  /// Folds a message this app just sent into its conversation row.
  ///
  /// [recomputeConversationCounts] rewrites counts and nothing else, but the
  /// rail orders threads by `last_message_at` and shows
  /// `last_message_preview` — so a send that only recounted would leave the
  /// thread sitting where it was, previewing the message it just answered.
  /// And it would never heal: the next pull skips a row it has already seen.
  ///
  /// The fold rules are [foldMessage]'s, not this method's. Reimplementing the
  /// "an outbound may go quiet, but never off `done`" asymmetry here is how
  /// the two paths would drift.
  ///
  /// All of it in ONE transaction, because it is a read-modify-write against a
  /// row the sync's own page transaction rewrites — and a send can land in the
  /// middle of a poll. Drift serialises transactions, so wrapping the read is
  /// what stops this method folding onto a snapshot the ingest has already
  /// replaced and writing the ingest's work back out.
  ///
  /// A thread with no stored row is left alone. Composing a new message writes
  /// its own conversation; this is for replying into one that exists.
  Future<void> foldOutboundSend(
    String source,
    String conversationKey, {
    required String? receivedAt,
    String? preview,
    String? subject,
  }) async {
    await db.transaction(() async {
      final row = await getConversationRow(source, conversationKey);
      if (row == null) return;

      final folded = foldMessage(
        ConvSnapshot(
          state: row['state'] as String? ?? stateWaiting,
          lastInboundAt: row['last_inbound_at'] as String?,
          lastOutboundAt: row['last_outbound_at'] as String?,
          lastMessageAt: row['last_message_at'] as String?,
          lastMessagePreview: row['last_message_preview'] as String?,
          subject: row['subject'] as String?,
        ),
        outbound: true,
        receivedAt: receivedAt,
        subject: subject,
        preview: preview,
      );

      await upsertConversation({
        'source': source,
        'conversation_key': conversationKey,
        'subject': folded.subject,
        // Read back and passed through, every one of them: the conflict clause
        // overwrites participants, state, counts and preview unconditionally,
        // so a field this call did not carry would be erased by a send.
        'participants_json': row['participants_json'],
        'state': folded.state,
        'category': row['category'],
        'cta_text': row['cta_text'],
        'cta_urgency': row['cta_urgency'],
        'message_count': row['message_count'],
        'inbound_count': row['inbound_count'],
        'last_inbound_at': folded.lastInboundAt,
        'last_outbound_at': folded.lastOutboundAt,
        'last_message_at': folded.lastMessageAt,
        'last_message_preview': folded.lastMessagePreview,
      });
      await recomputeConversationCounts(source, conversationKey);
    });
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
    final messages = [for (final row in result) Message.fromRow(row.data)];
    if (messages.isEmpty) return messages;

    // ONE query for the whole thread, never one per message. A thread is the
    // only place a message's attachments are rendered, and a hundred-message
    // thread that asked per message would be a hundred round trips to draw a
    // handful of chips.
    //
    // Per source, because the key is (source, message id) and a joined thread
    // legitimately holds both. Two sources on one thread is two queries, which
    // is still not per message.
    for (final source in sources) {
      final ids = [
        for (final message in messages)
          if (message.source == source) message.id,
      ];
      if (ids.isEmpty) continue;
      final rows = await attachmentsForMessages(source, ids);
      if (rows.isEmpty) continue;
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].source != source) continue;
        final own = rows[messages[i].id];
        if (own == null || own.isEmpty) continue;
        messages[i] = messages[i].withAttachments([
          for (final row in own)
            AttachmentRef.fromRow(row, conversationKey: conversationKey),
        ]);
      }
    }
    return messages;
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
  ///
  /// `latest_deadline` and `pending_draft_count` are read-time for the same
  /// reason and answer the two Needs You tabs that cannot be decided from a
  /// thread's own row. Both key off the thread's NEWEST INBOUND message, which
  /// is the message the thread is waiting on: [getDraft] resolves the
  /// composer's suggestion by exactly that subselect, so a thread the drafts
  /// tab claims and a thread whose composer is full are the same set of
  /// threads by construction rather than by coincidence.
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
          '  ai.snoozed_until AS snoozed_until, '
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
          "     AND w.status IN ('pending','processing')) AS ai_busy_thread, "
          // Non-inline only: a paperclip on a list card means "somebody sent
          // something with this", and counting the signature logos on ten
          // replies would put a 12 on a thread carrying no files at all.
          '  (SELECT COUNT(*) FROM attachments a '
          '   JOIN messages m2 ON m2.source = a.source '
          '     AND m2.source_message_id = a.source_message_id '
          '   WHERE a.source = c.source '
          '     AND m2.conversation_key = c.conversation_key '
          '     AND a.is_inline = 0) AS attachment_count, '
          // The newest inbound message's deadline, in the sender's own words.
          // The newest one's and nobody else's: a date somebody named three
          // replies ago is history, and a Deadlines tab that surfaced it would
          // be listing threads whose deadline has already been answered.
          '  (SELECT m4.deadline FROM messages m4 '
          '   WHERE m4.source = c.source AND m4.conversation_key = c.conversation_key '
          "     AND m4.direction = 'inbound' "
          '   ORDER BY m4.received_at DESC, m4.source_message_id DESC LIMIT 1'
          '  ) AS latest_deadline, '
          // How many suggestions are waiting on this thread — and the
          // subselect is the SAME newest-inbound rule [getDraft] uses, on
          // purpose. A pending draft is the one the thread would actually
          // show; a suggestion left against an older message is history, not
          // work, and counting it would put a badge on a thread whose composer
          // is empty.
          '  (SELECT COUNT(*) FROM drafts d '
          '   WHERE d.source = c.source AND d.conversation_key = c.conversation_key '
          "     AND d.status IN ('suggested','edited') "
          '     AND d.reply_to_message_id = ('
          '       SELECT m3.source_message_id FROM messages m3 '
          '        WHERE m3.source = c.source AND m3.conversation_key = c.conversation_key '
          "          AND m3.direction = 'inbound' "
          '        ORDER BY m3.received_at DESC, m3.source_message_id DESC LIMIT 1'
          '     )) AS pending_draft_count '
          'FROM conversations c '
          'LEFT JOIN conversation_ai ai '
          '  ON ai.source = c.source AND ai.conversation_key = c.conversation_key '
          'WHERE $where ORDER BY c.last_message_at DESC',
          variables: _args(args),
        )
        .get();
    return [for (final row in result) Conversation.fromRow(row.data)];
  }

  /// How many rows each half of [recentPeople] reads before merging.
  ///
  /// A bound rather than a page: what the caller wants is the handful of
  /// people it will actually show, and the query cannot know which rows those
  /// are until the two halves are merged and filtered. Four hundred of each is
  /// months of correspondence at any volume a desktop mailbox sees, and both
  /// queries are indexed reads of two columns.
  static const int _recentScanRows = 400;

  /// People the user has corresponded with, most recent first.
  ///
  /// Two sources, because neither is enough on its own: inbound messages know
  /// who WROTE, and conversation rosters know who was on the thread — the
  /// second is the only place a Teams member or a mail recipient the user
  /// never heard back from appears at all. Merged on the lowercased address,
  /// keeping the newest sighting of each, so somebody who wrote yesterday
  /// outranks somebody on a thread from March.
  ///
  /// A `teams:` address becomes a person carrying the GRAPH ID and no mail,
  /// which is what makes them chat-able; one with no display name beside it is
  /// dropped, because an id alone renders as an empty chip and cannot be
  /// searched for by name.
  ///
  /// [source] restricts BOTH halves — `'email'` or `'teams'`; null means both.
  /// The compose screen passes one, because only a Graph id can open a chat
  /// and only an address can be mailed.
  Future<List<Person>> recentPeople({
    String query = '',
    int limit = 8,
    String? source,
  }) async {
    // Address key → the person and when they were last seen. The key is the
    // lowercased address exactly as stored, so a `teams:` id and a mail
    // address can never collide.
    final seen = <String, ({Person person, String at})>{};

    void offer(String? name, String? address, String? at) {
      if (address == null || address.isEmpty) return;
      final stamp = at ?? '';
      final key = address.toLowerCase();
      final existing = seen[key];
      if (existing != null && stamp.compareTo(existing.at) <= 0) return;

      // A newer sighting with no name keeps the name an older one had: the
      // roster stores a mail RECIPIENT as a bare address, so the user's own
      // reply being the newest thing on a thread must not turn "Sarah
      // Whitfield" back into "sarah@x.com".
      final known = name == null || name.isEmpty
          ? existing?.person.displayName
          : name;

      final Person person;
      if (key.startsWith('teams:')) {
        final id = address.substring('teams:'.length);
        // An id with no name is unshowable and unsearchable: there is nothing
        // to render in a chip and nothing for a query to match.
        if (id.isEmpty || known == null || known.isEmpty) return;
        person =
            Person(id: id, displayName: known, source: PersonSource.recent);
      } else {
        person = Person(
          id: 'mail:$key',
          displayName: known == null || known.isEmpty ? address : known,
          mail: address,
          source: PersonSource.recent,
        );
      }
      seen[key] = (person: person, at: stamp);
    }

    // Bare `from_name` beside `MAX(received_at)`: SQLite takes the bare
    // columns from the row the max came from, so the name is the one on the
    // newest message rather than an arbitrary one.
    final senders = await db
        .customSelect(
          'SELECT from_name, from_address, MAX(received_at) AS last_at '
          'FROM messages '
          "WHERE direction = 'inbound' AND from_address IS NOT NULL "
          "  AND from_address <> '' "
          '${source == null ? '' : 'AND source = ? '}'
          'GROUP BY LOWER(from_address) '
          'ORDER BY last_at DESC LIMIT $_recentScanRows',
          variables: _args([?source]),
        )
        .get();
    for (final row in senders) {
      offer(
        row.data['from_name'] as String?,
        row.data['from_address'] as String?,
        row.data['last_at'] as String?,
      );
    }

    final threads = await db
        .customSelect(
          'SELECT participants_json, last_message_at FROM conversations '
          '${source == null ? '' : 'WHERE source = ? '}'
          'ORDER BY last_message_at DESC LIMIT $_recentScanRows',
          variables: _args([?source]),
        )
        .get();
    for (final row in threads) {
      final at = row.data['last_message_at'] as String?;
      for (final entry in _decodeJsonList(row.data['participants_json'])) {
        if (entry is! Map) continue;
        offer(entry['name'] as String?, entry['email'] as String?, at);
      }
    }

    final matched = [
      for (final entry in seen.values)
        if (matchesPersonQuery(entry.person, query)) entry,
    ]..sort((a, b) => b.at.compareTo(a.at));

    return [
      for (final entry in matched.take(limit)) entry.person,
    ];
  }

  /// Teams chats, newest activity first, whose subject or participant names
  /// contain [query]. A blank query lists them all.
  ///
  /// Filtered in Dart rather than in SQL because the names live inside
  /// `participants_json`, and a LIKE against that column would match the
  /// address half of an entry as readily as the name half — searching for
  /// `sam` would turn up every chat with `sam` inside a Graph id.
  ///
  /// A CONTAINS rather than the prefix match [recentPeople] uses: a chat is
  /// recognised by any word of a topic somebody else wrote, not by how it
  /// starts.
  Future<List<Conversation>> teamsChats({String query = ''}) async {
    final chats = await loadConversations(sources: const ['teams']);
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return chats;
    return [
      for (final chat in chats)
        if ((chat.subject ?? '').toLowerCase().contains(needle) ||
            chat.participants.any(
              (p) => (p.name ?? '').toLowerCase().contains(needle),
            ))
          chat,
    ];
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

  /// A message the gate KEPT, for one aliased `messages` table.
  ///
  /// The one spelling of "kept" in this file, spliced by alias, because
  /// several readers ask the same question and three spellings of it are
  /// three ways for the rail, the tile and the thread's own state to
  /// disagree.
  ///
  /// Kept means the gate did not throw the message out. Two subtleties ride
  /// in the clause:
  /// - a chat stored before chats were triaged was born `skipped` under
  ///   `teams_source`, and it is a real message from a real person — the
  ///   `skipped` there records a pipeline that did not exist yet, not a
  ///   judgement about the words.
  /// - a settle-time `not_worthy` drop is NOT a gate. It is a verdict about a
  ///   message the gate kept, and it leaves `triage_status` alone — so such a
  ///   message counts as kept here, which is the point: the pipeline deciding
  ///   a message was not worth a card is not the pipeline deciding it was
  ///   never said.
  static String keptMessageSql(String alias) => "($alias.triage_status "
      "<> 'skipped' OR $alias.gate_reason = 'teams_source')";

  /// Re-derives one thread's state from the messages the gate KEPT, in ONE
  /// direction, and says which state it wrote (null when nothing moved).
  ///
  /// The fold at ingest sets `needs_reply` the moment an inbound lands, and
  /// the gates speak afterwards — at the claim, at an Ignore, at a backlog
  /// demotion. This is how the thread finds out. The rule is the fold's own,
  /// re-read off the table: `needs_reply` iff a kept inbound exists and is
  /// STRICTLY newer than the newest outbound (no outbound at all counts as
  /// newer), else `waiting`. The asymmetry is the fold's — ties settle the
  /// thread, because a reply and the mail it answers sharing a timestamp is a
  /// reply, not an unanswered question.
  ///
  /// Outbound has NO kept clause. An outbound message is born
  /// `skipped`/`outbound` by the gates — triage answers "does this need me?"
  /// and the user's own send never does — so requiring it to be kept would
  /// throw away every reply the thread contains. Whatever the gate stamped
  /// it, an outbound is the owner's own word.
  ///
  /// ONE direction, and [restored] picks which:
  /// - `restored: false` may only lower `needs_reply → waiting`. A gate drop
  ///   can only take an obligation away. Raising here would let a widened
  ///   sync window reopen threads the user closed months ago — exactly what
  ///   the fold's `historical` flag exists to prevent, and the store does not
  ///   remember which rows were historical, so the only way to honour that
  ///   flag is to never raise on this path.
  ///
  ///   That is the whole of what `historical` buys here, and it is worth
  ///   being exact about it: the flag is honoured for RAISING, which this
  ///   path never does. It is NOT consulted when lowering, and must not be. A
  ///   Sent copy a widened window backfilled — an outbound newer than an ask
  ///   the store already held — will settle the thread on the next lowering
  ///   refold, where `foldMessage(historical: true)` refused to touch state
  ///   at ingest. That is correct rather than a leak: the user DID answer
  ///   that ask, the incremental fold could not know it because `historical`
  ///   is coarse (a flag about which SYNC PASS carried the row, not about
  ///   what the row says), and this refold answers from the whole mailbox as
  ///   stored. A backfilled reply is the mailbox's own record of a reply.
  /// - `restored: true` may only raise `waiting → needs_reply`. The owner
  ///   pulling one message back out of the dropped pile is a reason for the
  ///   thread to ask again, and never a reason to quieten it.
  ///
  /// `done` is a human's decision and neither direction moves it.
  ///
  /// A lowering refold that finds NO kept inbound at all also clears the
  /// thread's CTA and its Needs You chips: an ask can only come from a kept
  /// message, and a thread with nothing kept has nothing anybody could be
  /// answering.
  ///
  /// Written through [setConversationState] so `state_changed_at` is stamped
  /// — "waiting since the gate spoke" is a different row from "waiting since
  /// last month", and only that write knows.
  Future<String?> refoldThreadState(
    String source,
    String sourceMessageId, {
    required bool restored,
  }) async {
    return db.transaction(() async {
      final rows = await db
          .customSelect(
            'SELECT conversation_key FROM messages '
            'WHERE source = ? AND source_message_id = ?',
            variables: _args([source, sourceMessageId]),
          )
          .get();
      if (rows.isEmpty) return null;
      final key = rows.first.data['conversation_key'] as String? ?? '';
      if (key.isEmpty) return null;
      return _refoldThreadByKey(source, key, restored: restored);
    });
  }

  /// [refoldThreadState] with the thread already resolved, for the callers
  /// that have a key and no particular message — the backlog demotion, which
  /// moves many messages at once, and the one-shot repair.
  ///
  /// No transaction of its own: every caller opens one around it. The public
  /// entry point above does, the two writers that call this directly are
  /// already inside theirs, and the one-shot repair opens one PER THREAD —
  /// see [refoldAllThreadStates]. It has to be inside one somewhere, because
  /// the read of `state` and the write that answers it are one decision: an
  /// ingest landing between them would be judged by the row this method
  /// already read and then overwritten by the state it computed.
  Future<String?> _refoldThreadByKey(
    String source,
    String key, {
    required bool restored,
  }) async {
    final current = await db
        .customSelect(
          'SELECT state FROM conversations '
          'WHERE source = ? AND conversation_key = ?',
          variables: _args([source, key]),
        )
        .get();
    if (current.isEmpty) return null;
    final state = current.first.data['state'] as String? ?? 'waiting';
    // A human's decision, and nothing in the pipeline outranks it.
    if (state == 'done') return null;

    final marks = await db
        .customSelect(
          'SELECT '
          '  (SELECT MAX(m.received_at) FROM messages m '
          '   WHERE m.source = ? AND m.conversation_key = ? '
          "     AND m.direction = 'inbound' AND ${keptMessageSql('m')}"
          '  ) AS kept_inbound, '
          '  (SELECT MAX(m.received_at) FROM messages m '
          '   WHERE m.source = ? AND m.conversation_key = ? '
          "     AND m.direction = 'outbound'"
          '  ) AS last_outbound',
          variables: _args([source, key, source, key]),
        )
        .getSingle();
    final keptInbound = marks.data['kept_inbound'] as String?;
    final lastOutbound = marks.data['last_outbound'] as String?;

    final computed = keptInbound != null &&
            (lastOutbound == null || keptInbound.compareTo(lastOutbound) > 0)
        ? 'needs_reply'
        : 'waiting';
    if (computed == state) return null;

    if (restored) {
      if (!(state == 'waiting' && computed == 'needs_reply')) return null;
    } else {
      if (!(state == 'needs_reply' && computed == 'waiting')) return null;
      if (keptInbound == null) {
        await db.customUpdate(
          "UPDATE conversations SET cta_text = NULL, cta_urgency = 'normal', "
          'updated_at = ? WHERE source = ? AND conversation_key = ?',
          variables: _args([_nowIso(), source, key]),
        );
        await clearNeedsYou(source, key);
      }
    }

    await setConversationState(
      source,
      key,
      ConversationState.fromWire(computed),
    );
    return computed;
  }

  /// The one-shot repair: every thread still claiming `needs_reply` is
  /// re-derived with the lowering rule, across every connector. Returns how
  /// many actually moved.
  ///
  /// These are the rows written before the fold learned to wait for the gate:
  /// an inbound landed, the thread said `needs_reply`, and the gate that
  /// threw the message out a moment later told nobody. Only `needs_reply`
  /// rows are read because only they can move — the rule here never raises.
  ///
  /// ONE THREAD PER TRANSACTION, never the mailbox. Each refold reads a
  /// thread's state and writes the state that answers it, and a concurrent
  /// ingest landing between those two is exactly the interleaving that would
  /// settle a thread a message just reopened. One transaction around the
  /// whole walk would fix that too and hold a write lock over every thread in
  /// the store while it did — on a first run that is the length of the
  /// repair, with the syncs behind it.
  Future<int> refoldAllThreadStates() async {
    final rows = await db
        .customSelect(
          'SELECT source, conversation_key FROM conversations '
          "WHERE state = 'needs_reply'",
        )
        .get();
    var moved = 0;
    for (final row in rows) {
      final written = await db.transaction(
        () => _refoldThreadByKey(
          row.data['source'] as String? ?? 'email',
          row.data['conversation_key'] as String? ?? '',
          restored: false,
        ),
      );
      if (written != null) moved++;
    }
    return moved;
  }

  /// Which way the thread's last message went, or null when it has none.
  ///
  /// Reopening a done thread has to put it back into a state, and the only
  /// honest answer to which one is who spoke last: their message means the
  /// user owes a reply, the user's own means they are waiting on somebody.
  Future<String?> newestMessageDirection(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT direction FROM messages '
          'WHERE source = ? AND conversation_key = ? '
          'ORDER BY received_at DESC LIMIT 1',
          variables: _args([source, conversationKey]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['direction'] as String?;
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
  /// `ReadAckQueue` is what drains these rows, sending the ack to the connector
  /// and marking the work done; a row that outlives a sign-out is simply
  /// wiped with the mailbox.
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
  /// No sync calls this any more: with the lookback configurable, the window
  /// the user chose is the window the models read, and the enqueue paces the
  /// model work instead of demoting mail out of reach of it. What keeps the
  /// method is the exemption below, which is a rule about restored messages
  /// rather than about first runs. Nothing is deleted either way — a skipped
  /// message still renders, it just never reaches the model.
  ///
  /// A restored message is exempt: the stamp is the user's explicit ask for
  /// this one row, so it is never demoted back to backlog even when it sits
  /// far outside the newest slice — which is exactly where a restore from the
  /// archive usually finds it.
  ///
  /// Returns how many THREADS the demotion then folded back to `waiting`.
  /// Demoting a message is a gate speaking late, so every thread it touched
  /// is re-derived from what is left kept ([refoldThreadState]) — a thread
  /// whose only inbound just left the pipeline is nobody's to answer, and the
  /// whole demotion runs in one transaction so no reader can see the messages
  /// skipped while their threads still ask for a reply.
  Future<int> capPendingTriage(int cap, {String source = 'email'}) {
    return db.transaction(() async {
      final demoted = await db.customWriteReturning(
        '''
UPDATE messages SET triage_status = 'skipped', gate_reason = 'backlog',
  updated_at = ?
WHERE source = ? AND triage_status = 'pending' AND direction = 'inbound'
  AND (gate_override IS NULL OR gate_override <> 'user')
  AND source_message_id NOT IN (
    SELECT source_message_id FROM messages
    WHERE source = ? AND triage_status = 'pending' AND direction = 'inbound'
    ORDER BY received_at DESC LIMIT ?
  )
RETURNING conversation_key
''',
        variables: _args([_nowIso(), source, source, cap]),
      );
      // DISTINCT in Dart rather than in SQL: one demotion legitimately takes
      // several messages off the same thread, and refolding that thread once
      // per message would be the same answer written four times.
      final keys = <String>{
        for (final row in demoted)
          if ((row.data['conversation_key'] as String? ?? '').isNotEmpty)
            row.data['conversation_key'] as String,
      };
      var refolded = 0;
      for (final key in keys) {
        final written =
            await _refoldThreadByKey(source, key, restored: false);
        if (written != null) refolded++;
      }
      return refolded;
    });
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
  ///
  /// The progress rows go back with the messages, in one transaction, because
  /// a re-pended message is about to be triaged again and its row has to read
  /// that way. The gate cascade [writeTriageProgress] wrote — every stage
  /// `skipped`, `settle_state = 'done'`, `outcome = 'dropped'` — would
  /// otherwise stay behind, and the settle machine reads that stale cascade as
  /// a finished pipeline: the message settles again on stages that never ran,
  /// and [reviveOwedStorylineStages] cannot heal it either, since its
  /// `dropped = 0` guard correctly refuses a row that says it was dropped.
  Future<int> rependGatedTriage({
    required String source,
    required String gateReason,
    required String sinceIso,
  }) {
    return db.transaction(() async {
      final rows = await db.customWriteReturning(
        "UPDATE messages SET triage_status = 'pending', gate_reason = NULL, "
        'updated_at = ? '
        "WHERE source = ? AND direction = 'inbound' "
        "AND triage_status = 'skipped' AND gate_reason = ? "
        'AND received_at >= ? '
        'RETURNING source_message_id',
        variables: _args([_nowIso(), source, gateReason, sinceIso]),
      );
      final ids = [
        for (final row in rows) row.data['source_message_id'] as String? ?? '',
      ];
      await _resetProgressRows(source, ids);
      return ids.length;
    });
  }

  /// The owner pulling one message back past the gates.
  ///
  /// The `gate_override` stamp is what separates this from [rependGatedTriage]:
  /// that one clears a reason ONCE, and the next claim is free to re-derive the
  /// same gate and drop the message again. This stamp is durable, and it
  /// outranks every future re-derivation — the triage queue skips both gate
  /// calls for a stamped row and [capPendingTriage] refuses to demote it. It is
  /// the `created_by`/`added_by = 'user'` idea from storylines (see
  /// [stampStorylineId]) applied to the gates.
  ///
  /// Attempts and the last error reset because a restore is a fresh ask, not a
  /// retry: whatever the row spent before the gate took it is not held against
  /// the run the owner just asked for.
  Future<void> restoreMessage(String source, String sourceMessageId) async {
    await db.customUpdate(
      "UPDATE messages SET gate_override = 'user', triage_status = 'pending', "
      'gate_reason = NULL, triage_attempts = 0, triage_error = NULL, '
      'updated_at = ? '
      'WHERE source = ? AND source_message_id = ?',
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
  }

  /// Ignore: the owner throwing one message out by hand.
  ///
  /// The mirror of [restoreMessage] and written so that one is the way back.
  /// What it deliberately does NOT touch is `gate_override`: `triage_status`
  /// is the column every handler actually reads, so a message the owner once
  /// restored and has since changed their mind about stays out, and Restore
  /// still works — it re-stamps the override and re-pends the row.
  ///
  /// One transaction, because a half-ignored message is worse than an
  /// un-ignored one: a row skipped on `messages` while its thread still
  /// carries a Needs You chip would go on interrupting the person who just
  /// dismissed it.
  ///
  /// Queue rows are left exactly where they are. The extract and needs-you
  /// handlers already refuse a `skipped` row whose gate reason is not
  /// `teams_source`, so whatever is queued drains as a skip rather than as
  /// work — and deleting the rows would only lose the record that they ran.
  ///
  /// False when nothing is stored under the keys, having written nothing.
  Future<bool> dropMessage(String source, String sourceMessageId) {
    return db.transaction(() async {
      final rows = await db.customWriteReturning(
        "UPDATE messages SET triage_status = 'skipped', "
        "gate_reason = 'user', triage_error = NULL, updated_at = ? "
        'WHERE source = ? AND source_message_id = ? '
        'RETURNING conversation_key',
        variables: _args([_nowIso(), source, sourceMessageId]),
      );
      if (rows.isEmpty) return false;
      final conversationKey =
          rows.first.data['conversation_key'] as String? ?? '';

      // The same cascade a gate writes, through the same writer: pending
      // stages close as skipped, the row settles dropped under this reason,
      // and a stage that already finished keeps what it did.
      await writeTriageProgress(
        source,
        sourceMessageId,
        state: 'skipped',
        gateReason: 'user',
      );

      // And the notification row settles with it. It is an UPDATE guarded on
      // `state = 'pending'`, so this is a no-op for a message that already
      // settled — but a candidate still open would otherwise be re-decided by
      // the next coordinator sweep, on a row the owner has just thrown out.
      await settleNotify(
        source,
        sourceMessageId,
        state: 'suppressed',
        reason: 'gated',
      );

      // And the thread hears about it. Ignore is the owner working a gate by
      // hand, so it lowers the same way every other gate does: a thread whose
      // only kept inbound just left is nobody's to answer. Inside the
      // transaction, because a message skipped on `messages` while its thread
      // still says `needs_reply` is exactly the disagreement this fixes.
      await refoldThreadState(source, sourceMessageId, restored: false);

      // The chips go and the VERDICT stays. `needs_you` is the snapshot the
      // rails and the digest read; `needs_you_verdict` is what the judge
      // decided about the words, and an Ignore is not the owner saying the
      // judge misread them. The open-ask predicate excludes gated rows on its
      // own, so the thread stops holding an ask on the strength of the write
      // above rather than of a verdict rewritten here.
      await clearNeedsYou(source, conversationKey);

      // `explicit`, because a button is exactly that. Anything that learns
      // from these has to be able to tell it from the implicit signal of a
      // thread merely being opened.
      await recordFeedback(
        scope: 'message',
        scopeKey: '$source/$sourceMessageId',
        direction: 'down',
        origin: 'explicit',
      );
      return true;
    });
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
  ///
  /// A message the owner has IGNORED is out of reach here. The triage queue
  /// claims a row and hands it to the model, and the answer can land a minute
  /// later — after an Ignore pressed in between, which would otherwise be
  /// overwritten by a `triaged` status the owner never asked for. An Ignore is
  /// the owner's own gate and it outranks the model's opinion of the same
  /// message. It is only THIS gate that blocks: [restoreMessage] clears
  /// `gate_reason`, so a restored row is written like any other.
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
      'WHERE source = ? AND source_message_id = ? '
      "AND NOT (triage_status = 'skipped' AND gate_reason = 'user')",
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
  /// A message that already has a work row is excluded by the statement rather
  /// than dropped by the insert, and that is what makes [cap] a pace: it means
  /// "the next [cap] not-yet-queued messages, newest first", so a deep window
  /// drains over successive passes. Counting queued rows against the LIMIT
  /// instead — which is what this did — let the newest [cap] messages hold
  /// every slot forever, and older mail inside the window was never queued at
  /// all. `OR IGNORE` stays as the belt to that suspender: it is what makes a
  /// concurrent second call harmless.
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
  AND NOT EXISTS (SELECT 1 FROM work_items w
    WHERE w.task_kind = ? AND w.source = messages.source
      AND w.entity_id = messages.source_message_id)
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
        kind,
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

  /// [reviveErroredTriage] for ONE message, with no attempts ceiling.
  ///
  /// The ceiling is deliberately absent, and the difference matters: the bulk
  /// revival is the pipeline healing itself and has to stop somewhere, while
  /// this is the owner's own hand on one row — and a row past the ceiling is
  /// precisely the row they are asking about. Attempts are not reset either,
  /// so a message that fails again lands back in `error` honestly rather than
  /// looking untried.
  ///
  /// Returns how many rows moved: zero when the message was never errored,
  /// which is how the caller knows there was nothing to retry here.
  Future<int> reviveTriageFor(String source, String sourceMessageId) {
    return db.customUpdate(
      "UPDATE messages SET triage_status = 'pending', updated_at = ? "
      "WHERE source = ? AND source_message_id = ? AND triage_status = 'error'",
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
  }

  /// One work row's status, or null when the queue has never held it.
  ///
  /// Read before a requeue so a caller can tell what it actually did:
  /// [requeueWork] deliberately leaves a `pending` or `processing` row where
  /// it is, and a retry that named that stage anyway would be claiming credit
  /// for work that was already under way.
  Future<String?> workStatusOf(
    String kind,
    String source,
    String entityId,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT status FROM work_items '
          'WHERE task_kind = ? AND source = ? AND entity_id = ?',
          variables: _args([kind, source, entityId]),
        )
        .get();
    return rows.isEmpty ? null : rows.first.data['status'] as String?;
  }

  /// Every queue row behind one message: its own, its thread's storyline row,
  /// and its attachments'.
  ///
  /// Three shapes of `entity_id` because three grains file here — a message
  /// id, a conversation key (`storyline` is a question about a thread), and
  /// `'<message id>|<attachment id>'` for the attachment work. The LIKE is
  /// escaped, so an id carrying a `%` or a `_` matches its own attachments and
  /// nobody else's.
  ///
  /// Source-filtered, where [activityForEntity] is not: `work_items` keys on
  /// it, and a second connector's message with the same id is a different item
  /// of work rather than the same one seen twice.
  Future<List<Map<String, Object?>>> workItemsFor(
    String source,
    String sourceMessageId,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT task_kind, source, entity_id, status, attempts, error, '
          'created_at, updated_at FROM work_items '
          'WHERE source = ?1 AND (entity_id = ?2 OR entity_id = ?3 '
          "OR entity_id LIKE ?4 ESCAPE '\\') "
          'ORDER BY updated_at DESC, task_kind ASC',
          variables: _args([
            source,
            sourceMessageId,
            conversationKey,
            '${_escapeLike(sourceMessageId)}|%',
          ]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
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
  /// `app_prefs` SURVIVES, with eight exceptions. What this method isolates is
  /// one person's presence: which backend the app talks through, which server
  /// it points at, and where the slider sits are the machine's configuration,
  /// not the previous account's data, and wiping them turned every account
  /// switch into a re-setup. The exceptions are [dbOwnerKey] — the identity
  /// claim on these rows, which must not outlive the rows it describes, or
  /// the next sign-in would read the wiped mailbox as still owned — the two
  /// texts one person wrote about themselves and their inbox ([aboutMeKey],
  /// which would otherwise be inherited by the next identity and steer THEIR
  /// triage, and [needsYouRulesKey], which would decide what interrupts
  /// them) — and the two bootstrap-floor markers, [mailBootstrapFloorKey] and
  /// [teamsBootstrapFloorKey], which describe how far back THIS account's
  /// mail was drained and would otherwise tell the next account's first
  /// bootstrap that its window had already been covered — and the three
  /// one-shot markers, which say a catch-up has already run over rows this
  /// method is deleting: left behind, they would tell the next account's first
  /// sync that its mailbox had been reconciled and its verdicts backfilled
  /// when nothing had read a single row of it. Both callers depend on the
  /// first: sign-out leaves the database unclaimed, and `IdentityGuard`
  /// writes the new owner immediately after.
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
      'attachments',
      'attachment_text',
      'attachment_chunks',
    ];
    await db.transaction(() async {
      for (final table in tables) {
        await db.customUpdate('DELETE FROM $table');
      }
      await db.customUpdate(
        'DELETE FROM app_prefs WHERE key IN (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: _args([
          dbOwnerKey,
          aboutMeKey,
          needsYouRulesKey,
          mailBootstrapFloorKey,
          teamsBootstrapFloorKey,
          // The one-shot markers. Each says "this catch-up has already run
          // over these rows" — and the rows are about to be deleted, so on
          // the next account they would be a claim about a mailbox that was
          // never read. The catch-ups are cheap and self-exhausting; a
          // marker that outlived its data is not.
          'needs_you_flag_backfill',
          'needs_you_model_revive',
          'mail_last_reconcile',
        ]),
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
    // The clustering index, for the same reason and by the same argument. It
    // resets rather than rebuilds because `conversation_ai` has just been
    // emptied, so there is nothing to refill from; the next sweep's diff is
    // what fills it again.
    await _conversationIndex.reset();
    // The chunk index, for [_vecIndex]'s reason exactly: `attachment_chunks`
    // has just been emptied, and the floats vec0 holds in its shadow tables do
    // not go with a DELETE.
    await _chunkIndex.rebuild();
    // The two word indexes, for the same reason once more: an FTS5 table is a
    // virtual table, the DELETEs above do not reach inside one, and the
    // previous mailbox's subject lines would otherwise stay findable in the
    // shadow tables long after the mail they came from was gone.
    await _keywordIndex.rebuild();
    await _chunkKeywordIndex.rebuild();
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

  /// One message by its key, or null when the row is gone.
  ///
  /// [Message.fromRow] alone, with no attachment hydration: the callers are
  /// panels asking about ONE message, and a second query for files nobody
  /// draws is a cost paid on every open.
  Future<Message?> messageById(String source, String sourceMessageId) async {
    final result = await db
        .customSelect(
          'SELECT * FROM messages '
          'WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (result.isEmpty) return null;
    return Message.fromRow(result.first.data);
  }

  /// What the model pulled out of one message, decoded — or null when there is
  /// none stored and when what is stored does not parse.
  ///
  /// The catch is the point. This is read by a panel the user opened, and the
  /// blob is schemaless on purpose: a row written by an older shape of
  /// [ExtractionResult] must cost that panel one absent section, never the
  /// render around it.
  Future<ExtractionResult?> extractionFor(
    String source,
    String sourceMessageId,
  ) async {
    final raw = await getExtraction(source, sourceMessageId);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ExtractionResult.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return null;
    }
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

  /// When a deferred thread should come back, or null to clear the date.
  ///
  /// Insert-then-update like [setConversationBucket] and for its reason: a
  /// thread the embedder has never reached has no `conversation_ai` row, and a
  /// date the user set must not depend on whether some other task got there
  /// first.
  ///
  /// Written by PER-THREAD deferrals only. A sender rule is a standing
  /// instruction with no "when" in it, and giving its threads dates would hand
  /// them back one by one in defiance of the rule that filed them.
  Future<void> setSnoozedUntil(
    String source,
    String conversationKey,
    String? iso,
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
        'UPDATE conversation_ai SET snoozed_until = ?, updated_at = ? '
        'WHERE source = ? AND conversation_key = ?',
        variables: _args([iso, now, source, conversationKey]),
      );
    });
  }

  /// Every deferred thread whose date has arrived, back in the inbox. Returns
  /// how many moved.
  ///
  /// The reason it writes is `'user'` and not a word of its own, deliberately.
  /// `AttentionService._sweepBucket` re-files any thread whose reason is not
  /// `'user'`, so a resurfaced thread carrying anything else would be swept
  /// straight back to Later on the next pass and the date would look ignored.
  /// A date the user set IS the user's instruction, and when it fires the
  /// result is exactly what "keep this thread in my inbox" writes.
  ///
  /// The comparison is lexicographic over the UTC stamps [isoStamp] writes,
  /// which is chronological at that one shape — the same promise every other
  /// timestamp comparison in this store runs on.
  Future<List<({String source, String conversationKey})>> resurfaceDue(
    String nowIso,
  ) async {
    final rows = await db.customWriteReturning(
      'UPDATE conversation_ai '
      "SET bucket = NULL, bucket_reason = 'user', snoozed_until = NULL, "
      '    updated_at = ? '
      // The reason is part of the match: only a deferral the user made for
      // THIS thread has a date that means anything. A sender rule owns its
      // threads until the rule goes, and a row that inherited a stale date
      // from an earlier hand-deferral must not be handed back — and stamped
      // `user`, which the sweep never touches — behind the rule's back.
      "WHERE bucket = 'later' AND bucket_reason = 'user' "
      '  AND snoozed_until IS NOT NULL AND snoozed_until <= ? '
      // The keys and not a count: the caller has to raise the Needs You
      // chips a thread's messages lost while it sat in Later, and it can
      // only do that for the threads that actually moved.
      'RETURNING source, conversation_key',
      variables: _args([_nowIso(), nowIso]),
    );
    return [
      for (final row in rows)
        (
          source: row.data['source'] as String? ?? '',
          conversationKey: row.data['conversation_key'] as String? ?? '',
        ),
    ];
  }

  /// Takes Exchange's first-contact tip off every stored body and preview
  /// that still opens with it, and returns how many rows changed.
  ///
  /// The ingest strips it from new mail; this is the once-over for the rows
  /// that arrived before it did. Candidates are found with a LIKE so the
  /// regular expression runs over the few rows that can match rather than
  /// the whole table, and a row is rewritten only when the strip changed
  /// something. `updated_at` moves with the text — it is the keyword index's
  /// watermark, and a body rewritten under a stale stamp would stay indexed
  /// with the tip in it.
  Future<int> stripSenderIdentificationTips() async {
    final rows = await db
        .customSelect(
          'SELECT source, source_message_id, body_text, body_preview '
          'FROM messages '
          "WHERE body_text LIKE '%often get email from%' "
          "   OR body_preview LIKE '%often get email from%'",
        )
        .get();
    var changed = 0;
    for (final row in rows) {
      final body = row.data['body_text'] as String?;
      final preview = row.data['body_preview'] as String?;
      final newBody = body == null ? null : stripSenderIdentification(body);
      final newPreview =
          preview == null ? null : stripSenderIdentification(preview);
      if (newBody == body && newPreview == preview) continue;
      await db.customUpdate(
        'UPDATE messages SET body_text = ?, body_preview = ?, updated_at = ? '
        'WHERE source = ? AND source_message_id = ?',
        variables: _args([
          newBody,
          newPreview,
          _nowIso(),
          row.data['source'],
          row.data['source_message_id'],
        ]),
      );
      changed++;
    }
    return changed;
  }

  /// Fills the display name on every conversation participant stored with an
  /// address and no name, from the best source the store has: another
  /// participant entry with that address and a name, else the newest
  /// `from_name` on a message from that address. Returns how many
  /// conversations changed. Idempotent — a second run changes nothing.
  ///
  /// The once-over for the rows stored before the ingest carried recipient
  /// names. Every outbound recipient landed as `{name: null, email}`, so an
  /// outbound-only thread shows a bare address wherever `participants_json` is
  /// read — the thread header, the recent-people typeahead, and a colleague's
  /// own room row. The People layer resolves names across the list at read
  /// time, but only for what it was handed; this fixes the stored rows.
  ///
  /// Candidates are found with a LIKE so the rewrite runs over the few rows
  /// that can match rather than the whole table, and a row is written only
  /// when a name was actually filled — [stripSenderIdentificationTips]' shape,
  /// for its reasons.
  Future<int> fillParticipantNames() async {
    // The rows that could change, found first: on a store that never had a
    // nameless participant this returns before either scan below runs.
    final candidates = await db
        .customSelect(
          'SELECT source, conversation_key, participants_json '
          'FROM conversations '
          'WHERE participants_json LIKE \'%"name":null%\' '
          '   OR participants_json LIKE \'%"name":""%\'',
        )
        .get();
    if (candidates.isEmpty) return 0;

    // Built ONCE, over the whole store: a per-row lookup would be two queries
    // per candidate conversation, and the answer is the same every time.
    final names = <String, String>{};
    for (final row in await db
        .customSelect(
          'SELECT participants_json FROM conversations '
          'WHERE participants_json IS NOT NULL',
        )
        .get()) {
      for (final p in _decodeParticipantList(row.data['participants_json'])) {
        final address = (p['email'] as String?)?.trim().toLowerCase() ?? '';
        final name = (p['name'] as String?)?.trim() ?? '';
        if (address.isEmpty || name.isEmpty) continue;
        names.putIfAbsent(address, () => name);
      }
    }
    // One row per address, carrying the name off its NEWEST message — SQLite's
    // bare-column rule under MAX() — so the name somebody signs with today
    // wins over one they used a year ago, and the whole messages table is not
    // pulled into memory to decide it. `putIfAbsent` keeps a participant's
    // own entry over this.
    for (final row in await db
        .customSelect(
          'SELECT from_address, from_name, MAX(received_at) AS at '
          'FROM messages '
          "WHERE from_name IS NOT NULL AND from_name <> '' "
          '  AND from_address IS NOT NULL '
          'GROUP BY lower(from_address)',
        )
        .get()) {
      final address =
          (row.data['from_address'] as String?)?.trim().toLowerCase() ?? '';
      final name = (row.data['from_name'] as String?)?.trim() ?? '';
      if (address.isEmpty || name.isEmpty) continue;
      names.putIfAbsent(address, () => name);
    }
    if (names.isEmpty) return 0;

    var changed = 0;
    for (final row in candidates) {
      final participants =
          _decodeParticipantList(row.data['participants_json']);
      if (participants.isEmpty) continue;
      var filled = false;
      for (final p in participants) {
        final name = (p['name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty) continue;
        final address = (p['email'] as String?)?.trim().toLowerCase() ?? '';
        if (address.isEmpty) continue;
        final known = names[address];
        if (known == null) continue;
        p['name'] = known;
        filled = true;
      }
      if (!filled) continue;
      await db.customUpdate(
        'UPDATE conversations SET participants_json = ?, updated_at = ? '
        'WHERE source = ? AND conversation_key = ?',
        variables: _args([
          jsonEncode(participants),
          _nowIso(),
          row.data['source'],
          row.data['conversation_key'],
        ]),
      );
      changed++;
    }
    return changed;
  }

  /// A `participants_json` blob as mutable `{name, email}` maps. Tolerates
  /// null, empty, malformed JSON and a payload that decodes to a non-list —
  /// the same defensiveness every other reader of this column has, because a
  /// backfill that threw on one bad row would strand every row after it.
  static List<Map<String, Object?>> _decodeParticipantList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map)
            {
              'name': entry['name'] as String?,
              'email': entry['email'] as String?,
            },
      ];
    } on FormatException {
      return const [];
    }
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
  /// `reply_expected`, `deadline`, `addressed_me`, `needs_you_verdict` —
  /// because the scorer reads them about exactly this message, the newest
  /// inbound one.
  Future<Map<String, Map<String, Object?>>> latestInboundMeta({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT conversation_key, source, source_message_id, from_address, '
          '  received_at, extraction_json, needs_action, reply_expected, '
          '  deadline, addressed_me, needs_you_verdict FROM ('
          '  SELECT m.conversation_key AS conversation_key, m.source AS source, '
          '    m.source_message_id AS source_message_id, '
          '    m.from_address AS from_address, m.received_at AS received_at, '
          '    a.extraction_json AS extraction_json, '
          '    m.needs_action AS needs_action, '
          '    m.reply_expected AS reply_expected, '
          '    m.deadline AS deadline, m.addressed_me AS addressed_me, '
          '    m.needs_you_verdict AS needs_you_verdict, '
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

  /// The one spelling of "this thread holds an open ask", shared by
  /// [openAskThreads] and [hasOpenAsk] so a sweep and a single filing can
  /// never answer it differently.
  ///
  /// Thread-level rather than message-level on purpose: the newest message on
  /// a thread can be a quiet FYI while an older one is still an unanswered
  /// question, and the thread is the unit being filed. "Unanswered" is the
  /// thread's last outbound message — anything the owner sent after the ask
  /// closes it, whether or not it was a reply to that particular message.
  ///
  /// `COALESCE(c.last_outbound_at, '')` reads a thread the owner has never
  /// written on as one whose asks are all still open, which is the whole
  /// shape this exists to catch.
  ///
  /// The triage clause is the same admission every other reader of a kept
  /// message uses: a gated row is not an ask, whatever verdict it carries. No
  /// gate writes a verdict today, but a message the owner throws out by hand
  /// keeps the one it had — and a thread must not be held out of Later by a
  /// question its owner has already dismissed. The `teams_source` tolerance
  /// is the usual one for chats stored before chats were triaged.
  ///
  /// Deliberately unbounded in time: an unanswered ask holds its thread out of
  /// automatic Later for as long as it stays unanswered. The exits are a reply,
  /// Done, or the owner's own Later, and nothing else — a question does not
  /// stop being a question because a fortnight went by.
  ///
  /// "Kept" is [keptMessageSql] here, as in every reader that means exactly
  /// that — not a further copy of the predicate a later change could miss.
  /// (Two transcript readers OR the same two terms with an outbound arm; they
  /// ask a different question and keep their own spelling.)
  ///
  /// `final` rather than `const` only because a const cannot call a method.
  static final String _openAskWhere = """
  m.direction = 'inbound'
  AND m.needs_you_verdict = 1
  AND ${keptMessageSql('m')}
  AND m.received_at > COALESCE(c.last_outbound_at, '')""";

  /// Every thread holding an open ask: an inbound message the needs-you stage
  /// judged yes, received after the thread's last outbound message (or with no
  /// outbound at all). Keys are `'$source\n$conversationKey'`.
  ///
  /// The newline separator is spelled here rather than by the caller because
  /// every caller has to build the same key to look one up — a source and a
  /// conversation key, joined by a character neither of them can contain.
  ///
  /// One read for the whole mailbox, because the attention sweep runs on every
  /// list load and a query per thread would be hundreds of round trips per
  /// keystroke.
  Future<Set<String>> openAskThreads({
    List<String> sources = const ['email'],
  }) async {
    if (sources.isEmpty) return const {};
    final result = await db
        .customSelect(
          'SELECT DISTINCT m.source AS source, '
          '  m.conversation_key AS conversation_key '
          'FROM messages m '
          'LEFT JOIN conversations c '
          '  ON c.source = m.source AND c.conversation_key = m.conversation_key '
          'WHERE $_openAskWhere '
          '  AND m.source IN (${_placeholders(sources.length)})',
          variables: _args([...sources]),
        )
        .get();
    return {
      for (final row in result)
        openAskKey(
          row.data['source'] as String? ?? '',
          row.data['conversation_key'] as String? ?? '',
        ),
    };
  }

  /// The key [openAskThreads] returns, for a caller holding a thread.
  static String openAskKey(String source, String conversationKey) =>
      '$source\n$conversationKey';

  /// Whether one thread holds an open ask — see [openAskThreads].
  ///
  /// The single-thread path, for the extraction handler, which is filing one
  /// thread and has no use for the whole mailbox's set.
  Future<bool> hasOpenAsk(String source, String conversationKey) async {
    final result = await db
        .customSelect(
          'SELECT 1 FROM messages m '
          'LEFT JOIN conversations c '
          '  ON c.source = m.source AND c.conversation_key = m.conversation_key '
          'WHERE $_openAskWhere '
          '  AND m.source = ? AND m.conversation_key = ? '
          'LIMIT 1',
          variables: _args([source, conversationKey]),
        )
        .get();
    return result.isNotEmpty;
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
      // The date goes too, in both directions: a sender rule has no "when",
      // and a thread it releases has no deferral left for a date to belong to.
      // Left standing, a stale date would draw a `Back <when>` the rule would
      // never honour.
      return db.customUpdate(
        'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, '
        '  snoozed_until = NULL, updated_at = ? '
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
    // The digest, and not `attachment_text`: this list is the model-call kinds
    // the header's median is about, and text extraction is a fetch and an
    // embed, the same shape as `embed_message`, which is already left out.
    'attachment_digest',
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

  /// Everything the log holds about one message: its own events, its thread's,
  /// and its attachments'.
  ///
  /// The same three grains [workItemsFor] reads, and the same escaped LIKE for
  /// the attachment ids.
  ///
  /// No `source` filter, deliberately, and this is where the two reads part.
  /// An event's `source` column is sometimes the WORK's source rather than the
  /// message's — the storyline kinds record under their own — so filtering on
  /// it would drop rows that are genuinely about this message. The ids on
  /// either side are opaque server ids that do not collide across connectors,
  /// so nothing is bought by the filter anyway.
  Future<List<Map<String, Object?>>> activityForEntity({
    required String sourceMessageId,
    required String conversationKey,
    int limit = 100,
  }) async {
    final result = await db
        .customSelect(
          'SELECT * FROM activity_events '
          'WHERE entity_id = ?1 OR entity_id = ?2 '
          "OR entity_id LIKE ?3 ESCAPE '\\' "
          'ORDER BY id DESC LIMIT ?4',
          variables: _args([
            sourceMessageId,
            conversationKey,
            '${_escapeLike(sourceMessageId)}|%',
            limit,
          ]),
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
  ///
  /// `sources` rides on the list read for the same reason: the rail's source
  /// pills need the connectors of every row at once, and asking per storyline
  /// would be a query per row.
  static const String _storylineSelect = '''
SELECT s.*,
  (SELECT COUNT(*) FROM storyline_members m WHERE m.storyline_id = s.id)
    AS member_count,
  (SELECT COUNT(*) FROM storyline_members m
     JOIN conversations c
       ON c.source = m.source AND c.conversation_key = m.conversation_key
     WHERE m.storyline_id = s.id AND c.state = 'needs_reply')
    AS open_count,
  (SELECT GROUP_CONCAT(DISTINCT m.source) FROM storyline_members m
     WHERE m.storyline_id = s.id)
    AS sources
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
    Object? refreshedMemberHash = _unset,
    Object? refreshedMemberCount = _unset,
    Object? charterSuggestion = _unset,
    Object? recapText = _unset,
    Object? recapOpenJson = _unset,
    Object? recapDecisionsJson = _unset,
    Object? recapThrough = _unset,
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
    // The v10 columns all take the sentinel rather than a plain nullable: a
    // refresh clearing a charter suggestion and a caller not touching it are
    // different writes, and every one of these is cleared by somebody.
    if (!identical(refreshedMemberHash, _unset)) {
      sets.add('refreshed_member_hash = ?');
      args.add(refreshedMemberHash as String?);
    }
    if (!identical(refreshedMemberCount, _unset)) {
      sets.add('refreshed_member_count = ?');
      args.add(refreshedMemberCount as int?);
    }
    if (!identical(charterSuggestion, _unset)) {
      sets.add('charter_suggestion = ?');
      args.add(charterSuggestion as String?);
    }
    if (!identical(recapText, _unset)) {
      sets.add('recap_text = ?');
      args.add(recapText as String?);
    }
    if (!identical(recapOpenJson, _unset)) {
      sets.add('recap_open_json = ?');
      args.add(recapOpenJson as String?);
    }
    if (!identical(recapDecisionsJson, _unset)) {
      sets.add('recap_decisions_json = ?');
      args.add(recapDecisionsJson as String?);
    }
    if (!identical(recapThrough, _unset)) {
      sets.add('recap_through = ?');
      args.add(recapThrough as String?);
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

  /// Takes a thread out of a storyline. [block] records that someone meant
  /// it, so the next clustering pass cannot put it straight back — the model
  /// is not allowed to overrule a person by being confident twice.
  ///
  /// [blockedBy] says WHOSE "no" this is. `'user'` is the owner's own hand and
  /// is the only kind the confirm prompt ever learns from; `'audit'` is the
  /// re-check pass acting on a lesson the owner already taught, and feeding
  /// that back would let the model teach itself.
  ///
  /// [evidence] defaults to the MEMBER's own evidence — the sentence that put
  /// the thread here — read inside the same transaction that deletes it. That
  /// is what makes a negative example say what the model thought at the time.
  /// An explicit value wins, which is how the audit records its own reason.
  ///
  /// The block insert stays `INSERT OR IGNORE`: a thread already blocked here
  /// keeps its ORIGINAL provenance and evidence. The first "no" is the one
  /// that was reasoned about, and an audit re-blocking what the owner already
  /// removed must not overwrite the owner's word with its own.
  Future<void> removeStorylineMember(
    String storylineId,
    String source,
    String conversationKey, {
    required bool block,
    String blockedBy = 'user',
    String? evidence,
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
      // Read before the delete, and only when the caller named nothing: the
      // member row is about to be gone, and it is the only place the
      // membership's reason was ever written.
      var reason = evidence;
      if (reason == null) {
        final rows = await db
            .customSelect(
              'SELECT evidence FROM storyline_members '
              'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
              variables: _args([storylineId, source, conversationKey]),
            )
            .get();
        if (rows.isNotEmpty) reason = rows.first.data['evidence'] as String?;
      }
      await db.customUpdate(
        'DELETE FROM storyline_members '
        'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
        variables: _args([storylineId, source, conversationKey]),
      );
      await db.customUpdate(
        'INSERT OR IGNORE INTO storyline_member_blocks '
        '(storyline_id, source, conversation_key, blocked_at, blocked_by, '
        'evidence) VALUES (?, ?, ?, ?, ?, ?)',
        variables: _args([
          storylineId,
          source,
          conversationKey,
          _nowIso(),
          blockedBy,
          reason,
        ]),
      );
    });
  }

  /// Lifts a block, and does nothing else — the thread is NOT re-added.
  ///
  /// What "Allow again" means: the owner is not filing the thread back, they
  /// are withdrawing the veto. Whether it belongs is a question the model may
  /// now answer on its own judgement, the next time a pass considers it.
  Future<void> unblockStorylineMember(
    String storylineId,
    String source,
    String conversationKey,
  ) async {
    await db.customUpdate(
      'DELETE FROM storyline_member_blocks '
      'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
      variables: _args([storylineId, source, conversationKey]),
    );
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

  /// Which storylines block this one thread — the mirror of
  /// [blockedThreadsOf], read the other way round.
  ///
  /// One query for every candidate at once. The assignment pass asks this of
  /// every live storyline before it compares anything, and asking one
  /// storyline at a time made filing a single thread cost a query per
  /// storyline in the mailbox.
  Future<Set<String>> blockedStorylineIdsFor(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT storyline_id FROM storyline_member_blocks '
          'WHERE source = ? AND conversation_key = ?',
          variables: _args([source, conversationKey]),
        )
        .get();
    return {
      for (final row in result) row.data['storyline_id'] as String? ?? '',
    };
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

  /// The threads the OWNER filed into [storylineId] by hand, newest first.
  ///
  /// Newest first, unlike [membersOf], because these are read as examples: the
  /// owner's latest word about what belongs here is the one worth showing a
  /// model, and the caller takes the first few.
  Future<List<StorylineMember>> userMembersOf(String storylineId) async {
    final result = await db
        .customSelect(
          'SELECT * FROM storyline_members WHERE storyline_id = ? '
          "AND added_by = 'user' "
          'ORDER BY added_at DESC, conversation_key ASC',
          variables: _args([storylineId]),
        )
        .get();
    return [for (final row in result) StorylineMember.fromRow(row.data)];
  }

  /// The blocks on [storylineId], newest first, optionally only those written
  /// by [blockedBy] — `'user'` for the owner's own removals, `'audit'` for the
  /// re-check pass's.
  ///
  /// The subject rides along on a LEFT JOIN, so a block whose conversation row
  /// is gone still comes back: the block is the record, and it outlives the
  /// thread it was written about.
  Future<List<StorylineBlock>> blocksOf(
    String storylineId, {
    String? blockedBy,
  }) async {
    final result = await db
        .customSelect(
          'SELECT b.*, c.subject AS subject FROM storyline_member_blocks b '
          'LEFT JOIN conversations c ON c.source = b.source '
          'AND c.conversation_key = b.conversation_key '
          'WHERE b.storyline_id = ?'
          '${blockedBy == null ? '' : ' AND b.blocked_by = ?'} '
          'ORDER BY b.blocked_at DESC, b.conversation_key ASC',
          variables: _args([storylineId, ?blockedBy]),
        )
        .get();
    return [for (final row in result) StorylineBlock.fromRow(row.data)];
  }

  /// Every storyline one THREAD has been filed into, newest first, each with
  /// its storyline's title and status beside it.
  ///
  /// Thread-keyed where [membersOf] is storyline-keyed, because the caller is
  /// standing on one message and asking what became of the thread it is on.
  ///
  /// Every status rather than only the live ones, and a LEFT JOIN so a
  /// membership outlives the storyline row it names. A filing that has since
  /// been dismissed still HAPPENED; a history that showed only the decisions
  /// still standing would be a history of the present.
  Future<List<Map<String, Object?>>> membershipsForThread(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT m.storyline_id AS storyline_id, m.added_by AS added_by, '
          'm.evidence AS evidence, m.added_at AS added_at, '
          's.title AS title, s.status AS status '
          'FROM storyline_members m '
          'LEFT JOIN storylines s ON s.id = m.storyline_id '
          'WHERE m.source = ? AND m.conversation_key = ? '
          'ORDER BY m.added_at DESC, m.storyline_id ASC',
          variables: _args([source, conversationKey]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// The other half of [membershipsForThread]: every storyline this thread was
  /// kept OUT of, newest first, with who wrote the block and what they thought.
  ///
  /// Same shape and same LEFT JOIN for the same reason — a block is a record,
  /// and it outlives both the thread and the storyline it was written about.
  Future<List<Map<String, Object?>>> blocksForThread(
    String source,
    String conversationKey,
  ) async {
    final result = await db
        .customSelect(
          'SELECT b.storyline_id AS storyline_id, '
          'b.blocked_by AS blocked_by, b.evidence AS evidence, '
          'b.blocked_at AS blocked_at, s.title AS title, s.status AS status '
          'FROM storyline_member_blocks b '
          'LEFT JOIN storylines s ON s.id = b.storyline_id '
          'WHERE b.source = ? AND b.conversation_key = ? '
          'ORDER BY b.blocked_at DESC, b.storyline_id ASC',
          variables: _args([source, conversationKey]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Everything the comparison passes need about the members of
  /// [storylineIds]: which threads they are, who is on each one, and each
  /// one's vector.
  ///
  /// One query for the whole set. The assignment pass asks this of every live
  /// storyline for every thread it considers, and walking members one at a
  /// time made filing a single thread cost a query per member of every
  /// storyline in the mailbox.
  ///
  /// Both joins are LEFT, and that is the contract rather than an accident. A
  /// member whose conversation row is gone, or whose vector came from a
  /// different embedding model, is still a member: its row comes back with a
  /// null `participants_json` or a null `embedding`, so it contributes nothing
  /// to a centroid and nobody to a participant list, but the caller still sees
  /// that the thread is already filed here. [embedModel] rides the join rather
  /// than the WHERE for exactly that reason — as a filter it would drop the
  /// member entirely.
  Future<List<Map<String, Object?>>> memberContextRows(
    List<String> storylineIds, {
    required String embedModel,
  }) async {
    if (storylineIds.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT m.storyline_id AS storyline_id, m.source AS source, '
          'm.conversation_key AS conversation_key, '
          'c.participants_json AS participants_json, '
          'a.embedding AS embedding '
          'FROM storyline_members m '
          'LEFT JOIN conversations c '
          '  ON c.source = m.source '
          '  AND c.conversation_key = m.conversation_key '
          'LEFT JOIN conversation_ai a '
          '  ON a.source = m.source '
          '  AND a.conversation_key = m.conversation_key '
          '  AND a.embed_model = ? '
          'WHERE m.storyline_id IN (${_placeholders(storylineIds.length)}) '
          'ORDER BY m.added_at ASC, m.conversation_key ASC',
          variables: _args([embedModel, ...storylineIds]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Which live storylines one thread belongs to. Dismissed and archived ones
  /// are excluded: their member rows survive only as the record behind
  /// [dismissedHashExistsAny], and a thread is not "in" a suggestion the
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

  /// Brings the clustering index level with `conversation_ai` and returns how
  /// many rows it then holds — `null` when there is no usable index, which is
  /// the caller's signal to do the arithmetic itself.
  ///
  /// The count is the point of the return type: a KNN probe over this index
  /// has to ask for as many neighbours as the index holds to be certain it saw
  /// every one of them, and the sweep cannot know that number on its own.
  ///
  /// Overridable for the same reason [memberContextRows] is: a test that has
  /// to exercise the fallback needs a store that reports no index, and the
  /// alternative — unloading a process-global native extension — is not one.
  Future<int?> prepareConversationIndex({required String embedModel}) async {
    if (!await _conversationIndex.ensureReady()) return null;
    return _conversationIndex.backfill(embedModel: embedModel);
  }

  /// The [k] threads nearest [vector] in the clustering index, as cosine
  /// similarities, closest first. Empty when the index is unavailable — which
  /// only a caller that skipped [prepareConversationIndex] can be surprised by.
  ///
  /// The probe's own thread is among them, at similarity 1: the index cannot
  /// tell which row asked, so excluding it belongs to whoever knows.
  Future<List<({String source, String key, double similarity})>>
      conversationNeighbors(Uint8List vector, {required int k}) =>
          _conversationIndex.neighbors(vector, k: k);

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
  /// Both columns answer, because a storyline can be dismissed under a set
  /// that is not the one it was proposed as. The `cluster_hash` arm recognises
  /// the proposal-time group — immutable, and exactly what the sweep rebuilds.
  /// The `member_hash` arm recognises the members as they stood at dismissal,
  /// maintained by every membership write, which is what catches a group the
  /// user pruned before saying no.
  ///
  /// A LIST of hashes rather than one, because the recipe behind these strings
  /// changed when storyline hashes started folding the connector into every
  /// member. Old rows cannot be rewritten — a cluster tombstoned below the
  /// minimum size has no member rows at all, so nothing can rebuild what it
  /// was — and a "no" the user gave once has to keep holding. The caller
  /// offers every recipe for the same candidate set and any match is a match,
  /// in one round trip rather than one per recipe.
  Future<bool> dismissedHashExistsAny(List<String> hashes) async {
    if (hashes.isEmpty) return false;
    final placeholders = _placeholders(hashes.length);
    final result = await db
        .customSelect(
          "SELECT 1 FROM storylines WHERE status = 'dismissed' "
          'AND (cluster_hash IN ($placeholders) '
          'OR member_hash IN ($placeholders)) LIMIT 1',
          variables: _args([...hashes, ...hashes]),
        )
        .get();
    return result.isNotEmpty;
  }

  /// Every live storyline whose description no longer describes its members.
  ///
  /// The heal behind the refresh pass. `requeueWork` revives only `done` and
  /// `error` rows, so a refresh enqueued while an earlier one was `processing`
  /// is swallowed — and nothing else would ever notice, because every other
  /// trigger fires on an event that has already passed. This asks the durable
  /// question instead: is what we last described still what is in here?
  ///
  /// `IS NOT` rather than `!=` because both columns are nullable and SQLite's
  /// `!=` answers NULL — which is not true — for exactly the rows that most
  /// need finding: a storyline nobody has ever described has a null
  /// `refreshed_member_hash` and a real `member_hash`, and `IS NOT` calls that
  /// the difference it is. It also excludes the shape that has neither: a
  /// cluster tombstoned with no member rows is null on both sides, so
  /// `NULL IS NOT NULL` is false and it stays out — as its `dismissed` status
  /// already ensures.
  Future<List<String>> staleRefreshStorylineIds() async {
    final result = await db
        .customSelect(
          'SELECT id FROM storylines '
          "WHERE status IN ('suggested', 'active') "
          'AND refreshed_member_hash IS NOT member_hash '
          'ORDER BY id ASC',
        )
        .get();
    return [for (final row in result) row.data['id'] as String? ?? ''];
  }

  /// Every live storyline holding a message the recap has not read.
  ///
  /// The heal behind the recap pass, and it answers the same durable question
  /// [staleRefreshStorylineIds] does — for a pass whose every other trigger
  /// fires on a message ARRIVING. A storyline that already matches its
  /// description and has had no new mail since trips none of those triggers,
  /// so without this a storyline the recap has never read stays unread
  /// forever: every row the v10 backfill described, and every recap wakeup a
  /// `processing` row swallowed.
  ///
  /// Every predicate here is load-bearing, and all of them for one reason —
  /// this must ask the question the pass itself will answer, or a storyline it
  /// queues is a storyline it re-queues on every sweep for the rest of time.
  ///
  /// The gate exclusion is [recentStorylineMessages]' rule, character for
  /// character — the outbound arm included: skipped messages are not in the
  /// recap's window, except the owner's own and except chats, which are only
  /// ever skipped for being chats. Without it a storyline whose only newer
  /// messages are gated would be queued, find nothing to read, and stamp no
  /// watermark — and be queued again on the next sweep.
  ///
  /// The outbound arm is not merely parity, it is the point: a reply the user
  /// sent must make the recap stale, or the recap goes on saying they owe an
  /// answer they have already given. It is also what makes this catch-up the
  /// prompt path rather than a slow one — every sync ends by requeueing
  /// `storyline_sweep`, and the recap handler drains after the sweep's, so the
  /// sync that folds a sent reply in is the drain that recaps it.
  ///
  /// The `received_at` guard is the same anti-loop for the timestampless: the
  /// recap takes its watermark from the newest message in the window and
  /// returns early when there is none, so a row that can never move the
  /// watermark must never be the reason to run.
  ///
  /// One `EXISTS` serves both arms. `s.recap_through IS NULL` is the storyline
  /// nobody has recapped; `msg.received_at > s.recap_through` is the one that
  /// has fallen behind. Both live inside the message test on purpose — a
  /// storyline with no qualifying messages AT ALL is deliberately left alone
  /// even with a null watermark, because [StorylineService.recap] would find
  /// an empty window, return, and never converge.
  Future<List<String>> staleRecapStorylineIds() async {
    final result = await db
        .customSelect(
          'SELECT s.id FROM storylines s '
          "WHERE s.status IN ('suggested', 'active') "
          'AND EXISTS ('
          '  SELECT 1 FROM storyline_members m '
          '  JOIN messages msg ON msg.source = m.source '
          '    AND msg.conversation_key = m.conversation_key '
          '  WHERE m.storyline_id = s.id '
          "    AND msg.received_at IS NOT NULL AND msg.received_at != '' "
          "    AND (msg.direction = 'outbound' "
          "         OR msg.triage_status <> 'skipped' "
          "         OR msg.gate_reason = 'teams_source') "
          '    AND (s.recap_through IS NULL '
          '         OR msg.received_at > s.recap_through)'
          ') '
          'ORDER BY s.id ASC',
        )
        .get();
    return [for (final row in result) row.data['id'] as String? ?? ''];
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
  ///
  /// [payloadJson] is OVERWRITTEN on conflict, including with null, and that
  /// is the point rather than an oversight: a Regenerate that names a document
  /// has to carry it into the draft it is asking for, and the plain Regenerate
  /// after it has to drop the last one's — a payload that survived would go on
  /// pinning a file the user has stopped asking about, on every draft of that
  /// message for the rest of the mailbox's life.
  Future<void> requeueWork(
    String kind,
    String source,
    String entityId, {
    String? payloadJson,
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT INTO work_items '
      '(task_kind, source, entity_id, status, attempts, error, payload_json, '
      'created_at, updated_at) '
      "VALUES (?, ?, ?, 'pending', 0, NULL, ?, ?, ?) "
      'ON CONFLICT(task_kind, source, entity_id) DO UPDATE SET '
      "status = 'pending', updated_at = excluded.updated_at, "
      'payload_json = excluded.payload_json '
      "WHERE work_items.status IN ('done', 'error')",
      variables: _args([kind, source, entityId, payloadJson, now, now]),
    );
  }

  /// Puts the needs-you items a model-less build finished back in the queue,
  /// and returns how many that was.
  ///
  /// The one-shot catch-up for a real state on disk: the first build of this
  /// pass had only the deterministic floor, so every message below the floor
  /// came back `done` with a NULL verdict — and `INSERT OR IGNORE` will never
  /// offer those rows again. Its caller runs it once behind a pref, because
  /// what it is catching up on happened once.
  ///
  /// The predicate is deliberately simple, and the price of that is precision:
  /// gated and outbound rows whose verdict is NULL are revived too, and leave
  /// again through the handler's own guards. That costs one queue row each,
  /// once, against a predicate that would otherwise have to restate every
  /// guard the handler already owns.
  Future<int> reviveUnjudgedNeedsYou() {
    return db.customUpdate(
      "UPDATE work_items SET status = 'pending', attempts = 0, error = NULL, "
      'updated_at = ? '
      "WHERE task_kind = 'needs_you' AND status = 'done' "
      'AND EXISTS (SELECT 1 FROM messages m '
      'WHERE m.source = work_items.source '
      'AND m.source_message_id = work_items.entity_id '
      "AND m.direction = 'inbound' "
      'AND m.needs_you_verdict IS NULL)',
      variables: _args([_nowIso()]),
    );
  }

  /// Puts the needs-you verdict of every recent inbound message back on the
  /// queue, newest first, and returns how many rows that touched.
  ///
  /// The rules-save trigger: the owner has just rewritten the prompt every
  /// below-the-floor judgement reads, so the verdicts that prompt produced in
  /// the recent window are re-asked against the new one. Older verdicts are
  /// history rather than mistakes — the rules were what they were when those
  /// messages landed — so [sinceIso] bounds what is re-asked, and [cap] bounds
  /// the model bill a single Save can run up. The chip and the tile follow
  /// each new verdict through `NeedsYouHandler`'s own tail, so nothing here
  /// touches `message_progress`.
  ///
  /// The triage filter is the same admission the first judgement had:
  /// `triaged` is the status of a message the pipeline kept, and the
  /// `teams_source` tolerance carries the chat rows stored `skipped` before
  /// chats were triaged at all — re-judging on a rules change must not be the
  /// one pass that decides they never existed.
  ///
  /// The count is of rows SELECTED, not of work rows written, and that is the
  /// number the owner is shown: [requeueWork] inserts when a message has never
  /// been judged and revives a `done` or `error` row, but leaves a row already
  /// `pending` or `processing` in its place in the queue. Such a message is
  /// still going to be judged under the new rules, so counting it is honest.
  Future<int> requeueNeedsYouRejudge({
    required String sinceIso,
    List<String> sources = const ['email', 'teams'],
    int cap = 200,
  }) async {
    if (sources.isEmpty) return 0;
    final rows = await db
        .customSelect(
          'SELECT source, source_message_id FROM messages '
          "WHERE direction = 'inbound' "
          '  AND received_at >= ? '
          '  AND source IN (${_placeholders(sources.length)}) '
          "  AND (triage_status = 'triaged' OR gate_reason = 'teams_source') "
          'ORDER BY received_at DESC, source_message_id DESC '
          'LIMIT ?',
          variables: _args([sinceIso, ...sources, cap]),
        )
        .get();
    // One transaction for the whole batch: two hundred separate writes on a
    // Save is two hundred fsyncs, and the queue is only meaningful once every
    // row in the window is on it.
    await db.transaction(() async {
      for (final row in rows) {
        await requeueWork(
          'needs_you',
          row.data['source'] as String? ?? '',
          row.data['source_message_id'] as String? ?? '',
        );
      }
    });
    return rows.length;
  }

  /// Puts the storyline pass back on the queue for every conversation the
  /// settle race left owing one, and returns how many that was.
  ///
  /// The shape it heals: the coordinator settled a message in the middle of a
  /// sync, before its storyline work was enqueued, so the row carries
  /// `settle_state = 'done'` with `storyline_state` still `pending` — and
  /// `outcome` stuck at `pending` behind it, because both
  /// [writeDraftProgress] and [sweepSettledProgress] wait for a terminal
  /// storyline stage. With [writeStorylineProgress]'s owed-stage arm the pass
  /// this queues now lands, which is what makes this a heal rather than a
  /// retry loop: self-exhausting, because a row it fixes no longer matches.
  ///
  /// `dropped = 0` is load-bearing and not defensive. A gate cascade writes
  /// `settle_state = 'done'` too, with every stage `skipped` — but a gated row
  /// whose stages were left `pending` by an older write must stay dropped, and
  /// requeueing the model for mail the gate threw out is exactly what the gate
  /// exists to prevent.
  ///
  /// The NOT EXISTS keeps this off a conversation the queue is already going
  /// to reach: [requeueWork] would revive a `done` row under a drain that has
  /// not written its result yet, and one pass per stuck thread is the point.
  Future<int> reviveOwedStorylineStages({
    required List<String> sources,
  }) async {
    if (sources.isEmpty) return 0;
    final rows = await db
        .customSelect(
          '''
SELECT DISTINCT source, conversation_key
FROM message_progress
WHERE source IN (${_placeholders(sources.length)})
  AND settle_state = 'done'
  AND outcome = 'pending'
  AND storyline_state = 'pending'
  AND dropped = 0
  AND NOT EXISTS (
    SELECT 1 FROM work_items w
     WHERE w.task_kind = 'storyline'
       AND w.source = message_progress.source
       AND w.entity_id = message_progress.conversation_key
       AND w.status IN ('pending', 'processing')
  )
''',
          variables: _args(sources),
        )
        .get();
    for (final row in rows) {
      await requeueWork(
        'storyline',
        row.data['source'] as String? ?? '',
        row.data['conversation_key'] as String? ?? '',
      );
    }
    return rows.length;
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
  ///
  /// `context_json` is overwritten the same way and with the same rule,
  /// including with null: it is the inventory of what THIS answer read, and a
  /// regenerate that read nothing must not leave the previous answer's
  /// citations under the composer's provenance line.
  Future<void> upsertDraft({
    required String source,
    required String conversationKey,
    required String replyToMessageId,
    required String body,
    String? evidence,
    String? optionsJson,
    String? contextJson,
    String status = 'suggested',
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      '''
INSERT INTO drafts (
  source, conversation_key, reply_to_message_id, body, evidence, status,
  graph_draft_id, web_link, created_at, updated_at, options_json,
  options_dismissed, context_json
) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, 0, ?)
ON CONFLICT(source, reply_to_message_id) DO UPDATE SET
  conversation_key = excluded.conversation_key,
  body = excluded.body,
  evidence = excluded.evidence,
  status = excluded.status,
  graph_draft_id = NULL,
  web_link = NULL,
  updated_at = excluded.updated_at,
  options_json = excluded.options_json,
  options_dismissed = 0,
  context_json = excluded.context_json
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
        contextJson,
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

  /// Every suggestion still waiting, across the whole mailbox, newest first.
  ///
  /// The pane behind this is the model's outbox: what it has written and
  /// nobody has agreed to yet. Three narrowings make it that rather than a
  /// dump of the `drafts` table.
  ///
  /// **Statuses.** `suggested` and `edited` only. `sent` is history and
  /// `dismissed` is a row kept alive purely so the enqueue does not write the
  /// same suggestion straight back — see [updateDraftStatus].
  ///
  /// **The newest inbound rule.** The `reply_to_message_id` subselect is the
  /// one [getDraft] uses, character for character. A suggestion written
  /// against an older message is still stored and still readable in its
  /// thread, but it is not what the composer would offer, so listing it here
  /// would send the reader to a thread whose box is empty.
  ///
  /// **Done threads.** A closed thread is finished. A suggestion still sitting
  /// against it is the model having written something before the user decided
  /// the conversation was over, and a list that kept asking about it would be
  /// asking the user to re-close it once a day.
  Future<List<PendingDraft>> pendingDrafts({
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT d.source, d.conversation_key, d.reply_to_message_id, '
          '       d.body, d.status, d.updated_at, '
          '       c.subject AS subject, '
          '       m.from_name AS from_name, m.from_address AS from_address '
          'FROM drafts d '
          'JOIN conversations c '
          '  ON c.source = d.source AND c.conversation_key = d.conversation_key '
          'LEFT JOIN messages m '
          '  ON m.source = d.source AND m.source_message_id = d.reply_to_message_id '
          "WHERE d.status IN ('suggested','edited') "
          '  AND d.source IN (${_placeholders(sources.length)}) '
          '  AND c.state != ? '
          '  AND d.reply_to_message_id = ('
          '    SELECT m2.source_message_id FROM messages m2 '
          '     WHERE m2.source = d.source '
          '       AND m2.conversation_key = d.conversation_key '
          "       AND m2.direction = 'inbound' "
          '     ORDER BY m2.received_at DESC, m2.source_message_id DESC LIMIT 1'
          '  ) '
          'ORDER BY d.updated_at DESC',
          variables: _args([...sources, ConversationState.done.wire]),
        )
        .get();
    return [for (final row in result) PendingDraft.fromRow(row.data)];
  }

  /// What the user has sent, newest first — mail and chat together.
  ///
  /// There is no `sent` table: a send writes an outbound row into `messages`,
  /// so this column IS the Sent list. Echo rows are included rather than
  /// filtered out, and deliberately — the user watched the reply leave, and a
  /// list that hid it until the Sent Items copy synced would be a list that
  /// disagreed with what they just did. `SentRow.echo` is how the pane says
  /// which ones are still provisional.
  ///
  /// Ordered on `COALESCE(received_at, created_at)` because an echo has no
  /// `received_at` until the server's copy lands, and a sort on the null would
  /// put the newest thing at the bottom.
  Future<List<SentRow>> recentOutbound({
    List<String> sources = const ['email', 'teams'],
    int limit = 50,
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          'SELECT m.source, m.source_message_id, m.conversation_key, '
          '       m.subject, m.to_json, m.body_preview, m.body_text, '
          '       COALESCE(m.received_at, m.created_at) AS sent_at '
          'FROM messages m '
          "WHERE m.direction = 'outbound' "
          '  AND m.source IN (${_placeholders(sources.length)}) '
          'ORDER BY sent_at DESC, m.source_message_id DESC '
          'LIMIT ?',
          variables: _args([...sources, limit]),
        )
        .get();
    return [for (final row in result) SentRow.fromRow(row.data)];
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

  /// The newest [limit] messages across every thread in [storylineId], newest
  /// first — the window the recap pass reads.
  ///
  /// Newest FIRST, where [storylineTimeline] is oldest first, because the two
  /// have opposite problems. The timeline renders everything and scrolls; this
  /// takes a fixed-size tail off an unbounded history, and `ORDER BY … DESC
  /// LIMIT ?` is the only way to ask for the last twelve without reading the
  /// first thousand. The caller reverses what it gets — "where does this stand
  /// now" is a question about the END of a sequence, so the model reads them
  /// chronologically.
  ///
  /// The subject falls back to the CONVERSATION's, and that is not cosmetic: a
  /// chat message carries no subject at all (`TeamsSync.messageRow` stores
  /// null rather than inventing one), so without the fallback every line of a
  /// chat member thread would arrive with no thread name and the model could
  /// not tell one thread's messages from another's. The join is LEFT so a
  /// message that outran its own conversation row still comes back.
  ///
  /// Gated messages are excluded on exactly [EmbedHandler]'s rule: triage
  /// flipped them to `skipped` because they are newsletters, no-reply senders
  /// or auto-generated mail, and a recap that narrated the vendor's marketing
  /// mail would be describing the wrong storyline. The `teams_source`
  /// exception is the same legacy tolerance — a chat row stored before chats
  /// were triaged is `skipped` for no judgement anyone made, and dropping it
  /// would silently empty the recap of a chat-only storyline.
  ///
  /// **The owner's own messages are never gated out**, whatever their triage
  /// columns say, and that arm comes first for a reason. `triageStatusOnInsert`
  /// marks every outbound message `skipped`/`outbound`, but that gate answers
  /// "does this need the user?" — it is about not spending model calls on the
  /// user's own mail, and it was never a statement about the narrative. The
  /// recap's whole subject is who owes whom, and the reply the user sent is the
  /// single most important fact in that judgement: without this arm the window
  /// is every question ever asked of them and not one of their answers, so the
  /// model reads a storyline where the user has gone silent and writes open
  /// items they settled last week. The recap prompt already renders these as
  /// `You`, so nothing above this query needed changing.
  Future<List<Map<String, Object?>>> recentStorylineMessages(
    String storylineId, {
    int limit = 12,
  }) async {
    final result = await db
        .customSelect(
          'SELECT m.source AS source, '
          'm.source_message_id AS source_message_id, '
          'm.conversation_key AS conversation_key, '
          'COALESCE(m.subject, c.subject) AS subject, '
          'm.direction AS direction, m.from_name AS from_name, '
          'm.body_preview AS body_preview, m.body_text AS body_text, '
          'm.received_at AS received_at '
          'FROM messages m '
          'JOIN storyline_members sm '
          '  ON sm.source = m.source '
          '  AND sm.conversation_key = m.conversation_key '
          'LEFT JOIN conversations c '
          '  ON c.source = m.source AND c.conversation_key = m.conversation_key '
          'WHERE sm.storyline_id = ? '
          "AND (m.direction = 'outbound' "
          "     OR m.triage_status <> 'skipped' "
          "     OR m.gate_reason = 'teams_source') "
          'ORDER BY m.received_at DESC, m.source_message_id DESC '
          'LIMIT ?',
          variables: _args([storylineId, limit]),
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
  /// waiting on. `message_progress` is LEFT for a harder reason:
  /// [admitNotifyCandidates] selects from `messages` alone, so a candidate
  /// whose progress row is missing is still an admitted candidate, and an
  /// inner join would drop it out of the sweep entirely — a row that never
  /// settles at all, which is worse than one that settles on the deadline.
  ///
  /// Completeness reads the PIPELINE'S OWN RECORD, not the queue.
  /// `extract_state` and `storyline_state` are what those stages write when
  /// they finish. The work rows behind them are enqueued after BOTH drains of
  /// a sync, while triage claims `messages.triage_status = 'pending'` the
  /// instant a page commits — so in the seconds between there is a freshly
  /// triaged message with no work rows at all, which the EXISTS flags this
  /// replaced read as "nothing left to do". The sweep settled it, and
  /// [writeStorylineProgress] then refused the stamp that arrived a minute
  /// later, freezing the row at `storyline_state = 'pending'` forever.
  ///
  /// Needs-you has no stage column by design — its handler writes two columns
  /// on `messages` and no progress stage — so "judged" is spelled out here
  /// instead: a verdict actually written, or a `needs_you` work row that
  /// reached `done` or `error`. The second arm is not redundant. The handler
  /// finishes an item `done` WITHOUT a verdict on every one of its guards
  /// (deleted, outbound, gated), and waiting past that would be waiting on
  /// nobody.
  ///
  /// `storyline_state` is a CONVERSATION-grained stage, so it over-waits when
  /// what the pass is still working on is a sibling message of the thread.
  /// That is the intended trade, unchanged from the flag it replaces:
  /// announcing a message under the wrong storyline is worse than announcing
  /// it a few seconds late, and the deadline bounds how late.
  Future<List<Map<String, Object?>>> openNotifyCandidates({
    int limit = 50,
  }) async {
    final result = await db
        .customSelect(
          '''
SELECT n.source, n.source_message_id, n.conversation_key, n.deadline_at,
  m.subject, m.from_name, m.summary, m.urgency, m.deadline, m.needs_action,
  m.reply_expected, m.needs_you_verdict, m.is_read, m.triage_status,
  m.received_at,
  m.updated_at AS message_updated_at,
  c.cta_text, c.cta_urgency, c.state AS conversation_state,
  ai.attention_score, ai.bucket, ai.updated_at AS ai_updated_at,
  p.extract_state, p.storyline_state,
  CASE WHEN m.needs_you_verdict IS NOT NULL THEN 1
       WHEN EXISTS (SELECT 1 FROM work_items w
                    WHERE w.task_kind = 'needs_you' AND w.source = n.source
                      AND w.entity_id = n.source_message_id
                      AND w.status IN ('done', 'error')) THEN 1
       ELSE 0 END AS needs_you_judged
FROM message_notify n
JOIN messages m ON m.source = n.source AND m.source_message_id = n.source_message_id
LEFT JOIN conversations c ON c.source = n.source AND c.conversation_key = n.conversation_key
LEFT JOIN conversation_ai ai ON ai.source = n.source AND ai.conversation_key = n.conversation_key
LEFT JOIN message_progress p
       ON p.source = n.source AND p.source_message_id = n.source_message_id
WHERE n.state = 'pending'
ORDER BY n.deadline_at ASC
LIMIT ?
''',
          variables: _args([limit]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// One message in the shape [openNotifyCandidates] hands the sweep, for a
  /// caller that has a message id rather than a candidate row.
  ///
  /// It exists for the needs-you re-verdict, which has to answer the sweep's
  /// own question — `notifyWorthy` — about a message whose `message_notify`
  /// row settled long ago and is no longer selected by anything. Projecting
  /// the same column NAMES is the whole contract: the predicate reads a map,
  /// so a column renamed on one path and not the other would read null and
  /// quietly answer no.
  ///
  /// `received_at` rides along for the caller's own guard rather than for the
  /// predicate: `notifyWorthy` has no outbound clause, and a re-verdict has to
  /// know whether the user has already answered this thread.
  ///
  /// Null when the message is gone — queued, then deleted.
  Future<Map<String, Object?>?> notifyRowFor(
    String source,
    String sourceMessageId,
  ) async {
    final rows = await db
        .customSelect(
          '''
SELECT m.subject, m.from_name, m.summary, m.urgency, m.deadline,
  m.needs_action, m.reply_expected, m.needs_you_verdict, m.is_read,
  m.triage_status, m.received_at,
  c.cta_text, c.cta_urgency, c.state AS conversation_state,
  c.last_outbound_at,
  ai.attention_score, ai.bucket
FROM messages m
LEFT JOIN conversations c
       ON c.source = m.source AND c.conversation_key = m.conversation_key
LEFT JOIN conversation_ai ai
       ON ai.source = m.source AND ai.conversation_key = m.conversation_key
WHERE m.source = ? AND m.source_message_id = ?
''',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first.data);
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

  /// True when the message or its thread has work queued or running.
  ///
  /// Three arms because one message's work is filed under three different
  /// entity ids: its own id for the per-message stages, its conversation key
  /// for storyline assignment, and `'<message id>|<attachment id>'` for every
  /// document hanging off it (see `attachmentEntityId`). `substr` rather than
  /// LIKE on that last arm: a Graph message id can contain `_`, which LIKE
  /// reads as a wildcard, and the prefix test would then match ids that are
  /// not this message's at all.
  ///
  /// Triage is the fourth arm, and it is read off `messages` because triage
  /// has no work row: the queue claims `triage_status = 'pending'` directly.
  /// Without it every untriaged row of a large drain would read as stalled
  /// fifteen minutes in — the queue is working, just not on this row yet —
  /// and the In flight tile would go red on every big sync. The price is
  /// that a triage queue parked on a dead session never reads as stalled
  /// per row; that condition is global, and the activity log names it.
  ///
  /// It is what tells a row that has stopped from a row nobody has got to
  /// yet, so [HomeFeedRow.isStalled] and the stalled tile both stand on it.
  static const String _openWorkExists = '''
(EXISTS (
  SELECT 1 FROM work_items w
  WHERE w.source = p.source
    AND w.status IN ('pending', 'processing')
    AND (w.entity_id = p.source_message_id
         OR w.entity_id = p.conversation_key
         OR substr(w.entity_id, 1, length(p.source_message_id) + 1)
            = p.source_message_id || '|'))
 OR EXISTS (
  SELECT 1 FROM messages mt
  WHERE mt.source = p.source
    AND mt.source_message_id = p.source_message_id
    AND mt.triage_status IN ('pending', 'processing')))''';

  /// Which storyline the row is really filed in.
  ///
  /// `message_progress.storyline_id` is a pointer stamped when THIS row's own
  /// storyline pass ran, so it is null for a message that arrived on a thread
  /// already in a storyline, and null for a thread a person filed by hand
  /// afterwards — in both cases the thread is a member and the row says
  /// nothing. The feed's "Filed in" has to read the membership when the
  /// pointer is missing, or it would hide most of what is actually filed.
  ///
  /// Newest membership wins, because a thread is allowed to sit in several
  /// and the last one it joined is the one the reader was told about. Ties on
  /// `added_at` — two threads filed in the same pass share a stamp — break on
  /// the id, so the answer is stable between reads rather than sqlite's whim.
  ///
  /// LIVE storylines only, the same rule [storylineIdsFor] applies. Member
  /// rows survive a dismissal (D17), so without the join a suggestion the
  /// owner threw away would go on naming every row of its threads.
  static const String _effectiveStorylineId = '''
COALESCE(p.storyline_id, (
  SELECT x.storyline_id FROM storyline_members x
  JOIN storylines sx ON sx.id = x.storyline_id
                    AND sx.status IN ('suggested', 'active')
  WHERE x.source = p.source AND x.conversation_key = p.conversation_key
  ORDER BY x.added_at DESC, x.storyline_id DESC LIMIT 1))''';

  /// Everything a home-feed row needs, in one projection.
  ///
  /// Shared by the paging read, the live patch read and the two search reads
  /// on purpose: they must return the same shape, or the notifier would be
  /// replacing complete rows with rows that have holes in them.
  /// The column list alone, so a read that needs the same row shape over a
  /// DIFFERENT set of joins — [semanticSearch] comes in through
  /// `message_vectors` — can have it without copying the column list that
  /// [HomeFeedRow.fromRow] then has to keep agreeing with.
  ///
  /// The reason columns are here rather than behind a second read because
  /// they are what a row has to be able to explain itself with: why the gate
  /// let it through, why the verdict went the way it did, which bucket the
  /// sweep put the thread in. They are read live rather than snapshotted —
  /// they are the pipeline's own record, and it is allowed to change its
  /// mind.
  ///
  /// The two membership fields are SCALAR SUBQUERIES and not a join, and that
  /// is load-bearing: a thread can be in several storylines, a join would
  /// return one feed row per membership, and the list is keyed by row — two
  /// rows under one key is a crash, not a duplicate.
  static const String _homeFeedColumns = '''
p.source, p.source_message_id, p.conversation_key, p.received_at,
  p.triage_state, p.extract_state, p.storyline_state, p.draft_state,
  p.settle_state,
  p.outcome, p.dropped, p.drop_reason, p.needs_you, p.urgency, p.updated_at,
  $_effectiveStorylineId AS storyline_id,
  m.subject, m.from_name, m.from_address, m.has_attachments, m.summary,
  m.needs_you_verdict, m.needs_you_reason, m.gate_reason, m.triage_status,
  c.cta_text, c.state AS thread_state,
  s.title AS storyline_title,
  ai.bucket, ai.bucket_reason, ai.attention_score,
  (SELECT sm.evidence FROM storyline_members sm
     WHERE sm.storyline_id = s.id AND sm.source = p.source
       AND sm.conversation_key = p.conversation_key) AS storyline_evidence,
  (SELECT sm.added_by FROM storyline_members sm
     WHERE sm.storyline_id = s.id AND sm.source = p.source
       AND sm.conversation_key = p.conversation_key) AS storyline_added_by,
  $_openWorkExists AS work_open''';

  /// The joins [_homeFeedColumns] is written against, so its readers — the
  /// page read, the live patch, and the two search hydrations — cannot drift
  /// apart: a column present on one path and missing on another
  /// is a hole [HomeFeedRow.fromRow] reads as null on that path alone.
  ///
  /// `conversation_ai`'s primary key is `(source, conversation_key)`, so its
  /// LEFT JOIN cannot multiply a row — unlike the memberships above, which is
  /// why those stayed subqueries. `conversations` is keyed the same way, so
  /// the ask joins on exactly the same argument: one thread row per message
  /// row, whatever the thread's size.
  static const String _homeFeedJoins = '''
JOIN messages m
  ON m.source = p.source AND m.source_message_id = p.source_message_id
LEFT JOIN storylines s ON s.id = $_effectiveStorylineId
LEFT JOIN conversation_ai ai
  ON ai.source = p.source AND ai.conversation_key = p.conversation_key
LEFT JOIN conversations c
  ON c.source = p.source AND c.conversation_key = p.conversation_key''';

  static const String _homeFeedSelect = '''
SELECT $_homeFeedColumns
FROM message_progress p
$_homeFeedJoins''';

  /// One `message_progress` row exactly as stored, or null.
  ///
  /// The raw row, where [progressRowsFor] hands back the joined feed shape.
  /// A caller explaining one message needs both: the feed row for everything
  /// the rails already know how to say, and this for the five `*_at` stamps,
  /// which are joined onto nothing and are the only record of WHEN each stage
  /// finished.
  Future<Map<String, Object?>?> getProgressRow(
    String source,
    String sourceMessageId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM message_progress '
          'WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

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

  /// Opens one finished row back up — the reverse of the one-way cascade
  /// [writeTriageProgress] writes on a gate skip. Same return contract as
  /// [writeTriageProgress].
  ///
  /// All five stages go back to `pending` because all five are about to run
  /// again. `ingest_state` is not among them and must not be: the message
  /// itself exists and was never in doubt — only what the pipeline made of it
  /// was. `needs_you`, `urgency` and `storyline_id` are left alone too; triage
  /// and settle will restate them, and clearing them here would only blank the
  /// row's rail position for the seconds in between.
  ///
  /// `drop_reason` is cleared unconditionally, which no other writer does.
  /// [writeSettledProgress] only ever writes the reason on the way DOWN (its
  /// `CASE WHEN ?2 = 1`), so a row it un-drops keeps the stale reason it was
  /// dropped for. A restored row must not carry the old reason forward.
  Future<String?> restoreProgress(String source, String sourceMessageId) async {
    final rows = await db.customWriteReturning(
      'UPDATE message_progress SET\n$_resetProgressSet\n'
      'WHERE source = ?2 AND source_message_id = ?3\n'
      'RETURNING received_at',
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// Moves one progress row's clock, and nothing else.
  ///
  /// A retry is a progress write even when no stage state changes: it
  /// restarts the stalled clock, so the row stops accusing the pipeline of
  /// having given up on it, and the returned `received_at` gives the live
  /// screen a tick to re-read behind. Null when there is no progress row,
  /// which costs the tick and nothing else.
  Future<String?> touchProgress(String source, String sourceMessageId) async {
    final rows = await db.customWriteReturning(
      'UPDATE message_progress SET updated_at = ?1 '
      'WHERE source = ?2 AND source_message_id = ?3 '
      'RETURNING received_at',
      variables: _args([_nowIso(), source, sourceMessageId]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// The SET list every re-open shares, so the one-row path and the bulk path
  /// cannot drift into resetting different columns. `?1` is the stamp; each
  /// caller numbers its own WHERE from `?2`.
  static const String _resetProgressSet = '''
  triage_state = 'pending', extract_state = 'pending',
  storyline_state = 'pending', draft_state = 'pending',
  settle_state = 'pending',
  triage_at = NULL, extract_at = NULL, storyline_at = NULL,
  draft_at = NULL, settle_at = NULL,
  outcome = 'pending', dropped = 0, drop_reason = NULL,
  updated_at = ?1''';

  /// How many ids one reset statement carries. Well under SQLite's variable
  /// ceiling, and the same chunking [attachmentRefsFor] does for the same
  /// reason: a retired gate can match a whole window at once.
  static const int _resetProgressChunk = 200;

  /// [restoreProgress] for a list of messages, without the RETURNING — the
  /// bulk callers re-pend rows the user is not watching, and the tick per row
  /// would say nothing the next stage write does not say better.
  Future<void> _resetProgressRows(String source, List<String> ids) async {
    for (var start = 0; start < ids.length; start += _resetProgressChunk) {
      final chunk = ids.sublist(
        start,
        math.min(start + _resetProgressChunk, ids.length),
      );
      final slots = [
        for (var i = 0; i < chunk.length; i++) '?${i + 3}',
      ].join(', ');
      await db.customUpdate(
        'UPDATE message_progress SET\n$_resetProgressSet\n'
        'WHERE source = ?2 AND source_message_id IN ($slots)',
        variables: _args([_nowIso(), source, ...chunk]),
      );
    }
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
  /// Bounded by `(settle_state <> 'done' OR storyline_state = 'pending')`,
  /// which is what keeps a thread that keeps growing from rewriting the
  /// history above it — a message the user was told about last week must not
  /// gain a storyline column today, because the row they are scrolling past is
  /// a record of what they were told.
  ///
  /// The second arm is what "history" actually means here, and the first arm
  /// alone got it wrong. A stage that was already TERMINAL when the row
  /// settled is frozen: that pass had its answer and the user was told it. A
  /// stage still `pending` at settle was OWED — the settle machine can land in
  /// the middle of a sync, before the storyline work is even enqueued — and
  /// owed work finishes normally. Without this arm such a row is stuck
  /// forever: `storyline_state` never leaves `pending`, and both
  /// [writeDraftProgress] and [sweepSettledProgress] require a terminal
  /// storyline stage before they will close the `outcome`.
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
WHERE source = ?4 AND conversation_key = ?5
  AND (settle_state <> 'done' OR storyline_state = 'pending')
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

  /// Points one conversation's messages at a storyline, or stops pointing them
  /// at one — and touches nothing else.
  ///
  /// The narrow twin of [writeStorylineProgress], for the membership a PERSON
  /// decided. It exists separately because the two writes answer different
  /// questions: that one records how far the assignment pass got, and the
  /// stages it writes are what the settle machine and the draft close-out
  /// read. Filing a thread by hand moved no stage — it moved a pointer — and
  /// borrowing the pass's write to do it would restart a settled row's
  /// pipeline for a decision that was never the pipeline's.
  ///
  /// Unguarded on `settle_state`, which is the other half of the split. The
  /// pass is bounded by it so a thread that keeps growing cannot rewrite the
  /// history above it; a hand-filed thread must do exactly that, because the
  /// user is telling the app what the old messages were always about.
  ///
  /// Exactly one of [storylineId] and [clearingStorylineId] per call. Clearing
  /// names the storyline it is clearing rather than blanking the column: a
  /// thread can sit in two storylines, and taking it out of one must leave the
  /// other's stamp where it is.
  ///
  /// Returns the rows it touched, so [PipelineProgress.noteStorylineLink] can
  /// tick a live screen without a second read.
  Future<List<({String sourceMessageId, String receivedAt})>> stampStorylineId(
    String source,
    String conversationKey, {
    String? storylineId,
    String? clearingStorylineId,
  }) async {
    // Thrown, not asserted: with both null the stamp arm below would blanket-
    // null every row of the conversation — the exact write the clearing
    // predicate exists to forbid — and a release build strips asserts.
    if ((storylineId == null) == (clearingStorylineId == null)) {
      throw ArgumentError(
        'stampStorylineId writes a stamp or clears one, never both or neither',
      );
    }
    final clearing = clearingStorylineId;
    final rows = clearing != null
        ? await db.customWriteReturning(
            'UPDATE message_progress SET storyline_id = NULL, updated_at = ? '
            'WHERE source = ? AND conversation_key = ? AND storyline_id = ? '
            'RETURNING source_message_id, received_at',
            variables: _args([_nowIso(), source, conversationKey, clearing]),
          )
        : await db.customWriteReturning(
            'UPDATE message_progress SET storyline_id = ?, updated_at = ? '
            'WHERE source = ? AND conversation_key = ? '
            'RETURNING source_message_id, received_at',
            variables:
                _args([storylineId, _nowIso(), source, conversationKey]),
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

  /// Moves one SETTLED row's Needs You snapshot to a value the caller has
  /// recomputed, and hands back its `received_at` when it actually moved.
  ///
  /// `message_progress.needs_you` is a snapshot taken at settle time, and the
  /// verdict it copies can move afterwards — the needs-you pass re-judging a
  /// message after a document landed, or the owner editing their rules. A
  /// snapshot that never followed the verdict is a Needs You tile that
  /// disagrees with the verdict stored one table over.
  ///
  /// Three guards, each doing its own work. `settle_state = 'done'` because an
  /// UNSETTLED row has no snapshot to correct — it will take one at settle,
  /// from the same predicate, and writing early would only race the settle.
  /// `dropped = 0` because a dropped row's chip is never raised: the feed hides
  /// dropped rows and the tile sums the column, so a chip nobody can see would
  /// only inflate the count. The one-shot backfill already guards this way, and
  /// the two paths have to agree. `needs_you <> ?1` so the RETURNING carries
  /// only rows that CHANGED, the same discipline [clearNeedsYou] keeps: the
  /// caller ticks the bus per row, and a re-verdict that returned the same
  /// answer must not announce itself.
  Future<String?> refreshNeedsYouFlag(
    String source,
    String sourceMessageId, {
    required bool needsYou,
  }) async {
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET needs_you = ?1, updated_at = ?2
WHERE source = ?3 AND source_message_id = ?4 AND settle_state = 'done'
  AND dropped = 0
  AND needs_you <> ?1
RETURNING received_at
''',
      variables: _args([
        needsYou ? 1 : 0,
        _nowIso(),
        source,
        sourceMessageId,
      ]),
    );
    return rows.isEmpty ? null : rows.first.data['received_at'] as String?;
  }

  /// The one-shot catch-up for rows that settled before there was a verdict to
  /// read, and returns the ones it flagged.
  ///
  /// The `needs_you_verdict` column arrived in schema v10 and the settle
  /// snapshot predates it, so every row settled before then took its snapshot
  /// from asks that did not include the verdict — a message the needs-you pass
  /// later judged yes has `needs_you_verdict = 1` and `needs_you = 0`, and
  /// nothing in the app would ever reconcile them. Raise-only: this never
  /// clears a chip, because a 0 here can mean the coordinator decided against
  /// it on grounds this statement cannot see.
  ///
  /// The guards past the verdict are the ones `notifyWorthy` carries plus one
  /// it does not. Thread `done`, the `later` bucket and the attention floor are
  /// the user's loudness control and gate a judged yes like any other ask. The
  /// extra one is the outbound clause: the coordinator settles before any reply
  /// can exist, so `notifyWorthy` never needed it — but a chip raised months
  /// after the fact must not land on a thread the user already answered.
  /// `dropped = 0` keeps a gate cascade out of it: a gated row also carries
  /// `settle_state = 'done'`, and it is dropped, not owed.
  Future<List<({String source, String sourceMessageId, String receivedAt})>>
      backfillNeedsYouFromVerdicts({required double threshold}) =>
          _raiseNeedsYouFromVerdicts(threshold: threshold);

  /// The same raise as [backfillNeedsYouFromVerdicts], for ONE thread — the
  /// thread that has just come out of Later.
  ///
  /// A message that settles while its thread is deferred takes a snapshot of
  /// 0 on the strength of the bucket alone (`notifyWorthy`'s Later clause),
  /// and the snapshot moves afterwards only when the VERDICT moves. Lifting
  /// the bucket moves no verdict, so without this the message comes back to
  /// the inbox with a judged yes one table over and no chip, for good. Same
  /// statement and same guards as the backfill — the thread's own `done`,
  /// its last reply, the floor — so the two paths cannot disagree about what
  /// earns a chip; the `later` clause is still in it and is simply true now.
  Future<List<({String source, String sourceMessageId, String receivedAt})>>
      raiseNeedsYouForThread(
    String source,
    String conversationKey, {
    required double threshold,
  }) =>
          _raiseNeedsYouFromVerdicts(
            threshold: threshold,
            source: source,
            conversationKey: conversationKey,
          );

  Future<List<({String source, String sourceMessageId, String receivedAt})>>
      _raiseNeedsYouFromVerdicts({
    required double threshold,
    String? source,
    String? conversationKey,
  }) async {
    final oneThread = source != null && conversationKey != null;
    final rows = await db.customWriteReturning(
      '''
UPDATE message_progress SET needs_you = 1, updated_at = ?1
WHERE settle_state = 'done' AND needs_you = 0 AND dropped = 0
  ${oneThread ? 'AND source = ?3 AND conversation_key = ?4' : ''}
  AND EXISTS (SELECT 1 FROM messages m
              WHERE m.source = message_progress.source
                AND m.source_message_id = message_progress.source_message_id
                AND m.direction = 'inbound' AND m.needs_you_verdict = 1)
  AND COALESCE((SELECT c.state FROM conversations c
                WHERE c.source = message_progress.source
                  AND c.conversation_key = message_progress.conversation_key),
               '') <> 'done'
  AND COALESCE((SELECT c.last_outbound_at FROM conversations c
                WHERE c.source = message_progress.source
                  AND c.conversation_key = message_progress.conversation_key),
               '') < message_progress.received_at
  AND COALESCE((SELECT ai.bucket FROM conversation_ai ai
                WHERE ai.source = message_progress.source
                  AND ai.conversation_key = message_progress.conversation_key),
               '') <> 'later'
  AND COALESCE((SELECT ai.attention_score FROM conversation_ai ai
                WHERE ai.source = message_progress.source
                  AND ai.conversation_key = message_progress.conversation_key),
               0) >= ?2
RETURNING source, source_message_id, received_at
''',
      variables: _args([
        _nowIso(),
        threshold,
        if (oneThread) source,
        if (oneThread) conversationKey,
      ]),
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

  /// The home screen's tiles: seven over everything received since [sinceIso],
  /// and `needs_you` over all time.
  ///
  /// The seven are a readout of what the app has been DOING, and those numbers
  /// only grow — a lifetime total of processed mail is a number nobody can act
  /// on. Their filters are bounded by the same window, so each tile's number
  /// stays the number of rows under it.
  ///
  /// `needs_you` is the exception because it is not a readout at all: it is a
  /// pile to burn down to zero, and work owed since before last Tuesday is
  /// exactly the work a week would hide.
  ///
  /// ONE statement, which is the whole point: read separately, a message
  /// settling between two queries would land in one number and not the other,
  /// and the tiles would disagree until something reloaded them.
  ///
  /// `stalled` is the same three facts [HomeFeedRow.isStalled] reads, spelled
  /// in SQL: still `pending`, nothing queued or running for the message or
  /// its thread, and no progress write since [stalledBeforeIso]. The cutoff
  /// is BOUND rather than computed here so the tile and the rows under it are
  /// answering at the same instant — a tile that counted three and a list
  /// with two flags on it is a tile nobody believes twice.
  ///
  /// Term for term with the Dart predicate, down to the boundary: `<=` because
  /// the row's own test is `difference(...) >= homeStalledAfter`, and the empty
  /// stamp excluded because an unparseable clock answers FALSE there. A row
  /// with no `updated_at` sorts before every cutoff, and counting it would
  /// accuse the pipeline of a fault on the strength of a column nobody wrote.
  ///
  /// [sources] narrows the same way the feed under the tiles does — the list
  /// column's source chips are one selection, and a tile counting a connector
  /// the table is hiding would be a number nobody can find the rows for. An
  /// empty list is "no connector at all", which is zeros rather than
  /// everything.
  ///
  /// `emails` and `teams` are the TWO EXCEPTIONS, and they are exceptions
  /// because they are the source selector rather than a readout of it. With
  /// the Emails chip down, a Teams tile narrowed by [sources] would read `0`
  /// — a digit that says "no Teams mail" where the truth is "you are not
  /// looking at Teams", and the control a reader would press to find out is
  /// the very tile claiming there is nothing there. So they are scalar
  /// subqueries over the whole window with no source clause at all, and every
  /// other column stays narrowed.
  ///
  /// `urgent` carries `p.dropped = 0` because `homeFilterSql` does: the
  /// urgency column is triage's word about the message and a later drop —
  /// `not_worthy` at the settle pass, an Ignore — never rewrites it, so a
  /// count without the clause would sit above a table that could not show the
  /// rows it counted. Every tile is a promise its filter keeps, and the only
  /// way to keep it is for the two to narrow on the same thing.
  ///
  /// `needs_you` is the one number here that counts THREADS: it is
  /// [_liveNeedsYouThread] — the rail's own rule, bound to the same
  /// [threshold] the rail reads — over the distinct `(source,
  /// conversation_key)` pairs it holds for. The rail says "4" and this tile
  /// has to say "4", so the message-level `SUM(needs_you)` it used to be is
  /// gone: that column is the settle pass's snapshot of one MESSAGE, and a
  /// three-message thread counted three.
  ///
  /// It is a SCALAR SUBQUERY rather than a column of the aggregate, and that
  /// is what lets one statement answer two questions about two spans of time:
  /// the subquery has no [sinceIso] in it. Its joins live inside it: `c` and
  /// `ai` because that is what the [_liveNeedsYouThread] fragment reads, and
  /// `m2` because "kept" is [keptMessageSql], a fact about the MESSAGE. The
  /// outer query carries none of the three, since needs_you was the only
  /// reason they were ever wanted. All three are keyed on the primary key of
  /// the table they join, so none can turn one progress row into two.
  ///
  /// Still one statement, which is still the whole point: read separately, a
  /// thread settling between two queries would land in one number and not the
  /// other.
  Future<HomeMetrics> homeMetrics({
    required String sinceIso,
    required String stalledBeforeIso,
    required double threshold,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const HomeMetrics();
    final places = _placeholders(sources.length);
    final row = await db
        .customSelect(
          '''
SELECT
  (SELECT COUNT(*) FROM message_progress pe
    WHERE pe.received_at >= ? AND pe.source = 'email') AS emails,
  (SELECT COUNT(*) FROM message_progress pt
    WHERE pt.received_at >= ? AND pt.source = 'teams') AS teams,
  COALESCE(SUM(CASE WHEN p.dropped = 0
                      AND p.urgency IN ('urgent', 'high') THEN 1 ELSE 0 END), 0)
    AS urgent,
  COALESCE(SUM(p.dropped), 0) AS dropped,
  (SELECT COUNT(DISTINCT p2.source || char(10) || p2.conversation_key)
     FROM message_progress p2
     JOIN messages m2
       ON m2.source = p2.source AND m2.source_message_id = p2.source_message_id
     LEFT JOIN conversations c
       ON c.source = p2.source AND c.conversation_key = p2.conversation_key
     LEFT JOIN conversation_ai ai
       ON ai.source = p2.source AND ai.conversation_key = p2.conversation_key
    WHERE ${keptMessageSql('m2')} AND p2.source IN ($places)
      AND $_liveNeedsYouThread) AS needs_you,
  COALESCE(SUM(CASE WHEN p.storyline_id IS NOT NULL THEN 1 ELSE 0 END), 0)
    AS storylined,
  COALESCE(SUM(CASE WHEN p.outcome = 'pending' THEN 1 ELSE 0 END), 0)
    AS in_flight,
  COALESCE(SUM(CASE WHEN p.outcome = 'pending' AND p.updated_at <= ?
                      AND p.updated_at <> ''
                      AND NOT $_openWorkExists THEN 1 ELSE 0 END), 0)
    AS stalled,
  COALESCE(SUM(CASE WHEN p.triage_state = 'error' OR p.extract_state = 'error'
                      OR p.storyline_state = 'error' THEN 1 ELSE 0 END), 0)
    AS errored,
  COUNT(*) AS total
FROM message_progress p
WHERE p.received_at >= ? AND p.source IN ($places)
''',
          // In text order, which is the only order sqlite numbers anonymous
          // placeholders in: the two connector subqueries open the SELECT
          // list, so their windows bind FIRST; then the needs-you subquery's
          // sources and threshold; then the stalled cutoff beside it; and only
          // then the WHERE clause's own window and sources. Every outer column
          // is qualified `p.` so no subquery's alias — `pe`, `pt`, `p2`, `c`,
          // `ai` — can be read for it.
          variables: _args([
            sinceIso,
            sinceIso,
            ...sources,
            threshold,
            stalledBeforeIso,
            sinceIso,
            ...sources,
          ]),
        )
        .getSingle();
    return HomeMetrics.fromRow(row.data);
  }

  /// `isNeedsYou` spelled in SQL, over the `conversations c` and
  /// `conversation_ai ai` joins [_homeFeedJoins] already carries.
  ///
  /// Term for term with the Dart predicate the rail partitions on — nothing
  /// deferred to Later, nothing already closed, nothing scoring below the
  /// threshold the volume slider moves, and then a reply owed or an ask
  /// written. Two spellings of one rule, because the rail's count and the
  /// tile's count are the same promise and a reader who sees them disagree
  /// has no way to tell which one lied.
  ///
  /// It is about the THREAD, not the message: every column it reads is on
  /// `conversations` or `conversation_ai`, and `message_progress.needs_you` —
  /// the settle pass's snapshot — is deliberately not among them. The
  /// snapshot is what the row was told at the time; this is what is true now.
  ///
  /// The one `?` is the threshold, and it is the reason every caller returns
  /// its arguments beside its SQL.
  static const String _liveNeedsYouThread = '''
COALESCE(ai.bucket, '') <> 'later'
AND c.state <> 'done'
AND COALESCE(ai.attention_score, 0) >= ?
AND (c.state = 'needs_reply' OR COALESCE(c.cta_text, '') <> '')''';

  /// The WHERE fragment one [HomeFilter] stands for, with no leading `AND`
  /// and never empty — every filter narrows something, so a caller can always
  /// write `WHERE ${homeFilterSql(filter, threshold: t).sql} AND …`.
  ///
  /// The arguments ride back with the SQL rather than being bound by the
  /// caller from memory: one filter carries a placeholder and the rest carry
  /// none, and a caller that had to know which is which would eventually bind
  /// the wrong one. They splice in FIRST, because this fragment opens the
  /// WHERE clause and sqlite numbers anonymous placeholders by where they
  /// appear in the text.
  ///
  /// Public and static because it is a definition rather than a query. The
  /// feed's page read and the live patch ([progressPatchFor]) both bind this
  /// fragment through [_feedNarrowing], so the two cannot drift; the tiles
  /// ([homeMetrics]) mirror it by hand, column by column, and one test walks
  /// every filter to hold them to it. The rail's own copy of the Needs You
  /// rule (`isNeedsYou`, in Dart over a `Conversation`) is the one spelling
  /// that has to stay — see the doc on [_liveNeedsYouThread].
  ///
  /// [HomeFilter.needsYou] is the one filter that counts THREADS. The rail
  /// counts threads, the tile above the table is the same number, and so the
  /// table under it has to be one row per thread — the row that stands for a
  /// thread being its newest message the app kept. Every other filter is
  /// message-level, because every other tile counts messages.
  ///
  /// "Kept" there is [keptMessageSql] on `messages`, read through `m` — the
  /// alias [_homeFeedJoins] already carries — and through a `qm` join of its
  /// own inside the newest-kept subquery. It is a fact about the message the
  /// gate judged, not about the progress row that recorded the judgement, and
  /// two readers say it one way: this filter and [homeMetrics]' needs-you
  /// count.
  ///
  /// [HomeFilter.processed] deliberately includes dropped rows. The tile it
  /// belongs to counts `total − in_flight`, and a filter that showed fewer
  /// rows than the number written above it would be a tile nobody believes
  /// twice — the question is "what has the app finished with", and it has
  /// finished with the newsletters.
  ///
  /// [HomeFilter.errors] names exactly the three stages the errored tile
  /// counts, in the same order, so a tap on that tile lists what it counted.
  ///
  /// `ix_message_progress_visible` leads with `dropped`, so the two
  /// dropped-keyed filters stay equality seeks rather than scans over the
  /// whole table.
  static ({String sql, List<Object?> args}) homeFilterSql(
    HomeFilter filter, {
    required double threshold,
  }) =>
      switch (filter) {
        HomeFilter.fromOthers => (sql: 'p.dropped = 0', args: const []),
        HomeFilter.needsYou => (
            sql: '${keptMessageSql('m')} AND $_liveNeedsYouThread '
                'AND p.received_at = (SELECT MAX(q.received_at) '
                'FROM message_progress q '
                'JOIN messages qm ON qm.source = q.source '
                '  AND qm.source_message_id = q.source_message_id '
                'WHERE q.source = p.source '
                'AND q.conversation_key = p.conversation_key '
                'AND ${keptMessageSql('qm')})',
            args: [threshold],
          ),
        HomeFilter.urgent => (
            sql: "p.dropped = 0 AND p.urgency IN ('urgent', 'high')",
            args: const [],
          ),
        HomeFilter.inFlight => (sql: "p.outcome = 'pending'", args: const []),
        HomeFilter.errors => (
            sql: "(p.triage_state = 'error' "
                "OR p.extract_state = 'error' "
                "OR p.storyline_state = 'error')",
            args: const [],
          ),
        HomeFilter.dropped => (sql: 'p.dropped = 1', args: const []),
        HomeFilter.processed => (
            sql: "p.outcome <> 'pending'",
            args: const [],
          ),
      };

  /// The clause that says a progress row belongs under [filter] as the Inbox
  /// is showing it: the filter's own fragment, the source chips, and the
  /// window when there is one. With no chips up nothing belongs — a bare
  /// `0`, which the live patch's CASE reads as "not admitted" for every row.
  /// (The page read never sees that arm: it answers an empty source list with
  /// an empty page before asking, which saves the round trip.)
  ///
  /// ONE builder for the page read and the live patch, so that "the live path
  /// admits exactly what the page read returns" is a fact about the code's
  /// shape rather than a discipline two methods have to keep. The arguments
  /// come back in text order — the fragment's, then the sources, then the
  /// window — which is the order sqlite binds anonymous placeholders in, and
  /// the reason a caller must splice them before anything it appends.
  static ({String sql, List<Object?> args}) _feedNarrowing(
    HomeFilter filter, {
    required double threshold,
    required List<String> sources,
    String? sinceIso,
  }) {
    if (sources.isEmpty) return (sql: '0', args: const []);
    final narrowing = homeFilterSql(filter, threshold: threshold);
    final sql = StringBuffer(narrowing.sql)
      ..write(' AND p.source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...narrowing.args, ...sources];
    if (sinceIso != null) {
      sql.write(' AND p.received_at >= ?');
      args.add(sinceIso);
    }
    return (sql: sql.toString(), args: args);
  }

  /// One page of the feed, newest first — or oldest first under [ascending].
  ///
  /// Keyset rather than OFFSET, and two literal statements rather than one
  /// with a `? IS NULL OR` cursor: that form defeats the index range scan, and
  /// on a screen someone leaves open all day the difference is the whole
  /// table. The cursor is the previous page's last row — pass both halves or
  /// neither.
  ///
  /// [beforeReceivedAt] and [beforeSourceMessageId] are THE CURSOR, named for
  /// the common direction: "before" under [HomeSort.newest] and "after" under
  /// [ascending], where the compare flips to `>` along with the ORDER BY. One
  /// pair of parameters rather than two, because a page walk asks the same
  /// question in both directions — carry on from the row I am standing on.
  ///
  /// [filter] is the ONE way to ask which rows are wanted; see
  /// [homeFilterSql]. The Archive's Dropped tab passes
  /// [HomeFilter.dropped] and reads it as a list rather than as a search,
  /// because a gate-dropped message never reached the embedder and there is no
  /// vector to ask about it.
  ///
  /// [sinceIso] bounds the read by `received_at`, and the Inbox passes the
  /// tiles' own window under a WINDOWED tile filter and nothing under the
  /// others: the number on such a tile is only the number of rows under it if
  /// both are measured over the same week. Needs You passes none, because the
  /// pile it counts is all time — see [HomeFilterLabel.windowed].
  ///
  /// [threshold] is the attention slider's, and only [HomeFilter.needsYou]
  /// reads it. It defaults to 0 rather than being required because every other
  /// caller — the archive's Dropped tab, a test paging the feed — has no
  /// business knowing the rail's rule exists.
  Future<List<HomeFeedRow>> pageHomeFeed({
    String? beforeReceivedAt,
    String? beforeSourceMessageId,
    int limit = 50,
    HomeFilter filter = HomeFilter.fromOthers,
    String? sinceIso,
    bool ascending = false,
    double threshold = 0,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const [];
    // The narrowing opens the WHERE clause, so its arguments bind before the
    // cursor and the limit appended below — see [_feedNarrowing].
    final (sql: where, args: args) = _feedNarrowing(
      filter,
      threshold: threshold,
      sources: sources,
      sinceIso: sinceIso,
    );
    final order = ascending
        ? 'ORDER BY p.received_at ASC, p.source_message_id ASC'
        : 'ORDER BY p.received_at DESC, p.source_message_id DESC';
    final first = beforeReceivedAt == null || beforeSourceMessageId == null;

    final result = first
        ? await db
            .customSelect(
              '$_homeFeedSelect WHERE $where $order LIMIT ?',
              variables: _args([...args, limit]),
            )
            .get()
        : await db
            .customSelect(
              // The row-value compare is the cursor. sqlite has had it since
              // 3.15 (this app ships its own, and `db_adoption_test` pins
              // 3.35 for RETURNING); the portable spelling is
              //   p.received_at < ?a
              //   OR (p.received_at = ?a AND p.source_message_id < ?b)
              // which sqlite would not turn into one index range scan. It
              // flips to `>` under [ascending] for the same reason the ORDER
              // BY does: a cursor that walked the other way would re-read the
              // page it just handed over.
              '$_homeFeedSelect WHERE $where '
              'AND (p.received_at, p.source_message_id) '
              '${ascending ? '>' : '<'} (?, ?) '
              '$order LIMIT ?',
              variables: _args([
                ...args,
                beforeReceivedAt,
                beforeSourceMessageId,
                limit,
              ]),
            )
            .get();
    return [for (final row in result) HomeFeedRow.fromRow(row.data)];
  }

  /// The feed rows for [keys], as they stand.
  ///
  /// Once the live patch's read; now the single-row explainers' — the message
  /// history and the repair service each ask about one message and want the
  /// same joined shape the table draws. It delegates to [progressPatchFor]
  /// under the default filter and throws the flag away, so there is ONE
  /// spelling of this SELECT and one chunk loop, and a column added to the
  /// projection reaches both readers or neither.
  Future<List<HomeFeedRow>> progressRowsFor(
    List<({String source, String id})> keys,
  ) async {
    final patch = await progressPatchFor(keys, filter: HomeFilter.fromOthers);
    return [for (final entry in patch) entry.row];
  }

  /// The feed rows for [keys], each with whether the filter that is up would
  /// have returned it — the live patch's read.
  ///
  /// The row comes back whatever the flag says, because a row already on the
  /// table is replaced IN PLACE even when it stopped matching: the table never
  /// moves under a reader, and the live path still needs the new bar and the
  /// new outcome to draw. The flag is the one definition of "belongs under
  /// this filter" — the same [homeFilterSql] fragment [pageHomeFeed] reads,
  /// over the same source narrowing and the same window — so the live path and
  /// the page read cannot disagree about a row. A second spelling in Dart is
  /// exactly where they used to drift.
  ///
  /// Under [HomeFilter.needsYou] the flag also answers "is this the thread's
  /// newest kept message", which is the one question a single row cannot
  /// answer about itself — the SQL can, because it can look at the thread.
  /// That does not make an arrival placeable: whether the row it would replace
  /// is still on the table is a question about the LIST, so the notifier keeps
  /// counting arrivals there rather than inserting them.
  ///
  /// Empty [sources] flags every row `false` and still returns them all: no
  /// chip is up, so nothing is admitted, but the rows on the table are still
  /// patched in place.
  ///
  /// Chunked, because a burst is unbounded and sqlite's parameter limit is
  /// not: 200 pairs is 400 parameters, comfortably under the 999 an older
  /// build could be compiled with. The one chunk loop over feed rows —
  /// [progressRowsFor] delegates here.
  Future<List<({HomeFeedRow row, bool admitted})>> progressPatchFor(
    List<({String source, String id})> keys, {
    required HomeFilter filter,
    double threshold = 0,
    String? sinceIso,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (keys.isEmpty) return const [];

    // The SAME clause the page read puts in its WHERE, here inside a CASE so
    // the row comes back whatever the answer is. Built once for every chunk;
    // its arguments open the SELECT list and so bind before the key tuples in
    // the WHERE clause — text order, the only order sqlite knows.
    final (sql: narrowing, args: admitArgs) = _feedNarrowing(
      filter,
      threshold: threshold,
      sources: sources,
      sinceIso: sinceIso,
    );
    final admits = 'CASE WHEN $narrowing THEN 1 ELSE 0 END';

    const chunkSize = 200;
    final patch = <({HomeFeedRow row, bool admitted})>[];
    for (var start = 0; start < keys.length; start += chunkSize) {
      final end = start + chunkSize;
      final chunk = keys.sublist(start, end > keys.length ? keys.length : end);
      final tuples = List.filled(chunk.length, '(?, ?)').join(', ');
      final result = await db
          .customSelect(
            'SELECT $_homeFeedColumns,\n'
            '  $admits AS admitted\n'
            'FROM message_progress p\n'
            '$_homeFeedJoins\n'
            'WHERE (p.source, p.source_message_id) IN (VALUES $tuples)',
            variables: _args([
              ...admitArgs,
              for (final key in chunk) ...[key.source, key.id],
            ]),
          )
          .get();
      patch.addAll([
        for (final row in result)
          (
            row: HomeFeedRow.fromRow(row.data),
            admitted: (row.data['admitted'] as int? ?? 0) != 0,
          ),
      ]);
    }
    return patch;
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

  /// One message's stored vector, or null when it has none — or has one in a
  /// space nothing else compares against.
  ///
  /// The retriever's first question: a message that has already been embedded
  /// carries the vector its own attachments should be searched with, and
  /// asking the embedding server again for a card it has already read is a
  /// round trip that buys nothing.
  ///
  /// The tag guard is the whole reason this is not a bare `SELECT embedding`.
  /// A blob written under an older prefix sits in a different space, and a
  /// nearest-neighbour search across two spaces returns whatever the geometry
  /// happens to say — which is worse than no excerpts at all, because it looks
  /// like an answer. Null sends the caller to re-embed, which self-heals.
  ///
  /// [embedModel] is required rather than defaulted on [semanticSearch]'s
  /// precedent and for its reason: this layer imports nothing above itself, so
  /// the caller names the tag (`EmbeddingsClient.documentModelTag`).
  Future<Uint8List?> messageVectorBlob(
    String source,
    String sourceMessageId, {
    required String embedModel,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT embedding, embed_model FROM message_vectors '
          'WHERE source = ? AND source_message_id = ?',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    if (rows.isEmpty) return null;
    final row = rows.first.data;
    if (row['embed_model'] != embedModel) return null;
    final blob = row['embedding'];
    return blob is Uint8List ? blob : null;
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
  /// Already-queued messages are excluded by the statement too, for the reason
  /// given there: it is what makes [cap] "the next [cap] not-yet-queued
  /// messages, newest first" rather than a ceiling the newest [cap] rows hold
  /// forever.
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
  AND NOT EXISTS (SELECT 1 FROM work_items w
    WHERE w.task_kind = 'embed_message' AND w.source = messages.source
      AND w.entity_id = messages.source_message_id)
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
$_homeFeedJoins
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

  /// The most rowids either word read will carry back into Dart.
  ///
  /// `semanticSearch` caps its `k` at the same number and for the same reason:
  /// every id in the page is bound as a parameter by the read that hydrates it,
  /// and SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is 999. No caller passes
  /// a bigger limit, but `limit` is public on both and a ceiling is cheaper
  /// than a caller who discovers the ceiling.
  static const int _keywordCap = 400;

  /// Escapes what LIKE would otherwise read as a wildcard. The escape
  /// character goes first, or the backslashes the other two rules write would
  /// themselves be escaped a moment later.
  static String _escapeLike(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Feed rows the WORDS of [query] match, best first, or null when the word
  /// index could not be built.
  ///
  /// The other half of a search, and the only half that can see a gate-dropped
  /// message: one the gate threw out never reached the embedder, so no vector
  /// was ever written for it and [semanticSearch] cannot find it however well
  /// it matches — which leaves the one pile a person is most likely to come
  /// looking for unreachable by meaning.
  ///
  /// Null and `const []` are different answers, exactly as [semanticSearch]
  /// separates them: null is "there is nothing to search WITH" (a SQLite built
  /// without FTS5, or the `keywordSearch: false` seam), and an empty list is a
  /// statement about the mailbox.
  ///
  /// [includeDropped] defaults to FALSE — the home table's meaning, since the
  /// results sit where that table was and a search that widened the filter
  /// under them would answer a question nobody asked. The archive passes true.
  ///
  /// Ranked by bm25 with the column weights the index declares (a subject
  /// match beats a body match), and carrying [KeywordHit.coverage] so the
  /// fusion above can discount a row that matched one word of eight.
  Future<List<KeywordHit>?> keywordSearchMessages(
    String query, {
    int limit = SearchTuning.keywordFetch,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (!await _keywordIndex.ensureReady()) return null;
    if (sources.isEmpty) return const [];
    final fts = buildFtsQuery(query);
    // No words in it at all. A blank box must never return the mailbox.
    if (fts == null) return const [];

    // Heal before asking, for [semanticSearch]'s reason: the index is derived,
    // and a message written since the last search is filed by the watermark
    // pass rather than by whoever wrote it.
    await _keywordIndex.backfill();

    // Capped for [semanticSearch]'s reason: every rowid this returns is bound
    // as a parameter twice over — once by the hydrating read, once by each
    // coverage read — and SQLite's default parameter ceiling is 999.
    final matches = await _keywordIndex.match(
      fts.match,
      limit: math.min(limit, _keywordCap),
    );
    if (matches.isEmpty) return const [];

    final ids = [for (final match in matches) match.rowid];

    // One rowid query per term, over THIS page. Coverage is the fraction of
    // the query a row actually contains, and it cannot be read off a bm25
    // score — that number rewards rarity, not completeness.
    final matched = <int, int>{};
    for (final term in fts.terms) {
      for (final rowid in await _keywordIndex.rowidsMatching(
        quoteTerm(term),
        among: ids,
      )) {
        matched[rowid] = (matched[rowid] ?? 0) + 1;
      }
    }

    final where = StringBuffer('WHERE m.rowid IN (${_placeholders(ids.length)})');
    final args = <Object?>[...ids];
    if (!includeDropped) where.write(' AND p.dropped = 0');
    where.write(' AND p.source IN (${_placeholders(sources.length)})');
    args.addAll(sources);

    // [_homeFeedSelect]'s columns over [_homeFeedSelect]'s joins, plus the
    // rowid — spelled out here rather than by widening that constant, because
    // it is the only reader that has a rowid to map back to and the other four
    // would carry a column [HomeFeedRow.fromRow] has no field for.
    final result = await db
        .customSelect(
          '''
SELECT m.rowid AS message_rowid, $_homeFeedColumns
FROM message_progress p
$_homeFeedJoins
$where
''',
          variables: _args(args),
        )
        .get();

    final byRowid = <int, HomeFeedRow>{
      for (final row in result)
        row.data['message_rowid'] as int: HomeFeedRow.fromRow(row.data),
    };

    // Back into the index's order. SQL returned a set; the ranking lives in
    // [matches] and nowhere else.
    return [
      for (final match in matches)
        if (byRowid[match.rowid] case final row?)
          KeywordHit(
            row,
            bm25: match.bm25,
            coverage: fts.terms.isEmpty
                ? 0
                : (matched[match.rowid] ?? 0) / fts.terms.length,
          ),
    ];
  }

  /// Document passages the WORDS of [query] match, best first, or null when
  /// the word index could not be built.
  ///
  /// [keywordSearchMessages] over the second corpus, and it earns its place
  /// beside the vector read for the same reason the message one does: an
  /// invoice number or a person's name is exactly the kind of thing an
  /// embedding is worst at and a word index is best at.
  ///
  /// The digest passage is excluded here rather than at file time, which is
  /// the rule [searchAttachmentChunks] already follows: a search result
  /// promises the document's OWN words, and a digest is a model's summary of
  /// them.
  Future<List<AttachmentChunkHit>?> keywordSearchChunks(
    String query, {
    int limit = SearchTuning.keywordFetch,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (!await _chunkKeywordIndex.ensureReady()) return null;
    if (sources.isEmpty) return const [];
    final fts = buildFtsQuery(query);
    if (fts == null) return const [];

    await _chunkKeywordIndex.backfill();

    final capped = math.min(limit, _keywordCap);
    final matches = await _chunkKeywordIndex.match(fts.match, limit: capped);
    if (matches.isEmpty) return const [];

    final ids = [for (final match in matches) match.rowid];

    final matched = <int, int>{};
    for (final term in fts.terms) {
      for (final id in await _chunkKeywordIndex.rowidsMatching(
        quoteTerm(term),
        among: ids,
      )) {
        matched[id] = (matched[id] ?? 0) + 1;
      }
    }

    final where = StringBuffer('AND c.source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...sources];
    where.write(" AND c.locator != 'digest'");
    if (!includeDropped) where.write(' AND COALESCE(p.dropped, 0) = 0');

    return _hydrateChunkHits(
      [
        for (final match in matches)
          (
            id: match.rowid,
            distance: null,
            bm25: match.bm25,
            coverage: fts.terms.isEmpty
                ? 0.0
                : (matched[match.rowid] ?? 0) / fts.terms.length,
          ),
      ],
      // No model tag: a passage the words found need never have been embedded,
      // and filtering on the tag of an embedding it does not have would hide
      // exactly the documents this pass exists to reach.
      embedModel: null,
      extraWhere: where.toString(),
      extraArgs: args,
      limit: capped,
      // The per-file collapse happens in the fusion, over both passes at once.
      // Doing it here as well would throw away the passage the OTHER pass
      // ranked highest for the same file.
      onePerAttachment: false,
    );
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
  ///
  /// [sources] narrows it for [homeMetrics]' reason: the strip sits over the
  /// same table the chips are filtering, and ranking on a connector that is
  /// switched off would name a storyline whose messages are nowhere on screen.
  Future<List<HotStoryline>> hotStorylines({
    required String sinceIso,
    int limit = 8,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const [];
    final result = await db
        .customSelect(
          '''
SELECT p.storyline_id AS id, s.title AS title,
  COUNT(*) AS message_count, MAX(p.received_at) AS last_at
FROM message_progress p
JOIN storylines s ON s.id = p.storyline_id
WHERE p.storyline_id IS NOT NULL AND p.dropped = 0 AND p.received_at >= ?
  AND p.source IN (${_placeholders(sources.length)})
  AND s.status IN ('suggested', 'active')
GROUP BY p.storyline_id, s.title
ORDER BY message_count DESC, last_at DESC, id ASC
LIMIT ?
''',
          variables: _args([sinceIso, ...sources, limit]),
        )
        .get();
    return [for (final row in result) HotStoryline.fromRow(row.data)];
  }

  /// What the pipeline is doing right now, and what it has just finished.
  ///
  /// THREE reads, and three because they are three tables — the queue, the
  /// messages, and the progress rows — not because three round trips were
  /// cheaper to write. There is no way to ask one statement for all of it
  /// without a union whose branches share no columns.
  ///
  /// The queue read folds `task_kind` onto the stage words through
  /// [PipelinePulse.kindStages]; a kind that is not in that map is not
  /// pipeline work and is skipped rather than counted under its own name.
  ///
  /// Triage comes off `messages.triage_status` because triage has no work row
  /// at all — the queue claims the column directly — so a pulse that read only
  /// `work_items` would report an idle pipeline through the whole of a drain.
  ///
  /// [sinceIso] is compared against `message_progress.updated_at`: what the
  /// pipeline last WROTE, rather than when the message arrived. An empty
  /// [sources] is "no connector at all", which is the empty pulse rather than
  /// every connector.
  Future<PipelinePulse> pipelinePulse({
    required String sinceIso,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (sources.isEmpty) return const PipelinePulse();
    final places = _placeholders(sources.length);

    final queued = <String, int>{};
    final running = <String, int>{};
    void fold(String? stage, String? status, int n) {
      if (stage == null || n == 0) return;
      final into = status == 'processing' ? running : queued;
      into[stage] = (into[stage] ?? 0) + n;
    }

    final work = await db
        .customSelect(
          'SELECT task_kind, status, COUNT(*) AS n FROM work_items '
          "WHERE status IN ('pending', 'processing') "
          'AND source IN ($places) '
          'GROUP BY task_kind, status',
          variables: _args(sources),
        )
        .get();
    for (final row in work) {
      fold(
        PipelinePulse.kindStages[row.data['task_kind'] as String? ?? ''],
        row.data['status'] as String?,
        (row.data['n'] as num?)?.toInt() ?? 0,
      );
    }

    final triage = await db
        .customSelect(
          'SELECT triage_status, COUNT(*) AS n FROM messages '
          "WHERE triage_status IN ('pending', 'processing') "
          'AND source IN ($places) '
          'GROUP BY triage_status',
          variables: _args(sources),
        )
        .get();
    for (final row in triage) {
      fold(
        'triage',
        row.data['triage_status'] as String?,
        (row.data['n'] as num?)?.toInt() ?? 0,
      );
    }

    final row = await db
        .customSelect(
          '''
SELECT
  COALESCE(SUM(CASE WHEN p.outcome = 'done' THEN 1 ELSE 0 END), 0) AS settled,
  COALESCE(SUM(p.dropped), 0) AS dropped,
  COALESCE(SUM(CASE WHEN p.needs_you = 1 AND p.dropped = 0 THEN 1 ELSE 0 END),
           0) AS needs_you
FROM message_progress p
WHERE p.updated_at >= ? AND p.source IN ($places)
''',
          variables: _args([sinceIso, ...sources]),
        )
        .getSingle();
    int at(String column) => (row.data[column] as num?)?.toInt() ?? 0;

    return PipelinePulse(
      queued: queued,
      running: running,
      recentSettled: at('settled'),
      recentDropped: at('dropped'),
      recentNeedsYou: at('needs_you'),
    );
  }

  // ── attachments ──────────────────────────────────────────────────────

  /// How many message ids one `IN` clause carries. sqlite's default parameter
  /// limit is 999 and the hydration below binds a handful besides.
  static const int _attachmentIdChunk = 400;

  /// Writes what came with one message, and leaves everything the pipeline and
  /// the owner wrote alone.
  ///
  /// A re-sync sees the same attachments again — a delta replay, a chat message
  /// read a second time, an edit that added a file — so this is an upsert. What
  /// it updates is exactly the connector's own metadata. It never touches
  /// `text_*`, `digest_*`, `blob_*`, `thumb_path` or `pinned_storyline_id`:
  /// those are what the handlers extracted, what the cache fetched, and what the
  /// user pinned, and none of them get thrown away because a delta page came
  /// round again.
  ///
  /// Two of the metadata rules are worth stating. `name`, `content_type` and
  /// the rest COALESCE, so a later listing that omits a field cannot blank one
  /// already learned. `size` takes `MAX`, because the Teams wire never states a
  /// size and writes 0 for unknown — a plain overwrite would erase a real
  /// number the mail path or a byte fetch had already established.
  ///
  /// [rows] carry the connector's own keys: `attachment_id`, `ordinal`, `kind`,
  /// `name`, `content_type`, `size`, `is_inline`, `content_id`, `source_url`,
  /// `thumbnail_url`, `card_text`, `item_subject`, `item_from`, `item_received`.
  /// A row with no `attachment_id` is skipped rather than written under an
  /// empty key.
  Future<void> upsertAttachments(
    String source,
    String sourceMessageId,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final now = _nowIso();
    await db.transaction(() async {
      for (final row in rows) {
        final attachmentId = row['attachment_id'] as String? ?? '';
        if (attachmentId.isEmpty) continue;
        await db.customUpdate(
          'INSERT INTO attachments '
          '(source, source_message_id, attachment_id, ordinal, kind, name, '
          ' content_type, size, is_inline, content_id, source_url, '
          ' thumbnail_url, card_text, item_subject, item_from, item_received, '
          ' text_status, text_reason, text_truncated, text_chars, '
          ' digest_status, digest_json, blob_path, blob_sha256, '
          ' blob_fetched_at, thumb_path, pinned_storyline_id, '
          ' created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
          " 'pending', NULL, 0, 0, 'pending', NULL, NULL, NULL, NULL, NULL, "
          ' NULL, ?, ?) '
          'ON CONFLICT(source, source_message_id, attachment_id) DO UPDATE SET '
          '  ordinal = excluded.ordinal, '
          '  kind = excluded.kind, '
          '  name = COALESCE(excluded.name, attachments.name), '
          '  content_type = COALESCE(excluded.content_type, '
          '                          attachments.content_type), '
          '  size = MAX(excluded.size, attachments.size), '
          '  is_inline = excluded.is_inline, '
          '  content_id = COALESCE(excluded.content_id, attachments.content_id), '
          '  source_url = COALESCE(excluded.source_url, attachments.source_url), '
          '  thumbnail_url = COALESCE(excluded.thumbnail_url, '
          '                           attachments.thumbnail_url), '
          '  card_text = COALESCE(excluded.card_text, attachments.card_text), '
          '  item_subject = COALESCE(excluded.item_subject, '
          '                          attachments.item_subject), '
          '  item_from = COALESCE(excluded.item_from, attachments.item_from), '
          '  item_received = COALESCE(excluded.item_received, '
          '                           attachments.item_received), '
          '  updated_at = excluded.updated_at',
          variables: _args([
            source,
            sourceMessageId,
            attachmentId,
            (row['ordinal'] as num?)?.toInt() ?? 0,
            row['kind'] as String? ?? 'file',
            row['name'],
            row['content_type'],
            (row['size'] as num?)?.toInt() ?? 0,
            // Both spellings, for the reason `attachmentTextPolicy` gives: a
            // connector map carries a bool and a row carries 0/1, and STRICT
            // rejects the bool.
            row['is_inline'] == true || row['is_inline'] == 1 ? 1 : 0,
            row['content_id'],
            row['source_url'],
            row['thumbnail_url'],
            row['card_text'],
            row['item_subject'],
            row['item_from'],
            row['item_received'],
            now,
            now,
          ]),
        );
      }
    });
  }

  /// One message's attachments, in the order the connector listed them.
  Future<List<Map<String, Object?>>> attachmentsForMessage(
    String source,
    String sourceMessageId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM attachments '
          'WHERE source = ? AND source_message_id = ? '
          'ORDER BY ordinal ASC, attachment_id ASC',
          variables: _args([source, sourceMessageId]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// One message's attachments as the model [Message] carries, which is the
  /// shape every prompt builder reads.
  ///
  /// [loadThread] hydrates a whole thread in one query; a handler that read a
  /// single row with [getMessageRow] has no such hydration and has to ask.
  /// Callers guard on the row's own `has_attachments`, so the ordinary message
  /// costs no query at all.
  Future<List<AttachmentRef>> attachmentRefsFor(
    String source,
    String sourceMessageId, {
    String? conversationKey,
  }) async =>
      [
        for (final row in await attachmentsForMessage(source, sourceMessageId))
          AttachmentRef.fromRow(row, conversationKey: conversationKey),
      ];

  /// Many messages' attachments at once, keyed by message id.
  ///
  /// The whole point is that a thread costs ONE query rather than one per
  /// message: [loadThread] hydrates a hundred-message thread through a single
  /// call here. Ids are chunked so a long thread cannot blow sqlite's
  /// parameter limit.
  ///
  /// [digestedOnly] narrows to attachments the model has actually read, which
  /// is what the recap and the needs-you re-verdict want — an attachment with
  /// no digest has nothing to say to either.
  Future<Map<String, List<Map<String, Object?>>>> attachmentsForMessages(
    String source,
    List<String> ids, {
    bool digestedOnly = false,
  }) async {
    if (ids.isEmpty) return const {};
    final byMessage = <String, List<Map<String, Object?>>>{};
    for (var start = 0; start < ids.length; start += _attachmentIdChunk) {
      final slice = ids.sublist(
        start,
        math.min(start + _attachmentIdChunk, ids.length),
      );
      final result = await db
          .customSelect(
            'SELECT * FROM attachments '
            'WHERE source = ? '
            '  AND source_message_id IN (${_placeholders(slice.length)}) '
            '${digestedOnly ? "AND digest_status = 'done' "
                'AND digest_json IS NOT NULL ' : ''}'
            'ORDER BY source_message_id, ordinal ASC, attachment_id ASC',
            variables: _args([source, ...slice]),
          )
          .get();
      for (final row in result) {
        final id = row.data['source_message_id'] as String? ?? '';
        (byMessage[id] ??= []).add(Map<String, Object?>.from(row.data));
      }
    }
    return byMessage;
  }

  /// The digested attachments for a set of messages.
  ///
  /// A SECOND query rather than a join onto whatever produced [ids]. The recap
  /// window is `recentStorylineMessages`, which is a `LIMIT 12` — joining
  /// attachments onto it would spend that limit on attachments and hand the
  /// recap four messages.
  Future<Map<String, List<Map<String, Object?>>>> digestsForMessages(
    String source,
    List<String> ids,
  ) =>
      attachmentsForMessages(source, ids, digestedOnly: true);

  /// One attachment's row, or null.
  Future<Map<String, Object?>?> attachmentRow(
    String source,
    String sourceMessageId,
    String attachmentId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT * FROM attachments '
          'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
          variables: _args([source, sourceMessageId, attachmentId]),
        )
        .get();
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.data);
  }

  /// The extracted words for one attachment, or null when none were stored.
  Future<String?> attachmentTextOf(
    String source,
    String sourceMessageId,
    String attachmentId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT extracted_text FROM attachment_text '
          'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
          variables: _args([source, sourceMessageId, attachmentId]),
        )
        .get();
    if (result.isEmpty) return null;
    return result.first.data['extracted_text'] as String?;
  }

  /// The sync's answer for a file it will not queue, written on the row so the
  /// panel can say why instead of "still reading" for the life of the mailbox.
  ///
  /// **Only a `pending` row takes it.** A row already read (`done`), or one
  /// already carrying a reason, is never downgraded by a later sighting — a
  /// re-sync, a chat read a second time, a restore — so this is a single
  /// guarded UPDATE, not a transaction: it is safe inside `_ingestChat`'s.
  /// `digest_status` closes with it for the reason `setAttachmentText` gives:
  /// left `pending`, the preview panel's AI segment would say "Still reading
  /// this file…" about a document nothing will ever hand the model — and
  /// nothing else comes back to answer it. (The chip's own `reading…` hint
  /// needs `text_status = 'done'`, which a refused row never has.)
  /// `AttachmentTextHandler` short-circuits only on `done`, so a
  /// refusal recorded here is re-read when Restore lifts the gate and
  /// enqueues the work afresh.
  Future<void> recordAttachmentRefusal(
    String source,
    String sourceMessageId,
    String attachmentId,
    String reason,
  ) async {
    await db.customUpdate(
      "UPDATE attachments SET text_status = 'skipped', text_reason = ?, "
      "digest_status = 'skipped', updated_at = ? "
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ? '
      "AND text_status = 'pending'",
      variables: _args([
        reason,
        _nowIso(),
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// Restore's undo of [recordAttachmentRefusal] for the one refusal Restore
  /// lifts. Only a row refused as `gated` goes back to `pending`; every other
  /// word — `too_large`, `kind_card`, a connector's `gone` — is still true
  /// after the gate opens, and the policy will say it again.
  Future<void> reopenGatedAttachment(
    String source,
    String sourceMessageId,
    String attachmentId,
  ) async {
    await db.customUpdate(
      "UPDATE attachments SET text_status = 'pending', text_reason = NULL, "
      "digest_status = 'pending', updated_at = ? "
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ? '
      "AND text_status = 'skipped' AND text_reason = 'gated'",
      variables: _args([_nowIso(), source, sourceMessageId, attachmentId]),
    );
  }

  /// Records the outcome of trying to read one attachment.
  ///
  /// One transaction over two tables, because a `done` status with no words
  /// behind it would send the chunker looking for text that is not there.
  /// [text] is written only when it is non-empty; a skip leaves whatever an
  /// earlier successful pass stored, which is what makes a re-run of finished
  /// work free rather than destructive.
  ///
  /// [reason] is stored as NULL when empty, the rule `label` takes: the column
  /// means "there is a reason and it is this", never "the reason is nothing".
  ///
  /// **Anything but `done` also closes the digest.** No words means no digest,
  /// ever — and a refused attachment left at `digest_status = 'pending'` would
  /// carry the chip's `reading…` hint for the life of the mailbox, because
  /// nothing else would ever come along to answer it. A `done` leaves the
  /// column alone: the digest handler owns it from there.
  ///
  /// **A wordless skip leaves the count and the cut alone**, for the same
  /// reason it leaves the words alone. A requeue answering `gone`, or a gate
  /// applied after the fact, arrives with no text but does not un-read what an
  /// earlier pass read — and writing `text_chars = 0` there would put a zero on
  /// the chip above a Text segment still rendering forty thousand characters.
  Future<void> setAttachmentText(
    String source,
    String sourceMessageId,
    String attachmentId, {
    required String status,
    String? reason,
    String? text,
    bool truncated = false,
  }) async {
    final now = _nowIso();
    final words = text ?? '';
    await db.transaction(() async {
      if (words.isNotEmpty) {
        await db.customUpdate(
          'INSERT INTO attachment_text '
          '(source, source_message_id, attachment_id, extracted_text, chars, '
          ' fetched_at) VALUES (?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(source, source_message_id, attachment_id) DO UPDATE SET '
          '  extracted_text = excluded.extracted_text, '
          '  chars = excluded.chars, fetched_at = excluded.fetched_at',
          variables: _args([
            source,
            sourceMessageId,
            attachmentId,
            words,
            words.length,
            now,
          ]),
        );
      }
      // A skip that carries no words says nothing about how many there were,
      // so it says nothing: the two columns are left out of the statement
      // entirely rather than written as zeroes.
      final bool keepCount = words.isEmpty && status != 'done';
      await db.customUpdate(
        'UPDATE attachments SET text_status = ?, text_reason = ?, '
        '${keepCount ? '' : '  text_truncated = ?, text_chars = ?, '}'
        '  updated_at = ? '
        "${status == 'done' ? '' : ", digest_status = 'skipped' "}"
        'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
        variables: _args([
          status,
          (reason ?? '').isEmpty ? null : reason,
          if (!keepCount) truncated ? 1 : 0,
          if (!keepCount) words.length,
          now,
          source,
          sourceMessageId,
          attachmentId,
        ]),
      );
    });
  }

  /// What the model made of one document, as encoded JSON.
  Future<void> setAttachmentDigest(
    String source,
    String sourceMessageId,
    String attachmentId, {
    required String status,
    String? digestJson,
  }) async {
    await db.customUpdate(
      'UPDATE attachments SET digest_status = ?, digest_json = ?, '
      '  updated_at = ? '
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
      variables: _args([
        status,
        digestJson,
        _nowIso(),
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// What the message inside an `item` attachment says it is.
  ///
  /// A forwarded message arrives as a file, and the three things a person needs
  /// to recognise it — the subject it had, who sent it, when it arrived — are
  /// inside the wrapper rather than on the row. Both connectors learn them on
  /// the text call, which is why they are written here and not by
  /// [upsertAttachments]: the sync's attachment list has never carried them.
  ///
  /// COALESCE per column, and that is the whole reason this is not three plain
  /// assignments: a later pass that learned nothing must not blank what an
  /// earlier one learned. A text handler re-run answering `gone` knows no
  /// subject, and the subject it does not know is not an empty subject.
  ///
  /// All three null is a no-op, not a write — an ordinary file attachment
  /// reaches this method never having had an inner message to describe.
  Future<void> setAttachmentItem(
    String source,
    String sourceMessageId,
    String attachmentId, {
    String? subject,
    String? from,
    String? received,
  }) async {
    if (subject == null && from == null && received == null) return;
    await db.customUpdate(
      'UPDATE attachments SET '
      '  item_subject = COALESCE(?, item_subject), '
      '  item_from = COALESCE(?, item_from), '
      '  item_received = COALESCE(?, item_received), '
      '  updated_at = ? '
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
      variables: _args([
        subject,
        from,
        received,
        _nowIso(),
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// What the connector learned about a file it only had a url for.
  ///
  /// A link attachment is born `size = 0` and typeless — an Outlook "attach as
  /// link" run states a name and an address and nothing else — so the first
  /// read is where the chip learns `2.3 MB` and the preview learns which cap
  /// applies to it.
  ///
  /// Size only ever GROWS: a later listing stating less than a download
  /// already proved is a listing that was rounding, and a shrinking size would
  /// walk a file back under a cap it had already failed. A type already known
  /// is KEPT, because the connector's own word on a listing beats a guess made
  /// while reading. Both null is a no-op — nearly every attachment reaches
  /// this method having taught it nothing.
  Future<void> setAttachmentResolved(
    String source,
    String sourceMessageId,
    String attachmentId, {
    int? size,
    String? contentType,
  }) async {
    if (size == null && contentType == null) return;
    await db.customUpdate(
      'UPDATE attachments SET '
      '  size = MAX(size, COALESCE(?, size)), '
      '  content_type = COALESCE(content_type, ?), '
      '  updated_at = ? '
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
      variables: _args([
        size,
        contentType,
        _nowIso(),
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// Where the cache put this attachment's bytes and its thumbnail.
  ///
  /// COALESCE per column, so a thumbnail write does not blank the blob path a
  /// separate fetch established. `blob_fetched_at` is stamped only when a blob
  /// path is being written — a thumbnail is not the file.
  Future<void> setAttachmentBlob(
    String source,
    String sourceMessageId,
    String attachmentId, {
    String? blobPath,
    String? blobSha256,
    String? thumbPath,
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'UPDATE attachments SET '
      '  blob_path = COALESCE(?, blob_path), '
      '  blob_sha256 = COALESCE(?, blob_sha256), '
      '  blob_fetched_at = COALESCE(?, blob_fetched_at), '
      '  thumb_path = COALESCE(?, thumb_path), '
      '  updated_at = ? '
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
      variables: _args([
        blobPath,
        blobSha256,
        blobPath == null ? null : now,
        thumbPath,
        now,
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// Forgets where every cached file went, and keeps everything else.
  ///
  /// What Settings' "Clear attachment cache" leaves behind: the metadata a chip
  /// draws, the extracted words, the digests and the pins all survive, because
  /// none of them is a copy of the file — only the four columns naming a path on
  /// this disk are cleared, and the next time somebody opens the attachment it
  /// is fetched again. Distinct from [wipeAll], which deletes the rows outright
  /// because the mailbox they belong to is going.
  Future<void> clearAttachmentBlobs() async {
    await db.customUpdate(
      'UPDATE attachments SET blob_path = NULL, blob_sha256 = NULL, '
      '  blob_fetched_at = NULL, thumb_path = NULL',
    );
  }

  /// Pins one document to a storyline, or unpins it with a null [storylineId].
  ///
  /// The one column on an attachment row a person sets by hand, which is why
  /// [upsertAttachments] never writes it: a re-sync must not un-pin what
  /// somebody chose.
  Future<void> setAttachmentPinned(
    String source,
    String sourceMessageId,
    String attachmentId,
    String? storylineId,
  ) async {
    await db.customUpdate(
      'UPDATE attachments SET pinned_storyline_id = ?, updated_at = ? '
      'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
      variables: _args([
        storylineId,
        _nowIso(),
        source,
        sourceMessageId,
        attachmentId,
      ]),
    );
  }

  /// The documents pinned to one storyline, newest message first.
  ///
  /// A LEFT JOIN rather than an inner one: a pin outlives the message it hangs
  /// off — a wipe of one source, a message dropped from the store — and a
  /// document the user deliberately pinned must not vanish from the pane
  /// because its message did.
  Future<List<Map<String, Object?>>> pinnedAttachmentsForStoryline(
    String storylineId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT a.*, m.conversation_key AS conversation_key, '
          '       m.received_at AS message_received_at '
          'FROM attachments a '
          'LEFT JOIN messages m ON m.source = a.source '
          '  AND m.source_message_id = a.source_message_id '
          'WHERE a.pinned_storyline_id = ? '
          'ORDER BY m.received_at DESC, a.ordinal ASC, a.attachment_id ASC',
          variables: _args([storylineId]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Every document a storyline can show: the files on its threads, plus the
  /// ones somebody pinned to it.
  ///
  /// Two populations, one query. A storyline is a set of threads, so most of
  /// its documents arrive by membership; a pin is the other way in, and it
  /// OUTLIVES membership — the same reason [pinnedAttachmentsForStoryline]
  /// joins messages on the left. A thread dropped from the storyline takes its
  /// files with it, but not the one a person deliberately kept.
  ///
  /// `EXISTS` against `storyline_members` rather than a join, because a join
  /// would multiply an attachment by its memberships and the caller wants each
  /// file once. The OR then makes de-duplication free: a pinned file on a
  /// member thread satisfies both halves and is still one row.
  ///
  /// Inline images are excluded on both halves. This is the Documents list —
  /// a signature graphic in a footer is not a document, and it is not one
  /// because somebody pinned it either.
  ///
  /// Ordered pinned-first, then newest message first: the files a person chose
  /// are the ones they are coming back for, and everything after that is a
  /// timeline. `pinned_storyline_id IS ?` in the ORDER BY is compared against
  /// THIS storyline, so a file pinned to a different one sorts as the ordinary
  /// thread attachment it is here — which is why the id is passed twice. `IS`
  /// and not `=`, because `NULL = ?` is NULL and sqlite sorts NULL below 0: an
  /// `=` would put every file pinned ELSEWHERE above every file pinned nowhere,
  /// whatever their dates, and the timeline would be quietly wrong for exactly
  /// the storylines that share a thread.
  Future<List<Map<String, Object?>>> attachmentsForStoryline(
    String storylineId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT a.*, m.conversation_key AS conversation_key, '
          '       m.received_at AS message_received_at '
          'FROM attachments a '
          'LEFT JOIN messages m ON m.source = a.source '
          '  AND m.source_message_id = a.source_message_id '
          'WHERE a.is_inline = 0 AND ('
          '  EXISTS (SELECT 1 FROM storyline_members sm '
          '          WHERE sm.storyline_id = ? AND sm.source = m.source '
          '            AND sm.conversation_key = m.conversation_key) '
          '  OR a.pinned_storyline_id = ?) '
          'ORDER BY (a.pinned_storyline_id IS ?) DESC, m.received_at DESC, '
          '  a.ordinal ASC, a.attachment_id ASC',
          variables: _args([storylineId, storylineId, storylineId]),
        )
        .get();
    return [for (final row in result) Map<String, Object?>.from(row.data)];
  }

  /// Images, by whichever of the two things the connector said.
  ///
  /// Both halves are needed and neither is enough. Teams states `kind =
  /// 'image'` and often no content type at all; Graph states a content type and
  /// calls everything `file`. Nothing here reads the NAME, unlike
  /// `isImageAttachment` in the widget layer — a `LIKE '%.png'` is a scan, and
  /// this query is paged.
  ///
  /// A link is never a picture, whatever content type rides on it: a
  /// `reference` to a `.png` on a drive points somewhere else, and it files
  /// under Links alone. The three shelves partition the whole one.
  static const String _kindClauseImages =
      "AND (a.kind = 'image' OR (lower(a.content_type) LIKE 'image/%' "
      "  AND a.kind NOT IN ('reference','message_reference','card'))) ";

  /// The three kinds that point somewhere else rather than carrying bytes.
  static const String _kindClauseLinks =
      "AND a.kind IN ('reference','message_reference','card') ";

  /// Everything that is not a picture and not a link.
  ///
  /// The consequence worth stating: a `.png` that Graph reported as
  /// `application/octet-stream` and gave no `image` kind files under Documents
  /// rather than Images. Accepted deliberately — the alternative is reading the
  /// file name in SQL, which cannot use an index, and the reader still finds
  /// the file under All.
  static const String _kindClauseDocuments =
      "AND a.kind NOT IN ('image','reference','message_reference','card') "
      "AND (a.content_type IS NULL OR lower(a.content_type) NOT LIKE 'image/%') ";

  /// Every file the mailbox holds, newest message first — the Files stop.
  ///
  /// An INNER join, unlike the storyline shelf's LEFT one, and the difference
  /// is the whole point of the pane: this list is grouped by DAY and every row
  /// offers a way back into its thread, so a file whose message is gone has
  /// neither a day to file under nor a conversation to open. The storyline
  /// shelf keeps such a file because somebody deliberately pinned it there;
  /// nobody pinned anything here.
  ///
  /// Inline images are excluded and nothing else is: a signature logo is not a
  /// file anybody sent. There is deliberately NO byte-size rule — the
  /// `inlineImageMinBytes` threshold in the widget layer is about inline
  /// pictures, which are already gone, and the store must not import a widget
  /// constant to apply it twice.
  ///
  /// Paged rather than capped, because [FilesKind] narrows in SQL: filtering a
  /// page client-side would leave a "Load more" that sometimes added nothing.
  Future<List<FileRow>> recentAttachments({
    List<String> sources = const ['email', 'teams'],
    FilesKind kind = FilesKind.all,
    int limit = 100,
    int offset = 0,
  }) async {
    if (sources.isEmpty) return const [];
    final kindClause = switch (kind) {
      FilesKind.all => '',
      FilesKind.documents => _kindClauseDocuments,
      FilesKind.images => _kindClauseImages,
      FilesKind.links => _kindClauseLinks,
    };
    final result = await db
        .customSelect(
          'SELECT a.*, m.conversation_key AS conversation_key, '
          '       m.from_name AS from_name, m.from_address AS from_address, '
          '       m.direction AS direction, m.received_at AS received_at, '
          '       m.subject AS subject '
          'FROM attachments a '
          'JOIN messages m ON m.source = a.source '
          '  AND m.source_message_id = a.source_message_id '
          'WHERE a.is_inline = 0 '
          '  AND a.source IN (${_placeholders(sources.length)}) '
          '$kindClause'
          'ORDER BY m.received_at DESC, a.source_message_id DESC, '
          '  a.ordinal ASC, a.attachment_id ASC '
          'LIMIT ? OFFSET ?',
          variables: _args([...sources, limit, offset]),
        )
        .get();
    return [for (final row in result) FileRow.fromRow(row.data)];
  }

  // ── attachment chunks and their index ────────────────────────────────

  /// Replaces one attachment's passages with [chunks], and hands back their
  /// new ids in the order they were given.
  ///
  /// Delete-then-insert rather than a diff, because the chunker is
  /// deterministic: the same text and the same code produce the same
  /// passages, so a retry after a park re-derives exactly what was there and
  /// this is idempotent by construction. What it is NOT is cheap in the index
  /// — vec0 has no foreign key and no cascade, so the rowids of the passages
  /// deleted here stay filed. That is harmless and deliberate: an orphan
  /// rowid hydrates to no row in the join below and is dropped from the
  /// results, and [AttachmentChunkIndex.rebuild] — reached only from
  /// [wipeAll] — is what eventually clears them out.
  ///
  /// Every row is written un-embedded (`embedding` NULL, `dims` 0). The
  /// embedder fills them in one POST at a time, and the index's backfill
  /// deliberately cannot see a row until it has floats.
  Future<List<int>> replaceChunks(
    String source,
    String messageId,
    String attachmentId,
    List<({int seq, String locator, String text})> chunks,
  ) async {
    final now = _nowIso();
    final ids = <int>[];
    await db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM attachment_chunks '
        'WHERE source = ? AND source_message_id = ? AND attachment_id = ?',
        variables: _args([source, messageId, attachmentId]),
      );
      for (final chunk in chunks) {
        final row = await db
            .customSelect(
              'INSERT INTO attachment_chunks '
              '(source, source_message_id, attachment_id, seq, locator, '
              ' chunk_text, chars, embedding, dims, embed_model, embedded_at, '
              ' indexed_at, created_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL, NULL, NULL, ?) '
              'RETURNING id',
              variables: _args([
                source,
                messageId,
                attachmentId,
                chunk.seq,
                chunk.locator,
                chunk.text,
                chunk.text.length,
                now,
              ]),
            )
            .getSingle();
        ids.add(row.data['id'] as int);
      }
    });
    return ids;
  }

  /// Adds one more passage to an attachment, after everything already stored.
  ///
  /// What the digest handler writes its summary through: the digest is a
  /// passage of the document like any other — the one a search for "what is
  /// this file about" should land on — and appending it must not disturb the
  /// numbering [replaceChunks] laid down. The next `seq` is computed IN SQL
  /// inside the transaction, so two writers cannot both read the same maximum.
  Future<int> appendChunk(
    String source,
    String messageId,
    String attachmentId, {
    required String locator,
    required String text,
  }) async {
    final now = _nowIso();
    var id = 0;
    await db.transaction(() async {
      final row = await db
          .customSelect(
            'INSERT INTO attachment_chunks '
            '(source, source_message_id, attachment_id, seq, locator, '
            ' chunk_text, chars, embedding, dims, embed_model, embedded_at, '
            ' indexed_at, created_at) '
            'SELECT ?, ?, ?, '
            '  COALESCE(MAX(seq), -1) + 1, ?, ?, ?, NULL, 0, NULL, NULL, '
            '  NULL, ? '
            'FROM attachment_chunks '
            'WHERE source = ? AND source_message_id = ? AND attachment_id = ? '
            'RETURNING id',
            variables: _args([
              source,
              messageId,
              attachmentId,
              locator,
              text,
              text.length,
              now,
              source,
              messageId,
              attachmentId,
            ]),
          )
          .getSingle();
      id = row.data['id'] as int;
    });
    return id;
  }

  /// Files one passage's vector, and puts the row back on the index's
  /// worklist.
  ///
  /// `indexed_at` is cleared rather than stamped: this method's whole job is
  /// to make a row the backfill can finally see, and stamping it here would
  /// write the float into the table and never into the index.
  Future<void> setChunkEmbedding(
    int id, {
    required Uint8List embedding,
    required int dims,
    required String embedModel,
  }) async {
    await db.customUpdate(
      'UPDATE attachment_chunks SET embedding = ?, dims = ?, '
      '  embed_model = ?, embedded_at = ?, indexed_at = NULL WHERE id = ?',
      variables: _args([embedding, dims, embedModel, _nowIso(), id]),
    );
  }

  /// The passages of one attachment that have no vector yet, in document
  /// order.
  ///
  /// The resume path's worklist. A park on the embedding server leaves the
  /// text and the chunks stored and some tail of them un-embedded; the handler
  /// asks this on its next claim and pays only for what is left.
  Future<List<({int id, String text})>> unembeddedChunks(
    String source,
    String messageId,
    String attachmentId,
  ) async {
    final result = await db
        .customSelect(
          'SELECT id, chunk_text FROM attachment_chunks '
          'WHERE source = ? AND source_message_id = ? AND attachment_id = ? '
          '  AND embedding IS NULL ORDER BY seq',
          variables: _args([source, messageId, attachmentId]),
        )
        .get();
    return [
      for (final row in result)
        (
          id: row.data['id'] as int,
          text: row.data['chunk_text'] as String? ?? '',
        ),
    ];
  }

  /// Files every embedded passage the index has not seen. Returns how many
  /// were attempted.
  Future<int> indexPendingChunks() => _chunkIndex.backfill();

  /// How many of one message's documents the model said ask for something.
  ///
  /// A LIKE over the encoded JSON rather than a JSON1 extract, and that is a
  /// deliberate trade for a guarantee the model already gives:
  /// [AttachmentDigest.toJson] writes all five keys always, and `jsonEncode`
  /// emits them with no spaces, so `"asks":["` is present exactly when the
  /// list has an entry. JSON1 would be the same answer through a function this
  /// build is not obliged to have compiled in. A test pins the encoding.
  Future<int> attachmentsWithAsks(String source, String messageId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM attachments '
          "WHERE source = ? AND source_message_id = ? "
          "  AND digest_status = 'done' AND digest_json IS NOT NULL "
          """  AND digest_json LIKE '%"asks":["%'""",
          variables: _args([source, messageId]),
        )
        .getSingle();
    return (row.data['n'] as num?)?.toInt() ?? 0;
  }

  /// Turns ranked chunk ids into passages with their documents attached, back
  /// in the order they were ranked.
  ///
  /// Shared by three reads because the hydration is the same and only the
  /// scope and the ranking differ. The LEFT JOIN onto `message_progress` is
  /// unconditional so [extraWhere] can carry a dropped filter without a second
  /// shape of query; the LEFT JOIN onto `messages` is left because a pinned
  /// document outlives the message it came on.
  ///
  /// [ranked] carries whatever numbers the pass that produced it has —
  /// a distance from the vector index, a bm25 and a coverage from the word
  /// index, and both when the fusion merges them later. A record rather than
  /// `VecHit` because two of the three callers have no distance to report and
  /// a placeholder distance is a number that would still sort.
  ///
  /// [embedModel] is nullable for that same reason. The vector passes MUST
  /// filter on it — a distance measured against a vector written under another
  /// tag is meaningless and would still rank — where the word pass must not:
  /// a passage the words found need never have been embedded at all.
  ///
  /// Ids that hydrate to nothing are skipped rather than counted: that is
  /// exactly what an orphaned vec0 rowid looks like, and it is how
  /// [replaceChunks] gets away with leaving them behind.
  Future<List<AttachmentChunkHit>> _hydrateChunkHits(
    List<({int id, double? distance, double? bm25, double? coverage})> ranked, {
    required String? embedModel,
    String extraWhere = '',
    List<Object?> extraArgs = const [],
    required int limit,
    bool onePerAttachment = false,
  }) async {
    if (ranked.isEmpty) return const [];
    final ids = [for (final hit in ranked) hit.id];
    final modelWhere = embedModel == null ? '' : 'AND c.embed_model = ?';
    final result = await db
        .customSelect(
          '''
SELECT c.id AS chunk_id, c.seq AS chunk_seq, c.locator AS chunk_locator,
       c.chunk_text AS chunk_text,
       a.*, m.from_name AS from_name, m.direction AS direction,
       m.received_at AS received_at, m.conversation_key AS conversation_key
FROM attachment_chunks c
JOIN attachments a ON a.source = c.source
  AND a.source_message_id = c.source_message_id
  AND a.attachment_id = c.attachment_id
LEFT JOIN messages m ON m.source = c.source
  AND m.source_message_id = c.source_message_id
LEFT JOIN message_progress p ON p.source = c.source
  AND p.source_message_id = c.source_message_id
WHERE c.id IN (${_placeholders(ids.length)}) $modelWhere $extraWhere
''',
          variables: _args([
            ...ids,
            ?embedModel,
            ...extraArgs,
          ]),
        )
        .get();

    final byChunk = <int, Map<String, Object?>>{
      for (final row in result)
        row.data['chunk_id'] as int: Map<String, Object?>.from(row.data),
    };

    // Back into the index's order. SQL returned a set; the ranking lives in
    // [hits] and nowhere else.
    final hits = <AttachmentChunkHit>[];
    final seenDocuments = <String>{};
    for (final hit in ranked) {
      final row = byChunk[hit.id];
      if (row == null) continue;
      if (onePerAttachment) {
        // The NEAREST passage stands for the whole document. Without this a
        // fifty-chunk contract fills the page with itself and the second
        // document never appears.
        final document = '${row['source']}|${row['source_message_id']}'
            '|${row['attachment_id']}';
        if (!seenDocuments.add(document)) continue;
      }
      hits.add(
        AttachmentChunkHit(
          ref: AttachmentRef.fromRow(row),
          chunkId: hit.id,
          seq: (row['chunk_seq'] as num?)?.toInt() ?? 0,
          locator: row['chunk_locator'] as String? ?? '',
          text: row['chunk_text'] as String? ?? '',
          senderName: row['from_name'] as String?,
          outbound: row['direction'] == 'outbound',
          receivedAt: row['received_at'] as String?,
          distance: hit.distance,
          bm25: hit.bm25,
          coverage: hit.coverage,
        ),
      );
      if (hits.length == limit) break;
    }
    return hits;
  }

  /// The passages nearest [query] WITHIN a named scope — a thread's messages,
  /// a storyline's pinned documents, or both.
  ///
  /// The retrieval read: what a reply cites. Null when the index is
  /// unavailable, on [semanticSearch]'s reasoning.
  ///
  /// **Both scopes empty answers `const []` and never the corpus.** A caller
  /// that could not work out which thread it is on must get nothing rather
  /// than the nearest passage in the mailbox — a quote from a stranger's
  /// contract pasted into a reply is the one failure this whole path has to
  /// be incapable of.
  Future<List<AttachmentChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required String source,
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
    int limit = 6,
  }) async {
    if (!await _chunkIndex.ensureReady()) return null;
    if (messageIds.isEmpty && attachmentIds.isEmpty) return const [];

    // Heal before asking, for [semanticSearch]'s reason: a chunk whose index
    // write never landed would otherwise stay unfindable until some unrelated
    // document happened to be read.
    await _chunkIndex.backfill();

    final k = math.min(limit * 4, 400);
    // The scope goes INSIDE the neighbour search, not after it. A corpus-wide
    // KNN filtered afterwards returns the k nearest passages in the MAILBOX
    // that happen to be in scope, which on a mailbox of a few hundred chunks
    // is routinely none of them: a message saying "please see attached" is
    // near every strangers' document at once, and the thread's own contract
    // never makes the shortlist. Scoped, the k nearest are the k nearest
    // within the scope, which is the question that was being asked.
    final (indexScope, indexArgs) = _chunkScope(
      source,
      messageIds,
      attachmentIds,
    );
    final hits = await _chunkIndex.knn(
      query,
      k: k,
      rowidWhere: indexScope,
      rowidArgs: indexArgs,
    );
    if (hits.isEmpty) return const [];

    // The same predicate again on the hydration, belt and braces. It costs one
    // indexed lookup and it means an orphaned vec0 rowid — [replaceChunks]
    // leaves those behind — can never hydrate into a passage from outside the
    // scope.
    final (rowScope, rowArgs) = _chunkScope(
      source,
      messageIds,
      attachmentIds,
      prefix: 'c.',
    );
    return _hydrateChunkHits(
      [
        for (final hit in hits)
          (id: hit.id, distance: hit.distance, bm25: null, coverage: null),
      ],
      embedModel: embedModel,
      extraWhere: 'AND $rowScope',
      extraArgs: rowArgs,
      limit: limit,
    );
  }

  /// The SQL for "this source, and either one of these messages or one of
  /// these documents", with its arguments.
  ///
  /// One builder for three readers — the KNN's rowid subquery, its hydration,
  /// and [hasAttachmentChunks] — because a scope that disagreed with itself
  /// between the guard and the search would be a silent narrowing nobody could
  /// see. [prefix] is the table alias the caller needs (`c.` inside the join,
  /// nothing inside the subquery over `attachment_chunks` itself).
  ///
  /// Each half of the OR is written only when it has values: an empty `IN ()`
  /// is a syntax error, and a caller with neither half must not reach here at
  /// all — the scope would be `source = ?` and that IS the corpus.
  static (String, List<Object?>) _chunkScope(
    String source,
    List<String> messageIds,
    List<String> attachmentIds, {
    String prefix = '',
  }) {
    final scope = StringBuffer();
    final args = <Object?>[source];
    if (messageIds.isNotEmpty) {
      scope.write(
        '${prefix}source_message_id IN (${_placeholders(messageIds.length)})',
      );
      args.addAll(messageIds);
    }
    if (attachmentIds.isNotEmpty) {
      if (scope.isNotEmpty) scope.write(' OR ');
      scope.write(
        '${prefix}attachment_id IN (${_placeholders(attachmentIds.length)})',
      );
      args.addAll(attachmentIds);
    }
    return ('${prefix}source = ? AND ($scope)', args);
  }

  /// Whether anything in this scope has passages at all.
  ///
  /// The cheap read before the expensive one. [AttachmentRetriever] runs on
  /// every draft, and the overwhelming majority of threads have never had a
  /// document on them — so one indexed `LIMIT 1` here saves that thread a
  /// vector read, an index backfill, a KNN and, on a message the embed queue
  /// has not reached yet, a POST to the embedding server.
  ///
  /// An empty scope is false without a query, on [chunkKnn]'s rule: a caller
  /// that cannot say which thread it is on is asking about nothing, not about
  /// everything.
  Future<bool> hasAttachmentChunks(
    String source, {
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
  }) async {
    if (messageIds.isEmpty && attachmentIds.isEmpty) return false;
    final (scope, args) = _chunkScope(source, messageIds, attachmentIds);
    final result = await db
        .customSelect(
          'SELECT 1 FROM attachment_chunks WHERE $scope LIMIT 1',
          variables: _args(args),
        )
        .get();
    return result.isNotEmpty;
  }

  /// The passages nearest [query] anywhere in the mailbox, one per document.
  ///
  /// Home search's half of the chunk index, and the opposite of [chunkKnn] in
  /// scope for the opposite reason: a person typing a phrase they remember
  /// reading is asking about every file they have, and the answer they want is
  /// "this document, here" rather than the same contract nine times.
  ///
  /// Null when the index is unavailable and `const []` when there is nothing
  /// to search, exactly as [semanticSearch] separates them: one is a feature
  /// switched off, the other a statement about the mailbox.
  Future<List<AttachmentChunkHit>?> searchAttachmentChunks(
    Uint8List query, {
    required String embedModel,
    int limit = 6,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (!await _chunkIndex.ensureReady()) return null;
    if (sources.isEmpty) return const [];

    await _chunkIndex.backfill();

    // Eight times the ask rather than four. The collapse to one hit per
    // document is what needs the extra slack: a long spreadsheet can occupy a
    // whole page of neighbours on its own and still be one answer.
    final k = math.min(limit * 8, 400);
    final hits = await _chunkIndex.knn(query, k: k);
    if (hits.isEmpty) return const [];

    final where = StringBuffer('AND c.source IN (${_placeholders(sources.length)})');
    final args = <Object?>[...sources];
    // The digest passage is not a search hit. It is filed as a chunk of its own
    // document so the retrieval side can find "what is this file about", but a
    // search result promises the DOCUMENT'S OWN WORDS — and a digest is a
    // model's summary of them. Showing one would put sentences nobody wrote
    // under a file name, which is the same reason [AttachmentRetriever] drops
    // it before a reply can quote it.
    where.write(" AND c.locator != 'digest'");
    // A gate-dropped message keeps its rows; its documents must not surface in
    // the live search any more than the message does.
    if (!includeDropped) where.write(' AND COALESCE(p.dropped, 0) = 0');

    return _hydrateChunkHits(
      [
        for (final hit in hits)
          (id: hit.id, distance: hit.distance, bm25: null, coverage: null),
      ],
      embedModel: embedModel,
      extraWhere: where.toString(),
      extraArgs: args,
      limit: limit,
      onePerAttachment: true,
    );
  }
}
