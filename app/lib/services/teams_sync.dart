import 'dart:convert';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'attachments/attachment_markers.dart';
import 'attachments/attachment_policy.dart';
import 'conversation_state.dart';
import 'gates.dart';
import 'pipeline_progress.dart';
// One symbol only, and deliberately: `sync_service.dart` also declares a
// top-level `syncFloorDays`, and hauling it into this library beside
// [TeamsSync.syncFloorDays] would leave two names that read alike and mean
// different connectors. The clamp is the one rule both windows must agree on —
// a lookback out of range lands somewhere usable rather than throwing, whether
// it came from the mail setting or this one.
import 'sync_service.dart' show clampLookbackDays;
import 'backend/teams_backend.dart';

/// LEGACY. Nothing writes this any more.
///
/// It marked what a chat message carried instead of a triage decision, back
/// when triage was email-only and every chat was stored `skipped` with this
/// reason. Chats now enter the queue like mail, so the constant survives for
/// exactly two readers: the one-time backfill in [TeamsSync.syncNow] that
/// finds the rows written before the change, and `ExtractHandler`'s tolerance
/// of a straggler that the backfill's window did not reach.
const String teamsSourceGate = 'teams_source';

/// A chat message posted by a bot or a connector rather than a person. Skipped
/// like everything else from Teams, and additionally kept OUT of extraction —
/// the local model has nothing useful to say about a build notification.
const String teamsBotGate = 'auto_generated';

/// A Teams user's stable stand-in for an email address.
///
/// The `messages` table keys a sender by address, and so do `sender_prefs` and
/// the reply-rate query behind the attention score. A Graph user id namespaced
/// this way slots into all three harmlessly: it never collides with a real
/// address, a sender rule set on it applies to exactly that person, and the
/// reply-rate query — which runs per source — simply never sees it.
String teamsAddress(String userId) => 'teams:$userId';

/// Pulls Microsoft Teams 1:1 and group chats into the same conversations the
/// mail sync fills, and nothing else.
///
/// **This class may only be called from something the user did.** Microsoft's
/// terms for the Teams messaging endpoints forbid background polling: a
/// refresh must trace back to a button press or to the app coming back to the
/// foreground after a long enough gap. The inbox's sixty-second poll timer
/// calls `load()` and never reaches here, and there is a test that holds that
/// line — see `teams_poll_test.dart`.
///
/// It is NOT a [MailSync]. The interface exists so the conversations notifier
/// can be handed a stand-in for the mail round trip, and a Teams refresh is a
/// second, separately triggered thing rather than another implementation of
/// the same one.
///
/// Two rules carry over from `sync_service.dart` unchanged, because they are
/// what make a resumable sync correct rather than merely working:
/// - a message is folded into its conversation EXACTLY ONCE, guarded by
///   [MessageStore.hasMessage] asked before the upsert. Graph replays messages
///   across pages and across syncs, and folding one twice would reopen a
///   thread the user had closed.
/// - one chat is one transaction. A failure part way through the chat list
///   leaves every chat before it committed and the failing one untouched, so
///   the next refresh picks up where this one stopped.
class TeamsSync {
  static const String source = 'teams';

  /// The single `sync_state` row this connector owns. Teams has no folders and
  /// no delta cursor; the row exists to record when a sync last finished, which
  /// is what the rail's "Teams updated 4m ago" caption reads.
  static const String folder = 'chats';

  /// How far back a chat list reaches when nobody has said otherwise. The same
  /// two weeks the mail drain defaults to, and for the same reason: enough
  /// context to see what is live without dragging in a year of archive.
  ///
  /// A DEFAULT, not a limit. The user's Teams lookback overrides it through the
  /// resolver this class is built with, and this constant is what a caller that
  /// wired no resolver — every test that does not care, every caller from
  /// before the setting existed — falls back to.
  static const int syncFloorDays = 14;

  /// How many chat messages one refresh may queue for extraction. Lower than
  /// mail's cap: a chat message is a sentence, and a hundred of them is already
  /// half an hour of local model time.
  static const int _extractCap = 100;

  /// Names in an unnamed group chat's title before it becomes "and so on".
  static const int _maxSubjectNames = 3;

  /// The stored snippet's length, matching what a Graph mail delta page hands
  /// back for `bodyPreview`.
  static const int _previewChars = 160;

  final TeamsBackend _teams;
  final MessageStore _store;

  /// Whether Teams may be touched at all — in production, whether the tenant
  /// actually granted `Chat.Read`.
  ///
  /// Asked before the FIRST network call, so a refused consent costs zero
  /// requests rather than a round trip that comes back 403. A tenant that said
  /// no leaves this feature quietly absent, never broken.
  final Future<bool> Function() _canSync;

  final ActivityLog _log;
  final PipelineProgress _progress;

  /// How many days back the user asked their chats to reach. A closure rather
  /// than a value, for the reason [SyncService]'s twin is one: this service is
  /// built once and the preference changes under it, so a pass must use the
  /// setting as it stands when the pass starts rather than as it stood when the
  /// provider was first read. Null means nobody wired one, and answers
  /// [syncFloorDays].
  final int Function()? _lookbackDays;

  TeamsSync(
    this._teams,
    this._store, {
    Future<bool> Function()? canSync,
    ActivityLog? activityLog,
    PipelineProgress? progress,
    this._lookbackDays,
  })  : _canSync = canSync ?? _alwaysAllowed,
        _log = activityLog ?? ActivityLog.disabled(),
        _progress = progress ?? const PipelineProgress.disabled();

  static Future<bool> _alwaysAllowed() async => true;

  /// When the last refresh finished, as an ISO-8601 UTC string, or null when
  /// none ever has.
  Future<String?> get lastSyncedAt =>
      _store.getSyncedAt(folder, source: source);

