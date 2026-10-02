import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../data/calendar_store.dart';
import '../../models/calendar_models.dart';
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';
import '../llm/llm_client.dart' show redactEndpoints;
import 'calendar_writes.dart' show firstSentence;
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange;
import 'overlaps.dart';

/// Find a time on a scheduling thread (docs/pipeline/14-calendar.md "Find a
/// time"): the two windows, the search behind the pane, and the words the
/// pane puts in a reply.
///
/// Pure apart from the one search, which reads the backend (everyone's
/// calendars) or the mirror (the owner's own), and never the clock: the host
/// hands it `now`.

/// Which week the pane looks in.
enum FindTimeWindow {
  thisWeek,
  nextWeek;

  /// The activity row's enum word.
  String get wire => switch (this) {
        FindTimeWindow.thisWeek => 'this_week',
        FindTimeWindow.nextWeek => 'next_week',
      };

  /// The pill's words, and the empty sentence's.
  String get label => switch (this) {
        FindTimeWindow.thisWeek => 'This week',
        FindTimeWindow.nextWeek => 'Next week',
      };
}

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

  /// Each slot's head count of who is free. Filled for `graph` only: the
  /// mirror knows the owner's calendar and nobody else's, so a `local` slot
  /// has no entry.
  final Map<FreeSlot, SlotAvailability> availability;

  const FindTimeResult({
    this.slots = const [],
    this.source = 'local',
    this.note,
    this.overlaps = const {},
    this.availability = const {},
  });
}

/// The note when the account cannot read other people's free/busy.
const String findTimeLocalNote =
    "Showing your own free times — your account can't look up others' "
    'calendars.';

/// The working week's bounds the windows are cut from. Hours are fixed
/// (08:00 to 18:00 local) rather than read from the mailbox: the search
/// itself keeps to working hours, and the window only says which days.
const int _dayStartHour = 8;
const int _dayEndHour = 18;

/// [window] as UTC instants, with the local days it spans.
///
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
}) {
  final nowUtc = now.toUtc();
  final today = zone.dateOf(nowUtc);
  var monday = today.addDays(1 - today.weekday);
  final fridayEnd =
      zone.localDateTime(monday.addDays(4), _dayEndHour, 0).toUtc();
  // An instant plus a length is no wall-clock arithmetic: a DST change
  // cannot move it.
  final needed = Duration(minutes: durationMinutes < 1 ? 1 : durationMinutes);
  final over = today.weekday > DateTime.friday ||
      nowUtc.add(needed).isAfter(fridayEnd);
  if (over) monday = monday.addDays(7);
  if (window == FindTimeWindow.nextWeek) monday = monday.addDays(7);
  final friday = monday.addDays(4);
  final end = zone.localDateTime(friday, _dayEndHour, 0).toUtc();
  final opening = zone.localDateTime(monday, _dayStartHour, 0).toUtc();
  // This week, while it lasts, starts now; any other starts on its Monday.
  final start = window == FindTimeWindow.thisWeek && !over
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
}) async {
  final w = findTimeWindowUtc(window,
      now: now, zone: zone, durationMinutes: durationMinutes);
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
        ),
        'local',
        note: note,
      );

  if (addresses.isEmpty) return local();
  if (!w.endUtc.isAfter(w.startUtc)) return const FindTimeResult();
  try {
    final found = await backend.findMeetingTimes(
      attendees: addresses,
      durationMinutes: durationMinutes,
      windowStartUtc: w.startUtc,
      windowEndUtc: w.endUtc,
      maxCandidates: 5,
    );
    final ranked = [
      for (final s in found)
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
        source: 'graph', note: sentence.isEmpty ? e.message : sentence);
  } on CalendarScopeMissing {
    return const FindTimeResult(
      source: 'graph',
      note: 'Calendar permission missing — reconnect in Settings.',
    );
  } on CalendarUnavailable catch (e) {
    return FindTimeResult(source: 'graph', note: e.sentence);
  } on Object catch (e) {
    // The type alone said nothing when a live press failed (2026-10-02):
    // the server's reason, with any endpoint redacted, is what names a bad
    // window, a zone Graph refused or a tenant that will not answer.
    debugPrint('find a time: find_meeting_times failed: ${e.runtimeType}: '
        '${redactEndpoints('$e')}');
    return const FindTimeResult(
      source: 'graph',
      note: "Couldn't reach the calendar to find a time.",
    );
  }
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
