import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../data/calendar_store.dart';
import '../../models/calendar_models.dart';
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';
import '../llm/llm_client.dart' show redactEndpoints;
import 'ask_hints.dart';
import 'calendar_writes.dart' show firstSentence;
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange, shortDate;
import 'overlaps.dart';

/// Find a time on a scheduling thread (docs/pipeline/14-calendar.md "Find a
/// time"): the two windows, the search behind the pane, and the words the
/// pane puts in a reply.
///
/// Pure apart from the one search, which reads the backend (everyone's
/// calendars) or the mirror (the owner's own), and never the clock: the host
/// hands it `now`.

/// Where the search looks: the day the ask named, this week, or next.
enum FindTimeWindow {
  /// The day the ask's own words named ([AskHints.day]) and nothing else.
  /// Offered only when one was read; without one it behaves as [thisWeek].
  theirs,
  thisWeek,
  nextWeek;

  /// The activity row's enum word.
  String get wire => switch (this) {
        FindTimeWindow.theirs => 'theirs',
        FindTimeWindow.thisWeek => 'this_week',
        FindTimeWindow.nextWeek => 'next_week',
      };

  /// The pill's words, and the empty sentence's. [theirs]'s pill says the
  /// day instead — see [findTimeWindowLabel].
  String get label => switch (this) {
        FindTimeWindow.theirs => 'Their day',
        FindTimeWindow.thisWeek => 'This week',
        FindTimeWindow.nextWeek => 'Next week',
      };
}

/// The pill's words for [window]: [FindTimeWindow.theirs] is the day the ask
/// named ("Fri Oct 9"); with a weekday read, the weeks search that weekday
/// and say so ("This Fri", "Next Fri"); without one they keep their labels.
///
/// The label has no clock; the HOST hands it [covers], the day the search
/// would actually cover ([findTimeWindowUtc]'s `firstDay`), and [today]. A
/// week pill reads "This Fri" / "Next Fri" only while [covers] lies in its
/// nominal week (this week's Monday–Sunday, or next week's); once the
/// weekday has rolled past it — this week's Friday gone — it says the DATE
/// it now means ("Fri Oct 23"), so a pill never names a day that has gone.
/// Without them it labels by weekday alone.
String findTimeWindowLabel(
  FindTimeWindow window,
  AskHints? hints, {
  CalendarDate? covers,
  CalendarDate? today,
}) {
  final day = hints?.day;
  if (day == null) return window.label;
  if (window == FindTimeWindow.theirs) return shortDate(day);
  final wd = DateFormat('EEE').format(DateTime(day.year, day.month, day.day));
  if (covers != null && today != null) {
    var monday = today.addDays(1 - today.weekday);
    if (window == FindTimeWindow.nextWeek) monday = monday.addDays(7);
    final inWeek =
        !covers.isBefore(monday) && covers.isBefore(monday.addDays(7));
    if (!inWeek) return shortDate(covers);
  }
  return window == FindTimeWindow.thisWeek ? 'This $wd' : 'Next $wd';
}

/// Every window pill's words for [hints] at [now], each from the day its
/// search would cover — what a host builds once and hands a row or the pane.
Map<FindTimeWindow, String> findTimeWindowLabels(
  AskHints? hints, {
  required DateTime now,
  required CalendarZone zone,
  int durationMinutes = 0,
}) {
  final today = zone.dateOf(now.toUtc());
  return {
    for (final w in findTimeWindows(hints))
      w: findTimeWindowLabel(w, hints,
          covers: findTimeWindowUtc(w,
                  now: now,
                  zone: zone,
                  durationMinutes: durationMinutes,
                  hints: hints)
              .firstDay,
          today: today),
  };
}

/// [weekday] (ISO, Monday = 1) of the week starting [monday], from its
/// components.
CalendarDate weekdayWithin(CalendarDate monday, int weekday) =>
    monday.addDays(weekday - 1);

/// The window pills, in order: the ask's own day first when one was read,
/// then the two weeks.
List<FindTimeWindow> findTimeWindows(AskHints? hints) => [
      if (hints?.day != null) FindTimeWindow.theirs,
      FindTimeWindow.thisWeek,
      FindTimeWindow.nextWeek,
    ];

