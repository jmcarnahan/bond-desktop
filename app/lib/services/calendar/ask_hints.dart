import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/calendar_models.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show shortDate;
import 'when_resolver.dart';

/// What a scheduling ask's own words say about the time it wants
/// (docs/pipeline/14-calendar.md "Find a time"): "could we grab dinner on
/// Friday?" is Friday evening for an hour and a half, not three working-hours
/// slots.
///
/// Pure, and never a model: the day, a part of the day, a clock time and a
/// length come from [resolveWhen] (the command bar's grammar, read as a
/// question), and the meal and social words are a closed list here. Nothing
/// read here changes [DayPart]'s bounds, which are the command bar's.

/// A wall-clock window on whatever day it is applied to: a meal's hours, a
/// part of the day's, or two hours from a time the ask named.
@immutable
class AskHours {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;

  const AskHours({
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
  });

  /// [part]'s own bounds ([DayPartBounds]).
  factory AskHours.fromDayPart(DayPart part) => AskHours(
        startHour: part.start.$1,
        startMinute: part.start.$2,
        endHour: part.end.$1,
        endMinute: part.end.$2,
      );

  int get startInMinutes => startHour * 60 + startMinute;
  int get endInMinutes => endHour * 60 + endMinute;

  @override
  bool operator ==(Object other) =>
      other is AskHours &&
      other.startHour == startHour &&
      other.startMinute == startMinute &&
      other.endHour == endHour &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(startHour, startMinute, endHour, endMinute);

  @override
  String toString() => 'AskHours($startHour:$startMinute–$endHour:$endMinute)';
}

/// What [readAskHints] found. Every field may be null; [any] says whether
/// anything was.
@immutable
class AskHints {
  /// The day the ask named, never in the past.
  final CalendarDate? day;

  /// The hours to look in on every searched day.
  final AskHours? hours;

  /// The length the ask named, else its meal's usual length.
  final int? minutes;

  /// The row's line, "Asked for: Fri Oct 9 · dinner"; null when nothing was
  /// read.
  final String? said;

  const AskHints({this.day, this.hours, this.minutes, this.said});

  static const AskHints none = AskHints();

  bool get any => day != null || hours != null || minutes != null;
}

/// How much of an ask is read: its opening lines carry the time; a long
/// quoted history below them only adds other people's dates.
const int askHintsCap = 600;

/// One meal or social word: its hours and its usual length.
typedef _Meal = ({String word, RegExp re, AskHours hours, int minutes});

final List<_Meal> _meals = [
  (
    word: 'breakfast',
    re: RegExp(r'\bbreakfast\b', caseSensitive: false),
    hours: const AskHours(
        startHour: 7, startMinute: 30, endHour: 9, endMinute: 30),
    minutes: 45,
  ),
  (
    word: 'coffee',
    re: RegExp(r'\bcoffee\b', caseSensitive: false),
    hours: const AskHours(
        startHour: 9, startMinute: 0, endHour: 16, endMinute: 0),
    minutes: 30,
  ),
  // Wider than the command bar's DayPart.lunch (12–13): an ask's "lunch"
  // is a meal somewhere around noon, a command's is the hour it names.
  (
    word: 'lunch',
    // "lunchtime" is the meal too, with its length.
    re: RegExp(r'\blunch(?:\s*time)?\b', caseSensitive: false),
    hours: const AskHours(
        startHour: 11, startMinute: 30, endHour: 13, endMinute: 30),
    minutes: 60,
  ),
  (
    word: 'dinner',
    re: RegExp(r'\bdinner\b', caseSensitive: false),
    hours: const AskHours(
        startHour: 17, startMinute: 30, endHour: 20, endMinute: 30),
    minutes: 90,
  ),
  (
    word: 'drinks',
    // "a drink" as well as "drinks" — and so "soft drinks" too, which is
    // accepted: an ask that mentions them is rarely about the morning.
    re: RegExp(r'\b(?:drinks?|happy\s+hour)\b', caseSensitive: false),
    hours: const AskHours(
        startHour: 17, startMinute: 0, endHour: 19, endMinute: 30),
    minutes: 60,
  ),
];

/// The words a part of the day is said with on the row.
String _partWord(DayPart p) => switch (p) {
      DayPart.morning => 'morning',
      DayPart.afternoon => 'afternoon',
      DayPart.evening => 'evening',
      DayPart.endOfDay => 'end of day',
      DayPart.lunch => 'lunch',
    };

/// Where a quoted reply starts: "On Mon, Sep 28, 2026 at 3:15 PM Dana
/// wrote:" (which a client may wrap over two lines), an Outlook
/// "-----Original Message-----", or a "From:" header line. Everything after
/// it is the thread's history, whose dates are not this ask's.
final RegExp _quoteStart = RegExp(
    r'(^|\n)\s*(?:On\s[^\n]*(?:\n[^\n]*)?wrote:|-{2,}\s*Original Message\s*-{2,}|From:)',
    caseSensitive: false);

