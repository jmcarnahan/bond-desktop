import 'package:flutter/foundation.dart' show immutable;

import '../../models/calendar_models.dart';
import 'calendar_zone.dart';

/// Reading "when" out of a calendar command: "tomorrow morning", "fri
/// 2-2:30", "30 min next week".
///
/// The `when` and `duration` slots of the command bar (plan §1.1) are a small,
/// closed grammar, so they are resolved here in pure Dart and never by a
/// model: a model asked for a date computes it, and a computed date is wrong
/// for someone every time the week wraps or the clocks change. The generative
/// fallback only ever hands back COPIED phrases, which come through this same
/// resolver.
///
/// Three promises shape everything below:
///
/// - **Never invent a time.** "Thursday" is a day with no time; the planner
///   proposes free slots rather than this file picking 9:00. A part of day
///   ("afternoon") is a window, not a time.
/// - **The anchor is the person's local day.** `now` is read through the
///   display zone first, so at 5:30 PM in Los Angeles "tomorrow" is still
///   tomorrow there, not the day after (UTC has already rolled over).
/// - **Local datetimes are built from components** with
///   [CalendarZone.localDateTime] and converted to UTC last. Nothing adds a
///   [Duration] to a local wall time, because a day is not always 24 hours.
///
/// Like `deadline_parse.dart` it is pure and takes `now` as an argument: a
/// parser that read the clock could not be tested, since every expected
/// answer would move with the calendar.
///
/// Every phrase consumed is recorded as a [WhenSpan] with its [WhenKind], so
/// the command parser can take the leftover words as the subject, and can
/// tell "my 3pm" (which meeting) from "to 4pm" (where it goes) by position.

/// Whether the text books something or asks about the calendar. The one rule
/// it changes is the bare weekday on its own day (see [resolveWhen]).
enum WhenMode { booking, question }

/// A part of the day: a window, never a time.
///
/// `lunch` is an addition to the plan's four parts: "over lunch" is common in
/// scheduling asks and names a window as surely as "afternoon" does.
enum DayPart { morning, afternoon, evening, endOfDay, lunch }

/// The wall-clock bounds of each [DayPart] on the day it falls on.
extension DayPartBounds on DayPart {
  /// Start, as (hour, minute).
  (int, int) get start => switch (this) {
        DayPart.morning => (9, 0),
        DayPart.afternoon => (12, 0),
        DayPart.evening => (17, 0),
        // "End of day" is the last working hour before a 17:00 close — a
        // window to land something in, not a promise of 17:00 sharp.
        DayPart.endOfDay => (16, 0),
        DayPart.lunch => (12, 0),
      };

  /// End (exclusive), as (hour, minute).
  (int, int) get end => switch (this) {
        DayPart.morning => (12, 0),
        DayPart.afternoon => (17, 0),
        DayPart.evening => (20, 0),
        DayPart.endOfDay => (17, 0),
        DayPart.lunch => (13, 0),
      };
}

/// What a consumed phrase was.
enum WhenKind {
  /// A day: "today", "tonight", "Tuesday", "next Fri", "Oct 14", "10/14".
  day,

  /// "this week", "next week".
  week,

  /// One clock time: "3pm", "at 3", "15:00", "noon".
  time,

  /// A clock range: "2-3pm", "from 2 to 3".
  range,

  /// A part of the day: "morning", "EOD", "lunch".
  part,

  /// A length: "30 min", "an hour", "for 1.5h".
  duration,
}

/// A character range `[start, end)` of the input that a when or duration
/// expression consumed, and what it was.
@immutable
class WhenSpan {
  final int start;
  final int end;
  final WhenKind kind;

  const WhenSpan(this.start, this.end, this.kind);

  /// The consumed phrase itself.
  String textIn(String input) => input.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is WhenSpan &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => 'WhenSpan($start, $end, ${kind.name})';
}

/// Everything [resolveWhen] could read. Every field is independently
/// optional; an input with no when-words is [isEmpty].
///
/// The zone the text was resolved in is STORED ([zone]) rather than passed to
/// [startUtc]/[windowUtc]: the day was chosen in that zone ("today" there),
/// and turning it into instants through any other zone would be a bug, so the
/// API does not offer the chance.
///
/// When the text names several days or times, the LAST of each wins: a move
/// reads "move Monday's standup to Tuesday", and the target comes last. The
/// earlier phrases are still in [spans] with their kinds. A time and a part
/// that contradict each other ("my 3pm … to tomorrow morning") keep only the
/// later one, for the same reason.
@immutable
class WhenResolution {
  /// Every consumed phrase, in text order.
  final List<WhenSpan> spans;

  /// The resolved local date, or null (none named, or [unresolvedReason]).
  final CalendarDate? day;

  /// For "this week"/"next week": the inclusive last day (a Friday).
  final CalendarDate? rangeEnd;

  /// An explicit start time on the wall clock.
  final (int hour, int minute)? time;

  /// An explicit range end ("2-3pm"). May be at or before [time] only for a
  /// range that runs past midnight ("10pm-1am").
  final (int hour, int minute)? endTime;

  final DayPart? part;

  final Duration? duration;

  /// True exactly when [time] is set. A part of day never sets it.
  final bool explicitTime;

  /// Why a day phrase could not be resolved ("this Monday has passed"). Set
  /// INSTEAD of rolling the date forward: the person said "this", and quietly
  /// booking next week's would be a different meeting.
  final String? unresolvedReason;

