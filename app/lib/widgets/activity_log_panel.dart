import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../services/activity_log.dart';
import '../theme/tokens.dart';
import 'time_format.dart';

/// What the app has been doing while nobody was watching it.
///
/// The rule this panel exists to keep: **quiet is not the same as broken.** An
/// inbox that syncs in the background and annotates with a local model gives
/// the LO no way to tell "nothing arrived" from "the model server is off" or
/// "the Teams scope was never granted" — and the guess they make in that gap is
/// always the pessimistic one. Every row here is one thing that happened, in a
/// sentence, with the states that are not failures — parks, skips — rendered as
/// states rather than as red.
///
/// Dumb by construction, like the Later digest: stats and rows in, nothing read
/// from a provider, and [now] injected so a widget test pins the clock.
class ActivityLogPanel extends StatelessWidget {
  /// The header numbers, aggregated over whatever window the caller chose.
  final ActivityStats stats;

  /// Newest first — the order the store hands them over, and the order they
  /// are rendered in.
  final List<ActivityEvent> events;

  final DateTime now;

  const ActivityLogPanel({
    super.key,
    required this.stats,
    required this.events,
    required this.now,
  });

  /// How each kind is named to a person. The panel and [describe] read the
  /// same map, so a row's label and its sentence can never disagree.
  static const Map<String, String> _kindLabels = {
    'sync_mail': 'Mail sync',
    'sync_teams': 'Teams sync',
    'triage': 'Triage',
    'extract': 'Extract',
    'draft': 'Draft',
    'storyline': 'Storylines',
    'storyline_sweep': 'Storyline sweep',
    'embed_fail': 'Embeddings',
  };

  /// The machine-readable reasons the pipeline records, in the words the LO
  /// would use. Anything unmapped falls back to the raw reason with its
  /// underscores opened up — a new reason reads awkwardly rather than
  /// disappearing.
  static const Map<String, String> _reasons = {
    'model_unavailable': 'model server off',
    'session': 'signed out',
    'no_scope': 'not connected',
    'deleted': 'message deleted',
    'gated': 'nothing worth extracting',
    'already_drafted': 'already drafted',
    'no_reply_target': 'nothing to reply to',
  };

  static String _label(String kind) => _kindLabels[kind] ?? kind;

  static String _reason(Object? raw) {
    final reason = raw is String && raw.isNotEmpty ? raw : null;
    if (reason == null) return '';
    return _reasons[reason] ?? reason.replaceAll('_', ' ');
  }

  /// One event as one sentence.
  ///
  /// Pure and static: this is where every judgement about what a row MEANS
  /// lives — which statuses are failures, which are states, and which detail
  /// keys are worth a reader's attention — and keeping it out of the widget is
  /// what makes those judgements testable without a pump.
  ///
  /// Status is read before kind, because a park or a failure means the same
  /// thing whatever was being attempted, while the `ok` sentence is different
  /// for every kind.
  ///
  /// Model-call tallies are deliberately absent: `llm_calls` and the token
  /// counts are on nearly every AI row, and spending the sentence on them
  /// would bury the one fact the row is actually reporting. The time they
  /// took rides in the trailing duration instead.
  static String describe(ActivityEvent e) {
    final label = _label(e.kind);
    final detail = e.detail;

    // The embedding server is optional at runtime, so its only event is a
    // failure and it reads as a state of that server, not as a failed step.
    if (e.kind == 'embed_fail') {
      final reason = _reason(detail['reason']);
      return reason.isEmpty ? 'Embeddings unavailable' : 'Embeddings — $reason';
    }

    switch (e.status) {
      case 'parked':
        final reason = _reason(detail['reason']);
        return reason.isEmpty ? '$label parked' : '$label parked — $reason';
      case 'error':
        final error = detail['error'];
        final text = error is String && error.isNotEmpty ? error : null;
        return text == null ? '$label failed' : '$label failed — $text';
      case 'retry':
        final attempts = detail['attempts'];
        return attempts is num
            ? '$label retry (attempt ${attempts.toInt()})'
            : '$label retry';
      case 'skipped':
        final reason = _reason(detail['reason']);
        return reason.isEmpty ? '$label skipped' : '$label skipped — $reason';
    }

    switch (e.kind) {
      case 'sync_mail':
      case 'sync_teams':
        final count = e.count ?? 0;
        return count == 0 ? '$label — nothing new' : '$label — $count new';
      case 'triage':
        final parts = _parts([detail['urgency'], detail['category']]);
        return parts.isEmpty ? label : '$label — $parts';
      case 'extract':
        final topics = detail['topics'];
        final parts = _parts([
          detail['intent'],
          if (topics is List) topics.join(', ') else null,
        ]);
        return parts.isEmpty ? label : '$label — $parts';
      case 'draft':
        final chars = detail['chars'];
        return chars is num
            ? 'Draft written — ${chars.toInt()} chars'
            : 'Draft written';
      case 'storyline':
        return 'Storylines updated';
      case 'storyline_sweep':
        return 'Storyline sweep';
      default:
        return label;
    }
  }

  /// The pieces of a sentence that are actually present, joined the one way
  /// this panel joins things.
  static String _parts(List<Object?> values) => [
        for (final value in values)
          if (value is String && value.isNotEmpty) value,
      ].join(' · ');

