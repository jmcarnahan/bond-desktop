import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/message_models.dart' show localEchoPrefix;
import 'activity_log.dart';
import 'attachments/attachment_policy.dart';
import 'attachments/owa_links.dart';
import 'attention.dart';
import 'backend/backend_types.dart';
import 'backend/mail_backend.dart';
import 'conversation_state.dart';
import 'gates.dart';
import 'graph_mail.dart';
import 'mail_text.dart';
import 'pipeline_progress.dart';

/// How far back a mailbox that has never synced reaches. Two weeks is enough
/// context to thread the conversations that are actually live without
/// dragging in a year of archive.
const int syncFloorDays = 14;

/// The range a user may choose that floor from. A day is the shortest window
/// that still means "recent mail" on a machine that syncs once a morning; a
/// year is where a mailbox stops being an inbox and starts being an archive,
/// and where a first drain stops finishing in a sitting. Clamped rather than
/// rejected: a stored value from outside the range — hand-edited, or written
/// by a build that meant something else — must land somewhere usable, never
/// throw and never leave the window at nothing.
const int minLookbackDays = 1;
const int maxLookbackDays = 365;
int clampLookbackDays(int days) => days.clamp(minLookbackDays, maxLookbackDays);

/// How many backlog rows one enqueue pass files per queue. A pace rather than
/// a truncation: the enqueue skips messages that already have a work row, so
/// each sync files the next batch of not-yet-queued mail, newest first, and a
/// deep window drains over several passes instead of being cut down to its
/// newest this-many forever.
const int backlogEnqueueCap = 150;

/// How far back the reconcile re-enumerates, and how often it does it.
///
/// The delta feed is trusted for POSITION and has still been seen to skip a
/// message — two of nine inbound on one day, both of them present in a fresh
/// enumeration hours later, with no cause anyone could name. So a second pass
/// asks the plain question the cursor cannot: what is in the last day of this
/// folder? A day is far enough back that a skipped message is still inside it
/// by the time anyone notices, and ten minutes apart is cheap — two requests,
/// usually one empty page each — while bounding how late such a message can
/// arrive. The cursor itself is never touched: this is a safety net beside the
/// delta feed, not a replacement for it.
const Duration reconcileWindow = Duration(hours: 24);
const Duration reconcileEvery = Duration(minutes: 10);

