import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/calendar_models.dart';
import '../services/calendar/calendar_writes.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/event_standing.dart';
import '../services/calendar/write_rules.dart';
import '../theme/tokens.dart';
import 'calendar_write_flow.dart' show WriteStarter;

/// The writes one event offers, by the owner's role in it
/// (`write_rules.dart`): an attendee answers Yes / Maybe / No, adds a note
/// and proposes a new time — and, while the invite is still unanswered,
/// Dismisses it: a decline that tells the organiser nothing; an organiser
/// with guests moves and cancels; an event of the owner's own moves and
/// deletes.
///
/// Prop-only. The only state is which field is open and what is typed in it;
/// every write goes through [start], which the host's [CalendarWriteFlow]
/// owns, so the dry run, the confirm and the toast are the same wherever
/// these buttons are drawn.
///
/// **Which event.** [target] is what the host LOOKED UP and [shown] the
/// occurrence on display. They differ for a series: an answer or a cancel
/// goes to [target], the master, and so to every meeting in the series (the
/// summary says so); a move or a proposal acts on [shown] alone, because
/// moving a whole series is recurrence editing, which this does not do.
///
/// **No pickers.** A new time is typed — "Thu 3pm", "tomorrow 10–10:30" —
/// and read by the date resolver, with the absolute result shown under the
/// field before anything is sent. Escape in an open field closes it and goes
/// no further, so it never reaches the screen's Escape that closes the panel.
class EventActions extends StatefulWidget {
  const EventActions({
    super.key,
    required this.target,
    required this.shown,
    required this.zone,
    required this.clock,
    required this.today,
    required this.start,
    this.busy = false,
    this.compact = false,
    this.respondId,
  });

  static const Key yesKey = ValueKey('event-actions-yes');
  static const Key maybeKey = ValueKey('event-actions-maybe');
  static const Key noKey = ValueKey('event-actions-no');
  static const Key dismissKey = ValueKey('event-actions-dismiss');
  static const Key addNoteKey = ValueKey('event-actions-add-note');
  static const Key noteFieldKey = ValueKey('event-actions-note');
  static const Key proposeKey = ValueKey('event-actions-propose');
  static const Key proposeMaybeKey = ValueKey('event-actions-propose-maybe');
  static const Key proposeNoKey = ValueKey('event-actions-propose-no');
  static const Key removeKey = ValueKey('event-actions-remove');
  static const Key moveKey = ValueKey('event-actions-move');
  static const Key moveGoKey = ValueKey('event-actions-move-go');
  static const Key cancelKey = ValueKey('event-actions-cancel');
  static const Key cancelNoteKey = ValueKey('event-actions-cancel-note');
  static const Key cancelGoKey = ValueKey('event-actions-cancel-go');
  static const Key deleteKey = ValueKey('event-actions-delete');
  static const Key whenFieldKey = ValueKey('event-actions-when');
  static const Key whenPreviewKey = ValueKey('event-actions-when-preview');

  final CalendarEvent target;
  final CalendarEvent shown;
  final CalendarZone zone;

  /// Read each time a typed time is resolved, never captured: the panel can
  /// stand open for an hour, and "3pm" resolved against the instant it was
  /// drawn would let a time that has since passed through as the future.
  final DateTime Function() clock;
  final CalendarDate today;
  final WriteStarter start;
  final bool busy;

  /// The meeting card, an invite row and an agenda row: Yes / Maybe / No
  /// (and Dismiss while unanswered) only, and nothing
  /// at all for any other role.
  final bool compact;

  /// The id an RSVP answers when it is not [target]'s: an invite row folded
  /// from a series answers the series' master, whose own row the mirror
  /// usually does not hold. A different id from [target]'s reads as a
  /// series-wide answer in the summary.
  final String? respondId;

  @override
  State<EventActions> createState() => _EventActionsState();
}

enum _Open { none, note, propose, move, cancel }

class _EventActionsState extends State<EventActions> {
  final TextEditingController _note = TextEditingController();
  final TextEditingController _when = TextEditingController();
  _Open _open = _Open.none;

  @override
  void dispose() {
    _note.dispose();
    _when.dispose();
    super.dispose();
  }

  CalendarEvent get _target => widget.target;
  CalendarEvent get _shown => widget.shown;

  String get _respondId => widget.respondId ?? _target.id;

  bool get _series => _target.isSeriesMaster || _respondId != _target.id;

  void _toggle(_Open which) => setState(() {
        final opening = _open != which;
        // A new-time field starts empty each time, so a half-typed move is
        // never sent as a proposal. The note survives: it rides whichever
        // answer is pressed next.
        if (which == _Open.propose || which == _Open.move) _when.clear();
        if (opening && which == _Open.cancel) _note.clear();
        _open = opening ? which : _Open.none;
      });