  /// One pass over the chat list. Silent and free when Teams is unavailable.
  Future<void> syncNow() async {
    if (!await _canSync()) {
      // Recorded rather than returned silently, and safe to record on every
      // call: a Teams refresh only ever happens because the user asked for
      // one, so a tenant without `Chat.Read` gets one row per button press
      // instead of one per poll tick.
      await _log.record(
        'sync_teams',
        status: 'skipped',
        source: source,
        detail: {'reason': 'no_scope'},
      );
      return;
    }

    final sw = Stopwatch()..start();
    try {
      // Computed exactly ONCE per pass, here, before a single chat is read —
      // and before the `synced_at` stamp this pass writes after the loop. The
      // floor leans on that stamp (the vacation rule in [_effectiveFloor]), so
      // a floor read any later in the pass would find `synced_at = now` and
      // quietly collapse into the rolling window.
      final floor = await _effectiveFloor();
      // The marker is read on the same line of sight, one statement later, for
      // the same reason: what it detects is answered by re-fetching chats
      // during the loop, and a marker read after any of that would be racing a
      // write this pass made itself.
      //
      // An empty string reads as no marker at all. A pref is TEXT, and an empty
      // one left comparable would sort below every real floor: widening would
      // never fire again and nothing would ever overwrite it. (The same rule
      // the mail sync applies to its own marker.)
      final storedMarker = await _store.getPref(teamsBootstrapFloorKey);
      final marker =
          (storedMarker == null || storedMarker.isEmpty) ? null : storedMarker;
      // A vacation cannot false-positive as a widen: the marker names the
      // oldest floor ever deliberately drained from, and a `synced_at` stamp is
      // always newer than the floor of the bootstrap that wrote it.
      final widen = marker != null && floor.compareTo(marker) < 0;

      // Once per sync, held in memory. It is the one fact that decides whether
      // a chat message is the user's own, and the account record
      // graph_auth.dart persists is not this file's to extend.
      final myId = await _teams.myUserId();
      final chats = await _teams.listChats();

      var chatsSeen = 0;
      var chatsFetched = 0;
      var newMessages = 0;

      for (final chat in chats) {
        final key = chat['id'] as String?;
        if (key == null || key.isEmpty) continue;
        chatsSeen++;

        final stored = await _store.getConversationRow(source, key);
        final previewAt = _previewTimestamp(chat['lastMessagePreview']);

        // The whole reason the chat list expands its preview: a chat whose
        // newest message is one the store already has costs nothing at all.
        //
        // Bypassed on a widen pass, and it has to be: the store being current
        // about a chat's NEWEST message says nothing about the history behind
        // it, and the quiet chats are exactly the ones a wider window was asked
        // for. Skipping here would leave every one of them unbackfilled
        // forever, because the shortcut would fire again on every later pass.
        if (!widen && _alreadyCurrent(previewAt, stored)) continue;
        // A chat that has been quiet since before the floor and that this app
        // has never seen is history, not backlog.
        if (stored == null &&
            previewAt != null &&
            previewAt.compareTo(floor) < 0) {
          continue;
        }

        final firstSight = stored == null;
        // A chat nobody has stored reaches back to the FLOOR rather than taking
        // one undated page of whatever Graph hands over newest-first: the
        // setting says how far back this app looks, and a first sight that
        // stopped at fifty messages would make that sentence false for exactly
        // the chats a wide window was set for. On a widen pass every chat
        // re-reads from the new floor for the same reason — and the
        // `hasMessage` guard inside the ingest is what keeps the replay of
        // everything in between out of the fold and out of the counts.
        final lastAt = stored?['last_message_at'] as String?;
        final messages = await _teams.chatMessagesSince(
          key,
          widen || lastAt == null || lastAt.isEmpty ? floor : lastAt,
        );
        // Once per chat, ever. Members are what name an unnamed group chat and
        // who the thread header lists, and re-reading them on every refresh
        // would be a request per chat for an answer that almost never changes.
        final members = firstSight
            ? await _teams.chatMembers(key)
            : const <Map<String, dynamic>>[];

        chatsFetched++;
        newMessages += await _ingestChat(
          chat,
          key,
          messages,
          members,
          myId: myId,
          firstSight: firstSight,
          lastReadAt: _viewpointReadAt(chat['viewpoint']),
          backlogCutoff: floor,
          quietBeforeIso: widen ? marker : null,
        );
      }

      // How far back these chats have now been read, written only once every
      // chat in the list has returned. A chat that threw took the whole pass
      // with it before reaching this line, which is the design: the marker
      // still names the old floor, so the next pass detects the same widen and
      // finishes the chats that did not land.
      //
      // A null marker is ADOPTED rather than acted on. A database from before
      // this bookkeeping existed has no record of what it drained, and reading
      // that silence as "never drained anything" would make the first sync
      // after every upgrade re-read every chat for nothing. And the marker only
      // ever moves OLDER — a narrower setting is a preference about what to
      // keep, never a reason to forget history already fetched.
      if (marker == null || floor.compareTo(marker) < 0) {
        await _store.setPref(teamsBootstrapFloorKey, floor);
      }

      await _store.setSyncedAt(folder, _nowIso(), source: source);

      // Chat messages stored before chats joined the triage queue. They are
      // `skipped` for a reason that no longer exists, and nothing else would
      // ever look at them again.
      //
      // BEFORE the enqueue below, which now selects on triage status: a row
      // this flips to `pending` is a row that enqueue picks up in the same
      // pass rather than one refresh later. Self-exhausting — nothing writes
      // [teamsSourceGate] any more, so the next sync flips nothing.
      final repended = await _store.rependGatedTriage(
        source: source,
        gateReason: teamsSourceGate,
        sinceIso: floor,
      );

      // Chat messages the first triage judged before it asked whether a reply
      // is expected. Same position and same reason as the re-pend above: what
      // this flips to `pending` the enqueue below picks up in this pass.
      // Self-exhausting — see [MessageStore.rejudgeStaleTriage].
      final rejudged =
          await _store.rejudgeStaleTriage(source: source, sinceIso: floor);

      // The one-time catch-up for chats stored before ingest wrote
      // `addressed_me`. Null until it runs, so the activity row can tell "ran
      // and found nothing" from "did not run".
      int? backfilled;
      if (await _store.getPref('backfill_addressed_me_teams') == null) {
        backfilled = await _store.backfillTeamsAddressedMe(sinceIso: floor);
        await _store.setPref('backfill_addressed_me_teams', '1');
      }

      // A transient failure — the model server mid-load, two timeouts in a row
      // — must not remove a chat from the AI pipeline forever, exactly as it
      // must not for mail (`sync_service.dart`).
      final revivedTriage = await _store.reviveErroredTriage(source: source);

      // Claims nobody is holding any more, and one more try a day for what
      // exhausted the revival above — both exactly as the mail sync does them
      // (`sync_service.dart`), and both needed here too: a Teams-only session
      // is a session where nothing else would ever look.
      final staleBefore = _isoAgo(staleClaimAfter);
      final reclaimedTriage = await _store.reclaimStaleTriage(
        staleBeforeIso: staleBefore,
        sources: const [source],
      );
      final reclaimedWork = await _store.reclaimStaleWork(
        staleBeforeIso: staleBefore,
      );
      final terminalBefore = _isoAgo(terminalRetryAfter);
      final revivedTerminalTriage = await _store.reviveTerminalTriage(
        olderThanIso: terminalBefore,
        source: source,
      );
      final revivedTerminalWork = await _store.reviveTerminalWork(
        olderThanIso: terminalBefore,
      );

      // The rows the settle race left owing a storyline stage, exactly as the
      // mail sync heals them (`sync_service.dart`). Needed here on its own
      // terms: a Teams-only session runs no mail sync, and the race is not
      // mail-specific — this pass enqueues after its chat loop too.
      final revivedStoryline = await _store.reviveOwedStorylineStages(
        sources: const [source],
      );

      // Extraction, for the chat messages a person actually wrote. `OR IGNORE`
      // makes it idempotent, so it both picks up what just arrived and refills
      // a queue a crash left short.
      //
      // The mail defaults now, because a chat is triaged like mail: the
      // `pending/processing/triaged` filter is what leaves out the bots and
      // the user's own messages, which triage already skipped at ingest.
      final queued = await _store.enqueueExtractBacklog(
        cap: _extractCap,
        sinceIso: floor,
        source: source,
      );

      // And the needs-you verdict, over exactly the rows above — same cap,
      // same window, for the reason [MessageStore.enqueueNeedsYouBacklog]
      // gives. It matters most here: a chat is where the deterministic floor
      // actually fires.
      final queuedNeedsYou = await _store.enqueueNeedsYouBacklog(
        cap: _extractCap,
        sinceIso: floor,
        source: source,
      );

      // And their search vectors, over the same window and the same idempotent
      // insert — a chat is searchable on the same terms mail is.
      await _store.enqueueEmbedBacklog(
        cap: _extractCap,
        sinceIso: floor,
        source: source,
      );

      // Chat ingest freshens discovery exactly as mail ingest does: the sweep
      // reads both connectors, so a chat can now SEED a storyline and not only
      // join one. A requeue rather than an enqueue, so the sweep that ran after
      // the last sync runs again instead of staying `done` forever.
      //
      // The `'email'` is the work row's historical label, not a scope — see
      // [StorylineService._workSource]. Both syncs write the same row, which is
      // right: there is one pool to sweep, and one row for sweeping it.
      await _store.requeueWork('storyline_sweep', 'email', 'sweep');

      await _log.record(
        'sync_teams',
        source: source,
        count: newMessages,
        durationMs: sw.elapsedMilliseconds,
        detail: {
          'chats_seen': chatsSeen,
          'chats_fetched': chatsFetched,
          'queued_extract': queued,
          'queued_needs_you': queuedNeedsYou,
          'revived_triage': revivedTriage,
          // Only when they happened — see `sync_service.dart`.
          if (reclaimedTriage > 0) 'reclaimed_triage': reclaimedTriage,
          if (reclaimedWork > 0) 'reclaimed_work': reclaimedWork,
          if (revivedTerminalTriage > 0)
            'revived_terminal_triage': revivedTerminalTriage,
          if (revivedTerminalWork > 0)
            'revived_terminal_work': revivedTerminalWork,
          if (repended > 0) 'repended_triage': repended,
          if (rejudged > 0) 'rejudged_triage': rejudged,
          if (revivedStoryline > 0) 'revived_storyline': revivedStoryline,
          'backfilled_addressed_me': ?backfilled,
        },
      );
    } catch (e) {
      // The last frame in which the exception object still exists — the caller
      // collapses it into a banner string. Recorded, then rethrown so that
      // banner still appears.
      await _log.record(
        'sync_teams',
        status: 'error',
        source: source,
        durationMs: sw.elapsedMilliseconds,
        detail: {'error': '$e'},
      );
      rethrow;
    }
  }

