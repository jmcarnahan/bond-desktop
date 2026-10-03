import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:bond_inbox/services/llm/ask_read_task.dart';
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

  test('a date already past is dropped; only a weekday rolls', () {
    // Fri Oct 2 has gone by Wednesday Oct 7: "Oct 2" named that one day,
    // so it is no day now (the hours stand); "Friday" means a Friday.
    final dated = read('Dinner Oct 2?');
    expect(dated.day, isNull);
    expect(dated.hours?.startHour, 17);
    expect(dated.said, 'Asked for: dinner');
    expect(read('Dinner Friday?').day, friday);
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

  test('a past date is dropped even on today\'s weekday; the hours stay',
      () {
    // Wed Sep 30 read on Wed Oct 7: "Sep 30" named that day, not Wednesdays.
    final h = read('Dinner Sep 30?');
    expect(h.day, isNull);
    expect(h.hours?.startHour, 17);
  });

  test('a date long past is dropped, not rolled', () {
    expect(read('Dinner Jan 5?').day, isNull);
  });

  test('a weekday in a month-old ask still open rolls to its next '
      'occurrence, not dropped', () {
    // Sent Monday Aug 31 (late evening in LA): "friday" was Sep 4. Read on
    // Saturday Oct 3 the ask is still open, and the nearest Friday is the
    // answer: Oct 9 — not "no day" (the owner's live case, 2026-10-03).
    final h = readAskHints(
        subject: 'dinner on friday',
        body: 'want to get dinner on friday',
        now: DateTime.utc(2026, 10, 3, 16, 40),
        sentAt: DateTime.utc(2026, 9, 1, 2, 34),
        zone: la);
    expect(h.day, const CalendarDate(2026, 10, 9));
    expect(h.said, 'Asked for: Fri Oct 9 · dinner');
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

  group('read closer', () {
    // Wed Oct 7 2026, 9:00 PM in Los Angeles.
    final nine = DateTime.utc(2026, 10, 8, 4);
    // Mon Oct 5 and Tue Oct 6 2026, 10:00 AM and 6:00 PM in Los Angeles.
    final monday = DateTime.utc(2026, 10, 5, 17);
    final tuesdayEvening = DateTime.utc(2026, 10, 7, 1);

    test('a meal moves a range\'s bare end with its start', () {
      final dinner = read('dinner from 7 to 9');
      expect(dinner.hours,
          const AskHours(startHour: 19, startMinute: 0, endHour: 21, endMinute: 0));
      expect(dinner.minutes, 120);
      final lunch = read('lunch from 11 to 1');
      expect(lunch.hours,
          const AskHours(startHour: 11, startMinute: 0, endHour: 13, endMinute: 0));
      expect(lunch.minutes, 120);
    });

    test('a relative day whose hours are over is dropped, a weekday rolls',
        () {
      final tonight = readAskHints(
          subject: 'Today dinner?', body: '', now: nine, zone: la);
      expect(tonight.day, isNull);
      expect(tonight.hours,
          const AskHours(startHour: 17, startMinute: 30, endHour: 20, endMinute: 30));
      expect(tonight.minutes, 90);
      expect(tonight.said, 'Asked for: dinner');
      final weekday = readAskHints(
          subject: 'Wednesday dinner?', body: '', now: nine, zone: la);
      expect(weekday.day, const CalendarDate(2026, 10, 14));
    });

    test('a From: that starts a sentence is no header', () {
      final h = read('Catch up', 'Hi,\nFrom: tomorrow on I am free for dinner.');
      expect(h.day, const CalendarDate(2026, 10, 8));
      expect(h.hours?.startHour, 17);
      // A real header pair, quoted, still cuts.
      final quoted = read('Dinner Friday?',
          'Dinner Friday?\n> From: Dana Reyes\n> Sent: Monday 3pm\n'
          '> lunch on Tuesday?');
      expect(quoted.day, friday);
      expect(quoted.hours?.startHour, 17);
    });

    test('"On second thought" is the ask, not a reply header', () {
      final h = read('Plans',
          'On second thought, Friday dinner works.\nAs Sam wrote:\n'
          'the place on Main is good.');
      expect(h.day, friday);
      expect(h.hours?.startHour, 17);
      final real = read('Dinner Friday?',
          'Dinner Friday?\n\nOn Mon, Sep 29, 2026 at 3:15 PM Dana Reyes '
          '<dana@example.com> wrote:\n> lunch on Tuesday at noon?');
      expect(real.day, friday);
      expect(real.hours?.startHour, 17);
    });

    test('relative words read against when the message was sent', () {
      AskHints sent(String subject, DateTime at) => readAskHints(
          subject: subject, body: '', now: now, zone: la, sentAt: at);
      // Monday's "tomorrow" was Tuesday, gone by Wednesday: dropped.
      expect(sent('tomorrow dinner?', monday).day, isNull);
      // Monday's "Tuesday" is a weekday: it rolls to next Tuesday.
      expect(sent('Tuesday dinner?', monday).day,
          const CalendarDate(2026, 10, 13));
      // Tuesday evening's "tomorrow" is today, and dinner is still ahead.
      expect(sent('tomorrow dinner?', tuesdayEvening).day,
          const CalendarDate(2026, 10, 7));
      // Without sentAt, "tomorrow" is tomorrow.
      expect(read('tomorrow dinner?').day, const CalendarDate(2026, 10, 8));
    });

    test('a range past midnight ends at the day\'s last minute, and its '
        'length is the quarter hours that fit', () {
      final h = read('drinks 10pm-1am');
      expect(h.hours,
          const AskHours(startHour: 22, startMinute: 0, endHour: 23, endMinute: 59));
      expect(h.minutes, 105, reason: '119 is nobody\'s length');
    });

    test('a named time far outside the meal\'s hours gives the meal\'s', () {
      final h = read('drinks 10pm to midnight');
      expect(h.hours,
          const AskHours(startHour: 17, startMinute: 0, endHour: 19, endMinute: 30));
      expect(h.minutes, 60);
      expect(h.timeWords, 'for drinks');
    });

    test('a date whose hours are over is dropped, not rolled a week', () {
      // Fri Oct 9 2026 at 9:00 PM in Los Angeles.
      final h = readAskHints(
          subject: 'Dinner Oct 9?',
          body: '',
          now: DateTime.utc(2026, 10, 10, 4),
          zone: la);
      expect(h.day, isNull);
      expect(h.hours?.startHour, 17);
    });

    test('a four-digit clock time is no year in a reply header', () {
      final h = read('Plans',
          'On Friday dinner at 1930 works.\nAs Sam wrote:\n'
          'the place on Main is good.');
      expect(h.day, friday);
    });

    test('a meal never overrides an explicit am', () {
      final h = read('coffee at 4am');
      expect(h.hours,
          const AskHours(startHour: 4, startMinute: 0, endHour: 6, endMinute: 0));
      expect(h.minutes, 30);
    });
  });

  group('read by the model', () {
    // Mon Oct 5 and Tue Oct 6 2026, 10:00 AM and 6:00 PM in Los Angeles.
    final monday = DateTime.utc(2026, 10, 5, 17);
    final tuesdayEvening = DateTime.utc(2026, 10, 7, 1);
    const thursday = CalendarDate(2026, 10, 8);
    const tuesday = CalendarDate(2026, 10, 13);

    AskHints fromRead(String subject, String body, AskRead r,
            {DateTime? sentAt}) =>
        readAskHintsFromRead(
            read: r,
            subject: subject,
            body: body,
            now: now,
            zone: la,
            sentAt: sentAt);

    void expectSame(AskHints model, AskHints rules) {
      expect(model.day, rules.day, reason: 'day');
      expect(model.days, rules.days, reason: 'days');
      expect(model.hours, rules.hours, reason: 'hours');
      expect(model.minutes, rules.minutes, reason: 'minutes');
      expect(model.said, rules.said, reason: 'said');
      expect(model.timeWords, rules.timeWords, reason: 'timeWords');
    }

    test('a perfect read gives the rules\' reading, field for field', () {
      final cases = <(String, String, AskRead, DateTime?)>[
        (
          'dinner on friday',
          'could we grab dinner on Friday?',
          const AskRead(asksForTime: true, when: ['Friday'],
              meal: AskMeal.dinner),
          null,
        ),
        (
          'coffee tuesday morning?',
          '',
          const AskRead(asksForTime: true, when: ['tuesday'],
              time: 'morning', meal: AskMeal.coffee),
          null,
        ),
        (
          'Lunch next week?',
          '',
          const AskRead(asksForTime: true, when: ['next week'],
              meal: AskMeal.lunch),
          null,
        ),
        (
          'drinks 10pm-1am',
          '',
          const AskRead(asksForTime: true, time: '10pm-1am',
              meal: AskMeal.drinks),
          null,
        ),
        (
          'tomorrow dinner?',
          '',
          const AskRead(asksForTime: true, when: ['tomorrow'],
              meal: AskMeal.dinner),
          tuesdayEvening,
        ),
        (
          'tomorrow dinner?',
          '',
          const AskRead(asksForTime: true, when: ['tomorrow'],
              meal: AskMeal.dinner),
          monday,
        ),
      ];
      for (final (subject, body, r, sentAt) in cases) {
        final rules = readAskHints(
            subject: subject, body: body, now: now, zone: la, sentAt: sentAt);
        expect(rules.any, isTrue, reason: subject);
        expectSame(fromRead(subject, body, r, sentAt: sentAt), rules);
      }
    });

    test('Tuesday or Thursday afternoon is both days, sorted', () {
      final h = fromRead('Sync', 'Could we talk Tuesday or Thursday afternoon?',
          const AskRead(asksForTime: true, when: ['Tuesday', 'Thursday'],
              time: 'afternoon'));
      expect(h.days, [thursday, tuesday]);
      expect(h.day, thursday);
      expect(h.hours, AskHours.fromDayPart(DayPart.afternoon));
      expect(h.hours,
          const AskHours(startHour: 12, startMinute: 0, endHour: 17, endMinute: 0));
      expect(h.said, 'Asked for: Thu Oct 8 or Tue Oct 13 · afternoon');
      expect(h.timeWords, 'in the afternoon');
    });

    test('a when phrase not in the text is dropped', () {
      const body = 'Could we grab dinner on Friday?';
      // "Monday" is the model's own word: dropped; the meal stands.
      final h = fromRead('Dinner', body,
          const AskRead(asksForTime: true, when: ['Monday'],
              meal: AskMeal.dinner));
      expect(h.day, isNull);
      expect(h.days, isEmpty);
      expect(h.minutes, 90);
      // With nothing else kept, nothing was read.
      final none = fromRead('Dinner', body,
          const AskRead(asksForTime: true, when: ['next Monday'],
              time: 'at 7pm'));
      expect(none.any, isFalse);
      expect(none.said, isNull);
      // A normalised date is not a copy either.
      expect(
          fromRead('Dinner', body,
                  const AskRead(asksForTime: true, when: ['2026-10-09']))
              .any,
          isFalse);
    });

    test('a meal the text never says is dropped', () {
      final h = fromRead('Catch up', 'Lunch on Friday?',
          const AskRead(asksForTime: true, when: ['Friday'],
              meal: AskMeal.dinner));
      expect(h.day, friday);
      expect(h.hours, isNull);
      expect(h.minutes, isNull);
      expect(h.said, 'Asked for: Fri Oct 9');
      // Drinks covers "a drink" and "happy hour" through its own word list.
      final drink = fromRead('After work', 'Happy hour on Friday?',
          const AskRead(asksForTime: true, when: ['Friday'],
              meal: AskMeal.drinks));
      expect(drink.hours?.startHour, 17);
      expect(drink.minutes, 60);
    });

    test('not asking for a time is nothing, whatever came with it', () {
      final h = fromRead('Dinner', 'Could we grab dinner on Friday?',
          const AskRead(asksForTime: false, when: ['Friday'],
              meal: AskMeal.dinner));
      expect(h.any, isFalse);
      expect(h.said, isNull);
    });

    test('a ruled-out day the model did not copy is not read — the rules '
        'read it', () {
      const subject = 'Re: catch up';
      const body = "How about Monday instead? Friday doesn't work for me.";
      final h = fromRead(subject, body,
          const AskRead(asksForTime: true, when: ['Monday']));
      expect(h.day, const CalendarDate(2026, 10, 12));
      // That is the point: the regex reader reads the day ruled out.
      final rules =
          readAskHints(subject: subject, body: body, now: now, zone: la);
      expect(rules.day, friday);
    });

    test('relative words resolve against when the message was sent', () {
      const read = AskRead(asksForTime: true, when: ['tomorrow'],
          meal: AskMeal.dinner);
      expect(fromRead('Dinner', 'tomorrow?', read, sentAt: tuesdayEvening).day,
          const CalendarDate(2026, 10, 7));
      // Monday's tomorrow has gone: dropped, the meal stands.
      final gone = fromRead('Dinner', 'tomorrow?', read, sentAt: monday);
      expect(gone.day, isNull);
      expect(gone.minutes, 90);
      expect(fromRead('Dinner', 'tomorrow?', read).day, thursday);
    });

    test('a past weekday rolls to its next occurrence', () {
      // Tue Sep 1 2026's "Thursday" was Sep 3; the ask is still open.
      final h = fromRead('Sync', 'Thursday afternoon?',
          const AskRead(asksForTime: true, when: ['Thursday'],
              time: 'afternoon'),
          sentAt: DateTime.utc(2026, 9, 1, 17));
      expect(h.day, thursday);
      expect(h.days, [thursday]);
    });

    test('a when phrase carrying the time still gives the hours', () {
      final h = fromRead('Review', 'Can we meet Friday at 3pm?',
          const AskRead(asksForTime: true, when: ['Friday at 3pm']));
      expect(h.day, friday);
      expect(h.hours,
          const AskHours(startHour: 15, startMinute: 0, endHour: 17, endMinute: 0));
      expect(h.said, 'Asked for: Fri Oct 9 · 3:00 PM');
    });

    test('a copied length is the length', () {
      final h = fromRead('Quick one', 'A quick 20 min call on Thursday?',
          const AskRead(asksForTime: true, when: ['Thursday'],
              duration: '20 min'));
      expect(h.day, thursday);
      expect(h.minutes, 20);
      // A length the model did not copy is none.
      expect(
          fromRead('Quick one', 'A quick call on Thursday?',
                  const AskRead(asksForTime: true, when: ['Thursday'],
                      duration: '20 min'))
              .minutes,
          isNull);
    });

    test('a day read twice is one day', () {
      final h = fromRead('Sync', 'Thursday? Or Thu, Oct 8, whichever.',
          const AskRead(asksForTime: true, when: ['Thursday', 'Oct 8']));
      expect(h.days, [thursday]);
      expect(h.said, 'Asked for: Thu Oct 8');
    });
  });
}