/// The length pills: 30, 45 and 60, plus the ask's own length (dinner's 90)
/// in its place when it is none of them.
List<int> findTimeDurations(AskHints? hints) {
  final m = hints?.minutes;
  final out = [30, 45, 60];
  if (m != null && m > 0 && !out.contains(m)) out.add(m);
  return out..sort();
}

/// The window an empty answer suggests trying instead of [window].
FindTimeWindow findTimeOtherWindow(FindTimeWindow window) =>
    window == FindTimeWindow.nextWeek
        ? FindTimeWindow.thisWeek
        : window == FindTimeWindow.thisWeek
            ? FindTimeWindow.nextWeek
            : FindTimeWindow.thisWeek;

/// "this week", "next week", or "then" for the ask's own day — how an empty
/// sentence names where it looked.
String findTimeWindowWords(FindTimeWindow window) =>
    window == FindTimeWindow.theirs ? 'then' : window.label.toLowerCase();

/// How many of the people on a `graph` slot are free: the attendees Graph
/// answered for, plus the owner as organiser.
@immutable
class SlotAvailability {
  final int free;
  final int of;

  const SlotAvailability({required this.free, required this.of});

  bool get everyone => free >= of;

  /// The slot's second line in the asks column.
  String get caption => everyone ? 'Everyone free' : '$free of $of free';

  @override
  bool operator ==(Object other) =>
      other is SlotAvailability && other.free == free && other.of == of;

  @override
  int get hashCode => Object.hash(free, of);

  @override
  String toString() => 'SlotAvailability($free of $of)';
}

/// What one search found.
@immutable
class FindTimeResult {
  /// At most three: soonest first from the mirror, and from Graph the ones
  /// the most people are free for ([searchFindTime] says how they rank).
  final List<FreeSlot> slots;

  /// `graph` when everyone's calendars answered, `local` when only the
  /// owner's mirror did (nobody else on the search, or an account that
  /// cannot look others up).
  final String source;

  /// A sentence to show above the slots: why only the owner's calendar was
  /// read, or why nothing could be read at all. Null when there is nothing to
  /// say.
  final String? note;

  /// Each slot's overlaps with the owner's own calendar (the mirror). A
  /// `graph` slot should have none; the mirror can still know better.
  final Map<FreeSlot, Overlaps> overlaps;

  /// The search could not run (a refusal, a missing permission, the
  /// calendar unreachable): [note] says why, and no slots is not "nothing
  /// free", so nothing is tried in its place.
  final bool failed;

  /// Each slot's head count of who is free. Filled for `graph` only: the
  /// mirror knows the owner's calendar and nobody else's, so a `local` slot
  /// has no entry.
  final Map<FreeSlot, SlotAvailability> availability;

  /// How many `find_meeting_times` calls the search made — the activity
  /// row's `graph_calls`. Zero when nobody else was on it; one per hinted
  /// day when the ask's hours were searched over several days.
  final int graphCalls;

  const FindTimeResult({
    this.slots = const [],
    this.source = 'local',
    this.note,
    this.overlaps = const {},
    this.availability = const {},
    this.failed = false,
    this.graphCalls = 0,
  });
}

/// The note when the account cannot read other people's free/busy.
const String findTimeLocalNote =
    "Showing your own free times — your account can't look up others' "
    'calendars.';

/// The note when Graph answered nothing it could stand behind — see
/// [findTimeEmptyFallback].
const String findTimeUnreadableNote =
    "Couldn't read their free time — showing your own free times.";

/// The note when Graph answered, but with nothing inside the ask's own hours
/// (dinner asked, only daytime came back): the owner's own openings in
/// those hours stand in, the unreadable path's shape with its own reason.
const String findTimeOutsideHoursNote =
    'No time inside those hours from their calendar — showing your own '
    'free times.';

/// What an EMPTY `find_meeting_times` answer means, by Graph's
/// `emptySuggestionsReason` ([MeetingTimes.emptyReason], lowercased).
enum FindTimeEmpty {
  /// `attendeesunavailable`: Graph read everyone's calendar and nobody is
  /// free. A true "no time".
  nobodyFree,

