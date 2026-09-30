import '../../../models/calendar_models.dart';
import '../calendar_zone.dart';
import '../day_items.dart' show formatEventRange, shortDate;
import '../when_resolver.dart';
import 'command_types.dart';

/// Which meeting a command means — "my 3pm", "the design sync with Dana",
/// "tomorrow's standup" — scored against the cached calendar (plan §1.1: the
/// event slot is a KNOWN set, the mirror's meetings, so it is looked up).
///
/// **Where it looks.** A named day (or week) is searched whole, midnight to
/// midnight in the display zone — wider than the resolver's working-hours
/// window, because "Thursday's dinner" is at 19:00. With no day, the next
/// fourteen days from now: a command about a meeting is about one still to
/// come.
///
/// **The score**, additive:
///
/// - **3** when the named clock time is the meeting's local start. A named
///   time is also a filter: a timed meeting that starts at any other time,
///   and every all-day event, is not a candidate at all;
/// - **2** when the named day is the meeting's local day — and **1** when a
///   time was named with no day and the meeting is TODAY (so only ever
///   beside a time match), since "my 3pm" said on a Tuesday is Tuesday's
///   before it is Thursday's;
/// - **2** per named person on its attendee list or organising it;
/// - **1** per subject word the command shares with the meeting's subject
///   (three letters or more, stopwords out, "1:1" and its spellings as one
///   word).
///
/// A meeting that scores nothing is not a candidate. The rest come back best
/// first, and a tie at the top is left for the planner to ask about rather
/// than broken by anything the person did not say.

const Set<String> _stop = {
  'the', 'and', 'with', 'for', 'from', 'about', 'our', 'your', 'my',
  'meeting', 'meetings', 'call', 'calls', 'invite', 'event', 'this', 'that',
  'next', 'last', 'please', 'into', 'onto', 'then', 'them', 'their', 'can',
  'you', 'all',
};

final RegExp _oneOnOne =
    RegExp(r'\b(?:1\s*:\s*1|1\s*-\s*1|1\s*on\s*1|one[\s-]on[\s-]one)\b',
        caseSensitive: false);

/// The words of [text] that can match a subject: lower case, "1:1" folded to
/// one token, plurals left alone (a subject says "reviews" as often as not).
Set<String> subjectTokens(String text) {
  final folded = text.replaceAll(_oneOnOne, ' oneonone ');
  return {
    for (final w in folded.toLowerCase().split(RegExp(r"[^a-z0-9]+")))
      if (w.length >= 3 && !_stop.contains(w)) w,
  };
}

DateTime _utc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

/// The meetings [when], [people] and [subjectWords] could mean, among
/// [events], best first.
///
/// [when] is the REFERENCE when (`ParsedCommand.eventWhen`): for a move, the
/// words that say which meeting, not where it goes.
List<EventCandidate> matchEvents({
  required String subjectWords,
  required WhenResolution when,
  required PeopleMatch people,
  required List<CalendarEvent> events,
  required CalendarZone zone,
  required DateTime now,
}) {
  final nowUtc = now.toUtc();
  final day = when.day;
  final DateTime from;
  final DateTime to;
  if (day != null) {
    from = _utc(zone.localDateTime(day, 0, 0));
    to = _utc(zone.localDateTime((when.rangeEnd ?? day).addDays(1), 0, 0));
  } else {
    from = nowUtc;
    to = nowUtc.add(const Duration(days: 14));
  }
  final lastDay = when.rangeEnd ?? day;
  final wanted = subjectTokens(subjectWords);
  final addresses = {for (final p in people.matched) p.address};

  final out = <EventCandidate>[];
  for (final e in events) {
    if (e.isSeriesMaster || e.isCancelled) continue;
    final CalendarDate? localDay;
    if (e.isAllDay) {
      final s = e.startDate;
      final end = e.endDate;
      if (s == null || end == null) continue;
      final fromDay = zone.dateOf(from);
      final toDay = zone.dateOf(to.subtract(const Duration(microseconds: 1)));
      // [s, end) against [fromDay, toDay], dates only (D13).
      if (s.isAfter(toDay) || !end.isAfter(fromDay)) continue;
      localDay = s;
    } else {
      final s = e.startUtc;
      final end = e.endUtc;
      if (s == null || end == null) continue;
      if (!s.isBefore(to) || !end.isAfter(from)) continue;
      localDay = zone.dateOf(s);
    }

    var score = 0.0;
    final t = when.time;
    if (t != null) {
      // A named clock time is a FILTER before it is a score: "cancel my
      // 3pm" never means the 4 PM call, however well the rest matches, and
      // an all-day event starts at no time at all.
      if (!e.isTimed) continue;
      final local = zone.toLocal(e.startUtc!);
      if (local.hour != t.$1 || local.minute != t.$2) continue;
      score += 3;
    }
    if (day != null) {
      final onDay = !localDay.isBefore(day) &&
          (lastDay == null || !localDay.isAfter(lastDay));
      if (onDay) score += 2;
    } else if (t != null && localDay == when.today) {
      score += 1;
    }
    for (final a in addresses) {
      final onIt = e.organizerAddress.trim().toLowerCase() == a ||
          e.attendees.any((x) => x.address == a);
      if (onIt) score += 2;
    }
    if (wanted.isNotEmpty) {
      final have = subjectTokens(e.subject);
      score += wanted.where(have.contains).length;
    }
    if (score > 0) out.add(EventCandidate(e, score));
  }

  // Best first; then soonest, so a list of equals reads in calendar order.
  DateTime key(CalendarEvent e) =>
      e.startUtc ??
      DateTime.utc(e.startDate!.year, e.startDate!.month, e.startDate!.day);
  out.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byStart = key(a.event).compareTo(key(b.event));
    return byStart != 0 ? byStart : a.event.id.compareTo(b.event.id);
  });
  return List.unmodifiable(out);
}

/// The candidates tied at the top score — one when the match is clear.
List<EventCandidate> topCandidates(List<EventCandidate> candidates) {
  if (candidates.isEmpty) return const [];
  final best = candidates.first.score;
  return [for (final c in candidates) if (c.score == best) c];
}

/// A choice button's label: "Design sync · Thu Oct 8 · 3:00–3:30 PM", or
/// "Offsite · Fri Oct 9 · All day". [today] is accepted for the day words a
/// later caller may want; the date is always spelled out, because two
/// buttons that both said "Today" would be the choice the person is being
/// asked to make.
String eventChoiceLabel(CalendarEvent e, CalendarZone zone, CalendarDate today) {
  final subject = e.subject.trim().isEmpty ? '(no subject)' : e.subject.trim();
  if (e.isAllDay) {
    final s = e.startDate;
    return s == null ? subject : '$subject · ${shortDate(s)} · All day';
  }
  final s = e.startUtc;
  final end = e.endUtc;
  if (s == null || end == null) return subject;
  return '$subject · ${shortDate(zone.dateOf(s))} · '
      '${formatEventRange(zone, s, end)}';
}
