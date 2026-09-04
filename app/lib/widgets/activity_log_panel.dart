import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../services/activity_log.dart';
import '../theme/tokens.dart';
import 'home_metrics.dart';
import 'time_format.dart';

/// What the app has been doing while nobody was watching it.
///
/// The rule this panel exists to keep: **quiet is not the same as broken.** An
/// inbox that syncs in the background and annotates with a local model gives
/// the user no way to tell "nothing arrived" from "the model server is off" or
/// "the Teams scope was never granted" — and the guess they make in that gap is
/// always the pessimistic one. Every row here is one thing that happened, in a
/// sentence, with the states that are not failures — parks, skips — rendered as
/// states rather than as red.
///
/// A table rather than a list of cards, because the question a person brings to
/// this screen is comparative — "is triage always this slow?", "when did that
/// start failing?" — and comparison needs columns that line up. The cost is
/// that a row can only hold what fits on one line, which is what the
/// tap-to-expand block underneath is for: everything the row had to elide,
/// including the raw detail map, in place rather than in a dialog.
///
/// Liveness is the tiles' job. Rows are only written when something actually
/// happened (see `ActivityLog.record`), so an empty table is the normal state
/// of a working app, and the "last sync" tiles are what separate that from a
/// sync that has not run since Tuesday.
///
/// Dumb by construction, like the Later digest: stats and rows in, nothing read
/// from a provider, and [now] injected so a widget test pins the clock.
class ActivityLogPanel extends StatefulWidget {
  /// The header numbers, aggregated over whatever window the caller chose.
  final ActivityStats stats;

  /// Newest first — the order the store hands them over, and the order they
  /// are rendered in.
  final List<ActivityEvent> events;

  final DateTime now;

  /// When each scheduled pass last finished, ISO-8601. Read from the prefs the
  /// recorder stamps rather than from [events], because the passes these
  /// describe are usually the ones that wrote no row at all. Null renders as a
  /// dash — never run, or never recorded.
  final String? lastMailSyncIso;
  final String? lastTeamsSyncIso;
  final String? lastSweepIso;

  /// What an event was ABOUT, in words — a subject line. Resolving it needs the
  /// store, which this widget deliberately cannot reach, so the lookup is
  /// passed in. Returning null is ordinary and not an error: plenty of events
  /// point at rows that are not conversations or no longer exist.
  final String? Function(ActivityEvent event)? entityLabel;

  /// How many pipeline items have been retried past their ceiling and given
  /// up on. The error tile counts every failure, most of which a later sync
  /// retries on its own; this is the subset nothing will try again, and it is
  /// the one number a person can act on.
  final int deadItems;

  const ActivityLogPanel({
    super.key,
    required this.stats,
    required this.events,
    required this.now,
    this.lastMailSyncIso,
    this.lastTeamsSyncIso,
    this.lastSweepIso,
    this.entityLabel,
    this.deadItems = 0,
  });

  /// How each kind is named to a person. The panel and [describe] read the
  /// same map, so a row's label and its sentence can never disagree.
  static const Map<String, String> _kindLabels = {
    'sync_mail': 'Mail sync',
    'sync_teams': 'Teams sync',
    'triage': 'Triage',
    'extract': 'Extract',
    'draft': 'Draft',
    'mark_read': 'Mark read',
    'storyline': 'Storylines',
    'storyline_sweep': 'Storyline sweep',
    'storyline_recruit': 'Storyline recruit',
    'embed_fail': 'Embeddings',
  };

