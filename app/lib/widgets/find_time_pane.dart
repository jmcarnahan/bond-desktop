import 'dart:async';

import 'package:flutter/material.dart';

import '../models/calendar_models.dart' show CalendarDate, CalendarEvent;
import '../services/calendar/calendar_writes.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart'
    show formatEventRange, overlapLine, shortDate;
import '../services/calendar/find_time.dart';
import '../services/calendar/overlaps.dart' show FreeSlot;
import '../services/calendar/write_rules.dart'
    show writeDoneMessage, writeSummary;
import '../theme/tokens.dart';
import 'calendar_write_flow.dart';
import 'chips.dart' show BondFilterPill;
import 'command_plan_card.dart' show CommandPlanCard;
import 'pane_surface.dart';

export '../services/calendar/find_time.dart' show FindTimeResult, FindTimeWindow;

/// One person the search asks about: the thread's other participants, each
/// with an address.
typedef FindTimePerson = ({String name, String address});

/// The search the host runs for the pane — see `searchFindTime`.
typedef FindTimeSearch = Future<FindTimeResult> Function({
  required List<String> addresses,
  required int durationMinutes,
  required FindTimeWindow window,
});

/// Find a time, for a thread asking for one (docs/pipeline/14-calendar.md
/// "Find a time"): who, how long, which week, then up to three real free
/// slots with two things to do with them.
///
/// **Put these in the reply** writes ONE line naming every slot shown, with
/// the zone, into the thread's reply box — the other person picks, so they
/// are offered all three. **Send invite** books one slot for everyone
/// through [CalendarWriteFlow], the state machine every calendar write
/// shares, so an invite that emails people waits on the same inline confirm
/// strip naming them; a slot with nobody else on it goes straight on and
/// offers the Undo.
///
/// Prop-only: [search] is the host's (everyone's calendars, or the owner's
/// own mirror), and so is what a finished write and a filled reply do. A
/// pane in the main column with Back and Inbox, never a dialog.
///
/// **Searching.** Once as it opens and again on every change of people,
/// length or week, 200 ms after the last one; one search in flight at a
/// time, and an answer that a newer change overtook is thrown away.
class FindTimePane extends StatefulWidget {
  const FindTimePane({
    super.key,
    required this.subject,
    required this.participants,
    required this.zone,
    required this.today,
    required this.search,
    required this.onPutInReply,
    required this.writer,
    required this.onDone,
    required this.onBack,
    required this.onHome,
  });

  /// The thread's subject; the invite is "Re: " it.
  final String? subject;

  /// The thread's other participants with an address, owner excluded.
  final List<FindTimePerson> participants;
  final CalendarZone zone;
  final CalendarDate today;
  final FindTimeSearch search;

  /// Puts [text] in the thread's reply box.
  final void Function(String text) onPutInReply;
  final CalendarWriter writer;

  /// After an invite went through: the message for the toast, the undo
  /// when the write emailed nobody, and whether anybody was invited — false
  /// when the slot went on the owner's calendar alone (Add to calendar).
  final void Function(String message, CalendarWrite? undo, bool invited)
      onDone;
  final VoidCallback onBack;
  final VoidCallback? onHome;

  static const Key backKey = ValueKey('find-time-back');
  static const Key putAllKey = ValueKey('find-time-put-all');
  static const Key emptyKey = ValueKey('find-time-empty');
  static const Key noteKey = ValueKey('find-time-note');
  static const Key lookingKey = ValueKey('find-time-looking');
  static const Key justYouKey = ValueKey('find-time-just-you');
  static const Key waitingKey = ValueKey('find-time-waiting');

  /// The durations offered, in minutes.
  static const List<int> durations = [30, 45, 60];

  static Key durationKeyFor(int minutes) =>
      ValueKey('find-time-duration-$minutes');
  static Key windowKeyFor(FindTimeWindow w) =>
      ValueKey('find-time-window-${w.name}');
  static Key personKeyFor(String address) =>
      ValueKey('find-time-person-$address');
  static Key removePersonKeyFor(String address) =>
      ValueKey('find-time-remove-$address');
  static Key slotKeyFor(int i) => ValueKey('find-time-slot-$i');
  static Key overlapKeyFor(int i) => ValueKey('find-time-overlap-$i');
  static Key inviteKeyFor(int i) => ValueKey('find-time-invite-$i');

