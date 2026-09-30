import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'decision/decision_client.dart';
import 'decision/decision_heads.dart';
import 'decision/decision_input.dart';
import 'decision/decision_policy.dart';
import 'decision/needs_you_predicate.dart';
import 'decision/decision_questions.dart' show decisionQhash;
import 'drain_gate.dart';
import 'gates.dart';
import 'backend/backend_types.dart';
import 'conversation_cta.dart';
import 'llm/llm_client.dart';
import 'needs_you.dart' show needsYouFloor;
import 'owner_lookup.dart';
import 'pipeline_progress.dart';

/// How much triage is left, as of the last message the worker finished.
///
/// Built from the store's own counts rather than from a counter the worker
/// keeps, so it is correct across a restart and cannot drift: the numbers are
/// the rows.
class TriageProgress {
  /// `triage_status` → row count. Statuses with no rows are absent.
  final Map<String, int> counts;

  /// Why the last claim parked, or null when nothing is parked.
  ///
  /// `'model_unavailable'`, `'unauthorized'` or `'session'` — the same words
  /// the parked activity row carries. It rides the progress stream because
  /// the fact already exists inside the drain and dies there otherwise, and
  /// the alternative would be a health poller nobody wants. Cleared on the
  /// next pump and on the next message that reached a verdict, so the rail's
  /// sentence goes away by work getting done rather than by a timer.
  final String? parkedReason;

  const TriageProgress(this.counts, {this.parkedReason});

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

  final MessageStore _store;
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
  ///
  /// It is handed the `(source, id)` pairs this drain wrote a verdict for, so
  /// the worker can run those messages' own work before it resumes the
  /// backlog. A COPY is passed: the list is reused by the next drain.
  final Future<void> Function(List<({String source, String id})> triaged)?
      _onDrained;

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

  /// The same verdicts as [_drainWrote], as the pairs that name them.
  ///
  /// `skipped` rides along with `triaged` on purpose: both are verdicts that
  /// unblock the work queue's untriaged guard, and the handlers' own
  /// `skipped` branch is what closes those rows. Cleared per drain beside
  /// [_drainWrote], and handed to [_onDrained] as a copy.
  final List<({String source, String id})> _triagedNow = [];

  /// Why the last claim parked, or null. Published on every [TriageProgress],
  /// set at the two park sites, and cleared by a pump and by a message that
  /// reached a verdict.
  String? _parkedReason;

  String? _userAddress;
  bool _running = false;
  bool _stopped = false;

  /// Whether the app's processing switch is ON, or null where nobody wired one
  /// — every test, and any caller from before the switch existed. A CLOSURE,
  /// for `AiWorker._enabled`'s reason: the switch moves while a drain is
  /// running and a value captured here would only take effect at the next
  /// rebuild.
  final bool Function()? _enabled;

  /// The decision model, which classifies every kept message: the learned
  /// gate, urgency, category, needs_action and reply_expected. It is the only
  /// model this queue calls — the message's text (summary, action items,
  /// deadline) is the message-text stage's, on the fast lane behind it — so
  /// it is required: there is no triage without it.
  final DecisionClient _decisionClient;

  /// Who the owner is, for the decision state's owner line — a keychain read
  /// in the app. [_askOwner] starts it at a pump and a claim uses
  /// [_ownerKnown], whatever has arrived — after waiting at most
  /// [_ownerWait] for a lookup still in flight ([_awaitOwner]). The first
  /// claims after launch are the ones that race it: a Teams message has no
  /// body fetch to give the keychain time, and a state with no owner line is
  /// not the state the heads were trained on — the gate, reply and urgency
  /// heads read it too, not only needs-you. Never longer than that, for the
  /// self gate's `userAddress` reason: a read that has not answered must not
  /// hold the drain.
  final OwnerLookup? _owner;
  OwnerIdentity? _ownerKnown;
  bool _ownerAsking = false;

  /// The lookup [_askOwner] started, until it settles or a claim has waited
  /// [_ownerWait] for it once. Null means nobody waits.
  Future<void>? _ownerAsk;