  /// The machine-readable reasons the pipeline records, in the words the user
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
      case 'mark_read':
        final count = e.count ?? 0;
        return count == 1
            ? '$label — 1 message'
            : '$label — $count messages';
      case 'storyline':
        return 'Storylines updated';
      case 'storyline_sweep':
        final proposed = detail['proposed'];
        final confirmed = detail['confirmed'];
        final rejected = detail['rejected'];
        if (proposed is! num) return label;
        // The tallies the confirm stage added, when the row carries them. Rows
        // written before it existed have only `proposed`, and they still read
        // as the sentence they were written as.
        if (confirmed is! num || rejected is! num) {
          return '$label — ${proposed.toInt()} proposed';
        }
        return '$label — ${proposed.toInt()} proposed, '
            '${confirmed.toInt()} ${confirmed == 1 ? 'thread' : 'threads'} '
            'confirmed, ${rejected.toInt()} rejected';
      case 'storyline_recruit':
        final recruited = detail['recruited'];
        final considered = detail['considered'];
        return recruited is num && considered is num
            ? 'Recruited ${recruited.toInt()} of ${considered.toInt()} '
                'candidate threads'
            : label;
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

  /// How fast the model generated, in tokens per second, or null when this
  /// event cannot say.
  ///
  /// COMPLETION tokens over model time, not total tokens over wall time: the
  /// prompt is processed at a wholly different rate from the answer, and wall
  /// time includes the store writes around the call. This is the number that
  /// moves when a different model is loaded or the machine is thermally
  /// throttled, which is the only reason to show it.
  static double? speedOf(Map<String, Object?> detail) {
    final tokens = detail['completion_tokens'];
    final ms = detail['llm_ms'];
    if (tokens is! num || ms is! num) return null;
    if (tokens <= 0 || ms <= 0) return null;
    return tokens / (ms / 1000);
  }

  /// Tokens per second at the precision the number deserves: a decimal below
  /// ten, where the difference between 5.5 and 6 is the difference between
  /// usable and not, and none above it, where it is noise in a column.
  static String formatSpeed(double tps) {
    final value = tps >= 10 ? tps.toStringAsFixed(0) : tps.toStringAsFixed(1);
    return '$value t/s';
  }

  @override
  State<ActivityLogPanel> createState() => _ActivityLogPanelState();
}

class _ActivityLogPanelState extends State<ActivityLogPanel> {
  /// The event ids whose detail block is open. Ids rather than indices, so a
  /// tick that prepends a new row does not slide an expansion onto its
  /// neighbour.
  final Set<int> _expanded = {};