  /// How long a change waits for the next one before searching.
  static const Duration debounce = Duration(milliseconds: 200);

  /// The pane before the display zone has resolved: no slots can be drawn
  /// without a clock, so it says what it is waiting for — never a blank
  /// column — and keeps Back and Inbox.
  static Widget waiting({
    required VoidCallback onBack,
    VoidCallback? onHome,
  }) =>
      PaneSurface(
        title: 'Find a time',
        backKey: backKey,
        onBack: onBack,
        onHome: onHome,
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s24),
          child: Text(
            'Reading your calendar…',
            key: waitingKey,
            style: BondType.small.copyWith(color: BondColors.inkMuted),
          ),
        ),
      );

  @override
  State<FindTimePane> createState() => _FindTimePaneState();
}

class _FindTimePaneState extends State<FindTimePane> {
  late List<FindTimePerson> _people = [...widget.participants];
  int _minutes = FindTimePane.durations.first;
  FindTimeWindow _window = FindTimeWindow.thisWeek;

  FindTimeResult? _result;
  bool _searching = true;
  bool _inFlight = false;

  /// A change landed while a search was out: its answer is stale, and the
  /// search runs again with what is on screen now.
  bool _again = false;
  Timer? _timer;

  /// Whether the write in flight invites anybody, fixed when it was started:
  /// the people row stays editable meanwhile.
  bool _invited = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      _searching = true;
    });
    _timer?.cancel();
    _timer = Timer(FindTimePane.debounce, () => unawaited(_run()));
  }

  Future<void> _run() async {
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    FindTimeResult result;
    try {
      result = await widget.search(
        addresses: [for (final p in _people) p.address],
        durationMinutes: _minutes,
        window: _window,
      );
    } on Object {
      result = const FindTimeResult(
          note: "Couldn't reach the calendar to find a time.");
    }
    _inFlight = false;
    if (!mounted) return;
    if (_again) {
      _again = false;
      unawaited(_run());
      return;
    }
    setState(() {
      _result = result;
      _searching = _timer?.isActive ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PaneSurface(
      title: 'Find a time',
      backKey: FindTimePane.backKey,
      onBack: widget.onBack,
      onHome: widget.onHome,
      child: ListView(
        padding: const EdgeInsets.all(BondSpacing.s24),
        children: [
          if ((widget.subject ?? '').trim().isNotEmpty) ...[
            Text(
              widget.subject!.trim(),
              style: BondType.small.copyWith(color: BondColors.inkSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          _label('With'),
          _peopleRow(),
          const SizedBox(height: BondSpacing.s12),
          _label('How long'),
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s8,
            children: [
              for (final m in FindTimePane.durations)
                BondFilterPill(
                  key: FindTimePane.durationKeyFor(m),
                  label: '$m min',
                  selected: m == _minutes,
                  onTap: () {
                    if (m != _minutes) _changed(() => _minutes = m);
                  },
                ),
            ],
          ),
          const SizedBox(height: BondSpacing.s12),
          _label('When'),
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s8,
            children: [
              for (final w in FindTimeWindow.values)
                BondFilterPill(
                  key: FindTimePane.windowKeyFor(w),
                  label: w.label,
                  selected: w == _window,
                  onTap: () {
                    if (w != _window) _changed(() => _window = w);
                  },
                ),
            ],
          ),
          const SizedBox(height: BondSpacing.s24),
          ..._results(),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s4),
        child: Text(
          text,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      );

  /// The people, each removable. With nobody left the search is the owner's
  /// own calendar, and the row says so.
  Widget _peopleRow() {
    if (_people.isEmpty) {
      return Text(
        'Just you — your own free times.',
        key: FindTimePane.justYouKey,
        style: BondType.small.copyWith(color: BondColors.inkSecondary),
      );
    }
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        for (final p in _people)
          Container(
            key: FindTimePane.personKeyFor(p.address),
            padding: const EdgeInsets.only(left: BondSpacing.s8),
            decoration: BoxDecoration(
              borderRadius: BondRadii.fullAll,
              border: Border.all(color: BondColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: p.address,
                  child: Text(
                    p.name.trim().isEmpty ? p.address : p.name.trim(),
                    style: BondType.small,
                  ),
                ),
                IconButton(
                  key: FindTimePane.removePersonKeyFor(p.address),
                  tooltip: 'Leave out',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _changed(() => _people = [
                        for (final q in _people)
                          if (q.address != p.address) q,
                      ]),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _results() {
    final result = _result;
    if (_searching || result == null) {
      return [
        Text(
          'Looking…',
          key: FindTimePane.lookingKey,
          style: BondType.small.copyWith(color: BondColors.inkMuted),
        ),
      ];
    }
    final note = result.note;
    final slots = result.slots.take(3).toList();
    final everyone = _people.isNotEmpty && result.source == 'graph';
    final other = _window == FindTimeWindow.thisWeek
        ? FindTimeWindow.nextWeek
        : FindTimeWindow.thisWeek;
    return [
      if (note != null) ...[
        Text(
          note,
          key: FindTimePane.noteKey,
          style: BondType.small.copyWith(color: BondColors.inkSecondary),
        ),
        const SizedBox(height: BondSpacing.s12),
      ],
      // Nothing found is an answer; a search that failed has already said
      // why in its note, and "nobody is free" would claim it had looked.
      if (slots.isEmpty && (note == null || note == findTimeLocalNote))
        Text(
          '${everyone ? 'No time when everyone is free' : 'No free time'} '
          '${_window.label.toLowerCase()}. '
          'Try ${other.label.toLowerCase()}.',
          key: FindTimePane.emptyKey,
          style: BondType.small.copyWith(color: BondColors.inkSecondary),
        ),
      if (slots.isNotEmpty) _slots(result, slots),
    ];
  }

  Widget _slots(FindTimeResult result, List<FreeSlot> slots) {
    final zone = widget.zone;
    final addresses = [for (final p in _people) p.address];
    return CalendarWriteFlow(
      writer: widget.writer,
      onDone: (message, undo) => widget.onDone(message, undo, _invited),
      builder: (context, start, busy) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: FindTimePane.putAllKey,
              onPressed: busy
                  ? null
                  : () => widget.onPutInReply(findTimeReplyLine(slots, zone)),
              icon: const Icon(Icons.reply_outlined, size: 16),
              label: const Text('Put these in the reply'),
            ),
          ),
          const SizedBox(height: BondSpacing.s12),
          for (var i = 0; i < slots.length; i++)
            _slotRow(i, slots[i], result, busy, () {
              final write = CreateEvent.propose(
                subject: findTimeSubject(widget.subject),
                startUtc: slots[i].startUtc,
                endUtc: slots[i].endUtc,
                attendees: addresses,
                isOnlineMeeting: addresses.isNotEmpty,
              );
              _invited = addresses.isNotEmpty;
              start(
                write,
                summary: writeSummary(write,
                    shown: const CalendarEvent(id: ''),
                    series: false,
                    zone: zone,
                    today: widget.today),
                doneMessage: writeDoneMessage(write,
                    shown: null, series: false, zone: zone),
              );
            }, invites: addresses.isNotEmpty),
          const SizedBox(height: BondSpacing.s4),
          Text(
            result.source == 'graph'
                ? CommandPlanCard.graphCaption
                : CommandPlanCard.localCaption,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
      ),
    );
  }

  Widget _slotRow(
    int i,
    FreeSlot slot,
    FindTimeResult result,
    bool busy,
    VoidCallback onInvite, {
    required bool invites,
  }) {
    final zone = widget.zone;
    final o = result.overlaps[slot];
    final overlap = o != null && o.hard.isNotEmpty ? overlapLine(o) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${shortDate(zone.dateOf(slot.startUtc))} · '
                  '${formatEventRange(zone, slot.startUtc, slot.endUtc)}',
                  key: FindTimePane.slotKeyFor(i),
                  style: BondType.small,
                ),
                if (overlap != null)
                  Text(
                    overlap,
                    key: FindTimePane.overlapKeyFor(i),
                    style:
                        BondType.caption.copyWith(color: BondColors.attention),
                  ),
              ],
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          OutlinedButton(
            key: FindTimePane.inviteKeyFor(i),
            onPressed: busy ? null : onInvite,
            child: Text(invites ? 'Send invite' : 'Add to calendar'),
          ),
        ],
      ),
    );
  }
}