  /// The one wait the claims launched together share, and its timer. Held
  /// so [quiesce] can end it: a test's fake clock never reaches 300 ms after
  /// its tree is gone, and a timer left behind fails the test.
  Completer<void>? _ownerWaiting;
  Timer? _ownerTimer;

  /// How long a claim waits for an owner lookup still in flight.
  static const Duration _ownerWait = Duration(milliseconds: 300);

  /// The owner's Needs You slider, for [applyDecision]'s chip rule: a
  /// settled row whose answer at the slider a decision moves has its chip
  /// moved with it. Null in a test that wires none, which reads the default.
  final Future<double> Function()? _threshold;

  TriageQueue(
    this._store, {
    required this._decisionClient,
    this._userAddress,
    this._ensureBody,
    DrainGate? gate,
    this._concurrency = 3,
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
    this._enabled,
    this._onDrained,
    this._onGated,
    this._owner,
    Future<double> Function()? needsYouThreshold,
  })  : _gate = gate ?? DrainGate(),
        _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress,
        _threshold = needsYouThreshold;

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
    // A claim waiting for the owner goes on now, ownerless, so the loop
    // below has something to wait for that ends.
    _endOwnerWait();
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
    // A new pump is a fresh attempt, so the last park is no longer the news.
    // If the server is still down the first claim parks again and the reason
    // comes straight back.
    _parkedReason = null;
    if (_running) return;
    _running = true;
    try {
      // Before the first message, not after it: the header counter would
      // otherwise sit blank for the seventeen seconds that message takes,
      // which is exactly when a user with a fresh backlog is looking for it.
      final counts = await _emit();
      // Nothing pending means nothing to claim, so the gate is not taken at
      // all. It used to be — the drain would claim null and return — and the
      // wait for it is what made that wrong: a pump over an empty queue does
      // not ask for a yield (a worker's pass ended every minute for nothing
      // is the cost that guard exists to avoid), so this run would sit
      // TICKETLESS behind a worker drain that can hold the gate for hours,
      // with [_running] latched — and the latch returns every later pump at
      // the check above, so the mail that arrives mid-backlog can never ask
      // for the yield that would let it through. Skipping the gate leaves
      // [_running] free, and the first pump that finds that mail asks and
      // enqueues in the same step, exactly as [DrainGate.yieldRequested]
      // promises.
      if ((counts['pending'] ?? 0) == 0) return;
      // Who the owner is, for the decision state — started here; a claim
      // waits a moment for it at most (see [_owner]).
      _askOwner();
      // Asked in the same synchronous step as the `_gate.run` below, which is
      // what makes the flag transient — this run holds the ticket that clears
      // it. See [DrainGate.yieldRequested].
      _gate.requestYield();
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
          await _onDrained?.call(List.of(_triagedNow));
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
    _triagedNow.clear();
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

    // The owner line, then the decision state's inputs. Waiting on the owner
    // first (see [_owner]) costs at most [_ownerWait], and a lookup that has
    // not answered by then leaves the state ownerless, which the needs-you
    // pass reads as a probability to decide again rather than to trust.
    await _awaitOwner();
    final owner = decisionOwnerString(_ownerKnown);
    final input = await decisionInputFor(
      _store,
      source,
      message,
      conversationKey: current['conversation_key'] as String?,
      owner: owner,
    );

    try {
      // The decision pass: one forward pass of the decision model answers
      // every classification question from the message's rendered state. It
      // is the only model call triage makes — the text is the message-text
      // stage's, behind it on the fast lane. INSIDE this try on purpose: a
      // decision server that is down throws [DecisionUnavailableException],
      // an [LlmUnavailableException], so the message parks under
      // `decision_unavailable` — as does, under its own word, every fault
      // that would fail every message alike (a refused heads file, a server
      // that is not the decision model: `decision_misconfigured`) and a
      // missing install (`decision_not_installed`). Every park is retried by
      // the next pump, so a fixed address or a fresh install recovers with
      // nobody pressing anything. Only a 4xx the server gives this one
      // request is a failure that spends an attempt.
      final decided = await _decisionClient.decide(input);

      // The learned gate, after the rules gates and under the same escape
      // hatch: a message the owner restored is never gated again. Shaped
      // like the header gate above, plus an activity row, because unlike a
      // rules gate this one DID consult a model. A Teams 1:1 or @mention
      // ([needsYouFloor]) is never learned-gated either: somebody wrote to
      // the owner by name, which the needs-you floor treats as settled, and
      // before the decision model no gate ever took one.
      final learned = overridden || needsYouFloor(current)
          ? null
          : learnedGateReason(decided.answers);
      if (learned != null) {
        // The drop's decision row, and nothing else of [applyDecision]: a
        // gated message carries no triage fields and no needs-you number.
        // Clear AI results tells a learned drop from an ingest verdict by
        // this row (`clearDerived`'s `keptGate`).
        await _store.writeDecision(
          source,
          id,
          decided,
          qhash: decisionQhash,
          ownerKnown: owner != null,
        );
        await _writeTriage(
          source,
          id,
          status: 'skipped',
          gateReason: learned,
        );
        await _store.refoldThreadState(source, id, restored: false);
        await _notifyGated(source, id);
        await _log.record(
          'triage',
          status: 'skipped',
          source: source,
          entityId: id,
          durationMs: sw.elapsedMilliseconds,
          detail: {
            // `reason` is what the activity panel prints on a skipped row.
            'reason': learned,
            'gate': learned,
            'learned': true,
            'gate_p': _p2(decided.answers.p('gate', 'drop')),
            'decision_ms': decided.latencyMs,
          },
        );
        await _emit();
        return true;
      }

      // Everything the decision determines, through the one writer the
      // re-decide and the needs-you pass share. The row's verdict is written
      // ONCE, with the four fields, between the decision row and the
      // needs-you number: the rail, notify-worthy and the bucket filing
      // react now, and the text fills in when the message-text stage lands
      // (it refolds the CTA then). An ownerless decision's number is written
      // too, and SHOWN, but it is untrusted (the head was trained with the
      // owner line): `message_decisions.owner_known` records that, and the
      // needs-you pass decides the message again once the owner is known.
      final result = decidedTriage(decided.answers);
      await applyDecision(
        _store,
        source,
        current,
        decided,
        ownerKnown: owner != null,
        progress: _pipeline,
        threshold: _threshold,
        verdict: (fields) => _writeTriage(
          source,
          id,
          status: 'triaged',
          result: fields,
        ),
      );
      // A kept message with no text yet is owed its message-text call. What
      // this is for is a revived errored or terminal triage row from before
      // the decision model: its `extract` row closed `done` back when triage
      // wrote the summary, so without this it would stay triaged with no text
      // for good. The same repair `rependGatedTriage` makes, with no fresh
      // stamp, because nobody asked. Only a FINISHED row is revived: new mail
      // has a pending one already, and a message the sync queued no text for
      // gets none from here either (`requeueWork` alone would insert one).
      if (message.summary == null) {
        final text = await _store.workStatusOf('extract', source, id);
        if (text == 'done' || text == 'error') {
          await _store.requeueWork('extract', source, id);
        }
      }
      // What the decision model said, on the row. Its numbers ride in their
      // own key as well, because the log keeps one label per span.
      await _log.record(
        'triage',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: {
          'urgency': result.urgency,
          'category': result.category,
          'needs_action': result.needsAction,
          'reply_expected': result.replyExpected,
          'decision': decisionLine(decided),
        },
      );
      await _emit();
      return true;
    } on LlmUnavailableException catch (e) {
      // Nothing about this message failed, so it does not spend an attempt.
      // The drain launches nothing more either: every message behind it would
      // fail identically, and marking a hundred of them is just noise on a
      // laptop where the model server is not running. Triage is one kind on
      // one server, so unlike the AI worker there is no other queue here that
      // a different server could still be answering for.
      //
      // A refused key is the same park with a different reason, because it is
      // the same fact about every message behind this one — and the rail can
      // then say which of the two it is.
      final reason = parkReasonFor(e);
      _parkedReason = reason;
      await _writeTriage(source, id, status: 'pending');
      await _log.record(
        'triage',
        status: 'parked',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: {'reason': reason},
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

  /// Starts the owner lookup when the owner is not yet known and no lookup is
  /// in flight. Not awaited here (see [_owner]); a throw or a null answer
  /// leaves the owner unknown, and the next pump asks again.
  void _askOwner() {
    final lookup = _owner;
    if (lookup == null || _ownerKnown != null || _ownerAsking) return;
    _ownerAsking = true;
    late final Future<void> asking;
    asking = Future<OwnerIdentity?>.sync(lookup).then<void>(
      (owner) {
        _ownerKnown = owner;
      },
      onError: (Object _) {},
    ).whenComplete(() {
      _ownerAsking = false;
      if (identical(_ownerAsk, asking)) _ownerAsk = null;
    });
    _ownerAsk = asking;
  }

  /// Waits for an owner lookup still in flight, [_ownerWait] at most, then
  /// lets the claim go on with whatever is known. The claims launched
  /// together wait on the one lookup together, and a lookup that outlives
  /// the wait is waited for ONCE: after it, no claim waits on it again, so a
  /// keychain that never answers costs the first claims 300 ms and the rest
  /// nothing.
  Future<void> _awaitOwner() {
    final asking = _ownerAsk;
    if (_ownerKnown != null || asking == null) return Future.value();
    final shared = _ownerWaiting;
    if (shared != null) return shared.future;
    final waiting = _ownerWaiting = Completer<void>();
    void finish() {
      if (identical(_ownerWaiting, waiting)) {
        _ownerTimer?.cancel();
        _ownerTimer = null;
        _ownerWaiting = null;
      }
      if (!waiting.isCompleted) waiting.complete();
    }

    _ownerTimer = Timer(_ownerWait, () {
      // Waited for once: no later claim waits on this lookup again.
      if (identical(_ownerAsk, asking)) _ownerAsk = null;
      finish();
    });
    asking.whenComplete(finish);
    return waiting.future;
  }

  /// Ends a wait for the owner early, for [quiesce]: the claims waiting go
  /// on ownerless and nothing waits on the lookup again.
  void _endOwnerWait() {
    _ownerTimer?.cancel();
    _ownerTimer = null;
    _ownerAsk = null;
    final waiting = _ownerWaiting;
    _ownerWaiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// How far back the install-time re-decide reaches, in days.
  static const int redecideDays = 30;

  /// The most messages one re-decide takes, newest first. At about 40 ms a
  /// decision that is under a minute and a half of the decision server.
  static const int redecideCap = 2000;

  /// Re-decides the recent kept inbound messages a decision model trained on
  /// another question set decided — [redecide] over
  /// [MessageStore.staleDecisionRefs], the last [redecideDays] days, newest
  /// first, at most [redecideCap]. The install-time one-shot the mail sync
  /// runs when this build's heads are new (`SyncService`'s
  /// `redecide_qhash`): without it every message decided under the old model
  /// reads as undecided to the Why panel, extraction and drafting, and keeps
  /// the old model's numbers.
  ///
  /// `complete` is false when the switch is off or the decision model parked
  /// on the way (see [redecide]); what was re-decided or settled as failed
  /// stays so and drops out of the next run's list, so the next sync resumes
  /// where this one stopped.
  ///
  /// While the triage drain itself is parked on the decision model (the heads
  /// are an older model's, not installed, or the server is down), nothing is
  /// asked at all: the answer is already known, and asking would only write
  /// the same park again on every sync.
  Future<({int redecided, bool complete})> redecideStale({
    DateTime? now,
  }) async {
    if (_off) return (redecided: 0, complete: false);
    if (_parkedReason?.startsWith('decision_') ?? false) {
      return (redecided: 0, complete: false);
    }
    final since = MessageStore.isoStamp(
      (now ?? DateTime.now())
          .toUtc()
          .subtract(const Duration(days: redecideDays)),
    );
    return redecide(await _store.staleDecisionRefs(
      qhash: decisionQhash,
      sinceIso: since,
      limit: redecideCap,
    ));
  }

  /// The DECISION pass again for [refs], and nothing else of triage: the
  /// same state ([decisionInputFor]) and the same writer the claim uses,
  /// [applyDecision]. It never touches the text, the gate verdict or
  /// `triage_status`, and it never gates: a message kept once stays kept.
  /// Nor does it revisit a message gated before: it reads only `triaged`
  /// rows, so a drop the older model's learned gate made stays dropped, by
  /// design — Restore is the owner's way back for one it got wrong.
  ///
  /// Outside the drain and its claims on purpose. A message re-pended
  /// meanwhile is left to the triage that re-pended it.
  ///
  /// A decision server that is down, not installed, misconfigured or
  /// refusing the key PARKS it the way it parks a triage claim: it stops at
  /// that message and answers `complete: false`. The park is logged once per
  /// question set and reason per app run ([_redecideParksLogged]), so a model
  /// that stays parked for a week does not write a row on every sync.
  ///
  /// A 4xx this one request earned SETTLES the message for this question set
  /// ([MessageStore.settleFailedDecision]): it keeps its old numbers, reads
  /// as undecided, and leaves the stale list, so the same bad message is
  /// never asked again by this one-shot. A run that did not park is
  /// therefore complete, however many messages it settled that way.
  Future<({int redecided, bool complete})> redecide(
    List<({String source, String id})> refs,
  ) async {
    _askOwner();
    await _awaitOwner();
    final owner = decisionOwnerString(_ownerKnown);
    var redecided = 0;
    for (final ref in refs) {
      if (_off) return (redecided: redecided, complete: false);
      final row = await _store.getMessageRow(ref.source, ref.id);
      if (row == null || row['triage_status'] != 'triaged') continue;
      final input = await decisionInputFor(
        _store,
        ref.source,
        Message.fromRow(row),
        conversationKey: row['conversation_key'] as String?,
        owner: owner,
      );
      final DecisionResult decided;
      try {
        decided = await _decisionClient.decide(input);
      } on LlmUnavailableException catch (e) {
        final reason = parkReasonFor(e);
        if (_redecideParksLogged.add('$decisionQhash|$reason')) {
          await _log.record(
            'triage',
            status: 'parked',
            source: ref.source,
            entityId: ref.id,
            detail: {'reason': reason, 'redecide': true},
          );
        }
        return (redecided: redecided, complete: false);
      } on LlmException {
        await _store.settleFailedDecision(
          ref.source,
          ref.id,
          qhash: decisionQhash,
        );
        continue;
      }
      await applyDecision(
        _store,
        ref.source,
        row,
        decided,
        ownerKnown: owner != null,
        progress: _pipeline,
        threshold: _threshold,
      );
      redecided++;
    }
    return (redecided: redecided, complete: true);
  }

  /// The re-decide parks already logged this app run, as
  /// `'<qhash>|<park reason>'`.
  final Set<String> _redecideParksLogged = {};

  /// The row state the decision model's answers make: urgency and category
  /// are the heads' choices, and the two booleans are their
  /// yes-probabilities against the policy bars (`booleanYes` for
  /// needs_action, `replyYes` for reply_expected). No text: the
  /// message-text stage writes that.
  static TriageResult decidedTriage(DecisionAnswers a) => TriageResult(
        urgency: a['urgency'].choice,
        category: a['category'].choice,
        needsAction: a.p('needs_action', 'yes') >= DecisionPolicy.booleanYes,
        replyExpected: a.p('reply_expected', 'yes') >= DecisionPolicy.replyYes,
      );

  static String _p2(double p) => p.toStringAsFixed(2);

  /// The one line a triage activity row carries about the decision pass of a
  /// KEPT message: `gate=keep urgency=high category=work na=0.81 re=0.12
  /// ny=0.77 (58 ms)`. `gate=keep` is the verdict, not the head's argmax: a
  /// drop below the bar, a cold approach and a restored message all land here.
  static String decisionLine(DecisionResult d) {
    final a = d.answers;
    return 'gate=keep '
        'urgency=${a['urgency'].choice} '
        'category=${a['category'].choice} '
        'na=${_p2(a.p('needs_action', 'yes'))} '
        're=${_p2(a.p('reply_expected', 'yes'))} '
        'ny=${_p2(a.p('needs_you', 'yes'))} '
        '(${d.latencyMs} ms)';
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
    if (status == 'triaged' || status == 'skipped') {
      _drainWrote++;
      _triagedNow.add((source: source, id: id));
      // A message got through, so whatever the last park was about is over.
      // Here rather than at the two verdict call sites, so a third one cannot
      // be added that forgets to clear it.
      _parkedReason = null;
    }
    _claimed.remove('$source|$id');
  }

  /// The session is over, so every message behind this one would fail its
  /// fetch identically. The row goes back to `pending` without spending an
  /// attempt — nothing is wrong with the message — and the drain parks. The
  /// sign-out routing lives in the inbox notifier; triage's whole job here is
  /// to stop burning model time on previews it cannot improve on.
  Future<bool> _parkForSession(String source, String id, int durationMs) async {
    _parkedReason = 'session';
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

  /// Awaited by every caller, never fired and forgotten: the counts are read
  /// from the rows, so an unawaited emit would be free to report a queue that
  /// has already moved on.
  /// Returns the counts it read, so a caller that needs them — [pump],
  /// deciding whether a yield is worth asking for — does not run a second
  /// aggregate query over the same rows. Empty when the stream is closed and
  /// nothing was read.
  Future<Map<String, int>> _emit() async {
    if (_progress.isClosed) return const {};
    final counts = await _store.triageCounts(sources: sources);
    if (_progress.isClosed) return counts;
    _progress.add(TriageProgress(counts, parkedReason: _parkedReason));
    return counts;
  }
}

/// The decision model's input for one message: the message with its
/// attachment rows hydrated, and the thread as it stood when it landed.
///
/// The ONE builder, shared by the triage pass and by the needs-you pass when
/// it decides a message again, so the two cannot render different states for
/// the same message. The attachment rows are metadata the connector already
/// wrote — a local query, no network: for mail the detail fetch wrote them,
/// for chat the ingest loop did, and a failed fetch leaves the list empty.
/// They are hydrated because the state renders an empty body as "Shared a
/// file: …" from them, so a chat message that is nothing but a dropped
/// contract is not judged as blank.
///
/// The thread is context for `reply_expected` and needs-you: an unanswered
/// question a few messages back still expects an answer. Only what came
/// BEFORE this message — a later one is not context for a judgement about it.
/// The decision state takes the last three.
Future<DecisionInput> decisionInputFor(
  MessageStore store,
  String source,
  Message message, {
  required String? conversationKey,
  String? owner,
}) async {
  final attachments = await store.attachmentsForMessage(source, message.id);
  final key = conversationKey ?? '';
  if (attachments.isNotEmpty) {
    message = message.withAttachments([
      for (final row in attachments)
        AttachmentRef.fromRow(row, conversationKey: key),
    ]);
  }
  var thread = const <Message>[];
  if (key.isNotEmpty) {
    final loaded = await store.loadThread(key, sources: [source]);
    final receivedAt = message.receivedAt ?? '';
    thread = [
      for (final m in loaded)
        if (m.id != message.id &&
            (m.receivedAt ?? '').compareTo(receivedAt) <= 0)
          m,
    ];
  }
  return DecisionInput.fromRows(
    message: message,
    thread: thread,
    attachments: message.attachments,
    owner: owner,
  );
}

/// Writes everything one decision determines about a kept message, except
/// its gate verdict and `triage_status`: the ONE writer the triage claim, the
/// install-time re-decide ([TriageQueue.redecide]) and the needs-you pass's
/// re-decide share, so no path can leave a message half decided.
///
/// In order: the decision row (with the question hash and whether the state
/// had an owner line); the four triage fields ([TriageQueue.decidedTriage]);
/// `needs_you_p` with its templated sentence; the intent and importance
/// inside an extraction that already ran; the thread's CTA fold
/// ([foldCtaUp], the ask from the text already on the row); and the Needs
/// You chip ([followNeedsYouChip]) when the answer at the owner's slider
/// moved from the p [row] carried.
///
/// [verdict] is the triage claim's own write of `triage_status` with the
/// four fields; when it is given it takes the fields' place in the order, so
/// the claim writes its row once. [row] is the message row as the caller
/// read it BEFORE deciding: its `needs_you_p` is the "before" of the chip
/// rule, and its text feeds the fold.
Future<void> applyDecision(
  MessageStore store,
  String source,
  Map<String, Object?> row,
  DecisionResult decided, {
  required bool ownerKnown,
  PipelineProgress progress = const PipelineProgress.disabled(),
  Future<double> Function()? threshold,
  Future<void> Function(TriageResult fields)? verdict,
}) async {
  final id = row['source_message_id'] as String? ?? '';
  final message = Message.fromRow(row);
  final previous = (row['needs_you_p'] as num?)?.toDouble();
  final answers = decided.answers;
  await store.writeDecision(
    source,
    id,
    decided,
    qhash: decisionQhash,
    ownerKnown: ownerKnown,
  );
  final fields = TriageQueue.decidedTriage(answers);
  if (verdict != null) {
    await verdict(fields);
  } else {
    await store.writeDecidedTriage(source, id, fields);
  }
  final p = needsYouP(answers);
  await store.writeNeedsYouP(
    source,
    id,
    p: p,
    reason: p == null ? null : needsYouYesReason(answers),
  );
  await store.rewriteExtractionDecision(
    source,
    id,
    intent: answers['intent'].choice,
    importance: answers['importance'].choice,
  );
  // The decision's urgency and category onto the thread now. The ask is the
  // text's: on a message with no summary yet the thread's current ask is left
  // alone until the text lands; one whose text already landed folds its ask
  // from that text again.
  await foldCtaUp(
    store,
    source,
    row,
    urgency: fields.urgency,
    category: fields.category,
    needsAction: fields.needsAction,
    summary: message.summary ?? '',
    actionItems: message.actionItems,
    deadline: message.deadline ?? '',
    textLanded: message.summary != null,
  );
  await followNeedsYouChip(
    progress,
    source,
    id,
    previous: previous,
    p: p,
    threshold: threshold,
  );
}

/// Moves a settled row's Needs You chip when — and only when — a new
/// probability changed the answer at the owner's threshold ([needsYouAt]),
/// through [PipelineProgress.refreshNeedsYou].
///
/// A repeat must write nothing, or a chip the user cleared by replying would
/// come back every time the row was re-judged; a probability that moved
/// without crossing the slider is a repeat of the answer. A row not settled
/// yet has no chip to move, and the store's write says so by writing nothing.
///
/// Nothing here can fail the caller. The recorder swallows its own errors,
/// and a [threshold] read that throws degrades to the default: a chip that
/// did not follow is a stale square on the home screen, and re-running a
/// model call over it would be the more expensive mistake.
Future<void> followNeedsYouChip(
  PipelineProgress progress,
  String source,
  String id, {
  required double? previous,
  required double? p,
  Future<double> Function()? threshold,
}) async {
  if (previous == p) return;
  var cut = NeedsYouTuning.defaultThreshold;
  if (threshold != null) {
    try {
      cut = await threshold();
    } catch (e) {
      debugPrint('needs_you: reading the needs-you threshold failed: $e');
    }
  }
  if (needsYouAt(previous, cut) == needsYouAt(p, cut)) return;
  await progress.refreshNeedsYou(source, id, threshold: cut);
}
