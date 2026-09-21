import 'dart:async';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'drain_gate.dart';
import 'backend/backend_types.dart';
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';

/// How much work of one kind is left, as of the last item the worker
/// finished.
///
/// Built from the store's own counts rather than a counter the worker keeps,
/// so it is correct across a restart and cannot drift: the numbers are the
/// rows.
class WorkProgress {
  /// Which queue this is about — `extract` today.
  final String kind;

  /// `status` → row count. Statuses with no rows are absent.
  final Map<String, int> counts;

  /// Why the last claim parked, or null when nothing is parked.
  ///
  /// `'model_unavailable'`, `'unauthorized'` or `'session'` — the same words
  /// the parked activity row carries. It rides the progress stream because
  /// the fact already exists inside the drain and dies there otherwise, and
  /// the alternative would be a health poller nobody wants. Cleared on the
  /// next pump and on the next item that succeeds, so the rail's sentence
  /// goes away by work getting done rather than by a timer.
  final String? parkedReason;

  const WorkProgress(this.kind, this.counts, {this.parkedReason});

  int get remaining => (counts['pending'] ?? 0) + (counts['processing'] ?? 0);

  int get total => counts.values.fold(0, (sum, n) => sum + n);

  int get done => total - remaining;
}

/// One kind of AI work, and how to do one item of it.
///
/// [run] signals failure by throwing, and what it throws decides what happens
/// next — see [AiWorker.pump]. In particular a handler that swallows an
/// [LlmUnavailableException] would keep the drain grinding through a hundred
/// items against a server that is not running.
abstract class WorkHandler {
  /// Matches `work_items.task_kind`.
  String get kind;

  /// How many items of this kind may be at the server at once.
  ///
  /// One by default, and that default is the safe answer rather than a
  /// performance oversight: a handler whose items touch shared state has to
  /// see them one at a time — a storyline assignment changes the clusters the
  /// next candidate is measured against, so two at once would each decide
  /// against a mailbox the other is mid-way through changing. A handler raises
  /// this only when its items are genuinely independent of each other, and
  /// then no higher than the server it calls has slots for.
  ///
  /// A handler may back this with a CLOSURE over a setting rather than a
  /// constant — `DraftHandler` reads the prose server's width from the prefs
  /// — because [AiWorker._drainAll] re-reads it on every launch decision. A
  /// width changed in Settings therefore moves the next item rather than the
  /// next launch of the app.
  int get concurrency => 1;

  /// One row from `work_items`. `entity_id` names what to work on.
  Future<void> run(Map<String, Object?> item);
}

/// What one item's outcome means for the rest of the drain.
///
/// Three cases and not two, because since phase 3 the kinds do not share a
/// model server: "extraction's server is down" and "the session is over" used
/// to imply each other and no longer do.
enum _RunOutcome {
  /// Done, or failed in a way that is about this item. Carry on.
  ok,

  /// This KIND's server is not answering. Every item of this kind behind it
  /// would fail identically — but another kind on another server would not.
  parkKind,

  /// The session is gone. Every kind's Graph-dependent work fails the same
  /// way, so the whole drain stops.
  parkDrain,
}

/// Drains the `work_items` queue through its handlers, a few items of one kind
/// at a time.
///
/// This is `TriageQueue`'s protocol, generalised over a task kind — the same
/// atomic claim, the same failure policy, the same park-on-unavailable — and
/// it is a COPY rather than a shared base class on purpose. Triage is
/// hard-wired to the `messages` table by decision: its queue, its gates and
/// its fold-up are one thing, and the seam that would let them be shared is
/// not worth the coupling.
///
/// Bounded-concurrent within one kind, at [WorkHandler.concurrency]. The GPU
/// reads the model's weights once per decode step no matter how many sequences
/// share it, so K requests in flight at one llama-server come back in nothing
/// like K times the wall clock of one — the aggregate is worth roughly 2.5-3x
/// a serial drain. K is small and per handler because the trade runs the other
/// way past a point: each individual request gets slower as the batch grows,
/// and both the client's timeout and the person watching for the first
/// result care about one request's latency, not the aggregate.
///
/// The kinds still drain in handler ORDER rather than interleaved, and that
/// has never been about the server: extraction writes the embeddings both
/// storyline passes compare, and a draft reads the storyline summary.
///
/// THREE instances of this class, not one — see `AiWorkers`. One list in one
/// worker meant the 27B's work sat in front of the 4B's and behind it: a
/// message that arrived while a recap was being written waited for the recap,
/// and a draft the user asked for waited for the whole pass to come round.
/// The lanes are cut where the constraints are:
///
/// - the FAST lane — needs-you, extraction, embed, the two attachment kinds
///   and the three context kinds — shares one [DrainGate] with the triage
///   drain, because both send bulk work to the 4-slot fast server and the
///   gate is what keeps them from double-booking it. This is the lane a new
///   message's first seconds run on, and nothing on the 27B is allowed into
///   it;
/// - the STORYLINE lane holds the six storyline passes, behind their own
///   gate. They are mixed-slot (membership on the fast server, naming and
///   recaps on the 27B) and they mutate shared membership, so the ordering
///   arguments in `docs/pipeline/06-storylines.md` — refresh before recruit,
///   audit between them, recap after the sweep — only hold while all six stay
///   in ONE worker in list order;
/// - the DRAFT lane is `DraftHandler` alone, behind its own gate, at the
///   width the prose server was started with. A draft a person is waiting for
///   must not sit behind a sweep.
///
/// So ORDER ACROSS LANES is no longer list position: it is enqueue-and-pump.
/// A fast handler writes the `storyline*` or `draft` row and [onDrained] (or
/// `ExtractHandler.onDraftQueued`) wakes the lane that owns it. Inside a lane,
/// list order still means exactly what it always did.
///
/// A park is per KIND when it is the model server that went away, because
/// since phase 3 the kinds do not share one: extraction runs against the fast
/// server and drafting against the 27B, so "extraction's server is not
/// running" says nothing about drafting's. A dead SESSION is the opposite —
/// every kind's Graph-dependent work fails identically — and parks the whole
/// drain.
///
/// The worker owns no timer. [pump] is called after each sync, is a no-op
/// while a drain is running, and stops on its own when nothing is pending.
class AiWorker {
  /// Every source whose work this worker drains — the three connectors any
  /// queue in this app has rows under. Handlers are already per-item
  /// source-aware (they read `item['source']`), so widening this list is all a
  /// new connector needs.
  /// `local` is not a connector: it is the source context directories queue
  /// under, because a folder on this machine came from no mailbox at all.
  ///
  /// PUBLIC because it is no longer only this class's business: the draft
  /// prefetch cap in `ExtractHandler` counts work rows over exactly the sources
  /// that will drain them, and a second literal of this list would be a cap
  /// that stopped seeing a connector the day one was added.
  static const List<String> sources = ['email', 'teams', 'local'];

