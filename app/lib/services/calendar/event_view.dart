import 'package:flutter/foundation.dart' show immutable;

import '../../models/calendar_models.dart';
import '../../models/message_models.dart' show Message;
import 'calendar_sync.dart' show CalendarAvailability;
import 'calendar_zone.dart';
import 'day_items.dart';

/// What the event panel, the meeting card and a person's room say about one
/// meeting: which occurrence of a series to show, who is coming, where the
/// owner stands, and when — every sentence, worked out where a test can hand
/// it a clock and a zone.
///
/// Pure on purpose, as `day_items.dart` is: the widgets draw what this
/// answers, and the providers only fetch what it reads. Every wall-clock
/// string goes through [CalendarZone] and the Day stop's own formatters, so
/// a meeting reads the same in the panel as in the row that opened it.

// ── resolving an id ────────────────────────────────────────────────────

/// How resolving one event id went.
enum EventLookupState {
  /// The event is here — from the mirror or from a live read.
  found,

  /// The server says it no longer exists: cancelled and deleted, or a series
  /// that was removed.
  gone,

  /// The calendar is not this session's to read: no scope, or SDK mode.
  blocked,

  /// Anything else — offline, a timeout, a server error. Worth trying again.
  unreachable,
}

/// What resolving one event id gave.
///
/// A value rather than a thrown error, because every one of the four answers
/// is something the panel draws: an invite whose meeting was deleted is
/// still an invite somebody is reading, and "this event no longer exists"
/// is the answer they came for.
@immutable
class EventLookup {
  final EventLookupState state;

  /// Set iff [state] is [EventLookupState.found].
  final CalendarEvent? event;

  /// A series master's occurrences out of the mirror, by start; empty for
  /// anything that is not a master. A master read live gets them too: the
  /// mirror comes from calendarView, which holds a series' occurrences but
  /// seldom the master row, so an invite naming the master is usually read
  /// live while its occurrences sit in the store.
  final List<CalendarEvent> occurrences;

  /// False when the event was fetched live because the mirror did not hold
  /// it. A live read is kept in memory only and never written to the store:
  /// a row written outside the sync carries no run tag and the next sweep
  /// would delete it.
  final bool fromMirror;

  /// The session's calendar availability when the lookup ran — what a
  /// blocked panel's sentence is chosen by.
  final CalendarAvailability availability;

  const EventLookup.found(
    CalendarEvent this.event, {
    this.occurrences = const [],
    this.fromMirror = true,
    this.availability = CalendarAvailability.available,
  }) : state = EventLookupState.found;

  const EventLookup.gone({
    this.availability = CalendarAvailability.available,
  })  : state = EventLookupState.gone,
        event = null,
        occurrences = const [],
        fromMirror = true;

  const EventLookup.blocked(this.availability)
      : state = EventLookupState.blocked,
        event = null,
        occurrences = const [],
        fromMirror = true;

  const EventLookup.unreachable({
    this.availability = CalendarAvailability.available,
  })  : state = EventLookupState.unreachable,
        event = null,
        occurrences = const [],
        fromMirror = true;

  bool get isFound => state == EventLookupState.found;
}

/// One conversation linked to an event: a thread holding its invite, an
/// update or a cancellation, or the Teams meeting chat.
@immutable
class EventLink {
  final String source;
  final String conversationKey;

  /// The Teams meeting chat, found through [CalendarEvent.teamsThreadId]
  /// rather than through a message that names the event.
  final bool isMeetingChat;

  /// The stored conversation's subject. The host may replace it with the
  /// name the list already calls the thread by.
  final String title;

  /// The first storyline the conversation belongs to, or null.
  final String? storylineId;

  /// That storyline's title, filled by the host, which holds the storylines.
  final String? storylineTitle;

  const EventLink({
    required this.source,
    required this.conversationKey,
    this.isMeetingChat = false,
    required this.title,
    this.storylineId,
    this.storylineTitle,
  });

  /// This link with the host's words in place of the stored ones; a null
  /// argument keeps what was there.
  EventLink withView({String? title, String? storylineTitle}) => EventLink(
        source: source,
        conversationKey: conversationKey,
        isMeetingChat: isMeetingChat,
        title: title ?? this.title,
        storylineId: storylineId,
        storylineTitle: storylineTitle ?? this.storylineTitle,
      );
}

/// A person's meetings either side of now: the next one with them and the
/// last one that ended. Either may be null; both null is nothing to say.
@immutable
class PersonMeetings {
  final CalendarEvent? next;
  final CalendarEvent? last;

  const PersonMeetings({this.next, this.last});

  bool get isEmpty => next == null && last == null;
}

// ── which occurrence ───────────────────────────────────────────────────

/// Whether [e] has not finished by [nowUtc]: a timed event whose end is
/// after it, an all-day event whose (exclusive) end date is after the day it
/// is in [zone].
bool _stillAhead(CalendarEvent e, DateTime nowUtc, CalendarZone zone) {
  if (e.isAllDay) {
    final start = e.startDate;
    if (start == null) return false;
    final end = e.endDate;
    final after = end != null && end.isAfter(start) ? end : start.addDays(1);
    return after.isAfter(zone.dateOf(nowUtc));
  }
  final end = e.endUtc;
  return end != null && end.isAfter(nowUtc);
}