/// When the last reconcile finished, as a UTC ISO stamp. A preference rather
/// than a field, because the cadence has to survive the app being closed: a
/// service rebuilt on every launch would otherwise reconcile on every launch.
const String mailLastReconcileKey = 'mail_last_reconcile';

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

  /// How many days back the user asked this mailbox to reach. A closure rather
  /// than a value, for the reason [_userAddressReader] is one: this service is
  /// built once and the preference changes under it, and a sync must use the
  /// setting as it stands when the pass starts rather than as it stood when
  /// the provider was first read. Null means nobody wired one — every test
  /// that does not care, and every caller from before the setting existed —
  /// and answers [syncFloorDays].
  final int Function()? _lookbackDays;

  /// The user's attention floor, for the one-shot backfill below. A callback
  /// for [_lookbackDays]'s reason — the slider moves under a service built
  /// once — and null for every caller that predates the backfill, which then
  /// judges history against [AttentionTuning.defaultThreshold].
  final Future<double> Function()? _threshold;

  SyncService(
    this._mail,
    this._store, {
    ActivityLog? activityLog,
    PipelineProgress? progress,
    Future<String?> Function()? userAddress,
    Future<double> Function()? attentionThreshold,
    this._lookbackDays,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _progress = progress ?? const PipelineProgress.disabled(),
        _userAddressReader = userAddress,
        _threshold = attentionThreshold;

  /// The settle machine's reader, degraded its way — see
  /// `NotificationCoordinator._attentionThreshold`. A preference that cannot
  /// be read is a default, never a failed sync.
  Future<double> _thresholdOrDefault() async {
    final read = _threshold;
    if (read == null) return AttentionTuning.defaultThreshold;
    try {
      return await read();
    } catch (e) {
      debugPrint('sync: reading the attention threshold failed: $e');
      return AttentionTuning.defaultThreshold;
    }
  }

  @override
  Future<void> syncNow() async {
    _userAddress ??= await _resolveUserAddress();
    final sw = Stopwatch()..start();
    try {
      // Computed exactly ONCE per pass, here, before anything drains — and
      // then carried down as a parameter rather than recomputed where it is
      // used. [MessageStore.setDeltaLink] stamps `synced_at` on EVERY call,
      // including the `setDeltaLink(folder, null)` the 410 handler makes, so a
      // floor read after any drain would find `synced_at = now` and quietly
      // collapse the vacation rule below into the rolling window.
      //
      // The marker is read on the same line of sight, one statement later, for
      // the same reason: it is compared against that floor, and the widen it
      // detects is answered by clearing cursors mid-pass — a marker read after
      // any of that would be racing writes this pass made itself.
      final floor = await _effectiveFloor();
      // An empty string is treated as no marker at all — the same reading
      // [_effectiveFloor] gives an empty `synced_at`. A pref is TEXT, and an
      // empty one left comparable would sort below every real floor: widening
      // would never fire again, and nothing would ever overwrite it.
      final stored = await _store.getPref(mailBootstrapFloorKey);
      final marker = (stored == null || stored.isEmpty) ? null : stored;
      final widen = marker != null && floor.compareTo(marker) < 0;

      final (inbox, inboxResync) = await _syncFolder(
        'inbox',
        'inbound',
        floor: floor,
        widen: widen,
        quietBeforeIso: widen ? marker : null,
      );
      final (sent, sentResync) = await _syncFolder(
        'sentitems',
        'outbound',
        floor: floor,
        widen: widen,
        quietBeforeIso: widen ? marker : null,
      );

      // How far back this mailbox has now been drained, written only once both
      // folders have returned. A folder that threw took the whole pass with it
      // before reaching this line, which is the design: the marker still names
      // the old floor, so the next pass detects the same widen and finishes
      // the half that did not land.
      //
      // A null marker is ADOPTED rather than acted on. A database from before
      // this bookkeeping existed has no record of what it drained, and reading
      // that silence as "never drained anything" would make the first sync
      // after every upgrade re-drain the whole window for nothing.
      if (marker == null || floor.compareTo(marker) < 0) {
        await _store.setPref(mailBootstrapFloorKey, floor);
      }

      // The safety net, after the marker so a widen this pass detected is
      // already recorded, and before the revives so anything it finds is
      // ordinary mail by the time they run. What it ingests takes exactly the
      // ordinary path — `_ingestPage` lands it `pending` (or `backlog` below
      // the floor), and the backlog enqueues further down this same pass file
      // its extract, needs-you and embed rows — so there is nothing here to
      // queue by hand.
      final (reconciledInbox, reconciledSent, reconcileSubjects, reconcileError) =
          await _reconcileIfDue(floor: floor);

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

      // The rows the settle race left owing a storyline stage — settled while
      // this sync's own enqueue was still to come, so their `outcome` never
      // closed. Self-exhausting: with the owed-stage arm on
      // [MessageStore.writeStorylineProgress] the pass this queues finishes
      // them, and the next sync matches nothing.
      final revivedStoryline = await _store.reviveOwedStorylineStages(
        sources: const [_source],
      );

      // Mail the first triage judged before it asked whether a reply is
      // expected. BEFORE the enqueue below for the same reason the teams sync
      // orders its re-pend first: a row this flips to `pending` is one the
      // enqueue picks up in the same pass rather than a refresh later.
      // Self-exhausting — see [MessageStore.rejudgeStaleTriage].
      final rejudged = await _store.rejudgeStaleTriage(
        source: _source,
        sinceIso: floor,
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
          sinceIso: floor,
        );
        await _store.setPref('backfill_addressed_me_email', '1');
      }

      // After both drains, so the window it queues from is the mailbox as it
      // stands rather than as it stood mid-sync. `OR IGNORE` on the work table
      // makes this idempotent, which is what lets it run on every sync: new mail
      // is queued, finished work stays finished, and a queue that a crash left
      // short refills itself without anyone tracking that it did.
      final queued = await _store.enqueueExtractBacklog(
        cap: backlogEnqueueCap,
        sinceIso: floor,
        source: _source,
      );

      // The needs-you verdict, over exactly the rows above. Same cap and same
      // window on purpose — see [MessageStore.enqueueNeedsYouBacklog]: the two
      // queues covering one set of messages is what lets a reader tell "judged
      // no" from "never judged" without a second column to say which.
      final queuedNeedsYou = await _store.enqueueNeedsYouBacklog(
        cap: backlogEnqueueCap,
        sinceIso: floor,
        source: _source,
      );

      // The one-time catch-up for the build that judged only the floor: its
      // below-floor items finished `done` with a NULL verdict, and the
      // `OR IGNORE` enqueue above will never offer them again. Ran once, and
      // the pref is what says so. The count stays null until it runs — "did
      // not run" and "ran and found nothing" are different facts, and the
      // activity row says which.
      int? revivedNeedsYou;
      if (await _store.getPref('needs_you_model_revive') == null) {
        revivedNeedsYou = await _store.reviveUnjudgedNeedsYou();
        await _store.setPref('needs_you_model_revive', '1');
      }

      // The other half of that catch-up, on the home screen's side. The v10
      // verdict column arrived AFTER these rows settled, so the `needs_you`
      // snapshot each of them took never saw it: a message the pass later
      // judged yes carries `needs_you_verdict = 1` beside `needs_you = 0`, and
      // nothing else in the app would ever reconcile the two. Raise-only, and
      // guarded on the thread not being done and having no reply newer than
      // the message — a chip raised months late must not land on something the
      // user has already answered. Null until it runs, like the revive above.
      int? backfilledNeedsYou;
      if (await _store.getPref('needs_you_flag_backfill') == null) {
        backfilledNeedsYou = await _progress.backfillNeedsYou(
          threshold: await _thresholdOrDefault(),
        );
        await _store.setPref('needs_you_flag_backfill', '1');
      }

      // Exchange's first-contact tip, off the rows stored before the ingest
      // learned to strip it. Once, on the same one-shot idiom as the two
      // above. Null until it runs.
      int? strippedSenderTips;
      if (await _store.getPref('sender_tip_strip') == null) {
        strippedSenderTips = await _store.stripSenderIdentificationTips();
        await _store.setPref('sender_tip_strip', '1');
      }

      // The display names of everyone the user has written to, off the rows
      // stored before the ingest above learned to carry them. Same one-shot
      // idiom, and null until it runs. Read-time name resolution in the
      // People layer covers what a build was handed; this fixes what is
      // stored, which is what the thread header and the typeahead read.
      int? namedParticipants;
      if (await _store.getPref('participant_names_backfill') == null) {
        namedParticipants = await _store.fillParticipantNames();
        await _store.setPref('participant_names_backfill', '1');
      }

      // The threads written before the fold learned to wait for the gate.
      // An inbound landed, the thread said `needs_reply`, and the gate that
      // threw that message out a moment later told nobody — so the rail has
      // been listing threads holding nothing anyone could answer. Same
      // one-shot idiom as the three above, and null until it runs. Every
      // connector at once, because the lie is not the mail sync's alone.
      int? refoldedThreads;
      if (await _store.getPref('thread_state_refold') == null) {
        refoldedThreads = await _store.refoldAllThreadStates();
        await _store.setPref('thread_state_refold', '1');
      }

      // The per-message search vectors, over the same window and on the same
      // `OR IGNORE` idempotence — new mail is queued, and a backlog that
      // predates the search feature refills itself without anyone asking.
      await _store.enqueueEmbedBacklog(
        cap: backlogEnqueueCap,
        sinceIso: floor,
        source: _source,
      );

      // The clustering pass over everything not in a storyline yet. One row, not
      // one per thread — there is one mailbox to sweep — and a requeue rather
      // than an enqueue, so the sweep that ran after the last sync runs again
      // after this one instead of staying `done` forever.
      await _store.requeueWork('storyline_sweep', _source, 'sweep');

      // Only when it found something. A reconcile that found nothing is the
      // normal state and every ten minutes of it would bury the panel — and it
      // cannot be made quiet the ordinary way, because [ActivityLog] never
      // suppresses a row whose detail carries a list.
      if (reconciledInbox + reconciledSent > 0) {
        await _log.record(
          'sync_reconcile',
          source: _source,
          count: reconciledInbox + reconciledSent,
          detail: {
            'inbox': reconciledInbox,
            'sent': reconciledSent,
            'subjects': reconcileSubjects,
          },
        );
      }

      await _log.record(
        'sync_mail',
        source: _source,
        count: inbox + sent,
        durationMs: sw.elapsedMilliseconds,
        detail: {
          'inbox': inbox,
          'sent': sent,
          'queued_extract': queued,
          'queued_needs_you': queuedNeedsYou,
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
          if (revivedStoryline > 0) 'revived_storyline': revivedStoryline,
          // The count the delta feed owed and did not deliver. Absent on every
          // healthy pass, which is what makes its presence worth reading.
          if (reconciledInbox + reconciledSent > 0)
            'reconciled': reconciledInbox + reconciledSent,
          // A safety net that failed is a fact about the net, not about the
          // sync: the pass around it succeeded, so this rides on an `ok` row.
          'reconcile_error': ?reconcileError,
          'backfilled_addressed_me': ?backfilled,
          'revived_needs_you': ?revivedNeedsYou,
          'backfilled_needs_you': ?backfilledNeedsYou,
          'stripped_sender_tips': ?strippedSenderTips,
          'named_participants': ?namedParticipants,
          'refolded_threads': ?refoldedThreads,
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

  /// The user's lookback setting, or the default when there is not one to be
  /// had.
  ///
  /// Every failure answers [syncFloorDays]. The closure reads a Riverpod
  /// container this service does not own, and a container disposed mid-drain
  /// must cost the pass its preference, never the mail — the same rule
  /// [LlmClient]'s target resolver follows for the same reason.
  int _resolveLookbackDays() {
    try {
      return clampLookbackDays(_lookbackDays?.call() ?? syncFloorDays);
    } catch (_) {
      return syncFloorDays;
    }
  }

  /// When each of this source's folders last finished, as one stamp: the OLDER
  /// of the two, or whichever exists, or null when neither does.
  ///
  /// The older one is the honest answer. A pass that reached back only as far
  /// as the more recent stamp would leave the folder behind it with a gap
  /// nothing ever fetches again. String comparison stands in for date
  /// comparison because every stamp in this table is written by [_nowIso] in
  /// the same UTC ISO shape.
  Future<String?> _lastSyncedAt() async {
    final inbox = await _store.getSyncedAt('inbox', source: _source);
    final sent = await _store.getSyncedAt('sentitems', source: _source);
    if (inbox == null) return sent;
    if (sent == null) return inbox;
    return inbox.compareTo(sent) < 0 ? inbox : sent;
  }

  /// The oldest point this pass will reach.
  ///
  /// The OLDER of the rolling window and the last sync that finished — the
  /// vacation rule. Mail that arrived while the app was closed is unreachable
  /// through any shorter floor, and no cursor is coming to fetch it: the
  /// lookback is a preference about how much history to hold, never a licence
  /// to skip mail that was delivered while nobody was draining.
  Future<String> _effectiveFloor() async {
    final rolling = _isoDaysAgo(_resolveLookbackDays());
    final last = await _lastSyncedAt();
    if (last == null || last.isEmpty) return rolling;
    return last.compareTo(rolling) < 0 ? last : rolling;
  }

  /// One folder, including the single permitted recovery from an expired
  /// cursor. Returns `(messages seen for the first time, whether the 410
  /// recovery fired)`.
  ///
  /// [floor] is handed in rather than computed here, and both uses below are
  /// that same string — see the computation site in [syncNow] for why asking
  /// again inside this method would be wrong.
  ///
  /// [widen] says the user asked for more history than any bootstrap has
  /// fetched, so this folder abandons its cursor and drains from [floor]
  /// again. [quietBeforeIso] is how far back that history reaches: everything
  /// older than it is backfill rather than news, and the ingest folds it
  /// without letting it move a thread's state.
  Future<(int, bool)> _syncFolder(
    String folder,
    String direction, {
    required String floor,
    bool widen = false,
    String? quietBeforeIso,
  }) async {
    final storedLink = await _store.getDeltaLink(folder, source: _source);
    // Whether a cursor existed BEFORE this pass — not whether one is used.
    // A widen drains from the floor exactly like a first run does, but through
    // `startLink: null` on a mailbox that has been synced before; this flag is
    // the record of which of the two it was.
    final firstRun = storedLink == null;
    var newMessages = 0;
    var resynced = false;

    // Each folder drops its OWN cursor, immediately before its own drain,
    // rather than both being cleared up front: a failure in one folder then
    // leaves the other's cursor intact and its next pass incremental. The
    // marker only moves once both folders have returned, so a widen that got
    // half way is detected again next pass and finishes there. Clearing a
    // cursor and re-draining is the same move the 410 recovery below makes,
    // and safe for the same reason — `upsertMessage` conflicts
    // non-destructively and `firstSighting` keeps the replay out of the fold.
    if (widen && !firstRun) {
      await _store.setDeltaLink(folder, null, source: _source);
    }

    try {
      newMessages += await _drain(
        folder,
        direction,
        startLink: widen ? null : storedLink,
        minReceivedIso: (firstRun || widen) ? floor : null,
        quietBeforeIso: quietBeforeIso,
        backlogCutoff: floor,
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
          minReceivedIso: floor,
          // Null on every pass that is not a widen, so an ordinary 410
          // recovery cannot quiet genuinely new mail. A widen pass never
          // reaches here at all: its cursor was already cleared above, and a
          // drain with no cursor has nothing for Graph to expire.
          quietBeforeIso: quietBeforeIso,
          backlogCutoff: floor,
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

    return (newMessages, resynced);
  }

  /// How many of a reconcile's finds it names in the activity row. Enough to
  /// recognise what the feed dropped, few enough that one bad day does not
  /// write a mailbox listing into the log.
  static const int _reconcileSubjectsCap = 10;

  /// The safety net, at most once per [reconcileEvery]. Returns
  /// `(inbox finds, sent finds, their subjects, the failure or null)`.
  ///
  /// [floor] is the pass's own, handed down — see the computation site in
  /// [syncNow]. Nothing here recomputes it, and nothing here writes a cursor.
  Future<(int, int, List<String>, String?)> _reconcileIfDue({
    required String floor,
  }) async {
    final stamp = await _store.getPref(mailLastReconcileKey);
    final last =
        (stamp == null || stamp.isEmpty) ? null : DateTime.tryParse(stamp);
    // Absent, empty and unparseable all read as "never". A stamp nobody can
    // date cannot say the net ran recently, and the honest answer to that
    // doubt is two cheap requests rather than an unbounded wait.
    if (last != null &&
        DateTime.now().toUtc().difference(last.toUtc()) < reconcileEvery) {
      return (0, 0, const <String>[], null);
    }

    var inbox = 0;
    var sent = 0;
    final subjects = <String>[];
    String? error;
    try {
      final (inboxCount, inboxSubjects) =
          await _reconcileFolder('inbox', 'inbound', floor: floor);
      inbox = inboxCount;
      subjects.addAll(inboxSubjects);
      final (sentCount, sentSubjects) =
          await _reconcileFolder('sentitems', 'outbound', floor: floor);
      sent = sentCount;
      subjects.addAll(sentSubjects);
    } catch (e) {
      // Everything, including the [DeltaResyncRequired] that a 410 becomes. A
      // reconcile holds no cursor for Graph to expire, so a 410 here is a
      // server hiccup rather than the recoverable state it is in [_syncFolder]
      // — and a network failure in a safety net must never take the pass with
      // it. Both drains have already landed and the enqueue below still has to
      // run; whatever the inbox half found is kept.
      debugPrint('sync: mail reconcile failed: $e');
      error = '$e';
    }

    // Stamped after the attempt whether it worked or not, and never between
    // the two folders. A reconcile that fails every time must retry on the
    // ten-minute cadence, not on every sixty-second poll.
    await _store.setPref(mailLastReconcileKey, _isoAgo(Duration.zero));
    return (inbox, sent, subjects.take(_reconcileSubjectsCap).toList(), error);
  }

  /// One folder's reconcile: the last [reconcileWindow] enumerated from
  /// scratch, ingested through the same idempotent page path, with the cursor
  /// left exactly where the ordinary drain put it. Returns the messages seen
  /// for the first time and their subjects (at most [_reconcileSubjectsCap]).
  Future<(int, List<String>)> _reconcileFolder(
    String folder,
    String direction, {
    required String floor,
  }) async {
    final subjects = <String>[];
    final count = await _drain(
      folder,
      direction,
      startLink: null,
      minReceivedIso: _isoAgo(reconcileWindow),
      // Never a widen: everything a reconcile finds is news the feed owed,
      // whatever its timestamp, so nothing it ingests is quieted.
      quietBeforeIso: null,
      backlogCutoff: floor,
      persistCursor: false,
      onFirstSighting: (subject) {
        if (subjects.length < _reconcileSubjectsCap) subjects.add(subject);
      },
    );
    return (count, subjects);
  }

  /// Walks every page of one delta drain, committing as it goes. Returns how
  /// many messages were seen for the first time.
  ///
  /// [persistCursor] is false for a reconcile — see the terminal block below.
  /// [onFirstSighting] is told the subject of each message this drain is the
  /// first to see, which is how a reconcile can say what it caught.
  Future<int> _drain(
    String folder,
    String direction, {
    required String? startLink,
    required String? minReceivedIso,
    required String? quietBeforeIso,
    required String backlogCutoff,
    bool persistCursor = true,
    void Function(String subject)? onFirstSighting,
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

      newMessages += await _ingestPage(
        page.messages,
        direction,
        quietBeforeIso: quietBeforeIso,
        backlogCutoff: backlogCutoff,
        onFirstSighting: onFirstSighting,
      );

      final next = page.nextLink;
      if (next != null && next.isNotEmpty) {
        // Deliberately NOT persisted: a nextLink is a position inside an
        // unfinished walk, and storing one would let a later drain resume
        // mid-page and never receive the deltaLink that closes it.
        link = next;
        continue;
      }

      final delta = page.deltaLink;
      // A reconcile enumerates from scratch, and both Graph and the MCP tool
      // hand back a deltaLink for such a walk. Storing it would rewind the
      // folder's delta position to "now" — skipping every change between the
      // real cursor and this moment — AND stamp `synced_at`, which is what the
      // vacation rule reads. So a reconcile discards it.
      if (persistCursor && delta != null && delta.isNotEmpty) {
        await _store.setDeltaLink(folder, delta, source: _source);
      }
      return newMessages;
    }
  }

  /// One mail message as a `messages` row.
  ///
  /// **The one place a mail message becomes a row**, called both by this sync
  /// and by the echo writer in `mail_echo.dart` — which is the point. A reply
  /// the app sends is written locally before Sent Items has it, and if that
  /// row disagreed with the one the next drain would build, the disagreement
  /// would live in the database until somebody noticed a thread behaving
  /// unlike every other thread. Teams has held this shape since its first
  /// send; [TeamsSync.messageRow] is the twin.
  ///
  /// Nothing is derived here: the gate verdict, the direction and the
  /// addressed-me flag are all decided by the caller, because the two callers
  /// know them differently. The sync reads them off a delta page; the echo
  /// writer knows it wrote the message itself.
  static Map<String, Object?> mailRow({
    required String id,
    String? internetMessageId,
    required String conversationKey,
    required String direction,
    String? subject,
    String? fromName,
    String? fromAddress,
    required List<String> to,
    String? receivedAt,
    required bool isRead,
    String? bodyPreview,
    String? bodyText,
    bool hasAttachments = false,
    required String triageStatus,
    String? gateReason,
    bool addressedMe = false,
  }) =>
      {
        'source': _source,
        'source_message_id': id,
        'internet_message_id': internetMessageId,
        'conversation_key': conversationKey,
        'direction': direction,
        'subject': subject,
        'from_name': fromName,
        'from_address': fromAddress,
        'to_json': jsonEncode(to),
        'received_at': receivedAt,
        'is_read': isRead ? 1 : 0,
        'body_preview': bodyPreview,
        'body_text': bodyText,
        'has_attachments': hasAttachments ? 1 : 0,
        'triage_status': triageStatus,
        'gate_reason': gateReason,
        'addressed_me': addressedMe ? 1 : 0,
      };

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
  ///
  /// [quietBeforeIso] is set only on a widen pass, and names the floor the
  /// last bootstrap reached — see the `historical` flag in the loop below for
  /// what that buys.
  ///
  /// [onFirstSighting] is told each message this page is the first to see, by
  /// subject. Additive: the returned count is unchanged, and a caller that
  /// passes nothing behaves exactly as before.
  ///
  /// [backlogCutoff] is the pass's effective floor, handed down from [syncNow]
  /// rather than computed here. Mail older than it lands already
  /// `skipped`/`backlog` — a delta update can replay or introduce a message
  /// from before the window, and such a message renders but never reaches a
  /// model. Because it IS the sync floor, everything a bootstrap fetches is
  /// inside the AI window: the lookback the user chose is the depth the models
  /// read.
  Future<int> _ingestPage(
    List<Map<String, dynamic>> raw,
    String direction, {
    String? quietBeforeIso,
    required String backlogCutoff,
    void Function(String subject)? onFirstSighting,
  }) async {
    if (raw.isEmpty) return 0;
    final outbound = direction == 'outbound';

    return _store.db.transaction(() async {
      var newMessages = 0;
      final work = <String, _ConversationWork>{};

      // The echoes this page could be carrying the real copies of, read once
      // for the page rather than looked for under every message: on every
      // drain but the one after a send there are none, and the answer is one
      // indexed read. Consistent for the whole page — the send's own write
      // is a transaction of its own, and drift runs them one at a time.
      final pendingEchoes = outbound
          ? await _store.pendingEchoInternetMessageIds(_source)
          : const <String>{};

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

        // A message older than the floor the LAST bootstrap drained from is
        // history being backfilled, not news arriving: it existed before every
        // decision the user has made about these threads, so it must not remake
        // any of them. Watermarks and counts still move — the thread's record
        // gets more complete, its state does not change.
        final historical = quietBeforeIso != null &&
            receivedAt != null &&
            receivedAt.compareTo(quietBeforeIso) < 0;

        final subject = message['subject'] as String?;
        // Graph's preview of a link-attachment message is the file name
        // wrapped in zero-width spaces; search and cards must never carry an
        // invisible character.
        // And Exchange's first-contact tip, which the preview opens with for
        // any sender the mailbox has not seen — see `mail_text.dart`.
        final rawPreview =
            (message['bodyPreview'] as String?)?.replaceAll('\u200b', '');
        final preview =
            rawPreview == null ? null : stripSenderIdentification(rawPreview);
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
            recipients.first.$2.toLowerCase() == _userAddress!.toLowerCase();

        final (triageStatus, gateReason) = triageStatusOnInsert(
          outbound: outbound,
          receivedAt: receivedAt,
          backlogCutoff: backlogCutoff,
        );

        // An inbound the gate throws out AT INSERT — mail from behind the
        // sync floor, stored `skipped`/`backlog` — is history being
        // backfilled, not news arriving: nothing will ever read it, and a
        // thread must not be made to ask for a reply to a message no stage of
        // this app will look at. So it folds as `historical`, which moves the
        // watermarks and the counts and leaves the state where it stands.
        //
        // Inbound only. An outbound is ALWAYS `skipped`/`outbound` at insert
        // — triage answers "does this need me?" and the user's own send never
        // does — so folding on that stamp would make every reply historical
        // and no thread would ever settle.
        final gatedAtInsert = !outbound && triageStatus == 'skipped';

        // Asked before the write, because the fold below must see each
        // message exactly once. Delta feeds legitimately replay messages —
        // across pages, and wholesale during the 24-hour re-drain a 410
        // forces — and folding one a second time would reopen every thread
        // the user had marked done. The upsert itself still runs: a replay can
        // carry a newer read state.
        final internetMessageId = message['internetMessageId'] as String?;

        // The real copy of a reply this app sent replaces the local echo the
        // send wrote — same `internet_message_id`, different id. Done HERE,
        // before the sighting question, for two reasons: the real row must
        // read as a true first sighting so it folds like any other Sent Items
        // copy, and the delete must be in the same transaction as the insert
        // so no reader can ever see both rows at once.
        if (internetMessageId != null &&
            pendingEchoes.contains(internetMessageId)) {
          await _store.deleteLocalEcho(_source, internetMessageId);
        }

        final firstSighting = !await _store.hasMessage(_source, id);

        final ingested = await _store.upsertMessage(mailRow(
          id: id,
          internetMessageId: internetMessageId,
          conversationKey: key,
          direction: direction,
          subject: subject,
          fromName: fromName,
          fromAddress: fromAddress,
          // Addresses only. `to_json` is a list of address STRINGS — every
          // reader of it, `recipientsFromJson` included, expects that shape —
          // so the names ride into `participants_json` below and nowhere else.
          to: [for (final (_, address) in recipients) address],
          receivedAt: receivedAt,
          isRead: message['isRead'] == true,
          bodyPreview: preview,
          // Delta pages carry no body; the detail fetch fills it in later and
          // the upsert will not blank it. The attachment flag DOES ride the
          // delta page — it is in the select — so the paperclip is on the list
          // card before any body has been fetched.
          hasAttachments: message['hasAttachments'] == true,
          triageStatus: triageStatus,
          gateReason: gateReason,
          addressedMe: direction == 'inbound' && soleRecipient,
        ));

        // Non-null only when the pipeline had never heard of this message, so
        // a delta page replaying itself announces nothing. Not awaited because
        // there is nothing to wait for: the tick is a publish onto a stream.
        if (ingested != null) {
          _progress.noteIngest(_source, id, receivedAt: ingested);
        }

        if (!firstSighting) continue;
        newMessages++;
        // Only ever a first sighting, so a delta page replaying itself names
        // nothing. It is what lets the reconcile report WHICH messages the
        // feed had skipped rather than only how many.
        onFirstSighting?.call(subject ?? '');

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
        // nothing. Neither does a historical one, whatever its timestamp says:
        // the ask it would be answering has been on screen since before this
        // window reached back far enough to see it, and a reply from behind
        // that floor is not what the user is still waiting to write.
        final resolvesAsk = !historical &&
            outbound &&
            outboundResolves(entry.snapshot, receivedAt);
        entry.snapshot = foldMessage(
          entry.snapshot,
          outbound: outbound,
          receivedAt: receivedAt,
          subject: subject,
          preview: preview,
          // And NOT into `resolvesAsk` above, which is outbound-only and so
          // can never see this flag set — see where it is computed.
          historical: historical || gatedAtInsert,
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
          for (final (name, address) in recipients) {
            entry.addParticipant(name, address);
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
  /// between the delta page and this call is skipped rather than thrown over,
  /// and so is one the server refuses to show: it must not cost the rest of a
  /// thread its bodies, nor park a triage queue. Anything else is a real
  /// failure and belongs on the banner.
  Future<void> _fetchDetailInto(String sourceMessageId) async {
    // A local echo's id was minted by this app before the server had the
    // message, and its body was written by the hand that sent it. Asking
    // Graph for it is a 400 at best; every body fetch — triage's, Restore's,
    // a thread's — comes through here, so this is the one place to refuse.
    if (sourceMessageId.startsWith(localEchoPrefix)) return;

    final Map<String, dynamic> detail;
    try {
      detail = await _mail.getMessageDetail(sourceMessageId);
    } on GraphMailException catch (e) {
      // A 403 on one message's detail is a permanent refusal of that message
      // and nothing more — the sender policy on the MCP server, a mailbox
      // permission on the SDK — so it is skipped the way a vanished message
      // is. The delta feed already omits hidden senders; this path only runs
      // after a policy flip, and it must not park a thread or a triage queue.
      if (e.statusCode == 403 || e.statusCode == 404 || e.statusCode == 410) {
        return;
      }
      rethrow;
    }

    final uniqueBody = detail['uniqueBody'];
    final rawBody =
        uniqueBody is Map<String, dynamic> ? uniqueBody['content'] as String? : null;
    // Exchange's first-contact tip comes off HERE, where the body first
    // exists, so nothing downstream — the transcript, the index, the prompts
    // — ever sees a sentence the sender did not write. See `mail_text.dart`.
    final bodyText = rawBody == null ? null : stripSenderIdentification(rawBody);
    final headers = _headers(detail['internetMessageHeaders']);

    final rawAttachments = detail['attachments'];
    final rawCount = rawAttachments is List ? rawAttachments.length : 0;
    // A file attached as a link is not in Graph's attachment list — it is a
    // U+200B-delimited run in the body. Parsed here, once, because this is the
    // first time the body exists; numbered after the connector's own entries so
    // the ordinal cap counts real attachments first.
    final links = extractOwaLinks(bodyText, startOrdinal: rawCount);


    await _store.updateMessageDetail(
      _source,
      sourceMessageId,
      // Null stays null: `updateMessageDetail` COALESCEs, and an empty string
      // from a detail that carried no body would blank one already stored.
      bodyText: bodyText == null ? null : links.body,
      // Raised, never lowered. A link the connector never counted is still a
      // file on the message, and the paperclip is how a card says so; a
      // detail that states nothing about attachments stays null, which the
      // COALESCE in `updateMessageDetail` reads as "the delta page already
      // knew".
      hasAttachments:
          links.rows.isNotEmpty ? true : detail['hasAttachments'] as bool?,
      // Under a 'headers' key rather than at the top level: source_meta_json
      // is the whole connector-specific blob, and headers are one thing in
      // it.
      sourceMetaJson: headers.isEmpty ? null : jsonEncode({'headers': headers}),
    );

    await _storeAttachments(
      sourceMessageId,
      rawAttachments,
      extraRows: links.rows,
    );
  }

  /// Writes what came with one message and queues the eligible ones for text.
  ///
  /// Here rather than in the delta loop because this is where an attachment
  /// LIST first exists: a delta page carries the flag and nothing else. Triage
  /// runs this fetch itself before it judges (`TriageQueue` calls
  /// [ensureMessageBody] inside the claim), so the rows are in place by the
  /// time the model is asked about the message.
  ///
  /// Only `attachment_text` is queued. The digest is enqueued by the text
  /// handler once there are words to digest — asking a model to read a document
  /// nobody has extracted yet is a call that can only fail.
  ///
  /// `AttachmentTextHandler` drains the kind, in the post-sync pass; a row
  /// queued while it is already running is picked up on the next one.
  /// `enqueueWork` is INSERT OR IGNORE, so the same message fetched twice
  /// queues one item. A row the policy refuses is told why, once, while it is
  /// still `pending` — see `recordAttachmentRefusal`.
  ///
  /// [extraRows] are the files the connector did not list: an Outlook "attach
  /// as link" is a run in the body rather than an entry in `attachments[]`, so
  /// `extractOwaLinks` builds its rows and they join the connector's here.
  /// They take the same read-back policy pass as every other row, which is the
  /// point of merging them before it rather than upserting them separately.
  Future<void> _storeAttachments(
    String sourceMessageId,
    Object? rawAttachments, {
    List<Map<String, Object?>> extraRows = const [],
  }) async {
    if ((rawAttachments is! List || rawAttachments.isEmpty) &&
        extraRows.isEmpty) {
      return;
    }

    final listed = rawAttachments is List ? rawAttachments : const [];
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < listed.length; i++) {
      final entry = listed[i];
      if (entry is! Map) continue;
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      rows.add({
        'attachment_id': id,
        // The connector's own order, not this loop's index into the entries it
        // could parse — a malformed entry must not renumber the ones after it.
        'ordinal': i,
        'kind': entry['kind'] as String? ?? 'unknown',
        'name': entry['name'] as String?,
        'content_type': entry['content_type'] as String?,
        'size': (entry['size'] as num?)?.toInt() ?? 0,
        'is_inline': entry['is_inline'] == true || entry['is_inline'] == 1,
        'content_id': entry['content_id'] as String?,
        'source_url': entry['source_url'] as String?,
      });
    }
    // The body's link rows land after the connector's, already numbered from
    // its count, so a link never takes a real attachment's ordinal.
    rows.addAll(extraRows);
    if (rows.isEmpty) return;

    await _store.upsertAttachments(_source, sourceMessageId, rows);

    // Read back rather than judged from the maps above, because the policy asks
    // about the MESSAGE too — a gated message queues nothing — and because the
    // upsert's MAX() may have raised a size this listing did not state.
    final message = await _store.getMessageRow(_source, sourceMessageId);
    if (message == null) return;
    for (final row in await _store.attachmentsForMessage(
      _source,
      sourceMessageId,
    )) {
      final (eligible, why) = attachmentTextPolicy(message, row);
      if (!eligible) {
        await _store.recordAttachmentRefusal(
          _source,
          sourceMessageId,
          row['attachment_id'] as String? ?? '',
          why ?? 'ineligible',
        );
        continue;
      }
      await _store.enqueueWork(
        'attachment_text',
        _source,
        attachmentEntityId(
          sourceMessageId,
          row['attachment_id'] as String? ?? '',
        ),
      );
    }
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

  /// `(name, address)` for every To: recipient that has an address.
  ///
  /// The NAME is carried, not dropped: it is the only place the display name
  /// of somebody the user wrote to ever appears, and without it every
  /// outbound-only thread stores its recipients as a bare address — which is
  /// what the thread header, the recent-people typeahead and a person's own
  /// room row then have to show. [_address] already returns it; this used to
  /// throw it away.
  ///
  /// An entry with no address is dropped, as before: there is nothing to key a
  /// participant on, and a name alone cannot be written to.
  static List<(String?, String)> _recipients(Object? raw) {
    if (raw is! List) return const [];
    final out = <(String?, String)>[];
    for (final entry in raw) {
      final (name, address) = _address(entry);
      if (address != null && address.isNotEmpty) out.add((name, address));
    }
    return out;
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

/// [days] before now, at UTC midnight — [_isoAgo]'s shape, cut back to the
/// start of the day.
///
/// The settings screen promises mail since a named day, and midnight is what
/// makes that sentence exactly true rather than true to within the hour
/// someone happened to press refresh. It can only ever WIDEN the window, by
/// less than a day, which is the safe direction: a floor that moves earlier
/// cannot lose mail.
String _isoDaysAgo(int days) {
  final t = DateTime.now().toUtc().subtract(Duration(days: days));
  return DateTime.utc(t.year, t.month, t.day)
      .toIso8601String()
      .replaceFirst('.000Z', 'Z');
}
