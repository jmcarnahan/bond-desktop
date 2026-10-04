import 'package:flutter/foundation.dart' show immutable;

import '../../models/calendar_models.dart';
import 'ask_hours.dart';
import 'calendar_zone.dart';
import 'event_standing.dart';

/// Does this slot clash, and when is the person actually free?
///
/// A port of the reference overlap rules from an earlier calendar assistant,
/// each of which was paid for by a shipped bug there.
///
/// The word is deliberately "overlap" and never "conflict": in this app
/// "conflict" already means an etag rejection (`CalendarEventChanged`, the
/// `if_match` that lost a race), and a scheduling clash borrowing the name
/// would collide with it in every later conversation about this code.
///
/// What counts, and why:
///
/// - **All-day events are noted, never blocking.** They are dates on the wall
///   ([CalendarEvent.startDate]/[CalendarEvent.endDate]), not instants, so
///   they never reach the arithmetic at all. A person with an all-day "Offsite"
///   banner gets a mention, not a refusal.
/// - **Cancelled events, and events the person DECLINED,** are not on their
///   day.
/// - **`free` and `workingElsewhere`** are, by Outlook's own definition, not
///   busy.
/// - **A tentative hold is a SOFT overlap** — a Maybe answer, or anything
///   Outlook shows as tentative, which is how an unanswered invite sits
///   ([isTentativeHold]): worth saying out loud, not worth refusing a booking
///   over.
/// - **Touching ends do not overlap.** A 3:00–4:00 and a 4:00–5:00 are a normal
///   afternoon, not a clash; see [instantsOverlap].
/// - **An event never overlaps itself.** The event being MOVED is ignored by
///   id, or every reschedule would look blocked by its own old slot.
///
/// Everything is compared as UTC instants. Local wall time enters in exactly
/// one place — building the working window on each local date — and goes
/// through [CalendarZone.localDateTime], so a DST day is 23 or 25 hours long
/// and 08:00 still means 08:00.

/// Outlook `showAs` states that do not occupy the person (compared
/// lower-case).
const Set<String> _nonBlockingShowAs = {'free', 'workingelsewhere'};

/// The grid free slots are proposed on. People think in quarter hours, and a
/// finer grid would offer "3:07 PM is free".
const Duration _step = Duration(minutes: 15);

/// The working window when the mailbox has not said, on the person's own
/// wall clock.
const (int, int) _defaultStart = (8, 0);
const (int, int) _defaultEnd = (18, 0);

/// Strict overlap of two half-open spans `[aStart, aEnd)` and
/// `[bStart, bEnd)`. Touching ends are NOT an overlap.
///
/// [DateTime.isBefore] compares instants (microseconds since the epoch), not
/// wall fields, so a UTC value and a `TZDateTime` in any zone compare
/// correctly — including the repeated hour of a fall-back night, where two
/// different instants share one wall-clock label.
bool instantsOverlap(
  DateTime aStart,
  DateTime aEnd,
  DateTime bStart,
  DateTime bEnd,
) =>
    aStart.isBefore(bEnd) && bStart.isBefore(aEnd);

/// What a proposed slot runs into, split by how much it matters.
@immutable
class Overlaps {
  /// Busy (or `oof`, `unknown`, or no `showAs` at all) timed events the slot
  /// runs into. These are a real clash.
  final List<CalendarEvent> hard;

  /// Maybe timed events the slot runs into — a `tentative` showAs or a
  /// tentative answer ([isTentativeHold]): said out loud, never a refusal.
  final List<CalendarEvent> soft;

  /// All-day events on the slot's day(s). Mentioned, never blocking.
  final List<CalendarEvent> allDayNotes;

  const Overlaps({
    this.hard = const [],
    this.soft = const [],
    this.allDayNotes = const [],
  });

  /// Nothing at all to say about the slot.
  bool get isEmpty => hard.isEmpty && soft.isEmpty && allDayNotes.isEmpty;

  @override
  String toString() => 'Overlaps(hard: ${hard.map((e) => e.id).toList()}, '
      'soft: ${soft.map((e) => e.id).toList()}, '
      'allDay: ${allDayNotes.map((e) => e.id).toList()})';
}