  /// The user's Teams lookback, or the default when there is not one to be had.
  ///
  /// Every failure answers [syncFloorDays]. The closure reads a Riverpod
  /// container this service does not own, and a container disposed mid-pass
  /// must cost the pass its preference, never the chats — the same rule the
  /// mail sync's resolver follows for the same reason.
  int _resolveLookbackDays() {
    try {
      return clampLookbackDays(_lookbackDays?.call() ?? syncFloorDays);
    } catch (_) {
      return syncFloorDays;
    }
  }

  /// The oldest point this pass will reach.
  ///
  /// The OLDER of the rolling window and the last sync that finished — the
  /// vacation rule. Chat messages that arrived while the app was closed are
  /// unreachable through any shorter floor, and nothing is coming back for
  /// them: the lookback is a preference about how much history to hold, never a
  /// licence to skip what was said while nobody was syncing.
  Future<String> _effectiveFloor() async {
    final rolling = _isoDaysAgo(_resolveLookbackDays());
    final last = await lastSyncedAt;
    if (last == null || last.isEmpty) return rolling;
    return last.compareTo(rolling) < 0 ? last : rolling;
  }

  /// Whether the chat list says this chat has nothing the store lacks.
  ///
  /// Both halves must be known. A chat with no preview timestamp, or one this
  /// app has never stored, is always fetched: guessing "nothing new" from a
  /// missing fact is how a sync silently stops working.
  static bool _alreadyCurrent(String? previewAt, Map<String, Object?>? stored) {
    if (previewAt == null || stored == null) return false;
    final lastMessageAt = stored['last_message_at'] as String?;
    if (lastMessageAt == null || lastMessageAt.isEmpty) return false;
    return previewAt.compareTo(lastMessageAt) <= 0;
  }