  /// How many urgent refs one pass carries at most.
  ///
  /// Eight, and small on purpose: the priority pass runs ahead of the whole
  /// backlog, so a caller that handed it a hundred refs would have built a
  /// second backlog in front of the first and starved everything behind it.
  /// A triage drain writes at most its concurrency in verdicts per round, so
  /// eight is several drains' worth. Refs past the cap are dropped rather
  /// than queued: they are still pending rows, and the handler walk reaches
  /// them a moment later.
  static const int maxPriorityRefs = 8;

  /// One retry, then the item is left alone. Same trade triage makes: a local
  /// model that answered unparseably often gets it right on a second pass, and
  /// an item that fails twice will fail every time.
  ///
  /// Public because a handler sometimes has to know it is on its LAST attempt
  /// — a digest that keeps failing has to close its own file row, or the
  /// reconcile pass revives the work row on the next sync and the file costs
  /// two fast-slot calls a minute forever.
  static const int maxAttempts = 2;

  /// Whether [error] on attempt [attempts] is the END of an item.
  ///
  /// [attempts] is the count INCLUDING this run, the way [_recordFailure]
  /// computes it: `item['attempts'] + 1`.
  ///
  /// A 400 from a `json_schema` request is this app's schema being wrong,
  /// not the model's answer. It is identical on every retry, so retrying it
  /// burns model time to reproduce a bug — and it is therefore fatal on the
  /// FIRST attempt, before the count is anywhere near the ceiling.
  ///
  /// Public and shared because a handler that has to close its OWN row when
  /// the worker gives up has to give up on exactly the same rung. Two copies
  /// of this rule is a handler that leaves a row `pending` against a work
  /// row already written `error`, which the reconcile pass then revives
  /// every sync.
  static bool isFatal(Object error, int attempts) =>
      (error is LlmException && error.statusCode == 400) ||
      attempts >= maxAttempts;

  final MessageStore _store;
  final List<WorkHandler> _handlers;
  final DrainGate _gate;
  final ActivityLog _log;

  /// Only ever told about the two ways an item can end BADLY. Every stage
  /// writes its own progress from inside its handler; what a handler cannot
  /// see is the worker deciding, after it threw, whether that was a park or a
  /// failure.
  final PipelineProgress _pipeline;

  final StreamController<WorkProgress> _progress =
      StreamController<WorkProgress>.broadcast();

  /// The drain in flight, or null. Doubles as the "already running" guard and
  /// as what a second [pump] returns, so a caller that pumped mid-drain still
  /// awaits real completion instead of an instant no-op.
  Future<void>? _draining;

  /// Set when [pump] lands mid-drain: the active drain makes one more full
  /// handler pass before finishing, picking up whatever that pump was for —
  /// a kind it had already moved past would otherwise wait for the next sync.
  bool _repump = false;

  /// The items this worker currently holds claims on, as `(kind, source,
  /// entityId)` — the work table's primary key. See `TriageQueue` for why a
  /// queue has to know what it is holding: a worker rebuilt mid-drain, which
  /// is what a backend switch does, used to leave every claimed row
  /// `processing` until the next launch.
  final Set<(String, String, String)> _claimed = {};

  /// The items actually at a model server, so [dispose] can wait for their
  /// results before deciding what is still claimed.
  final Set<Future<void>> _inFlight = {};

  /// Messages a caller named as URGENT, waiting for the next pass to open.
  ///
  /// Filled by [pump]'s `first:` and emptied by the pass that runs them, so a
  /// ref sits here for at most one handler walk. Small on purpose — see
  /// [maxPriorityRefs].
  final List<({String source, String id})> _priority = [];

  bool _stopped = false;

  /// Why the last claim parked, or null. Published on every [WorkProgress],
  /// set by [_park], and cleared by a pump and by an item that succeeded.
  String? _parkedReason;

