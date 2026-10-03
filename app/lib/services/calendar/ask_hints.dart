import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/calendar_models.dart';
import '../llm/ask_read_task.dart' show AskMeal, AskRead;
import 'ask_hours.dart';
import 'ask_words.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show shortDate;
import 'phrase_guard.dart';
import 'when_resolver.dart';

export 'ask_hours.dart' show AskHours;
export 'ask_words.dart' show askHintsCap, askOwnWords, capAtWord;

/// What a scheduling ask's own words say about the time it wants
/// (docs/pipeline/14-calendar.md "Find a time"): "could we grab dinner on
/// Friday?" is Friday evening for an hour and a half, not three working-hours
/// slots.
///
/// Pure, and never calls a model: the day, a part of the day, a clock time
/// and a length come from [resolveWhen] (the command bar's grammar, read as
/// a question), and the meal and social words are a closed list here. The
/// model's reading ([readAskHintsFromRead]) is phrases it copied, resolved
/// here by the same rules. Nothing read here changes [DayPart]'s bounds,
/// which are the command bar's.

/// What [readAskHints] found. Every field may be null; [any] says whether
/// anything was.
@immutable
class AskHints {
  /// The day the ask named, never in the past: the first of [days].
  final CalendarDate? day;

  /// Every day the ask named, sorted, never in the past: one for a single
  /// day, several for alternatives the model read ("Tuesday or Thursday").
  /// [day] is `days.firstOrNull` for every reader, by construction.
  final List<CalendarDate> days;

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

  const AskHints({
    this.day,
    this.days = const [],
    this.hours,
    this.minutes,
    this.said,
    this.timeWords,
  });

  static const AskHints none = AskHints();

  bool get any => day != null || hours != null || minutes != null;
}

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

/// How far outside a meal's hours a time it names may sit and still be
/// that meal's: "dinner at 4" is a reach, "drinks at midnight" is not drinks
/// hours at all.
const int _mealReachMinutes = 120;

/// Reads [subject] and [body] (the ask's NEWEST inbound message) for a day,
/// hours and a length, at [now] in [zone].
///
/// - **Only the ask's own words**: the body is cut at its first quoted-reply
///   header ([askOwnWords]), so a date in the history ("On Mon … at 3:15 PM
///   Dana wrote:") never wins.
/// - **When it was said**: relative words ("tomorrow", a bare weekday) are
///   read against [sentAt], the message's own time, when the host has it,
///   else [now]; whether that day is gone is judged at [now].
/// - **Day**: the resolver's, read as a question (a bare weekday on its own
///   day is today). A week ("next week") is not a day. Only a WEEKDAY
///   recurs: one that has gone (an old message's "Thursday", however old
///   the message — the ask is still open) rolls forward to its NEXT
///   occurrence — today, when it is today's weekday — because the weekday
///   is what the person meant and the next one is the nearest answer. A
///   relative day ("tomorrow" in Monday's message, read on Wednesday) or a
///   date ("Oct 2", read on Oct 5) that has gone is dropped: each named one
///   day, not a weekday — the same rule as "too late" below. "yesterday" is
///   no day (the resolver does not read it).
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
      capAtWord('${subject.trim()}. ${askOwnWords(body).trim()}', askHintsCap);
  final w = resolveWhen(text,
      now: sentAt ?? now, zone: zone, mode: WhenMode.question);

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

  return _hintsFrom(
    dayReads: [w],
    timeRead: w,
    duration: w.duration,
    meal: meal,
    now: now,
    zone: zone,
  );
}

/// The model's reading of an ask, re-resolved by the same rules as
/// [readAskHints] (docs/pipeline/14-calendar.md "Reading the ask").
///
/// The model (`ask_read`) only COPIED phrases out of [subject] and [body];
/// it never computed a day or a time. Here each phrase is checked and read
/// by the same Dart the rules use:
///
/// - **Not asking**: `asks_for_time` false is [AskHints.none], whatever
///   phrases came with it.
/// - **The literal guard**: a `when`, `time` or `duration` phrase is kept
///   only when it is in the ask's own words on word boundaries
///   ([findPhrase]); anything else is the model's own wording, or
///   invented, and is dropped. A meal is kept only when that meal's own
///   word matches the text (the closed list [readAskHints] scans), so
///   "dinner" read into a message that never says it is no meal. The text
///   is the subject and the whole of the body's own words, not cut at
///   [askHintsCap]: the model read up to `askReadCap`.
/// - **Days**: each kept `when` phrase is resolved ON ITS OWN as a question
///   at [sentAt] (else [now]), so "Tuesday or Thursday" is two days, and a
///   day the sender ruled out is not read at all when the model did not
///   copy it. The day rules are [readAskHints]'s: a past weekday rolls to
///   its next occurrence, a past relative day or date is dropped, a week is
///   not a day, and today too late rolls or drops.
/// - **Hours and length**: the kept `time` phrase through [resolveWhen], a
///   kept `duration` phrase through [parseDuration]; with no `time` phrase,
///   the first `when` phrase that itself carries a time or a part of the
///   day ("Friday at 3pm") gives the hours, so nothing is lost when the
///   model folds the time into the day. The meal and hour rules are
///   [readAskHints]'s, through the one core.
///
/// Nothing kept at all is [AskHints.none]. The [AskRead] is stored as
/// phrases, never dates, so a reading made last week is re-resolved against
/// today here.
AskHints readAskHintsFromRead({
  required AskRead read,
  required String subject,
  required String body,
  required DateTime now,
  required CalendarZone zone,
  DateTime? sentAt,
}) {
  if (!read.asksForTime) return AskHints.none;
  final text = '${subject.trim()}. ${askOwnWords(body).trim()}';
  String? kept(String phrase) {
    final t = phrase.trim();
    return findPhrase(text, t) == null ? null : t;
  }

  WhenResolution resolve(String phrase) => resolveWhen(phrase,
      now: sentAt ?? now, zone: zone, mode: WhenMode.question);

  final whens = [
    for (final p in read.when)
      if (kept(p) case final k?) resolve(k),
  ];
  final timePhrase = kept(read.time);
  final durationPhrase = kept(read.duration);
  final meal = read.meal == AskMeal.none
      ? null
      : _meals
          .where((m) => m.word == read.meal.wire && m.re.hasMatch(text))
          .firstOrNull;

  if (whens.isEmpty &&
      timePhrase == null &&
      durationPhrase == null &&
      meal == null) {
    return AskHints.none;
  }

  final timeRead = timePhrase != null
      ? resolve(timePhrase)
      : whens.where((r) => r.time != null || r.part != null).firstOrNull ??
          resolve('');
  final named = durationPhrase == null ? null : parseDuration(durationPhrase);
  return _hintsFrom(
    dayReads: [
      for (final r in whens)
        if (r.day != null) r,
    ],
    timeRead: timeRead,
    duration: named ?? timeRead.duration,
    meal: meal,
    now: now,
    zone: zone,
  );
}

