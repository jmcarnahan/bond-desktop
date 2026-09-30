import '../../models/calendar_models.dart';
import 'calendar_writes.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange, shortDate;
import 'event_view.dart' show eventWhenLine;
import 'when_resolver.dart';

/// Which calendar writes an event offers, how a typed new time becomes one,
/// and every sentence a write shows — its confirm line, its toast, who it
/// emails.
///
/// Pure, as `event_view.dart` is: the widgets draw what this answers, so the
/// role rules and the sentences are tested with a clock and a zone and no
/// widget at all.

// ── roles ──────────────────────────────────────────────────────────────

/// Where the owner stands on an event, which is what decides the writes it
/// offers: an attendee answers, an organiser moves and cancels, and an event
/// of the owner's own moves and deletes.
enum EventRole { attendee, organiserWithGuests, ownEvent }

/// [e]'s role for the owner.
///
/// Whose event it is decides first, and an empty attendee list never does: an
/// organiser who hides the attendee list sends invites whose copy lists
/// nobody, and reading those as the owner's own would offer Move and Delete on
/// somebody else's meeting instead of an answer. Graph marks the owner's own
/// events `isOrganizer` (response `organizer`), so either says it.
///
/// On the organiser's side, guests are the people: a room is booked, not
/// invited, so a meeting with only a room is the owner's own — moved or
/// deleted, where "Cancel meeting" would read as cancelling on someone. The
/// dry run still names every address a write emails, a room included, and
/// the confirm follows that list rather than this role.
EventRole eventRoleOf(CalendarEvent e) {
  final organiser = e.isOrganizer || e.responseStatus == 'organizer';
  if (!organiser) return EventRole.attendee;
  final self = e.organizerAddress.trim().toLowerCase();
  final guests = e.attendees.any((a) =>
      a.type.trim().toLowerCase() != 'resource' &&
      a.address.trim().toLowerCase() != self);
  return guests ? EventRole.organiserWithGuests : EventRole.ownEvent;
}

/// Whether "Move to…" belongs on [shown]: not an attendee's (only the
/// organiser may move a meeting, gotcha 6), not cancelled, and not a series
/// master — moving a whole series is recurrence editing, which this round
/// does not do; the occurrence on display moves instead.
bool canMove(CalendarEvent shown) =>
    eventRoleOf(shown) != EventRole.attendee &&
    !shown.isCancelled &&
    !shown.isSeriesMaster;

/// Whether "Propose new time" belongs on [shown]: an attendee's live, timed
/// occurrence whose organiser has not forbidden proposals (only an explicit
/// false forbids). An all-day proposal is not offered: Outlook proposes
/// instants, and a whole day as an instant is the conversion D13 bans.
bool canPropose(CalendarEvent shown) =>
    eventRoleOf(shown) == EventRole.attendee &&
    !shown.isCancelled &&
    !shown.isSeriesMaster &&
    shown.allowNewTimeProposals != false &&
    shown.isTimed;

/// Whether Yes / Maybe / No belong on [target]: an attendee's live meeting.
bool canRespond(CalendarEvent target) =>
    eventRoleOf(target) == EventRole.attendee && !target.isCancelled;

// ── the new time ───────────────────────────────────────────────────────

/// What a typed new time resolved to.
sealed class NewTime {
  const NewTime();
}

final class NewTimeTimed extends NewTime {
  const NewTimeTimed(this.startUtc, this.endUtc);

  final DateTime startUtc;
  final DateTime endUtc;
}

final class NewTimeAllDay extends NewTime {
  const NewTimeAllDay(this.startDate, this.endDate);

  final CalendarDate startDate;

  /// Exclusive.
  final CalendarDate endDate;
}

final class NewTimeProblem extends NewTime {
  const NewTimeProblem(this.reason);

  /// A sentence for the person, saying what to type instead.
  final String reason;
}

