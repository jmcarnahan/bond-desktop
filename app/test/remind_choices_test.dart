import 'package:bond_inbox/models/calendar_models.dart' show CalendarDate;
import 'package:bond_inbox/models/message_models.dart'
    show Conversation, Message, Participant;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/reminders/remind_choices.dart';
import 'package:flutter_test/flutter_test.dart';

/// The thread bar's Remind me choices and the typed time, worked out by the
/// host. Pure: the clock and the zone are arguments, so the dates here are
/// absolute.
void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  setUp(() => la = CalendarZone.tryNamed('America/Los_Angeles')!);

  // Tuesday Sep 29 2026, 9:00 AM in Los Angeles.
  final now = DateTime.utc(2026, 9, 29, 16);
  DateTime laAt(int month, int day, int hour, [int minute = 0]) =>
      la.localDateTime(CalendarDate(2026, month, day), hour, minute).toUtc();

  Map<String, DateTime> byId(List<RemindChoice> cs) =>
      {for (final c in cs) c.id: c.atUtc};

  group('remindChoices', () {
    test('a Tuesday morning: in two hours, 5 pm, tomorrow, next Monday', () {
      final cs = remindChoices(now: now, zone: la);
      expect([for (final c in cs) c.label], [
        'In 2 hours',
        '5 pm today',
        'Tomorrow 9 am',
        'Next Monday 9 am',
      ]);
      expect(byId(cs), {
        'in-2-hours': DateTime.utc(2026, 9, 29, 18),
        'five-pm': laAt(9, 29, 17),
        'tomorrow': laAt(9, 30, 9),
        'next-monday': laAt(10, 5, 9),
      });
    });

    test('5 pm goes once it is ten minutes off or less', () {
      final late = laAt(9, 29, 16, 51);
      expect(byId(remindChoices(now: late, zone: la)).keys,
          isNot(contains('five-pm')));
      final before = laAt(9, 29, 16, 49);
      expect(byId(remindChoices(now: before, zone: la)).keys,
          contains('five-pm'));
    });

    test('on a Sunday next Monday is tomorrow, so it is offered once', () {
      final sunday = laAt(10, 4, 10);
      final ids = byId(remindChoices(now: sunday, zone: la));
      expect(ids['tomorrow'], laAt(10, 5, 9));
      expect(ids.keys, isNot(contains('next-monday')));
    });

    test('a Monday: next Monday is a week on, never today', () {
      final monday = laAt(10, 5, 8);
      expect(byId(remindChoices(now: monday, zone: la))['next-monday'],
          laAt(10, 12, 9));
    });

    test('the deadline at 09:00 on its day, while that is still ahead', () {
      final cs = remindChoices(
          now: now, zone: la, deadlineDay: const CalendarDate(2026, 10, 2));
      expect(cs.last.id, 'deadline');
      expect(cs.last.label, 'On the deadline · Fri Oct 2');
      expect(cs.last.atUtc, laAt(10, 2, 9));

      // Today's 09:00 has just passed: nothing to offer.
      expect(
          byId(remindChoices(
                  now: laAt(9, 29, 9, 1),
                  zone: la,
                  deadlineDay: const CalendarDate(2026, 9, 29)))
              .keys,
          isNot(contains('deadline')));
      // A deadline in the past: none either.
      expect(
          byId(remindChoices(
                  now: now,
                  zone: la,
                  deadlineDay: const CalendarDate(2026, 9, 28)))
              .keys,
          isNot(contains('deadline')));
    });

    test('a DST weekend leaves 9 am at 9 am', () {
      // Friday Oct 30 2026; Los Angeles falls back on Sunday Nov 1.
      final friday = laAt(10, 30, 10);
      final monday = byId(remindChoices(now: friday, zone: la))['next-monday']!;
      expect(la.toLocal(monday).hour, 9);
      expect(la.dateOf(monday), const CalendarDate(2026, 11, 2));
    });
  });

  group('resolveRemindText', () {
    test('a day and a time are that instant, labelled absolutely', () {
      final r = resolveRemindText('Thu 3pm', now: now, zone: la)!;
      expect(r.atUtc, laAt(10, 1, 15));
      expect(r.label, 'Thu Oct 1, 3:00 PM');
      expect(r.id, 'typed');
    });

    test('a day alone is 09:00; a time alone is today', () {
      expect(resolveRemindText('tomorrow', now: now, zone: la)!.atUtc,
          laAt(9, 30, 9));
      expect(resolveRemindText('at 4pm', now: now, zone: la)!.atUtc,
          laAt(9, 29, 16));
    });

    test('a part of the day with no time is its start', () {
      expect(
          resolveRemindText('tomorrow afternoon', now: now, zone: la)!.atUtc,
          laAt(9, 30, 12));
    });

    test('nothing ahead is null: empty, no when-words, or already past', () {
      expect(resolveRemindText('', now: now, zone: la), isNull);
      expect(resolveRemindText('banana bread', now: now, zone: la), isNull);
      expect(resolveRemindText('at 8am', now: now, zone: la), isNull);
    });
  });

  test('followUpWhen: the weekday and the wall time', () {
    expect(followUpWhen(laAt(10, 1, 9), la), 'Thu 9:00 AM');
  });

  test('remindDeadlineDay reads the deadline against the mail that named it',
      () {
    const c = Conversation(
      id: 'c1',
      latestDeadline: '2026-10-02',
      lastInboundAt: '2026-09-28T17:00:00Z',
    );
    expect(remindDeadlineDay(c, now), const CalendarDate(2026, 10, 2));
    expect(remindDeadlineDay(const Conversation(id: 'c2'), now), isNull);
  });

  test('replyToName: the thread\'s name for the sender, else the from-name, '
      'else the address, else them', () {
    const thread = Conversation(
      id: 'c1',
      latestInboundFrom: 'Dana@Example.com',
      participants: [
        Participant(name: 'Eric Lund', email: 'eric@example.com'),
        Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
      ],
    );
    const newest = Message(
        id: 'm1', outbound: false, fromName: 'D. Whitfield',
        fromAddress: 'dana@example.com');
    // Matched by address, case aside.
    expect(replyToName(thread, newest), 'Dana Whitfield');
    // No participant by that address: the message's own from-name.
    const stranger = Conversation(id: 'c2', latestInboundFrom: 'x@example.com');
    expect(replyToName(stranger, newest), 'D. Whitfield');
    // No name anywhere: the address.
    expect(replyToName(stranger, null), 'x@example.com');
    // Nothing at all.
    expect(replyToName(const Conversation(id: 'c3'), null), 'them');
  });
}
