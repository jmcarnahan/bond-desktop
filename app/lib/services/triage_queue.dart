import 'dart:async';

import '../data/message_store.dart';
import '../models/message_models.dart';
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

/// Drains pending inbound messages through the gates and the local model, one
/// at a time, newest first.
///
/// Strictly serial, and not as a simplification: the model generates at about
/// twelve tokens a second on one machine, so a second concurrent request does
/// not go twice as fast, it makes both requests take twice as long — and it
/// throws away llama-server's prompt cache between them.
///
/// Each message goes through two tiers, in this order for a reason:
///
/// 1. the gates that read only what a delta page already carried — who sent
///    it. A no-reply sender is a no-reply sender whatever its body says, and
///    catching it here means the bulk mail never costs a Graph round trip.
/// 2. the per-message detail fetch, then the gates again, then the model. A
///    delta page carries a ~255-character preview and no headers at all, so
///    without this step triage would classify from a snippet and the
///    newsletter and auto-generated gates could never fire.
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
  static const String _source = 'email';

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

  final StreamController<TriageProgress> _progress =
      StreamController<TriageProgress>.broadcast();

  String? _userAddress;
  bool _running = false;
  bool _stopped = false;

  TriageQueue(
    this._store,
    this._client, {
    String? userAddress,
    Future<void> Function(String sourceMessageId)? ensureBody,
    DrainGate? gate,
  })  : _userAddress = userAddress,
        _ensureBody = ensureBody,
        _gate = gate ?? DrainGate();

  /// The signed-in mailbox, for the gate that skips the loan officer's own
  /// mail. Set after sign-in resolves; until then that one gate is simply off.
  set userAddress(String? value) => _userAddress = value;

  Stream<TriageProgress> get progress => _progress.stream;

  /// Ends the current drain after the message in flight finishes. Not
  /// permanent: the next [pump] starts a fresh drain.
  void stop() => _stopped = true;

  /// Clears claims a previous run left behind. Startup only — it must not run
  /// while a worker holds a claim, or it would hand that message to a second
  /// drain.
  void resetInterrupted() => _store.resetInterruptedTriage(source: _source);

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
    _emit();
    try {
      await _gate.run(() async {
        while (!_stopped) {
          final row = _store.nextPendingTriage(sources: const [_source]);
          if (row == null) break;
          if (!await _triageOne(row)) break;
        }
      });
    } finally {
      _running = false;
    }
  }

  /// One message. Returns false when the drain should stop rather than move
  /// on to the next message.
  Future<bool> _triageOne(Map<String, Object?> row) async {
    final id = row['source_message_id'] as String? ?? '';
    var current = row;
    var message = Message.fromRow(current);

    // Claimed before the first await. A crash mid-model-call therefore leaves
    // the row in `processing`, which is exactly what [resetInterrupted]
    // looks for at the next launch — and what keeps a re-entrant pump from
    // handing the same message to two drains.
    _store.writeTriage(_source, id, status: 'processing');

    // Tier one, on the delta page's own fields. Free, and it is what keeps
    // the fetch below off every no-reply and every message the LO sent.
    final senderGate = gateFor(message, userAddress: _userAddress);
    if (senderGate != null) {
      _store.writeTriage(_source, id, status: 'skipped', gateReason: senderGate);
      _emit();
      return true;
    }

    // Tier two, and only for what survived tier one. Skipped entirely for a
    // message that already has both — a thread the LO opened was fetched then.
    final fetch = _ensureBody;
    if (fetch != null &&
        (message.bodyText?.isNotEmpty != true || message.headers.isEmpty)) {
      try {
        await fetch(id);
        current = _store.getMessageRow(_source, id) ?? current;
        message = Message.fromRow(current);
      } on NotSignedIn {
        return _parkForSession(id);
      } on ReconsentRequired {
        return _parkForSession(id);
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
      _store.writeTriage(_source, id, status: 'skipped', gateReason: headerGate);
      _emit();
      return true;
    }

    try {
      final result = await runTask(
        _client,
        const TriageTask(),
        TriageInput(message, DateTime.now()),
      );
      _store.writeTriage(_source, id, status: 'triaged', result: result);
      _foldUp(current, message, result);
      _emit();
      return true;
    } on LlmUnavailableException {
      // Nothing about this message failed, so it does not spend an attempt.
      // The drain stops too: every message behind it would fail identically,
      // and marking a hundred of them is just noise on a laptop where the
      // model server is not running.
      _store.writeTriage(_source, id, status: 'pending');
      _emit();
      return false;
    } on LlmException catch (e) {
      return _recordFailure(current, id, e, e.statusCode);
    } catch (e) {
      return _recordFailure(current, id, e, null);
    }
  }

  /// The session is over, so every message behind this one would fail its
  /// fetch identically. The row goes back to `pending` without spending an
  /// attempt — nothing is wrong with the message — and the drain parks. The
  /// sign-out routing lives in the inbox notifier; triage's whole job here is
  /// to stop burning model time on previews it cannot improve on.
  bool _parkForSession(String id) {
    _store.writeTriage(_source, id, status: 'pending');
    _emit();
    return false;
  }

  bool _recordFailure(
    Map<String, Object?> row,
    String id,
    Object error,
    int? statusCode,
  ) {
    final attempts = ((row['triage_attempts'] as num?)?.toInt() ?? 0) + 1;
    // A 400 from a json_schema request is this app's schema being wrong, not
    // the model's answer. It is identical on every retry, so retrying it
    // burns model time to reproduce a bug.
    final fatal = statusCode == 400 || attempts >= _maxAttempts;
    _store.writeTriage(
      _source,
      id,
      status: fatal ? 'error' : 'pending',
      error: '$error',
      attempts: attempts,
    );
    _emit();
    return true;
  }

  /// Copies one message's result up onto its conversation — but only when the
  /// message is the thread's newest inbound.
  ///
  /// Without that check a backlog would end up showing the wrong ask: the
  /// worker runs newest-first, so an older message finishing later would
  /// overwrite a current CTA with one from last week.
  void _foldUp(
    Map<String, Object?> row,
    Message message,
    TriageResult result,
  ) {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = _store.getConversationRow(_source, key);
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

    _store.updateConversationTriage(
      _source,
      key,
      ctaText: (ask == null || ask.isEmpty)
          ? null
          : (ask.length > _ctaCap ? ask.substring(0, _ctaCap) : ask),
      ctaUrgency: result.urgency,
      category: result.category,
    );
  }

  void _emit() {
    if (_progress.isClosed) return;
    _progress.add(
      TriageProgress(_store.triageCounts(sources: const [_source])),
    );
  }
}
