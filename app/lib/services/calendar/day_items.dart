import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart';

import '../../models/calendar_models.dart';
import '../../models/message_models.dart';
import '../decision/stored_decision.dart';
import '../deadline_parse.dart';
import 'calendar_sync.dart' show CalendarAvailability;
import 'calendar_zone.dart';
import 'overlaps.dart';

/// The Day stop's arithmetic: what one day holds, in what order, and every
/// string the stop prints about a time.
///
/// Pure on purpose. The day is a MERGE of three things the app already knows
/// — the calendar mirror, the deadlines triage read out of the mail, and the
/// threads coming back from Later — and the merge rules are where the bugs
/// would live, so they live here where a test can hand them a clock and a
/// zone. The widgets only draw what this answers.
///
/// Every wall-clock string is read through the display zone
/// ([CalendarZone.toLocal]) and never through `DateTime.toLocal()`: the
/// device's zone and the calendar's display zone are two answers that agree
/// on most machines, and the one where they do not is the traveller's laptop
/// the zone resolver exists for.

// ── the items ──────────────────────────────────────────────────────────

/// One row of a day's agenda.
@immutable
sealed class DayItem {
  const DayItem();
}

/// A timed meeting, with what it runs into on the same day.
final class MeetingItem extends DayItem {
  final CalendarEvent event;

  /// Computed against that same day's events, so a row can say "overlaps your
  /// 1:1" without a second read.
  final Overlaps overlaps;

  const MeetingItem(this.event, {this.overlaps = const Overlaps()});

  bool get needsResponse => event.needsResponse;
}

/// An all-day event: a date on the wall, never an instant, so it heads the
/// day rather than sitting at a midnight it does not have.
final class AllDayItem extends DayItem {
  final CalendarEvent event;

  const AllDayItem(this.event);
}

/// A thread whose newest inbound named this day as its deadline.
final class DeadlineItem extends DayItem {
  final Conversation conversation;

  /// The deadline in the sender's own words, as [showableDeadline] passes it.
  final String deadline;

  /// The day it falls on, as [buildDayItems] matched it. The sender's words
  /// are no date, and a week of markers (the grid's header) needs one per
  /// tile; null only where a caller built the item by hand.
  final CalendarDate? day;

  const DeadlineItem(this.conversation, this.deadline, {this.day});
}

/// A thread snoozed into Later that comes back at [atUtc] on this day.
final class ReturnItem extends DayItem {
  final Conversation conversation;
  final DateTime atUtc;

  const ReturnItem(this.conversation, this.atUtc);
}

/// Where "now" falls among the day's timed rows. Only ever on today.
final class NowMarker extends DayItem {
  final DateTime atUtc;

  const NowMarker(this.atUtc);
}

// ── which days an event is on ──────────────────────────────────────────

bool _declined(CalendarEvent e) =>
    e.responseStatus.trim().toLowerCase() == 'declined';

/// Whether [e] is a commitment at all: not cancelled, not declined. The same
/// two tests the overlap maths skips on, so a count and an overlap line can
/// never disagree about what is on the day.
bool _counts(CalendarEvent e) => !e.isCancelled && !_declined(e);

/// The local dates a timed event touches, first and last inclusive.
///
/// The last date is the one holding the instant just before the end, so a
/// 9:00–10:00 PM meeting stays on its own day and an event ending at exactly
/// midnight does not spill onto the next. A zero-length event sits on its
/// start date.
(CalendarDate, CalendarDate)? _timedSpan(CalendarEvent e, CalendarZone zone) {
  final s = e.startUtc;
  final end = e.endUtc;
  if (s == null || end == null) return null;
  final first = zone.dateOf(s);
  final last = end.isAfter(s)
      ? zone.dateOf(end.subtract(const Duration(microseconds: 1)))
      : first;
  return (first, last);
}

