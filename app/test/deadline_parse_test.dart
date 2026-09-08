import 'package:bond_inbox/services/deadline_parse.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one place that turns a sender's words into a day.
///
/// Every case is anchored on a FIXED `now` — Tuesday 10 March 2026 — because
/// half this grammar is relative and a suite that read the clock would pass on
/// Monday and fail on Friday.
void main() {
  // A Tuesday, mid-afternoon, so the time of day never leaks into an answer
  // that is supposed to be a midnight.
  final now = DateTime(2026, 3, 10, 15);

  DateTime? parse(String text) => parseDeadline(text, now: now);

  group('dates the sender spelled out', () {
    test('ISO, bare and inside a sentence', () {
      expect(parse('2026-03-20'), DateTime(2026, 3, 20));
      expect(parse('by 2026-03-20 please'), DateTime(2026, 3, 20));
    });

    test('month and day, either order, ordinal and year optional', () {
      expect(parse('March 20'), DateTime(2026, 3, 20));
      expect(parse('Mar 20th'), DateTime(2026, 3, 20));
      expect(parse('20 March'), DateTime(2026, 3, 20));
      expect(parse('20 Mar 2026'), DateTime(2026, 3, 20));
      expect(parse('March 20, 2026'), DateTime(2026, 3, 20));
    });

    test('slashes read US order, which is the app locale', () {
      expect(parse('3/20'), DateTime(2026, 3, 20));
      expect(parse('3/20/2026'), DateTime(2026, 3, 20));
    });

    test('a day already gone by this year means next year', () {
      // A deadline is something the sender is waiting on, so it points
      // forward. January is behind March.
      expect(parse('Jan 5'), DateTime(2027, 1, 5));
    });

    test('a day the month does not have is no date at all', () {
      // DateTime would roll February 30 into March 2, and _resolveYear would
      // then find March 2 already past and push it a whole year out.
      expect(parse('February 30'), isNull);
      expect(parse('30 Feb'), isNull);
      expect(parse('2026-02-31'), isNull);
      expect(parse('2/31'), isNull);
      expect(parse('April 31, 2026'), isNull);
      // The forward window is one year, and neither 2026 nor 2027 has one.
      expect(parse('Feb 29'), isNull);
      expect(parse('Feb 29 2028'), DateTime(2028, 2, 29));
    });

    test('a year the sender gave is taken as given', () {
      expect(parse('5 Jan 2027'), DateTime(2027, 1, 5));
    });
  });

  group('days the sender named relatively', () {
    test('today, tomorrow, the day after', () {
      expect(parse('today'), DateTime(2026, 3, 10));
      expect(parse('tomorrow'), DateTime(2026, 3, 11));
      expect(parse('day after tomorrow'), DateTime(2026, 3, 12));
    });

    test('a weekday is the NEXT one, and its own weekday is a week off', () {
      expect(parse('Friday'), DateTime(2026, 3, 13));
      expect(parse('fri'), DateTime(2026, 3, 13));
      // Tuesday, written on a Tuesday, means the one coming.
      expect(parse('Tuesday'), DateTime(2026, 3, 17));
      // 'next friday' is deliberately the same day as 'friday'.
      expect(parse('next friday'), DateTime(2026, 3, 13));
      expect(parse('this friday'), DateTime(2026, 3, 13));
      expect(parse('next monday'), DateTime(2026, 3, 16));
    });

    test('a weekday buried in a sentence still counts', () {
      expect(parse('can you get back to me by friday'), DateTime(2026, 3, 13));
    });

    test('ends of things', () {
      expect(parse('end of week'), DateTime(2026, 3, 13));
      expect(parse('end of the week'), DateTime(2026, 3, 13));
      expect(parse('eow'), DateTime(2026, 3, 13));
      expect(parse('end of month'), DateTime(2026, 3, 31));
      expect(parse('eom'), DateTime(2026, 3, 31));
      expect(parse('end of day'), DateTime(2026, 3, 10));
      expect(parse('eod'), DateTime(2026, 3, 10));
      expect(parse('tonight'), DateTime(2026, 3, 10));
    });

    test('next week is next Monday', () {
      expect(parse('next week'), DateTime(2026, 3, 16));
    });

    test('end of week from a Friday is the NEXT Friday', () {
      final friday = DateTime(2026, 3, 13, 9);
      expect(parseDeadline('end of week', now: friday), DateTime(2026, 3, 20));
    });
  });

  group('what it refuses', () {
    test('words naming no day at all', () {
      expect(parse('whenever'), isNull);
      expect(parse(''), isNull);
      expect(parse('   '), isNull);
      expect(parse('Q3'), isNull);
      expect(parse('asap'), isNull);
    });

    test('a month number nobody has', () {
      expect(parse('19/40'), isNull);
    });
  });

  group('when a deferred thread comes back', () {
    test('the named day at nine in the morning', () {
      expect(
        snoozeUntilFor(deadline: 'March 20', now: now),
        DateTime(2026, 3, 20, 9),
      );
    });

    test('no deadline is seven days on', () {
      expect(snoozeUntilFor(now: now), DateTime(2026, 3, 17, 9));
      expect(snoozeUntilFor(deadline: '', now: now), DateTime(2026, 3, 17, 9));
      expect(
        snoozeUntilFor(deadline: 'whenever', now: now),
        DateTime(2026, 3, 17, 9),
      );
    });

    test('a date already past is seven days on, not the past', () {
      // Otherwise Later would hand the thread straight back on the next list
      // load, and the button would look broken.
      expect(
        snoozeUntilFor(deadline: '2026-03-01', now: now),
        DateTime(2026, 3, 17, 9),
      );
      // Today counts as past: it is not AFTER today.
      expect(
        snoozeUntilFor(deadline: 'today', now: now),
        DateTime(2026, 3, 17, 9),
      );
    });
  });

  group('the two pills', () {
    test('tomorrow and next week, both at nine', () {
      expect(
        snoozePreset(SnoozePreset.tomorrow, now),
        DateTime(2026, 3, 11, 9),
      );
      expect(
        snoozePreset(SnoozePreset.nextWeek, now),
        DateTime(2026, 3, 17, 9),
      );
    });
  });
}