  int _lastDrainCount = 0;

  /// How many items the most recent drain processed.
  ///
  /// Read by the lane wiring inside `onDrained`, where it is what tells a
  /// drain that moved the mailbox from one that was pumped and found nothing:
  /// [_onDrained] fires after empty drains too, by design, so a caller that
  /// re-arms something on the strength of a drain has to gate on this or it
  /// re-arms it on every idle pump.
  ///
  /// An item counts when it finished or failed on its own terms, which is
  /// [_RunOutcome.ok] — either way the queue moved and a handler ran. A PARK
  /// does not: both kinds put the item back exactly as they found it, having
  /// processed nothing, so counting one would report work on a drain that hit
  /// a downed server and stopped.
  ///
  /// Zeroed once per [pump], at the top of [_drainUntilQuiet] rather than of
  /// [_drainAll]: a repumped drain runs [_drainAll] more than once and fires
  /// [_onDrained] only at the end, so a count zeroed per inner pass would
  /// report the last of them instead of the whole drain.
  ///
  /// A hook must therefore read this BEFORE its first `await`. [_fireDrained]
  /// runs synchronously inside [_drainUntilQuiet]'s `finally`, with [_draining]
  /// already cleared, so a pump landing while a suspended hook waits starts a
  /// fresh drain and zeroes the count out from under it.
  int get lastDrainCount => _lastDrainCount;

  /// Whether the app's processing switch is ON, or null where nobody wired
  /// one — every test, and any caller from before the switch existed.
  ///
  /// A CLOSURE over session state rather than a flag set on this object, on
  /// `WorkHandler.concurrency`'s precedent: the switch moves while a worker is
  /// mid-drain, and a value captured at construction would only take effect at
  /// the next rebuild. Read on every launch decision instead, so the drain
  /// stops at the item after the one the user switched off during.
  final bool Function()? _enabled;

  /// Told after every completed drain, so the lanes this one feeds can walk.
  ///
  /// `TriageQueue._onDrained`'s shape with one difference: it fires even when
  /// the drain wrote nothing. An empty fast drain still has to wake the
  /// storyline and draft lanes, because a caller that enqueued a row directly
  /// — a user's Regenerate, a restore — is exactly the case where this lane
  /// had nothing of its own to do.
  final void Function()? _onDrained;

  AiWorker(
    this._store, {
    required List<WorkHandler> handlers,
    DrainGate? gate,
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
    this._enabled,
    this._onDrained,
  })  : _handlers = List.unmodifiable(handlers),
        _gate = gate ?? DrainGate(),
        _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  Stream<WorkProgress> get progress => _progress.stream;

  /// True only when a switch was wired AND says no. An unwired worker is on,
  /// which is what keeps every existing caller and every test unchanged.
  bool get _off => _enabled?.call() == false;

  /// Whether this drain must end, and the one thing every loop below asks.
  ///
  /// It LATCHES: an off read here sets [_stopped], so a drain the switch cut
  /// short ends the way a [stop] ends it — [_fireDrained] stays silent, the
  /// repump loop finishes, and no sibling lane is woken while processing is
  /// off. Without the latch a cut drain would still fire the callback, and the
  /// fast lane's `beforeWaking` would re-arm the storyline sweep on a mailbox
  /// nothing is allowed to look at.
  bool get _halted {
    if (_off) _stopped = true;
    return _stopped;
  }

  /// The kinds this worker drains, in drain order.
  ///
  /// Public so the lane wiring can be pinned by a test: which kinds live on
  /// which worker is the whole of the three-lane split, and nothing at
  /// runtime could otherwise be asked.
  List<String> get kinds => [for (final handler in _handlers) handler.kind];

  /// Ends the current drain after the items already in flight finish. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

  /// Clears claims a previous run left behind, across every kind. Startup only
  /// — it must not run while a worker holds a claim, or it would hand that
  /// item to a second drain.
  Future<void> resetInterrupted() => _store.resetInterruptedWork();

