import 'dart:convert';

import '../data/message_store.dart';
import 'activity_log.dart';
import 'backend/auth_session.dart';
import 'backend/backend_types.dart';
import 'backend/mail_backend.dart';
import 'backend/teams_backend.dart';

/// Tells the server about reads that already happened locally.
///
/// [MessageStore.markConversationRead] flips the rows the moment a thread is
/// opened and leaves a `mark_read` work row carrying the ids it flipped. This
/// drains those rows. Nothing on screen waits for it: by the time it runs, the
/// thread is already unbold and the user has moved on.
///
/// **Deliberately not an `AiWorker` handler**, though the rows live in the same
/// table. Every one of those lanes drains behind a `DrainGate` — the fast one
/// behind whatever triage is doing, the other two behind a sweep or a draft —
/// and each parks a whole kind when its model server is down. An ack is a
/// 200-millisecond PATCH that has nothing to do with any model, and putting it
/// in any of those queues would leave the server's unread badge minutes behind
/// the app's — or stalled entirely — for reasons that are none of its
/// business.
///
/// A row this queue parks at `error` is not stuck for good. A later pump
/// revives it while it is under the store's own lifetime ceiling, and reopening
/// the thread rewrites it as `pending` with `attempts` back to zero — so the
/// gesture a person would naturally repeat is also the one that retries. That
/// is why [_maxAttempts] is small: it bounds a bad minute, not the ack.
class ReadAckQueue {
  static const String _kind = 'mark_read';

  /// The sources this queue drains. Both, and they are acked completely
  /// differently: mail names the messages it read, while a chat names only
  /// itself, because Teams keeps read state as one viewpoint per conversation.
  /// [_ackOne] is where that split lives.
  static const List<String> _sources = ['email', 'teams'];

  /// Failures before the row parks at `error`, where the revival at the top of
  /// each drain buys it one more attempt at a time — the AI worker's shape, and
  /// [MessageStore.reviveErroredWork] holds the ceiling that ends it for good.
  static const int _maxAttempts = 3;

  final MessageStore _store;
  final MailBackend _mail;
  final TeamsBackend _teams;
  final AuthSession _auth;
  final ActivityLog _log;

  /// The drain in flight, or null. Doubles as the "already running" guard and
  /// as what a second [pump] returns, so a caller that pumped mid-drain still
  /// awaits real completion instead of an instant no-op.
  Future<void>? _draining;

  /// Set when [pump] lands mid-drain: the running drain makes one more pass
  /// rather than letting a row written a microsecond after its last claim wait
  /// for the next thread the user opens.
  bool _repump = false;

