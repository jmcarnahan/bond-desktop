import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/calendar_models.dart';
import 'ask_hours.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show shortDate;
import 'when_resolver.dart';

export 'ask_hours.dart' show AskHours;

/// What a scheduling ask's own words say about the time it wants
/// (docs/pipeline/14-calendar.md "Find a time"): "could we grab dinner on
/// Friday?" is Friday evening for an hour and a half, not three working-hours
/// slots.
///
/// Pure, and never a model: the day, a part of the day, a clock time and a
/// length come from [resolveWhen] (the command bar's grammar, read as a
/// question), and the meal and social words are a closed list here. Nothing
/// read here changes [DayPart]'s bounds, which are the command bar's.

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

  /// How the hours were asked for, to put after a weekday in a sentence:
  /// "for dinner", "in the evening", "at 7:00 PM", "for dinner at 7:00 PM";
  /// null when no hours were read.
  final String? timeWords;

  const AskHints(
      {this.day, this.hours, this.minutes, this.said, this.timeWords});

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

/// A year as a reply header writes it: after a comma or a slash ("Sep 29,
/// 2026", "29/09/2026"), or opening an ISO date ("2026-09-29") — never a
/// clock time such as "at 1930".
const String _year = r'(?:(?:,\s*|/)(?:19|20)\d\d\b|\b(?:19|20)\d\d-\d\d)';

/// Where a quoted reply starts: "On Mon, Sep 28, 2026 at 3:15 PM Dana
/// (dana@…) wrote:" (which a client may wrap over two lines), an Outlook
/// "-----Original Message-----", or a header block — a "From:" line with a
/// "Sent:", "Date:" or "To:" line within the two under it, either possibly
/// quoted with ">". Everything after it is the thread's history, whose
/// dates are not this ask's.
///
/// Each form is held to what only a header has, because the cut drops
/// everything below it: an "On … wrote:" needs a [_year], a "<" or an "@"
/// in its line or two ("On second thought, Friday dinner works." above
/// somebody's "… wrote:" is the ask, not its history), and a lone "From:
/// tomorrow on I am free" line is a sentence.
final RegExp _quoteStart = RegExp(
    r'(^|\n)[ \t]*>?[ \t]*(?:'
    'On\\s[^\\n]*(?:$_year|<|@)[^\\n]*(?:\\n[^\\n]*)?wrote:'
    '|On\\s[^\\n]*\\n[^\\n]*(?:$_year|<|@)[^\\n]*wrote:'
    r'|-{2,}\s*Original Message\s*-{2,}'
    r'|From:[^\n]*\n(?:[^\n]*\n)?[ \t]*>?[ \t]*(?:Sent|Date|To):)',
    caseSensitive: false);

/// [body] up to its first quoted-reply header ([_quoteStart]).
String _ownWords(String body) {
  final m = _quoteStart.firstMatch(body);
  return m == null ? body : body.substring(0, m.start);
}

/// How far back a day may be and still mean its weekday: a message from last
/// week saying "Thursday" means a Thursday. Older dates are another meeting.
const int _rollDays = 7;

/// How far outside a meal's hours a time it names may sit and still be
/// that meal's: "dinner at 4" is a reach, "drinks at midnight" is not drinks
/// hours at all.
const int _mealReachMinutes = 120;