  /// Every other word — `attendeesunavailableorunknown`,
  /// `organizerunavailable`, `locationsunavailable`, `unknown` — and none at
  /// all: Graph could not read somebody's free time (an attendee in another
  /// tenant answers nothing), so "nobody is free" would be false. The owner's
  /// own openings stand in, said as such.
  unreadable,
}

/// The ONE rule for an empty answer, which Find a time and the command
/// planner both read. Measured live on 2026-10-02: an attendee outside the
/// owner's tenant made Graph answer zero suggestions for both weeks.
FindTimeEmpty findTimeEmptyFallback(String emptyReason) =>
    emptyReason.trim().toLowerCase() == 'attendeesunavailable'
        ? FindTimeEmpty.nobodyFree
        : FindTimeEmpty.unreadable;

/// The working week's bounds the windows are cut from. Hours are fixed
/// (08:00 to 18:00 local) rather than read from the mailbox: the search
/// itself keeps to working hours, and the window only says which days.
const int _dayStartHour = 8;
const int _dayEndHour = 18;

/// [window] as UTC instants, with the local days it spans.
///
/// **Their day** ([hints] naming a day) is that day alone, from the ask's
/// hours' start (else 08:00) to their end (else 18:00), and from now when it
/// is today. With no day read it is this week.
///
/// With [hints] hours, a week opens on its Monday at their start and closes
/// on its Friday at their end, so Friday's dinner is inside "this week".
///
/// **A week with a weekday read** ([hints] naming a day) means THAT weekday
/// of the week ([weekdayWithin]) at the hours: "dinner on Friday" with Next
/// week is next week's Friday evening, not the week's evenings. This week's
/// instance once gone (past, or today with the hours over) is next week's,
/// as their day rolls, and next week is the one after it. [wholeWeek] asks
/// for the whole Monday–Friday of that weekday's week at the hours instead:
/// the fallback when the weekday offers nothing.
/// **This week** is now until Friday 18:00 local; on a weekend, or once
/// less than [durationMinutes] (at least a minute) is left before Friday
/// 18:00, the week is over and it means the coming Monday 08:00 to Friday
/// 18:00 — a week with no room left for the meeting is not one to search.
/// **Next week** is always the Monday after this week's.
/// Built from [CalendarDate] components with [CalendarZone.localDateTime],
/// never by adding a Duration across midnight, so a DST change inside the
/// week moves nothing.
({DateTime startUtc, DateTime endUtc, CalendarDate firstDay, CalendarDate lastDay})
    findTimeWindowUtc(
  FindTimeWindow window, {
  required DateTime now,
  required CalendarZone zone,
  int durationMinutes = 0,
  AskHints? hints,
  bool wholeWeek = false,
}) {
  final nowUtc = now.toUtc();
  final today = zone.dateOf(nowUtc);
  final h = hints?.hours;
  final (openH, openM) = h == null ? (_dayStartHour, 0) : (h.startHour, h.startMinute);
  final (closeH, closeM) = h == null ? (_dayEndHour, 0) : (h.endHour, h.endMinute);
  final theirDay = hints?.day;
  if (window == FindTimeWindow.theirs && theirDay != null) {
    final opening = zone.localDateTime(theirDay, openH, openM).toUtc();
    final closing = zone.localDateTime(theirDay, closeH, closeM).toUtc();
    return (
      startUtc: nowUtc.isAfter(opening) ? nowUtc : opening,
      endUtc: closing,
      firstDay: theirDay,
      lastDay: theirDay,
    );
  }
  // An instant plus a length is no wall-clock arithmetic: a DST change
  // cannot move it.
  final needed = Duration(minutes: durationMinutes < 1 ? 1 : durationMinutes);
  if (theirDay != null) {
    var day = weekdayWithin(today.addDays(1 - today.weekday), theirDay.weekday);
    final closingToday = zone.localDateTime(day, closeH, closeM).toUtc();
    if (day.isBefore(today) ||
        (day == today && nowUtc.add(needed).isAfter(closingToday))) {
      day = day.addDays(7);
    }
    if (window == FindTimeWindow.nextWeek) day = day.addDays(7);
    final first = wholeWeek ? day.addDays(1 - day.weekday) : day;
    final last = wholeWeek ? first.addDays(4) : day;
    final opening = zone.localDateTime(first, openH, openM).toUtc();
    final closing = zone.localDateTime(last, closeH, closeM).toUtc();
    final start = nowUtc.isAfter(opening) ? nowUtc : opening;
    return (
      startUtc: start,
      endUtc: closing,
      firstDay: wholeWeek ? zone.dateOf(start) : day,
      lastDay: last,
    );
  }
  var monday = today.addDays(1 - today.weekday);
  final fridayEnd =
      zone.localDateTime(monday.addDays(4), closeH, closeM).toUtc();
  final over = today.weekday > DateTime.friday ||
      nowUtc.add(needed).isAfter(fridayEnd);
  if (over) monday = monday.addDays(7);
  if (window == FindTimeWindow.nextWeek) monday = monday.addDays(7);
  final friday = monday.addDays(4);
  final end = zone.localDateTime(friday, closeH, closeM).toUtc();
  final opening = zone.localDateTime(monday, openH, openM).toUtc();
  // This week, while it lasts, starts now; any other starts on its Monday.
  // ([theirs] with no day read is this week.)
  final start = window != FindTimeWindow.nextWeek && !over
      ? (nowUtc.isAfter(opening) ? nowUtc : opening)
      : opening;
  return (
    startUtc: start,
    endUtc: end,
    firstDay: zone.dateOf(start),
    lastDay: friday,
  );
}