  /// Stops the drain and gives back every claim it is still holding — the
  /// work queue's `TriageQueue.quiesce`, in the same order and for the same
  /// reasons.
  ///
  /// [dispose] minus the closing of the progress stream, so the worker is
  /// REUSABLE afterwards: the caller is a reset that is about to delete the
  /// rows this worker holds claims on, and the very next thing it wants is
  /// this same worker draining again. The `_stopped` it leaves behind is per
  /// drain, which [pump] clears.
  ///
  /// It does not touch the processing switch, either way. What the switch
  /// says is the user's, and a reset that turned it on or off behind them
  /// would be answering a question they did not ask.
  ///
  /// Re-entrant by memoisation: two concurrent callers share ONE run. The
  /// second is reachable through [dispose] — a provider invalidated during a
  /// reset window disposes this worker while the reset host is already
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
      // A LOOP, not one wait — see `TriageQueue.quiesce`: a claim already at
      // the store when [_stopped] flipped joins [_inFlight] after the first
      // snapshot, and releasing under a still-running item would hand it to a
      // second worker.
      while (_inFlight.isNotEmpty) {
        await Future.wait(_inFlight.toList())
            .catchError((_) => const <void>[]);
      }
      for (final (kind, source, id) in _claimed.toList()) {
        // Guarded on `processing` in the statement itself, so a claim
        // released here cannot reopen an item that finished while this was
        // deciding.
        await _store.releaseWorkClaim(kind, source, id);
      }
      _claimed.clear();
      // The refs go too. A quiesce is what a reset runs before it deletes the
      // rows this worker was holding, so a ref kept across one would name a
      // work item that no longer exists — and the next pump would open a
      // priority pass for it before touching the queue that does.
      _priority.clear();
    } finally {
      _quiescing = false;
    }
  }

  /// Raised for the whole of [quiesce], and read by [pump] as "off": a pump
  /// that lands during the wait must not lift [_stopped] and resume the
  /// drain this method is waiting out.
  bool _quiescing = false;

  /// [quiesce], and then the stream goes too — this worker is done.
  ///
  /// The close lands AFTER the wait rather than before it, which is the one
  /// difference from the order this method used to keep. Nothing depends on
  /// the old order: [_emit] guards on `isClosed` at both ends, so an item
  /// landing during the wait either reports a count nobody is listening to or
  /// finds the controller shut, and neither throws.
  Future<void> dispose() async {
    await quiesce();
    await _progress.close();
  }

  /// Drains every handler's queue in order until nothing is pending, the
  /// worker is stopped, or something happens that would fail identically for
  /// every item behind the current one.
  ///
  /// Serialized two ways. Against ITSELF: a call while a drain is running does
  /// not start a racing one — it schedules one more full pass on the active
  /// drain and returns that drain's future, so the caller still awaits the
  /// pass that will do its work. Against the OTHER queue on its gate: the
  /// whole drain runs under this lane's [DrainGate], so the fast lane can
  /// never interleave model calls with a triage drain already at the server.
  ///
  /// The future this returns completes once [_onDrained] has been CALLED, not
  /// once what it started has finished — which is the point of it being a
  /// `void` callback. "This lane is drained" is the fact a caller waits for,
  /// and waking the next lane must not extend this one's wall clock.
  ///
  /// With processing switched off it does nothing at all: no gate is taken, no
  /// claim is made, and [_onDrained] does not fire — a wake while off would
  /// re-arm the storyline sweep on every sixty-second poll. The flag is raised
  /// on the way out rather than merely returned on, because a drain already
  /// running has to learn about the switch too, and [_drainAll] is where it
  /// reads it. A completed future and never null: callers both `await` this
  /// and `unawaited(…)` it.
  ///
  /// [first] names messages whose work should run AHEAD of the backlog — the
  /// pairs a triage drain has just written verdicts for. They are claimed one
  /// handler at a time in the walk's own order, at the next CLAIM BOUNDARY
  /// rather than at the top of the next pass, so a message that arrived mid
  /// backlog costs its own needs-you and extraction rather than a whole pass
  /// of everybody else's — see [_servePriority]. A ref for a source this
  /// worker does not drain is dropped, a duplicate is ignored, and the queue
  /// is capped at [maxPriorityRefs].
  Future<void> pump({List<({String source, String id})> first = const []}) {
    // Merged before the off check, not after it: a ref named while
    // processing is off is still the newest message, and the pump that
    // follows the switch coming back on should carry it.
    for (final ref in first) {
      if (!sources.contains(ref.source)) continue;
      if (_priority.contains(ref)) continue;
      if (_priority.length >= maxPriorityRefs) break;
      _priority.add(ref);
    }
    // A quiesce in progress counts as off: the latch it set must survive
    // until its claims are handed back, or a pump landing mid-wait would
    // clear [_stopped], resume the drain, and let `_claimed.clear()` run
    // under a live claim.
    if (_off || _quiescing) {
      _stopped = true;
      return _draining ?? Future<void>.value();
    }
    // Cleared on every ON pump, and this is what makes the switch reversible
    // mid-drain: the latch in [_halted] leaves [_stopped] set, and a drain
    // still finishing its last item would otherwise drop the [_repump] below
    // on `while (_repump && !_stopped)` and go quiet until the next poll.
    // [stop] already promises exactly this — the next pump starts draining
    // again.
    _stopped = false;
    // A new pump is a fresh attempt, so the last park is no longer the news.
    // If the server is still down the first claim parks again and the reason
    // comes straight back.
    _parkedReason = null;
    final inFlight = _draining;
    if (inFlight != null) {
      _repump = true;
      return inFlight;
    }
    final drain = _drainUntilQuiet();
    _draining = drain;
    return drain;
  }

  /// One gated drain, and one more for a pump that landed in its last
  /// microtasks.
  ///
  /// [_drainAll] re-reads [_repump] between its own passes, but between its
  /// final read and this worker noticing the drain is over there is a gap —
  /// the gate's future resolving, this frame resuming — in which a [pump]
  /// would find [_draining] still set, raise the flag and hand back a future
  /// about to complete without the row it was called for. The loop here reads
  /// the flag again after the gate returns, and the `finally` clears
  /// [_draining] in the same synchronous step as that last read, so no such
  /// gap is left: a pump either joins a drain that will run again, or starts
  /// a fresh one.
  Future<void> _drainUntilQuiet() async {
    // Once per pump, and not once per [_drainAll] pass — see
    // [lastDrainCount]. What a reader of that getter is asking about is this
    // whole drain, repumps included.
    _lastDrainCount = 0;
    try {
      do {
        await _gate.run(_drainAll);
      } while (_repump && !_stopped);
    } finally {
      // Cleared FIRST, so a pump issued from inside the callback starts a
      // fresh drain rather than joining the one that has just finished.
      _draining = null;
      _fireDrained();
    }
  }

  /// Wakes whatever this lane feeds, outside the gate and without waiting.
  ///
  /// Outside, because the callback's job is to pump ANOTHER worker, and one
  /// that ran while this drain still held the gate would be describing a lane
  /// that is not free yet. Guarded, because this drain's work is already
  /// written: a callback that throws must not turn a completed drain into a
  /// failed future its caller sees.
  ///
  /// Silent after a [stop] or a [dispose], on `TriageQueue.pump`'s rule: a
  /// drain cut short must not restart the lanes it feeds — the next pump has
  /// them either way, and a worker being torn down would otherwise wake the
  /// one being torn down beside it.
  void _fireDrained() {
    final onDrained = _onDrained;
    if (onDrained == null || _stopped) return;
    try {
      onDrained();
    } catch (_) {}
  }

  /// This entry RESETS [_stopped], which is why the processing switch cannot
  /// live in [stop] alone: a pump landing after an off would clear the flag
  /// here and drain anyway. The reset reads the switch instead, so an off
  /// worker starts every drain already stopped and returns before it takes a
  /// claim.
  ///
  /// It reads [_quiescing] as well, and that is not belt and braces. A gate
  /// run enqueued BEFORE a quiesce began runs after it started, and the first
  /// thing this method would otherwise do is open a priority pass and take
  /// fresh claims — while [_quiesceOnce] is releasing the claims it holds and
  /// about to call `_claimed.clear()`. [pump] already treats a quiesce as off
  /// for the same reason; this is the same rule read from inside.
  Future<void> _drainAll() async {
    _stopped = _off || _quiescing;
    if (_stopped) return;
    do {
      _repump = false;
      // Raised when the triage drain has asked for the gate back. A yield
      // ends a PASS, not a drain: the repump below is what resumes the walk
      // from the top once triage has had its turn.
      var yielding = false;
      // Kinds a priority pass found a downed server for. Per PASS, so the
      // walk below does not dial the same down server a second time over the
      // same seconds. A repump walks them again, which is the accepted cost
      // commented at the yield return.
      final parkedKinds = <String>{};
      if (_priority.isNotEmpty && await _servePriority(parkedKinds)) return;
      for (final handler in _handlers) {
        // The switch is re-read per handler as well as per item: an off that
        // lands mid-drain must stop the NEXT launch, while the item already at
        // the server finishes and its answer is written — see the
        // `Future.wait(_inFlight)` below, which is outside every break.
        if (_halted) break;
        // The yield first, as at the claim boundary below: a triage drain
        // that is already waiting must not be made to sit out a whole
        // priority pass on top of the kind that just finished. Nothing is in
        // flight at a kind boundary, so there is nothing to wait for before
        // handing the gate back — the repump is what resumes the walk, and
        // the refs are still queued for it.
        if (_gate.yieldRequested) {
          _repump = true;
          return;
        }
        // Refs that landed while the PREVIOUS kind was draining, served
        // before this kind starts rather than at the top of the next pass.
        if (_priority.isNotEmpty && await _servePriority(parkedKinds)) return;
        // A priority pass just found this kind's server down. Every item
        // behind it would fail identically, and it is the same seconds and
        // the same server: skipped before the emit, so the walk costs no
        // query for a kind it is not going to dial.
        if (parkedKinds.contains(handler.kind)) continue;
        // Before the first item of each kind, not after it: a counter that
        // appears only once the first item lands is blank for exactly the
        // seconds someone would be looking at it.
        await _emit(handler.kind);

        // Up to [WorkHandler.concurrency] items of this kind at the server at
        // once. What makes that safe is the claim:
        // [MessageStore.claimPendingWork] is one UPDATE…RETURNING, so choosing
        // an item and taking it off the pending list are the same indivisible
        // step. Two concurrent drains — or two iterations of this loop, which
        // suspends on the claim now — can never see the same row: whichever
        // claim lands second finds nothing pending to match and comes back
        // null.
        var parkedKind = false;
        var parkedDrain = false;
        // [_halted] rather than [_stopped] in both conditions: a switch moved
        // while this kind is draining must stop the next LAUNCH, not just the
        // next kind — an off during a sixty-message backlog would otherwise
        // keep dialling the model until that backlog ran out.
        while (!_halted && !parkedKind && !parkedDrain && !yielding) {
          while (_inFlight.length < handler.concurrency &&
              !_halted &&
              !parkedKind &&
              !parkedDrain) {
            // The claim boundary, and the only place a yield is read. The
            // item already at the server is never abandoned — the
            // `Future.wait` below is outside every break — so a yield costs
            // the waiting drain one item, not a whole pass.
            if (_gate.yieldRequested) {
              yielding = true;
              break;
            }
            // And the claim boundary is where a REF is served too. This is
            // the one that matters for the wall clock: a message named while
            // this kind is half way through a sixty-row backlog must not wait
            // for the backlog to end. Its own needs-you and extraction run
            // here, and the walk picks up where it left off afterwards.
            if (_priority.isNotEmpty &&
                await _servePriority(parkedKinds)) {
              return;
            }
            // A ref pass is long enough for the processing switch to have
            // moved under it; read the halt again before claiming.
            if (_halted) break;
            if (parkedKinds.contains(handler.kind)) {
              parkedKind = true;
              break;
            }
            final item = await _store.claimPendingWork(
              handler.kind,
              sources: sources,
            );
            if (item == null) break;
            _launch(handler, item, (outcome) {
              parkedKind |= outcome == _RunOutcome.parkKind;
              parkedDrain |= outcome == _RunOutcome.parkDrain;
            });
          }
          if (_inFlight.isEmpty) break;
          // Over a COPY: `whenComplete` mutates the set as each item lands.
          await Future.any(_inFlight.toList());
        }
        // A park stops new launches, never the work already at the server:
        // those answers are paid for and their results are kept.
        await Future.wait(_inFlight.toList());

        // A dead session fails every kind identically, so nothing behind this
        // one is worth trying — and neither is a repump, which would park on
        // the same dead session all over again. A server that is down is not
        // that: it is one kind's server, and the next kind may be on another.
        if (parkedDrain) return;

        // The pass ends here and the gate goes back to the FIFO, where the
        // triage drain that asked is already waiting. [_drainUntilQuiet]
        // re-enters `_gate.run(_drainAll)` behind it, so the backlog resumes
        // from the top of the walk rather than being dropped.
        //
        // The accepted cost, stated plainly: if a kind parked in this same
        // pass, the repump walks it again and dials that down server once
        // more. That is exactly what an external `pump()` during a parked
        // drain does today, and it is bounded — one yield per triage pump.
        if (yielding) {
          _repump = true;
          return;
        }
      }
    } while (_repump && !_stopped);
  }

  /// Everything one launched item needs, in one place.
  ///
  /// The claim bookkeeping, the span, the count and the in-flight set are
  /// identical for the handler walk and for the priority pass, and a second
  /// copy of them is how the two would drift — a claim recorded on one path
  /// and not the other is a row left `processing` after a quiesce.
  /// [onOutcome] is the only difference: each caller folds the parks into its
  /// own loop variables.
  ///
  /// [_lastDrainCount] is raised HERE rather than at the end of the drain,
  /// because [_drainAll] returns early on a parked drain and a count written
  /// at the end would be the previous drain's.
  void _launch(
    WorkHandler handler,
    Map<String, Object?> item,
    void Function(_RunOutcome outcome) onOutcome,
  ) {
    _claimed.add(_claimKey(handler.kind, item));
    late final Future<void> future;
    // [ActivityLog.inSpan] gives this item its own tally, so concurrent
    // items' notes and model calls land on their own activity rows.
    future = _log.inSpan(() => _runOne(handler, item)).then((outcome) {
      if (outcome == _RunOutcome.ok) _lastDrainCount++;
      onOutcome(outcome);
    }).whenComplete(() => _inFlight.remove(future));
    _inFlight.add(future);
  }

  /// Serves whatever refs are waiting, wherever the drain happens to be.
  ///
  /// Called at three points, and the third is the one the wall clock cares
  /// about: the top of a pass, the top of each handler's turn, and before
  /// every claim in the launch loop. The first two alone were not enough, and
  /// the box measured it — a pump that lands while a pass is already walking
  /// finds that pass's `_priority` snapshot already taken, so the ref sat
  /// until the pass ended and a message's extraction waited behind every
  /// needs-you in the backlog. A claim boundary is where the drain is free to
  /// do something else, so it is where a ref gets in.
  ///
  /// Every caller guards the call with a SYNCHRONOUS `_priority.isNotEmpty`
  /// and short-circuits, and that is load bearing rather than tidiness. This
  /// method is `async`, so awaiting it costs a microtask hop even when it
  /// returns at once — three of them per claim, on a path that runs for every
  /// item of every kind. A drain that suspends where it used to run straight
  /// through finishes later than its caller expects, and the callers that
  /// fire a pump and do not await it are real: `StorylinesNotifier.recruitNow`
  /// and its siblings. The guard below stays as a second line of defence.
  ///
  /// Returns true when the whole drain must end, which every caller turns
  /// into a return. [parkedKinds] is the PASS's set, read and written by the
  /// serve rather than rebuilt per serve: a second serve must not dial a kind
  /// the first one already found down.
  Future<bool> _servePriority(Set<String> parkedKinds) async {
    if (_priority.isEmpty) return false;
    final refs = List.of(_priority);
    _priority.clear();
    return _runPriority(refs, parkedKinds);
  }

  /// Puts refs back at the FRONT of the priority queue, so a pass cut short
  /// keeps the promise [pump] makes: a named message is still the newest one
  /// when the worker comes back.
  ///
  /// Deduped against what is already queued and capped like any other merge.
  /// A ref whose row the cut pass already finished is harmless: its work item
  /// is no longer `pending`, so the next claim for it comes back null.
  void _keepPriority(List<({String source, String id})> refs) {
    for (final ref in refs.reversed) {
      if (_priority.contains(ref)) continue;
      _priority.insert(0, ref);
    }
    if (_priority.length > maxPriorityRefs) {
      _priority.removeRange(maxPriorityRefs, _priority.length);
    }
  }

  /// The named refs, handler by handler in the walk's own order, so a message
  /// that has just been triaged gets `needs_you`, then `extract`, then its
  /// embedding and the rest before the backlog resumes.
  ///
  /// Reentrant with the walk by design: [_servePriority] calls this from
  /// inside the launch loop, so a pass that is half way through one kind
  /// stops there, runs the named refs through EVERY handler, and then carries
  /// on with the kind it was on. The walk's own loop variables are untouched
  /// by that, because the parks this pass sees come back as a return value
  /// rather than as a write into somebody else's `parkedKind`.
  ///
  /// EVERY handler is walked, not the message-keyed ones. Five of the fast
  /// lane's eight kinds are keyed on attachment ids, conversation keys and
  /// file paths rather than on a message id, so a message's ref misses them
  /// by design — one cheap indexed query each, against a natural key, which
  /// is a price worth paying for the property that matters: a kind added to
  /// this lane later and keyed on a message cannot be forgotten here.
  ///
  /// One run path only: [_launch] is the walk's, so [_runOne], [_claimKey],
  /// `_log.inSpan`, [_claimed] and [_lastDrainCount] are shared rather than
  /// copied. Progress is emitted per kind before that kind's first launch,
  /// as the walk does, so a pass over one message does not leave the header
  /// counter reading the last drain's numbers; a kind with no ref to take
  /// emits nothing, because nothing about it changed.
  ///
  /// No yield is read inside the pass: this pass is what the yield exists to
  /// let through, and reading one here would starve exactly the message the
  /// ask was made for.
  ///
  /// [parkedKinds] is the whole PASS's set, read as well as written. A kind
  /// the walk or an earlier serve already found down is skipped here, so two
  /// serves in one pass cost one dial at a dead server rather than two, and a
  /// kind this pass parks is added for everybody after it.
  ///
  /// Returns the parked-drain verdict, which its caller turns into a return.
  Future<bool> _runPriority(
    List<({String source, String id})> refs,
    Set<String> parkedKinds,
  ) async {
    for (final handler in _handlers) {
      if (_halted) {
        _keepPriority(refs);
        return false;
      }
      if (parkedKinds.contains(handler.kind)) continue;
      var parkedKind = false;
      var parkedDrain = false;
      var emitted = false;
      for (final ref in refs) {
        if (_halted || parkedKind || parkedDrain) break;
        while (_inFlight.length >= handler.concurrency) {
          await Future.any(_inFlight.toList());
        }
        // One UPDATE…RETURNING on the natural key, carrying the same
        // untriaged guard the walk's claim carries: a ref whose row is gone,
        // already claimed or still ahead of its own triage verdict comes back
        // null and the walk takes it later.
        final item = await _store.claimWorkItem(
          handler.kind,
          ref.source,
          ref.id,
        );
        if (item == null) continue;
        if (!emitted) {
          emitted = true;
          await _emit(handler.kind);
        }
        _launch(handler, item, (outcome) {
          parkedKind |= outcome == _RunOutcome.parkKind;
          parkedDrain |= outcome == _RunOutcome.parkDrain;
        });
      }
      // Outside every break, on the walk's rule: a park stops new launches,
      // never the work already at the server.
      await Future.wait(_inFlight.toList());
      if (parkedKind) parkedKinds.add(handler.kind);
      if (parkedDrain) {
        // The same keep the halt arm makes, for the same reason: the handlers
        // after this one never ran, so the named message has not finished its
        // walk. Without it a signed-out session, or any other whole-drain
        // park, dropped the just-triaged refs on the floor and the newest
        // message went back to waiting its turn in `created_at` order — which
        // is the one thing this whole path exists to stop.
        _keepPriority(refs);
        return true;
      }
      if (_halted) {
        _keepPriority(refs);
        return false;
      }
    }
    return false;
  }

  static (String, String, String) _claimKey(
    String kind,
    Map<String, Object?> item,
  ) =>
      (
        kind,
        item['source'] as String? ?? 'email',
        item['entity_id'] as String? ?? '',
      );

  /// One item, with a heartbeat under it.
  ///
  /// The heartbeat is what makes [MessageStore.reclaimStaleWork] safe to run
  /// on every sync — and it matters more here than in triage, because a
  /// storyline sweep is one item that legitimately takes minutes. A claim
  /// that is still being worked says so once a minute, so the watchdog's
  /// five-minute window can only close on a worker that is gone.
  Future<_RunOutcome> _runOne(
    WorkHandler handler,
    Map<String, Object?> item,
  ) {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final beat = Timer.periodic(pipelineHeartbeatInterval, (_) {
      // A failed touch costs nothing: the window is five beats wide.
      _store.touchWork(handler.kind, source, id).catchError((_) {});
    });
    return _runClaimed(handler, item, source, id).whenComplete(beat.cancel);
  }

  /// Everything one claimed item does, and what its outcome means for the rest
  /// of the drain.
  Future<_RunOutcome> _runClaimed(
    WorkHandler handler,
    Map<String, Object?> item,
    String source,
    String id,
  ) async {
    // The item arrives already claimed — the statement that picked it is the
    // statement that wrote its `processing`. A crash mid-model-call therefore
    // leaves it claimed, which is exactly what [resetInterrupted] looks for at
    // the next launch.
    final sw = Stopwatch()..start();

    try {
      await handler.run(item);
      await _writeWork(handler.kind, source, id, status: 'done');
      // The work row is `done` either way; the activity row is where a
      // handler that early-returned gets to say so. [ActivityLog.note] and
      // [ActivityLog.noteStatus] are how it does that without throwing, and
      // both are folded in and cleared by this one call.
      await _log.record(
        handler.kind,
        status: _log.pendingStatusOr('ok'),
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
      );
      // An item got through, so whatever the last park was about is over.
      // Cleared BEFORE the emit, so the progress this success publishes
      // carries a null reason and the rail's sentence goes with it.
      _parkedReason = null;
      await _emit(handler.kind);
      return _RunOutcome.ok;
    } on LlmUnavailableException catch (e) {
      // Nothing about this item failed, so it does not spend an attempt. This
      // kind stops too: every item of it behind this one would fail
      // identically, and marking a hundred of them is just noise on a laptop
      // where that model server is not running.
      //
      // A refused key, and a dead EMBEDDING server, are the same park with a
      // different reason, because each is the same fact about every item
      // behind this one — and the rail can then say which of the three it is.
      // The slot matters because the two are placed separately: the box can be
      // serving every generating stage while the local embedding server is the
      // one that is down.
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkKind,
        parkReasonFor(e),
        sw.elapsedMilliseconds,
      );
    } on NotSignedIn {
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkDrain,
        'session',
        sw.elapsedMilliseconds,
      );
    } on ReconsentRequired {
      return _park(
        handler.kind,
        source,
        id,
        _RunOutcome.parkDrain,
        'session',
        sw.elapsedMilliseconds,
      );
    } on LlmException catch (e) {
      return _recordFailure(
        handler.kind,
        item,
        e,
        e.statusCode,
        sw.elapsedMilliseconds,
      );
    } catch (e) {
      return _recordFailure(handler.kind, item, e, null, sw.elapsedMilliseconds);
    }
  }

  /// Every write that ends this worker's interest in an item, and the claim
  /// release that goes with it.
  ///
  /// One wrapper rather than a `_claimed.remove` beside each write site: a
  /// path that wrote a result and forgot to release would leave [dispose]
  /// holding a claim on an item that is already finished.
  Future<void> _writeWork(
    String kind,
    String source,
    String entityId, {
    required String status,
    String? error,
    int? attempts,
  }) async {
    await _store.writeWork(
      kind,
      source,
      entityId,
      status: status,
      error: error,
      attempts: attempts,
    );
    _claimed.remove((kind, source, entityId));
  }

  /// Back to `pending` without spending an attempt. The session ending or the
  /// server being down says nothing about this item; [outcome] says how far
  /// the park reaches and [reason] tells the activity row why.
  Future<_RunOutcome> _park(
    String kind,
    String source,
    String id,
    _RunOutcome outcome,
    String reason,
    int durationMs,
  ) async {
    _parkedReason = reason;
    await _writeWork(kind, source, id, status: 'pending');
    // Back to waiting, not failed: nothing about this item went wrong.
    if (kind == 'extract') {
      await _pipeline.noteExtract(source, id, state: 'pending');
    }
    if (kind == 'draft') {
      await _pipeline.noteDraft(source, id, state: 'pending');
    }
    await _log.record(
      kind,
      status: 'parked',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {'reason': reason},
    );
    await _emit(kind);
    return outcome;
  }

  Future<_RunOutcome> _recordFailure(
    String kind,
    Map<String, Object?> item,
    Object error,
    int? statusCode,
    int durationMs,
  ) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final attempts = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
    final fatal = isFatal(error, attempts);
    await _writeWork(
      kind,
      source,
      id,
      status: fatal ? 'error' : 'pending',
      error: redactEndpoints('$error'),
      attempts: attempts,
    );
    // `error` only once the retries are gone: an item that will be tried again
    // is back to waiting, and a bar that showed red in between would be
    // reporting a state the pipeline does not consider final.
    if (kind == 'extract') {
      await _pipeline.noteExtract(
        source,
        id,
        state: fatal ? 'error' : 'pending',
      );
    }
    // The drafting handler writes `running` at entry and never gets to speak
    // again once it throws, so the same two states have to come from here —
    // and for this kind, too, the entity id IS the message id.
    if (kind == 'draft') {
      await _pipeline.noteDraft(source, id, state: fatal ? 'error' : 'pending');
    }
    // The storyline handler only speaks on success — an exception never
    // reaches its switch — so the worker has to say when the retries are
    // gone, or the stage would sit at `pending` and the row would never
    // settle. For this kind the entity id IS the conversation key.
    if (kind == 'storyline' && fatal) {
      await _pipeline.noteStoryline(source, id, state: 'error');
    }
    // `retry` while the item still has an attempt left, `error` once it does
    // not — the work row's `pending` cannot tell those apart after the fact.
    await _log.record(
      kind,
      status: fatal ? 'error' : 'retry',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {
        // Redacted, not raw. An unreachable server never reaches this write
        // (`_park` takes it first), but a 4xx body snippet or a handler's own
        // sentence can still echo an address, and an address is a setting,
        // not a row.
        'error': redactEndpoints('$error'),
        'attempts': attempts,
        'status_code': ?statusCode,
      },
    );
    await _emit(kind);
    return _RunOutcome.ok;
  }

  /// Awaited by every caller, never fired and forgotten: the counts are read
  /// from the rows, so an unawaited emit would be free to report a queue that
  /// has already moved on.
  Future<void> _emit(String kind) async {
    if (_progress.isClosed) return;
    final counts = await _store.workCounts(kind, sources: sources);
    if (_progress.isClosed) return;
    _progress.add(WorkProgress(kind, counts, parkedReason: _parkedReason));
  }
}