/// Whether [event] is on the person's day at all: not cancelled, not
/// declined. Shared by the overlap check and the free-slot walk so the two
/// can never disagree about what counts.
bool _counts(CalendarEvent event) => switch (standingOf(event)) {
      EventStanding.cancelled || EventStanding.declined => false,
      _ => true,
    };

String _showAs(CalendarEvent event) => event.showAs.trim().toLowerCase();

/// Splits [events] into what blocks `[startUtc, endUtc)`, what merely worries
/// it, and the all-day banners worth mentioning either way.
///
/// [ignoreEventId] is the event being MOVED: an event always overlaps its own
/// old slot, and reporting that would make every reschedule look blocked.
///
/// All-day events: the reference rules noted every all-day event they were
/// handed, because their callers only ever handed them one day's events.
/// This app's callers may
/// hand over the whole mirror, so when [zone] is given an all-day event is
/// noted only if its dates cover a local date the slot touches in that zone.
/// Without [zone] there is no way to say which local dates the slot touches,
/// so every all-day event is noted (the reference behaviour) and the caller is
/// expected to have filtered to the day.
///
/// A timed event whose instants could not be read (both null — see
/// [CalendarEvent]) is skipped: it cannot be placed, and guessing would place
/// it wrong.
Overlaps findOverlaps(
  Iterable<CalendarEvent> events,
  DateTime startUtc,
  DateTime endUtc, {
  String? ignoreEventId,
  CalendarZone? zone,
}) {
  final hard = <CalendarEvent>[];
  final soft = <CalendarEvent>[];
  final notes = <CalendarEvent>[];
  // The local dates the slot touches: its first instant's date through its
  // last instant's date. `endUtc` is exclusive, so a slot ending exactly at
  // midnight does not touch the next day.
  final firstDate = zone?.dateOf(startUtc);
  final lastDate = zone?.dateOf(endUtc.isAfter(startUtc)
      ? endUtc.subtract(const Duration(microseconds: 1))
      : startUtc);
  for (final event in events) {
    if (ignoreEventId != null && event.id == ignoreEventId) continue;
    if (!_counts(event)) continue;
    if (event.isAllDay) {
      // BEFORE any arithmetic: an all-day boundary is a date, not an instant.
      if (firstDate == null || lastDate == null) {
        notes.add(event);
        continue;
      }
      final s = event.startDate;
      final e = event.endDate;
      if (s == null || e == null) continue;
      // [s, e) against [firstDate, lastDate]: e is exclusive.
      if (!s.isAfter(lastDate) && e.isAfter(firstDate)) notes.add(event);
      continue;
    }
    final showAs = _showAs(event);
    if (_nonBlockingShowAs.contains(showAs)) continue;
    final s = event.startUtc;
    final e = event.endUtc;
    if (s == null || e == null) continue;
    if (!instantsOverlap(s, e, startUtc, endUtc)) continue;
    if (isTentativeHold(event)) {
      soft.add(event);
    } else {
      hard.add(event);
    }
  }
  return Overlaps(
    hard: List.unmodifiable(hard),
    soft: List.unmodifiable(soft),
    allDayNotes: List.unmodifiable(notes),
  );
}

/// What [event]'s own slot runs into among [others] — the view an event panel
/// shows ("overlaps your 1:1 with Dana").
///
/// [event] is ignored by id, so passing the whole day (itself included) is
/// fine. An all-day event has no slot to clash with, so it returns an empty
/// [Overlaps]; so does a timed event whose instants could not be read, and a
/// cancelled or declined one — it is not on the day, so it clashes with
/// nothing, just as nothing clashes with it. A `free` or `workingElsewhere`
/// event occupies no time either, so it wears no clash for a busy meeting
/// that shows nothing back.
Overlaps overlapsForEvent(
  CalendarEvent event,
  Iterable<CalendarEvent> others, {
  CalendarZone? zone,
}) {
  if (!_counts(event)) return const Overlaps();
  if (_nonBlockingShowAs.contains(_showAs(event))) return const Overlaps();
  final s = event.startUtc;
  final e = event.endUtc;
  if (event.isAllDay || s == null || e == null) return const Overlaps();
  return findOverlaps(others, s, e, ignoreEventId: event.id, zone: zone);
}

