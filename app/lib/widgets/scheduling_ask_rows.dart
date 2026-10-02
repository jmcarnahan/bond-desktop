import 'package:flutter/material.dart';

import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart'
    show formatEventRange, overlapLine, shortDate;
import '../services/calendar/find_time.dart';
import '../services/calendar/overlaps.dart' show FreeSlot;
import '../theme/tokens.dart';
import 'command_plan_card.dart' show CommandPlanCard;

/// One scheduling ask, by its thread: the connector and the conversation key.
typedef AskKey = ({String source, String key});

/// What the Day column draws for one thread asking for a time
/// (docs/pipeline/14-calendar.md "Find a time"). The inbox owns the search
/// and hands the rail one of these per ask, so the row is a function of it.
@immutable
class SchedulingAskRow {
  final String source;
  final String key;
  final String subject;

  /// Who asked: the newest inbound sender's name, else their address.
  final String askedBy;

  /// Open under its head, with the pills and the slots. One at a time.
  final bool expanded;

  /// A search is out.
  final bool busy;

  /// An invite for this ask went out this session.
  final bool invited;
  final int minutes;
  final FindTimeWindow window;

  /// The last search's answer, kept while the row is folded so opening it
  /// again shows it at once. Null until the first search lands.
  final FindTimeResult? result;

  const SchedulingAskRow({
    required this.source,
    required this.key,
    required this.subject,
    required this.askedBy,
    this.expanded = false,
    this.busy = false,
    this.invited = false,
    this.minutes = 30,
    this.window = FindTimeWindow.thisWeek,
    this.result,
  });
}

/// The six things a row can ask of its host, each by the ask's thread.
class SchedulingAskCallbacks {
  final void Function(String source, String key) onToggle;
  final void Function(String source, String key, int minutes) onMinutes;
  final void Function(String source, String key, FindTimeWindow window)
      onWindow;
  final void Function(String source, String key, FreeSlot slot) onPickSlot;
  final void Function(String source, String key) onPutInReply;
  final void Function(String source, String key) onOpen;

  const SchedulingAskCallbacks({
    required this.onToggle,
    required this.onMinutes,
    required this.onWindow,
    required this.onPickSlot,
    required this.onPutInReply,
    required this.onOpen,
  });
}

/// One ask in the 260 px Day column, in the rail's dark ink.
///
/// Folded it is two lines, the subject over who asked, and a tap opens it.
/// Open it adds how long and which week as pills (a change searches again),
/// then up to three slots, each one tap target: the date and times over who
/// can make it, or over the owner's own clash when the mirror knows one.
/// Picking a slot is the host's: it shows that day with the proposal on it.
///
/// Every line is one line and ellipsizes; nothing here is wider than the
/// column's 236 px of content.
class SchedulingAskTile extends StatelessWidget {
  const SchedulingAskTile({
    super.key,
    required this.row,
    required this.zone,
    required this.callbacks,
  });

  final SchedulingAskRow row;
  final CalendarZone zone;
  final SchedulingAskCallbacks callbacks;

  static Key rowKeyFor(String source, String key) =>
      ValueKey('ask-row-$source|$key');
  static Key minutesKeyFor(String source, String key, int minutes) =>
      ValueKey('ask-minutes-$source|$key-$minutes');
  static Key windowKeyFor(String source, String key, FindTimeWindow w) =>
      ValueKey('ask-window-$source|$key-${w.name}');
  static Key slotKeyFor(String source, String key, int i) =>
      ValueKey('ask-slot-$source|$key-$i');
  static Key putInReplyKeyFor(String source, String key) =>
      ValueKey('ask-put-in-reply-$source|$key');
  static Key openKeyFor(String source, String key) =>
      ValueKey('ask-open-$source|$key');
  static Key invitedKeyFor(String source, String key) =>
      ValueKey('ask-invited-$source|$key');

  /// The lengths offered, in minutes — the pane's three.
  static const List<int> durations = [30, 45, 60];

  static final TextStyle _caption =
      BondType.caption.copyWith(color: BondColors.onDarkMuted);