/// One search: everyone's calendars when [addresses] names somebody,
/// otherwise — and when the account cannot read others' — the owner's own
/// mirror (`find_meeting_times` refuses an empty list; gotcha 28).
///
/// Graph is asked for five candidates and the best three are kept, ranked by
/// how many people are free (the attendees answering `free`, plus the owner
/// when the organiser's word is `free`), then Graph's own confidence, then
/// the sooner start. Graph's order alone put a slot one person could not make
/// above one everyone could.
///
/// [hints] (the ask's own words, [readAskHints]) narrow it: their hours
/// clamp every day of the owner's own walk and of the window Graph is given,
/// a day they named is not skipped as a weekend, and Graph's
/// `activity_domain` follows the hours and the days searched
/// ([_activityDomain]). Over a window of several days the hours are asked
/// about ONE DAY AT A TIME (at most seven calls, five candidates each, a
/// day already over skipped): one call over a week of evenings starting now
/// got the daytime back, and every candidate fell outside the hours. The
/// days are asked together. A day whose call fails costs only that day (and
/// with nothing found the answer is the unreadable fallback, never "Nobody
/// is free"); every day failing, or a failure every day would share (a
/// missing permission, an account that cannot look others up), is the
/// search failing. With a weekday read, a week searches that weekday
/// ([findTimeWindowUtc]); when it offers nothing, the rest of its week at
/// the same hours is offered under a note saying so — unless the rest of
/// the week is the same window (that weekday is today, and the days before
/// it have gone).
///
/// Never throws: a calendar error is an empty result with its sentence.
Future<FindTimeResult> searchFindTime({
  required CalendarBackend backend,
  required CalendarStore calendar,
  required MailboxSettings? hours,
  required List<String> addresses,
  required int durationMinutes,
  required FindTimeWindow window,
  required DateTime now,
  required CalendarZone zone,
  AskHints? hints,
}) async {
  Future<FindTimeResult> once({bool wholeWeek = false}) => _searchOnce(
        backend: backend,
        calendar: calendar,
        hours: hours,
        addresses: addresses,
        durationMinutes: durationMinutes,
        window: window,
        now: now,
        zone: zone,
        hints: hints,
        wholeWeek: wholeWeek,
      );
  final day = hints?.day;
  final first = await once();
  // A weekend day has no Monday–Friday of its own to fall back on: the
  // working week around a Sunday would be the days BEFORE it.
  if (day == null ||
      window == FindTimeWindow.theirs ||
      day.weekday > DateTime.friday ||
      first.slots.isNotEmpty ||
      first.failed) {
    return first;
  }
  // Friday searched on a Friday: the rest of the week is today alone, the
  // day just searched at the same hours (from now rather than from their
  // opening, which the hours clamp makes the same walk). Asking again would
  // only repeat the answer.
  ({DateTime startUtc, DateTime endUtc, CalendarDate firstDay, CalendarDate lastDay})
      windowOf({bool wholeWeek = false}) => findTimeWindowUtc(window,
          now: now,
          zone: zone,
          durationMinutes: durationMinutes,
          hints: hints,
          wholeWeek: wholeWeek);
  final searched = windowOf();
  final rest = windowOf(wholeWeek: true);
  if (rest.firstDay == searched.firstDay &&
      rest.lastDay == searched.lastDay) {
    return first;
  }
  final week = await once(wholeWeek: true);
  final calls = first.graphCalls + week.graphCalls;
  if (week.slots.isEmpty) {
    return FindTimeResult(
      slots: first.slots,
      source: first.source,
      note: first.note,
      overlaps: first.overlaps,
      availability: first.availability,
      failed: first.failed,
      graphCalls: calls,
    );
  }
  final weekday =
      DateFormat('EEEE').format(DateTime(day.year, day.month, day.day));
  final words = hints?.timeWords;
  final note = 'Nothing free on $weekday${words == null ? '' : ' $words'} '
      'that week — the rest of the week:';
  return FindTimeResult(
    slots: week.slots,
    source: week.source,
    note: week.note == null ? note : '$note ${week.note}',
    overlaps: week.overlaps,
    availability: week.availability,
    graphCalls: calls,
  );
}