/// The rules both readers share: the days out of [dayReads] (each may carry
/// one), the hours out of [timeRead] next to [meal], the length out of
/// [duration], judged at [now] in [zone]. [readAskHints] documents every
/// rule; this is where they live, once.
AskHints _hintsFrom({
  required List<WhenResolution> dayReads,
  required WhenResolution timeRead,
  required Duration? duration,
  required _Meal? meal,
  required DateTime now,
  required CalendarZone zone,
}) {
  final today = zone.dateOf(now.toUtc());

  // Each day read, with whether it was said as a weekday (only a weekday
  // recurs).
  final picked = <(CalendarDate, bool)>[];
  for (final w in dayReads) {
    final weekday = w.dayMention == DayMention.weekday;
    var day = w.rangeEnd == null ? w.day : null;
    if (day == null) continue;
    if (day.isBefore(today)) {
      if (!weekday) continue;
      final delta = (day.weekday - today.weekday + 7) % 7;
      day = today.addDays(delta);
    }
    picked.add((day, weekday));
  }

  AskHours? hours;
  String? what;
  String? timeWords;
  int? rangeMinutes;
  // What is left of a window cut at midnight; null when it was not cut.
  int? cutWindow;
  var t = timeRead.time;
  final m = meal;
  var shifted = false;
  // A meal says which half of the day a bare hour means: 7 next to
  // "dinner" is 19:00. Breakfast keeps its morning — 8 + 12 is no
  // breakfast hour — and "coffee at 4am" keeps the am it was given.
  if (t != null &&
      m != null &&
      timeRead.timeForm == TimeForm.bare &&
      t.$1 < 12) {
    final pm = (t.$1 + 12) * 60 + t.$2;
    if (pm >= m.hours.startInMinutes - 60 && pm <= m.hours.endInMinutes + 60) {
      t = (t.$1 + 12, t.$2);
      shifted = true;
    }
  }
  // A bare or named time far outside the meal's hours is not the meal's
  // ("drinks 10pm to midnight" reads midnight last): the meal's hours stand.
  // A time with am/pm or on a 24-hour clock is the person's own word.
  if (t != null && m != null && timeRead.timeForm != TimeForm.marked) {
    final at = t.$1 * 60 + t.$2;
    if (at < m.hours.startInMinutes - _mealReachMinutes ||
        at > m.hours.endInMinutes + _mealReachMinutes) {
      t = null;
    }
  }
  if (t != null) {
    final start = t.$1 * 60 + t.$2;
    final et = timeRead.endTime;
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
  } else if (timeRead.part case final part?) {
    hours = AskHours.fromDayPart(part);
    what = _partWord(part);
    timeWords = part == DayPart.endOfDay ? 'at end of day' : 'in the $what';
  }

  final named = duration?.inMinutes;
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
  // rolled. With no hours, today stands. Judged for each day read.
  final h = hours;
  final length = Duration(
      minutes: (minutes ?? 1) < 1 ? 1 : (minutes ?? 1));
  final days = <CalendarDate>{};
  for (final (day, weekday) in picked) {
    if (day == today && h != null) {
      final close =
          zone.localDateTime(day, h.endHour, h.endMinute).toUtc();
      if (now.toUtc().add(length).isAfter(close)) {
        if (weekday) days.add(day.addDays(7));
        continue;
      }
    }
    days.add(day);
  }
  final sorted = days.toList()..sort();

  final bits = [
    if (sorted.isNotEmpty) sorted.map(shortDate).join(' or '),
    ?what,
  ];
  return AskHints(
    day: sorted.firstOrNull,
    days: List.unmodifiable(sorted),
    hours: hours,
    minutes: minutes,
    said: bits.isEmpty ? null : 'Asked for: ${bits.join(' · ')}',
    timeWords: timeWords,
  );
}
