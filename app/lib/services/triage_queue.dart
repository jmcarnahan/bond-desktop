import 'dart:async';

import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'drain_gate.dart';
import 'gates.dart';
import 'backend/backend_types.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/triage_task.dart';
import 'pipeline_progress.dart';

/// How much triage is left, as of the last message the worker finished.
///
/// Built from the store's own counts rather than from a counter the worker
/// keeps, so it is correct across a restart and cannot drift: the numbers are
/// the rows.
class TriageProgress {
  /// `triage_status` → row count. Statuses with no rows are absent.
  final Map<String, int> counts;

  const TriageProgress(this.counts);

  /// Messages the worker still has to look at. The only number the UI shows —
  /// [total] counts every message ever synced, most of which were skipped as
  /// outbound or backlog and never meant anything to a human.
  int get remaining =>
      (counts['pending'] ?? 0) + (counts['processing'] ?? 0);

  int get total => counts.values.fold(0, (sum, n) => sum + n);

  int get done => total - remaining;
}

/// Drains pending inbound messages through the gates and the local model, a
/// few at a time, newest first.
///
/// Bounded-concurrent rather than serial, and the bound is the interesting
/// half. A GPU reads the model's weights once per decode step however many
/// sequences share that step, so K requests in flight at one llama-server come
/// back in nothing like K times the wall clock of one: at K=3, against a
/// server started with matching slots, the aggregate is worth roughly 2.5-3x a
/// serial drain. The trade reverses past a small K — every request in a batch
/// gets individually slower — and two things here care about ONE request
/// rather than the aggregate: [LlmClient]'s timeout, which is sized to catch
/// a wedged server rather than a batched one, and the person waiting for the
/// first triaged message to appear.
///
/// Each message goes through two tiers, in this order for a reason:
///
/// 1. the gates that read only what a delta page already carried — who sent
///    it. A no-reply sender is a no-reply sender whatever its body says, and
///    catching it here means the bulk mail never costs a Graph round trip.
///    One of those gates is not a pattern at all: the sender's standing rule,
///    read from the store once per claim and handed to both calls, so an
///    address the owner dropped by hand is gated exactly where a no-reply is.
/// 2. the per-message detail fetch, then the gates again, then the model. A
///    delta page carries a ~255-character preview and no headers at all, so
///    without this step triage would classify from a snippet and the
///    newsletter and auto-generated gates could never fire. Mail only — a
///    chat message arrives whole, and there is no second call to make.
///
/// A failed detail fetch DEGRADES rather than blocks: the message is triaged
/// on its preview and the drain moves on. A Graph hiccup costing one message
/// its full body is much cheaper than it costing every message behind it.
///
/// The exception is a fetch that fails because the session ended
/// ([NotSignedIn], [ReconsentRequired]). That is not a hiccup — every message
/// behind it would fail the same way — so the drain parks instead, leaving
/// its row pending and its attempt count untouched. Signing back in and
/// syncing pumps it again.
///
/// One narrow case is DEFERRED rather than degraded, and it is the one where
/// classifying from the preview would be worst: a failed fetch that leaves a
/// machine-shaped sender ([suspectMachineSender]) with no headers at all. The
/// header gates are the gates that catch exactly that mail, and they have
/// nothing to read. So the message goes back to `pending` with an attempt
/// spent and the next drain re-fetches it; after [_maxAttempts] it is
/// classified headerless exactly as it always was. The drain carries on with
/// the message behind it either way.
///
/// The queue owns no timer. [pump] is called after each sync, is a no-op while
/// a drain is already running, and stops on its own when nothing is pending.
/// A drain that ends because the model server is down leaves its row pending
/// and lets the next poll try again.
///
/// This drain runs FIRST, and that is now an invariant of the pipeline rather
/// than the order two pumps happened to be fired in. A message is never
/// extracted or judged for needs-you before triage has spoken about it:
/// `MessageStore.claimPendingWork` refuses to hand the AI worker an `extract`
/// or `needs_you` item whose message is still `pending` or `processing`, so
/// whichever drain wins the shared [DrainGate], the gates decide first. What
/// this queue owes the worker in return is a knock on the door when it is
/// done — see [_onDrained].
class TriageQueue {
  /// Every connector whose messages this queue drains. One queue rather than
  /// one per source: a chat message and an email are the same question —
  /// "does this need me?" — asked of the same taxonomy on the same server, and
  /// splitting them would mean two drains competing for one model's slots.
  ///
  /// The list is public because startup clears interrupted claims per source
  /// (`main.dart`) and must cover exactly what this drains.
  static const List<String> sources = ['email', 'teams'];

