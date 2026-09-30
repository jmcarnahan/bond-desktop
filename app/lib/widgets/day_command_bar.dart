import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/calendar/calendar_zone.dart';
import '../services/calendar/command/command_types.dart';
import '../services/calendar/day_items.dart'
    show formatEventRange, formatEventTime, shortDate;
import '../services/calendar/when_resolver.dart';
import '../services/calendar/write_rules.dart'
    show bareHourAfterTo, moveShiftOf;
import '../theme/tokens.dart';
import 'chips.dart';

/// The Day stop's command bar: one line of text that asks the calendar
/// something or tells it to do something (docs/pipeline/14-calendar.md
/// "Commands").
///
/// Prop-only apart from the text: the host binds the clock, the zone, the
/// people and the meetings into [DayCommandBar.preview] and
/// [DayCommandBar.submit], and owns whatever Enter produced — the plan card
/// is drawn by the pane under this bar, not by the bar, so a rebuild of the
/// bar can never lose a proposal that is waiting on a press.
///
/// **The live preview.** A synchronous parse, debounced 150 ms, read back as
/// chips: what it will do, when (absolute, on the display zone's clock, so
/// "tomorrow" says which tomorrow), who, which meeting, how long. No model
/// and no network run per keystroke; the chips are what the rules already
/// understood, so a missing chip is the person's cue to say it plainer
/// before pressing Enter rather than after.
///
/// **A move's two times.** For a move the when chip is where the meeting
/// GOES (the words after the split, a shift like "1 h later" included),
/// tinted when it cannot be read yet, and the time it is at now rides on the
/// event chip ("Design sync · 3:00 PM").
///
/// **Keys.** Enter submits; Escape clears the text and the preview and tells
/// the host to drop its plan — and only then: with an empty field and no
/// plan standing it is left for the screen. While [busy] Enter does nothing,
/// so a second Enter cannot send a second command under the first. Editing
/// the text away from what was submitted drops the plan too ([onCleared]),
/// so a card never stands under words that did not make it. The field is an
/// `EditableText`, so the screen's single-letter shortcuts stay out of it.
class DayCommandBar extends StatefulWidget {
  const DayCommandBar({
    super.key,
    required this.preview,
    required this.submit,
    required this.zone,
    required this.clock,
    this.initialText,
    this.onCleared,
    this.busy = false,
    this.planStands = false,
  });

  static const String hint =
      'Ask or tell: move my 3pm with Dana to tomorrow morning';

  static const Key fieldKey = ValueKey('day-command-field');
  static const Key previewKey = ValueKey('day-command-preview');
  static const Key clearKey = ValueKey('day-command-clear');
  static const Key busyKey = ValueKey('day-command-busy');

  /// One preview chip: `action`, `when`, `people`, `event`, `duration`.
  static Key chipKeyFor(String kind) => ValueKey('day-command-chip-$kind');

  /// How long the text must sit still before the preview reads it.
  static const Duration debounce = Duration(milliseconds: 150);

  /// The synchronous parse; the host binds now, the zone, the people and the
  /// meetings.
  final ParsedCommand Function(String text) preview;

  /// Enter. The host runs the router and owns the plan it returns.
  final Future<void> Function(String text) submit;

  final CalendarZone zone;

  /// Anchors a time with no day ("at 3") to today for its chip.
  final DateTime Function() clock;

  /// Text handed over from elsewhere (⌘K's "Ask Day" row): written into the
  /// field and submitted once, one frame after it arrives. Read when the bar
  /// mounts and whenever it changes to a new non-null value, so the host
  /// clears it once it has been submitted and the same words can be handed
  /// over again.
  final String? initialText;

  /// Escape and the ✕: the host drops the plan the text produced.
  final VoidCallback? onCleared;

  /// A submitted command is still being read.
  final bool busy;

  /// The host is drawing a plan for the submitted text: Escape has that to
  /// drop even with the field empty.
  final bool planStands;

  @override
  State<DayCommandBar> createState() => _DayCommandBarState();
}

