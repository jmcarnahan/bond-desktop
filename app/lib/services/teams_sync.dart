import 'dart:convert';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'conversation_state.dart';
import 'gates.dart';
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

  /// How far back a chat list that has never synced reaches. The same two
  /// weeks the mail drain uses, and for the same reason: enough context to see
  /// what is live without dragging in a year of archive.
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

  TeamsSync(
    this._teams,
    this._store, {
    Future<bool> Function()? canSync,
    ActivityLog? activityLog,
  })  : _canSync = canSync ?? _alwaysAllowed,
        _log = activityLog ?? ActivityLog.disabled();

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
      final floor = _isoAgo(const Duration(days: syncFloorDays));
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
        if (_alreadyCurrent(previewAt, stored)) continue;
        // A chat that has been quiet since before the floor and that this app
        // has never seen is history, not backlog.
        if (stored == null &&
            previewAt != null &&
            previewAt.compareTo(floor) < 0) {
          continue;
        }

        final firstSight = stored == null;
        final messages = await _teams.chatMessagesSince(
          key,
          stored?['last_message_at'] as String?,
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
        );
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
          'revived_triage': revivedTriage,
          if (repended > 0) 'repended_triage': repended,
          if (rejudged > 0) 'rejudged_triage': rejudged,
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
  Future<int> _ingestChat(
    Map<String, dynamic> chat,
    String key,
    List<Map<String, dynamic>> raw,
    List<Map<String, dynamic>> members, {
    required String myId,
    required bool firstSight,
    required String? lastReadAt,
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
            oneOnOne: oneOnOne);
        if (row == null) continue;

        final id = row['source_message_id'] as String;
        // Asked before the write, because the fold below must see each message
        // exactly once — see the class comment. The upsert itself still runs.
        final firstSighting = !await _store.hasMessage(source, id);

        await _store.upsertMessage(row);
        if (!firstSighting) continue;
        newMessages++;

        final outbound = row['direction'] == 'outbound';

        // A draft answers the message that was newest when the model wrote it.
        // The moment a newer inbound message lands, that draft is a reply to
        // the wrong thing — so it goes, and the enqueue on the next list load
        // writes a fresh one against what the sender actually just said.
        if (!outbound) await _store.deleteDraft(source, key);

        // Asked BEFORE the fold advances the inbound watermark — a reply the
        // user sent from any Teams client resolves the standing ask, exactly
        // as the composer's send path does for a reply sent from here.
        final resolvesAsk = outbound &&
            outboundResolves(work.snapshot, row['received_at'] as String?);
        work.snapshot = foldMessage(
          work.snapshot,
          outbound: outbound,
          receivedAt: row['received_at'] as String?,
          preview: row['body_preview'] as String?,
        );
        if (resolvesAsk) work.clearCta();
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
  static Map<String, Object?>? messageRow(
    Map<String, dynamic> message,
    String key, {
    required bool outbound,
    String? lastReadAt,
    bool oneOnOne = false,
    List<String> mentions = const [],
    String? myId,
  }) {
    if (message['messageType'] != 'message') return null;
    final id = message['id'] as String?;
    if (id == null || id.isEmpty) return null;

    final (name, senderId, fromApplication) = _sender(message['from']);
    final bodyText = _bodyText(message['body']);
    // A bot never gets the model's time — a build notification has no urgency
    // and asks the reader for nothing — and everything else takes exactly the
    // rule mail takes.
    //
    // No backlog cutoff, unlike mail: [syncFloorDays] already bounds how far
    // back a chat message can arrive from, so nothing older than the window
    // reaches here. Mail needs its own cap because a first sync of a real
    // mailbox can hand over a hundred thousand messages at once.
    final (triageStatus, gateReason) = fromApplication
        ? ('skipped', teamsBotGate)
        : triageStatusOnInsert(
            outbound: outbound,
            receivedAt: message['createdDateTime'] as String?,
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
      'body_preview': bodyText.length > _previewChars
          ? bodyText.substring(0, _previewChars)
          : bodyText,
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
    };
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
  /// and every level is checked, because the field is absent altogether on the
  /// wire this app reads today (the MCP server predates it). Absent means no
  /// mention signal and nothing else: a chat that carries no mentions degrades
  /// to the 1:1 half of [addressed_me] rather than to a wrong answer.
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
