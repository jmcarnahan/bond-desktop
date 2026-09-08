/// Reading a date out of the words a sender used.
///
/// Triage stores `messages.deadline` in the sender's own language — "Friday",
/// "before the 15th", "end of month" — because that is what the message
/// actually said, and normalising it at write time would throw away the only
/// evidence anyone could check. This is the other half of that decision: the
/// one place that turns those words into a day, for the one caller that needs
/// a day rather than a sentence.
///
/// Everything here is pure and takes `now` as an argument. A parser that read
/// the clock could not be tested at all — every expected answer would move
/// with the calendar — and the anchor has to be the READER's local day, since
/// "Friday" means their Friday.
library;

/// Full month names, index 0 = January, so a lookup is `index + 1`.
const List<String> _monthNames = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];

/// Weekday names in `DateTime.weekday` order — Monday is 1, so a lookup is
/// `index + 1`.
const List<String> _weekdayNames = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// Which month a word names, or null. Accepts the full name and the
/// three-letter form ('sept' too, which is the one four-letter abbreviation
/// people actually write).
int? _monthOf(String word) {
  final lower = word.toLowerCase();
  for (var i = 0; i < _monthNames.length; i++) {
    final name = _monthNames[i];
    if (lower == name) return i + 1;
    if (lower == name.substring(0, 3)) return i + 1;
  }
  if (lower == 'sept') return 9;
  return null;
}

/// Which weekday a word names, 1..7, or null. Full name or three letters.
int? _weekdayOf(String word) {
  final lower = word.toLowerCase();
  for (var i = 0; i < _weekdayNames.length; i++) {
    final name = _weekdayNames[i];
    if (lower == name) return i + 1;
    if (lower == name.substring(0, 3)) return i + 1;
  }
  return null;
}

/// Local midnight of the day [now] falls on — the anchor every relative answer
/// counts from, and what "not after today" is measured against.
DateTime _startOfDay(DateTime now) => DateTime(now.year, now.month, now.day);

/// A day named without a year: this year, or next year when that day has
/// already gone by.
///
/// The forward reading is the only useful one. A deadline is something the
/// sender is waiting on, so "Jan 5" written in March means the January that is
/// coming rather than the one two months behind.
DateTime _resolveYear(int month, int day, DateTime now) {
  final thisYear = DateTime(now.year, month, day);
  if (!thisYear.isBefore(_startOfDay(now))) return thisYear;
  return DateTime(now.year + 1, month, day);
}

/// The last day of the month [anchor] falls in.
DateTime _endOfMonth(DateTime anchor) =>
    DateTime(anchor.year, anchor.month + 1, 0);

final RegExp _isoDate = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})');

/// `Mar 20`, `March 20th`, `March 20, 2026`. The `(?!\d)` is what stops the
/// day part from eating the first two digits of a trailing year — without it
/// `5 Jan 2027` reads as January 20th.
final RegExp _monthFirst = RegExp(
    r'([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?!\d)(?:,?\s+(\d{4}))?');

/// `20 March`, `20 Mar 2026`. Tried BEFORE [_monthFirst], because the
/// month-first pattern would otherwise read `5 Jan 2027` as `Jan 20`.
final RegExp _dayFirst = RegExp(
    r'(\d{1,2})(?:st|nd|rd|th)?(?!\d)\s+([a-z]{3,9})\.?(?:,?\s+(\d{4}))?');

final RegExp _slashDate = RegExp(r'(\d{1,2})/(\d{1,2})(?!\d)(?:/(\d{4}))?');
final RegExp _weekdayPhrase = RegExp(r'(?:this|next|on)?\s*([a-z]{3,9})');