Future<FindTimeResult> _searchOnce({
  required CalendarBackend backend,
  required CalendarStore calendar,
  required MailboxSettings? hours,
  required List<String> addresses,
  required int durationMinutes,
  required FindTimeWindow window,
  required DateTime now,
  required CalendarZone zone,
  required AskHints? hints,
  required bool wholeWeek,
}) async {
  final w = findTimeWindowUtc(window,
      now: now,
      zone: zone,
      durationMinutes: durationMinutes,
      hints: hints,
      wholeWeek: wholeWeek);
  List<CalendarEvent> events;
  try {
    events = await calendar.eventsBetween(
      startUtc: zone.localDateTime(w.firstDay, 0, 0).toUtc(),
      endUtc: zone.localDateTime(w.lastDay.addDays(1), 0, 0).toUtc(),
      fromDate: w.firstDay,
      toDateExclusive: w.lastDay.addDays(1),
    );
  } on Object catch (e) {
    debugPrint('find a time: the mirror could not be read: ${e.runtimeType}');
    events = const [];
  }

  // The calls made so far, which every result below reports.
  var graphCalls = 0;

  FindTimeResult withOverlaps(List<FreeSlot> slots, String source,
          {String? note,
          Map<FreeSlot, SlotAvailability> availability = const {}}) =>
      FindTimeResult(
        slots: slots,
        source: source,
        note: note,
        overlaps: {
          for (final s in slots)
            s: findOverlaps(events, s.startUtc, s.endUtc, zone: zone),
        },
        availability: availability,
        graphCalls: graphCalls,
      );

  FindTimeResult local({String? note}) => withOverlaps(
        freeSlotsInRange(
          events: events,
          firstDay: w.firstDay,
          lastDay: w.lastDay,
          durationMinutes: durationMinutes,
          zone: zone,
          hours: hours,
          limit: 3,
          nowUtc: now.toUtc(),
          windowStartUtc: w.startUtc,
          windowEndUtc: w.endUtc,
          dailyHours: hints?.hours,
          // The ask's own weekday is walked whatever the calendar says; a
          // whole week searched under hints still skips its weekend.
          skipNonWorkingDays: hints?.day == null || wholeWeek,
        ),
        'local',
        note: note,
      );

  // Hours that end where they start (a 23:59 clock time) hold no meeting:
  // nothing is offered, and nobody is asked, rather than the working day.
  final h = hints?.hours;
  if (h != null && h.endInMinutes <= h.startInMinutes) {
    return const FindTimeResult();
  }
  // A window that ends where it starts (their hours over today) searches
  // nothing and asks nobody.
  if (!w.endUtc.isAfter(w.startUtc)) return const FindTimeResult();
  if (addresses.isEmpty) return local();
  // One ask of Graph per hinted day over a window of several days, else
  // one over the whole window.
  final asks = h != null && w.firstDay != w.lastDay
      ? _hintedDays(w, h,
          zone: zone,
          durationMinutes: durationMinutes,
          hints: hints,
          hours: hours)
      : [
          (
            startUtc: w.startUtc,
            endUtc: w.endUtc,
            // With the ask's hours Graph still answers across the whole
            // window, so it is asked for more and those outside the hours
            // are dropped below.
            maxCandidates: h == null ? 5 : 20,
            domain: _activityDomain(hints, hours,
                namedDay: hints?.day != null && w.firstDay == w.lastDay
                    ? w.firstDay
                    : null),
          ),
        ];
  // Every hinted day already over: nothing to search, nobody asked.
  if (asks.isEmpty) return local();
  try {
    Future<MeetingTimes> ask(_GraphAsk a) => backend.findMeetingTimes(
          attendees: addresses,
          durationMinutes: durationMinutes,
          windowStartUtc: a.startUtc,
          windowEndUtc: a.endUtc,
          maxCandidates: a.maxCandidates,
          activityDomain: a.domain,
        );
    graphCalls = asks.length;
    // The days are asked together, not one after another (five calls in
    // series were five round trips), each failure caught on its own and the
    // answers kept in day order. One ask throws straight to the handlers.
    final List<_GraphOutcome> outcomes = asks.length == 1
        ? [(answer: await ask(asks.single), error: null, stack: null)]
        : await Future.wait([
            for (final a in asks)
              ask(a).then<_GraphOutcome>(
                (answer) => (answer: answer, error: null, stack: null),
                onError: (Object e, StackTrace st) =>
                    (answer: null, error: e, stack: st),
              ),
          ]);
    final answers = [for (final o in outcomes) ?o.answer];
    final failures = [
      for (final o in outcomes)
        if (o.error case final e?) (error: e, stack: o.stack!),
    ];
    // A failure every day would share — a missing permission, an account
    // that cannot look others up — is the search's own, as one call's
    // would be. Any other day failing costs that day; every day failing is
    // the search failing, through the handlers below.
    for (final f in failures) {
      final e = f.error;
      if (e is CalendarScopeMissing ||
          (e is CalendarRefused && e.code == 'unsupported_account')) {
        Error.throwWithStackTrace(e, f.stack);
      }
    }
    if (answers.isEmpty) {
      Error.throwWithStackTrace(failures.first.error, failures.first.stack);
    }
    final answered = _merged(answers);
    // A day nobody could read is not a day nobody is free: with any day
    // unread and nothing found, the owner's own openings stand in, said as
    // the unreadable fallback, never "Nobody is free".
    if (failures.isNotEmpty && answered.suggestions.isEmpty) {
      return local(note: findTimeUnreadableNote);
    }
    var found = answered;
    if (h != null && answered.suggestions.isNotEmpty) {
      found = MeetingTimes(suggestions: [
        for (final s in answered.suggestions)
          if (_insideHours(s, h, zone)) s,
      ]);
      if (found.suggestions.isEmpty) {
        return local(note: findTimeOutsideHoursNote);
      }
    }
    if (found.suggestions.isEmpty) {
      switch (findTimeEmptyFallback(found.emptyReason)) {
        case FindTimeEmpty.nobodyFree:
          return FindTimeResult(
            source: 'graph',
            note: 'Nobody is free ${findTimeWindowWords(window)} — try '
                '${findTimeOtherWindow(window).label.toLowerCase()}.',
          );
        case FindTimeEmpty.unreadable:
          return local(note: findTimeUnreadableNote);
      }
    }
    final ranked = [
      for (final s in found.suggestions)
        (suggestion: s, availability: _availabilityOf(s, addresses)),
    ]..sort((a, b) {
        final byFree = b.availability.free.compareTo(a.availability.free);
        if (byFree != 0) return byFree;
        final byConfidence =
            b.suggestion.confidence.compareTo(a.suggestion.confidence);
        if (byConfidence != 0) return byConfidence;
        return a.suggestion.startUtc.compareTo(b.suggestion.startUtc);
      });
    final kept = ranked.take(3).toList();
    return withOverlaps(
      [
        for (final k in kept)
          FreeSlot(k.suggestion.startUtc, k.suggestion.endUtc),
      ],
      'graph',
      availability: {
        for (final k in kept)
          FreeSlot(k.suggestion.startUtc, k.suggestion.endUtc): k.availability,
      },
    );
  } on CalendarRefused catch (e) {
    if (e.code == 'unsupported_account') return local(note: findTimeLocalNote);
    final sentence = firstSentence(e.reason);
    return FindTimeResult(
        source: 'graph',
        note: sentence.isEmpty ? e.message : sentence,
        failed: true,
        graphCalls: graphCalls);
  } on CalendarScopeMissing {
    return FindTimeResult(
      source: 'graph',
      note: 'Calendar permission missing — reconnect in Settings.',
      failed: true,
      graphCalls: graphCalls,
    );
  } on CalendarUnavailable catch (e) {
    return FindTimeResult(
        source: 'graph',
        note: e.sentence,
        failed: true,
        graphCalls: graphCalls);
  } on Object catch (e) {
    // The type alone said nothing when a live press failed (2026-10-02):
    // the server's reason, with any endpoint redacted, is what names a bad
    // window, a zone Graph refused or a tenant that will not answer.
    debugPrint('find a time: find_meeting_times failed: ${e.runtimeType}: '
        '${redactEndpoints('$e')}');
    return FindTimeResult(
      source: 'graph',
      note: "Couldn't reach the calendar to find a time.",
      failed: true,
      graphCalls: graphCalls,
    );
  }
}