  static String? _previewTimestamp(Object? raw) =>
      raw is Map ? raw['createdDateTime'] as String? : null;

  /// How far this user has read the chat, or null when the tenant does not say.
  ///
  /// Null is a real answer and the safe one — see [_isRead] for what it buys.
  static String? _viewpointReadAt(Object? raw) =>
      raw is Map ? raw['lastMessageReadDateTime'] as String? : null;

  /// Stores one chat's messages and folds its conversation, all or nothing.
  /// Returns how many messages were seen for the first time.
  ///
  /// The transaction is what makes the CHAT the unit of resumability — see the
  /// class comment. Every network call this needs has already happened by the
  /// time it starts, and must: the awaits inside are sqlite's own, and a
  /// transaction held open across a Graph call is one held open across a
  /// stalled socket.
  ///
  /// The count is RETURNED rather than recorded here, for the same reason the
  /// mail drain returns its own: an activity row written inside this
  /// transaction would roll back with the chat.
  ///
  /// [backlogCutoff] is the pass's floor, handed down so a message from behind
  /// it is stored `skipped` instead of costing the model seventeen seconds.
  /// [quietBeforeIso] is set only on a widen pass and names the floor the
  /// LAST one reached: everything older than it is history being backfilled
  /// rather than news arriving, and is folded without being allowed to move a
  /// chat's state.
  Future<int> _ingestChat(
    Map<String, dynamic> chat,
    String key,
    List<Map<String, dynamic>> raw,
    List<Map<String, dynamic>> members, {
    required String myId,
    required bool firstSight,
    required String? lastReadAt,
    required String backlogCutoff,
    String? quietBeforeIso,
  }) {
    return _store.db.transaction(() async {
      var newMessages = 0;
      final storedRow = await _store.getConversationRow(source, key);
      final work = _ChatWork.from(storedRow);

      // Asked once per chat, and from two different places on purpose: the
      // roster is fetched only at first sight (a deliberate request budget —
      // see the call site), so every later sync reads the answer back off the
      // participants that first sight stored. A 1:1 chat stores exactly one
      // participant, because the roster is written without the user.
      final oneOnOne = firstSight
          ? members.where((m) {
              final id = m['userId'] as String?;
              return id != null && id.isNotEmpty && id != myId;
            }).length ==
              1
          : _participantCount(storedRow) == 1;

      if (firstSight) {
        for (final member in members) {
          final userId = member['userId'] as String?;
          // Never the user themselves: a thread header lists who is on the
          // other end, exactly as it does for mail.
          if (userId == null || userId.isEmpty || userId == myId) continue;
          work.addParticipant(
            member['displayName'] as String?,
            teamsAddress(userId),
          );
        }
      }

      for (final message in raw) {
        final row = _messageRow(message, key, myId, lastReadAt,
            oneOnOne: oneOnOne, backlogCutoff: backlogCutoff);
        if (row == null) continue;

        final id = row['source_message_id'] as String;
        // Asked before the write, because the fold below must see each message
        // exactly once — see the class comment. The upsert itself still runs.
        final firstSighting = !await _store.hasMessage(source, id);

        final ingested = await _store.upsertMessage(row);

        // On EVERY sighting, not only the first: an edit can add a file to a
        // message the store already has. The upsert preserves everything the
        // handlers and the user wrote, so a re-sight costs a metadata update
        // and nothing else.
        //
        // Chat has no detail step, so this is where the rows are written and
        // the work is queued — the mail path does both inside its detail fetch.
        // Sqlite only: `_ingestChat` runs inside a transaction, and Teams'
        // terms forbid a background fetch, so nothing here reaches the network.
        // The refusal write is one guarded UPDATE for the same reason.
        final attachments = attachmentRows(message);
        if (attachments.isNotEmpty) {
          await _store.upsertAttachments(source, id, attachments);
          final stored = await _store.getMessageRow(source, id);
          if (stored != null) {
            for (final attachment in await _store.attachmentsForMessage(
              source,
              id,
            )) {
              final (eligible, why) = attachmentTextPolicy(stored, attachment);
              if (!eligible) {
                await _store.recordAttachmentRefusal(
                  source,
                  id,
                  attachment['attachment_id'] as String? ?? '',
                  why ?? 'ineligible',
                );
                continue;
              }
              await _store.enqueueWork(
                'attachment_text',
                source,
                attachmentEntityId(
                  id,
                  attachment['attachment_id'] as String? ?? '',
                ),
              );
            }
          }
        }

        // Non-null only when the pipeline had never heard of this message, so
        // a chat read a second time announces nothing. Not awaited because
        // there is nothing to wait for: the tick is a publish onto a stream.
        if (ingested != null) {
          _progress.noteIngest(source, id, receivedAt: ingested);
        }

        if (!firstSighting) continue;
        newMessages++;

        final outbound = row['direction'] == 'outbound';
        final receivedAt = row['received_at'] as String?;

        // A message older than the floor the LAST pass reached is history being
        // backfilled, not a chat waking up: it was already said before every
        // decision the user has made about this thread, so it must not remake
        // any of them. Watermarks and counts still move — the chat's record
        // gets more complete, its state does not change.
        final historical = quietBeforeIso != null &&
            receivedAt != null &&
            receivedAt.compareTo(quietBeforeIso) < 0;

        // A chat the gate throws out AT INSERT — a bot's build notification
        // under [teamsBotGate], a line from behind the sync floor under
        // `backlog` — is history being backfilled, not a chat waking up:
        // nothing will read it, and no thread should be made to ask for a
        // reply to it. Same words as `historical` above, and it folds the
        // same way: watermarks and counts move, state does not.
        //
        // Inbound only, for the mail ingest's reason: an outbound is always
        // `skipped`/`outbound` at insert, and folding on that stamp would
        // stop every reply from settling its chat.
        //
        // No [teamsSourceGate] exemption is needed here. Nothing writes that
        // reason any more — [_messageRow] stamps a bot or defers to
        // `triageStatusOnInsert` — so a live person's chat cannot arrive
        // `skipped` under it, and the rows that carry it are legacy rows the
        // re-pend above is already clearing.
        final gatedAtInsert = !outbound && row['triage_status'] == 'skipped';

        // Asked BEFORE the fold advances the inbound watermark — a reply the
        // user sent from any Teams client resolves the standing ask, exactly
        // as the composer's send path does for a reply sent from here. A
        // historical one answers nothing, whatever its timestamp says: the ask
        // it would be clearing has been on screen since before this window
        // reached back far enough to see it, and a reply from behind that floor
        // is not the one the user is still owed.
        final resolvesAsk =
            !historical && outbound && outboundResolves(work.snapshot, receivedAt);
        work.snapshot = foldMessage(
          work.snapshot,
          outbound: outbound,
          receivedAt: receivedAt,
          preview: row['body_preview'] as String?,
          historical: historical || gatedAtInsert,
        );
        if (resolvesAsk) {
          work.clearCta();
          // And the chip goes with the CTA. A reply the user sent from any
          // Teams client is what takes the thread off the Needs You list;
          // reading it never was.
          await _progress.clearNeedsYou(source, key);
        }
      }

      await _writeConversation(key, work, chat, firstSight: firstSight);
      return newMessages;
    });
  }

