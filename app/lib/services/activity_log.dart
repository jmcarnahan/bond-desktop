import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../data/message_store.dart';
import 'llm/llm_client.dart';

/// One row of `activity_events`, decoded for the panel.
@immutable
class ActivityEvent {
  final int id;
  final String kind;
  final String? source;
  final String status;
  final String? entityId;
  final int? count;
  final int? durationMs;

  /// The decoded `detail_json`, `{}` when absent or unreadable.
  final Map<String, Object?> detail;

  final String createdAt;

  const ActivityEvent({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.source,
    this.entityId,
    this.count,
    this.durationMs,
    this.detail = const {},
  });

  factory ActivityEvent.fromRow(Map<String, Object?> row) => ActivityEvent(
        id: (row['id'] as num?)?.toInt() ?? 0,
        kind: row['kind'] as String? ?? '',
        source: row['source'] as String?,
        status: row['status'] as String? ?? 'ok',
        entityId: row['entity_id'] as String?,
        count: (row['count'] as num?)?.toInt(),
        durationMs: (row['duration_ms'] as num?)?.toInt(),
        detail: _decodeDetail(row['detail_json']),
        createdAt: row['created_at'] as String? ?? '',
      );

  static Map<String, Object?> _decodeDetail(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Map<String, Object?>.from(decoded)
          : const {};
    } on FormatException {
      return const {};
    }
  }
}

/// Appends what the app did to `activity_events` and ticks a broadcast stream
/// so an open panel updates without polling.
///
/// The one rule everything below serves: **the log must never be able to
/// break the pipeline it observes.** Every write is wrapped, every failure is
/// a [debugPrint], and the default every instrumented constructor takes is
/// [ActivityLog.disabled] — a recorder that stores nothing.
///
/// Besides the finished rows, it carries the facts about each unit of work IN
/// FLIGHT — the model calls it made ([noteLlmCall]) and whatever its handler
/// chose to add ([note]/[noteStatus]) — in a pending slot that the unit's own
/// [record] folds in and clears.
///
/// One slot per unit, not one slot total, and the drains are why. They run up
/// to K=3 items in flight, so three triage messages' model calls interleave —
/// and with a single slot, whichever recorded first would claim all three
/// tallies (the original single-slot design said as much: "if a future phase
/// parallelizes the drains, this slot is the thing that breaks"). The fix is
/// [inSpan]: a queue wraps each item's whole async flow in it, and every
/// note or record made anywhere inside — the handler's, the storyline
/// service's, even the [LlmCallObserver] the client fires mid-request — lands
/// in that item's slot, because a callback runs in whatever zone invokes it
/// and the item's entire await chain lives in the item's zone.
///
/// Callers that never overlap — the sync passes, anything outside a drain —
/// use the ROOT slot without wrapping and behave exactly as before; see
/// [_staleAfter], which makes a caller torn down mid-unit (a backend switch)
/// harmless: its orphaned tally ages out instead of being attributed to
/// whatever runs next. A span's slot needs no aging at all — it dies with the
/// zone that owned it.
class ActivityLog {
  /// A pending tally older than this belongs to a unit of work that never
  /// recorded — a torn-down queue, a crash mid-item — and is dropped rather
  /// than folded into a stranger's row.
  static const Duration _staleAfter = Duration(minutes: 10);

  /// The kinds that run on a schedule rather than because something happened,
  /// and so are the only ones a "did nothing" outcome is unremarkable for. A
  /// triage or a draft that did nothing is news; a poll that did nothing is
  /// the normal state of an inbox.
  static const Set<String> _quietKinds = {
    'sync_mail',
    'sync_teams',
    'storyline',
    'storyline_sweep',
  };

  /// Detail keys that describe how much a pass LOOKED AT, not what it
  /// changed. A connected Teams tenant always has chats to scan, so if the
  /// scan tally counted as "something happened", no Teams sync would ever be
  /// quiet and the panel would fill with "nothing new" rows from the one
  /// connector that only syncs when the user asks.
  static const Set<String> _scanKeys = {'chats_seen', 'chats_fetched'};

