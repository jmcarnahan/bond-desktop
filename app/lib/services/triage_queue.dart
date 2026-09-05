import 'dart:async';

import '../data/message_store.dart';
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
/// rather than the aggregate: [LlmClient]'s 120-second timeout, which is
/// sized to catch a wedged server rather than a batched one, and the person
/// waiting for the first triaged message to appear.
///
/// Each message goes through two tiers, in this order for a reason:
///
/// 1. the gates that read only what a delta page already carried — who sent
///    it. A no-reply sender is a no-reply sender whatever its body says, and
///    catching it here means the bulk mail never costs a Graph round trip.
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
/// The queue owns no timer. [pump] is called after each sync, is a no-op while
/// a drain is already running, and stops on its own when nothing is pending.
/// A drain that ends because the model server is down leaves its row pending
/// and lets the next poll try again.
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

  String? _userAddress;
  bool _running = false;
  bool _stopped = false;

  TriageQueue(
    this._store,
    this._client, {
    String? userAddress,
    Future<void> Function(String sourceMessageId)? ensureBody,
    DrainGate? gate,
    int concurrency = 3,
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _userAddress = userAddress,
        _ensureBody = ensureBody,
        _gate = gate ?? DrainGate(),
        _concurrency = concurrency,
        _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  /// The signed-in mailbox, for the gate that skips the user's own mail. Set
  /// after sign-in resolves; until then that one gate is simply off.
  set userAddress(String? value) => _userAddress = value;

  Stream<TriageProgress> get progress => _progress.stream;

  /// Ends the current drain after the messages already in flight finish. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

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
  /// progress stream first is safe for the same reason [_emit] guards on
  /// `isClosed` — an in-flight message emitting into a closed controller is
  /// a no-op, not a crash.
  ///
  /// Awaited by nobody in the app (`ref.onDispose` takes a `void` callback),
  /// which is exactly right: the release is a database write that either
  /// lands or is picked up by [MessageStore.reclaimStaleTriage] five minutes
  /// later. Tests await it.
  Future<void> dispose() async {
    _stopped = true;
    _progress.close();
    // A LOOP, not one wait: a claim that was already at the store when
    // [_stopped] flipped lands in [_inFlight] after the first snapshot was
    // taken. Waiting on the stale snapshot and then releasing would flip a
    // message that is STILL RUNNING back to `pending`, where a second queue
    // could claim it and spend a second model call on the same mail.
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList()).catchError((_) => const <void>[]);
    }
    for (final claim in _claimed.toList()) {
      final parts = claim.split('|');
      // Guarded on `processing` in the statement itself, so a claim released
      // here cannot reopen a message that finished while this was deciding.
      await _store.releaseTriageClaim(parts.first, parts.skip(1).join('|'));
    }
    _claimed.clear();
  }

  /// Drains until nothing is pending, the queue is stopped, or the model
  /// server turns out to be down. Idempotent: a second call while a drain is
  /// running returns immediately rather than starting a racing one. The drain
  /// itself runs under the shared [DrainGate], so it never interleaves model
  /// calls with an AI-worker drain already at the server.
  Future<void> pump() async {
    if (_running) return;
    _running = true;
    _stopped = false;
    // Before the first message, not after it: the header counter would
    // otherwise sit blank for the seventeen seconds that message takes, which
    // is exactly when a user with a fresh backlog is looking for it.
    await _emit();
    try {
      await _gate.run(_drain);
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
    var parked = false;
    while (!_stopped && !parked) {
      while (_inFlight.length < _concurrency && !_stopped && !parked) {
        final row = await _store.claimPendingTriage(sources: sources);
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

    // Tier one, on the delta page's own fields. Free, and it is what keeps
    // the fetch below off every no-reply and every message the user sent.
    final senderGate =
        overridden ? null : gateFor(message, userAddress: _userAddress);
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
        // and the drain carries on.
      }
    }

    // Again, because the gates that read headers had nothing to read a moment
    // ago. Re-running the sender gate too is free and keeps this one call
    // the single place a gate decision is made.
    final headerGate =
        overridden ? null : gateFor(message, userAddress: _userAddress);
    if (headerGate != null) {
      await _writeTriage(
        source,
        id,
        status: 'skipped',
        gateReason: headerGate,
      );
      await _emit();
      return true;
    }

    // The thread is context for `reply_expected`: an unanswered question a few
    // messages back still expects an answer, and this message on its own does
    // not say so. Only what came BEFORE it — a later message is not context
    // for a judgement about this one. TriageTask takes the last few.
    var thread = const <Message>[];
    final key = current['conversation_key'] as String?;
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
        TriageInput(message, DateTime.now(), thread: thread),
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
      error: '$error',
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
        'error': '$error',
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