/// [body] up to its first quoted-reply header ([_quoteStart]).
String _ownWords(String body) {
  final m = _quoteStart.firstMatch(body);
  return m == null ? body : body.substring(0, m.start);
}

/// How far back a day may be and still mean its weekday: a message from last
/// week saying "Thursday" means a Thursday. Older dates are another meeting.
const int _rollDays = 7;

/// Reads [subject] and [body] (the ask's NEWEST inbound message) for a day,
/// hours and a length, at [now] in [zone].
///
/// - **Only the ask's own words**: the body is cut at its first quoted-reply
///   header, so a date in the history ("On Mon … at 3:15 PM Dana wrote:")
///   never wins.
/// - **Day**: the resolver's, read as a question (a bare weekday on its own
///   day is today). A week ("next week") is not a day. A day at most seven
///   days past (an old message's "Oct 2") rolls forward to that weekday's
///   next occurrence — today, when it is today's weekday — because the ask
///   may be days old and the weekday is what the person meant; an older one
///   is dropped. "yesterday" is no day (the resolver does not read it).
/// - **Hours**, most specific first: an explicit clock time (two hours from
///   it, or the range it names), else a meal or social word (the earliest
///   in the text: breakfast, coffee, lunch, dinner, drinks or happy hour),
///   else a part of the day. A meal beats a part: "coffee tuesday morning"
///   is coffee's hours. A meal also says which half of the day a bare hour
///   is: "dinner at 7" is 19:00 (the resolver alone reads 7:00 AM).
/// - **Minutes**: a length the ask named, else a range's own length, else
///   the meal's usual length, else none.
AskHints readAskHints({
  required String subject,
  required String body,
  required DateTime now,
  required CalendarZone zone,
}) {
  final text =
      _cap('${subject.trim()}. ${_ownWords(body).trim()}', askHintsCap);
  final w = resolveWhen(text, now: now, zone: zone, mode: WhenMode.question);

  CalendarDate? day = w.rangeEnd == null ? w.day : null;
  if (day != null && day.isBefore(w.today)) {
    if (day.isBefore(w.today.addDays(-_rollDays))) {
      day = null;
    } else {
      final delta = (day.weekday - w.today.weekday + 7) % 7;
      day = w.today.addDays(delta);
    }
  }

  _Meal? meal;
  var mealAt = -1;
  for (final m in _meals) {
    final hit = m.re.firstMatch(text);
    if (hit == null) continue;
    if (meal == null || hit.start < mealAt) {
      meal = m;
      mealAt = hit.start;
    }
  }

  AskHours? hours;
  String? what;
  int? rangeMinutes;
  var t = w.time;
  final part = w.part;
  if (t != null) {
    // A meal says which half of the day a bare hour means: 7 next to
    // "dinner" is 19:00. Breakfast keeps its morning — 8 + 12 is no
    // breakfast hour.
    final m = meal;
    if (m != null && t.$1 < 12) {
      final pm = (t.$1 + 12) * 60 + t.$2;
      if (pm >= m.hours.startInMinutes - 60 && pm <= m.hours.endInMinutes + 60) {
        t = (t.$1 + 12, t.$2);
      }
    }
    final start = t.$1 * 60 + t.$2;
    final et = w.endTime;
    var end = start + 120;
    if (et != null) {
      final e = et.$1 * 60 + et.$2;
      // A range ends where it says; one past midnight ends at midnight.
      end = e > start ? e : 24 * 60;
      rangeMinutes = end - start;
    }
    // A window past midnight is cut at the day's last minute: the search
    // looks in one local day at a time.
    final capped = end > 24 * 60 - 1 ? 24 * 60 - 1 : end;
    hours = AskHours(
      startHour: t.$1,
      startMinute: t.$2,
      endHour: capped ~/ 60,
      endMinute: capped % 60,
    );
    final clock =
        DateFormat('h:mm a').format(DateTime.utc(2000, 1, 1, t.$1, t.$2));
    what = m == null ? clock : '${m.word} · $clock';
  } else if (meal != null) {
    hours = meal.hours;
    what = meal.word;
  } else if (part != null) {
    hours = AskHours.fromDayPart(part);
    what = _partWord(part);
  }

  final named = w.duration?.inMinutes;
  final minutes = named != null && named > 0
      ? named
      : rangeMinutes ?? meal?.minutes;

  final bits = [
    if (day != null) shortDate(day),
    ?what,
  ];
  return AskHints(
    day: day,
    hours: hours,
    minutes: minutes,
    said: bits.isEmpty ? null : 'Asked for: ${bits.join(' · ')}',
  );
}

/// [s] cut to at most [max] UTF-16 units, back to the last whitespace
/// before the cap so a word is never halved ("at 11pm" never reads "at 1"),
/// and so never through a surrogate pair either. `brief_gatherer.dart`'s
/// `capRunes` cuts mid-word, which a resolver cannot afford.
String _cap(String s, int max) {
  if (s.length <= max) return s;
  final space = s.lastIndexOf(RegExp(r'\s'), max);
  if (space > 0) return s.substring(0, space);
  final last = s.codeUnitAt(max - 1);
  return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? max - 1 : max);
}