/// Whether [e] belongs on [day]: a timed event on every local date it
/// touches, an all-day event on every date in `[startDate, endDate)`.
bool eventTouchesDay(CalendarEvent e, CalendarDate day, CalendarZone zone) {
  if (e.isAllDay) {
    final start = e.startDate;
    if (start == null) return false;
    final end = e.endDate;
    // A malformed or empty span still means the day it starts on.
    if (end == null || !end.isAfter(start)) return day == start;
    return !day.isBefore(start) && day.isBefore(end);
  }
  final span = _timedSpan(e, zone);
  if (span == null) return false;
  return !day.isBefore(span.$1) && !day.isAfter(span.$2);
}

// ── the day ────────────────────────────────────────────────────────────

/// Later, spelled here rather than imported: `laterRows` lives in a widget
/// file, and a service reaching into widgets would be the wrong way round.
bool _isLater(Conversation c) =>
    c.bucket == 'later' && c.state != ConversationState.done;

/// Where [c]'s deadline lands, and the words it lands with — or null when the
/// thread is done, names no deadline worth showing, or names one no parser
/// can place.
///
/// Relative words are read against the INBOUND MESSAGE THAT NAMED THEM
/// ([Conversation.lastInboundAt]: [Conversation.latestDeadline] is the newest
/// inbound's deadline, and that is its stamp), never against the reader's
/// clock. "EOD" said three weeks ago meant three weeks ago; read against
/// today it would be due today forever, "tomorrow" would always be tomorrow,
/// and "Friday" would come round again every week. A thread with no inbound
/// stamp falls back to [now], the only anchor it has.
///
/// The parser answers device-local midnight of the named day, so the anchor
/// is handed over in the device's zone and the day is read off its
/// components.
(CalendarDate, String)? _deadlineOf(Conversation c, DateTime now) {
  if (c.state == ConversationState.done) return null;
  final raw = c.latestDeadline;
  if (raw == null) return null;
  final anchor = DateTime.tryParse(c.lastInboundAt ?? '')?.toLocal() ?? now;
  final shown = showableDeadline(raw, now: anchor);
  if (shown == null) return null;
  final at = parseDeadline(raw, now: anchor);
  if (at == null) return null;
  return (CalendarDate(at.year, at.month, at.day), shown);
}

/// The instant [c] comes back from Later, or null when it is not in Later or
/// its snooze stamp does not parse.
DateTime? _returnAt(Conversation c) {
  if (!_isLater(c)) return null;
  return DateTime.tryParse(c.snoozedUntil ?? '')?.toUtc();
}

/// The local date [c] comes back from Later on — [_returnAt]'s day in the
/// display zone.
CalendarDate? _returnDate(Conversation c, CalendarZone zone) {
  final at = _returnAt(c);
  return at == null ? null : zone.dateOf(at);
}