  /// How many people a stored chat row lists, defensively. A row that is not
  /// there, or whose `participants_json` will not decode, counts zero — which
  /// reads as "not a 1:1", the quiet answer.
  static int _participantCount(Map<String, Object?>? row) {
    final raw = row?['participants_json'];
    if (raw is! String || raw.isEmpty) return 0;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.length : 0;
    } on FormatException {
      return 0;
    }
  }

  /// One chat message this sync pulled, as a `messages` row.
  ///
  /// Only the direction is this method's own: everything else is
  /// [TeamsSync.messageRow], so a message the app sends itself stores exactly
  /// the columns a message it pulled would.
  Map<String, Object?>? _messageRow(
    Map<String, dynamic> message,
    String key,
    String myId,
    String? lastReadAt, {
    required bool oneOnOne,
    String? backlogCutoff,
  }) {
    final (_, senderId, _) = _sender(message['from']);
    return messageRow(
      message,
      key,
      outbound: senderId != null && senderId == myId,
      lastReadAt: lastReadAt,
      oneOnOne: oneOnOne,
      mentions: mentionedUserIds(message['mentions']),
      myId: myId,
      backlogCutoff: backlogCutoff,
    );
  }

  /// One Graph chat message as a `messages` row, or null when it is not one.
  ///
  /// Graph mixes system events into the same feed — someone joined, the topic
  /// changed, a call ended — and only `messageType: 'message'` is something a
  /// person said.
  ///
  /// **The one place a chat message becomes a row**, called both by this sync
  /// and by the composer's send — which is the point. A reply the app posts is
  /// written locally from what Graph handed back, and if that row disagreed
  /// with the one the next pull would build, the disagreement would live in the
  /// database until somebody noticed a chat behaving unlike every other chat.
  ///
  /// [outbound] is passed rather than derived because the two callers know it
  /// differently: the sync compares the sender against the signed-in user's id,
  /// while the composer knows it wrote the message itself and must not depend
  /// on Graph having echoed a `from` back at all.
  /// [oneOnOne], [mentions] and [myId] are what decide `addressed_me`, and all
  /// three default to "nothing known": the composer's send path passes none of
  /// them, and an outbound row is not addressed to its own author anyway.
  /// [backlogCutoff] defaults the same way and for the same reason — the
  /// composer's message is its own, outbound and now, and is `skipped` as such
  /// whatever window it lands in.
  static Map<String, Object?>? messageRow(
    Map<String, dynamic> message,
    String key, {
    required bool outbound,
    String? lastReadAt,
    bool oneOnOne = false,
    List<String> mentions = const [],
    String? myId,
    String? backlogCutoff,
  }) {
    if (message['messageType'] != 'message') return null;
    final id = message['id'] as String?;
    if (id == null || id.isEmpty) return null;

    final (name, senderId, fromApplication) = _sender(message['from']);
    final bodyText = _bodyText(message['body']);
    // The preview is what a list card and a recap line show, and a marker in
    // either is a token nobody typed. `body_text` KEEPS its markers — the
    // transcript draws a chip where the file sat, and every prompt strips them
    // for itself.
    final previewText = stripAttachmentMarkers(bodyText);
    // A bot never gets the model's time — a build notification has no urgency
    // and asks the reader for nothing — and everything else takes exactly the
    // rule mail takes.
    //
    // The cutoff the sync hands down IS its floor, so in the ordinary case it
    // decides nothing: a bounded fetch asks the server for messages newer than
    // that floor and everything it returns is inside it. It is what keeps that
    // invariant true when something hands over a message from outside — a wire
    // replay, a tenant whose filter came back unapplied, or a widen pass
    // deliberately reading history back in. Such a message is stored, and
    // stored `skipped`: the chat's record gets more complete without costing
    // the local model seventeen seconds per line of it.
    final (triageStatus, gateReason) = fromApplication
        ? ('skipped', teamsBotGate)
        : triageStatusOnInsert(
            outbound: outbound,
            receivedAt: message['createdDateTime'] as String?,
            backlogCutoff: backlogCutoff,
          );

    // A chat message singles the reader out two ways: it was sent to them and
    // nobody else, or it named them. A bot's message computes this the same
    // way and gets the same answer — it is inbound-gated regardless.
    final addressedMe = !outbound &&
        (oneOnOne || (myId != null && mentions.contains(myId)));

    return {
      'source': source,
      'source_message_id': id,
      // The chat IS the thread. Unlike mail there is no separate conversation
      // id to fall back from, and a chat id is already unique.
      'conversation_key': key,
      'direction': outbound ? 'outbound' : 'inbound',
      'from_name': name,
      'from_address': senderId == null ? null : teamsAddress(senderId),
      // A chat message has no subject and inventing one from its first line
      // would put a sentence where every reader expects a title.
      'subject': null,
      'body_text': bodyText,
      'body_preview': previewText.length > _previewChars
          ? previewText.substring(0, _previewChars)
          : previewText,
      'received_at': message['createdDateTime'] as String?,
      'is_read': _isRead(
        message['createdDateTime'] as String?,
        lastReadAt,
        outbound: outbound,
      )
          ? 1
          : 0,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
      'addressed_me': addressedMe ? 1 : 0,
      // Read from the same normalised list [attachmentRows] reads, so the flag
      // on the row and the rows in the attachments table can never disagree.
      'has_attachments':
          (message['attachments'] as List?)?.isNotEmpty == true ? 1 : 0,
    };
  }

  /// One chat message's attachments as `attachments` rows.
  ///
  /// Separate from [messageRow] rather than a key inside it, because the two
  /// have different callers: the composer's send path writes a message row and
  /// has no attachments to write, and the store takes attachments through a
  /// different method anyway.
  ///
  /// Both backends hand over the SAME flat entries — the MCP server sends them
  /// that way and [GraphTeams.attachmentEntries] converts Graph's into it — so
  /// this reads one shape.
  ///
  /// Three fields are decided here rather than taken from the wire. `size` is 0
  /// because a chat attachment never states one; the upsert's `MAX()` lets a
  /// later byte fetch raise it. `is_inline` is set for images, because an image
  /// in a chat body IS inline by definition — it was pasted into the sentence.
  /// `source_url` takes the entry's `content_url`, which for a shared file is
  /// the OneDrive sharing link the bytes are fetched by.
  static List<Map<String, Object?>> attachmentRows(
    Map<String, dynamic> message,
  ) {
    final entries = message['attachments'];
    if (entries is! List || entries.isEmpty) return const [];
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map) continue;
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final kind = entry['kind'] as String? ?? 'other';
      rows.add({
        'attachment_id': id,
        'ordinal': i,
        'kind': kind,
        'name': entry['name'] as String?,
        'content_type': entry['content_type'] as String?,
        'size': 0,
        'is_inline': kind == 'image',
        'content_id': null,
        'source_url': entry['content_url'] as String?,
        'thumbnail_url': entry['thumbnail_url'] as String?,
        'card_text': entry['card_text'] as String?,
      });
    }
    return rows;
  }

  /// Whether one chat message counts as already read.
  ///
  /// Teams keeps read state per CHAT, not per message: the chat carries one
  /// `viewpoint.lastMessageReadDateTime`, and everything at or before it has
  /// been seen. That single timestamp is projected back onto each message here,
  /// which is what lets a chat bold the rail the way an unread mail thread does
  /// — and what makes reading the chat in Teams itself un-bold it here, since
  /// the viewpoint is server truth and arrives on the next pull for free.
  ///
  /// Every uncertain case answers READ, deliberately. A tenant whose chat list
  /// carries no viewpoint, or a timestamp neither Graph nor this app can parse,
  /// gets exactly the behaviour this app had before it read viewpoints at all.
  /// The failure that matters is the other one: a thread called unread on a
  /// guess bolds itself forever, and no amount of opening it helps. It is also
  /// why no migration backfills anything: every Teams row already stored was
  /// written read, which is exactly what this answers for a chat it cannot
  /// place.
  ///
  /// Parsed rather than string-compared, unlike the rest of this file: the two
  /// timestamps come from different Graph properties and need not agree on
  /// fractional-second digits, which is enough to make `<=` on the strings
  /// disagree with `<=` on the instants.
  static bool _isRead(
    String? createdAt,
    String? lastReadAt, {
    required bool outbound,
  }) {
    if (outbound) return true;
    if (createdAt == null || lastReadAt == null) return true;
    final created = DateTime.tryParse(createdAt);
    final read = DateTime.tryParse(lastReadAt);
    if (created == null || read == null) return true;
    return !created.isAfter(read);
  }

  /// `(display name, graph id, sent by an application)`.
  ///
  /// `from.application` non-null is a bot or a connector. Both shapes carry an
  /// id and a display name, and every level of the object can be absent — a
  /// system-adjacent message can arrive with no `from` at all.
  static (String?, String?, bool) _sender(Object? raw) {
    if (raw is! Map) return (null, null, false);
    final user = raw['user'];
    if (user is Map) {
      return (user['displayName'] as String?, user['id'] as String?, false);
    }
    final application = raw['application'];
    if (application is Map) {
      return (
        application['displayName'] as String?,
        application['id'] as String?,
        true,
      );
    }
    return (null, null, false);
  }

  /// The Graph ids a chat message @mentions, in the order they appear.
  ///
  /// Graph nests them three deep — `[{'mentioned': {'user': {'id': …}}}]` —
  /// and every level is checked, because the field can still arrive absent or
  /// malformed: an MCP server older than `mentioned_user_ids`, or a shape
  /// Graph changes under us. Absent means no mention signal and nothing else:
  /// a chat that carries no mentions degrades to the 1:1 half of
  /// [addressed_me] rather than to a wrong answer.
  static List<String> mentionedUserIds(Object? raw) {
    if (raw is! List) return const [];
    final ids = <String>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final mentioned = entry['mentioned'];
      if (mentioned is! Map) continue;
      final user = mentioned['user'];
      if (user is! Map) continue;
      final id = user['id'] as String?;
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// A chat message's body as text. Graph sends `html` for anything with
  /// formatting, a mention, or an emoji, and `text` for the rest.
  static String _bodyText(Object? raw) {
    if (raw is! Map) return '';
    final content = raw['content'] as String?;
    if (content == null || content.isEmpty) return '';
    return raw['contentType'] == 'html'
        ? stripChatHtml(content)
        : content.trim();
  }

  /// Writes the folded conversation, or nothing when no message reached it.
  ///
  /// A chat with only system events, or one whose every message was already
  /// stored, leaves the row exactly as it was — including its `updated_at`.
  Future<void> _writeConversation(
    String key,
    _ChatWork work,
    Map<String, dynamic> chat, {
    required bool firstSight,
  }) async {
    final snapshot = work.snapshot;
    if (snapshot == null) return;

    await _store.upsertConversation({
      'source': source,
      'conversation_key': key,
      // A renamed group chat follows its topic; an unnamed one is named after
      // the people in it, once. Null on a later sync keeps whatever is stored,
      // because the upsert COALESCEs this column.
      'subject': _subjectFor(chat, work, firstSight: firstSight),
      'participants_json': jsonEncode(work.participants),
      'state': snapshot.state,
      // Carried through, not recomputed: the conflict clause overwrites these
      // unconditionally, so passing nulls would erase whatever the AI passes
      // wrote on the last refresh.
      'category': work.category,
      'cta_text': work.ctaText,
      'cta_urgency': work.ctaUrgency,
      // Placeholders — the recompute below is the real write, and no reader
      // sees these: both statements are inside one transaction.
      'message_count': 0,
      'inbound_count': 0,
      'last_inbound_at': snapshot.lastInboundAt,
      'last_outbound_at': snapshot.lastOutboundAt,
      'last_message_at': snapshot.lastMessageAt,
      'last_message_preview': snapshot.lastMessagePreview,
    });
    await _store.recomputeConversationCounts(source, key);
  }

  static String? _subjectFor(
    Map<String, dynamic> chat,
    _ChatWork work, {
    required bool firstSight,
  }) {
    final topic = (chat['topic'] as String?)?.trim();
    if (topic != null && topic.isNotEmpty) return topic;
    if (!firstSight) return null;

    final names = [
      for (final participant in work.participants)
        (participant['name'] as String?) ?? (participant['email'] as String? ?? ''),
    ]..removeWhere((name) => name.isEmpty);
    if (names.isEmpty) return null;
    if (names.length <= _maxSubjectNames) return names.join(', ');
    return '${names.take(_maxSubjectNames).join(', ')}…';
  }
}

