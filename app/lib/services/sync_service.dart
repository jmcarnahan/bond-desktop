import 'dart:convert';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'backend/backend_types.dart';
import 'backend/mail_backend.dart';
import 'conversation_state.dart';
import 'gates.dart';
import 'graph_mail.dart';
import 'pipeline_progress.dart';

/// How far back a mailbox that has never synced reaches. Two weeks is enough
/// context to thread the conversations that are actually live without
/// dragging in a year of archive.
const int syncFloorDays = 14;

/// Inbound mail older than this arrives already `skipped`. It still renders;
/// it just never reaches the triage model, which exists to answer "does this
/// need me today?".
const int triageWindowDays = 7;

/// Even inside the triage window, a first sync can land more than a model can
/// chew through. Only the newest this many messages stay queued.
const int firstRunTriageCap = 150;

/// Bodies fetched per [MailSync.ensureBodies] call. A thread longer than this
/// fills in from the newest end down over subsequent opens.
const int _bodyFetchBatch = 20;

/// What the providers depend on, so a test can stand in for the whole Graph
/// round trip without a fake HTTP client.
abstract class MailSync {
  Future<void> syncNow();

  Future<void> ensureBodies(String conversationKey);

  /// One message's body and headers, for a caller that has a message rather
  /// than a thread — the triage worker, which needs the real body to classify
  /// and the headers to gate on, and cannot wait for a human to open the
  /// thread first.
  Future<void> ensureMessageBody(String sourceMessageId);
}

/// Drains Graph's delta feeds into sqlite and folds the result into
/// conversations.
///
/// The drain's crash-safety rule: each page's rows are committed BEFORE the
/// cursor advances. A crash mid-drain therefore replays from the last stored
/// cursor, and the composite-primary-key upsert absorbs the replay. The
/// reverse order would lose whole pages silently, which is the failure this
/// ordering exists to prevent.
class SyncService implements MailSync {
  /// Every call below names its source explicitly rather than leaning on the
  /// store's default. It is the seam a second connector (Teams) copies, and
  /// it should be greppable.
  static const String _source = 'email';

  final MailBackend _mail;
  final MessageStore _store;
  final ActivityLog _log;
  final PipelineProgress _progress;

  /// How to find out which mailbox this is. A callback rather than a future,
  /// so the keychain is read on the first sync rather than when this object is
  /// built: the provider that wires it is read by things that never sync, and
  /// a Future would have to be created — and its read started — at that point.
  final Future<String?> Function()? _userAddressReader;

  /// The resolved address, or null while it is still unknown. Null is a real
  /// state, not a placeholder: until it resolves, nothing can say a message
  /// was addressed to the user, so nothing does.
  String? _userAddress;