  /// One retry, then the message is left alone. A local model that answered
  /// unparseably often gets it right on a second pass; a message that fails
  /// twice is a message that will fail every time, and the queue behind it is
  /// worth more than it is.
  static const int _maxAttempts = 2;

  /// A conversation row's CTA is one line in a list, and the model was told to
  /// write imperatives — this is a backstop, not a formatting step.
  static const int _ctaCap = 200;

  final MessageStore _store;
  final LlmClient _client;
  final DrainGate _gate;

  /// Fetches one message's body and headers into the store — in the app,
  /// [MailSync.ensureMessageBody]. Null in tests that have no Graph at all,
  /// which simply triage whatever is stored.
  final Future<void> Function(String sourceMessageId)? _ensureBody;

  final ActivityLog _log;

  /// Where each message's stage lands for the home screen. Defaulted to the
  /// disabled recorder, so a test that builds this queue writes nothing extra.
  final PipelineProgress _pipeline;

  final StreamController<TriageProgress> _progress =
      StreamController<TriageProgress>.broadcast();

  /// How many messages may be at the model server at once. See the class doc
  /// for why it is small; `concurrency: 1` restores the old strictly-serial
  /// drain, which is what the tests that assert on request ORDER use.
  final int _concurrency;

  /// The messages this queue currently holds claims on, as `'$source|$id'`.
  ///
  /// A claim is a row written `processing`, and only the worker that took it
  /// knows it is still wanted. Tracking them is what lets [dispose] hand back
  /// what it is holding: without it, a queue torn down mid-drain — which is
  /// what a backend switch does — left every claimed row `processing` until
  /// the next launch reset it.
  final Set<String> _claimed = {};

  /// The messages actually at the model server, so [dispose] can wait for
  /// their results before deciding what is still claimed.
  final Set<Future<void>> _inFlight = {};

  /// Told once at the end of a drain that wrote at least one verdict, so the
  /// AI worker walks its queue again. In the app: `aiWorker.pump()`.
  ///
  /// This exists because of the invariant above. `app_providers` fires
  /// `triageQueue.pump(); aiWorker.pump()` back to back — at the supervisor's
  /// `onReady` and again on every sync — and the worker can win the shared
  /// [DrainGate], because this queue awaits an `_emit()` before it asks for
  /// the gate at all. The worker then finds every `extract` and `needs_you`
  /// row ineligible, leaves them pending, and nothing re-pumps it until the
  /// next sync: a first sync's whole backlog would sit unextracted for as
  /// long as the user did not sync again. This callback is what gets the
  /// worker to walk once triage has actually spoken.
  ///
  /// Called OUTSIDE the gate on purpose — the worker's own pump queues on the
  /// same [DrainGate], so calling it from inside would deadlock — and not at
  /// all when a drain wrote nothing, which is a park or an empty queue.
  final Future<void> Function()? _onDrained;

  /// Told after either gate tier writes `skipped`, before the progress emit.
  /// In the app: `GateRepairService.afterGate`.
  ///
  /// What a gate that lands late has to undo lives there, not here — the
  /// thread's embedding, its automatic storyline memberships, the work rows
  /// that would file it again. This queue judges; it does not clean up.
  final Future<void> Function(String source, String sourceMessageId)? _onGated;

  /// Messages this drain deliberately put back `pending`, so it does not
  /// immediately claim them again.
  ///
  /// It has to exist because of the ordering: [MessageStore.claimPendingTriage]
  /// takes the NEWEST pending row, and a message deferred a moment ago is
  /// usually exactly that. Without the exclusion the drain would spin on one
  /// message until its attempts ran out, re-fetching in a tight loop. Cleared
  /// per drain, because the deferral is about this drain rather than about
  /// the message: the next pump is meant to try the fetch again.
  final Set<({String source, String id})> _deferred = {};

  /// Verdicts this drain wrote: `triaged` and `skipped`, the two statuses
  /// that move a message past triage for good. Reset when a drain starts, so
  /// it describes the drain that just ended rather than the session.
  int _drainWrote = 0;

  String? _userAddress;
  bool _running = false;
  bool _stopped = false;

  /// Whether the app's processing switch is ON, or null where nobody wired one
  /// — every test, and any caller from before the switch existed. A CLOSURE,
  /// for `AiWorker._enabled`'s reason: the switch moves while a drain is
  /// running and a value captured here would only take effect at the next
  /// rebuild.
  final bool Function()? _enabled;