/// One chat being folded during an ingest.
///
/// A near-copy of `sync_service.dart`'s `_ConversationWork`, and deliberately
/// not a shared class: the two connectors decide participants completely
/// differently — mail reads them off every message, Teams reads them once from
/// the roster — and the only part they share is the carry-through discipline,
/// which is four fields.
class _ChatWork {
  ConvSnapshot? snapshot;
  final List<Map<String, Object?>> participants;
  final String? category;
  String? ctaText;
  String ctaUrgency;

  _ChatWork({
    this.snapshot,
    required this.participants,
    this.category,
    this.ctaText,
    this.ctaUrgency = 'normal',
  });

  /// The user's reply resolved the chat's standing ask. Mutates rather than
  /// copies because the ingest loop accumulates into one instance per chat.
  void clearCta() {
    ctaText = null;
    ctaUrgency = 'normal';
  }

  /// Seeds from the stored row, or starts empty when the chat is new. The
  /// stored `state` is what carries a human's `done` into the fold.
  factory _ChatWork.from(Map<String, Object?>? row) {
    if (row == null) return _ChatWork(participants: []);
    return _ChatWork(
      snapshot: ConvSnapshot(
        state: row['state'] as String? ?? stateWaiting,
        lastInboundAt: row['last_inbound_at'] as String?,
        lastOutboundAt: row['last_outbound_at'] as String?,
        lastMessageAt: row['last_message_at'] as String?,
        lastMessagePreview: row['last_message_preview'] as String?,
        subject: row['subject'] as String?,
      ),
      participants: _decodeParticipants(row['participants_json']),
      category: row['category'] as String?,
      ctaText: row['cta_text'] as String?,
      ctaUrgency: row['cta_urgency'] as String? ?? 'normal',
    );
  }