  @override
  Widget build(BuildContext context) {
    final s = row.source;
    final k = row.key;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: row.expanded ? BondColors.onDarkFaint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _head(s, k),
            if (row.expanded)
              Padding(
                padding: const EdgeInsets.only(
                  left: BondSpacing.s8 + BondSpacing.s8,
                  right: BondSpacing.s8,
                  bottom: BondSpacing.s8,
                ),
                child: _body(s, k),
              ),
          ],
        ),
      ),
    );
  }

  Widget _head(String s, String k) {
    return InkWell(
      key: rowKeyFor(s, k),
      onTap: () => callbacks.onToggle(s, k),
      borderRadius: BondRadii.smAll,
      hoverColor: BondColors.onDarkFaint,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s8,
          vertical: BondSpacing.s4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.subject,
              style: BondType.small.copyWith(
                color: row.expanded
                    ? BondColors.onDarkPrimary
                    : BondColors.onDarkSecondary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (row.invited)
              Text(
                'Invite sent',
                key: invitedKeyFor(s, k),
                style: BondType.caption.copyWith(color: BondColors.railAccent),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (row.askedBy.isNotEmpty)
              Text(
                row.askedBy,
                style: _caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(String s, String k) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bare numbers: three "30 min" pills do not fit the column, and the
        // leading word says what they count.
        Wrap(
          spacing: BondSpacing.s4,
          runSpacing: BondSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('min', style: _caption),
            for (final m in durations)
              _Pill(
                key: minutesKeyFor(s, k, m),
                label: '$m',
                selected: m == row.minutes,
                onTap: () => callbacks.onMinutes(s, k, m),
              ),
          ],
        ),
        const SizedBox(height: BondSpacing.s4),
        Wrap(
          spacing: BondSpacing.s4,
          runSpacing: BondSpacing.s4,
          children: [
            for (final w in FindTimeWindow.values)
              _Pill(
                key: windowKeyFor(s, k, w),
                label: w.label,
                selected: w == row.window,
                onTap: () => callbacks.onWindow(s, k, w),
              ),
          ],
        ),
        const SizedBox(height: BondSpacing.s8),
        ..._results(s, k),
      ],
    );
  }

  List<Widget> _results(String s, String k) {
    final result = row.result;
    if (row.busy) return [Text('Finding…', style: _caption)];
    if (result == null) return const [];
    if (result.slots.isEmpty) {
      final other = row.window == FindTimeWindow.thisWeek
          ? FindTimeWindow.nextWeek
          : FindTimeWindow.thisWeek;
      return [
        Text(
          result.note ??
              'No free time found ${row.window.label.toLowerCase()} — '
                  'try ${other.label.toLowerCase()}.',
          style: _caption,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        _actions(s, k, slots: false),
      ];
    }
    final slots = result.slots.take(3).toList();
    final note = (result.note ?? '').trim();
    return [
      // Slots with a note are slots with a caveat: the owner's own calendar
      // only, say, when the account cannot look others up.
      if (note.isNotEmpty)
        Text(
          note,
          style: _caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      for (var i = 0; i < slots.length; i++) _slot(s, k, i, slots[i], result),
      _actions(s, k, slots: true),
      Text(
        result.source == 'graph'
            ? CommandPlanCard.graphCaption
            : CommandPlanCard.localCaption,
        style: _caption,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ];
  }

  /// One slot: the date and times, then the owner's own clash when the
  /// mirror has one (it outranks the head count, which came from Graph's
  /// view of the same calendar), else who is free.
  Widget _slot(String s, String k, int i, FreeSlot slot, FindTimeResult r) {
    final o = r.overlaps[slot];
    final clash = o != null && o.hard.isNotEmpty ? overlapLine(o) : null;
    return InkWell(
      key: slotKeyFor(s, k, i),
      onTap: () => callbacks.onPickSlot(s, k, slot),
      borderRadius: BondRadii.smAll,
      hoverColor: BondColors.onDarkFaint,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${shortDate(zone.dateOf(slot.startUtc))} · '
              '${formatEventRange(zone, slot.startUtc, slot.endUtc)}',
              style: BondType.small.copyWith(color: BondColors.onDarkPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              clash ?? r.availability[slot]?.caption ?? 'your free time',
              style: clash != null
                  ? BondType.caption.copyWith(color: BondColors.railAccent)
                  : _caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(String s, String k, {required bool slots}) {
    return Wrap(
      spacing: BondSpacing.s12,
      children: [
        if (slots)
          _TextAction(
            key: putInReplyKeyFor(s, k),
            label: 'Put in reply',
            onTap: () => callbacks.onPutInReply(s, k),
          ),
        _TextAction(
          key: openKeyFor(s, k),
          label: 'Open thread',
          onTap: () => callbacks.onOpen(s, k),
        ),
      ],
    );
  }
}

/// A small choice pill in the rail's ink: filled when it is the one chosen.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? BondColors.onDarkTint : BondColors.rail,
      borderRadius: BondRadii.fullAll,
      child: InkWell(
        // The chosen one takes no tap: pressing it would only search again
        // for what is already showing.
        onTap: selected ? null : onTap,
        borderRadius: BondRadii.fullAll,
        hoverColor: BondColors.onDarkFaint,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: 2,
          ),
          child: Text(
            label,
            style: BondType.caption.copyWith(
              color: selected
                  ? BondColors.onDarkPrimary
                  : BondColors.onDarkSecondary,
            ),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

/// Put in reply and Open thread: words, not buttons, in the rail's accent.
class _TextAction extends StatelessWidget {
  const _TextAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BondRadii.smAll,
      hoverColor: BondColors.onDarkFaint,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
        child: Text(
          label,
          style: BondType.caption.copyWith(
            color: BondColors.railAccent,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}