  SyncService(
    this._mail,
    this._store, {
    ActivityLog? activityLog,
    PipelineProgress? progress,
    Future<String?> Function()? userAddress,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _progress = progress ?? const PipelineProgress.disabled(),
        _userAddressReader = userAddress;

  @override
  Future<void> syncNow() async {
    _userAddress ??= await _resolveUserAddress();
    final sw = Stopwatch()..start();
    try {
      final (inbox, inboxResync) = await _syncFolder('inbox', 'inbound');
      final (sent, sentResync) = await _syncFolder('sentitems', 'outbound');

      // A transient failure — the model server mid-load, two timeouts in a row
      // — must not remove mail from the AI pipeline forever. Errored rows get
      // another chance on each sync until their attempt ceiling; the enqueue
      // below is `OR IGNORE`, so nothing here double-queues.
      final revivedTriage = await _store.reviveErroredTriage(source: _source);
      final revivedWork = await _store.reviveErroredWork();

      // Claims nobody is holding any more — a queue rebuilt by a backend
      // switch, a process killed mid-drain. Safe to run while a drain is live
      // because a live claim heartbeats every minute and this window is five
      // of them; see [MessageStore.reclaimStaleTriage]. Attempts untouched:
      // nothing about these rows failed.
      final staleBefore = _isoAgo(staleClaimAfter);
      final reclaimedTriage = await _store.reclaimStaleTriage(
        staleBeforeIso: staleBefore,
        sources: const [_source],
      );
      final reclaimedWork = await _store.reclaimStaleWork(
        staleBeforeIso: staleBefore,
      );

      // And one more try a day for what exhausted the revival above. A
      // permanent ceiling is permanent data loss, and most of what reaches it
      // is a local outage that has since healed.
      final terminalBefore = _isoAgo(terminalRetryAfter);
      final revivedTerminalTriage = await _store.reviveTerminalTriage(
        olderThanIso: terminalBefore,
        source: _source,
      );
      final revivedTerminalWork = await _store.reviveTerminalWork(
        olderThanIso: terminalBefore,
      );

      // Mail the first triage judged before it asked whether a reply is
      // expected. BEFORE the enqueue below for the same reason the teams sync
      // orders its re-pend first: a row this flips to `pending` is one the
      // enqueue picks up in the same pass rather than a refresh later.
      // Self-exhausting — see [MessageStore.rejudgeStaleTriage].
      final rejudged = await _store.rejudgeStaleTriage(
        source: _source,
        sinceIso: _isoAgo(const Duration(days: triageWindowDays)),
      );

      // The one-time catch-up for mail stored before ingest wrote
      // `addressed_me`. Skipped WITHOUT setting the pref while the address is
      // unknown, so a keychain that has not answered yet costs a retry next
      // sync rather than the backfill altogether. The count stays null until
      // it runs — "did not run" and "ran and found nothing" are different
      // facts, and the activity row says which.
      int? backfilled;
      final backfillDone =
          await _store.getPref('backfill_addressed_me_email') != null;
      if (!backfillDone && _userAddress != null) {
        backfilled = await _store.backfillEmailAddressedMe(
          userAddress: _userAddress!,
          sinceIso: _isoAgo(const Duration(days: triageWindowDays)),
        );
        await _store.setPref('backfill_addressed_me_email', '1');
      }

      // After both drains, so the window it queues from is the mailbox as it
      // stands rather than as it stood mid-sync. `OR IGNORE` on the work table
      // makes this idempotent, which is what lets it run on every sync: new mail
      // is queued, finished work stays finished, and a queue that a crash left
      // short refills itself without anyone tracking that it did.
      final queued = await _store.enqueueExtractBacklog(
        cap: firstRunTriageCap,
        sinceIso: _isoAgo(const Duration(days: triageWindowDays)),
        source: _source,
      );

      // The per-message search vectors, over the same window and on the same
      // `OR IGNORE` idempotence — new mail is queued, and a backlog that
      // predates the search feature refills itself without anyone asking.
      await _store.enqueueEmbedBacklog(
        cap: firstRunTriageCap,
        sinceIso: _isoAgo(const Duration(days: triageWindowDays)),
        source: _source,
      );

      // The clustering pass over everything not in a storyline yet. One row, not
      // one per thread — there is one mailbox to sweep — and a requeue rather
      // than an enqueue, so the sweep that ran after the last sync runs again
      // after this one instead of staying `done` forever.
      await _store.requeueWork('storyline_sweep', _source, 'sweep');

      await _log.record(
        'sync_mail',
        source: _source,
        count: inbox + sent,
        durationMs: sw.elapsedMilliseconds,
        detail: {
          'inbox': inbox,
          'sent': sent,
          'queued_extract': queued,
          'revived_triage': revivedTriage,
          'revived_work': revivedWork,
          // Only when they happened. A zero here would read as an event where
          // there was none — and, unlike the two counts above, these are the
          // rare paths: a sync that reclaims nothing is every sync.
          if (reclaimedTriage > 0) 'reclaimed_triage': reclaimedTriage,
          if (reclaimedWork > 0) 'reclaimed_work': reclaimedWork,
          if (revivedTerminalTriage > 0)
            'revived_terminal_triage': revivedTerminalTriage,
          if (revivedTerminalWork > 0)
            'revived_terminal_work': revivedTerminalWork,
          if (rejudged > 0) 'rejudged_triage': rejudged,
          'backfilled_addressed_me': ?backfilled,
          if (inboxResync || sentResync) 'resync': true,
        },
      );
    } catch (e) {
      // The last frame in which the exception object still exists: the load
      // that called this collapses it into a banner string. Recorded, then
      // rethrown so that banner still appears.
      await _log.record(
        'sync_mail',
        status: 'error',
        source: _source,
        durationMs: sw.elapsedMilliseconds,
        detail: {'error': '$e'},
      );
      rethrow;
    }
  }

  /// The signed-in address, or null when there is not one to be had.
  ///
  /// Every failure answers null. The address is a keychain read behind a
  /// callback this class did not write, and a locked keychain or a rejected
  /// prompt must cost the mailbox one signal, never the whole sync.
  Future<String?> _resolveUserAddress() async {
    if (_userAddressReader == null) return null;
    try {
      return await _userAddressReader();
    } catch (_) {
      return null;
    }
  }

  /// One folder, including the single permitted recovery from an expired
  /// cursor. Returns `(messages seen for the first time, whether the 410
  /// recovery fired)`.
  Future<(int, bool)> _syncFolder(String folder, String direction) async {
    final storedLink = await _store.getDeltaLink(folder, source: _source);
    final firstRun = storedLink == null;
    var newMessages = 0;
    var resynced = false;

    try {
      newMessages += await _drain(
        folder,
        direction,
        startLink: storedLink,
        minReceivedIso: firstRun ? _isoAgo(const Duration(days: syncFloorDays)) : null,
      );
    } on DeltaResyncRequired {
      // The cursor is older than Graph's change history — which means an
      // unknown stretch of changes is unreachable through it. The only floor
      // that cannot lose mail is the same one a first run uses: anything
      // shorter (a "recovery" window) silently drops whatever arrived between
      // the dead cursor and that window's edge, and nothing ever fetches it
      // again. Ingest is idempotent per page, so re-reading stored mail costs
      // bandwidth once and corrupts nothing.
      await _store.setDeltaLink(folder, null, source: _source);
      resynced = true;
      try {
        // Re-reading stored mail is not "new": firstSighting inside the
        // ingest already keeps the replay out of the count.
        newMessages += await _drain(
          folder,
          direction,
          startLink: null,
          minReceivedIso: _isoAgo(const Duration(days: syncFloorDays)),
        );
      } on DeltaResyncRequired {
        // Twice in one drain is not an expired token, it is a loop.
        throw GraphMailException(
          'Microsoft Graph rejected the mail sync cursor for "$folder" twice '
          'in a row. The next refresh will try again.',
          410,
        );
      }
    }

    // Only the inbox: outbound mail is never queued for triage in the first
    // place, so there is nothing there to cap.
    if (firstRun && folder == 'inbox') {
      await _store.capPendingTriage(firstRunTriageCap, source: _source);
    }
    return (newMessages, resynced);
  }

  /// Walks every page of one delta drain, committing as it goes. Returns how
  /// many messages were seen for the first time.
  Future<int> _drain(
    String folder,
    String direction, {
    required String? startLink,
    required String? minReceivedIso,
  }) async {
    var link = startLink;
    var firstRequest = true;
    var newMessages = 0;

    while (true) {
      final page = await _mail.deltaPage(
        folder,
        link: link,
        // The floor belongs to the first request only. Every link after it
        // is opaque and already carries the query it was born with.
        minReceivedIso: firstRequest ? minReceivedIso : null,
      );
      firstRequest = false;

      newMessages += await _ingestPage(page.messages, direction);

      final next = page.nextLink;
      if (next != null && next.isNotEmpty) {
        // Deliberately NOT persisted: a nextLink is a position inside an
        // unfinished walk, and storing one would let a later drain resume
        // mid-page and never receive the deltaLink that closes it.
        link = next;
        continue;
      }

      final delta = page.deltaLink;
      if (delta != null && delta.isNotEmpty) {
        await _store.setDeltaLink(folder, delta, source: _source);
      }
      return newMessages;
    }
  }

  /// Stores one page's messages and folds their conversations, all or
  /// nothing. Returns how many were seen for the first time.
  ///
  /// The transaction is what makes the page the unit of resumability: a
  /// failure part way through leaves the cursor where it was AND leaves no
  /// half-folded conversation whose counts disagree with its messages. The
  /// count is RETURNED rather than recorded here for the same reason: an
  /// activity row written inside the transaction would roll back with the
  /// page, and one that somehow survived would count messages that never
  /// landed.
  Future<int> _ingestPage(
    List<Map<String, dynamic>> raw,
    String direction,
  ) async {
    if (raw.isEmpty) return 0;
    final outbound = direction == 'outbound';
    final backlogCutoff = _isoAgo(const Duration(days: triageWindowDays));

    return _store.db.transaction(() async {
      var newMessages = 0;
      final work = <String, _ConversationWork>{};

      for (final message in raw) {
        // A deletion tombstone carries no fields to store. The local row is
        // left alone: this app reads mail it has already seen, and a thread
        // vanishing out from under the user mid-read is worse than one
        // lingering a day past its deletion.
        if (message.containsKey('@removed')) continue;

        final id = message['id'] as String?;
        if (id == null || id.isEmpty) continue;
        // A draft is mail that was never sent. It has no place in a thread
        // that is asking whether the user replied.
        if (message['isDraft'] == true) continue;

        final receivedAt = message['receivedDateTime'] as String?;
        final subject = message['subject'] as String?;
        final preview = message['bodyPreview'] as String?;
        final key = conversationKeyFor(
          message['conversationId'] as String?,
          id,
        );

        final (fromName, fromAddress) = _address(message['from']);
        final recipients = _recipients(message['toRecipients']);

        // The user was singled out when they are the ONLY name on the To:
        // line. `recipients` comes from `toRecipients`, so a CC never reaches
        // here — which is the rule, not an accident of the data: mail copied
        // to the user is not mail aimed at them.
        final soleRecipient = _userAddress != null &&
            recipients.length == 1 &&
            recipients.first.toLowerCase() == _userAddress!.toLowerCase();

        final (triageStatus, gateReason) = triageStatusOnInsert(
          outbound: outbound,
          receivedAt: receivedAt,
          backlogCutoff: backlogCutoff,
        );

        // Asked before the write, because the fold below must see each
        // message exactly once. Delta feeds legitimately replay messages —
        // across pages, and wholesale during the 24-hour re-drain a 410
        // forces — and folding one a second time would reopen every thread
        // the user had marked done. The upsert itself still runs: a replay can
        // carry a newer read state.
        final firstSighting = !await _store.hasMessage(_source, id);

        final ingested = await _store.upsertMessage({
          'source': _source,
          'source_message_id': id,
          'internet_message_id': message['internetMessageId'] as String?,
          'conversation_key': key,
          'direction': direction,
          'subject': subject,
          'from_name': fromName,
          'from_address': fromAddress,
          'to_json': jsonEncode(recipients),
          'received_at': receivedAt,
          'is_read': message['isRead'] == true ? 1 : 0,
          'body_preview': preview,
          // Delta pages carry no body and no attachment flag; the detail
          // fetch fills both in later and the upsert will not blank either.
          'body_text': null,
          'has_attachments': 0,
          'triage_status': triageStatus,
          'gate_reason': gateReason,
          'addressed_me': direction == 'inbound' && soleRecipient ? 1 : 0,
        });

        // Non-null only when the pipeline had never heard of this message, so
        // a delta page replaying itself announces nothing. Not awaited because
        // there is nothing to wait for: the tick is a publish onto a stream.
        if (ingested != null) {
          _progress.noteIngest(_source, id, receivedAt: ingested);
        }

        if (!firstSighting) continue;
        newMessages++;

        // Spelled out rather than `putIfAbsent`, which takes a synchronous
        // factory and the seed read is a query now.
        var entry = work[key];
        if (entry == null) {
          entry = _ConversationWork.from(
            await _store.getConversationRow(_source, key),
          );
          work[key] = entry;
        }
        // Asked BEFORE the fold advances the inbound watermark: a reply the
        // user sent anywhere — Outlook, a phone — resolves the ask the CTA
        // was holding, exactly as the composer's own send path does. An
        // outbound older than the newest inbound answers nothing and clears
        // nothing.
        final resolvesAsk =
            outbound && outboundResolves(entry.snapshot, receivedAt);
        entry.snapshot = foldMessage(
          entry.snapshot,
          outbound: outbound,
          receivedAt: receivedAt,
          subject: subject,
          preview: preview,
        );
        if (resolvesAsk) {
          entry.clearCta();
          // And the chip goes with the CTA. A reply the user sent — from here,
          // from Outlook, from a phone — is what takes a thread off the Needs
          // You list; reading it never was.
          await _progress.clearNeedsYou(_source, key);
        }
        // Whoever is on the other end: the sender of mail that came in, the
        // recipients of mail that went out. Never the user.
        if (outbound) {
          for (final address in recipients) {
            entry.addParticipant(null, address);
          }
        } else {
          entry.addParticipant(fromName, fromAddress);
        }
      }

      for (final folded in work.entries) {
        await _writeConversation(folded.key, folded.value);
      }
      return newMessages;
    });
  }

  Future<void> _writeConversation(String key, _ConversationWork entry) async {
    final snapshot = entry.snapshot;
    // Unreachable: an entry exists only because a message was folded into
    // it. Checked rather than forced so a future caller cannot make an empty
    // write silently reset a thread.
    if (snapshot == null) return;
    await _store.upsertConversation({
      'source': _source,
      'conversation_key': key,
      'subject': snapshot.subject,
      'participants_json': jsonEncode(entry.participants),
      'state': snapshot.state,
      // Carried through, not recomputed: the conflict clause overwrites
      // these unconditionally, so passing nulls here would erase whatever
      // the triage worker wrote on the last pass.
      'category': entry.category,
      'cta_text': entry.ctaText,
      'cta_urgency': entry.ctaUrgency,
      // Placeholders — the recompute below is the real write. They are only
      // here because the upsert's column list requires a value, and no
      // reader sees them: both statements are inside one transaction.
      'message_count': 0,
      'inbound_count': 0,
      'last_inbound_at': snapshot.lastInboundAt,
      'last_outbound_at': snapshot.lastOutboundAt,
      'last_message_at': snapshot.lastMessageAt,
      'last_message_preview': snapshot.lastMessagePreview,
    });
    await _store.recomputeConversationCounts(_source, key);
  }

  /// Fills in the bodies of an opened thread, newest first.
  ///
  /// Only messages with nothing stored are fetched, so the second open of a
  /// thread costs one sqlite read and no network at all.
  @override
  Future<void> ensureBodies(String conversationKey) async {
    final thread =
        await _store.loadThread(conversationKey, sources: const [_source]);
    final missing = [
      for (final message in thread)
        if (message.bodyText == null || message.bodyText!.isEmpty) message,
    ]..sort((a, b) => (b.receivedAt ?? '').compareTo(a.receivedAt ?? ''));

    for (final message in missing.take(_bodyFetchBatch)) {
      await _fetchDetailInto(message.id);
    }
  }

  /// The tier-two fetch for one message.
  ///
  /// Everything the triage worker needs that a delta page does not carry: the
  /// unquoted body it classifies from, and the headers its bulk-mail gates
  /// read. Triage calls this per message rather than per thread, which is why
  /// it is factored out of [ensureBodies] rather than living inside its loop.
  @override
  Future<void> ensureMessageBody(String sourceMessageId) =>
      _fetchDetailInto(sourceMessageId);

  /// Fetches one message's detail and stores it. A message that vanished
  /// between the delta page and this call is skipped rather than thrown over:
  /// it must not cost the rest of a thread its bodies, nor park a triage
  /// queue. Anything else is a real failure and belongs on the banner.
  Future<void> _fetchDetailInto(String sourceMessageId) async {
    final Map<String, dynamic> detail;
    try {
      detail = await _mail.getMessageDetail(sourceMessageId);
    } on GraphMailException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 410) return;
      rethrow;
    }

    final uniqueBody = detail['uniqueBody'];
    final bodyText =
        uniqueBody is Map<String, dynamic> ? uniqueBody['content'] as String? : null;
    final headers = _headers(detail['internetMessageHeaders']);

    await _store.updateMessageDetail(
      _source,
      sourceMessageId,
      bodyText: bodyText,
      hasAttachments: detail['hasAttachments'] as bool?,
      // Under a 'headers' key rather than at the top level: source_meta_json
      // is the whole connector-specific blob, and headers are one thing in
      // it.
      sourceMetaJson: headers.isEmpty ? null : jsonEncode({'headers': headers}),
    );
  }