  /// Closes the open field and drops what was typed in it: Escape's job
  /// inside a field, which the key then stops at.
  void _close() => setState(() {
        if (_open == _Open.propose || _open == _Open.move) _when.clear();
        if (_open == _Open.note || _open == _Open.cancel) _note.clear();
        _open = _Open.none;
      });

  void _go(CalendarWrite w) {
    if (widget.busy) return;
    // Only a write aimed at the master reaches the whole series; a proposal
    // and a move act on the occurrence on display.
    final series = _series &&
        ((w is RespondToEvent && !w.proposes) ||
            w is CancelMeeting ||
            w is DeleteEvent);
    widget.start(
      w,
      summary: writeSummary(w,
          shown: _shown,
          series: series,
          zone: widget.zone,
          today: widget.today),
      doneMessage: writeDoneMessage(w,
          shown: _shown, series: series, zone: widget.zone),
      // The event the write is aimed at: the organiser an answer goes to,
      // the guests a cancel reaches.
      mayEmail: mayEmailFor(w, event: widget.target),
    );
  }

  String? get _comment {
    final t = _note.text.trim();
    return t.isEmpty ? null : t;
  }

  NewTime get _newTime => resolveNewTime(_when.text,
      shown: _shown, now: widget.clock(), zone: widget.zone);

  void _respond(RsvpResponse r) =>
      _go(RespondToEvent(_respondId, r, comment: _comment));

  void _propose(RsvpResponse r) {
    final t = _newTime;
    if (t is! NewTimeTimed) return;
    _go(RespondToEvent(_shown.id, r,
        comment: _comment, proposeStartUtc: t.startUtc, proposeEndUtc: t.endUtc));
  }