  /// A thread header lists who is on it; past a handful the list stops being
  /// readable and starts being a wall. A large group chat is named by its
  /// topic anyway.
  static const int _maxParticipants = 8;

  void addParticipant(String? name, String? address) {
    if (address == null || address.isEmpty) return;
    final key = address.toLowerCase();
    for (final existing in participants) {
      if ((existing['email'] as String?)?.toLowerCase() == key) return;
    }
    if (participants.length >= _maxParticipants) return;
    participants.add({'name': name, 'email': address});
  }

  static List<Map<String, Object?>> _decodeParticipants(Object? raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final entry in decoded)
          if (entry is Map)
            {'name': entry['name'] as String?, 'email': entry['email'] as String?},
      ];
    } on FormatException {
      return [];
    }
  }
}

// ── chat HTML ──────────────────────────────────────────────────────────────
//
// Graph converts mail HTML to text server-side, which is why nothing in this
// app parses mail markup. The chat endpoints offer no equivalent, so this is
// the one place the app does its own stripping — and it is deliberately blunt.
// A chat message is a sentence or two with a mention and a bold word in it,
// not a newsletter, and the wrong answer here costs a stray space rather than
// an unreadable body.

/// `<script>`/`<style>` and everything between them. Vanishingly rare in a
/// chat message and catastrophic when it slips through, since the content
/// between the tags is not text anyone typed.
final RegExp _scriptOrStyle = RegExp(
  r'<(script|style)\b[^>]*>.*?</\1>',
  caseSensitive: false,
  dotAll: true,
);