/// One open span of the person's time, as UTC instants. `[startUtc, endUtc)`
/// is always exactly the requested duration in real time.
@immutable
class FreeSlot {
  final DateTime startUtc;
  final DateTime endUtc;

  const FreeSlot(this.startUtc, this.endUtc);

  Duration get duration => endUtc.difference(startUtc);

  @override
  bool operator ==(Object other) =>
      other is FreeSlot &&
      other.startUtc.isAtSameMomentAs(startUtc) &&
      other.endUtc.isAtSameMomentAs(endUtc);

  @override
  int get hashCode => Object.hash(
      startUtc.microsecondsSinceEpoch, endUtc.microsecondsSinceEpoch);

  @override
  String toString() =>
      'FreeSlot(${startUtc.toIso8601String()} – ${endUtc.toIso8601String()})';
}

/// Up to [limit] open slots of [durationMinutes] on local [day] in [zone].
///
/// **The window.** The working day comes from [hours] when its start and end
/// both parse (`HH:MM`, `HH:MM:SS`, or Graph's `HH:MM:SS.fffffff`) and the
/// end is after the start; otherwise it is 08:00–18:00. It is CONSTRUCTED on
/// [day] with [zone]'s wall clock, never offset from UTC, or it would slide an
/// hour twice a year.
///
/// The hours are read on [zone]'s wall clock even when
/// [MailboxSettings.workingZoneIana] names another zone. That is a choice: the
/// numbers mean "my working day", and a person travelling with their laptop
/// works 9–5 where they are, not 9–5 back home; building the window in the
/// mailbox's zone would offer a Londoner's 06:00 to someone in Seattle.
///
/// **The walk** runs on UTC INSTANTS in 15-minute steps from the window
/// start. Adding a [Duration] to a local wall time moves its fields and
/// re-derives the offset, so a wall-clock walk would offer 02:00 on a
/// spring-forward morning (an hour that does not exist) and a 90-minute slot
/// labelled 60 on a fall-back one. Stepping in UTC keeps both true at once: a
/// slot is always its real length, and read back through [zone] its label is
/// always a wall time that exists. The window start is local-aligned (it is a
/// wall time), so steps land on :00/:15/:30/:45 — except in the window's
/// stretch after a DST transition in a zone whose shift is not a whole
/// quarter hour, which no working window in practice straddles.
///
/// **Each returned slot is a DISTINCT opening**: on a hit the walk jumps to
/// the end of the slot it just found (rounded up to the next quarter-hour
/// step, so a 20-minute slot does not push the next offer to :20). A clear
/// 16:00–18:00 asked for 60 minutes offers 16:00 and 17:00, not 16:00, 16:15
/// and 16:30 — three buttons for one gap while the 17:00 slot goes unsaid.
///
/// **What blocks.** Timed events that are not cancelled, not declined, and
/// not `free`/`workingElsewhere`. A Maybe ([isTentativeHold]) BLOCKS by
/// default, unlike
/// the reference rules' free-slot walk (which offers a slot whenever no
/// HARD overlap was found): a slot offered here may be sent to
/// other people as an invite, and offering a time the owner has tentatively
/// promised elsewhere is the worse mistake. A proposed slot that lands on a
/// tentative hold is still only a SOFT overlap in [findOverlaps]. Pass
/// [tentativeBlocks] false for the reference behaviour. All-day events never
/// block.
///
/// **[windowStartUtc] and [windowEndUtc] narrow the search** (either may be
/// null): the day's window is the INTERSECTION of the working window and
/// `[windowStartUtc, windowEndUtc)`. "Find 30 min tomorrow afternoon" hands
/// the resolver's `windowUtc` here, so the first offer is 12:00 and not the
/// 08:00 the working day would otherwise open with. A clamped start between
/// grid steps is rounded up onto the grid. An intersection shorter than the
/// duration — a clamp outside working hours, say — offers nothing.
///
/// **[notBeforeUtc] is a preference, not a filter**: when the 3:00 is taken,
/// "4:00 instead" is the useful answer and "9:00 this morning" is not — but a
/// day that only has earlier gaps still offers them rather than nothing. The
/// preferred group is its own chain of distinct openings SEEDED at
/// [notBeforeUtc] (rounded up onto the grid), so "not before 3:30" offers
/// 3:30 itself rather than whatever the 08:00 chain happened to land on after
/// it. Then come the openings that start before it, NEAREST FIRST: when the
/// afternoon is gone, 1:00 is a better second-best than 8:00.
///
/// **[nowUtc] IS a filter**: a slot starting before it is never offered —
/// nobody can meet at 9:00 at 10:42.
List<FreeSlot> freeSlotsOnDay({
  required Iterable<CalendarEvent> events,
  required CalendarDate day,
  required int durationMinutes,
  required CalendarZone zone,
  MailboxSettings? hours,
  int limit = 3,
  DateTime? notBeforeUtc,
  DateTime? nowUtc,
  DateTime? windowStartUtc,
  DateTime? windowEndUtc,
  bool tentativeBlocks = true,
}) {
  if (durationMinutes <= 0 || limit <= 0) return const [];
  return _offer(
    busy: _busySpans(events, tentativeBlocks),
    days: [day],
    duration: Duration(minutes: durationMinutes),
    zone: zone,
    window: _WorkingWindow.of(hours),
    limit: limit,
    notBeforeUtc: notBeforeUtc,
    nowUtc: nowUtc,
    windowStartUtc: windowStartUtc,
    windowEndUtc: windowEndUtc,
  );
}