/// [text] read as a new time for [shown], in booking mode.
///
/// Whatever the text leaves out is kept from the meeting, never invented: a
/// day alone keeps the meeting's wall time, a time alone keeps its day, and
/// no length keeps its length. A part of the day with no time ("tomorrow
/// morning") is a Problem rather than a guess at an hour. An all-day event
/// moves by whole days and keeps its span.
NewTime resolveNewTime(
  String text, {
  required CalendarEvent shown,
  required DateTime now,
  required CalendarZone zone,
}) {
  final r = resolveWhen(text, now: now, zone: zone, mode: WhenMode.booking);
  if (r.isEmpty) {
    return const NewTimeProblem("Type a day or a time — e.g. 'Thu 3pm'.");
  }
  final unresolved = r.unresolvedReason;
  if (unresolved != null) return NewTimeProblem(unresolved);
  if (r.rangeEnd != null) return const NewTimeProblem('Name one day, not a week.');

  if (shown.isAllDay) {
    const wholeDays =
        NewTimeProblem('Name a day — an all-day event moves by whole days.');
    final day = r.day;
    if (day == null || r.time != null) return wholeDays;
    final start = shown.startDate;
    if (start == null) return wholeDays;
    final end = shown.endDate;
    var span = end == null
        ? 1
        : DateTime.utc(end.year, end.month, end.day)
            .difference(DateTime.utc(start.year, start.month, start.day))
            .inDays;
    if (span < 1) span = 1;
    if (day.isBefore(r.today)) return const NewTimeProblem('That day has passed.');
    if (day == start) {
      return const NewTimeProblem("That's when it already is.");
    }
    return NewTimeAllDay(day, day.addDays(span));
  }

  final s = shown.startUtc;
  final e = shown.endUtc;
  if (s == null || e == null) {
    return const NewTimeProblem("This event's times couldn't be read.");
  }
  // An instant duration: a ninety-minute meeting is ninety real minutes,
  // across a DST change included.
  final length = e.difference(s);
  final day = r.day ?? zone.dateOf(s);
  var time = r.time;
  if (time == null) {
    if (r.part != null) {
      return const NewTimeProblem("Add a time — e.g. 'tomorrow 10am'.");
    }
    final local = zone.toLocal(s);
    time = (local.hour, local.minute);
  }
  final window = WhenResolution(
    today: r.today,
    zone: zone,
    day: day,
    time: time,
    endTime: r.endTime,
    duration: r.duration ?? length,
    explicitTime: true,
  ).windowUtc!;
  final (start, end) = window;
  if (start.isBefore(now.toUtc())) {
    return const NewTimeProblem('That time has passed.');
  }
  if (start == s && end == e) {
    return const NewTimeProblem("That's when it already is.");
  }
  return NewTimeTimed(start, end);
}

/// "Thu Oct 8 · 3:00–4:00 PM", "Fri Oct 9 · All day", "Fri Oct 9 – Sat Oct 10
/// · All day" — or the problem's own sentence.
String newTimeLabel(NewTime t, {required CalendarZone zone}) => switch (t) {
      NewTimeTimed(:final startUtc, :final endUtc) =>
        '${shortDate(zone.dateOf(startUtc))} · '
            '${formatEventRange(zone, startUtc, endUtc)}',
      NewTimeAllDay(:final startDate, :final endDate) =>
        endDate.isAfter(startDate.addDays(1))
            ? '${shortDate(startDate)} – ${shortDate(endDate.addDays(-1))} '
                '· All day'
            : '${shortDate(startDate)} · All day',
      NewTimeProblem(:final reason) => reason,
    };

/// The label of the times [w] moves to or creates at.
String _targetLabel(MoveEvent w, CalendarZone zone) => w.isAllDay
    ? newTimeLabel(NewTimeAllDay(w.startDate!, w.endDate!), zone: zone)
    : newTimeLabel(NewTimeTimed(w.startUtc!, w.endUtc!), zone: zone);

// ── sentences ──────────────────────────────────────────────────────────

String _quoted(String subject) {
  final s = subject.trim();
  return '"${s.isEmpty ? '(no subject)' : s}"';
}