/// A shared file, as Teams writes it into the body: an empty `<attachment>`
/// tag whose id names an entry in the message's own attachment list.
final RegExp _attachmentTag = RegExp(
  r'<attachment\s+id="([^"]*)"\s*>\s*</attachment\s*>',
  caseSensitive: false,
);

/// A RUN of block boundaries, which is one line break however many tags it
/// took to write.
///
/// The run is the point. Teams wraps every line of a multi-line message in its
/// own `<div>`, so the seam between two lines is `</div><div>` — two tags, one
/// break — and matching them separately would double-space every message in
/// the app. A deliberate blank line (`<div><br></div>`) collapses into the same
/// single break, which is the one thing this loses and is worth losing: a chat
/// message is a sentence or two, and a stray blank line in the preview costs
/// more than the one it preserves.
///
/// `\b` is what keeps `<pre>` out of the `p` alternative; the surrounding
/// `\s*` absorbs the newlines Graph puts between tags, which would otherwise
/// survive as blank lines of their own.
final RegExp _breakRun = RegExp(
  r'(?:\s*(?:<br\s*/?>|</?(?:p|div|li|tr)\b[^>]*>)\s*)+',
  caseSensitive: false,
);

final RegExp _anyTag = RegExp(r'<[^>]*>');

/// Space around a newline, and runs of three or more newlines. Both are what a
/// stripped `<div>` per line leaves behind.
final RegExp _spaceAroundNewline = RegExp(r'[ \t]*\n[ \t]*');
final RegExp _blankRun = RegExp(r'\n{3,}');

/// [html] as the plain text a person typed.
///
/// A `<at>Eric Vance</at>` mention keeps its inner text and loses its tag,
/// which falls out of stripping tags rather than being special-cased: a
/// mention IS the name, and dropping it would remove the one word that says
/// who a message is aimed at.
///
/// Entities are decoded LAST, after every tag is gone. The other order would
/// turn a literal `&lt;b&gt;` a person typed into markup and then delete it.
String stripChatHtml(String? html) {
  if (html == null || html.isEmpty) return '';

  var text = html.replaceAll(_scriptOrStyle, '');

  // Markers FIRST, before any tag stripping, because both forms ARE tags and
  // the strippers below would delete them — which is exactly what used to
  // happen: a message whose whole content was a shared file stored as an empty
  // body, and a pasted screenshot as nothing at all. The marker records where
  // in the sentence the file sat, so the row can draw a chip there and every
  // prompt can take it back out.
  //
  // Still before `_decodeEntities`, which runs last, so a literal `&lt;img …`
  // a person typed cannot be decoded into a tag and then minted into a marker
  // for a file that does not exist.
  text = text.replaceAllMapped(_attachmentTag, (m) => '[[att:${m[1]}]]');
  text = text.replaceAllMapped(hostedImageTag, (m) => '[[img:${m[1]}]]');

  text = text.replaceAll(_breakRun, '\n');
  text = text.replaceAll(_anyTag, '');
  text = _decodeEntities(text);

  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll(_spaceAroundNewline, '\n');
  text = text.replaceAll(_blankRun, '\n\n');
  return text.trim();
}

/// The handful of entities that actually appear in chat HTML. `&amp;` is
/// decoded last so `&amp;lt;` comes out as the literal `&lt;` a person typed
/// rather than as a `<`.
String _decodeEntities(String text) => text
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// Now, as an ISO-8601 UTC timestamp at seconds precision — the shape Graph's
/// own timestamps have, so a plain string comparison IS a chronological one
/// everywhere else in this file.
String _nowIso() => _isoAgo(Duration.zero);

String _isoAgo(Duration ago) {
  final t = DateTime.now().toUtc().subtract(ago);
  final truncated =
      DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  return truncated.toIso8601String().replaceFirst('.000Z', 'Z');
}

/// [days] before now, at UTC midnight — [_isoAgo]'s shape, cut back to the
/// start of the day.
///
/// The settings screen promises chats since a named day, and midnight is what
/// makes that sentence exactly true rather than true to within the hour someone
/// happened to press refresh. It can only ever WIDEN the window, by less than a
/// day, which is the safe direction: a floor that moves earlier cannot lose a
/// message.
String _isoDaysAgo(int days) {
  final t = DateTime.now().toUtc().subtract(Duration(days: days));
  return DateTime.utc(t.year, t.month, t.day)
      .toIso8601String()
      .replaceFirst('.000Z', 'Z');
}