  /// The person's local date when the text was read. A time with no day
  /// ("at 3") leaves [day] null — whether that means today, or names a
  /// meeting, is the caller's call — and this is what the caller anchors to.
  final CalendarDate today;

  /// The zone [day] and [time] are wall-clock values in.
  final CalendarZone zone;

  const WhenResolution({
    required this.today,
    required this.zone,
    this.spans = const [],
    this.day,
    this.rangeEnd,
    this.time,
    this.endTime,
    this.part,
    this.duration,
    this.explicitTime = false,
    this.unresolvedReason,
  });

  /// Nothing in the text was a when or duration phrase.
  bool get isEmpty => spans.isEmpty;

  /// The explicit start instant: [day] at [time], or null without both.
  ///
  /// On a spring-forward day a wall time the clocks skip (02:30 in Los
  /// Angeles on 2026-03-08) does not throw: the `timezone` package resolves
  /// it FORWARD by the gap (02:30 → 03:30 PDT). A repeated wall time on a
  /// fall-back day resolves to its first occurrence (the daylight one).
  DateTime? get startUtc {
    final d = day;
    final t = time;
    if (d == null || t == null) return null;
    return _utc(zone.localDateTime(d, t.$1, t.$2));
  }

  /// The local window this resolution names, as UTC instants, or null when
  /// there is no day.
  ///
  /// - a week range → the first day 00:00 to the day after [rangeEnd] 00:00
  ///   (for "next week": Monday 00:00 to Saturday 00:00);
  /// - an explicit [time] → from it to [endTime], else to [time] + [duration],
  ///   else 30 minutes;
  /// - a [part] → the part's bounds on [day];
  /// - a day alone → the 08:00–18:00 working day.
  ///
  /// A week range wins over a time or part in the same text ("afternoons
  /// next week" is a range to search, and the caller filters by part).
  (DateTime, DateTime)? get windowUtc {
    final d = day;
    if (d == null) return null;
    final re = rangeEnd;
    if (re != null) {
      return (
        _utc(zone.localDateTime(d, 0, 0)),
        _utc(zone.localDateTime(re.addDays(1), 0, 0)),
      );
    }
    final t = time;
    if (t != null) {
      final start = _utc(zone.localDateTime(d, t.$1, t.$2));
      final et = endTime;
      if (et != null) {
        final nominal = _minutes(et) - _minutes(t);
        // A range that runs past midnight ends on the next local date.
        final endDay = nominal > 0 ? d : d.addDays(1);
        var end = _utc(zone.localDateTime(endDay, et.$1, et.$2));
        // A DST gap can swallow a short range ("2-3am" on a spring-forward
        // night builds 03:00 PDT for both ends). Keep the start and give the
        // range its nominal length rather than a zero-length window.
        if (!end.isAfter(start)) {
          end = start.add(
              Duration(minutes: nominal > 0 ? nominal : nominal + 24 * 60));
        }
        return (start, end);
      }
      // Adding a Duration to an INSTANT is correct: a 90-minute meeting is
      // ninety real minutes whatever the wall clock does meanwhile.
      return (start, start.add(duration ?? const Duration(minutes: 30)));
    }
    final p = part;
    if (p != null) {
      return (
        _utc(zone.localDateTime(d, p.start.$1, p.start.$2)),
        _utc(zone.localDateTime(d, p.end.$1, p.end.$2)),
      );
    }
    return (
      _utc(zone.localDateTime(d, 8, 0)),
      _utc(zone.localDateTime(d, 18, 0)),
    );
  }

  @override
  String toString() => 'WhenResolution(day: $day, rangeEnd: $rangeEnd, '
      'time: $time, endTime: $endTime, part: $part, duration: $duration, '
      'unresolved: $unresolvedReason, spans: $spans)';
}

int _minutes((int, int) t) => t.$1 * 60 + t.$2;

DateTime _utc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

// ---------------------------------------------------------------------------
// Durations
// ---------------------------------------------------------------------------

/// Nothing glued on the left of a number: not a digit, a letter, a colon or a
/// decimal point, so "1:30" is not "30 minutes" and "v2h" is nothing.
const String _nb = r'(?<![\w.:])';

const String _hourUnit = r'(?:h|hrs?|hours?)';
const String _minuteUnit = r'(?:m|mins?|minutes?)';

const Map<String, int> _numberWords = {
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'ten': 10,
  'fifteen': 15,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fortyfive': 45,
  'fifty': 50,
  'ninety': 90,
};

/// Each duration grammar with how to read its match, most specific first: "1h
/// 30m" before "1h", "an hour and a half" before "an hour".
final List<(RegExp, Duration? Function(RegExpMatch))> _durationRules = [
  (
    RegExp('$_nb(?:for\\s+)?(\\d+)\\s*$_hourUnit\\s*(?:and\\s+)?(\\d{1,2})\\s*$_minuteUnit\\b',
        caseSensitive: false),
    (m) => Duration(
        hours: int.parse(m.group(1)!), minutes: int.parse(m.group(2)!)),
  ),
  (
    RegExp('$_nb(?:for\\s+)?(?:an?|one)\\s+hour\\s+and\\s+a\\s+half\\b',
        caseSensitive: false),
    (_) => const Duration(minutes: 90),
  ),
  (
    RegExp('$_nb(?:for\\s+)?(?:a\\s+)?half\\s+(?:an?\\s+)?hour\\b',
        caseSensitive: false),
    (_) => const Duration(minutes: 30),
  ),
  (
    RegExp('$_nb(?:for\\s+)?(\\d+(?:\\.\\d+)?)\\s*$_hourUnit\\b',
        caseSensitive: false),
    (m) => Duration(minutes: (double.parse(m.group(1)!) * 60).round()),
  ),
  (
    RegExp('$_nb(?:for\\s+)?(\\d+)\\s*$_minuteUnit\\b', caseSensitive: false),
    (m) => Duration(minutes: int.parse(m.group(1)!)),
  ),
  (
    RegExp(
        '$_nb(?:for\\s+)?(an?|one|two|three|four|five|six|ten|fifteen|twenty|thirty|forty[\\s-]?five|forty|fifty|ninety)\\s+(hours?|hrs?|minutes?|mins?)\\b',
        caseSensitive: false),
    (m) {
      final word = m.group(1)!.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
      final n = _numberWords[word];
      if (n == null) return null;
      final unit = m.group(2)!.toLowerCase();
      return unit.startsWith('h') ? Duration(hours: n) : Duration(minutes: n);
    },
  ),
];