/// One day's ask answered: its answer, or what it threw.
typedef _GraphOutcome = ({
  MeetingTimes? answer,
  Object? error,
  StackTrace? stack,
});

/// One ask of Graph: its window, how many candidates, and its domain.
typedef _GraphAsk = ({
  DateTime startUtc,
  DateTime endUtc,
  int maxCandidates,
  String domain,
});

/// How many days the ask's hours are asked about one call each, at most.
const int _maxHintedDays = 7;

/// The ask's [h] on each day of [w], one Graph ask per day: from the later
/// of the window's start and that day's opening to the earlier of its end
/// and that day's close, five candidates, and that day's own domain. A day
/// with no room left for [durationMinutes] is skipped. Each day's bounds come
/// from [CalendarZone.localDateTime], so a DST change inside the week moves
/// nothing.
List<_GraphAsk> _hintedDays(
  ({DateTime startUtc, DateTime endUtc, CalendarDate firstDay, CalendarDate lastDay})
      w,
  AskHours h, {
  required CalendarZone zone,
  required int durationMinutes,
  required AskHints? hints,
  required MailboxSettings? hours,
}) {
  final needed = Duration(minutes: durationMinutes < 1 ? 1 : durationMinutes);
  final out = <_GraphAsk>[];
  for (var day = w.firstDay;
      !day.isAfter(w.lastDay) && out.length < _maxHintedDays;
      day = day.addDays(1)) {
    final opening =
        _plainUtc(zone.localDateTime(day, h.startHour, h.startMinute));
    final closing =
        _plainUtc(zone.localDateTime(day, h.endHour, h.endMinute));
    final start = w.startUtc.isAfter(opening) ? w.startUtc : opening;
    final end = w.endUtc.isBefore(closing) ? w.endUtc : closing;
    if (start.add(needed).isAfter(end)) continue;
    out.add((
      startUtc: start,
      endUtc: end,
      maxCandidates: 5,
      // Several days are searched only with no day named (or the rest of
      // its week), whose non-working days the owner's own walk skips too.
      domain: _activityDomain(hints, hours),
    ));
  }
  return out;
}