/// One day's agenda, in the order it is read.
///
/// All-day events head it (in the order given — the store's), then the
/// deadlines, which have a day but no hour, then everything with an instant
/// — meetings, returns from Later and the Now marker — by that instant.
///
/// The Now marker sits after every timed row that started strictly before
/// [now] and before every row starting at or after it, so a meeting starting
/// this very minute reads as next rather than as past. A meeting and a return
/// at the same instant put the meeting first: it is the thing with people in
/// it.
///
/// A thread contributes ONE row per day. A deadline beats a return, because
/// "due today" is the stronger thing to be told about the same thread.
///
/// Deadlines resolve against the mail that named them (see [_deadlineOf]),
/// so a deadline whose day has passed is simply not on today: overdue work
/// is Needs You's to raise, not the agenda's.
///
/// Declined and cancelled meetings stay on the day — the row fades or strikes
/// through — because a meeting that silently vanished is a meeting somebody
/// turns up to. Overlaps are measured against [events] as given, which
/// [overlapsForEvent] already filters for cancelled, declined and free time.
///
/// [now] may be in any zone: instants are compared in UTC, and the deadline
/// parser is handed [now] itself (as the fallback anchor) because it reads
/// the reader's device day.
List<DayItem> buildDayItems({
  required CalendarDate day,
  required List<CalendarEvent> events,
  required List<Conversation> conversations,
  required DateTime now,
  required CalendarZone zone,
}) {
  final nowUtc = now.toUtc();
  final dayEvents = [
    for (final e in events)
      if (!e.isSeriesMaster && eventTouchesDay(e, day, zone)) e,
  ];

  final allDay = <DayItem>[
    for (final e in dayEvents)
      if (e.isAllDay) AllDayItem(e),
  ];

  final deadlines = <DayItem>[];
  final returns = <ReturnItem>[];
  for (final (on, item) in _markers(conversations, now, zone)) {
    if (on != day) continue;
    switch (item) {
      case DeadlineItem():
        deadlines.add(item);
      case ReturnItem():
        returns.add(item);
      default:
        break;
    }
  }

  // (instant, rank, input order, item): rank puts the Now marker ahead of
  // anything starting at the same instant, and a meeting ahead of a return.
  final timed = <(DateTime, int, int, DayItem)>[];
  var order = 0;
  for (final e in dayEvents) {
    if (e.isAllDay || e.startUtc == null) continue;
    timed.add((
      e.startUtc!,
      0,
      order++,
      MeetingItem(e, overlaps: overlapsForEvent(e, dayEvents, zone: zone)),
    ));
  }
  for (final r in returns) {
    timed.add((r.atUtc, 1, order++, r));
  }
  if (zone.dateOf(nowUtc) == day) {
    timed.add((nowUtc, -1, order++, NowMarker(nowUtc)));
  }
  timed.sort((a, b) {
    final byAt = a.$1.compareTo(b.$1);
    if (byAt != 0) return byAt;
    final byRank = a.$2.compareTo(b.$2);
    if (byRank != 0) return byRank;
    return a.$3.compareTo(b.$3);
  });

  return [
    ...allDay,
    ...deadlines,
    for (final t in timed) t.$4,
  ];
}

/// Every thread's deadline and return, each with the local date it falls
/// on, in [conversations] order: the one place the agenda's rows and the
/// grid's header markers are decided, so [buildDayItems] and [rangeMarkers]
/// cannot drift apart.
///
/// A thread contributes one marker per day: a deadline claims its day, so a
/// return on that same day is dropped, and a return on any other day still
/// stands.
Iterable<(CalendarDate, DayItem)> _markers(
  List<Conversation> conversations,
  DateTime now,
  CalendarZone zone,
) sync* {
  for (final c in conversations) {
    final due = _deadlineOf(c, now);
    if (due != null) yield (due.$1, DeadlineItem(c, due.$2, day: due.$1));
    final at = _returnAt(c);
    if (at == null) continue;
    final on = zone.dateOf(at);
    if (due != null && due.$1 == on) continue;
    yield (on, ReturnItem(c, at));
  }
}

/// The deadlines and returns of every day in `[from, toExclusive)`, day by
/// day, in the order [buildDayItems] lists them on each — deadlines first,
/// then returns by their instant — and nothing else.
///
/// The grid's header wants only these, and a week of [buildDayItems] would
/// run the overlap maths seven times over events the header never reads.
List<DayItem> rangeMarkers({
  required CalendarDate from,
  required CalendarDate toExclusive,
  required List<Conversation> conversations,
  required DateTime now,
  required CalendarZone zone,
}) {
  final deadlines = <CalendarDate, List<DayItem>>{};
  final returns = <CalendarDate, List<ReturnItem>>{};
  for (final (on, item) in _markers(conversations, now, zone)) {
    if (on.isBefore(from) || !on.isBefore(toExclusive)) continue;
    switch (item) {
      case DeadlineItem():
        (deadlines[on] ??= []).add(item);
      case ReturnItem():
        (returns[on] ??= []).add(item);
      default:
        break;
    }
  }
  final out = <DayItem>[];
  for (var d = from; d.isBefore(toExclusive); d = d.addDays(1)) {
    out.addAll(deadlines[d] ?? const <DayItem>[]);
    // By instant, ties in input order: [buildDayItems]' own sort, which
    // List.sort alone would not promise (it is not stable).
    final back = [...?returns[d]].indexed.toList()
      ..sort((a, b) {
        final byAt = a.$2.atUtc.compareTo(b.$2.atUtc);
        return byAt != 0 ? byAt : a.$1.compareTo(b.$1);
      });
    out.addAll([for (final (_, r) in back) r]);
  }
  return out;
}