/// Up to [limit] open slots of [durationMinutes] from [firstDay] through
/// [lastDay] (INCLUSIVE), with every rule of [freeSlotsOnDay] applied per day.
///
/// With [skipNonWorkingDays] (the default), days the mailbox does not work
/// are skipped: [MailboxSettings.workingDays] when it names any (Graph's
/// English day names, compared case-insensitively), else Saturday and
/// Sunday. [freeSlotsOnDay] never skips — a caller that names a Saturday
/// means the Saturday.
///
/// [notBeforeUtc] is a preference across the whole range (later-or-equal
/// slots first, then the earlier ones nearest first, possibly from an earlier
/// day), [nowUtc] a filter — callers pass `firstDay` = today, and the morning
/// that has already gone is not offered. [windowStartUtc]/[windowEndUtc] clamp
/// every day's window, so a range clamp from Wednesday 15:00 to Thursday 12:00
/// offers Wednesday's late afternoon and Thursday's morning only.
///
/// [dailyHours] replaces the working window on EVERY day — an ask for dinner
/// looks at 17:30–20:30, not at the mailbox's 9–5 — and is clamped by the
/// window bounds like the working window is. Pair it with
/// [skipNonWorkingDays] false when the ask named the day.
List<FreeSlot> freeSlotsInRange({
  required Iterable<CalendarEvent> events,
  required CalendarDate firstDay,
  required CalendarDate lastDay,
  required int durationMinutes,
  required CalendarZone zone,
  MailboxSettings? hours,
  int limit = 3,
  DateTime? notBeforeUtc,
  DateTime? nowUtc,
  DateTime? windowStartUtc,
  DateTime? windowEndUtc,
  bool skipNonWorkingDays = true,
  bool tentativeBlocks = true,
  AskHours? dailyHours,
}) {
  if (durationMinutes <= 0 || limit <= 0) return const [];
  if (lastDay.isBefore(firstDay)) return const [];
  // Hours that end where they start hold no slot, and say so by offering
  // none — never the working day in their place.
  if (dailyHours != null &&
      dailyHours.endInMinutes <= dailyHours.startInMinutes) {
    return const [];
  }
  final workingDays = _workingWeekdays(hours);
  final window = dailyHours == null
      ? _WorkingWindow.of(hours)
      : _WorkingWindow(
          (dailyHours.startHour, dailyHours.startMinute),
          (dailyHours.endHour, dailyHours.endMinute),
        );
  return _offer(
    busy: _busySpans(events, tentativeBlocks),
    days: [
      for (var day = firstDay; !day.isAfter(lastDay); day = day.addDays(1))
        if (!skipNonWorkingDays || workingDays.contains(day.weekday)) day,
    ],
    duration: Duration(minutes: durationMinutes),
    zone: zone,
    window: window,
    limit: limit,
    notBeforeUtc: notBeforeUtc,
    nowUtc: nowUtc,
    windowStartUtc: windowStartUtc,
    windowEndUtc: windowEndUtc,
  );
}