/// The event a card or panel should SHOW for [e]: for a series master, the
/// first non-cancelled occurrence that has not ended by [nowUtc], else the
/// last occurrence, else [e] itself; for anything else, [e].
///
/// A master carries the series' FIRST occurrence's times, so a weekly
/// meeting that started in March would otherwise read as a meeting in
/// March. [occurrences] are the mirror's, by start.
CalendarEvent displayOccurrence(
  CalendarEvent e,
  List<CalendarEvent> occurrences,
  DateTime nowUtc,
  CalendarZone zone,
) {
  if (!e.isSeriesMaster || occurrences.isEmpty) return e;
  final now = nowUtc.toUtc();
  for (final o in occurrences) {
    if (!o.isCancelled && _stillAhead(o, now, zone)) return o;
  }
  return occurrences.last;
}

/// Whether [e] is part of a recurring series: the master itself, or one of
/// its occurrences or exceptions.
bool isSeriesEvent(CalendarEvent e) =>
    e.isSeriesMaster || e.seriesMasterId.trim().isNotEmpty;

/// Whether a Join button belongs on [e] at all at [nowUtc]: it has a join
/// link, it is not cancelled, and it has not ended. Wider than [joinable],
/// which says when the button is the thing to press — fifteen minutes out
/// until the end — and is what the button's emphasis follows. A meeting next
/// Thursday still offers its link, quietly; a past one does not.
bool offersJoin(CalendarEvent e, DateTime nowUtc, CalendarZone zone) {
  if (e.joinUrl.trim().isEmpty || e.isCancelled) return false;
  return _stillAhead(e, nowUtc.toUtc(), zone);
}

// ── who is coming ──────────────────────────────────────────────────────

/// The name a one-person tally part uses: the first word of the name, or
/// the address's local part when there is no name.
String _firstName(Attendee a) {
  final name = a.name.trim();
  if (name.isNotEmpty) return name.split(RegExp(r'\s+')).first;
  final address = a.address.trim();
  final at = address.indexOf('@');
  return at > 0 ? address.substring(0, at) : address;
}

/// "4 of 6 accepted · Sam declined · 1 no reply" on the organiser's copy;
/// "2 accepted · Sam declined" on an attendee's; null when there is nothing
/// honest to count.
///
/// Rooms are not people and the organiser is not an invitee, so neither is
/// counted — whether the organiser is known by address or only by a response
/// of `organizer`. Parts in a fixed order — accepted, maybe, declined, no
/// reply — with the empty ones left out, so the line is as short as the
/// answer.
///
/// Exchange keeps attendees' responses reliably only on the ORGANISER's
/// copy; an attendee's copy commonly reports `none` for everyone, which the
/// full rules would read as "6 no reply". So off the organiser's copy only
/// definite answers are counted — no "no reply" and no "of N" — and a copy
/// with none says nothing.
String? attendeeTally(CalendarEvent e) {
  final organiser = e.organizerAddress.trim().toLowerCase();
  final counted = [
    for (final a in e.attendees)
      if (a.type.trim().toLowerCase() != 'resource' &&
          a.response.trim().toLowerCase() != 'organizer' &&
          (organiser.isEmpty || a.address.trim().toLowerCase() != organiser))
        a,
  ];
  if (counted.isEmpty) return null;
  var accepted = 0;
  var maybe = 0;
  final declined = <Attendee>[];
  var noReply = 0;
  for (final a in counted) {
    switch (a.response.trim().toLowerCase()) {
      case 'accepted':
        accepted++;
      case 'tentativelyaccepted':
        maybe++;
      case 'declined':
        declined.add(a);
      default:
        noReply++;
    }
  }
  final declinedPart = declined.length == 1
      ? '${_firstName(declined.first)} declined'
      : declined.length > 1
          ? '${declined.length} declined'
          : null;
  if (!e.isOrganizer) {
    if (accepted + maybe + declined.length == 0) return null;
    return [
      if (accepted > 0) '$accepted accepted',
      if (maybe > 0) '$maybe maybe',
      ?declinedPart,
    ].join(' · ');
  }
  final total = counted.length;
  final parts = <String>[
    if (accepted == total)
      total == 1 ? 'Accepted' : 'All $total accepted'
    else if (accepted > 0)
      '$accepted of $total accepted',
    if (maybe > 0) '$maybe maybe',
    ?declinedPart,
    if (noReply > 0) '$noReply no reply',
  ];
  return parts.join(' · ');
}

/// Where the owner stands: "You organised this", "You accepted", "You said
/// maybe", "You declined", "You haven't answered", or "No answer needed"
/// when the organiser asked for none. A cancelled meeting is "Cancelled",
/// whatever was answered before.
String responseLine(CalendarEvent e) {
  if (e.isCancelled) return 'Cancelled';
  final status = e.responseStatus.trim().toLowerCase();
  if (e.isOrganizer || status == 'organizer') return 'You organised this';
  switch (status) {
    case 'accepted':
      return 'You accepted';
    case 'tentativelyaccepted':
      return 'You said maybe';
    case 'declined':
      return 'You declined';
  }
  if (e.needsResponse) return "You haven't answered";
  return 'No answer needed';
}

