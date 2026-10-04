import '../../models/calendar_models.dart';
import 'calendar_writes.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange, shortDate;
import 'event_view.dart' show eventWhenLine, isOwnersEvent;
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
  if (!isOwnersEvent(e)) return EventRole.attendee;
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

// ── a move by a duration ───────────────────────────────────────────────

/// The words that make a length a SHIFT, and which way: "back 30 min" is
/// earlier, "by an hour" (no direction said) is later.
const Map<String, int> _shiftWords = {
  'by': 1,
  'forward': 1,
  'later': 1,
  'ahead': 1,
  'out': 1,
  'back': -1,
  'backward': -1,
  'backwards': -1,
  'earlier': -1,
};

final RegExp _shiftWord = RegExp(
    r'\b(by|forward|later|ahead|out|back|backwards?|earlier)\b',
    caseSensitive: false);

/// How far a move's target words SHIFT the meeting — "by an hour", "back
/// 30 min", "an hour later", "earlier by 15 minutes" — or null when they
/// are not a shift.
///
/// Only a target that names no day, time or part of day can be a shift:
/// "to 4pm for an hour" is a new time with a new length, and the length is
/// [resolveNewTime]'s. The shift is the LAST thing in the words, so "push
/// the standup back 30 min" reads the same as "push my 3pm back 30 min".
/// A shift keeps the meeting's length, always; a length said with no
/// direction word at all ("move my 3pm an hour") is not a shift and not a
/// time, and the planner asks when it moves to instead of stretching it.
Duration? moveShiftOf(
  String target, {
  required DateTime now,
  required CalendarZone zone,
}) {
  final t = target.trim().replaceFirst(RegExp(r'[.!?]+$'), '').trim();
  if (t.isEmpty) return null;
  final r = resolveWhen(t, now: now, zone: zone, mode: WhenMode.booking);
  if (r.day != null || r.time != null || r.part != null) return null;
  if (r.unresolvedReason != null) return null;

  // "<direction> [by] <length>" at the end.
  for (final m in _shiftWord.allMatches(t)) {
    var rest = t.substring(m.end).trim();
    final sign = _shiftWords[m.group(1)!.toLowerCase()]!;
    rest = rest.replaceFirst(RegExp(r'^by\s+', caseSensitive: false), '');
    final d = wholeDuration(rest);
    if (d != null) return sign < 0 ? -d : d;
  }
  // "[by] <length> <direction>" at the end.
  final tail = RegExp(
          r'\s(later|earlier|forward|back|backwards?|ahead|out)$',
          caseSensitive: false)
      .firstMatch(t);
  if (tail != null) {
    final before = t.substring(0, tail.start);
    final sign = _shiftWords[tail.group(1)!.toLowerCase()]!;
    // The longest length that ends where the direction word begins.
    for (final w in RegExp(r'(?:^|\s)(?=\S)').allMatches(before)) {
      var rest = before.substring(w.end);
      rest = rest.replaceFirst(RegExp(r'^by\s+', caseSensitive: false), '');
      final d = wholeDuration(rest);
      if (d != null) return sign < 0 ? -d : d;
    }
  }
  return null;
}

/// A move's target that gives a bare hour after "to" — "move my 3pm to 4" —
/// with no am, pm or minutes. Daytime-first would read it as 4 PM, and a
/// write that emails people is not the place for a guess.
bool bareHourAfterTo(String target) {
  for (final m in RegExp(
          r'\bto\s+(\d{1,2})(?![\d:./])(?!\s*(?:a\.?m\b|p\.?m\b|am|pm|a\b|p\b|'
          r"o['’]?\s*clock|h\b|hrs?\b|hours?\b|m\b|mins?\b|minutes?\b))",
          caseSensitive: false)
      .allMatches(target)) {
    final n = int.parse(m.group(1)!);
    if (n >= 1 && n <= 12) return true;
  }
  return false;
}

/// [shown] moved by [by], start AND end, so its length stays what it was.
/// An all-day event moves by whole days only.
NewTime shiftedTime(
  CalendarEvent shown,
  Duration by, {
  required DateTime now,
}) {
  if (shown.isAllDay) {
    return const NewTimeProblem(
        'Name a day — an all-day event moves by whole days.');
  }
  final s = shown.startUtc;
  final e = shown.endUtc;
  if (s == null || e == null) {
    return const NewTimeProblem("This event's times couldn't be read.");
  }
  final start = s.add(by);
  final end = e.add(by);
  if (start.isBefore(now.toUtc())) {
    return const NewTimeProblem('That time has passed.');
  }
  return NewTimeTimed(start, end);
}