/// The mailbox's working window as [AskHours] — what Find a time compares an
/// ask's hours against to decide whether Graph may look outside work time.
/// 08:00–18:00 when the hours do not parse, the walk's own fallback.
AskHours workingWindowOf(MailboxSettings? hours) {
  final w = _WorkingWindow.of(hours);
  return AskHours(
    startHour: w.start.$1,
    startMinute: w.start.$2,
    endHour: w.end.$1,
    endMinute: w.end.$2,
  );
}

/// Whether the mailbox works on [day]: [MailboxSettings.workingDays] when it
/// names any, else Monday–Friday — the rule [freeSlotsInRange] skips by.
bool isWorkingDay(MailboxSettings? hours, CalendarDate day) =>
    _workingWeekdays(hours).contains(day.weekday);

/// The walk behind both public calls, over [days] in order.
///
/// With no [notBeforeUtc] it is one chain per day, chronological, stopping
/// once [limit] are found. With one, each day gives two chains: the preferred
/// one seeded at [notBeforeUtc], and the day's ordinary chain cut to the
/// openings that start before it. The earlier ones are kept chronological as
/// found and reversed at the end, which is nearest-first across days too.
/// Once the preferred group is full no later day can change the answer.
List<FreeSlot> _offer({
  required List<(DateTime, DateTime)> busy,
  required List<CalendarDate> days,
  required Duration duration,
  required CalendarZone zone,
  required _WorkingWindow window,
  required int limit,
  required DateTime? notBeforeUtc,
  required DateTime? nowUtc,
  required DateTime? windowStartUtc,
  required DateTime? windowEndUtc,
}) {
  final preferred = <FreeSlot>[];
  final earlier = <FreeSlot>[];
  for (final day in days) {
    final w = _DayWindow.on(
      day: day,
      zone: zone,
      window: window,
      clampStartUtc: windowStartUtc,
      clampEndUtc: windowEndUtc,
    );
    if (w == null) continue;
    List<FreeSlot> chainFrom(DateTime from) => _chain(
          busy: busy,
          from: from,
          window: w,
          duration: duration,
          nowUtc: nowUtc,
        );
    if (notBeforeUtc == null) {
      preferred.addAll(chainFrom(w.start));
    } else {
      earlier.addAll(
          chainFrom(w.start).where((s) => s.startUtc.isBefore(notBeforeUtc)));
      final seed = _alignUp(notBeforeUtc, w.origin);
      preferred.addAll(chainFrom(seed.isAfter(w.start) ? seed : w.start));
    }
    if (preferred.length >= limit) break;
  }
  // An earlier opening that overlaps a preferred one is the same gap offered
  // twice (15:30 and 15:00 for an hour on a clear afternoon), so only the
  // earlier openings that stand apart from every preferred one are kept.
  final picked = preferred.take(limit).toList();
  final apart = earlier.reversed.where((e) => !picked.any((p) =>
      instantsOverlap(e.startUtc, e.endUtc, p.startUtc, p.endUtc)));
  return List.unmodifiable([...picked, ...apart].take(limit));
}

/// The timed events that block an offer, as UTC spans.
List<(DateTime, DateTime)> _busySpans(
  Iterable<CalendarEvent> events,
  bool tentativeBlocks,
) {
  final out = <(DateTime, DateTime)>[];
  for (final event in events) {
    if (event.isAllDay || !_counts(event)) continue;
    final showAs = _showAs(event);
    if (_nonBlockingShowAs.contains(showAs)) continue;
    if (!tentativeBlocks && isTentativeHold(event)) continue;
    final s = event.startUtc;
    final e = event.endUtc;
    if (s == null || e == null) continue;
    out.add((s, e));
  }
  return out;
}