// ── invites ────────────────────────────────────────────────────────────

/// One invite still owed an answer, a recurring series folded to one entry.
@immutable
class InviteEntry {
  /// The soonest occurrence still owed — what the row shows and what an
  /// answer to "this one" would answer.
  final CalendarEvent event;

  /// How many owed occurrences this entry stands for.
  final int occurrences;

  /// A linked invite message the decision model read as urgent or important.
  final bool pinned;

  /// What [event]'s slot runs into.
  final Overlaps overlaps;

  const InviteEntry(
    this.event, {
    this.occurrences = 1,
    this.pinned = false,
    this.overlaps = const Overlaps(),
  });

  bool get isSeries => occurrences > 1 || event.seriesMasterId.isNotEmpty;

  InviteEntry withContext({bool? pinned, Overlaps? overlaps}) => InviteEntry(
        event,
        occurrences: occurrences,
        pinned: pinned ?? this.pinned,
        overlaps: overlaps ?? this.overlaps,
      );
}

/// The instant an invite sorts by: a timed event's start, an all-day event's
/// date at UTC midnight — the key `CalendarStore.invitesOwed` sorts by, so the
/// two orders agree.
DateTime inviteSortKey(CalendarEvent e) =>
    e.startUtc ??
    (e.startDate == null
        ? DateTime.utc(0)
        : DateTime.utc(e.startDate!.year, e.startDate!.month, e.startDate!.day));

/// The local date an invite starts on.
CalendarDate? inviteDate(CalendarEvent e, CalendarZone zone) {
  if (e.isAllDay) return e.startDate;
  final s = e.startUtc;
  return s == null ? null : zone.dateOf(s);
}

/// [owed] with every recurring series folded to one entry.
///
/// `invitesOwed` answers every expanded occurrence of an unanswered series,
/// and a weekly meeting nobody has answered is seventeen rows of the same
/// question. Folded by `seriesMasterId`: the entry keeps the SOONEST
/// occurrence and counts the rest. An event with no series master stands
/// alone. Entries come out in the order of their soonest occurrence.
List<InviteEntry> collapseInvites(List<CalendarEvent> owed) {
  final soonest = <String, CalendarEvent>{};
  final counts = <String, int>{};
  final keys = <String>[];
  for (final e in owed) {
    final series = e.seriesMasterId;
    final key = series.isEmpty ? 'event\u0000${e.id}' : 'series\u0000$series';
    final had = soonest[key];
    if (had == null) {
      keys.add(key);
      soonest[key] = e;
      counts[key] = 1;
      continue;
    }
    counts[key] = counts[key]! + 1;
    final byStart = inviteSortKey(e).compareTo(inviteSortKey(had));
    if (byStart < 0 || (byStart == 0 && e.id.compareTo(had.id) < 0)) {
      soonest[key] = e;
    }
  }
  final entries = [
    for (final key in keys) InviteEntry(soonest[key]!, occurrences: counts[key]!),
  ];
  return orderInvites(entries);
}

/// Whether any of [decisions] — the stored decisions of an invite's linked
/// messages — reads the invite as pressing: urgency `high` or `urgent`, or
/// importance `high`.
///
/// Tolerant by construction: a message the model never read is null, and an
/// unreadable blob has no fields; both are simply not a pin. The lookup is
/// `fields[...]` and never the throwing `operator []`.
bool invitePinned(Iterable<StoredDecision?> decisions) {
  for (final d in decisions) {
    if (d == null) continue;
    final fields = d.answers.fields;
    final urgency = fields['urgency']?.choice;
    if (urgency == 'high' || urgency == 'urgent') return true;
    if (fields['importance']?.choice == 'high') return true;
  }
  return false;
}