  /// `internetMessageHeaders` as a lowercase-keyed map. Header names are
  /// case-insensitive on the wire and every reader downstream (the phase-4
  /// bulk-mail gates) looks them up by a lowercase literal.
  ///
  /// A repeated header keeps its FIRST occurrence, which for the one that
  /// actually repeats — `Received` — is the most recent hop.
  static Map<String, String> _headers(Object? raw) {
    if (raw is! List) return const {};
    final headers = <String, String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;
      headers.putIfAbsent(name.toLowerCase(), () => entry['value']?.toString() ?? '');
    }
    return headers;
  }

  /// `(name, address)` out of a Graph recipient object, tolerating every
  /// level of it being absent — a message from a mail-enabled system account
  /// can arrive with no `from` at all.
  static (String?, String?) _address(Object? raw) {
    if (raw is! Map) return (null, null);
    final emailAddress = raw['emailAddress'];
    if (emailAddress is! Map) return (null, null);
    return (
      emailAddress['name'] as String?,
      emailAddress['address'] as String?,
    );
  }

  static List<String> _recipients(Object? raw) {
    if (raw is! List) return const [];
    final addresses = <String>[];
    for (final entry in raw) {
      final (_, address) = _address(entry);
      if (address != null && address.isNotEmpty) addresses.add(address);
    }
    return addresses;
  }
}