  TriageQueue(
    this._store,
    this._client, {
    this._userAddress,
    this._ensureBody,
    DrainGate? gate,
    this._concurrency = 3,
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
    this._enabled,
    this._onDrained,
    this._onGated,
  })  : _gate = gate ?? DrainGate(),
        _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  /// The signed-in mailbox, for the gate that skips the user's own mail. Set
  /// after sign-in resolves; until then that one gate is simply off.
  set userAddress(String? value) => _userAddress = value;

  Stream<TriageProgress> get progress => _progress.stream;

  /// Ends the current drain after the messages already in flight finish. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

  /// True only when a switch was wired AND says no. An unwired queue is on.
  bool get _off => _enabled?.call() == false;

  /// Whether this drain must end — `AiWorker._halted`, in the same words and
  /// for the same reason: an off read here LATCHES [_stopped], so a drain the
  /// switch cut short cannot knock on the worker's door on its way out.
  bool get _halted {
    if (_off) _stopped = true;
    return _stopped;
  }

  /// Clears claims a previous run left behind. Startup only — it must not run
  /// while a worker holds a claim, or it would hand that message to a second
  /// drain.
  Future<void> resetInterrupted() async {
    for (final source in sources) {
      await _store.resetInterruptedTriage(source: source);
    }
  }

  /// Stops the drain and gives back every claim it is still holding.
  ///
  /// The order is the whole method. Stop first, so nothing new is claimed;
  /// wait for the messages already at the server, because those answers are
  /// paid for and their results are written by the same paths that release
  /// their claims; then hand back whatever is left — a message that was
  /// mid-flight when the process was told to stop.
  ///
  /// Writing to the store after this object is disposed is safe: the store
  /// outlives the queue, watching only the database provider. Closing the
  /// progress stream around it is safe for the same reason [_emit] guards on
  /// `isClosed` — an in-flight message emitting into a closed controller is
  /// a no-op, not a crash.
  ///
  /// Awaited by nobody in the app (`ref.onDispose` takes a `void` callback),
  /// which is exactly right: the release is a database write that either
  /// lands or is picked up by [MessageStore.reclaimStaleTriage] five minutes
  /// later. Tests await it.
  ///
  /// [dispose] minus the closing of the progress stream, so the queue is
  /// REUSABLE afterwards: the caller is a reset that is about to delete the
  /// rows this queue holds claims on, and the very next thing it wants is
  /// this same queue draining again. The `_stopped` it leaves behind is per
  /// drain, which [pump] clears. The processing switch is untouched either
  /// way — what it says is the user's answer, not a reset's.
  ///
  /// Re-entrant by memoisation: two concurrent callers share ONE run. The
  /// second is reachable through [dispose] — a provider invalidated during a
  /// reset window disposes this queue while the reset host is already
  /// quiescing it — and two runs would race on the `finally`, the first to
  /// finish dropping [_quiescing] while the other is still releasing claims,
  /// which is the exact window [_quiescing] exists to close.
  Future<void> quiesce() =>
      _quiesceRun ??= _quiesceOnce().whenComplete(() => _quiesceRun = null);

  /// The run in progress, and null between runs. Held for the whole of
  /// [_quiesceOnce] including its `finally`, so the latch and the claim
  /// release belong to one caller no matter how many asked.
  Future<void>? _quiesceRun;

  Future<void> _quiesceOnce() async {
    _stopped = true;
    _quiescing = true;
    try {
      // A LOOP, not one wait: a claim that was already at the store when
      // [_stopped] flipped lands in [_inFlight] after the first snapshot was
      // taken. Waiting on the stale snapshot and then releasing would flip a
      // message that is STILL RUNNING back to `pending`, where a second queue
      // could claim it and spend a second model call on the same mail.
      while (_inFlight.isNotEmpty) {
        await Future.wait(_inFlight.toList())
            .catchError((_) => const <void>[]);
      }
      for (final claim in _claimed.toList()) {
        final parts = claim.split('|');
        // Guarded on `processing` in the statement itself, so a claim
        // released here cannot reopen a message that finished while this was
        // deciding.
        await _store.releaseTriageClaim(parts.first, parts.skip(1).join('|'));
      }
      _claimed.clear();
    } finally {
      _quiescing = false;
    }
  }