/// Pinned invites first, then soonest first, then by id — a total order, so
/// the list never reshuffles between two reads of the same rows.
List<InviteEntry> orderInvites(List<InviteEntry> entries) {
  final out = [...entries];
  out.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final byStart =
        inviteSortKey(a.event).compareTo(inviteSortKey(b.event));
    if (byStart != 0) return byStart;
    return a.event.id.compareTo(b.event.id);
  });
  return out;
}

// ── the list column ───────────────────────────────────────────────────

/// What one day holds, counted for its row in the list column.
@immutable
class DaySummary {
  /// Timed and all-day events that are commitments — not cancelled, not
  /// declined.
  final int meetings;
  final int due;
  final int returns;
  final int invites;

  const DaySummary({
    this.meetings = 0,
    this.due = 0,
    this.returns = 0,
    this.invites = 0,
  });

  bool get isEmpty => meetings == 0 && due == 0 && returns == 0 && invites == 0;

  @override
  bool operator ==(Object other) =>
      other is DaySummary &&
      other.meetings == meetings &&
      other.due == due &&
      other.returns == returns &&
      other.invites == invites;

  @override
  int get hashCode => Object.hash(meetings, due, returns, invites);

  @override
  String toString() =>
      'DaySummary(meetings: $meetings, due: $due, returns: $returns, '
      'invites: $invites)';
}

/// [items] (one day's, from [buildDayItems]) and the owed [invites] starting
/// on [day], counted.
DaySummary daySummary({
  required CalendarDate day,
  required List<DayItem> items,
  required List<InviteEntry> invites,
  required CalendarZone zone,
}) {
  var meetings = 0;
  var due = 0;
  var returns = 0;
  for (final item in items) {
    switch (item) {
      case MeetingItem(:final event) || AllDayItem(:final event):
        if (_counts(event)) meetings++;
      case DeadlineItem():
        due++;
      case ReturnItem():
        returns++;
      case NowMarker():
        break;
    }
  }
  var owed = 0;
  for (final entry in invites) {
    if (inviteDate(entry.event, zone) == day) owed++;
  }
  return DaySummary(
    meetings: meetings,
    due: due,
    returns: returns,
    invites: owed,
  );
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// A bare date as a DateTime for [DateFormat]: UTC for [_wall]'s reason, so
/// a date whose midnight the device skips (a zone that springs forward at
/// midnight) still formats as itself.
DateTime _naive(CalendarDate d) => DateTime.utc(d.year, d.month, d.day);

/// A day row's label: "Today · 3 meetings · 1 due", "Thu Oct 2 · clear".
///
/// "clear" rather than nothing, because a row for today that said only
/// "Today" would read as a heading with its rows missing.
String dayRowLabel(CalendarDate day, CalendarDate today, DaySummary s) {
  final prefix = day == today
      ? 'Today'
      : day == today.addDays(1)
          ? 'Tomorrow'
          : DateFormat('EEE MMM d').format(_naive(day));
  final parts = [
    if (s.meetings > 0) _plural(s.meetings, 'meeting', 'meetings'),
    if (s.due > 0) '${s.due} due',
    if (s.returns > 0) '${s.returns} back',
    if (s.invites > 0) _plural(s.invites, 'invite', 'invites'),
  ];
  if (parts.isEmpty) return '$prefix · clear';
  return '$prefix · ${parts.join(' · ')}';
}

/// The Day column's rows: today and tomorrow always — the two days anybody
/// asks about — then each later day up to [horizon] that has anything on it.
/// An empty Thursday is not worth a row; an empty today is worth saying.
///
/// The conversations are narrowed ONCE to the ones that land somewhere in
/// the window — by the same [_deadlineOf] and [_returnDate] that
/// [buildDayItems] places them with, so the two cannot disagree — and only
/// those go into each day's merge. Otherwise every build of the column
/// would parse every thread's deadline fifteen times over.
List<(CalendarDate, DaySummary)> upcomingDays({
  required CalendarDate today,
  required List<CalendarEvent> events,
  required List<Conversation> conversations,
  required List<InviteEntry> invites,
  required DateTime now,
  required CalendarZone zone,
  int horizon = 14,
}) {
  final last = today.addDays(horizon);
  bool inWindow(CalendarDate? d) =>
      d != null && !d.isBefore(today) && !d.isAfter(last);
  final candidates = [
    for (final c in conversations)
      if (inWindow(_deadlineOf(c, now)?.$1) || inWindow(_returnDate(c, zone)))
        c,
  ];
  final out = <(CalendarDate, DaySummary)>[];
  for (var i = 0; i <= horizon; i++) {
    final day = today.addDays(i);
    final items = buildDayItems(
      day: day,
      events: events,
      conversations: candidates,
      now: now,
      zone: zone,
    );
    final summary =
        daySummary(day: day, items: items, invites: invites, zone: zone);
    if (i < 2 || !summary.isEmpty) out.add((day, summary));
  }
  return out;
}

/// The instant the invites read is taken "as of": [now] in UTC, floored to
/// the quarter hour.
///
/// The host computes it on every build and hands it to the provider as the
/// family argument, so the provider never keeps a clock of its own — an
/// invite that has started drops off and "today" rolls over at midnight
/// without anything else having to happen. Floored so the argument, and so
/// the read, changes four times an hour rather than on every frame.
DateTime invitesAsOf(DateTime now) {
  final u = now.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute - u.minute % 15);
}