// ── when ───────────────────────────────────────────────────────────────

/// Whole days from [from] to [to], counted on dates: UTC midnights have no
/// DST, so the difference is always a whole number of days.
int _daysBetween(CalendarDate from, CalendarDate to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// "Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM" for a timed event;
/// "All day · Thursday, Oct 2" for a one-day all-day event; "All day · Thu
/// Oct 2 – Sat Oct 4" for a multi-day one (the inclusive last day is the
/// exclusive end date less one); "" when the times are missing.
///
/// A date outside [today]'s year carries its year — "Monday, Mar 3, 2025 ·
/// 10:00–10:30 AM", "All day · Mon Mar 3 – Wed Mar 5, 2025" — because an
/// invite from last spring otherwise reads as a meeting this spring. A
/// multi-day span names the year once, after the end; one whose two ends sit
/// in different years names both.
String eventWhenLine(
  CalendarEvent e, {
  required CalendarZone zone,
  required CalendarDate today,
}) {
  String year(CalendarDate d) => d.year == today.year ? '' : ', ${d.year}';
  if (e.isAllDay) {
    final start = e.startDate;
    if (start == null) return '';
    final end = e.endDate;
    if (end != null && end.isAfter(start.addDays(1))) {
      final last = end.addDays(-1);
      final from = shortDate(start);
      final to = shortDate(last);
      if (start.year == last.year) return 'All day · $from – $to${year(start)}';
      // Ends in two years: one of them is not this year, so both say theirs.
      return 'All day · $from, ${start.year} – $to, ${last.year}';
    }
    return 'All day · ${dayTitle(start, today)}${year(start)}';
  }
  final s = e.startUtc;
  final end = e.endUtc;
  if (s == null || end == null) return '';
  final day = zone.dateOf(s);
  return '${dayTitle(day, today)}${year(day)} · '
      '${formatEventRange(zone, s, end)}';
}

/// "Today 10:00 AM", "Tomorrow 10:00 AM", "Thu Oct 2, 10:00 AM" — or, for an
/// all-day event, the day alone.
String _shortWhen(CalendarEvent e, CalendarZone zone, CalendarDate today) {
  final s = e.startUtc;
  final day = e.isAllDay ? e.startDate : (s == null ? null : zone.dateOf(s));
  if (day == null) return '';
  final time = (!e.isAllDay && s != null) ? formatEventTime(zone, s) : null;
  if (day == today) return time == null ? 'Today' : 'Today $time';
  if (day == today.addDays(1)) {
    return time == null ? 'Tomorrow' : 'Tomorrow $time';
  }
  return time == null ? shortDate(day) : '${shortDate(day)}, $time';
}

String _subjectOf(CalendarEvent e) =>
    e.subject.trim().isEmpty ? '(no subject)' : e.subject.trim();

/// "Next meeting: Design review · Today 10:00 AM", "· Tomorrow 10:00 AM",
/// "· Thu Oct 2, 10:00 AM". An empty subject is "(no subject)".
String nextMeetingLabel(
  CalendarEvent e, {
  required CalendarZone zone,
  required CalendarDate today,
}) {
  final when = _shortWhen(e, zone, today);
  return 'Next meeting: ${_subjectOf(e)}${when.isEmpty ? '' : ' · $when'}';
}

/// "Last met today", "Last met yesterday", "Last met 12 days ago" — counted
/// in the display zone's DATES between the meeting's start and [today],
/// never as a duration divided by a day, which a DST change in between
/// would round the wrong way.
String lastMetLabel(
  CalendarEvent e, {
  required CalendarZone zone,
  required CalendarDate today,
}) {
  final s = e.startUtc;
  final day = e.isAllDay ? e.startDate : (s == null ? null : zone.dateOf(s));
  if (day == null) return 'Last met';
  final days = _daysBetween(day, today);
  if (days <= 0) return 'Last met today';
  if (days == 1) return 'Last met yesterday';
  return 'Last met $days days ago';
}

// ── which messages get a card ──────────────────────────────────────────

String _meetingKind(Message m) =>
    (m.meetingMessageType ?? '').trim().toLowerCase();

/// Whether [m] gets a meeting card: it names an event AND it is an invite
/// (`meetingRequest`) or a cancellation (`meetingCancelled`) in Graph's own
/// words. Responses (`meetingAccepted` and the rest) and plain mail never
/// do, and nothing is guessed from a subject line.
bool showsMeetingCard(Message m) {
  final id = m.meetingEventId;
  if (id == null || id.trim().isEmpty) return false;
  final kind = _meetingKind(m);
  return kind == 'meetingrequest' || kind == 'meetingcancelled';
}

/// Whether the card is the cancelled one-liner.
bool isCancellationCard(Message m) => _meetingKind(m) == 'meetingcancelled';