/// [t] as a plain UTC [DateTime]: a `TZDateTime`'s `==` compares its
/// location too, and the backend seam takes instants.
DateTime _plainUtc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

/// Several days' answers as one: every suggestion once (by its start and
/// end), and, when none came back, `attendeesunavailable` only when every
/// day said so — one day nobody could read is not "nobody is free".
MeetingTimes _merged(List<MeetingTimes> answers) {
  if (answers.length == 1) return answers.single;
  final seen = <(DateTime, DateTime)>{};
  final suggestions = [
    for (final a in answers)
      for (final s in a.suggestions)
        if (seen.add((s.startUtc.toUtc(), s.endUtc.toUtc()))) s,
  ];
  if (suggestions.isNotEmpty) return MeetingTimes(suggestions: suggestions);
  final reasons = [for (final a in answers) a.emptyReason];
  final nobody = reasons.every(
      (r) => findTimeEmptyFallback(r) == FindTimeEmpty.nobodyFree);
  return MeetingTimes(
      emptyReason: nobody
          ? reasons.first
          : reasons.firstWhere(
              (r) => findTimeEmptyFallback(r) != FindTimeEmpty.nobodyFree));
}

/// Who is free for one suggestion, out of the people ASKED plus the owner:
/// each address in [asked] whose word is `free`, plus the owner when the
/// organiser's is. Someone Graph did not answer for counts as not free, and
/// an attendee entry outside [asked] (the owner's own address, say) counts
/// for nothing, so nobody is counted twice.
SlotAvailability _availabilityOf(MeetingTimeSuggestion s, List<String> asked) {
  final words = {
    for (final e in s.attendeeAvailability.entries)
      e.key.trim().toLowerCase(): e.value.toLowerCase(),
  };
  final people = {for (final a in asked) a.trim().toLowerCase()};
  var free = s.organizerAvailability.toLowerCase() == 'free' ? 1 : 0;
  for (final a in people) {
    if (words[a] == 'free') free += 1;
  }
  return SlotAvailability(free: free, of: people.length + 1);
}