/// The distinct openings of [duration] in [window] from [from] on,
/// chronological: on a hit the walk jumps to the slot's end, rounded up onto
/// the grid.
List<FreeSlot> _chain({
  required List<(DateTime, DateTime)> busy,
  required DateTime from,
  required _DayWindow window,
  required Duration duration,
  required DateTime? nowUtc,
}) {
  final out = <FreeSlot>[];
  var cursor = from;
  while (!cursor.add(duration).isAfter(window.end)) {
    final end = cursor.add(duration);
    if (nowUtc != null && cursor.isBefore(nowUtc)) {
      cursor = cursor.add(_step);
      continue;
    }
    final blocked = busy.any((b) => instantsOverlap(b.$1, b.$2, cursor, end));
    if (blocked) {
      cursor = cursor.add(_step);
      continue;
    }
    out.add(FreeSlot(cursor, end));
    cursor = _alignUp(end, window.origin);
  }
  return out;
}

/// [t] rounded UP to the next quarter-hour step counted from [origin], so a
/// jump past a 20-minute slot lands back on the grid. A [t] at or before
/// [origin] is [origin]: nothing on the grid comes before the window opens.
DateTime _alignUp(DateTime t, DateTime origin) {
  final stepUs = _step.inMicroseconds;
  final offset = t.difference(origin).inMicroseconds;
  if (offset <= 0) return origin;
  final steps = (offset + stepUs - 1) ~/ stepUs;
  return origin.add(Duration(microseconds: steps * stepUs));
}

/// One local day's search window, as UTC instants.
class _DayWindow {
  /// The working window's start: the grid every step is counted from. It is
  /// a local wall time, so the steps land on :00/:15/:30/:45.
  final DateTime origin;

  /// Where the walk may begin: [origin], or a later clamp rounded onto the
  /// grid.
  final DateTime start;

  /// The last instant a slot may end at.
  final DateTime end;

  const _DayWindow(this.origin, this.start, this.end);

  /// The working window on [day], narrowed to `[clampStartUtc,
  /// clampEndUtc)`; null when nothing of it is left.
  static _DayWindow? on({
    required CalendarDate day,
    required CalendarZone zone,
    required _WorkingWindow window,
    required DateTime? clampStartUtc,
    required DateTime? clampEndUtc,
  }) {
    final origin =
        _utc(zone.localDateTime(day, window.start.$1, window.start.$2));
    var end = _utc(zone.localDateTime(day, window.end.$1, window.end.$2));
    var start = origin;
    if (clampStartUtc != null) start = _alignUp(clampStartUtc, origin);
    if (clampEndUtc != null && clampEndUtc.isBefore(end)) {
      end = _utc(clampEndUtc);
    }
    if (!start.isBefore(end)) return null;
    return _DayWindow(origin, start, end);
  }
}

/// A plain UTC [DateTime] for the same instant as [t] (a `TZDateTime` in any
/// zone), so everything the walk hands back has [DateTime.isUtc] true.
DateTime _utc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

/// The working day's start and end as wall-clock (hour, minute) pairs.
class _WorkingWindow {
  final (int, int) start;
  final (int, int) end;

  const _WorkingWindow(this.start, this.end);

  static final RegExp _hhmm =
      RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$');

  /// [hours]' window when both ends parse and the end is after the start;
  /// otherwise the 08:00–18:00 default. A window that wraps midnight (a night
  /// shift) is not representable on one local date and falls back too.
  static _WorkingWindow of(MailboxSettings? hours) {
    const fallback = _WorkingWindow(_defaultStart, _defaultEnd);
    if (hours == null) return fallback;
    final s = _parse(hours.workingStart);
    final e = _parse(hours.workingEnd);
    if (s == null || e == null) return fallback;
    if (e.$1 * 60 + e.$2 <= s.$1 * 60 + s.$2) return fallback;
    return _WorkingWindow(s, e);
  }

  static (int, int)? _parse(String raw) {
    final m = _hhmm.firstMatch(raw.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return null;
    return (h, min);
  }
}

/// ISO weekday numbers (Monday = 1), index + 1.
const List<String> _dayNames = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// The ISO weekdays the mailbox works: [MailboxSettings.workingDays] when it
/// names any day this knows, else Monday–Friday.
Set<int> _workingWeekdays(MailboxSettings? hours) {
  final named = <int>{};
  for (final raw in hours?.workingDays ?? const <String>[]) {
    final i = _dayNames.indexOf(raw.trim().toLowerCase());
    if (i >= 0) named.add(i + 1);
  }
  return named.isEmpty ? const {1, 2, 3, 4, 5} : named;
}