/// Reads [subject] and [body] (the ask's NEWEST inbound message) for a day,
/// hours and a length, at [now] in [zone].
///
/// - **Only the ask's own words**: the body is cut at its first quoted-reply
///   header ([_quoteStart]), so a date in the history ("On Mon … at 3:15 PM
///   Dana wrote:") never wins.
/// - **When it was said**: relative words ("tomorrow", a bare weekday) are
///   read against [sentAt], the message's own time, when the host has it,
///   else [now]; whether that day is gone is judged at [now].
/// - **Day**: the resolver's, read as a question (a bare weekday on its own
///   day is today). A week ("next week") is not a day. Only a WEEKDAY
///   recurs: one at most seven days past (an old message's "Thursday")
///   rolls forward to its next occurrence — today, when it is today's
///   weekday — because the ask may be days old and the weekday is what the
///   person meant; an older one is dropped. A relative day ("tomorrow" in
///   Monday's message, read on Wednesday) or a date ("Oct 2", read on Oct 5)
///   that has gone is dropped: each named one day, not a weekday — the
///   same rule as "too late" below. "yesterday" is no day (the resolver
///   does not read it).
/// - **Hours**, most specific first: an explicit clock time (two hours from
///   it, or the range it names), else a meal or social word (the earliest
///   in the text: breakfast, coffee, lunch, dinner, drinks or happy hour),
///   else a part of the day. A meal beats a part: "coffee tuesday morning"
///   is coffee's hours. A meal also says which half of the day a BARE hour
///   is: "dinner at 7" is 19:00 (the resolver alone reads 7:00 AM), and a
///   range's bare end moves with its start ("dinner from 7 to 9" is
///   19:00–21:00); an hour with am/pm or on a 24-hour clock is taken as
///   written. A bare or named time ("midnight") more than two hours outside
///   the meal's hours is not that meal's: the meal's hours stand.
/// - **Past midnight**: a window is cut at the day's last minute (the search
///   walks one local day at a time), and the length is cut to the quarter
///   hours left in it, so "drinks 10pm-1am" is 22:00–23:59 for 105 minutes
///   (a "119" pill is nobody's length).
/// - **Today, too late**: a day that is today whose hours have already
///   ended rolls a week on when it was a weekday ("dinner on Friday" read
///   on Friday at nine is next Friday), and is dropped when it was a
///   relative day or a date ("dinner tonight?" or "dinner Oct 9?" read at
///   nine names no other day); with no hours, today stands.
/// - **Minutes**: a length the ask named, else a range's own length, else
///   the meal's usual length, else none — never more than the window holds
///   once it was cut at midnight.
AskHints readAskHints({
  required String subject,
  required String body,
  required DateTime now,
  required CalendarZone zone,
  DateTime? sentAt,
}) {
  final text =
      _cap('${subject.trim()}. ${_ownWords(body).trim()}', askHintsCap);
  final w = resolveWhen(text,
      now: sentAt ?? now, zone: zone, mode: WhenMode.question);
  final today = zone.dateOf(now.toUtc());
  final weekday = w.dayMention == DayMention.weekday;

  CalendarDate? day = w.rangeEnd == null ? w.day : null;
  if (day != null && day.isBefore(today)) {
    if (!weekday || day.isBefore(today.addDays(-_rollDays))) {
      day = null;
    } else {
      final delta = (day.weekday - today.weekday + 7) % 7;
      day = today.addDays(delta);
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
  String? timeWords;
  int? rangeMinutes;
  // What is left of a window cut at midnight; null when it was not cut.
  int? cutWindow;
  var t = w.time;
  final m = meal;
  var shifted = false;
  // A meal says which half of the day a bare hour means: 7 next to
  // "dinner" is 19:00. Breakfast keeps its morning — 8 + 12 is no
  // breakfast hour — and "coffee at 4am" keeps the am it was given.
  if (t != null && m != null && w.timeForm == TimeForm.bare && t.$1 < 12) {
    final pm = (t.$1 + 12) * 60 + t.$2;
    if (pm >= m.hours.startInMinutes - 60 && pm <= m.hours.endInMinutes + 60) {
      t = (t.$1 + 12, t.$2);
      shifted = true;
    }
  }
  // A bare or named time far outside the meal's hours is not the meal's
  // ("drinks 10pm to midnight" reads midnight last): the meal's hours stand.
  // A time with am/pm or on a 24-hour clock is the person's own word.
  if (t != null && m != null && w.timeForm != TimeForm.marked) {
    final at = t.$1 * 60 + t.$2;
    if (at < m.hours.startInMinutes - _mealReachMinutes ||
        at > m.hours.endInMinutes + _mealReachMinutes) {
      t = null;
    }
  }
  if (t != null) {
    final start = t.$1 * 60 + t.$2;
    final et = w.endTime;
    var end = start + 120;
    if (et != null) {
      var e = et.$1 * 60 + et.$2;
      // The meal moved the start into the afternoon; a bare end the range
      // put before it moves with it ("dinner from 7 to 9" is 19:00–21:00,
      // not 19:00 to midnight).
      if (shifted && et.$1 < 12 && e <= start) e += 12 * 60;
      // A range ends where it says; one past midnight ends at midnight.
      end = e > start ? e : 24 * 60;
      rangeMinutes = end - start;
    }
    // A window past midnight is cut at the day's last minute: the search
    // looks in one local day at a time.
    final capped = end > 24 * 60 - 1 ? 24 * 60 - 1 : end;
    if (capped < end) cutWindow = capped - start;
    hours = AskHours(
      startHour: t.$1,
      startMinute: t.$2,
      endHour: capped ~/ 60,
      endMinute: capped % 60,
    );
    final clock =
        DateFormat('h:mm a').format(DateTime.utc(2000, 1, 1, t.$1, t.$2));
    what = m == null ? clock : '${m.word} · $clock';
    timeWords = m == null ? 'at $clock' : 'for ${m.word} at $clock';
  } else if (m != null) {
    hours = m.hours;
    what = m.word;
    timeWords = 'for ${m.word}';
  } else if (w.part case final part?) {
    hours = AskHours.fromDayPart(part);
    what = _partWord(part);
    timeWords = part == DayPart.endOfDay ? 'at end of day' : 'in the $what';
  }

  final named = w.duration?.inMinutes;
  var minutes = named != null && named > 0
      ? named
      : rangeMinutes ?? meal?.minutes;
  // Cut to the quarter hours that fit (a 119 is nobody's length), never
  // under one quarter hour.
  final cut = cutWindow;
  if (minutes != null && cut != null && minutes > cut) {
    minutes = cut < 15 ? cut : cut - cut % 15;
  }

  // Today's hours already gone: "dinner on Friday" read on Friday at nine
  // means next Friday. Gone means no room left for the meeting before they
  // close — now plus its length past the close — the arithmetic
  // `findTimeWindowUtc` judges a week by. Only a weekday recurs: "tonight"
  // and "Oct 9" each named that one day, so they are dropped rather than
  // rolled. With no hours, today stands.
  final h = hours;
  final length = Duration(
      minutes: (minutes ?? 1) < 1 ? 1 : (minutes ?? 1));
  if (day != null && day == today && h != null) {
    final close =
        zone.localDateTime(day, h.endHour, h.endMinute).toUtc();
    if (now.toUtc().add(length).isAfter(close)) {
      day = weekday ? day.addDays(7) : null;
    }
  }

  final bits = [
    if (day != null) shortDate(day),
    ?what,
  ];
  return AskHints(
    day: day,
    hours: hours,
    minutes: minutes,
    said: bits.isEmpty ? null : 'Asked for: ${bits.join(' · ')}',
    timeWords: timeWords,
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