  void _move() {
    switch (_newTime) {
      case NewTimeTimed(:final startUtc, :final endUtc):
        _go(MoveEvent.timed(_shown.id, startUtc: startUtc, endUtc: endUtc));
      case NewTimeAllDay(:final startDate, :final endDate):
        _go(MoveEvent.allDay(_shown.id, startDate: startDate, endDate: endDate));
      case NewTimeProblem():
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = eventRoleOf(_target);
    final rows = <Widget>[];
    if (canRespond(_target)) {
      rows.add(_rsvpRow());
      if (!widget.compact) rows.addAll(_attendeeExtras());
    } else if (!widget.compact) {
      if (role == EventRole.attendee && _target.isCancelled) {
        rows.add(_buttons([
          OutlinedButton(
            key: EventActions.removeKey,
            onPressed: widget.busy
                ? null
                : () => _go(DeleteEvent(_target.id)),
            child: const Text('Remove from calendar'),
          ),
        ]));
      } else if (role == EventRole.organiserWithGuests) {
        rows.addAll(_organiserRows());
      } else if (role == EventRole.ownEvent) {
        rows.addAll(_ownRows());
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Widget _buttons(List<Widget> children) => Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );

  Widget _rsvpRow() {
    // The chosen button follows what the owner ANSWERED, not the standing:
    // an accepted meeting the calendar shows tentative is still a Yes.
    final answered = answerOf(_target);
    Widget answer(Key key, String label, RsvpResponse r, EventAnswer current) {
      if (answered == current) {
        // Already the answer: shown as chosen, and not pressable twice.
        return FilledButton.tonal(key: key, onPressed: null, child: Text(label));
      }
      return OutlinedButton(
        key: key,
        onPressed: widget.busy ? null : () => _respond(r),
        child: Text(label),
      );
    }

    return _buttons([
      answer(EventActions.yesKey, 'Yes', RsvpResponse.accept,
          EventAnswer.accepted),
      answer(EventActions.maybeKey, 'Maybe', RsvpResponse.tentative,
          EventAnswer.tentative),
      answer(EventActions.noKey, 'No', RsvpResponse.decline,
          EventAnswer.declined),
      // The quiet decline: never with the typed note, which only a sent
      // answer can carry.
      if (_target.needsResponse)
        OutlinedButton(
          key: EventActions.dismissKey,
          onPressed: widget.busy
              ? null
              : () => _go(RespondToEvent(_respondId, RsvpResponse.decline,
                  sendResponse: false)),
          child: const Text('Dismiss'),
        ),
    ]);
  }

  List<Widget> _attendeeExtras() {
    final proposable = canPropose(_shown);
    final proposed = _open == _Open.propose ? _newTime : null;
    return [
      _buttons([
        TextButton(
          key: EventActions.addNoteKey,
          onPressed: widget.busy ? null : () => _toggle(_Open.note),
          child: const Text('Add note'),
        ),
        if (proposable)
          TextButton(
            key: EventActions.proposeKey,
            onPressed: widget.busy ? null : () => _toggle(_Open.propose),
            child: const Text('Propose new time'),
          ),
      ]),
      // The note stays typed when the field closes, and rides whichever
      // answer or proposal is sent next; the summary says "with your note".
      if (_open == _Open.note)
        _noteField(EventActions.noteFieldKey, 'A note to the organiser'),
      if (_open == _Open.propose && proposable) ...[
        _whenField(onSubmitted: () => _propose(RsvpResponse.tentative)),
        const SizedBox(height: BondSpacing.s4),
        _buttons([
          OutlinedButton(
            key: EventActions.proposeMaybeKey,
            onPressed: widget.busy || proposed is! NewTimeTimed
                ? null
                : () => _propose(RsvpResponse.tentative),
            child: const Text('Send as Maybe'),
          ),
          OutlinedButton(
            key: EventActions.proposeNoKey,
            onPressed: widget.busy || proposed is! NewTimeTimed
                ? null
                : () => _propose(RsvpResponse.decline),
            child: const Text('Send as No'),
          ),
        ]),
      ],
    ];
  }

  List<Widget> _moveRows() {
    if (_open != _Open.move) return const [];
    final resolved = _newTime is! NewTimeProblem;
    return [
      _whenField(onSubmitted: _move),
      const SizedBox(height: BondSpacing.s4),
      _buttons([
        FilledButton(
          key: EventActions.moveGoKey,
          onPressed: widget.busy || !resolved ? null : _move,
          child: const Text('Move'),
        ),
      ]),
    ];
  }

  List<Widget> _organiserRows() {
    return [
      _buttons([
        if (canMove(_shown))
          OutlinedButton(
            key: EventActions.moveKey,
            onPressed: widget.busy ? null : () => _toggle(_Open.move),
            child: const Text('Move to…'),
          ),
        if (!_target.isCancelled)
          OutlinedButton(
            key: EventActions.cancelKey,
            onPressed: widget.busy ? null : () => _toggle(_Open.cancel),
            child: const Text('Cancel meeting'),
          ),
      ]),
      ..._moveRows(),
      if (_open == _Open.cancel) ...[
        _noteField(EventActions.cancelNoteKey, 'A note to everyone (optional)'),
        const SizedBox(height: BondSpacing.s4),
        _buttons([
          FilledButton(
            key: EventActions.cancelGoKey,
            style: FilledButton.styleFrom(backgroundColor: BondColors.error),
            onPressed: widget.busy
                ? null
                : () => _go(CancelMeeting(_target.id, comment: _comment)),
            child: const Text('Cancel meeting…'),
          ),
        ]),
      ],
    ];
  }

  List<Widget> _ownRows() {
    return [
      _buttons([
        if (canMove(_shown))
          OutlinedButton(
            key: EventActions.moveKey,
            onPressed: widget.busy ? null : () => _toggle(_Open.move),
            child: const Text('Move to…'),
          ),
        OutlinedButton(
          key: EventActions.deleteKey,
          onPressed: widget.busy ? null : () => _go(DeleteEvent(_target.id)),
          child: const Text('Delete'),
        ),
      ]),
      ..._moveRows(),
    ];
  }

  /// [field] with Escape bound to [_close]. Bound here, the nearest handler
  /// to the focused field, so the key is consumed before the screen's own
  /// Escape sees it.
  Widget _escapable(Widget field) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: field,
      );

  Widget _noteField(Key key, String hint) => Padding(
        padding: const EdgeInsets.only(top: BondSpacing.s4),
        child: _escapable(TextField(
          key: key,
          controller: _note,
          enabled: !widget.busy,
          autofocus: true,
          maxLines: 1,
          style: BondType.small,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        )),
      );

  Widget _whenField({required VoidCallback onSubmitted}) {
    final text = _when.text.trim();
    final t = text.isEmpty ? null : _newTime;
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _escapable(TextField(
            key: EventActions.whenFieldKey,
            controller: _when,
            enabled: !widget.busy,
            autofocus: true,
            maxLines: 1,
            style: BondType.small,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'e.g. Thu 3pm, tomorrow 10–10:30',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_newTime is! NewTimeProblem) onSubmitted();
            },
          )),
          if (t != null)
            Padding(
              padding: const EdgeInsets.only(top: BondSpacing.s4),
              child: Text(
                newTimeLabel(t, zone: widget.zone),
                key: EventActions.whenPreviewKey,
                style: t is NewTimeProblem
                    ? BondType.caption.copyWith(color: BondColors.inkMuted)
                    : BondType.small.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
