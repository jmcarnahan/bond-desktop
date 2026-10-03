import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// The when/duration grammar of the command bar. `now` is FIXED: Wednesday
/// 2026-10-14 10:42 on the Los Angeles wall clock, built through the zone so
/// no test hardcodes an offset.
void main() {
  late CalendarZone la;
  late CalendarZone auckland;
  late DateTime now;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    auckland = CalendarZone.tryNamed('Pacific/Auckland')!;
    now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
  });

  WhenResolution book(String text) =>
      resolveWhen(text, now: now, zone: la, mode: WhenMode.booking);
  WhenResolution ask(String text) =>
      resolveWhen(text, now: now, zone: la, mode: WhenMode.question);

  CalendarDate d(int m, int day, [int y = 2026]) => CalendarDate(y, m, day);

  DateTime utc(CalendarDate day, int h, [int m = 0]) {
    final t = la.localDateTime(day, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  test('the fixed now is a Wednesday', () {
    expect(book('today').day!.weekday, DateTime.wednesday);
  });

  group('relative days', () {
    test('today, tonight, tomorrow, tmrw, day after tomorrow', () {
      expect(book('today').day, d(10, 14));
      final tonight = book('tonight');
      expect(tonight.day, d(10, 14));
      expect(tonight.part, DayPart.evening);
      expect(tonight.explicitTime, isFalse);
      expect(book('tomorrow').day, d(10, 15));
      expect(book('TMRW').day, d(10, 15));
      expect(book('day after tomorrow').day, d(10, 16));
      expect(book('the day after tomorrow').day, d(10, 16));
    });

    test('"this afternoon" implies today only when no day is named', () {
      final r = ask('am I busy this afternoon');
      expect(r.day, d(10, 14));
      expect(r.part, DayPart.afternoon);
      expect(ask('Friday this afternoon').day, d(10, 16));
    });
  });

  test('the resolution says how the day was said and the time written', () {
    expect(ask('friday').dayMention, DayMention.weekday);
    expect(ask('next friday').dayMention, DayMention.weekday);
    expect(ask('tuesday next week').dayMention, DayMention.weekday);
    expect(ask('tomorrow').dayMention, DayMention.relative);
    expect(ask('tonight').dayMention, DayMention.relative);
    expect(ask('this afternoon').dayMention, DayMention.relative);
    expect(ask('Oct 20').dayMention, DayMention.date);
    expect(ask('2026-10-20').dayMention, DayMention.date);
    expect(ask('next week').dayMention, isNull,
        reason: 'a week is no day mention');
    expect(ask('at 3').dayMention, isNull);
    expect(ask('at 7').timeForm, TimeForm.bare);
    expect(ask('from 7 to 9').timeForm, TimeForm.bare);
    expect(ask('at 4am').timeForm, TimeForm.marked);
    expect(ask('at 15:00').timeForm, TimeForm.marked);
    expect(ask('at noon').timeForm, TimeForm.named);
    expect(ask('friday').timeForm, isNull);
  });

  group('weekdays', () {
    test('booking: a bare weekday is strictly after today', () {
      expect(book('Wednesday').day, d(10, 21));
      expect(book('Thursday').day, d(10, 15));
      expect(book('tue').day, d(10, 20));
      expect(book('Tues').day, d(10, 20));
      expect(book('mon').day, d(10, 19));
    });

    test('question: a bare weekday is today when it matches', () {
      expect(ask('Wednesday').day, d(10, 14));
      expect(ask('Thursday').day, d(10, 15));
      expect(ask('Tuesday').day, d(10, 20));
    });

    test('next <weekday> is the booking rule in both modes', () {
      for (final r in [book('next Wednesday'), ask('next Wednesday')]) {
        expect(r.day, d(10, 21));
      }
      expect(ask('next Thursday').day, d(10, 15));
      expect(book('next thurs').day, d(10, 15));
    });

    test('this <weekday>: this ISO week, never rolled forward', () {
      expect(book('this Friday').day, d(10, 16));
      expect(book('this Wednesday').day, d(10, 14));
      expect(book('this Sunday').day, d(10, 18));
      final passed = book('this Monday');
      expect(passed.day, isNull);
      expect(passed.unresolvedReason, 'this Monday has passed');
      expect(ask('this Monday').unresolvedReason, 'this Monday has passed');
    });

    test('a plural weekday is a habit, not a date', () {
      final r = book('send the Mondays report');
      expect(r.day, isNull);
      expect(r.isEmpty, isTrue);
      expect(book('Fridays are quiet').isEmpty, isTrue);
    });

    test('a weekday inside a longer word is not a weekday', () {
      expect(book('the wedding photos').isEmpty, isTrue);
      expect(book('a sunny satchel').isEmpty, isTrue);
    });

    test('sat, sun, mon and wed are days only in a day\'s context', () {
      const text = 'I sat with Dana tomorrow';
      final sat = book(text);
      expect(sat.day, d(10, 15));
      expect(sat.spans.map((s) => s.textIn(text)), ['tomorrow']);
      expect(book('the sun is out').isEmpty, isTrue);
      expect(book('she weds in June').day, isNull);
      // Before: on/next/this/by/until/till/before/after/every/from.
      expect(book('next sat').day, d(10, 17));
      expect(book('by sun').day, d(10, 18));
      expect(book('every mon we sync').day, d(10, 19));
      // After: a time, a date, a part of day, the end, or punctuation.
      expect(book('sun 3pm').day, d(10, 18));
      expect(book('sat at 10').day, d(10, 17));
      expect(book('wed morning').day, d(10, 21));
      expect(book('sat 10/17').day, d(10, 17));
      expect(book('sync, sat.').day, d(10, 17));
      // The other abbreviations need no context.
      expect(book('fri with Lee').day, d(10, 16));
      expect(book('thurs with Lee').day, d(10, 15));
    });
  });

  group('weeks', () {
    test('next week is next Monday through next Friday', () {
      final r = book('next week');
      expect(r.day, d(10, 19));
      expect(r.rangeEnd, d(10, 23));
      expect(r.time, isNull);
      final w = r.windowUtc!;
      expect(w.$1, utc(d(10, 19), 0));
      expect(w.$2, utc(d(10, 24), 0));
    });

    test('this week is today through Friday', () {
      final r = ask('this week');
      expect(r.day, d(10, 14));
      expect(r.rangeEnd, d(10, 16));
    });

    test('this week on a weekend is unresolved', () {
      final saturday = la.localDateTime(d(10, 17), 9, 0);
      final r = resolveWhen('this week',
          now: saturday, zone: la, mode: WhenMode.question);
      expect(r.day, isNull);
      expect(r.rangeEnd, isNull);
      expect(r.unresolvedReason, isNotNull);
    });

    test('a weekday with a week phrase lands inside that week', () {
      final r = book('Tuesday next week');
      expect(r.day, d(10, 20));
      expect(r.rangeEnd, isNull);
      expect(ask('Friday this week').day, d(10, 16));
      expect(book('Monday this week').unresolvedReason,
          'this Monday has passed');
      expect(book('Tuesday of next week').day, d(10, 20));
      expect(book('next week, Tuesday').day, d(10, 20));
      expect(book('next week Tuesday').day, d(10, 20));
    });

    test('a weekday apart from the week phrase is its own mention', () {
      // Not adjacent: the ordinary last-wins rule, so "tomorrow" wins.
      final r = book('move my Monday meeting next week to tomorrow');
      expect(r.day, d(10, 15));
      expect(r.rangeEnd, isNull);
      // And the week phrase, when it comes last, wins as a week.
      final w = book('move my Monday meeting to next week');
      expect(w.day, d(10, 19));
      expect(w.rangeEnd, d(10, 23));
    });
  });

  group('explicit dates', () {
    test('month names, day-first, ordinals, US slash, ISO', () {
      expect(book('Oct 22').day, d(10, 22));
      expect(book('22 Oct').day, d(10, 22));
      expect(book('October 22nd').day, d(10, 22));
      expect(book('the 22nd of October').day, d(10, 22));
      expect(book('10/22').day, d(10, 22));
      expect(book('2026-12-01').day, d(12, 1));
      expect(book('Oct 14').day, d(10, 14)); // today is not "passed"
      expect(book('Sept 3').day, d(9, 3, 2027));
    });

    test('a passed date rolls to next year when booking, not when asking', () {
      expect(book('Oct 2').day, d(10, 2, 2027));
      expect(ask('Oct 2').day, d(10, 2, 2026));
      expect(book('1/5').day, d(1, 5, 2027));
      expect(ask('1/5').day, d(1, 5, 2026));
    });

    test('an explicit year is kept', () {
      expect(book('Oct 2, 2026').day, d(10, 2, 2026));
      expect(book('14 Oct 2027').day, d(10, 14, 2027));
      expect(book('10/14/27').day, d(10, 14, 2027));
    });

    test('an impossible date is not a date', () {
      expect(book('Feb 30').day, isNull);
      expect(book('13/40').day, isNull);
    });

    test('"May 3pm" is a time, not May 3rd', () {
      final r = book('may 3pm work');
      expect(r.day, isNull);
      expect(r.time, (15, 0));
    });

    test('May is a month month-first, or day-first with an ordinal or "of"',
        () {
      expect(book('May 3').day, d(5, 3, 2027));
      expect(book('May 3rd').day, d(5, 3, 2027));
      expect(book('May 3, 2027').day, d(5, 3, 2027));
      expect(book('3rd May').day, d(5, 3, 2027));
      expect(book('the 3rd of May').day, d(5, 3, 2027));
      expect(book('3 of May').day, d(5, 3, 2027));
      expect(book('3 may').day, isNull);
    });

    test('"at 3 may work" is a time and a verb, not a date', () {
      const text = 'Thursday at 3 may work';
      final r = book(text);
      expect(r.day, d(10, 15));
      expect(r.time, (15, 0));
      expect(r.spans.map((s) => s.textIn(text)), ['Thursday', 'at 3']);
    });
  });

  group('clock times', () {
    test('a bare hour is daytime-first: 1-6 PM, 7-11 AM, 12 noon', () {
      const expected = {
        1: 13,
        2: 14,
        3: 15,
        4: 16,
        5: 17,
        6: 18,
        7: 7,
        8: 8,
        9: 9,
        10: 10,
        11: 11,
        12: 12,
      };
      for (final entry in expected.entries) {
        expect(book('tomorrow at ${entry.key}').time, (entry.value, 0),
            reason: 'at ${entry.key}');
      }
    });

    test('explicit am/pm and 24-hour forms win', () {
      expect(book('3pm').time, (15, 0));
      expect(book('3 pm').time, (15, 0));
      expect(book('3:30pm').time, (15, 30));
      expect(book('3:30 p.m.').time, (15, 30));
      expect(book('7pm').time, (19, 0));
      expect(book('5am').time, (5, 0));
      expect(book('12am').time, (0, 0));
      expect(book('12pm').time, (12, 0));
      expect(book('15:00').time, (15, 0));
      expect(book('09:30').time, (9, 30));
      expect(book('3:30').time, (15, 30)); // bare hour with minutes
      expect(book('at 3').time, (15, 0));
      expect(book("3 o'clock").time, (15, 0));
    });

    test('noon and midnight', () {
      expect(book('at noon').time, (12, 0));
      expect(book('12 noon').time, (12, 0));
      expect(book('midnight').time, (0, 0));
      expect(book('midnight').day, isNull);
    });

    test('midnight with tonight is the next date\'s 00:00', () {
      for (final text in [
        'midnight tonight',
        'tonight at 12',
        '12am tonight',
      ]) {
        final r = book(text);
        expect(r.day, d(10, 15), reason: text);
        expect(r.time, (0, 0), reason: text);
        expect(r.part, isNull, reason: text);
        expect(r.startUtc, utc(d(10, 15), 0), reason: text);
      }
      // Any other time tonight stays tonight.
      expect(book('tonight at 8').day, d(10, 14));
    });

    test('a bare number is not a time', () {
      expect(book('invite 3 people').time, isNull);
      expect(book('book 1:1 with Priya').time, isNull);
      expect(book('invite 3 people').isEmpty, isTrue);
    });

    test('a part of day reads a bare hour: tonight at 8 is 20:00', () {
      expect(book('tonight at 8').time, (20, 0));
      expect(book('tomorrow morning at 6').time, (6, 0));
      expect(book('Thursday afternoon at 1').time, (13, 0));
      // An explicit am/pm still wins.
      expect(book('tomorrow evening at 8am').part, isNull);
    });

    test('explicitTime is set exactly when a time is', () {
      expect(book('3pm').explicitTime, isTrue);
      expect(book('morning').explicitTime, isFalse);
      expect(book('Thursday').explicitTime, isFalse);
    });
  });

  group('ranges', () {
    test('forms', () {
      void range(String text, (int, int) start, (int, int) end) {
        final r = book(text);
        expect(r.time, start, reason: text);
        expect(r.endTime, end, reason: text);
        expect(r.explicitTime, isTrue, reason: text);
      }

      range('2-3pm', (14, 0), (15, 0));
      range('2–3pm', (14, 0), (15, 0));
      range('from 2 to 3', (14, 0), (15, 0));
      range('2pm to 3:30pm', (14, 0), (15, 30));
      range('10-10:30', (10, 0), (10, 30));
      range('11-1pm', (11, 0), (13, 0));
      range('from 6 to 7', (18, 0), (19, 0));
      range('between 1 and 2', (13, 0), (14, 0));
      range('9am-12', (9, 0), (12, 0));
      range('14:00-15:30', (14, 0), (15, 30));
    });

    test('a range past midnight ends on the next local day', () {
      final r = book('Friday 10pm-1am');
      expect(r.time, (22, 0));
      expect(r.endTime, (1, 0));
      final w = r.windowUtc!;
      expect(w.$1, utc(d(10, 16), 22));
      expect(w.$2, utc(d(10, 17), 1));
    });

    test('an unmarked "2-3" is not a range', () {
      expect(book('2-3 people').isEmpty, isTrue);
    });

    test('a both-marked range that runs backwards is not a range', () {
      final r = book('3pm-2pm');
      expect(r.endTime, isNull);
      expect(r.spans.map((s) => s.kind), isNot(contains(WhenKind.range)));
      // Crossing pm to am still runs past midnight.
      expect(book('10pm-1am').endTime, (1, 0));
      expect(book('10am-1am').endTime, isNull);
    });

    test('"my 3pm to 4pm" is a meeting and a target, not a range', () {
      final r = book('move my 3pm to 4pm');
      expect(r.time, (16, 0));
      expect(r.endTime, isNull);
      expect(r.spans.map((s) => s.kind), [WhenKind.time, WhenKind.time]);
    });

    test('a move verb reads "3pm to 4pm" as a meeting and a target', () {
      for (final text in [
        'move 3pm to 4pm',
        'push 3pm to 4pm',
        'reschedule 3pm to 4pm',
        'can you shift 2pm to 3pm tomorrow',
      ]) {
        final r = book(text);
        expect(r.endTime, isNull, reason: text);
        expect(r.spans.where((s) => s.kind == WhenKind.time), hasLength(2),
            reason: text);
      }
      // "from" and a dash still make a range, verb or not.
      expect(book('move it from 3pm to 4pm').endTime, (16, 0));
      expect(book('move it to 3-4pm').endTime, (16, 0));
      // A verb in an earlier sentence moves nothing in this one.
      expect(book('I moved it. Book 3pm to 4pm').endTime, (16, 0));
    });

    test('the range window uses the range end', () {
      final w = book('tomorrow 2-3:30pm').windowUtc!;
      expect(w.$1, utc(d(10, 15), 14));
      expect(w.$2, utc(d(10, 15), 15, 30));
    });
  });

  group('parts of day', () {
    test('each part and its window', () {
      final cases = {
        'tomorrow morning': (DayPart.morning, 9, 12),
        'tomorrow afternoon': (DayPart.afternoon, 12, 17),
        'tomorrow evening': (DayPart.evening, 17, 20),
        'tomorrow EOD': (DayPart.endOfDay, 16, 17),
        'tomorrow end of day': (DayPart.endOfDay, 16, 17),
        'tomorrow over lunch': (DayPart.lunch, 12, 13),
        'tomorrow lunchtime': (DayPart.lunch, 12, 13),
      };
      for (final entry in cases.entries) {
        final r = book(entry.key);
        final (part, from, to) = entry.value;
        expect(r.part, part, reason: entry.key);
        expect(r.time, isNull, reason: entry.key);
        expect(r.explicitTime, isFalse, reason: entry.key);
        expect(r.windowUtc, (utc(d(10, 15), from), utc(d(10, 15), to)),
            reason: entry.key);
      }
    });

    test('end of day is a window, never 17:00 as an explicit time', () {
      final r = book('Friday EOD');
      expect(r.part, DayPart.endOfDay);
      expect(r.time, isNull);
      expect(r.startUtc, isNull);
    });
  });

  group('durations', () {
    test('parseDuration table', () {
      const table = {
        '30 min': 30,
        '30 mins': 30,
        '30m': 30,
        'half an hour': 30,
        'half hour': 30,
        'a half hour': 30,
        'an hour': 60,
        '1 hour': 60,
        '1h': 60,
        '90m': 90,
        '1.5h': 90,
        '1.5 hours': 90,
        '2 hours': 120,
        '2 hrs': 120,
        '45 minutes': 45,
        'for 20 minutes': 20,
        '1h 30m': 90,
        '1 hour and 15 minutes': 75,
        'an hour and a half': 90,
        'fifteen minutes': 15,
        'two hours': 120,
        'forty-five minutes': 45,
      };
      for (final entry in table.entries) {
        expect(parseDuration('book ${entry.key} with Lee'),
            Duration(minutes: entry.value),
            reason: entry.key);
      }
    });

    test('parseDuration is null when absent, and ignores clock times', () {
      expect(parseDuration('book Lee tomorrow'), isNull);
      expect(parseDuration('at 3pm'), isNull);
      expect(parseDuration('10:30'), isNull);
      expect(parseDuration('the Mondays report'), isNull);
      expect(parseDuration(''), isNull);
    });

    test('a duration sets the window length after an explicit time', () {
      final r = book('tomorrow at 3 for 90 minutes');
      expect(r.duration, const Duration(minutes: 90));
      final w = r.windowUtc!;
      expect(w.$2.difference(w.$1), const Duration(minutes: 90));
    });

    test('with no duration an explicit time gets 30 minutes', () {
      final w = book('tomorrow at 3').windowUtc!;
      expect(w.$1, utc(d(10, 15), 15));
      expect(w.$2, utc(d(10, 15), 15, 30));
    });
  });

  group('never invent a time', () {
    test('a day alone has no time and the working-day window', () {
      for (final text in ['Thursday', 'tomorrow', 'Oct 22', 'next Friday']) {
        final r = book(text);
        expect(r.time, isNull, reason: text);
        expect(r.part, isNull, reason: text);
        expect(r.explicitTime, isFalse, reason: text);
        expect(r.startUtc, isNull, reason: text);
        final w = r.windowUtc!;
        expect(la.toLocal(w.$1).hour, 8, reason: text);
        expect(la.toLocal(w.$2).hour, 18, reason: text);
      }
    });

    test('a time with no day leaves the day to the caller', () {
      final r = book('at 3pm');
      expect(r.time, (15, 0));
      expect(r.day, isNull);
      expect(r.startUtc, isNull);
      expect(r.windowUtc, isNull);
      expect(r.today, d(10, 14));
    });
  });

  group('spans', () {
    test('each span is exactly the phrase it consumed', () {
      const text = 'Book 30 min with Lee next Tuesday from 2 to 3 afternoon';
      final r = book(text);
      expect(r.spans.map((s) => s.textIn(text)).toList(),
          ['30 min', 'next Tuesday', 'from 2 to 3', 'afternoon']);
      expect(r.spans.map((s) => s.kind).toList(), [
        WhenKind.duration,
        WhenKind.day,
        WhenKind.range,
        WhenKind.part,
      ]);
    });

    test('prefixes are consumed with their phrase', () {
      const text = 'lunch on Friday at noon for an hour';
      final r = book(text);
      expect(r.spans.map((s) => s.textIn(text)).toList(),
          ['lunch', 'on Friday', 'at noon', 'for an hour']);
    });

    test('the leftover words are the subject', () {
      const text = 'block 90m for the budget review tomorrow';
      final r = book(text);
      final kept = StringBuffer();
      var i = 0;
      for (final s in r.spans) {
        kept.write(text.substring(i, s.start));
        i = s.end;
      }
      kept.write(text.substring(i));
      expect(kept.toString().split(RegExp(r'\s+')).where((w) => w.isNotEmpty),
          ['block', 'for', 'the', 'budget', 'review']);
    });

    test('matching is case-insensitive', () {
      expect(book('TOMORROW AT 3PM').startUtc, utc(d(10, 15), 15));
    });
  });

  group('zones', () {
    test('Pacific/Auckland: today is already tomorrow there', () {
      // 20:00 UTC on Oct 14 is 09:00 Thursday Oct 15 in Auckland (NZDT).
      final instant = DateTime.utc(2026, 10, 14, 20);
      WhenResolution nz(String text) => resolveWhen(text,
          now: instant, zone: auckland, mode: WhenMode.booking);
      expect(nz('today').day, d(10, 15));
      expect(nz('tomorrow').day, d(10, 16));
      expect(nz('Thursday').day, d(10, 22)); // booking: strictly after today
      expect(
          resolveWhen('Thursday',
                  now: instant, zone: auckland, mode: WhenMode.question)
              .day,
          d(10, 15));
      // The same instant in Los Angeles is still Wednesday.
      expect(
          resolveWhen('today', now: instant, zone: la, mode: WhenMode.booking)
              .day,
          d(10, 14));
      // Instants are built on Auckland's wall clock.
      final start = nz('tomorrow at 9am').startUtc!;
      expect(start, DateTime.utc(2026, 10, 15, 20));
    });

    test('spring forward: a nonexistent wall time resolves forward, no throw',
        () {
      final saturday = la.localDateTime(d(3, 7), 12, 0);
      WhenResolution r(String text) => resolveWhen(text,
          now: saturday, zone: la, mode: WhenMode.booking);
      final skipped = r('tomorrow at 2:30am');
      expect(skipped.day, d(3, 8));
      expect(skipped.time, (2, 30));
      // 02:30 does not exist on 2026-03-08 in Los Angeles; the timezone
      // package reads it as 03:30 PDT (10:30 UTC).
      expect(skipped.startUtc, DateTime.utc(2026, 3, 8, 10, 30));
      // A range the gap swallows keeps its nominal length.
      final w = r('tomorrow 2-3am').windowUtc!;
      expect(w.$2.difference(w.$1), const Duration(hours: 1));
      // The working day is 08:00-18:00 PDT: ten real hours.
      final day = r('tomorrow').windowUtc!;
      expect(day.$1, DateTime.utc(2026, 3, 8, 15));
      expect(day.$2.difference(day.$1), const Duration(hours: 10));
    });

    test('fall back: a repeated wall time is its first occurrence', () {
      final r = resolveWhen('Nov 1 at 1:30am',
          now: now, zone: la, mode: WhenMode.booking);
      expect(r.startUtc, DateTime.utc(2026, 11, 1, 8, 30)); // 01:30 PDT
      final day = resolveWhen('Nov 1',
              now: now, zone: la, mode: WhenMode.booking)
          .windowUtc!;
      expect(day.$2.difference(day.$1), const Duration(hours: 10));
    });
  });

  group('nothing to read', () {
    test('unknown text gives an empty resolution', () {
      for (final text in ['', 'hello world', 'ping Contoso about the deck']) {
        final r = book(text);
        expect(r.isEmpty, isTrue, reason: text);
        expect(r.day, isNull);
        expect(r.time, isNull);
        expect(r.part, isNull);
        expect(r.duration, isNull);
        expect(r.unresolvedReason, isNull);
        expect(r.windowUtc, isNull);
      }
    });
  });

  group('paraphrases', () {
    // (input, mode, day, rangeEnd, time, endTime, part, minutes)
    final rows = <(
      String,
      WhenMode,
      String?,
      String?,
      (int, int)?,
      (int, int)?,
      DayPart?,
      int?,
    )>[
      ('move my 3pm with Dana to tomorrow morning', WhenMode.booking,
          '2026-10-15', null, null, null, DayPart.morning, null),
      ('find 30 min with Lee next week', WhenMode.booking, '2026-10-19',
          '2026-10-23', null, null, null, 30),
      ('am I free Thursday afternoon?', WhenMode.question, '2026-10-15', null,
          null, null, DayPart.afternoon, null),
      ('book 1:1 with Priya fri 2-2:30', WhenMode.booking, '2026-10-16', null,
          (14, 0), (14, 30), null, null),
      ('block 90m for the budget review tomorrow', WhenMode.booking,
          '2026-10-15', null, null, null, null, 90),
      ('decline the offsite on Oct 22', WhenMode.booking, '2026-10-22', null,
          null, null, null, null),
      ("what's on my calendar today?", WhenMode.question, '2026-10-14', null,
          null, null, null, null),
      ('am I free Wednesday at 3?', WhenMode.question, '2026-10-14', null,
          (15, 0), null, null, null),
      ('schedule Wednesday at 3 with Contoso', WhenMode.booking, '2026-10-21',
          null, (15, 0), null, null, null),
      ('set up an hour with Fabrikam next Tuesday', WhenMode.booking,
          '2026-10-20', null, null, null, null, 60),
      ('lunch with Sam on Friday', WhenMode.booking, '2026-10-16', null, null,
          null, DayPart.lunch, null),
      ('push the design review to Monday 10am', WhenMode.booking,
          '2026-10-19', null, (10, 0), null, null, null),
      ('cancel my 4pm today', WhenMode.booking, '2026-10-14', null, (16, 0),
          null, null, null),
      ('move the Contoso sync to 2pm tomorrow', WhenMode.booking,
          '2026-10-15', null, (14, 0), null, null, null),
      ('book half an hour with Jordan tomorrow afternoon', WhenMode.booking,
          '2026-10-15', null, null, null, DayPart.afternoon, 30),
      ('any time EOD thursday for a quick call', WhenMode.booking,
          '2026-10-15', null, null, null, DayPart.endOfDay, null),
      ('set a 45 minutes review on 10/20 at 9', WhenMode.booking,
          '2026-10-20', null, (9, 0), null, null, 45),
      ('hold 2 hours next Thursday morning', WhenMode.booking, '2026-10-15',
          null, null, null, DayPart.morning, 120),
      ('meet Alex tonight at 7', WhenMode.booking, '2026-10-14', null,
          (19, 0), null, DayPart.evening, null),
      ('am I busy this afternoon', WhenMode.question, '2026-10-14', null,
          null, null, DayPart.afternoon, null),
      ('what do I have next week', WhenMode.question, '2026-10-19',
          '2026-10-23', null, null, null, null),
      ('coffee with Riley day after tomorrow at noon', WhenMode.booking,
          '2026-10-16', null, (12, 0), null, null, null),
      ('reschedule the standup to Tue 9:15', WhenMode.booking, '2026-10-20',
          null, (9, 15), null, null, null),
      ('free for 20 minutes Friday between 1 and 2?', WhenMode.question,
          '2026-10-16', null, (13, 0), (14, 0), null, 20),
      ('block from 2 to 3:30 on Thursday for planning', WhenMode.booking,
          '2026-10-15', null, (14, 0), (15, 30), null, null),
      ('invite the Fabrikam team for 1.5 hours on Nov 3', WhenMode.booking,
          '2026-11-03', null, null, null, null, 90),
      ("what's happening this week", WhenMode.question, '2026-10-14',
          '2026-10-16', null, null, null, null),
      ('put 15 min on my calendar at 4:45pm', WhenMode.booking, null, null,
          (16, 45), null, null, 15),
      ("decline Monday's all hands", WhenMode.booking, '2026-10-19', null,
          null, null, null, null),
      ('is Dana free Oct 2?', WhenMode.question, '2026-10-02', null, null,
          null, null, null),
      ('book the retro for Oct 2', WhenMode.booking, '2027-10-02', null, null,
          null, null, null),
      ('can we do tmrw 11-11:30?', WhenMode.booking, '2026-10-15', null,
          (11, 0), (11, 30), null, null),
      ('1:1 with Priya this Friday at 10:30', WhenMode.booking, '2026-10-16',
          null, (10, 30), null, null, null),
      ('quick chat at 1 tomorrow for 15 mins', WhenMode.booking, '2026-10-15',
          null, (13, 0), null, null, 15),
      ('an hour with Jordan Thursday over lunch', WhenMode.booking,
          '2026-10-15', null, null, null, DayPart.lunch, 60),
      ('move the budget review to 10/21 3-4pm', WhenMode.booking,
          '2026-10-21', null, (15, 0), (16, 0), null, null),
      ('anything on Saturday evening?', WhenMode.question, '2026-10-17', null,
          null, null, DayPart.evening, null),
      ('book the offsite on 14 Nov', WhenMode.booking, '2026-11-14', null,
          null, null, null, null),
      ('set up the Contoso kickoff next week for an hour and a half',
          WhenMode.booking, '2026-10-19', '2026-10-23', null, null, null, 90),
      ('remind the team about the Mondays report', WhenMode.booking, null,
          null, null, null, null, null),
      ('Tuesday next week at 3:30 with Sam', WhenMode.booking, '2026-10-20',
          null, (15, 30), null, null, null),
      ('move Monday\'s standup to Tuesday', WhenMode.booking, '2026-10-20',
          null, null, null, null, null),
      ('move 3pm to 4pm', WhenMode.booking, null, null, (16, 0), null, null,
          null),
      ('book 3pm to 4pm tomorrow', WhenMode.booking, '2026-10-15', null,
          (15, 0), (16, 0), null, null),
      ('I sat with Dana tomorrow', WhenMode.booking, '2026-10-15', null, null,
          null, null, null),
      ('sun 3pm', WhenMode.booking, '2026-10-18', null, (15, 0), null, null,
          null),
      ('next sat', WhenMode.booking, '2026-10-17', null, null, null, null,
          null),
      ('Thursday at 3 may work', WhenMode.booking, '2026-10-15', null,
          (15, 0), null, null, null),
      ('move my Monday meeting next week to tomorrow', WhenMode.booking,
          '2026-10-15', null, null, null, null, null),
      ('3pm-2pm', WhenMode.booking, null, null, (15, 0), null, null, null),
      ('midnight tonight', WhenMode.booking, '2026-10-15', null, (0, 0), null,
          null, null),
      ('tonight at 12', WhenMode.booking, '2026-10-15', null, (0, 0), null,
          null, null),
      ('midnight', WhenMode.booking, null, null, (0, 0), null, null, null),
    ];

    for (final (text, mode, day, rangeEnd, time, endTime, part, minutes)
        in rows) {
      test('${mode.name}: $text', () {
        final r = resolveWhen(text, now: now, zone: la, mode: mode);
        expect(r.day?.toIso(), day, reason: 'day');
        expect(r.rangeEnd?.toIso(), rangeEnd, reason: 'rangeEnd');
        expect(r.time, time, reason: 'time');
        expect(r.endTime, endTime, reason: 'endTime');
        expect(r.part, part, reason: 'part');
        expect(r.duration?.inMinutes, minutes, reason: 'duration');
        expect(r.explicitTime, time != null, reason: 'explicitTime');
        for (final s in r.spans) {
          expect(s.textIn(text).trim(), s.textIn(text),
              reason: 'a span never starts or ends in whitespace');
        }
      });
    }
  });
}