  /// Raised for the whole of [quiesce] and read by [pump] as "off", so a
  /// pump landing mid-wait cannot lift [_stopped] and restart the drain.
  bool _quiescing = false;

  /// [quiesce], and then the stream goes too — this queue is done.
  ///
  /// The close lands AFTER the wait rather than before it, which is the one
  /// difference from the order this method used to keep. Nothing depends on
  /// the old order, for the reason the doc above gives: [_emit] guards on
  /// `isClosed`, so a message landing during the wait either reports a count
  /// nobody is listening to or finds the controller shut.
  Future<void> dispose() async {
    await quiesce();
    await _progress.close();
  }

  /// Drains until nothing is pending, the queue is stopped, or the model
  /// server turns out to be down. Idempotent: a second call while a drain is
  /// running returns immediately rather than starting a racing one. The drain
  /// itself runs under the shared [DrainGate], so it never interleaves model
  /// calls with an AI-worker drain already at the server.
  ///
  /// With processing switched off it takes no gate, claims nothing, calls no
  /// model and knocks on no door — but it still EMITS. The count is a local
  /// read, and it is the whole of what the rail's "Processing is off · N
  /// waiting" caption has to say: a queue that returned in silence would leave
  /// that caption blank on the one launch it was written for, because nothing
  /// else ever puts a first snapshot on this stream.
  ///
  /// The stop flag is raised on the way out rather than merely returned on,
  /// because a drain already running has to learn about the switch too.
  Future<void> pump() async {
    // A quiesce in progress counts as off — `AiWorker.pump`, same reason: a
    // pump landing mid-wait would clear [_stopped] and let the drain claim
    // again under `_claimed.clear()`.
    if (_off || _quiescing) {
      _stopped = true;
      await _emit();
      return;
    }
    // Cleared before the running check, not after it: an ON landing while a
    // drain is in its tail has to lift the latch the switch left on THAT
    // drain, or the pass would end early and the rest of the backlog would
    // wait for the next poll. This is [stop]'s promise — the next pump drains
    // again — read the only way it can be while a drain is still open.
    _stopped = false;
    if (_running) return;
    _running = true;
    // Before the first message, not after it: the header counter would
    // otherwise sit blank for the seventeen seconds that message takes, which
    // is exactly when a user with a fresh backlog is looking for it.
    await _emit();
    try {
      await _gate.run(_drain);
      // After the gate is released and before the drain flag is: the worker
      // this wakes takes the very gate we are standing outside of. Not after
      // a stop or a dispose, either: `AiWorker._drainAll` clears its own stop
      // flag on entry, so a knock landing on a torn-down pair could restart a
      // worker that had just handed back its claims. A drain cut short has
      // the next sync's pump to fall back on.
      if (_drainWrote > 0 && !_stopped) {
        // A callback that throws is the caller's problem, never this drain's:
        // the messages are already written and re-running them would cost a
        // second set of model calls for the same verdicts.
        try {
          await _onDrained?.call();
        } catch (_) {}
      }
    } finally {
      _running = false;
    }
  }

  /// Up to [_concurrency] messages at the model server at once.
  ///
  /// What makes that safe is the claim: [MessageStore.claimPendingTriage] is
  /// one UPDATE…RETURNING, so choosing a message and taking it off the pending
  /// list are the same indivisible step. Two concurrent drains — or two
  /// iterations of this loop, which suspends on the claim now — can never see
  /// the same row: whichever claim lands second finds nothing pending to match
  /// and comes back null.
  Future<void> _drain() async {
    _drainWrote = 0;
    _deferred.clear();
    var parked = false;
    // [_halted] and not [_stopped]: the processing switch is read on every
    // launch decision, so an off lands on the message after the one already at
    // the server rather than at the end of the backlog.
    while (!_halted && !parked) {
      while (_inFlight.length < _concurrency && !_halted && !parked) {
        // Past the store's exclusion cap a deferred row would be handed
        // straight back — its second attempt spent in this drain rather than
        // the next, which is the opposite of what a deferral is for. So the
        // drain stops claiming here and the next pump carries on.
        if (_deferred.length >= MessageStore.maxTriageExclusions) break;
        final row = await _store.claimPendingTriage(
          sources: sources,
          excluding: _deferred.toList(),
        );
        if (row == null) break;
        _claimed.add(_claimKey(row));
        late final Future<void> future;
        // [ActivityLog.inSpan] gives this message its own tally, so three
        // concurrent messages' model calls land on three activity rows
        // instead of whichever records first.
        future = _log.inSpan(() => _triageOne(row)).then((carryOn) {
          if (!carryOn) parked = true;
        }).whenComplete(() => _inFlight.remove(future));
        _inFlight.add(future);
      }
      if (_inFlight.isEmpty) break;
      // Over a COPY: `whenComplete` mutates the set as each message lands.
      await Future.any(_inFlight.toList());
    }
    // A park — or a [stop] — stops new launches, never the requests already at
    // the server: those answers are paid for, and their results are kept.
    await Future.wait(_inFlight.toList());
  }

