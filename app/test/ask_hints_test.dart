import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an ask's own words say about the time it wants: the day, the hours
/// and the length, read from fictional mail. Wednesday Oct 7 2026, 9:00 AM in
/// Los Angeles.
void main() {
  late CalendarZone la;
  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  final now = DateTime.utc(2026, 10, 7, 16);
  const friday = CalendarDate(2026, 10, 9);

  AskHints read(String subject, [String body = '']) =>
      readAskHints(subject: subject, body: body, now: now, zone: la);

  test('dinner on friday: that Friday, the evening, an hour and a half', () {
    final h = read('dinner on friday', 'could we grab dinner on Friday?');
    expect(h.day, friday);
    expect(h.hours,
        const AskHours(startHour: 17, startMinute: 30, endHour: 20, endMinute: 30));
    expect(h.minutes, 90);
    expect(h.said, 'Asked for: Fri Oct 9 · dinner');
    expect(h.any, isTrue);
  });

  test('a meal word wins over a part of the day', () {
    final h = read('coffee tuesday morning?');
    expect(h.day, const CalendarDate(2026, 10, 13));
    expect(h.hours,
        const AskHours(startHour: 9, startMinute: 0, endHour: 16, endMinute: 0));
    expect(h.minutes, 30);
    expect(h.said, 'Asked for: Tue Oct 13 · coffee');
  });

  test('a part alone gives its own bounds', () {
    final h = read('Sync', 'Thursday afternoon works for me');
    expect(h.day, const CalendarDate(2026, 10, 8));
    expect(h.hours, AskHours.fromDayPart(DayPart.afternoon));
    expect(h.minutes, isNull);
    expect(h.said, 'Asked for: Thu Oct 8 · afternoon');
  });

  test('lunch next week: a week is not a day, and lunch is wider than '
      'the command bar\'s hour', () {
    final h = read('Lunch next week?');
    expect(h.day, isNull);
    expect(h.hours,
        const AskHours(startHour: 11, startMinute: 30, endHour: 13, endMinute: 30));
    expect(h.minutes, 60);
    expect(h.said, 'Asked for: lunch');
  });

  test('an explicit time beats everything, two hours from it, and a named '
      'length beats the default', () {
    final h = read('Northwind review', 'How about 3pm on thursday for 45 min?');
    expect(h.day, const CalendarDate(2026, 10, 8));
    expect(h.hours,
        const AskHours(startHour: 15, startMinute: 0, endHour: 17, endMinute: 0));
    expect(h.minutes, 45);
    expect(h.said, 'Asked for: Thu Oct 8 · 3:00 PM');
  });

  test('nothing about a time reads nothing', () {
    final h = read('Quick sync', 'Can we do a quick sync about the deck?');
    expect(h.any, isFalse);
    expect(h.said, isNull);
  });

  test('a day already past rolls to that weekday\'s next occurrence', () {
    // Fri Oct 2 has gone by Wednesday Oct 7: the person meant a Friday.
    final h = read('Dinner Oct 2?');
    expect(h.day, friday);
  });

  test('only the opening of a long message is read', () {
    final h = read('Catch up', '${'x ' * 400}dinner on friday');
    expect(h.any, isFalse);
  });

  test('a meal says which half of the day a bare hour is', () {
    final dinner = read('dinner at 7 on friday?');
    expect(dinner.day, friday);
    expect(dinner.hours,
        const AskHours(startHour: 19, startMinute: 0, endHour: 21, endMinute: 0));
    expect(dinner.said, 'Asked for: Fri Oct 9 · dinner · 7:00 PM');
    expect(dinner.minutes, 90);
    final breakfast = read('breakfast at 8?');
    expect(breakfast.hours,
        const AskHours(startHour: 8, startMinute: 0, endHour: 10, endMinute: 0));
    expect(breakfast.minutes, 45);
  });

  test('a range ends where it says, and is the length', () {
    final h = read('Thursday 2-3:30pm?');
    expect(h.hours,
        const AskHours(startHour: 14, startMinute: 0, endHour: 15, endMinute: 30));
    expect(h.minutes, 90);
  });

  test('a quoted reply\'s dates never win', () {
    final h = read('Dinner Friday?',
        'Dinner Friday?\n\nOn Mon, Sep 28, 2026 at 3:15 PM Dana Ortiz\n'
        '<dana@fabrikam.example> wrote:\n> lunch on Tuesday at noon?');
    expect(h.day, friday);
    expect(h.hours?.startHour, 17, reason: 'dinner, not the 3:15 PM above');
    final outlook = read('Dinner Friday?',
        'Dinner Friday?\n-----Original Message-----\nFrom: Dana\n'
        'Sent: Monday 3pm');
    expect(outlook.hours?.startHour, 17);
  });

  test('at 11pm is cut at the day\'s last minute', () {
    final h = read('Drinks at 11pm?');
    expect(h.hours,
        const AskHours(startHour: 23, startMinute: 0, endHour: 23, endMinute: 59));
  });

  test('drinks, a drink and happy hour are the evening drink', () {
    for (final text in [
      'drinks on thursday?',
      'grab a drink thursday?',
      'happy hour thursday?',
    ]) {
      final h = read(text);
      expect(h.hours,
          const AskHours(startHour: 17, startMinute: 0, endHour: 19, endMinute: 30),
          reason: text);
      expect(h.minutes, 60, reason: text);
    }
  });

  test('breakfast alone is the early morning', () {
    final h = read('Breakfast friday?');
    expect(h.hours,
        const AskHours(startHour: 7, startMinute: 30, endHour: 9, endMinute: 30));
    expect(h.minutes, 45);
  });

  test('lunchtime is the lunch meal, with its length', () {
    final h = read('Thursday lunchtime?');
    expect(h.hours,
        const AskHours(startHour: 11, startMinute: 30, endHour: 13, endMinute: 30));
    expect(h.minutes, 60);
  });

  test('a coffeehouse is not coffee', () {
    final h = read('Meet at the coffeehouse on friday?');
    expect(h.day, friday);
    expect(h.hours, isNull);
  });

  test('a past day on today\'s weekday is today (seven days back at most)',
      () {
    // Wed Sep 30 read on Wed Oct 7: the weekday is today.
    expect(read('Dinner Sep 30?').day, const CalendarDate(2026, 10, 7));
  });

  test('a day long past is dropped, not rolled', () {
    expect(read('Dinner Jan 5?').day, isNull);
  });

  test('yesterday is no day', () {
    expect(read('Sorry I missed you yesterday').day, isNull);
  });

  test('the cap never halves a time', () {
    // Cut at 600 units mid-word this would read "at 1".
    final h = read('', '${'a' * 593} at 11pm');
    expect(h.hours, isNull);
  });

  test('today\'s hours already over roll the day a week on', () {
    // Friday Oct 9 2026 in Los Angeles: 21:00, then 15:00.
    final late = readAskHints(
        subject: 'dinner on friday?',
        body: '',
        now: DateTime.utc(2026, 10, 10, 4),
        zone: la);
    expect(late.day, const CalendarDate(2026, 10, 16));
    expect(late.said, 'Asked for: Fri Oct 16 · dinner');
    final early = readAskHints(
        subject: 'dinner on friday?',
        body: '',
        now: DateTime.utc(2026, 10, 9, 22),
        zone: la);
    expect(early.day, const CalendarDate(2026, 10, 9));
    // No hours: today stands, whatever the time.
    final bare = readAskHints(
        subject: 'friday?',
        body: 'can we talk on friday?',
        now: DateTime.utc(2026, 10, 10, 4),
        zone: la);
    expect(bare.day, const CalendarDate(2026, 10, 9));
  });

  test('too late today is now plus the meeting past the close', () {
    // Friday Oct 9: at 19:30 a 90-minute dinner no longer fits by 20:30.
    final late = readAskHints(
        subject: 'dinner on friday?',
        body: '',
        now: DateTime.utc(2026, 10, 10, 2, 30),
        zone: la);
    expect(late.day, const CalendarDate(2026, 10, 16));
    // At 18:30 it still does.
    final inTime = readAskHints(
        subject: 'dinner on friday?',
        body: '',
        now: DateTime.utc(2026, 10, 10, 1, 30),
        zone: la);
    expect(inTime.day, const CalendarDate(2026, 10, 9));
  });

  test('the time words say how the hours were asked for', () {
    expect(read('dinner on friday?').timeWords, 'for dinner');
    expect(read('Thursday afternoon?').timeWords, 'in the afternoon');
    expect(read('3pm thursday?').timeWords, 'at 3:00 PM');
    expect(read('dinner at 7 friday?').timeWords, 'for dinner at 7:00 PM');
    expect(read('friday?').timeWords, isNull);
  });
}