/// The date a deadline names, or null when it names none this parser knows.
///
/// Case-insensitive and whitespace-tolerant, and it reads a date out of a
/// SENTENCE rather than demanding one: "by 2026-03-20 please" is what a sender
/// writes, and a parser that only accepted the bare form would find a date in
/// almost nothing triage stores.
///
/// Every answer is LOCAL midnight of the named day, because the day is the
/// only part of it anybody meant. What time of day a deferral comes back is
/// [snoozeUntilFor]'s decision, not the sender's.
///
/// The grammar, in the order it is tried:
///  - ISO `YYYY-MM-DD`, anywhere in the text.
///  - `Month D` / `Mon D` / `D Month` / `D Mon`, ordinal suffix and trailing
///    year optional. Without a year, the next occurrence — see [_resolveYear].
///  - `M/D` or `M/D/YYYY`, US order, which is the app's locale.
///  - `today`, `tomorrow`, `day after tomorrow`.
///  - `end of (the) day` / `eod` / `tonight` → today.
///  - `next week` → next Monday.
///  - `end of (the) week` / `eow` → this week's Friday, or next Friday from
///    Friday onwards — a week that is already at its end means the next one.
///  - `end of (the) month` / `eom` → the last day of this month, or of next
///    month when today already is that day.
///  - a weekday name, with or without `this`/`next`/`on` in front: the next
///    occurrence strictly after today, so today's own weekday is a week away.
///    `next friday` is deliberately the SAME day as `friday` — the two mean
///    the same thing to most people who write them, and a parser that guessed
///    differently would be wrong for half its readers with no way to tell.
///
/// Anything else is null, which reads upstream as "the message named no date
/// anyone can act on" rather than as a guess.
DateTime? parseDeadline(String text, {required DateTime now}) {
  final raw = text.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();

  final iso = _isoDate.firstMatch(lower);
  if (iso != null) {
    final year = int.parse(iso.group(1)!);
    final month = int.parse(iso.group(2)!);
    final day = int.parse(iso.group(3)!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return DateTime(year, month, day);
    }
  }

  for (final match in _dayFirst.allMatches(lower)) {
    final month = _monthOf(match.group(2)!);
    if (month == null) continue;
    final day = int.parse(match.group(1)!);
    if (day < 1 || day > 31) continue;
    final year = match.group(3);
    return year == null
        ? _resolveYear(month, day, now)
        : DateTime(int.parse(year), month, day);
  }

  for (final match in _monthFirst.allMatches(lower)) {
    final month = _monthOf(match.group(1)!);
    if (month == null) continue;
    final day = int.parse(match.group(2)!);
    if (day < 1 || day > 31) continue;
    final year = match.group(3);
    return year == null
        ? _resolveYear(month, day, now)
        : DateTime(int.parse(year), month, day);
  }

  final slash = _slashDate.firstMatch(lower);
  if (slash != null) {
    final month = int.parse(slash.group(1)!);
    final day = int.parse(slash.group(2)!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      final year = slash.group(3);
      return year == null
          ? _resolveYear(month, day, now)
          : DateTime(int.parse(year), month, day);
    }
  }

  final today = _startOfDay(now);

  // Day arithmetic through the constructor rather than through `Duration`:
  // adding 24 hours across a daylight-saving boundary lands at 23:00 of the
  // day before, and every answer here is supposed to be a midnight.
  //
  // Before `tomorrow`, because it CONTAINS it.
  if (lower.contains('day after tomorrow')) {
    return DateTime(today.year, today.month, today.day + 2);
  }
  if (lower.contains('tomorrow')) {
    return DateTime(today.year, today.month, today.day + 1);
  }
  if (lower.contains('today')) return today;
  if (lower.contains('tonight') ||
      lower.contains('eod') ||
      RegExp(r'end of (the )?day').hasMatch(lower)) {
    return today;
  }

  // Before the weekday walk, so `next week` is not read as a weekday that
  // happens to start with the same letters.
  if (lower.contains('next week')) {
    return _nextWeekday(today, DateTime.monday);
  }
  if (lower.contains('eow') || RegExp(r'end of (the )?week').hasMatch(lower)) {
    // From Friday onwards the week the reader is in has already ended, so the
    // Friday they mean is the next one.
    return today.weekday >= DateTime.friday
        ? _nextWeekday(today, DateTime.friday)
        : DateTime(
            today.year,
            today.month,
            today.day + (DateTime.friday - today.weekday),
          );
  }
  if (lower.contains('eom') || RegExp(r'end of (the )?month').hasMatch(lower)) {
    final end = _endOfMonth(today);
    if (end.isAfter(today)) return end;
    return _endOfMonth(DateTime(today.year, today.month + 1, 1));
  }

  // Every word, not just the first: "reply by friday" names a day, and a
  // parser that only looked at "reply" would find none.
  for (final match in _weekdayPhrase.allMatches(lower)) {
    final day = _weekdayOf(match.group(1)!);
    if (day != null) return _nextWeekday(today, day);
  }

  return null;
}

/// The next [weekday] strictly after [today] — today's own weekday is seven
/// days away, never zero. Somebody writing a weekday name on the day itself
/// means the one coming, otherwise they would have written "today".
DateTime _nextWeekday(DateTime today, int weekday) {
  var delta = weekday - today.weekday;
  if (delta <= 0) delta += 7;
  return DateTime(today.year, today.month, today.day + delta);
}

/// The default seven-day deferral, in days.
const int _defaultSnoozeDays = 7;

/// The hour a deferred thread comes back at: the start of a working day rather
/// than midnight, so a thread that resurfaces is read on the day it names
/// instead of appearing overnight and being scrolled past by morning.
const int _snoozeHour = 9;

/// When a deferred thread should come back.
///
/// The date the sender named, at 09:00 local — a deadline is the best guess
/// anyone has about when this thread matters again, and it costs nothing to
/// use it. Seven days when there is none, and seven days when the named day is
/// NOT after today: a deadline already past would bring the thread back on the
/// very next list load, which is a Later button that visibly does nothing.
DateTime snoozeUntilFor({String? deadline, required DateTime now}) {
  final fallback = DateTime(
    now.year,
    now.month,
    now.day + _defaultSnoozeDays,
    _snoozeHour,
  );
  final text = deadline?.trim() ?? '';
  if (text.isEmpty) return fallback;
  final parsed = parseDeadline(text, now: now);
  if (parsed == null) return fallback;
  if (!parsed.isAfter(_startOfDay(now))) return fallback;
  return DateTime(parsed.year, parsed.month, parsed.day, _snoozeHour);
}

/// The two deferrals offered as one tap in the Later digest.
///
/// Two and not five: the pills sit on every row of a list the reader is
/// working DOWN, and a row that offered a date picker's worth of choices would
/// stop being a row. Anything else is a deadline the sender named, which
/// [snoozeUntilFor] already reads.
enum SnoozePreset { tomorrow, nextWeek }

/// Tomorrow at 09:00 local, or seven days on at 09:00 local — [snoozeUntilFor]'s
/// hour, because a thread that comes back should arrive at the same time of
/// day however it was deferred.
DateTime snoozePreset(SnoozePreset preset, DateTime now) => switch (preset) {
      SnoozePreset.tomorrow =>
        DateTime(now.year, now.month, now.day + 1, _snoozeHour),
      SnoozePreset.nextWeek => DateTime(
          now.year,
          now.month,
          now.day + _defaultSnoozeDays,
          _snoozeHour,
        ),
    };