  static String _claimKey(Map<String, Object?> row) =>
      '${row['source'] as String? ?? 'email'}|'
      '${row['source_message_id'] as String? ?? ''}';

  /// One message, with a heartbeat under it.
  ///
  /// The heartbeat is what makes [MessageStore.reclaimStaleTriage] safe to run
  /// on every sync: a claim that is still being worked says so once a minute,
  /// so the watchdog's five-minute window can only close on a worker that is
  /// gone. Without it, the first message slower than the window would be
  /// handed to a second drain while the first was still waiting on the model.
  Future<bool> _triageOne(Map<String, Object?> row) {
    final id = row['source_message_id'] as String? ?? '';
    final source = row['source'] as String? ?? 'email';
    final beat = Timer.periodic(pipelineHeartbeatInterval, (_) {
      // A failed touch costs nothing: the window is five beats wide.
      _store.touchTriage(source, id).catchError((_) {});
    });
    return _triageClaimed(row, source, id).whenComplete(beat.cancel);
  }

  /// Everything one claimed message does. Returns false when the drain should
  /// launch nothing further rather than move on to the next message.
  Future<bool> _triageClaimed(
    Map<String, Object?> row,
    // Read off the claimed row rather than held on the class: one drain takes
    // messages from every source in [sources], and every store write and
    // activity row below is keyed by `(source, id)`.
    String source,
    String id,
  ) async {
    var current = row;
    var message = Message.fromRow(current);

    // The claim is what the bar means by `running`: the row is off the pending
    // list and this worker owns it.
    await _pipeline.noteTriage(source, id, state: 'running');

    // The row arrives already claimed — the statement that picked it is the
    // statement that wrote its `processing`. A crash mid-model-call therefore
    // leaves it claimed, which is exactly what [resetInterrupted] looks for at
    // the next launch.
    final sw = Stopwatch()..start();

    // The owner restored this one from the dropped pile, so no gate gets to
    // take it again. Read once and held for the whole claim, deliberately:
    // the stamp is the user's word and nothing inside a claim changes it —
    // the mid-claim re-read below refreshes body and headers, not that.
    //
    // It lives here rather than in `gates.dart` for the same reason
    // `MessageStore.stampStorylineId` lives in the store: the gate functions
    // stay pure judgements about a message, while the override is a fact
    // about what the user did with it. That belongs at the call site.
    final overridden = (current['gate_override'] as String?) == 'user';

    // One read per claim, reused by both tiers: the rule is the owner's word
    // about a sender and nothing inside a claim changes it. Skipped for a
    // restored row for the same reason the gates are — Restore is the escape
    // hatch from every gate, this one included.
    final from = message.fromAddress ?? '';
    final senderDisposition = overridden || from.isEmpty
        ? null
        : await _store.getSenderPref(from);

    // Tier one, on the delta page's own fields. Free, and it is what keeps
    // the fetch below off every no-reply and every message the user sent.
    final senderGate = overridden
        ? null
        : gateFor(
            message,
            userAddress: _userAddress,
            senderDisposition: senderDisposition,
          );
    if (senderGate != null) {
      // No activity row, here or at the header gate below. A `triage` row
      // means the model was consulted, and a gate is the mechanism that keeps
      // it from being — one row per newsletter would bury the work the panel
      // exists to show under the mail that never cost anything.
      await _writeTriage(
        source,
        id,
        status: 'skipped',
        gateReason: senderGate,
      );
      // The thread hears about the gate. The fold at ingest reads only kept
      // messages, and this message was kept until a moment ago — so the
      // thread may be asking for a reply to something that will never reach
      // a model. One direction: a gate can only take an obligation away.
      // BEFORE `_emit()`, so the reload the rails do behind that tick reads
      // the state this just wrote rather than the one it replaced.
      await _store.refoldThreadState(source, id, restored: false);
      await _notifyGated(source, id);
      await _emit();
      return true;
    }

    // Tier two, and only for what survived tier one. Skipped entirely for a
    // message that already has both — a thread the user opened was fetched then.
    //
    // Mail only, and that is a correctness guard rather than an optimisation:
    // `source_meta_json` is where headers live and only the mail sync writes
    // it, so EVERY chat row has empty headers and would ask for a mail detail
    // fetch that cannot succeed. A chat message's body already arrived whole
    // at ingest — there is no second Graph call that would improve it.
    final fetch = _ensureBody;
    var fetchFailed = false;
    if (fetch != null &&
        source == 'email' &&
        (message.bodyText?.isNotEmpty != true || message.headers.isEmpty)) {
      try {
        await fetch(id);
        current = await _store.getMessageRow(source, id) ?? current;
        message = Message.fromRow(current);
      } on NotSignedIn {
        return _parkForSession(source, id, sw.elapsedMilliseconds);
      } on ReconsentRequired {
        return _parkForSession(source, id, sw.elapsedMilliseconds);
      } catch (_) {
        // Degraded, not parked: this message is classified from its preview
        // and the drain carries on — unless the deferral below applies.
        fetchFailed = true;
      }
    }

    // The one shape of degraded fetch worth another attempt. Decided after the
    // catch rather than inside it, so the branch reads as what it is: the
    // fetch failed, and now the message is judged on what it left behind.
    if (fetchFailed &&
        message.headers.isEmpty &&
        _deferHeaderless(current, message)) {
      final attempts = ((current['triage_attempts'] as num?)?.toInt() ?? 0) + 1;
      // BEFORE the write, so no claim in this drain can pick the row back up
      // between the two: it is about to be the newest pending message again.
      _deferred.add((source: source, id: id));
      await _writeTriage(source, id, status: 'pending', attempts: attempts);
      await _log.record(
        'triage',
        status: 'retry',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: {'reason': 'headerless', 'attempts': attempts},
      );
      await _emit();
      // The drain is healthy; only this one fetch was not.
      return true;
    }

    // Again, because the gates that read headers had nothing to read a moment
    // ago. Re-running the sender gate too is free and keeps this one call
    // the single place a gate decision is made.
    final headerGate = overridden
        ? null
        : gateFor(
            message,
            userAddress: _userAddress,
            senderDisposition: senderDisposition,
          );
    if (headerGate != null) {
      await _writeTriage(
        source,
        id,
        status: 'skipped',
        gateReason: headerGate,
      );
      // Same as tier one, and for every reason it gives — including the
      // chat gate, which reaches here too: a message that stripped down to
      // nothing is a message the model will never read.
      await _store.refoldThreadState(source, id, restored: false);
      await _notifyGated(source, id);
      await _emit();
      return true;
    }

    // The thread is context for `reply_expected`: an unanswered question a few
    // messages back still expects an answer, and this message on its own does
    // not say so. Only what came BEFORE it — a later message is not context
    // for a judgement about this one. TriageTask takes the last few.
    // Names and sizes, never contents: the line this feeds is metadata the
    // connector already wrote, so it costs a local query and no network at all.
    // The rows are here by now for mail because the detail fetch above wrote
    // them, and for chat because the ingest loop did; a failed fetch simply
    // leaves the list empty and the line absent.
    final attachments = await _store.attachmentsForMessage(source, id);
    final key = current['conversation_key'] as String?;
    // Hydrated from the rows just read — `loadThread` does this for a whole
    // thread; a single-row read has to ask. The block the model sees
    // synthesises "Shared a file: …" from these, so a chat message that is
    // nothing but a dropped contract stops arriving with an empty body.
    if (attachments.isNotEmpty) {
      message = message.withAttachments([
        for (final row in attachments)
          AttachmentRef.fromRow(row, conversationKey: key),
      ]);
    }

    var thread = const <Message>[];
    if (key != null && key.isNotEmpty) {
      final loaded = await _store.loadThread(key, sources: [source]);
      final receivedAt = message.receivedAt ?? '';
      thread = [
        for (final m in loaded)
          if (m.id != message.id &&
              (m.receivedAt ?? '').compareTo(receivedAt) <= 0)
            m,
      ];
    }

    try {
      final result = await runTask(
        _client,
        const TriageTask(),
        TriageInput(
          message,
          DateTime.now(),
          thread: thread,
          attachments: attachments,
        ),
      );
      await _writeTriage(source, id, status: 'triaged', result: result);
      await _foldUp(source, current, message, result);
      // What the model decided, on the row. The `llm_*` tally the call itself
      // reported folds in from the log's pending slot.
      await _log.record(
        'triage',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: {
          'urgency': result.urgency,
          'category': result.category,
          'needs_action': result.needsAction,
          'action_items': result.actionItems.length,
          'reply_expected': result.replyExpected,
          if (result.deadline.isNotEmpty) 'deadline': result.deadline,
        },
      );
      await _emit();
      return true;
    } on LlmUnavailableException {
      // Nothing about this message failed, so it does not spend an attempt.
      // The drain launches nothing more either: every message behind it would
      // fail identically, and marking a hundred of them is just noise on a
      // laptop where the model server is not running. Triage is one kind on
      // one server, so unlike the AI worker there is no other queue here that
      // a different server could still be answering for.
      await _writeTriage(source, id, status: 'pending');
      await _log.record(
        'triage',
        status: 'parked',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: {'reason': 'model_unavailable'},
      );
      await _emit();
      return false;
    } on LlmException catch (e) {
      return _recordFailure(
        source,
        current,
        id,
        e,
        e.statusCode,
        sw.elapsedMilliseconds,
      );
    } catch (e) {
      return _recordFailure(
        source,
        current,
        id,
        e,
        null,
        sw.elapsedMilliseconds,
      );
    }
  }