/// Graph's `activity_domain` for a search with [hints]. Graph's `personal`
/// is the working hours PLUS the weekend, and only `unrestricted` opens
/// every hour of every day, so: `unrestricted` when the ask's hours leave
/// the mailbox's working window (dinner); `personal` when the search is the
/// ONE day the ask named ([namedDay]: the window's single day, whichever
/// pill asked for it — "This week" with a Saturday read searches that
/// Saturday) and that day is not a working day; `work` (the server's
/// default) otherwise. A window of several days — no day named, or the rest
/// of a week — stays `work`: the owner's own walk skips its non-working
/// days, and Graph must not offer them either.
String _activityDomain(AskHints? hints, MailboxSettings? hours,
    {CalendarDate? namedDay}) {
  final h = hints?.hours;
  if (h != null) {
    final work = workingWindowOf(hours);
    if (h.startInMinutes < work.startInMinutes ||
        h.endInMinutes > work.endInMinutes) {
      return 'unrestricted';
    }
  }
  if (namedDay != null && !isWorkingDay(hours, namedDay)) return 'personal';
  return 'work';
}

/// Whether [s] starts and ends inside [hours] on its own local day.
bool _insideHours(MeetingTimeSuggestion s, AskHours hours, CalendarZone zone) {
  final start = zone.toLocal(s.startUtc.toUtc());
  final end = zone.toLocal(s.endUtc.toUtc());
  final sameDay = start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  final from = start.hour * 60 + start.minute;
  final to = end.hour * 60 + end.minute;
  return sameDay &&
      from >= hours.startInMinutes &&
      to <= hours.endInMinutes;
}

/// "Tue 14 Oct 10:00–10:30 AM PDT": one slot, absolute, with the zone's
/// abbreviation (else its IANA name) — the words go to somebody who may be
/// reading them in another zone.
String findTimeSlotLine(FreeSlot slot, CalendarZone zone) {
  final day = zone.dateOf(slot.startUtc);
  final date = DateFormat('EEE d MMM')
      .format(DateTime(day.year, day.month, day.day));
  final abbreviation =
      zone.toLocal(slot.startUtc.toUtc()).timeZoneName.trim();
  final label = abbreviation.isNotEmpty ? abbreviation : zone.iana;
  return '$date ${formatEventRange(zone, slot.startUtc, slot.endUtc)} $label';
}

/// The one line Put in reply writes: every slot shown, not only one, so the
/// other person can pick.
String findTimeReplyLine(List<FreeSlot> slots, CalendarZone zone) => [
      'Would any of these work?',
      for (final s in slots) findTimeSlotLine(s, zone),
    ].join(' · ');

/// The invite's subject: the thread's, as a reply ("Re: …"), or "Meeting".
String findTimeSubject(String? threadSubject) {
  final s = (threadSubject ?? '').trim();
  if (s.isEmpty) return 'Meeting';
  if (s.toLowerCase().startsWith('re:')) return s;
  return 'Re: $s';
}
