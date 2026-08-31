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
/// Besides the finished rows, it carries the facts about the unit of work IN
/// FLIGHT — the model calls it made ([noteLlmCall]) and whatever its handler
/// chose to add ([note]/[noteStatus]) — in one pending slot that the next
/// [record] folds in and clears. One slot is enough because both drains hold
/// the shared `DrainGate` and each is strictly serial: there is never a
/// second unit of work to interleave with. If a future phase parallelizes
/// the drains, this slot is the thing that breaks — see [_staleAfter], which
/// also makes a queue torn down mid-drain (a backend switch) harmless: its
/// orphaned tally ages out instead of being attributed to whatever runs next.
class ActivityLog {
  /// A pending tally older than this belongs to a unit of work that never
  /// recorded — a torn-down queue, a crash mid-item — and is dropped rather
  /// than folded into a stranger's row.
  static const Duration _staleAfter = Duration(minutes: 10);

  final MessageStore? _store;
  final StreamController<ActivityEvent>? _events;

  Map<String, Object?> _pendingDetail = {};
  String? _pendingStatus;
  int _pendingLlmCalls = 0;
  int _pendingLlmMs = 0;
  int _pendingPromptTokens = 0;
  int _pendingCompletionTokens = 0;
  String? _pendingLlmLabel;
  String? _pendingLlmError;
  DateTime? _pendingSince;

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

  /// Facts the handler wants on the row the worker is about to write —
  /// extraction's topics, a draft's length.
  void note(Map<String, Object?> facts) {
    if (_store == null) return;
    _touchPending();
    _pendingDetail.addAll(facts);
  }

  /// Overrides the status the worker would otherwise write — a handler that
  /// early-returned wants `skipped`, not a misleading `ok`.
  void noteStatus(String status) {
    if (_store == null) return;
    _touchPending();
    _pendingStatus = status;
  }

  /// Accumulated, not stored: calls, summed ms, summed tokens. A storyline
  /// sweep makes several model calls per item and they belong on one row.
  void noteLlmCall(LlmCallRecord call) {
    if (_store == null) return;
    _touchPending();
    _pendingLlmCalls += 1;
    _pendingLlmMs += call.durationMs;
    _pendingPromptTokens += call.promptTokens ?? 0;
    _pendingCompletionTokens += call.completionTokens ?? 0;
    _pendingLlmLabel = call.label;
    if (call.outcome != 'ok') _pendingLlmError = call.error ?? call.outcome;
  }

  /// The status the pending slot holds, or [fallback] when nothing set one.
  /// Read-and-consumed by the worker at its `done` write, so a handler's
  /// `skipped` beats the worker's `ok` without the handler throwing.
  String pendingStatusOr(String fallback) => _pendingStatus ?? fallback;

  /// Appends one event, folding in and clearing whatever [note]/[noteLlmCall]
  /// accumulated since the last record.
  void record(
    String kind, {
    String status = 'ok',
    String? source,
    String? entityId,
    int? count,
    int? durationMs,
    Map<String, Object?> detail = const {},
  }) {
    final store = _store;
    if (store == null) return;
    try {
      final merged = <String, Object?>{..._drainPending(), ...detail};
      final json = merged.isEmpty ? null : jsonEncode(merged);
      store.recordActivity(
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
        final rows = store.recentActivity(limit: 1);
        if (rows.isNotEmpty) events.add(ActivityEvent.fromRow(rows.first));
      }
    } catch (e) {
      debugPrint('ActivityLog: dropped a $kind event: $e');
      _clearPending();
    }
  }

  void dispose() {
    _events?.close();
  }

  void _touchPending() {
    final since = _pendingSince;
    if (since != null && DateTime.now().difference(since) > _staleAfter) {
      _clearPending();
    }
    _pendingSince ??= DateTime.now();
  }

  Map<String, Object?> _drainPending() {
    _touchPending();
    final detail = _pendingDetail;
    if (_pendingLlmCalls > 0) {
      detail['llm_calls'] = _pendingLlmCalls;
      detail['llm_ms'] = _pendingLlmMs;
      if (_pendingPromptTokens > 0) {
        detail['prompt_tokens'] = _pendingPromptTokens;
      }
      if (_pendingCompletionTokens > 0) {
        detail['completion_tokens'] = _pendingCompletionTokens;
      }
      final label = _pendingLlmLabel;
      if (label != null) detail['llm_label'] = label;
    }
    final llmError = _pendingLlmError;
    if (llmError != null) detail['llm_error'] = llmError;
    _clearPending();
    return detail;
  }

  void _clearPending() {
    _pendingDetail = {};
    _pendingStatus = null;
    _pendingLlmCalls = 0;
    _pendingLlmMs = 0;
    _pendingPromptTokens = 0;
    _pendingCompletionTokens = 0;
    _pendingLlmLabel = null;
    _pendingLlmError = null;
    _pendingSince = null;
  }
}