/// One conversation being folded during a page's ingest.
///
/// It holds the fields the fold owns ([snapshot]) beside the ones it does not
/// but that the store's unconditional-overwrite conflict clause would destroy
/// if they were not carried through.
class _ConversationWork {
  ConvSnapshot? snapshot;
  final List<Map<String, Object?>> participants;
  final String? category;
  String? ctaText;
  String ctaUrgency;

  _ConversationWork({
    this.snapshot,
    required this.participants,
    this.category,
    this.ctaText,
    this.ctaUrgency = 'normal',
  });

  /// The user's reply resolved the thread's standing ask. Mutates rather than
  /// copies because the loop above accumulates into one instance per thread.
  void clearCta() {
    ctaText = null;
    ctaUrgency = 'normal';
  }

  /// Seeds from the stored row, or starts empty when the thread is new. The
  /// stored `state` is what carries a human's `done` into the fold.
  factory _ConversationWork.from(Map<String, Object?>? row) {
    if (row == null) return _ConversationWork(participants: []);
    return _ConversationWork(
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
  /// readable and starts being a wall.
  static const int _maxParticipants = 8;

  void addParticipant(String? name, String? email) {
    if (email == null || email.isEmpty) return;
    final key = email.toLowerCase();
    for (final existing in participants) {
      if ((existing['email'] as String?)?.toLowerCase() == key) {
        // A later message may carry the display name an earlier one lacked.
        if ((existing['name'] as String?)?.isNotEmpty != true &&
            name != null &&
            name.isNotEmpty) {
          existing['name'] = name;
        }
        return;
      }
    }
    if (participants.length >= _maxParticipants) return;
    participants.add({'name': name, 'email': email});
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

/// An ISO-8601 UTC timestamp [ago] before now, at seconds precision.
///
/// Seconds, not milliseconds: this string goes into a `$filter` and is
/// compared against Graph's own `receivedDateTime`, which has no fractional
/// part. Matching the shape is what lets a plain string comparison stand in
/// for a date comparison everywhere else in this file.
String _isoAgo(Duration ago) {
  final t = DateTime.now().toUtc().subtract(ago);
  final truncated =
      DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  return truncated.toIso8601String().replaceFirst('.000Z', 'Z');
}