/// What is still ahead today, for the Inbox stack's Today section: timed
/// commitments touching today's local date that have not ended, soonest
/// first, at most [limit]. A meeting in progress counts — it is the one most
/// worth a glance.
List<CalendarEvent> remainingToday({
  required List<CalendarEvent> events,
  required DateTime nowUtc,
  required CalendarZone zone,
  int limit = 3,
}) {
  final now = nowUtc.toUtc();
  final today = zone.dateOf(now);
  final left = [
    for (final e in events)
      if (e.isTimed &&
          !e.isSeriesMaster &&
          _counts(e) &&
          e.endUtc != null &&
          e.endUtc!.isAfter(now) &&
          eventTouchesDay(e, today, zone))
        e,
  ];
  left.sort((a, b) {
    final byStart = a.startUtc!.compareTo(b.startUtc!);
    return byStart != 0 ? byStart : a.id.compareTo(b.id);
  });
  return left.take(limit).toList();
}

// ── where the calendar shows ──────────────────────────────────────────

/// Whether the Day stop draws the mirror's rows at all.
///
/// Hidden only where the calendar is not this session's to show: a grant
/// without the calendar scope, and SDK mode — a switch to SDK leaves the old
/// rows in the table, and showing them would be a calendar nothing keeps
/// current. An offline tick ([CalendarAvailability.unavailable]) and a
/// session no tick has answered yet still show what was saved.
bool calendarShowsMirror(CalendarAvailability a) =>
    a == CalendarAvailability.available ||
    a == CalendarAvailability.unknown ||
    a == CalendarAvailability.unavailable;

/// Whether the Inbox stack carries its Today section: only once a tick has
/// said the calendar is there (or was, a moment ago). Never on `unknown`, so
/// the stack does not grow a section and lose it again on a launch whose
/// first answer is "no calendar".
bool calendarShowsToday(CalendarAvailability a) =>
    a == CalendarAvailability.available ||
    a == CalendarAvailability.unavailable;

// ── words about time ──────────────────────────────────────────────────

/// A local wall time with no zone attached, for [DateFormat], which formats
/// the fields it is given. Built from the zoned value's components so the
/// device zone never gets a say.
///
/// Built as a UTC DateTime, which only carries the fields: the device-local
/// constructor would NORMALISE them through the device's own zone, and a
/// display-zone 2:30 AM that falls in the DEVICE's spring-forward gap would
/// come out as 3:30. UTC has no gaps, so the fields go in and come out as
/// given.
DateTime _wall(CalendarZone zone, DateTime utc) {
  final l = zone.toLocal(utc);
  return DateTime.utc(l.year, l.month, l.day, l.hour, l.minute);
}

/// `h:mm a` on the display zone's clock: "9:05 AM".
String formatEventTime(CalendarZone zone, DateTime utc) =>
    DateFormat('h:mm a').format(_wall(zone, utc));