class _DayCommandBarState extends State<DayCommandBar> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'day-command');
  Timer? _debounce;
  ParsedCommand? _parsed;

  /// The text last submitted, while the host may be drawing a plan for it.
  String? _submitted;

  @override
  void initState() {
    super.initState();
    _handOver(widget.initialText);
  }

  @override
  void didUpdateWidget(DayCommandBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.initialText;
    if (text != null && text != oldWidget.initialText) _handOver(text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// [text] into the field with its preview at once — nobody is typing, so
  /// there is nothing to wait out — and submitted a frame later, once the
  /// host that handed it over has finished the build that did so.
  void _handOver(String? text) {
    if (text == null || text.trim().isEmpty) return;
    _debounce?.cancel();
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _parsed = widget.preview(text);
    _submitted = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      if (_parsed != null) setState(() {});
      unawaited(widget.submit(text));
    });
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final submitted = _submitted;
    if (submitted != null && text != submitted) {
      // The words moved on: the plan they made no longer describes them.
      _submitted = null;
      widget.onCleared?.call();
    }
    if (text.trim().isEmpty) {
      if (_parsed != null) setState(() => _parsed = null);
      return;
    }
    _debounce = Timer(DayCommandBar.debounce, () {
      // The text may have moved on inside the wait; read what is there now.
      if (!mounted || _text.text != text) return;
      setState(() => _parsed = widget.preview(text));
    });
  }

  void _onSubmitted(String text) {
    // Read when the key lands, not when this frame was built.
    if (widget.busy || text.trim().isEmpty) return;
    _debounce?.cancel();
    _submitted = text;
    setState(() => _parsed = widget.preview(text));
    unawaited(widget.submit(text));
  }

  void _clear() {
    _debounce?.cancel();
    _submitted = null;
    _text.clear();
    setState(() => _parsed = null);
    widget.onCleared?.call();
  }

  /// Escape, consumed only when there is something here to clear.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_text.text.isEmpty && !widget.planStands) {
      return KeyEventResult.ignored;
    }
    _clear();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final chips = parsed == null || _text.text.trim().isEmpty
        ? const <Widget>[]
        : _chips(parsed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: TextField(
            key: DayCommandBar.fieldKey,
            controller: _text,
            focusNode: _focus,
            style: BondType.small,
            textInputAction: TextInputAction.done,
            onChanged: _onChanged,
            onSubmitted: _onSubmitted,
            // Enter keeps the cursor here: the answer lands under the bar,
            // and a follow-up is typed over the same line.
            onEditingComplete: () {},
            decoration: InputDecoration(
              isDense: true,
              hintText: DayCommandBar.hint,
              hintStyle: BondType.small.copyWith(color: BondColors.inkMuted),
              prefixIcon: const Icon(Icons.auto_awesome_outlined, size: 16),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              border: OutlineInputBorder(borderRadius: BondRadii.smAll),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: BondSpacing.s8,
                vertical: BondSpacing.s8,
              ),
              suffixIcon: _suffix(),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s4),
          Wrap(
            key: DayCommandBar.previewKey,
            spacing: BondSpacing.s4,
            runSpacing: BondSpacing.s4,
            children: chips,
          ),
        ],
      ],
    );
  }

  Widget? _suffix() {
    if (widget.busy) {
      return const Padding(
        padding: EdgeInsets.all(BondSpacing.s8),
        child: SizedBox(
          key: DayCommandBar.busyKey,
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // Only once there is something to clear, the Find box's rule.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _text,
      builder: (context, value, _) => value.text.isEmpty
          ? const SizedBox.shrink()
          : IconButton(
              key: DayCommandBar.clearKey,
              icon: const Icon(Icons.close, size: 14),
              tooltip: 'Clear',
              visualDensity: VisualDensity.compact,
              onPressed: _clear,
            ),
    );
  }

  List<Widget> _chips(ParsedCommand p) {
    Widget chip(String kind, String label, {bool unsure = false}) => BondChip(
          key: DayCommandBar.chipKeyFor(kind),
          tone: unsure ? BondTone.attention : BondTone.neutral,
          label: label,
        );
    final action = commandActionLabel(p.action);
    final move = p.action == CommandAction.move;
    final target = move
        ? moveTargetChip(p, zone: widget.zone, clock: widget.clock)
        : null;
    final when = move
        ? target!.label
        : whenChipLabel(p.when, zone: widget.zone, clock: widget.clock);
    final whenUnsure =
        move ? target!.unsure : p.when.unresolvedReason != null;
    final people = peopleChipLabel(p.people);
    var event = eventChipLabel(p.events);
    // A move's source time rides on its meeting.
    if (move && event != null && !event.endsWith(' matches')) {
      final e = p.events.first.event;
      final s = e.startUtc;
      if (e.isTimed && s != null) {
        event = '$event · ${formatEventTime(widget.zone, s)}';
      }
    }
    // A shift is not a length: "by an hour" keeps the meeting's.
    final duration =
        move && target!.shift ? null : p.duration ?? p.when.duration;
    return [
      if (action != null) chip('action', action),
      if (when != null) chip('when', when, unsure: whenUnsure),
      if (people != null)
        chip('people', people,
            unsure: p.people.ambiguous.isNotEmpty ||
                p.people.unresolved.isNotEmpty),
      if (event != null)
        chip('event', event, unsure: event.endsWith(' matches')),
      if (duration != null) chip('duration', durationLabel(duration)),
    ];
  }
}

/// The action as a person would say it, or null for `unknown` — no chip is
/// better than a chip saying "unknown".
String? commandActionLabel(CommandAction a) => switch (a) {
      CommandAction.create => 'Create',
      CommandAction.move => 'Move',
      CommandAction.cancel => 'Cancel',
      CommandAction.rsvpYes => 'Yes',
      CommandAction.rsvpNo => 'No',
      CommandAction.rsvpMaybe => 'Maybe',
      CommandAction.findTime => 'Find a time',
      CommandAction.askFree => 'Am I free',
      CommandAction.askAgenda => 'Agenda',
      CommandAction.askPerson => 'Meetings with',
      CommandAction.unknown => null,
    };

/// The when, absolute on [zone]'s clock: "Thu Oct 1 · 3:00 PM", "Thu Oct 1
/// morning", "Thu Oct 1 – Fri Oct 2", "3:00 PM" for a time with no day. The
/// resolver's reason when a day phrase could not be resolved. Null when the
/// text named no day, time or part.
String? whenChipLabel(
  WhenResolution w, {
  required CalendarZone zone,
  required DateTime Function() clock,
}) {
  final reason = w.unresolvedReason;
  if (reason != null) return reason;
  final day = w.day;
  final time = w.time;
  final part = w.part;
  if (day != null && w.rangeEnd != null && w.rangeEnd != day) {
    return '${shortDate(day)} – ${shortDate(w.rangeEnd!)}';
  }
  if (time != null) {
    final on = day ?? zone.dateOf(clock().toUtc());
    final start = _utc(zone.localDateTime(on, time.$1, time.$2));
    final end = w.endTime;
    final clockText = end == null
        ? formatEventTime(zone, start)
        : formatEventRange(
            zone,
            start,
            _utc(zone.localDateTime(
                // A range past midnight ends the next day.
                (end.$1 * 60 + end.$2) <= (time.$1 * 60 + time.$2)
                    ? on.addDays(1)
                    : on,
                end.$1,
                end.$2)));
    return day == null ? clockText : '${shortDate(day)} · $clockText';
  }
  if (day != null) {
    return part == null ? shortDate(day) : '${shortDate(day)} ${partLabel(part)}';
  }
  if (part != null) return partLabel(part);
  return null;
}

/// A move's when chip: where the meeting GOES, from the words after the
/// split ([ParsedCommand.targetText]) — never the whole text, whose times
/// include the one it is at now. A shift reads "1 h later" / "30 min
/// earlier". [unsure] when the destination cannot be read yet: nothing
/// said, a bare hour ("to 4"), or the resolver's own reason; then the label
/// is "to when?" if nothing better can be said.
({String label, bool unsure, bool shift}) moveTargetChip(
  ParsedCommand p, {
  required CalendarZone zone,
  required DateTime Function() clock,
}) {
  final text = p.targetText;
  final now = clock().toUtc();
  final shift = moveShiftOf(text, now: now, zone: zone);
  if (shift != null) {
    final label = shift.isNegative
        ? '${durationLabel(-shift)} earlier'
        : '${durationLabel(shift)} later';
    return (label: label, unsure: false, shift: true);
  }
  final r = text.trim().isEmpty
      ? WhenResolution(today: p.when.today, zone: zone)
      : resolveWhen(text, now: now, zone: zone, mode: WhenMode.booking);
  final label = whenChipLabel(r, zone: zone, clock: clock);
  final placed = r.day != null || r.time != null || r.part != null;
  final unsure = !placed || r.unresolvedReason != null || bareHourAfterTo(text);
  return (label: label ?? 'to when?', unsure: unsure, shift: false);
}

/// "morning", "end of day".
String partLabel(DayPart p) => switch (p) {
      DayPart.morning => 'morning',
      DayPart.afternoon => 'afternoon',
      DayPart.evening => 'evening',
      DayPart.endOfDay => 'end of day',
      DayPart.lunch => 'lunch',
    };

/// Everyone named: matched names, "Dana? (2)" for a name two people share,
/// "Sam?" for a name nobody in the mail has. Null when nobody was named.
String? peopleChipLabel(PeopleMatch m) {
  if (m.isEmpty) return null;
  final parts = <String>[
    for (final k in m.matched) k.name.trim().isEmpty ? k.address : k.name.trim(),
    for (final list in m.ambiguous)
      if (list.isNotEmpty)
        '${list.first.firstName.isEmpty ? list.first.address : list.first.firstName}'
            '? (${list.length})',
    for (final name in m.unresolved) '$name?',
  ];
  return parts.join(', ');
}

/// The meeting the command means: its subject, or "N matches" when several
/// tie at the top score. Null when none matched.
String? eventChipLabel(List<EventCandidate> events) {
  if (events.isEmpty) return null;
  final top = events.first.score;
  final tied = events.where((c) => c.score == top).length;
  if (tied > 1) return '$tied matches';
  final subject = events.first.event.subject.trim();
  return subject.isEmpty ? '(no subject)' : subject;
}

/// "30 min", "1 h", "1 h 30 min".
String durationLabel(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes - h * 60;
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}

DateTime _utc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

