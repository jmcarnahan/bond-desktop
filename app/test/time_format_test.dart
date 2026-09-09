import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Inbox table's stamp.
///
/// Every fixture here is a LOCAL `DateTime`, and `toIso8601String()` on one
/// carries no `Z` — so it parses back as local and the assertion holds in every
/// zone this suite runs in. A UTC fixture would pin a different string on every
/// machine, which is the one thing a date test must not do.

String _at(int year, int month, int day, int hour, int minute) =>
    DateTime(year, month, day, hour, minute).toIso8601String();

void main() {
  group('feedStamp', () {
    final noon = DateTime(2026, 9, 3, 12);

    test('drops the day when it is today, and only then', () {
      expect(feedStamp(_at(2026, 9, 3, 9, 5), noon), '9:05 AM');
      expect(feedStamp(_at(2026, 9, 3, 23, 59), noon), '11:59 PM');
    });

    test('keeps the day on every other one', () {
      expect(feedStamp(_at(2026, 9, 2, 9, 5), noon), 'Sep 2, 9:05 AM');
      expect(feedStamp(_at(2026, 8, 28, 16, 30), noon), 'Aug 28, 4:30 PM');
      // Later today's calendar day is still today, even though it is ahead of
      // the clock — a stamp is not an age.
      expect(feedStamp(_at(2026, 9, 4, 1, 0), noon), 'Sep 4, 1:00 AM');
    });

    test('the calendar day is what decides, not the hours between', () {
      // Ninety minutes apart, and on two different days: the row that arrived
      // late last night has to say so.
      final justAfterMidnight = DateTime(2026, 9, 3, 0, 30);
      expect(
        feedStamp(_at(2026, 9, 2, 23, 0), justAfterMidnight),
        'Sep 2, 11:00 PM',
      );
    });

    test('anything unparseable is nothing, never an exception', () {
      expect(feedStamp(null, noon), isNull);
      expect(feedStamp('', noon), isNull);
      expect(feedStamp('not a date', noon), isNull);
    });
  });
}