  /// A duration in the largest unit that still says something: milliseconds
  /// under a second, one decimal of seconds under a minute, minutes and
  /// seconds above it. A model call that took 94 seconds is the interesting
  /// row on this panel, and "94000ms" is not how anyone reads that.
  static String formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final seconds = (ms / 1000).round();
    return '${seconds ~/ 60}m${(seconds % 60).toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      children: [
        _tiles(),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(BondSpacing.s32),
            child: Text(
              'Nothing recorded yet.',
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final (dayKey, rows) in _grouped()) ...[
            _dayHeader(dayKey),
            for (final event in rows) _row(event),
          ],
      ],
    );
  }

  /// The headline numbers. A [Wrap] rather than a Row: six tiles do not fit
  /// the narrow layout's main pane, and a tile that has wrapped still reads
  /// correctly while a squeezed one does not.
  Widget _tiles() {
    final avg = stats.avgMsByKind;
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Wrap(
        spacing: BondSpacing.s12,
        runSpacing: BondSpacing.s12,
        children: [
          _tile('${stats.ingestedBySource['email'] ?? 0}', 'Mail messages'),
          _tile('${stats.ingestedBySource['teams'] ?? 0}', 'Teams messages'),
          _tile('${stats.aiItemCount}', 'AI items'),
          _tile(
            '${stats.errorCount}',
            'Errors',
            // Only a count that is not zero earns the colour. A red nought is
            // an alarm about the absence of a problem.
            valueColor: stats.errorCount > 0 ? BondColors.error : null,
          ),
          _tile(_avg(avg['triage']), 'Avg triage'),
          _tile(_avg(avg['extract']), 'Avg extract'),
        ],
      ),
    );
  }

  static String _avg(int? ms) => ms == null ? '—' : formatDuration(ms);

  Widget _tile(String value, String label, {Color? valueColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s16,
        vertical: BondSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: BondType.mono.copyWith(
              fontSize: 20,
              height: 28 / 20,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: BondType.caption),
        ],
      ),
    );
  }

  /// The events by local calendar day, newest day first, each day's rows in
  /// the order they were handed over.
  List<(String, List<ActivityEvent>)> _grouped() {
    final days = <String, List<ActivityEvent>>{};
    for (final event in events) {
      final dayKey = dayKeyOfIso(event.createdAt) ?? '';
      (days[dayKey] ??= <ActivityEvent>[]).add(event);
    }
    final dayKeys = days.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final dayKey in dayKeys) (dayKey, days[dayKey]!)];
  }

  Widget _dayHeader(String dayKey) {
    final label =
        formatDayLabel(dayKey) ?? (dayKey.isEmpty ? 'Undated' : dayKey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s4,
        BondSpacing.s16,
        BondSpacing.s4,
        BondSpacing.s8,
      ),
      child: Text(label.toUpperCase(), style: BondType.label),
    );
  }

  /// One event: what it was, what happened, when, and how long it took.
  ///
  /// The kind is its own column so a reader scanning for "what did triage do"
  /// has a left edge to run down — and the sentence beside it drops the kind
  /// [describe] opens with, because "Mail sync · Mail sync — 4 new" is the same
  /// words twice. Whole word only: "Storyline" must not eat the "s" off
  /// "Storylines updated".
  Widget _row(ActivityEvent event) {
    final label = _label(event.kind);
    final sentence = describe(event);
    final tail = switch (sentence) {
      _ when sentence == label => '',
      _ when sentence.startsWith('$label — ') =>
        sentence.substring(label.length + 3),
      _ when sentence.startsWith('$label ') =>
        sentence.substring(label.length + 1),
      _ => sentence,
    };
    final ago = relativeTime(event.createdAt, now);
    final durationMs = event.durationMs;

    return Material(
      color: BondColors.surface,
      borderRadius: BondRadii.mdAll,
      child: InkWell(
        onTap: null,
        borderRadius: BondRadii.mdAll,
        child: Container(
          margin: const EdgeInsets.only(bottom: BondSpacing.s4),
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s12,
            vertical: BondSpacing.s8,
          ),
          decoration: BoxDecoration(
            borderRadius: BondRadii.mdAll,
            border: Border.all(color: BondColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: BondSpacing.s4),
                child: _dot(event.status),
              ),
              const SizedBox(width: BondSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: BondType.small.copyWith(
                        color: BondColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (tail.isNotEmpty)
                      Text(
                        tail,
                        style: BondType.small,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: BondSpacing.s8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ago != null) Text(ago, style: BondType.caption),
                  if (durationMs != null)
                    Text(
                      formatDuration(durationMs),
                      style: BondType.mono.copyWith(
                        fontSize: 12,
                        height: 16 / 12,
                        color: BondColors.inkSecondary,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The status, as the smallest mark that can carry it.
  ///
  /// A park and a retry share the attention colour on purpose: both mean the
  /// work is still owed, and neither is something the LO did wrong. Only
  /// `error` is red.
  Widget _dot(String status) {
    final color = switch (status) {
      'ok' => BondColors.success,
      'skipped' => BondColors.inkMuted,
      'retry' || 'parked' => BondColors.attention,
      'error' => BondColors.error,
      _ => BondColors.inkMuted,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