/// The first length named in [text] ("30 min", "an hour", "1.5h", "for 20
/// minutes"), or null when it names none.
Duration? parseDuration(String text) {
  final claims = _Claims(text.length);
  final found = _durations(text, claims);
  if (found.isEmpty) return null;
  found.sort((a, b) => a.$1.start.compareTo(b.$1.start));
  return found.first.$2;
}

/// [text] when it is nothing but one length ("an hour", "30 min", "for 20
/// minutes"), else null: "by an hour" is a shift, "an hour" alone is a
/// length, and a move reads the two apart with this.
Duration? wholeDuration(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final found = _durations(t, _Claims(t.length));
  if (found.length != 1) return null;
  final (span, d) = found.single;
  return span.start == 0 && span.end == t.length ? d : null;
}

List<(WhenSpan, Duration)> _durations(String text, _Claims claims) {
  final out = <(WhenSpan, Duration)>[];
  for (final (re, read) in _durationRules) {
    for (final m in re.allMatches(text)) {
      if (!claims.free(m.start, m.end)) continue;
      final d = read(m);
      if (d == null || d <= Duration.zero) continue;
      claims.claim(m.start, m.end);
      out.add((WhenSpan(m.start, m.end, WhenKind.duration), d));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Days
// ---------------------------------------------------------------------------

const String _monthAlt = r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';

int _monthOf(String word) => const {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    }[word.toLowerCase().substring(0, 3)]!;

/// `2026-10-14`.
final RegExp _isoDate =
    RegExp(r'(?<![\d/-])(\d{4})-(\d{2})-(\d{2})(?!\d)');

/// `14 Oct`, `14th of October`, `14 Oct 2027`. Tried BEFORE [_monthFirst]
/// (as in `deadline_parse.dart`), or `5 Jan 2027` would read as `Jan 20`.
/// "May" is also a verb, so a day-first May needs an ordinal or "of" ("3rd
/// May", "the 3rd of May"): "Thursday at 3 may work" names no date. See
/// [_dayFirstMayOk].
final RegExp _dayFirst = RegExp(
    '(?<![\\w.:/])(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?$_monthAlt\\.?(?![a-z])(?:,?\\s+(\\d{4})(?!\\d))?',
    caseSensitive: false);

/// A day-first match that may stand when its month is May: the number
/// carries an ordinal or is followed by "of".
final RegExp _dayFirstMayOk =
    RegExp(r'^\d{1,2}(?:st|nd|rd|th|\s+of\b)', caseSensitive: false);

/// `Oct 14`, `October 14th`, `Oct 14, 2027`. The lookaheads keep `May 3pm`
/// from reading as May 3rd and `Oct 1:30` from reading as Oct 1.
final RegExp _monthFirst = RegExp(
    '(?<![a-z])$_monthAlt\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?![a-z\\d:])(?!\\s*[ap]\\.?m\\b)(?:,?\\s+(\\d{4})(?!\\d))?',
    caseSensitive: false);

/// `10/14`, `10/14/2026`, `10/14/26` — US month/day.
final RegExp _slashDate = RegExp(
    r'(?<![\d/.:])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])');

/// "day after tomorrow" is listed first so "tomorrow" never claims its tail.
final RegExp _relativeDay = RegExp(
    r'\b(?:(?:the\s+)?day\s+after\s+(?:tomorrow|tmrw)|today|tonight|tomorrow|tmrw)\b',
    caseSensitive: false);

final RegExp _weekPhrase =
    RegExp(r'\b(this|next)\s+week\b', caseSensitive: false);

/// What may sit between a weekday and the week phrase that refines it:
/// nothing, "of" ("Tuesday of next week") or a comma ("next week, Tuesday").
final RegExp _weekJoin =
    RegExp(r'^[\s,]*(?:of[\s,]*)?$', caseSensitive: false);

/// A weekday, optionally with `on` and `this`/`next`. The trailing `\b` is
/// what keeps a plural out: "Mondays report" is a habit, not a date — `monday`
/// is followed by `s`, and no shorter alternative ends on a word boundary.
final RegExp _weekday = RegExp(
    r'\b(?:on\s+)?(?:(this|next)\s+)?(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s|nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b',
    caseSensitive: false);

/// Abbreviations that are also common words ("I sat", "the sun", "she
/// weds"; "mon" is slang). Each counts as a weekday only in a weekday's
/// context: [_weekdayLeadIn] before it, or [_weekdayLeadOut] after it. Full
/// names and the other abbreviations ("tue", "thurs", "fri") need neither.
const Set<String> _guardedWeekdays = {'sat', 'sun', 'mon', 'wed', 'weds'};

/// A word before a guarded abbreviation that makes it a day. "on", "this" and
/// "next" usually sit inside the weekday match itself; the rest do not.
final RegExp _weekdayLeadIn = RegExp(
    r'\b(?:on|next|this|by|until|till|before|after|every|from)\s+$',
    caseSensitive: false);

/// What after a guarded abbreviation makes it a day: the end of the text or
/// punctuation, a time ("sun 3pm", "sat at 10", "sun noon"), a date ("sat
/// 10/17", "sat Oct 17"), a part of the day, or a week phrase.
final RegExp _weekdayLeadOut = RegExp(
    r'^(?:\s*$|\s*[.,;:!?)]|\s*(?:at\s+|@\s*)?\d|'
    r'\s+(?:noon|midday|midnight|morning|afternoon|evening|night|'
    r'(?:this|next)\s+week)\b|'
    '\\s+$_monthAlt(?![a-z]))',
    caseSensitive: false);

int _weekdayOf(String word) => const {
      'mon': 1,
      'tue': 2,
      'wed': 3,
      'thu': 4,
      'fri': 5,
      'sat': 6,
      'sun': 7,
    }[word.toLowerCase().substring(0, 3)]!;

const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// A day phrase, resolved or not, and where it sat in the text.
class _DayMention {
  final int pos;
  final CalendarDate? day;
  final CalendarDate? rangeEnd;
  final String? reason;

  /// "this morning" implies today, but only when nothing else names a day.
  final bool weak;

  /// Set for a week phrase: 'this' or 'next'.
  final String? week;

  /// Set for a BARE weekday (no this/next), which a week phrase refines.
  final int? bareWeekday;

  /// "tonight": a midnight named with it is the NEXT date's 00:00.
  final bool tonight;

  const _DayMention(
    this.pos, {
    this.day,
    this.rangeEnd,
    this.reason,
    this.weak = false,
    this.week,
    this.bareWeekday,
    this.tonight = false,
  });
}

/// The calendar day, or null when there is no such day. `DateTime` rolls an
/// impossible date forward (Feb 30 → Mar 2); a date that quietly moved is
/// worse than none.
CalendarDate? _civil(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final t = DateTime.utc(y, m, d);
  return t.month == m ? CalendarDate(y, m, d) : null;
}

/// A day named without a year. Booking looks FORWARD (an Oct 2 booked on
/// Oct 14 is next year's); a question keeps this year ("was I free on Oct
/// 2?" asks about the one just gone).
CalendarDate? _yearless(int m, int d, CalendarDate today, WhenMode mode) {
  final thisYear = _civil(today.year, m, d);
  if (mode == WhenMode.question) return thisYear;
  if (thisYear != null && !thisYear.isBefore(today)) return thisYear;
  return _civil(today.year + 1, m, d);
}

/// The next [weekday] STRICTLY after [today] (1..7 days ahead).
CalendarDate _nextStrict(CalendarDate today, int weekday) {
  var delta = (weekday - today.weekday + 7) % 7;
  if (delta == 0) delta = 7;
  return today.addDays(delta);
}

/// Monday of [today]'s ISO week.
CalendarDate _mondayOf(CalendarDate today) => today.addDays(1 - today.weekday);

/// "this `<weekday>`": this ISO week's occurrence, or a reason when it has
/// passed. Never rolled forward.
_DayMention _thisWeekday(int pos, CalendarDate today, int weekday) {
  final target = _mondayOf(today).addDays(weekday - 1);
  if (target.isBefore(today)) {
    return _DayMention(pos,
        reason: 'this ${_weekdayNames[weekday - 1]} has passed');
  }
  return _DayMention(pos, day: target);
}

List<(WhenSpan, _DayMention)> _days(
  String text,
  _Claims claims,
  CalendarDate today,
  WhenMode mode,
) {
  final out = <(WhenSpan, _DayMention)>[];

  void take(RegExp re, _DayMention? Function(RegExpMatch) read) {
    for (final m in re.allMatches(text)) {
      if (!claims.free(m.start, m.end)) continue;
      final mention = read(m);
      if (mention == null) continue;
      claims.claim(m.start, m.end);
      final kind = mention.week != null ? WhenKind.week : WhenKind.day;
      out.add((WhenSpan(m.start, m.end, kind), mention));
    }
  }

  int? year(String? raw) {
    if (raw == null) return null;
    final y = int.parse(raw);
    return raw.length == 2 ? 2000 + y : y;
  }

  _DayMention? dated(int pos, int m, int d, int? y) {
    final day = y == null ? _yearless(m, d, today, mode) : _civil(y, m, d);
    return day == null ? null : _DayMention(pos, day: day);
  }

  take(_isoDate, (m) {
    final day = _civil(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!));
    return day == null ? null : _DayMention(m.start, day: day);
  });
  take(_dayFirst, (m) {
    final month = _monthOf(m.group(2)!);
    if (month == 5 && !_dayFirstMayOk.hasMatch(m.group(0)!)) return null;
    return dated(m.start, month, int.parse(m.group(1)!), year(m.group(3)));
  });
  take(
      _monthFirst,
      (m) => dated(m.start, _monthOf(m.group(1)!), int.parse(m.group(2)!),
          year(m.group(3))));
  take(
      _slashDate,
      (m) => dated(m.start, int.parse(m.group(1)!), int.parse(m.group(2)!),
          year(m.group(3))));
  take(_relativeDay, (m) {
    final word = m.group(0)!.toLowerCase();
    if (word.contains('after')) {
      return _DayMention(m.start, day: today.addDays(2));
    }
    if (word == 'today' || word == 'tonight') {
      return _DayMention(m.start, day: today, tonight: word == 'tonight');
    }
    return _DayMention(m.start, day: today.addDays(1));
  });
  take(_weekPhrase, (m) {
    final which = m.group(1)!.toLowerCase();
    if (which == 'next') {
      final monday = _mondayOf(today).addDays(7);
      return _DayMention(m.start,
          day: monday, rangeEnd: monday.addDays(4), week: 'next');
    }
    if (today.weekday > 5) {
      return _DayMention(m.start,
          reason: "this week's working days have passed", week: 'this');
    }
    return _DayMention(m.start,
        day: today, rangeEnd: _mondayOf(today).addDays(4), week: 'this');
  });
  take(_weekday, (m) {
    final qualifier = m.group(1)?.toLowerCase();
    final word = m.group(2)!.toLowerCase();
    if (qualifier == null &&
        _guardedWeekdays.contains(word) &&
        !m.group(0)!.toLowerCase().startsWith(RegExp(r'on\s')) &&
        !_weekdayLeadIn.hasMatch(text.substring(0, m.start)) &&
        !_weekdayLeadOut.hasMatch(text.substring(m.end))) {
      return null;
    }
    final wd = _weekdayOf(word);
    if (qualifier == 'this') return _thisWeekday(m.start, today, wd);
    if (qualifier == 'next' || mode == WhenMode.booking) {
      return _DayMention(m.start,
          day: _nextStrict(today, wd), bareWeekday: qualifier == null ? wd : null);
    }
    // Question mode, bare: "am I free Wednesday?" asked on a Wednesday means
    // today.
    final day = today.weekday == wd ? today : _nextStrict(today, wd);
    return _DayMention(m.start, day: day, bareWeekday: wd);
  });
  return out;
}

// ---------------------------------------------------------------------------
// Parts of the day
// ---------------------------------------------------------------------------

final RegExp _partPhrase = RegExp(
    r'\b(?:(this|in\s+the|the|over)\s+)?(morning|afternoon|evening|end\s+of\s+(?:the\s+)?day|eod|lunch\s*time|lunch)\b',
    caseSensitive: false);

DayPart _partOf(String word) {
  final w = word.toLowerCase();
  if (w.startsWith('morning')) return DayPart.morning;
  if (w.startsWith('afternoon')) return DayPart.afternoon;
  if (w.startsWith('evening')) return DayPart.evening;
  if (w.startsWith('lunch')) return DayPart.lunch;
  return DayPart.endOfDay;
}

/// Loose bounds, in minutes, a clock time may fall in and still AGREE with a
/// part ("9:30 tomorrow morning"). Wider than the part windows on purpose:
/// "7am tomorrow morning" agrees. A time outside them contradicts the part.
(int, int) _looseBounds(DayPart p) => switch (p) {
      DayPart.morning => (5 * 60, 12 * 60),
      DayPart.afternoon => (12 * 60, 18 * 60),
      DayPart.evening => (17 * 60, 24 * 60),
      DayPart.endOfDay => (15 * 60, 18 * 60),
      DayPart.lunch => (11 * 60, 14 * 60),
    };

// ---------------------------------------------------------------------------
// Clock times
// ---------------------------------------------------------------------------

const String _meridiem = r'([ap]\.?m\.?)';

/// A clock time as written, before daytime-first reading.
class _RawTime {
  final int hour;
  final int minute;

  /// 'am' / 'pm', or null.
  final String? meridiem;

  /// Written as a 24-hour time: an hour of 0 or 13–23, or a two-digit hour
  /// with a leading zero ("09:30").
  final bool literal24;

  const _RawTime(this.hour, this.minute, this.meridiem, this.literal24);

  bool get bare => meridiem == null && !literal24;

  static _RawTime? read(String hourText, String? minuteText, String? mer) {
    final h = int.parse(hourText);
    final m = minuteText == null ? 0 : int.parse(minuteText);
    final meridiem = mer?.toLowerCase().replaceAll('.', '');
    if (meridiem != null) {
      if (h < 1 || h > 12) return null;
      return _RawTime(h, m, meridiem, false);
    }
    if (h > 23) return null;
    final literal24 =
        h == 0 || h >= 13 || (hourText.length == 2 && hourText[0] == '0');
    return _RawTime(h, m, null, literal24);
  }

  /// The hour on a 24-hour clock under [mer] ('am'/'pm').
  static int withMeridiem(int h, String mer) =>
      mer == 'am' ? (h == 12 ? 0 : h) : (h == 12 ? 12 : h + 12);

  /// Resolved to a wall time.
  ///
  /// An explicit am/pm or a 24-hour form wins. A BARE hour is daytime-first
  /// — 1–6 is PM, 7–11 AM, 12 noon — because nobody books a 3 AM, and "at 3"
  /// means the afternoon. A part of day in the same text overrides that for
  /// hours 1–11: "tonight at 8" is 20:00 and "tomorrow morning at 6" is 06:00.
  (int, int) resolve(DayPart? part) {
    if (meridiem != null) return (withMeridiem(hour, meridiem!), minute);
    if (literal24) return (hour, minute);
    if (part != null && hour >= 1 && hour <= 11) {
      switch (part) {
        case DayPart.morning:
          return (hour, minute);
        case DayPart.afternoon:
        case DayPart.evening:
        case DayPart.endOfDay:
          return (hour + 12, minute);
        case DayPart.lunch:
          break;
      }
    }
    if (hour >= 1 && hour <= 6) return (hour + 12, minute);
    return (hour, minute);
  }
}

/// `2-3pm`, `2–3pm`, `from 2 to 3`, `2pm to 3:30pm`, `10-10:30`, `between 1
/// and 2`. Without from/between, minutes or an am/pm it is not a time range
/// ("2-3 people"), and the match is refused.
final RegExp _range = RegExp(
    '(?<![\\w:./-])(?:(from|between)\\s+)?(\\d{1,2})(?::([0-5]\\d))?\\s*$_meridiem?\\s*(-|–|—|to|until|till|and)\\s*(\\d{1,2})(?::([0-5]\\d))?(?:\\s*$_meridiem)?(?![\\w:/])',
    caseSensitive: false);

/// The text before a range ends in a possessive ("my", "the", …).
final RegExp _possessiveBefore = RegExp(
    r'\b(?:my|the|our|your|his|her|their)\s+$',
    caseSensitive: false);

/// A verb that moves a meeting: "move 3pm to 4pm" names a meeting and then
/// where it goes, exactly as "move my 3pm to 4pm" does.
final RegExp _moveVerb = RegExp(
    r'\b(?:move[ds]?|moving|push(?:e[ds])?|pushing|reschedul(?:e[ds]?|ing)|'
    r'shift(?:ed|s|ing)?|bump(?:ed|s|ing)?|chang(?:e[ds]?|ing)|'
    r'switch(?:e[ds])?|switching)\b',
    caseSensitive: false);

/// Where a clause ends: a move verb in an earlier sentence moves nothing
/// here.
final RegExp _clauseBreak = RegExp(r'[;!?\n]|\.(?=\s)');

/// The clause of [text] that ends at [end]: everything since the last
/// [_clauseBreak] before it.
String _clauseBefore(String text, int end) {
  final before = text.substring(0, end);
  var start = 0;
  for (final m in _clauseBreak.allMatches(before)) {
    start = m.end;
  }
  return before.substring(start);
}

/// `noon`, `12 noon`, `midnight`, `midday`, with an optional `at`.
final RegExp _namedTime = RegExp(
    r'\b(?:at\s+)?(?:12\s+)?(noon|midday|midnight)\b',
    caseSensitive: false);

/// `3pm`, `3:30 p.m.`, `15:00`, `at 3`, `3 o'clock`. A bare number is not a
/// time: it needs `at`, minutes, an am/pm or `o'clock`, or "3 people" and
/// "1:1" would be read as clock times.
final RegExp _clock = RegExp(
    '(?<![\\w:./-])(?:(at|@)\\s*)?(\\d{1,2})(?::([0-5]\\d))?(?:\\s*$_meridiem|\\s*(o\'?clock))?(?![\\w:/]|\\.\\d)',
    caseSensitive: false);

/// A clock phrase before resolution: one time, or a range.
class _TimeMention {
  final WhenSpan span;
  final _RawTime? start;
  final _RawTime? end;

  /// For `noon`/`midnight`, which need no reading.
  final (int, int)? fixed;

  const _TimeMention(this.span, {this.start, this.end, this.fixed});

  /// (start, end?) under [part], or null for a range that cannot be ordered.
  ((int, int), (int, int)?)? resolve(DayPart? part) {
    final f = fixed;
    if (f != null) return (f, null);
    final a = start!;
    final b = end;
    if (b == null) return (a.resolve(part), null);
    return _orderRange(a, b, part);
  }
}

/// A range's two ends, each read in the other's light.
///
/// An am/pm on one end propagates to an unmarked other end when that gives
/// start < end ("2-3pm" is 14:00–15:00, "11-1pm" is not 23:00–13:00 so the
/// start falls back to daytime-first 11:00). Two unmarked ends are each read
/// daytime-first, and an end that lands at or before the start moves forward
/// twelve hours ("from 6 to 7" is 18:00–19:00). Two marked ends are taken as
/// written and must run forward, unless they cross from pm to am, which runs
/// past midnight ("10pm-1am"). "3pm-2pm" cannot be ordered and is no range.
((int, int), (int, int)?)? _orderRange(_RawTime a, _RawTime b, DayPart? part) {
  bool before((int, int) x, (int, int) y) => _minutes(x) < _minutes(y);
  final ma = a.meridiem;
  final mb = b.meridiem;
  if (ma != null && mb != null) {
    final at = a.resolve(part);
    final bt = b.resolve(part);
    if (before(at, bt) || (ma == 'pm' && mb == 'am')) return (at, bt);
    return null;
  }
  if (a.bare && mb != null) {
    final bt = b.resolve(part);
    final propagated = (_RawTime.withMeridiem(a.hour, mb), a.minute);
    if (a.hour <= 12 && before(propagated, bt)) return (propagated, bt);
    final at = a.resolve(part);
    return before(at, bt) ? (at, bt) : null;
  }
  if (b.bare && ma != null) {
    final at = a.resolve(part);
    final propagated = (_RawTime.withMeridiem(b.hour, ma), b.minute);
    if (b.hour <= 12 && before(at, propagated)) return (at, propagated);
    final bt = b.resolve(part);
    return before(at, bt) ? (at, bt) : null;
  }
  final at = a.resolve(part);
  var bt = b.resolve(part);
  if (!before(at, bt) && b.bare && bt.$1 < 12) bt = (bt.$1 + 12, bt.$2);
  return before(at, bt) ? (at, bt) : null;
}

List<_TimeMention> _times(String text, _Claims claims) {
  final out = <_TimeMention>[];
  for (final m in _range.allMatches(text)) {
    if (!claims.free(m.start, m.end)) continue;
    final lead = m.group(1)?.toLowerCase();
    final joiner = m.group(5)!.toLowerCase();
    // "and" only joins a range after "between" ("2 and 3 people" is not one).
    if (joiner == 'and' && lead != 'between') continue;
    // "move my 3pm to 4pm" is two times, not a range: a word joiner after a
    // possessive names a meeting and then where it goes, and so does one
    // after a move verb earlier in the clause ("move 3pm to 4pm"). "from" or
    // a dash still makes a range ("my 2-3pm", "move it from 3pm to 4pm").
    final wordJoiner = joiner == 'to' || joiner == 'until' || joiner == 'till';
    if (wordJoiner &&
        lead == null &&
        (_possessiveBefore.hasMatch(text.substring(0, m.start)) ||
            _moveVerb.hasMatch(_clauseBefore(text, m.start)))) {
      continue;
    }
    final marked = lead != null ||
        m.group(3) != null ||
        m.group(4) != null ||
        m.group(7) != null ||
        m.group(8) != null;
    if (!marked) continue;
    final a = _RawTime.read(m.group(2)!, m.group(3), m.group(4));
    final b = _RawTime.read(m.group(6)!, m.group(7), m.group(8));
    if (a == null || b == null) continue;
    // Refuse now what can never be ordered, so the words stay leftovers
    // rather than a consumed phrase with no meaning. The part is not known
    // yet; the final ordering is redone with it in [resolveWhen].
    if (_orderRange(a, b, null) == null) continue;
    claims.claim(m.start, m.end);
    out.add(_TimeMention(WhenSpan(m.start, m.end, WhenKind.range),
        start: a, end: b));
  }
  for (final m in _namedTime.allMatches(text)) {
    if (!claims.free(m.start, m.end)) continue;
    claims.claim(m.start, m.end);
    final word = m.group(1)!.toLowerCase();
    out.add(_TimeMention(WhenSpan(m.start, m.end, WhenKind.time),
        fixed: word == 'midnight' ? (0, 0) : (12, 0)));
  }
  for (final m in _clock.allMatches(text)) {
    if (!claims.free(m.start, m.end)) continue;
    final marked = m.group(1) != null ||
        m.group(3) != null ||
        m.group(4) != null ||
        m.group(5) != null;
    if (!marked) continue;
    final t = _RawTime.read(m.group(2)!, m.group(3), m.group(4));
    if (t == null) continue;
    claims.claim(m.start, m.end);
    out.add(_TimeMention(WhenSpan(m.start, m.end, WhenKind.time), start: t));
  }
  return out;
}

// ---------------------------------------------------------------------------
// The resolver
// ---------------------------------------------------------------------------

/// Which characters an earlier (more specific) grammar already consumed. A
/// later match that touches any of them is dropped whole, so "30 min" is a
/// duration and never also "at 30", and "Oct 14" is a date and never a time.
class _Claims {
  final List<bool> _taken;

  _Claims(int length) : _taken = List.filled(length, false);

  bool free(int start, int end) {
    for (var i = start; i < end; i++) {
      if (_taken[i]) return false;
    }
    return true;
  }

  void claim(int start, int end) {
    for (var i = start; i < end; i++) {
      _taken[i] = true;
    }
  }
}

/// Reads every when and duration phrase in [text] against [now] in [zone].
///
/// [now] is converted to [zone] first; "today" is that local date. The
/// rules, each pinned by a test:
///
/// - **Bare weekday** ("Tuesday", "tue", "Tues"): in [WhenMode.booking] the
///   next occurrence STRICTLY after today (booking "Wednesday" on a
///   Wednesday means next week's); in [WhenMode.question] today when it is
///   that weekday ("am I free Wednesday?" on a Wednesday), else the next.
/// - **"next `<weekday>`"**: the booking rule, in both modes.
/// - **"this `<weekday>`"**: this ISO week's (Monday-start) occurrence; if that
///   is before today, [WhenResolution.unresolvedReason] is set and the day is
///   null — never rolled forward.
/// - **"today"**, **"tonight"** (today + evening), **"tomorrow"/"tmrw"**,
///   **"day after tomorrow"**.
/// - **"next week"**: next Monday through next Friday. **"this week"**: today
///   through this Friday; on a weekend, unresolved. A bare weekday with a
///   week phrase ("Tuesday next week") is that weekday in that week.
/// - **Explicit dates** ("Oct 14", "14 Oct", "October 14th", "10/14" as US
///   month/day, "2026-10-14"): with no year, this year — or next year when
///   booking a date already past. A question keeps this year.
/// - **Clock times** ("3pm", "3:30pm", "15:00", "noon", "midnight", "at 3"):
///   a bare hour is daytime-first (see `_RawTime.resolve`).
/// - **Ranges** ("2-3pm", "from 2 to 3", "2pm to 3:30pm", "10-10:30").
/// - **Parts of day**: morning 9–12, afternoon 12–17, evening 17–20, end of
///   day / EOD 16–17, lunch 12–13 — windows, never an explicit time.
/// - **Durations**: see [parseDuration].
/// - **Never invent a time**: a day with no time or part leaves
///   [WhenResolution.time] null.
///
/// The grammars run most specific first — durations, dates, relative days,
/// weeks, weekdays, parts, then clock times — and each claims its characters,
/// so "Oct 14" is never also "at 14" and "30 min" is never "at 30". Matching
/// is case-insensitive and respects word boundaries. Text with no when-words
/// gives an empty resolution; nothing here throws.
WhenResolution resolveWhen(
  String text, {
  required DateTime now,
  required CalendarZone zone,
  required WhenMode mode,
}) {
  final local = zone.toLocal(now);
  final today = CalendarDate(local.year, local.month, local.day);
  final claims = _Claims(text.length);
  final spans = <WhenSpan>[];

  final durations = _durations(text, claims);
  final days = _days(text, claims, today, mode);

  final parts = <(WhenSpan, DayPart, bool)>[];
  for (final m in _partPhrase.allMatches(text)) {
    if (!claims.free(m.start, m.end)) continue;
    claims.claim(m.start, m.end);
    final impliesToday = m.group(1)?.toLowerCase() == 'this';
    parts.add((WhenSpan(m.start, m.end, WhenKind.part), _partOf(m.group(2)!),
        impliesToday));
  }

  final times = _times(text, claims);

  // --- the part: the last one named; "tonight" is an evening. ---
  DayPart? part;
  int partPos = -1;
  for (final (span, p, _) in parts) {
    if (span.start > partPos) {
      part = p;
      partPos = span.start;
    }
  }
  for (final (span, _) in days) {
    if (span.textIn(text).toLowerCase() == 'tonight' && span.start > partPos) {
      part = DayPart.evening;
      partPos = span.start;
    }
  }

  // --- the day ---
  final mentions = [for (final (_, d) in days) d];
  for (final (span, _, impliesToday) in parts) {
    if (impliesToday) {
      mentions.add(_DayMention(span.start, day: today, weak: true));
    }
  }
  // "Tuesday next week": a bare weekday NEXT TO a week phrase is that
  // weekday inside the week, and the pair is one mention. Apart, they are
  // two mentions and the last wins as usual: "move my Monday meeting next
  // week to tomorrow" means tomorrow.
  final paired = <_DayMention>{};
  for (final (ws, wm) in days) {
    if (wm.week == null) continue;
    for (final (ds, dm) in days) {
      if (dm.bareWeekday == null || paired.contains(dm)) continue;
      final gap = ds.end <= ws.start
          ? text.substring(ds.end, ws.start)
          : ws.end <= ds.start
              ? text.substring(ws.end, ds.start)
              : null;
      if (gap == null || !_weekJoin.hasMatch(gap)) continue;
      paired
        ..add(wm)
        ..add(dm);
      final pos = ws.start > ds.start ? ws.start : ds.start;
      final wd = dm.bareWeekday!;
      mentions.add(wm.week == 'next'
          ? _DayMention(pos, day: _mondayOf(today).addDays(7 + wd - 1))
          : _thisWeekday(pos, today, wd));
      break;
    }
  }
  mentions.removeWhere(paired.contains);
  CalendarDate? day;
  CalendarDate? rangeEnd;
  String? reason;
  _DayMention? winner;
  final strong = mentions.where((m) => !m.weak).toList();
  final pool = strong.isNotEmpty ? strong : mentions;
  if (pool.isNotEmpty) {
    pool.sort((a, b) => a.pos.compareTo(b.pos));
    winner = pool.last;
    day = winner.day;
    rangeEnd = winner.rangeEnd;
    reason = winner.reason;
  }

  // --- the time: the last one named, read in the light of the part ---
  (int, int)? time;
  (int, int)? endTime;
  var timePos = -1;
  _TimeMention? chosen;
  times.sort((a, b) => a.span.start.compareTo(b.span.start));
  for (final t in times.reversed) {
    final r = t.resolve(part);
    if (r == null) continue;
    time = r.$1;
    endTime = r.$2;
    timePos = t.span.start;
    chosen = t;
    break;
  }
  // "midnight tonight", "tonight at 12": the midnight that ends tonight, which
  // is the NEXT date's 00:00 — not this morning's, long gone, and not noon,
  // which a bare 12 otherwise reads as. It is a time, so the evening window
  // no longer applies.
  final raw = chosen?.start;
  final atMidnight = chosen != null &&
      chosen.end == null &&
      (time?.$1 == 0 || (raw != null && raw.bare && raw.hour == 12));
  final tonightDay = day;
  if (atMidnight &&
      winner != null &&
      winner.tonight &&
      tonightDay != null &&
      time != null) {
    time = (0, time.$2);
    day = tonightDay.addDays(1);
    part = null;
  }
  // A time and a part that disagree ("my 3pm … to tomorrow morning"): the
  // later phrase is the one meant; the earlier stays in `spans`.
  final p = part;
  final t = time;
  if (p != null && t != null) {
    final (lo, hi) = _looseBounds(p);
    final m = _minutes(t);
    final agrees = m >= lo && m < hi;
    if (!agrees) {
      if (partPos > timePos) {
        time = null;
        endTime = null;
      } else {
        part = null;
      }
    }
  }

  // --- the duration: the last one named ---
  Duration? duration;
  if (durations.isNotEmpty) {
    durations.sort((a, b) => a.$1.start.compareTo(b.$1.start));
    duration = durations.last.$2;
  }

  spans
    ..addAll(durations.map((d) => d.$1))
    ..addAll(days.map((d) => d.$1))
    ..addAll(parts.map((p) => p.$1))
    ..addAll(times.map((t) => t.span))
    ..sort((a, b) => a.start.compareTo(b.start));

  return WhenResolution(
    today: today,
    zone: zone,
    spans: List.unmodifiable(spans),
    day: day,
    rangeEnd: rangeEnd,
    time: time,
    endTime: endTime,
    part: part,
    duration: duration,
    explicitTime: time != null,
    unresolvedReason: day == null ? reason : null,
  );
}