/// A drop on the grid read as a new time for [shown]: the typed move's own
/// refusals, in the typed move's own words, so a drag cannot send what the
/// "Move to…" field would have refused.
///
/// The grid has already snapped the instants, so there is nothing to
/// resolve — only to check: the same times, a start in the past, an end not
/// after the start.
NewTime checkDrop({
  required CalendarEvent shown,
  required DateTime startUtc,
  required DateTime endUtc,
  required DateTime now,
}) {
  // Plain UTC stamps, compared as instants: a zoned stamp (the grid's
  // package hands back `TZDateTime`s) is never `==` to a plain one.
  DateTime utc(DateTime t) =>
      DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);
  final start = utc(startUtc);
  final end = utc(endUtc);
  final s = shown.startUtc;
  final e = shown.endUtc;
  if (s != null &&
      e != null &&
      start.isAtSameMomentAs(s) &&
      end.isAtSameMomentAs(e)) {
    return const NewTimeProblem("That's when it already is.");
  }
  if (start.isBefore(now.toUtc())) {
    return const NewTimeProblem('That time has passed.');
  }
  if (!end.isAfter(start)) {
    return const NewTimeProblem('A meeting needs to end after it starts.');
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
    case RespondToEvent() when w.quiet:
      const tail = ' — declines without telling the organiser';
      return series
          ? 'Dismiss every meeting in $subject$tail'
          : '${one('Dismiss')}$tail';
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
    case RespondToEvent() when w.quiet:
      return 'Dismissed $what — nobody was told.';
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
///
/// [mayEmail] is who the write would reach when the dry run listed nobody
/// ([mayEmailFor]): an RSVP, a cancel, a delete and a create with guests
/// confirm anyway (`needsConfirm`), and a strip that confirms while saying
/// nothing about mail would read as a write that sends none. Said as "This
/// may email:", because it is the app's reading of the event, not the
/// server's list.
String? emailedLine(
  List<String> notifies, {
  List<String> mayEmail = const [],
}) {
  final (list, verb) = notifies.isNotEmpty
      ? (notifies, 'This emails')
      : (mayEmail, 'This may email');
  if (list.isEmpty) return null;
  final shown = list.take(5).join(', ');
  final more = list.length - 5;
  return more > 0 ? '$verb: $shown and $more more' : '$verb: $shown';
}

/// What rides the done toast: " Emails go to a@x.", " Emails go to 3
/// people.", or ''. Worded as where the mail goes rather than as mail sent:
/// the list is the dry run's (or [mayEmail], as [emailedLine] reads it), a
/// preview, and the server sends — or does not — after the app has let go.
String emailedSuffix(
  List<String> notifies, {
  List<String> mayEmail = const [],
}) {
  final list = notifies.isNotEmpty ? notifies : mayEmail;
  if (list.isEmpty) return '';
  if (list.length == 1) return ' Emails go to ${list.single}.';
  return ' Emails go to ${list.length} people.';
}

/// Who [w] reaches by mail as the app reads [event] (the event written to)
/// — the fallback [emailedLine] and [emailedSuffix] use when a write that
/// confirms anyway came back from its dry run naming nobody:
///
/// - an answer (and a proposal) goes to the organiser; a Dismiss to nobody;
/// - a create goes to the people on it;
/// - a cancel or a delete goes to the event's guests: not rooms, not the
///   organiser's own address (the [eventRoleOf] rule);
/// - a move lists nobody here: it confirms only on the dry run's own list.
///
/// Lowercased and deduplicated, in the order given.
List<String> mayEmailFor(CalendarWrite w, {CalendarEvent? event}) {
  final out = <String>{};
  void add(String address) {
    final a = address.trim().toLowerCase();
    if (a.isNotEmpty) out.add(a);
  }

  switch (w) {
    case RespondToEvent():
      if (w.sendResponse) add(event?.organizerAddress ?? '');
    case CreateEvent():
      w.attendees.forEach(add);
    case CancelMeeting():
    case DeleteEvent():
      final e = event;
      if (e == null) break;
      final self = e.organizerAddress.trim().toLowerCase();
      for (final a in e.attendees) {
        if (a.type.trim().toLowerCase() == 'resource') continue;
        if (a.address.trim().toLowerCase() == self) continue;
        add(a.address);
      }
    case MoveEvent():
      break;
  }
  return out.toList();
}

/// The confirm button: it names a destructive write, and a Dismiss, rather
/// than "Send" — a Dismiss sends nothing.
String confirmLabelFor(CalendarWrite w) => switch (w) {
      RespondToEvent(quiet: true) => 'Dismiss',
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