/// The confirm strip's line, imperative: what pressing Send will do.
///
/// [series] says the write answers every meeting in a series (the target is
/// its master), and the line says so, because "Accept" on one weekly
/// meeting's card that quietly accepts all seventeen is the surprise D5
/// exists to prevent.
String writeSummary(
  CalendarWrite w, {
  required CalendarEvent shown,
  required bool series,
  required CalendarZone zone,
  required CalendarDate today,
}) {
  final subject = _quoted(shown.subject);
  final when = eventWhenLine(shown, zone: zone, today: today);
  String one(String verb) =>
      when.isEmpty ? '$verb $subject' : '$verb $subject · $when';
  switch (w) {
    case RespondToEvent():
      final verb = switch (w.response) {
        RsvpResponse.accept => 'Accept',
        RsvpResponse.tentative => 'Maybe',
        RsvpResponse.decline => 'Decline',
      };
      var line = series ? '$verb every meeting in $subject' : one(verb);
      if (w.proposes) {
        final label = newTimeLabel(
            NewTimeTimed(w.proposeStartUtc!, w.proposeEndUtc!),
            zone: zone);
        line = '$line, proposing $label';
      }
      if ((w.comment ?? '').trim().isNotEmpty) line = '$line with your note';
      return line;
    case MoveEvent():
      return 'Move $subject to ${_targetLabel(w, zone)}';
    case CancelMeeting():
      return series ? 'Cancel every meeting in $subject' : one('Cancel');
    case DeleteEvent():
      return series ? 'Delete every meeting in $subject' : one('Delete');
    case CreateEvent():
      return 'Create ${_quoted(w.subject)} · '
          '${newTimeLabel(NewTimeTimed(w.startUtc, w.endUtc), zone: zone)}';
  }
}

/// The toast after a write went through, past tense.
///
/// [series] is [writeSummary]'s flag, read the same way, so the toast after
/// a series-wide answer, cancel or delete says every meeting as the confirm
/// did. A proposal and a move act on one occurrence and ignore it.
String writeDoneMessage(
  CalendarWrite w, {
  required CalendarEvent? shown,
  required bool series,
  required CalendarZone zone,
}) {
  final subject = _quoted(shown?.subject ?? '');
  final what = series ? 'every meeting in $subject' : subject;
  switch (w) {
    case RespondToEvent():
      if (w.proposes) return 'Proposed a new time for $subject.';
      return switch (w.response) {
        RsvpResponse.accept => 'Accepted $what.',
        RsvpResponse.tentative => 'Said maybe to $what.',
        RsvpResponse.decline => 'Declined $what.',
      };
    case MoveEvent():
      return 'Moved $subject to ${_targetLabel(w, zone)}.';
    case CancelMeeting():
      return 'Cancelled $what.';
    case DeleteEvent():
      return 'Deleted $what.';
    case CreateEvent():
      return 'Created ${_quoted(w.subject)}.';
  }
}

/// "This emails: a@x, b@y" — five addresses, then "and N more" — or null
/// when the write emails nobody.
String? emailedLine(List<String> notifies) {
  if (notifies.isEmpty) return null;
  final shown = notifies.take(5).join(', ');
  final more = notifies.length - 5;
  return more > 0 ? 'This emails: $shown and $more more' : 'This emails: $shown';
}

/// What rides the done toast: " Emailed a@x.", " Emailed 3 people.", or ''.
String emailedSuffix(List<String> notifies) {
  if (notifies.isEmpty) return '';
  if (notifies.length == 1) return ' Emailed ${notifies.single}.';
  return ' Emailed ${notifies.length} people.';
}

/// The confirm button: it names a destructive write rather than "Send".
String confirmLabelFor(CalendarWrite w) => switch (w) {
      DeleteEvent() => 'Delete',
      CancelMeeting() => 'Cancel meeting',
      _ => 'Send',
    };

/// The dismiss button: beside "Cancel meeting", a second "Cancel" would read
/// as the same press, so a destructive write's dismiss says "Keep it".
String dismissLabelFor(CalendarWrite w) => switch (w) {
      DeleteEvent() || CancelMeeting() => 'Keep it',
      _ => 'Cancel',
    };