  ReadAckQueue(
    this._store,
    this._mail,
    this._teams,
    this._auth, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  /// Drains every claimable `mark_read` row, then returns.
  ///
  /// Single-flight: a call while a drain is running does not start a racing
  /// one — it schedules one more pass on the active drain and returns that
  /// drain's future, so the caller still awaits the pass that will do its work.
  /// The claim itself is what makes even a lost race harmless: it is one
  /// UPDATE…RETURNING, so no two drains can be handed the same row.
  Future<void> pump() {
    final inFlight = _draining;
    if (inFlight != null) {
      _repump = true;
      return inFlight;
    }
    final drain = _drain();
    _draining = drain.whenComplete(() => _draining = null);
    return _draining!;
  }

  Future<void> _drain() async {
    // Once per drain, before the first claim: a failure that was about the
    // network heals on the next thread open instead of waiting for the one
    // that queued it to be reopened. Kind-filtered, because the model queues
    // have their own revival on the sync path and reviving them from here
    // would hand them a free attempt every time somebody opened a thread. NOT
    // inside the repump loop, or a row this drain just parked would be handed
    // straight back to it.
    await _store.reviveErroredWork(kind: _kind);

    // One try per row per drain. A failed row goes back to `pending` and, being
    // the newest, is exactly what the next claim hands back — so without this
    // set a single bad minute would spend all three of a row's attempts in one
    // breath, and against a thread carrying a hundred ids that is three hundred
    // requests inside a second. The row waits for the next pump instead, which
    // is the next thread the user opens.
    final tried = <String>{};

    // The grant, read once per source per drain. In MCP mode a scope check is
    // itself a server round-trip, and the answer cannot change mid-drain in
    // any way this queue should act on.
    final gates = <String, _Gate>{};

    do {
      _repump = false;
      while (true) {
        final item = await _store.claimPendingWork(_kind, sources: _sources);
        if (item == null) break;
        final source = item['source'] as String? ?? 'email';
        final id = item['entity_id'] as String? ?? '';
        if (!tried.add('$source\u0000$id')) {
          // Put the claim back before stopping: the row is `processing` from
          // the statement that handed it over, and leaving it there would take
          // it out of the queue until the next launch.
          await _store.writeWork(_kind, source, id, status: 'pending');
          break;
        }
        if (!await _ackOne(item, gates)) return;
      }
    } while (_repump);
  }

  /// What the grant allows for [source]'s acks.
  ///
  /// [AuthSession.hasScope] answers false both when the grant lacks the scope
  /// and when there was no grant to read — a failed probe, an MCP server mid-
  /// restart, a signed-out session. Only the first is forever, and `skipped`
  /// is a terminal status nothing revives, so the two must not be conflated.
  /// `mail.read` is the baseline every usable session carries in both backend
  /// modes, and a session that cannot answer it is a session that cannot
  /// answer anything: its rows wait as `pending` for one that can.
  Future<_Gate> _resolveGate(String source) async {
    final scope = source == 'teams' ? 'chat.readwrite' : 'mail.readwrite';
    if (await _auth.hasScope(scope)) return _Gate.allowed;
    if (await _auth.hasScope('mail.read')) return _Gate.skipped;
    return _Gate.parked;
  }

  /// One row. Returns false when the drain should stop rather than claim the
  /// next one.
  Future<bool> _ackOne(
    Map<String, Object?> item,
    Map<String, _Gate> gates,
  ) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final sw = Stopwatch()..start();

    final gate = gates[source] ??= await _resolveGate(source);

    // No session to ask means no verdict on the row — put the claim back and
    // stop the drain, exactly as an [AuthException] from the request itself
    // would.
    if (gate == _Gate.parked) {
      await _store.writeWork(_kind, source, id, status: 'pending');
      await _log.record(
        _kind,
        status: 'parked',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: const {'reason': 'session'},
      );
      return false;
    }

    // Before any request: an account that never granted the write scope
    // cannot ack, and finding that out from a 403 per thread would spend the
    // requests to learn what the grant already says. `skipped` is terminal —
    // nothing revives it, because nothing about it is going to change without
    // a new sign-in.
    if (gate == _Gate.skipped) {
      await _store.writeWork(_kind, source, id, status: 'skipped');
      await _log.record(
        _kind,
        status: 'skipped',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: const {'reason': 'no_scope'},
      );
      return true;
    }

    // What the row names, and what the two sources do with it. Mail acks the
    // MESSAGES it read, one id at a time. A chat acks ITSELF — `entity_id` is
    // the chat id, and the payload ids are deliberately unused, because Teams
    // keeps read state as one viewpoint per conversation and moving it to the
    // newest message covers every id the payload could have named. The ids are
    // still decoded for the chat, but only so the activity row can say how many
    // messages the read was worth.
    final ids = _decodeIds(item['payload_json']);
    final chat = source == 'teams';

    // A mail payload that decodes to nothing is `done`, not an error: the ids
    // are the whole errand, and a row with none has no request to make. A chat
    // is never in that position, so it does not take this exit — the id it was
    // claimed under IS the request.
    if (!chat && ids.isEmpty) {
      await _store.writeWork(_kind, source, id, status: 'done');
      await _log.record(
        _kind,
        source: source,
        entityId: id,
        count: 0,
        durationMs: sw.elapsedMilliseconds,
      );
      return true;
    }

    try {
      if (chat) {
        await _teams.markChatRead(id);
      } else {
        final failed = await _mail.markRead(ids);
        if (failed.isNotEmpty) {
          // Every id the backend handed back is one worth asking about again —
          // it already dropped the ones that are merely gone. The whole row
          // retries, ids the server accepted included: marking a read message
          // read again is free, and remembering which ones landed would mean
          // rewriting the payload mid-drain.
          return await _failed(
            item,
            '${failed.length} of ${ids.length} messages were not marked read',
            sw.elapsedMilliseconds,
          );
        }
      }
      await _store.writeWork(_kind, source, id, status: 'done');
      await _log.record(
        _kind,
        source: source,
        entityId: id,
        count: ids.length,
        durationMs: sw.elapsedMilliseconds,
      );
      return true;
    } on AuthException {
      // Nothing about this row failed, so it does not spend an attempt — and
      // nothing behind it is worth trying either, because a dead session fails
      // every ack identically.
      await _store.writeWork(_kind, source, id, status: 'pending');
      await _log.record(
        _kind,
        status: 'parked',
        source: source,
        entityId: id,
        durationMs: sw.elapsedMilliseconds,
        detail: const {'reason': 'session'},
      );
      return false;
    } catch (e) {
      return await _failed(item, '$e', sw.elapsedMilliseconds);
    }
  }

  /// Spends one attempt, and parks the row once it has none left. Always
  /// returns true: a failed ack is about that thread, and the next row's
  /// messages are a different set of ids on the same working session.
  Future<bool> _failed(
    Map<String, Object?> item,
    String error,
    int durationMs,
  ) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';
    final attempts = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
    final spent = attempts >= _maxAttempts;

    await _store.writeWork(
      _kind,
      source,
      id,
      status: spent ? 'error' : 'pending',
      error: error,
      attempts: attempts,
    );
    // `retry` while the row still has an attempt left, `error` once it does
    // not — the work row's `pending` cannot tell those apart after the fact.
    await _log.record(
      _kind,
      status: spent ? 'error' : 'retry',
      source: source,
      entityId: id,
      durationMs: durationMs,
      detail: {'error': error, 'attempts': attempts},
    );
    return true;
  }

  /// The ids one row carries. A payload that is not a JSON array of strings
  /// carries none — the drain reads what [MessageStore] wrote and never
  /// defends against a half-written array, so the answer to anything else is
  /// "nothing to ack", not a crash.
  static List<String> _decodeIds(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final id in decoded)
          if (id is String && id.isNotEmpty) id,
      ];
    } on FormatException {
      return const [];
    }
  }
}

/// The three answers a grant can give an ack: go ahead, never, and not now.
enum _Gate { allowed, skipped, parked }