  /// Where each pass's completion time is stamped. `storyline` is absent on
  /// purpose: it is per-thread work, so "when did it last run" is a fact about
  /// whichever thread happened to be extracted, not about the mailbox.
  static const Map<String, String> _lastRunPrefKeys = {
    'sync_mail': activityLastSyncMailKey,
    'sync_teams': activityLastSyncTeamsKey,
    'storyline_sweep': activityLastSweepKey,
  };

  /// The zone value under which [inSpan] parks a unit's slot. An [Object]
  /// identity key rather than a symbol so nothing outside this file can forge
  /// or read it.
  static final Object _spanKey = Object();

  final MessageStore? _store;
  final StreamController<ActivityEvent>? _events;

  /// The slot for callers that never overlap. Everything inside an [inSpan]
  /// gets its own instead.
  final _PendingSlot _rootSlot = _PendingSlot();

  _PendingSlot get _slot =>
      (Zone.current[_spanKey] as _PendingSlot?) ?? _rootSlot;

  ActivityLog(MessageStore store)
      : _store = store,
        _events = StreamController<ActivityEvent>.broadcast();

  /// A recorder that stores nothing and emits nothing — the default every
  /// instrumented constructor takes, so tests that build a SyncService or a
  /// queue without caring about activity keep compiling unchanged.
  ActivityLog.disabled()
      : _store = null,
        _events = null;

  /// Ticks once per recorded event. Broadcast, so an open panel subscribing
  /// late misses nothing it cannot re-read from the table.
  Stream<ActivityEvent> get events =>
      _events?.stream ?? const Stream<ActivityEvent>.empty();

  /// Runs one unit of work with its own pending slot, so the notes and model
  /// calls it makes anywhere in its async flow fold into ITS row rather than
  /// into whichever concurrent sibling records first. The queues wrap each
  /// item in this; a caller with nothing concurrent going on simply doesn't.
  Future<T> inSpan<T>(Future<T> Function() body) {
    if (_store == null) return body();
    return runZoned(body, zoneValues: {_spanKey: _PendingSlot()});
  }

  /// Facts the handler wants on the row the worker is about to write —
  /// extraction's topics, a draft's length.
  void note(Map<String, Object?> facts) {
    if (_store == null) return;
    final slot = _slot.._touch();
    slot.detail.addAll(facts);
  }

  /// Overrides the status the worker would otherwise write — a handler that
  /// early-returned wants `skipped`, not a misleading `ok`.
  void noteStatus(String status) {
    if (_store == null) return;
    final slot = _slot.._touch();
    slot.status = status;
  }

  /// Accumulated, not stored: calls, summed ms, summed tokens. A storyline
  /// sweep makes several model calls per item and they belong on one row.
  void noteLlmCall(LlmCallRecord call) {
    if (_store == null) return;
    final slot = _slot.._touch();
    slot.llmCalls += 1;
    slot.llmMs += call.durationMs;
    slot.promptTokens += call.promptTokens ?? 0;
    slot.completionTokens += call.completionTokens ?? 0;
    slot.llmLabel = call.label;
    if (call.outcome != 'ok') slot.llmError = call.error ?? call.outcome;
  }

  /// The status the pending slot holds, or [fallback] when nothing set one.
  /// Read-and-consumed by the worker at its `done` write, so a handler's
  /// `skipped` beats the worker's `ok` without the handler throwing.
  String pendingStatusOr(String fallback) => _slot.status ?? fallback;

