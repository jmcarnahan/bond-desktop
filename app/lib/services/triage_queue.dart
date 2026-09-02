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

  final StreamController<TriageProgress> _progress =
      StreamController<TriageProgress>.broadcast();

  /// How many messages may be at the model server at once. See the class doc
  /// for why it is small; `concurrency: 1` restores the old strictly-serial
  /// drain, which is what the tests that assert on request ORDER use.
  final int _concurrency;

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
  })  : _userAddress = userAddress,
        _ensureBody = ensureBody,
        _gate = gate ?? DrainGate(),
        _concurrency = concurrency,
        _log = activityLog ?? ActivityLog.disabled();

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

  void dispose() {
    _stopped = true;
    _progress.close();
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
    final inFlight = <Future<void>>{};
    var parked = false;
    while (!_stopped && !parked) {
      while (inFlight.length < _concurrency && !_stopped && !parked) {
        final row = await _store.claimPendingTriage(sources: sources);
        if (row == null) break;
        late final Future<void> future;
        // [ActivityLog.inSpan] gives this message its own tally, so three
        // concurrent messages' model calls land on three activity rows
        // instead of whichever records first.
        future = _log.inSpan(() => _triageOne(row)).then((carryOn) {
          if (!carryOn) parked = true;
        }).whenComplete(() => inFlight.remove(future));
        inFlight.add(future);
      }
      if (inFlight.isEmpty) break;
      // Over a COPY: `whenComplete` mutates the set as each message lands.
      await Future.any(inFlight.toList());
    }
    // A park — or a [stop] — stops new launches, never the requests already at
    // the server: those answers are paid for, and their results are kept.
    await Future.wait(inFlight.toList());
  }

  /// One message. Returns false when the drain should launch nothing further
  /// rather than move on to the next message.
  Future<bool> _triageOne(Map<String, Object?> row) async {
    final id = row['source_message_id'] as String? ?? '';
    // Read off the claimed row rather than held on the class: one drain takes
    // messages from every source in [sources], and every store write and
    // activity row below is keyed by `(source, id)`.
    final source = row['source'] as String? ?? 'email';
    var current = row;
    var message = Message.fromRow(current);

    // The row arrives already claimed — the statement that picked it is the
    // statement that wrote its `processing`. A crash mid-model-call therefore
    // leaves it claimed, which is exactly what [resetInterrupted] looks for at
    // the next launch.
    final sw = Stopwatch()..start();

    // Tier one, on the delta page's own fields. Free, and it is what keeps
    // the fetch below off every no-reply and every message the user sent.
    final senderGate = gateFor(message, userAddress: _userAddress);
    if (senderGate != null) {
      // No activity row, here or at the header gate below. A `triage` row
      // means the model was consulted, and a gate is the mechanism that keeps
      // it from being — one row per newsletter would bury the work the panel
      // exists to show under the mail that never cost anything.
      await _store.writeTriage(
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
    final headerGate = gateFor(message, userAddress: _userAddress);
    if (headerGate != null) {
      await _store.writeTriage(
        source,
        id,
        status: 'skipped',
        gateReason: headerGate,
      );
      await _emit();
      return true;
    }

    try {
      final result = await runTask(
        _client,
        const TriageTask(),
        TriageInput(message, DateTime.now()),
      );
      await _store.writeTriage(source, id, status: 'triaged', result: result);
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
      await _store.writeTriage(source, id, status: 'pending');
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

  /// The session is over, so every message behind this one would fail its
  /// fetch identically. The row goes back to `pending` without spending an
  /// attempt — nothing is wrong with the message — and the drain parks. The
  /// sign-out routing lives in the inbox notifier; triage's whole job here is
  /// to stop burning model time on previews it cannot improve on.
  Future<bool> _parkForSession(String source, String id, int durationMs) async {
    await _store.writeTriage(source, id, status: 'pending');
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
    await _store.writeTriage(
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
  /// message is the thread's newest inbound.
  ///
  /// Without that check a backlog would end up showing the wrong ask: the
  /// worker runs newest-first, so an older message finishing later would
  /// overwrite a current CTA with one from last week.
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

    // The first action item is the ask, in the imperative the model was asked
    // for. With no items, a summary stands in only when the message actually
    // needs something — a summary shown as a CTA on mail that needs nothing
    // reads as work that isn't there.
    final ask = result.actionItems.isNotEmpty
        ? result.actionItems.first
        : (result.needsAction ? result.summary : null);

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