  /// Whether a failed fetch on this message is worth one more attempt instead
  /// of a headerless classification.
  ///
  /// Three conditions, and each narrows it: mail only (a chat has no detail
  /// fetch to retry), a sender whose local part looks like a machine (the mail
  /// whose verdict the missing headers would actually have changed), and an
  /// attempt still left.
  ///
  /// The counter is [_maxAttempts], shared with the model failures, on
  /// purpose. Bounded means bounded: a message the fetch keeps failing on and
  /// a message the model keeps refusing to parse are the same message from the
  /// queue's point of view — one that has had its turns. A second constant
  /// would be a second thing to reason about for no behaviour anyone wants.
  bool _deferHeaderless(Map<String, Object?> row, Message message) {
    if (message.source != 'email') return false;
    final from = message.fromAddress?.toLowerCase() ?? '';
    if (from.isEmpty) return false;
    final at = from.indexOf('@');
    if (!suspectMachineSender(at >= 0 ? from.substring(0, at) : from)) {
      return false;
    }
    return ((row['triage_attempts'] as num?)?.toInt() ?? 0) < _maxAttempts;
  }

  /// A callback that throws is not this drain's problem: the verdict is
  /// already written, and the repair it names has its own one-shot behind it.
  Future<void> _notifyGated(String source, String id) async {
    try {
      await _onGated?.call(source, id);
    } catch (_) {}
  }