/// A meeting's span, as short as it can honestly be:
/// "10:00–10:30 AM" (one meridiem, one date), "11:30 AM–12:30 PM" (two
/// meridiems), "11:00 PM–Tue 1:00 AM" (ends on a later local date).
String formatEventRange(CalendarZone zone, DateTime startUtc, DateTime endUtc) {
  final s = _wall(zone, startUtc);
  final e = _wall(zone, endUtc);
  final sameDate = s.year == e.year && s.month == e.month && s.day == e.day;
  if (!sameDate) {
    return '${DateFormat('h:mm a').format(s)}–'
        '${DateFormat('EEE h:mm a').format(e)}';
  }
  if ((s.hour < 12) == (e.hour < 12)) {
    return '${DateFormat('h:mm').format(s)}–${DateFormat('h:mm a').format(e)}';
  }
  return '${DateFormat('h:mm a').format(s)}–${DateFormat('h:mm a').format(e)}';
}

/// "in 18m" inside the hour before a meeting, "now" while it runs, otherwise
/// null. Minutes round UP, so a meeting 30 seconds out says "in 1m" and
/// never "in 0m".
String? meetingCountdown(CalendarEvent e, DateTime nowUtc) {
  final s = e.startUtc;
  final end = e.endUtc;
  if (!e.isTimed || e.isCancelled || s == null || end == null) return null;
  final now = nowUtc.toUtc();
  if (s.isAfter(now)) {
    final wait = s.difference(now);
    if (wait >= const Duration(minutes: 60)) return null;
    final micros = wait.inMicroseconds;
    var minutes = (micros + Duration.microsecondsPerMinute - 1) ~/
        Duration.microsecondsPerMinute;
    if (minutes < 1) minutes = 1;
    return 'in ${minutes}m';
  }
  if (now.isBefore(end)) return 'now';
  return null;
}

/// Whether a Join button belongs on [e]: it has a join link, it is a live
/// timed meeting, and [nowUtc] is from fifteen minutes before the start
/// (inclusive) until the end (exclusive).
bool joinable(CalendarEvent e, DateTime nowUtc) {
  final s = e.startUtc;
  final end = e.endUtc;
  if (e.joinUrl.trim().isEmpty || !e.isTimed || e.isCancelled) return false;
  if (s == null || end == null) return false;
  final now = nowUtc.toUtc();
  return !now.isBefore(s.subtract(const Duration(minutes: 15))) &&
      now.isBefore(end);
}

/// The Monday of [day]'s week: the grid's week starts Monday, and the week
/// read is keyed by it so every day of one week shares one read.
CalendarDate mondayOf(CalendarDate day) => day.addDays(1 - day.weekday);

/// The Day pane's title: "Today · Tuesday, Sep 29", "Tomorrow · …",
/// "Yesterday · …", or just "Thursday, Oct 2".
String dayTitle(CalendarDate day, CalendarDate today) {
  final body = DateFormat('EEEE, MMM d').format(_naive(day));
  if (day == today) return 'Today · $body';
  if (day == today.addDays(1)) return 'Tomorrow · $body';
  if (day == today.addDays(-1)) return 'Yesterday · $body';
  return body;
}

/// "EEE MMM d" for a bare date: "Thu Oct 2".
String shortDate(CalendarDate day) =>
    DateFormat('EEE MMM d').format(_naive(day));

/// A row's overlap line — "⚠ overlaps Budget review +2" — or null when the
/// slot runs into nothing worth saying. A hard overlap is named before a
/// soft one; all-day banners are not overlaps and are not counted.
String? overlapLine(Overlaps o) {
  final total = o.hard.length + o.soft.length;
  if (total == 0) return null;
  final first = o.hard.isNotEmpty ? o.hard.first : o.soft.first;
  final subject =
      first.subject.trim().isEmpty ? '(no subject)' : first.subject.trim();
  return '⚠ overlaps $subject${total > 1 ? ' +${total - 1}' : ''}';
}