  /// The column grid, shared by the header and every row — the whole reason
  /// this reads as a table and not as a list. The status dot has no header of
  /// its own; its width is reserved above so Type starts in the same place.
  static const double _statusWidth = 20;
  static const double _typeWidth = 56;
  static const double _speedWidth = 64;
  static const double _whenWidth = 76;
  static const double _tookWidth = 64;

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    return ListView(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      children: [
        _tiles(),
        // Only when there is something to say — a "0 items given up on" line
        // is an alarm about the absence of a problem.
        if (widget.deadItems > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: BondSpacing.s8),
            child: Text(
              widget.deadItems == 1
                  ? '1 item given up on'
                  : '${widget.deadItems} items given up on',
              style: BondType.caption,
            ),
          ),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(BondSpacing.s32),
            child: Text(
              'Nothing recorded yet.',
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          )
        else ...[
          _columnHeader(),
          for (final (dayKey, rows) in _grouped()) ...[
            _dayHeader(dayKey),
            for (final event in rows) _entry(event),
          ],
        ],
      ],
    );
  }

  /// The headline numbers. A [Wrap] rather than a Row: the tiles do not fit
  /// the narrow layout's main pane, and a tile that has wrapped still reads
  /// correctly while a squeezed one does not.
  ///
  /// The counts describe the window the caller aggregated over; the three
  /// "last" tiles describe right now. Together they answer the two different
  /// questions people arrive with — "is it working?" and "is it working
  /// *currently*?" — which no single number can.
  ///
  /// The "last" tiles carry wall-clock stamps, not relative ages, and the
  /// reason is what keeps them honest: the panel's clock only ticks while
  /// syncs keep running, so a relative "just now" freezes at "just now" in
  /// exactly the failure it exists to expose. "8:13 PM" an hour later
  /// convicts itself.
  Widget _tiles() {
    final stats = widget.stats;
    final avg = stats.avgMsByKind;
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
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
          _tile(_genSpeed(), 'Gen speed'),
          _tile(_stamp(widget.lastMailSyncIso), 'Last sync'),
          // Only when Teams has actually run: a permanent dash beside a live
          // mail tile reads as a broken connector rather than an absent one.
          if (widget.lastTeamsSyncIso != null)
            _tile(_stamp(widget.lastTeamsSyncIso), 'Last teams sync'),
          _tile(_stamp(widget.lastSweepIso), 'Last sweep'),
        ],
      ),
    );
  }

  static String _avg(int? ms) =>
      ms == null ? '—' : ActivityLogPanel.formatDuration(ms);

  static String _stamp(String? iso) => formatTimestamp(iso) ?? '—';

  /// Generation speed across the whole window, weighted by time rather than
  /// averaged per row: a hundred one-token retries and one long answer are not
  /// two data points of equal worth. Summing both sides and dividing once gives
  /// the rate the machine actually sustained.
  String _genSpeed() {
    var tokens = 0.0;
    var ms = 0.0;
    for (final event in widget.events) {
      final eventTokens = event.detail['completion_tokens'];
      final eventMs = event.detail['llm_ms'];
      if (eventTokens is! num || eventMs is! num) continue;
      if (eventTokens <= 0 || eventMs <= 0) continue;
      tokens += eventTokens.toDouble();
      ms += eventMs.toDouble();
    }
    if (ms <= 0) return '—';
    return ActivityLogPanel.formatSpeed(tokens * 1000 / ms);
  }

  // The home metrics bar's tile, which is the same tile: two rows of numbers
  // that look alike ARE one widget, so a change to the chrome cannot land on
  // one screen and miss the other. The method stays as the local name every
  // call site above already uses.
  Widget _tile(String value, String label, {Color? valueColor}) {
    return BondStatTile(value: value, label: label, valueColor: valueColor);
  }

  /// The events by local calendar day, newest day first, each day's rows in
  /// the order they were handed over.
  List<(String, List<ActivityEvent>)> _grouped() {
    final days = <String, List<ActivityEvent>>{};
    for (final event in widget.events) {
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

  /// Names the columns once, above every day. Built from the same widths as
  /// the rows rather than through a shared layout widget, because the header is
  /// the one place where a wrong grid is visible immediately.
  Widget _columnHeader() {
    Widget cell(String text, double width, {TextAlign? align}) => SizedBox(
          width: width,
          child: Text(text, style: BondType.label, textAlign: align),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s4,
        BondSpacing.s8,
        BondSpacing.s4,
        0,
      ),
      child: Row(
        children: [
          const SizedBox(width: _statusWidth),
          const SizedBox(width: BondSpacing.s8),
          cell('Type', _typeWidth),
          const SizedBox(width: BondSpacing.s8),
          Expanded(child: Text('Activity', style: BondType.label)),
          const SizedBox(width: BondSpacing.s8),
          cell('t/s', _speedWidth, align: TextAlign.right),
          const SizedBox(width: BondSpacing.s8),
          cell('When', _whenWidth, align: TextAlign.right),
          const SizedBox(width: BondSpacing.s8),
          cell('Took', _tookWidth, align: TextAlign.right),
        ],
      ),
    );
  }

  /// One event's row, plus its detail block when that row is open.
  Widget _entry(ActivityEvent event) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(event),
        if (_expanded.contains(event.id)) _detail(event),
      ],
    );
  }

  /// One event: what it was, what happened, how fast the model ran, when, and
  /// how long it took.
  ///
  /// One line, always, at the price of eliding the sentence — the tap that
  /// opens [_detail] is what gets the whole of it back. Every card affordance
  /// the old rows had is gone: at this density a border per row is a grid of
  /// boxes rather than a table, so a single hairline underneath carries the
  /// separation instead.
  Widget _row(ActivityEvent event) {
    final durationMs = event.durationMs;
    final speed = ActivityLogPanel.speedOf(event.detail);
    final mono = BondType.mono.copyWith(
      fontSize: 12,
      height: 16 / 12,
      color: BondColors.inkSecondary,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() {
          if (!_expanded.remove(event.id)) _expanded.add(event.id);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s4,
            vertical: BondSpacing.s4,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: BondColors.border)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: _statusWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _dot(event.status),
                ),
              ),
              const SizedBox(width: BondSpacing.s8),
              SizedBox(
                width: _typeWidth,
                child: Text(
                  _sourceLabel(event.source),
                  style: BondType.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: BondSpacing.s8),
              Expanded(
                child: Text(
                  ActivityLogPanel.describe(event),
                  style: BondType.small.copyWith(color: BondColors.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: BondSpacing.s8),
              SizedBox(
                width: _speedWidth,
                child: speed == null
                    ? const SizedBox.shrink()
                    : Text(
                        ActivityLogPanel.formatSpeed(speed),
                        style: mono,
                        textAlign: TextAlign.right,
                      ),
              ),
              const SizedBox(width: BondSpacing.s8),
              SizedBox(
                width: _whenWidth,
                child: Text(
                  relativeTime(event.createdAt, widget.now) ?? '',
                  style: BondType.caption,
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: BondSpacing.s8),
              SizedBox(
                width: _tookWidth,
                child: Text(
                  durationMs == null
                      ? ''
                      : ActivityLogPanel.formatDuration(durationMs),
                  style: mono,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Which connector the event came from. `App` rather than a blank for the
  /// passes that belong to no source — a blank cell in a table reads as
  /// missing data, and "the app did this by itself" is not missing.
  static String _sourceLabel(String? source) => switch (source) {
        'email' => 'Mail',
        'teams' => 'Teams',
        _ => 'App',
      };

  /// Everything the row had to leave out, in place.
  ///
  /// Inline rather than a dialog on purpose: a person reading this table is
  /// comparing rows, and a modal takes the comparison away to show one of
  /// them. The raw detail map is rendered whole and unfiltered — this is the
  /// bottom of the panel, and a key nobody has taught it to name is exactly
  /// what someone digging is here for.
  Widget _detail(ActivityEvent event) {
    final label = widget.entityLabel?.call(event);
    final entityId = event.entityId;
    final speed = ActivityLogPanel.speedOf(event.detail);
    final keys = event.detail.keys.toList()..sort();
    final mono = BondType.mono.copyWith(
      fontSize: 12,
      height: 16 / 12,
      color: BondColors.inkSecondary,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: BondSpacing.s4),
      padding: const EdgeInsets.all(BondSpacing.s12),
      decoration: const BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(ActivityLogPanel.describe(event), style: BondType.small),
          if (label != null && label.isNotEmpty)
            Text(
              label,
              style: BondType.small.copyWith(fontWeight: FontWeight.w600),
            ),
          if (entityId != null && entityId.isNotEmpty)
            Text(entityId, style: mono),
          for (final key in keys)
            Text('$key: ${_value(event.detail[key])}', style: mono),
          if (speed != null)
            Text('speed: ${ActivityLogPanel.formatSpeed(speed)}', style: mono),
        ],
      ),
    );
  }

  /// A detail value as one line. Lists are joined rather than shown as their
  /// Dart literal: `[dinner plans, invoice]` is a topic list a person can read,
  /// and the brackets are the only part of it that came from the language.
  static String _value(Object? value) =>
      value is List ? value.join(', ') : '$value';

  /// The status, as the smallest mark that can carry it.
  ///
  /// A park and a retry share the attention colour on purpose: both mean the
  /// work is still owed, and neither is something the user did wrong. Only
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