  /// Every write that ends this queue's interest in a message, and the claim
  /// release that goes with it.
  ///
  /// One wrapper rather than a `_claimed.remove` beside each of the six write
  /// sites: a path that wrote a result and forgot to release would leave
  /// [dispose] holding a claim on a message that is already finished.
  Future<void> _writeTriage(
    String source,
    String id, {
    required String status,
    TriageResult? result,
    String? error,
    String? gateReason,
    int? attempts,
  }) async {
    await _store.writeTriage(
      source,
      id,
      status: status,
      result: result,
      error: error,
      gateReason: gateReason,
      attempts: attempts,
    );
    // Mapped here rather than at the six call sites, and `pending` is a real
    // answer among them: a park is the bar going back to waiting, not a stage
    // that finished.
    await _pipeline.noteTriage(
      source,
      id,
      state: switch (status) {
        'triaged' => 'done',
        'skipped' => 'skipped',
        'error' => 'error',
        _ => 'pending',
      },
      urgency: result?.urgency,
      gateReason: gateReason,
    );
    // The two statuses that mean triage REACHED a verdict, which is what the
    // AI worker was waiting to hear. A park writes `pending` and is not a
    // verdict at all. A spent `error` is terminal and does make the message
    // claimable, but it is not counted here: it arrives on a drain the model
    // was failing through, and waking a second drain onto the same servers is
    // the last thing that moment needs. The next sync's pump picks it up.
    if (status == 'triaged' || status == 'skipped') _drainWrote++;
    _claimed.remove('$source|$id');
  }