  /// Appends one event, folding in and clearing whatever [note]/[noteLlmCall]
  /// accumulated since the last record.
  ///
  /// Except when the event is QUIET — a sync or a storyline pass that finished
  /// `ok` having done nothing at all ([_isQuiet]). Those are most of them: the
  /// mail poll runs on a timer whether or not the mailbox moved, and a panel
  /// whose every screen is "Mail sync — nothing new" hides the handful of rows
  /// a person opened it to read. A quiet pass writes no row.
  ///
  /// Quiet is not the same as unrecorded, and the two things a suppressed pass
  /// still owes the reader are both delivered here. The timestamp goes to the
  /// pref ([_lastRunPrefKeys]) that the panel's "last sync" tile reads, so the
  /// pass is still visible as freshness rather than as a row. And a TRANSIENT
  /// event — `id: -1`, never stored, never re-readable — goes to the stream, so
  /// an open panel rebuilds and those relative times keep moving. Roughly once
  /// a minute, which is what makes the tile trustworthy: a stalled clock on a
  /// live panel would read as a stalled sync.
  Future<void> record(
    String kind, {
    String status = 'ok',
    String? source,
    String? entityId,
    int? count,
    int? durationMs,
    Map<String, Object?> detail = const {},
  }) async {
    final store = _store;
    if (store == null) return;
    try {
      // Before the first await, so the tally this event carries is drained in
      // the zone that accumulated it and cannot pick up a sibling's notes.
      final merged = <String, Object?>{..._drainPending(), ...detail};

      final prefKey = _lastRunPrefKeys[kind];
      if (prefKey != null && status == 'ok') {
        await store.setPref(prefKey, DateTime.now().toUtc().toIso8601String());
      }

      if (_isQuiet(kind, status, count, merged)) {
        final events = _events;
        if (events != null && !events.isClosed) {
          events.add(ActivityEvent(
            id: -1,
            kind: kind,
            status: status,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            source: source,
            count: count,
            durationMs: durationMs,
            detail: merged,
          ));
        }
        return;
      }

      final json = merged.isEmpty ? null : jsonEncode(merged);
      await store.recordActivity(
        kind: kind,
        status: status,
        source: source,
        entityId: entityId,
        count: count,
        durationMs: durationMs,
        detailJson: json,
      );
      final events = _events;
      if (events != null && !events.isClosed) {
        final rows = await store.recentActivity(limit: 1);
        if (rows.isNotEmpty && !events.isClosed) {
          events.add(ActivityEvent.fromRow(rows.first));
        }
      }
    } catch (e) {
      debugPrint('ActivityLog: dropped a $kind event: $e');
      _slot._clear();
    }
  }

  void dispose() {
    _events?.close();
  }

  /// Whether this event is a scheduled pass that came back empty-handed.
  ///
  /// The detail test is the careful half, and it is deliberately conservative:
  /// a pass is quiet only when EVERY value it carries — the scan tallies in
  /// [_scanKeys] aside — is a number equal to zero. Anything else — a
  /// `resync: true`, a model tally, a storyline's noted `assigned` — is
  /// something that happened, and the row survives to say so. Erring this way
  /// costs an occasional dull row; erring the other way would silently
  /// swallow the row that explained a slow morning.
  static bool _isQuiet(
    String kind,
    String status,
    int? count,
    Map<String, Object?> detail,
  ) {
    if (!_quietKinds.contains(kind)) return false;
    if (status != 'ok') return false;
    if ((count ?? 0) != 0) return false;
    return detail.entries.every((entry) =>
        _scanKeys.contains(entry.key) ||
        (entry.value is num && entry.value == 0));
  }

  Map<String, Object?> _drainPending() => _slot._drain();
}

/// One unit of work's accumulating tally — the root caller's, or a span's.
///
/// The staleness handling ([_touch]) only ever matters for the root slot: a
/// span's slot is unreachable once its zone's work ends, recorded or not.
/// It stays on the class rather than the root because it is behavior of a
/// slot, not of the log.
class _PendingSlot {
  Map<String, Object?> detail = {};
  String? status;
  int llmCalls = 0;
  int llmMs = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  String? llmLabel;
  String? llmError;
  DateTime? since;

  void _touch() {
    final start = since;
    if (start != null &&
        DateTime.now().difference(start) > ActivityLog._staleAfter) {
      _clear();
    }
    since ??= DateTime.now();
  }

  Map<String, Object?> _drain() {
    _touch();
    final drained = detail;
    if (llmCalls > 0) {
      drained['llm_calls'] = llmCalls;
      drained['llm_ms'] = llmMs;
      if (promptTokens > 0) drained['prompt_tokens'] = promptTokens;
      if (completionTokens > 0) drained['completion_tokens'] = completionTokens;
      final label = llmLabel;
      if (label != null) drained['llm_label'] = label;
    }
    final error = llmError;
    if (error != null) drained['llm_error'] = error;
    _clear();
    return drained;
  }

  void _clear() {
    detail = {};
    status = null;
    llmCalls = 0;
    llmMs = 0;
    promptTokens = 0;
    completionTokens = 0;
    llmLabel = null;
    llmError = null;
    since = null;
  }
}