  /// The session is over, so every message behind this one would fail its
  /// fetch identically. The row goes back to `pending` without spending an
  /// attempt — nothing is wrong with the message — and the drain parks. The
  /// sign-out routing lives in the inbox notifier; triage's whole job here is
  /// to stop burning model time on previews it cannot improve on.
  Future<bool> _parkForSession(String source, String id, int durationMs) async {
    await _writeTriage(source, id, status: 'pending');
    await _log.record(
      'triage',
      status: 'parked',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {'reason': 'session'},
    );
    await _emit();
    return false;
  }

  Future<bool> _recordFailure(
    String source,
    Map<String, Object?> row,
    String id,
    Object error,
    int? statusCode,
    int durationMs,
  ) async {
    final attempts = ((row['triage_attempts'] as num?)?.toInt() ?? 0) + 1;
    // A 400 from a json_schema request is this app's schema being wrong, not
    // the model's answer. It is identical on every retry, so retrying it
    // burns model time to reproduce a bug.
    final fatal = statusCode == 400 || attempts >= _maxAttempts;
    await _writeTriage(
      source,
      id,
      status: fatal ? 'error' : 'pending',
      error: redactEndpoints('$error'),
      attempts: attempts,
    );
    // `retry` while the message still has an attempt left, `error` once it
    // does not — the row says which of the two this was, where the message's
    // own `pending` status cannot.
    await _log.record(
      'triage',
      status: fatal ? 'error' : 'retry',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {
        // Redacted, as the worker's twin is: a 4xx body or a handler's own
        // sentence can echo an address, and an address is a setting, not a row.
        'error': redactEndpoints('$error'),
        'attempts': attempts,
        'status_code': ?statusCode,
      },
    );
    await _emit();
    return true;
  }

  /// Copies one message's result up onto its conversation — but only when the
  /// message is the thread's newest inbound, and only while the user has not
  /// already replied to it.
  ///
  /// Without the newest-inbound check a backlog would end up showing the wrong
  /// ask: the worker runs newest-first, so an older message finishing later
  /// would overwrite a current CTA with one from last week.
  ///
  /// Without the already-replied check a RE-triage would resurrect a dead ask.
  /// Ingest clears the CTA on exactly the outbound that answers it
  /// ([outboundResolves]); anything that sends the same message through triage
  /// again afterwards — a re-judgment backfill, an error revive, a reply that
  /// lands before the first drain gets there — would write that ask straight
  /// back, along with the urgency multiplier that pushes an answered thread
  /// into Needs You. The tie goes to the reply, matching [outboundResolves]:
  /// an outbound at the same instant as the inbound counts as the answer.
  Future<void> _foldUp(
    String source,
    Map<String, Object?> row,
    Message message,
    TriageResult result,
  ) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
    if (conversation == null) return;

    final lastInbound = conversation['last_inbound_at'] as String?;
    final receivedAt = message.receivedAt ?? '';
    if (lastInbound != null &&
        lastInbound.isNotEmpty &&
        receivedAt.compareTo(lastInbound) < 0) {
      return;
    }

    final lastOutbound = conversation['last_outbound_at'] as String?;
    if (lastOutbound != null &&
        lastOutbound.isNotEmpty &&
        lastOutbound.compareTo(receivedAt) >= 0) {
      return;
    }

    // The first action item is the ask, in the imperative the model was asked
    // for. With no items, a summary stands in only when the message actually
    // needs something — a summary shown as a CTA on mail that needs nothing
    // reads as work that isn't there.
    var ask = result.actionItems.isNotEmpty
        ? result.actionItems.first
        : (result.needsAction ? result.summary : null);

    // The deadline rides the banner for free — "Send the invoice — by Friday"
    // is the line the row wanted anyway. Appended BEFORE the clamp below, so
    // the pair stays honest: a long ask loses its own tail rather than ending
    // up with a deadline the cap would have cut in half.
    if (ask != null && ask.isNotEmpty && result.deadline.isNotEmpty) {
      ask = '$ask — by ${result.deadline}';
    }

    await _store.updateConversationTriage(
      source,
      key,
      ctaText: (ask == null || ask.isEmpty)
          ? null
          : (ask.length > _ctaCap ? ask.substring(0, _ctaCap) : ask),
      ctaUrgency: result.urgency,
      category: result.category,
    );
  }

  /// Awaited by every caller, never fired and forgotten: the counts are read
  /// from the rows, so an unawaited emit would be free to report a queue that
  /// has already moved on.
  Future<void> _emit() async {
    if (_progress.isClosed) return;
    final counts = await _store.triageCounts(sources: sources);
    if (_progress.isClosed) return;
    _progress.add(TriageProgress(counts));
  }
}
