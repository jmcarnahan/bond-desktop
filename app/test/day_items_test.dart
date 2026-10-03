import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/reminder_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/stored_decision.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Day stop's merge and its words about time. Everything is pure and
/// takes the clock and the zone as arguments, so the dates here are absolute:
/// nothing judges them against the machine's own clock.
void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  setUp(() => la = CalendarZone.tryNamed('America/Los_Angeles')!);

  // Tuesday Sep 29 2026, 9:00 AM in Los Angeles.
  final now = DateTime.utc(2026, 9, 29, 16);
  const today = CalendarDate(2026, 9, 29);

  CalendarEvent timed(
    String id,
    DateTime start, {
    Duration length = const Duration(minutes: 30),
    String? subject,
    bool isCancelled = false,
    String responseStatus = 'accepted',
    String showAs = 'busy',
    String joinUrl = '',
    String seriesMasterId = '',
  }) =>
      CalendarEvent(
        id: id,
        subject: subject ?? 'Meeting $id',
        startUtc: start,
        endUtc: start.add(length),
        isCancelled: isCancelled,
        responseStatus: responseStatus,
        showAs: showAs,
        joinUrl: joinUrl,
        seriesMasterId: seriesMasterId,
      );

  CalendarEvent allDay(String id, CalendarDate start, CalendarDate end,
          {String? subject}) =>
      CalendarEvent(
        id: id,
        subject: subject ?? 'All day $id',
        isAllDay: true,
        startDate: start,
        endDate: end,
      );

  List<String> describe(List<DayItem> items) => [
        for (final i in items)
          switch (i) {
            MeetingItem(:final event) => 'meeting:${event.id}',
            AllDayItem(:final event) => 'allday:${event.id}',
            DeadlineItem(:final conversation) => 'due:${conversation.id}',
            ReturnItem(:final conversation) => 'back:${conversation.id}',
            ReminderItem(:final reminder) => 'remind:${reminder.id}',
            NowMarker() => 'now',
          },
      ];

  Reminder reminder(
    String id,
    DateTime atUtc, {
    ReminderStatus status = ReminderStatus.active,
  }) =>
      Reminder(
        id: id,
        kind: ReminderKind.replyBy,
        source: 'email',
        conversationKey: 'conv-$id',
        title: 'Reply to Contoso: $id',
        remindAt: atUtc.toIso8601String(),
        status: status,
        createdFrom: ReminderOrigin.bar,
        createdAt: '2026-09-28T00:00:00.000000Z',
        updatedAt: '2026-09-28T00:00:00.000000Z',
      );

  group('reminders', () {
    test('an active reminder lands on its LOCAL day and ranks with the '
        'returns by instant', () {
      final items = buildDayItems(
        day: today,
        now: now,
        zone: la,
        events: [timed('m', DateTime.utc(2026, 9, 29, 18))],
        conversations: const [
          Conversation(
            id: 'r1',
            bucket: 'later',
            snoozedUntil: '2026-09-29T18:00:00.000000Z',
          ),
        ],
        reminders: [
          // 11 AM Los Angeles.
          reminder('am', DateTime.utc(2026, 9, 29, 18)),
          // 00:30 Sep 30 UTC is 5:30 PM on the 29th in Los Angeles — its
          // local day.
          reminder('eve', DateTime.utc(2026, 9, 30, 0, 30)),
          // 9 AM on the 30th: another day.
          reminder('next', DateTime.utc(2026, 9, 30, 16)),
          reminder('gone', DateTime.utc(2026, 9, 29, 17),
              status: ReminderStatus.cancelled),
        ],
      );
      expect(describe(items), [
        'now',
        // One instant: the meeting, then the return, then the reminder.
        'meeting:m',
        'back:r1',
        'remind:am',
        'remind:eve',
      ]);
    });

    test('daySummary counts them and dayRowLabel says so', () {
      final items = buildDayItems(
        day: today.addDays(1),
        now: now,
        zone: la,
        events: const [],
        conversations: const [],
        reminders: [
          reminder('a', DateTime.utc(2026, 9, 30, 16)),
          reminder('b', DateTime.utc(2026, 9, 30, 20)),
        ],
      );
      final s = daySummary(
          day: today.addDays(1), items: items, invites: const [], zone: la);
      expect(s, const DaySummary(reminders: 2));
      expect(s.isEmpty, isFalse);
      expect(dayRowLabel(today.addDays(1), today, s),
          'Tomorrow · 2 reminders');
      expect(dayRowLabel(today, today, const DaySummary(reminders: 1)),
          'Today · 1 reminder');
    });

    test('rangeMarkers carries them beside the returns, by instant', () {
      const monday = CalendarDate(2026, 9, 28);
      final got = rangeMarkers(
        from: monday,
        toExclusive: monday.addDays(7),
        now: now,
        zone: la,
        conversations: const [
          Conversation(id: 'back', bucket: 'later',
              snoozedUntil: '2026-09-30T20:00:00.000000Z'),
        ],
        reminders: [
          reminder('late', DateTime.utc(2026, 9, 30, 22)),
          reminder('early', DateTime.utc(2026, 9, 30, 16)),
          // Outside the week.
          reminder('out', DateTime.utc(2026, 10, 6, 16)),
        ],
      );
      expect(describe(got), ['remind:early', 'back:back', 'remind:late']);
      expect((got.first as ReminderItem).atUtc, DateTime.utc(2026, 9, 30, 16));
    });

    test('upcomingDays gives a later day a row for a reminder alone', () {
      final days = upcomingDays(
        today: today,
        now: now,
        zone: la,
        events: const [],
        conversations: const [],
        invites: const [],
        reminders: [reminder('fri', DateTime.utc(2026, 10, 2, 16))],
      );
      expect([for (final (d, _) in days) d.toIso()],
          ['2026-09-29', '2026-09-30', '2026-10-02']);
      expect(days.last.$2, const DaySummary(reminders: 1));
    });
  });

  group('buildDayItems', () {
    test('all-day first, then deadlines, then timed rows by instant with the '
        'Now marker in place', () {
      final items = buildDayItems(
        day: today,
        now: now,
        zone: la,
        events: [
          allDay('a1', today, today.addDays(1), subject: 'Offsite'),
          timed('late', DateTime.utc(2026, 9, 29, 18)),
          timed('early', DateTime.utc(2026, 9, 29, 15)),
          // Starts exactly now: it is next, not past.
          timed('kickoff', DateTime.utc(2026, 9, 29, 16)),
        ],
        conversations: const [
          Conversation(
            id: 'r1',
            subject: 'Contoso contract',
            bucket: 'later',
            snoozedUntil: '2026-09-29T18:00:00.000000Z',
          ),
          Conversation(
            id: 'd1',
            subject: 'Fabrikam quote',
            latestDeadline: '2026-09-29',
          ),
        ],
      );

      expect(describe(items), [
        'allday:a1',
        'due:d1',
        'meeting:early',
        'now',
        'meeting:kickoff',
        // A meeting and a return at the same instant: the meeting first.
        'meeting:late',
        'back:r1',
      ]);
    });

    test('the Now marker is only on today', () {
      final items = buildDayItems(
        day: today.addDays(1),
        now: now,
        zone: la,
        events: [timed('t', DateTime.utc(2026, 9, 30, 17))],
        conversations: const [],
      );
      expect(describe(items), ['meeting:t']);
    });

    test('deadlines: open threads whose showable deadline lands on the day',
        () {
      const day = CalendarDate(2026, 10, 1);
      final items = buildDayItems(
        day: day,
        now: now,
        zone: la,
        events: const [],
        conversations: const [
          Conversation(id: 'yes', latestDeadline: '2026-10-01'),
          Conversation(
            id: 'closed',
            latestDeadline: '2026-10-01',
            state: ConversationState.done,
          ),
          Conversation(id: 'other-day', latestDeadline: '2026-10-02'),
          // Plan-relative with no date in it: never shown, so never placed.
          Conversation(id: 'plan', latestDeadline: 'Day 1'),
          Conversation(id: 'none'),
        ],
      );
      expect(describe(items), ['due:yes']);
      expect((items.single as DeadlineItem).deadline, '2026-10-01');
    });

    test('a return lands on its LOCAL day, across the UTC date line', () {
      const conv = Conversation(
        id: 'r',
        bucket: 'later',
        // 8:00 PM on Oct 1 in Los Angeles.
        snoozedUntil: '2026-10-02T03:00:00.000000Z',
      );
      List<String> on(CalendarDate day) => describe(buildDayItems(
            day: day,
            now: now,
            zone: la,
            events: const [],
            conversations: const [conv],
          ));
      expect(on(const CalendarDate(2026, 10, 1)), ['back:r']);
      expect(on(const CalendarDate(2026, 10, 2)), isEmpty);
    });

    test('returns only from Later, and not from a done thread', () {
      final items = buildDayItems(
        day: today,
        now: now,
        zone: la,
        events: const [],
        conversations: const [
          Conversation(id: 'inbox', snoozedUntil: '2026-09-29T20:00:00Z'),
          Conversation(
            id: 'done',
            bucket: 'later',
            state: ConversationState.done,
            snoozedUntil: '2026-09-29T20:00:00Z',
          ),
          Conversation(id: 'garbled', bucket: 'later', snoozedUntil: 'soon'),
        ],
      );
      expect(describe(items), ['now']);
    });

    test('a thread gives one row per day, and a deadline beats a return', () {
      final items = buildDayItems(
        day: const CalendarDate(2026, 10, 1),
        now: now,
        zone: la,
        events: const [],
        conversations: const [
          Conversation(
            id: 'both',
            bucket: 'later',
            latestDeadline: '2026-10-01',
            snoozedUntil: '2026-10-01T17:00:00.000000Z',
          ),
        ],
      );
      expect(describe(items), ['due:both']);
    });

    test('overlaps are measured against the same day, hard before soft', () {
      final items = buildDayItems(
        day: today,
        now: now,
        zone: la,
        events: [
          timed('main', DateTime.utc(2026, 9, 29, 20),
              length: const Duration(hours: 1), subject: 'Planning'),
          timed('maybe', DateTime.utc(2026, 9, 29, 20, 30),
              showAs: 'tentative', subject: 'Maybe lunch'),
          timed('clash', DateTime.utc(2026, 9, 29, 20, 15),
              subject: 'Budget review'),
        ],
        conversations: const [],
      );
      final main = items
          .whereType<MeetingItem>()
          .firstWhere((m) => m.event.id == 'main');
      expect([for (final e in main.overlaps.hard) e.id], ['clash']);
      expect([for (final e in main.overlaps.soft) e.id], ['maybe']);
      expect(overlapLine(main.overlaps), '⚠ overlaps Budget review +1');

      final maybe = items
          .whereType<MeetingItem>()
          .firstWhere((m) => m.event.id == 'maybe');
      expect(overlapLine(maybe.overlaps), '⚠ overlaps Planning +1');
      expect(overlapLine(const Overlaps()), isNull);
    });

    test('cancelled and declined meetings stay on the day', () {
      final items = buildDayItems(
        day: today,
        now: now,
        zone: la,
        events: [
          timed('gone', DateTime.utc(2026, 9, 29, 20), isCancelled: true),
          timed('no', DateTime.utc(2026, 9, 29, 21),
              responseStatus: 'declined'),
        ],
        conversations: const [],
      );
      expect(describe(items), ['now', 'meeting:gone', 'meeting:no']);
    });

    test('a DST day: 9:00 on Nov 1 in Los Angeles is 9:00', () {
      const day = CalendarDate(2026, 11, 1);
      final start = la.localDateTime(day, 9, 0).toUtc();
      final items = buildDayItems(
        day: day,
        now: now,
        zone: la,
        events: [timed('dst', start)],
        conversations: const [],
      );
      final m = items.single as MeetingItem;
      expect(formatEventRange(la, m.event.startUtc!, m.event.endUtc!),
          '9:00–9:30 AM');
    });

    group('relative deadlines read against the mail that named them', () {
      // The parser answers in the DEVICE's zone, so the expected days are
      // worked out through it too, from the same stamps.
      CalendarDate localDay(DateTime utc) {
        final l = utc.toLocal();
        return CalendarDate(l.year, l.month, l.day);
      }

      List<String> on(CalendarDate day, Conversation c) =>
          describe(buildDayItems(
            day: day,
            now: now,
            zone: la,
            events: const [],
            conversations: [c],
          )).where((d) => d != 'now').toList();

      test('"tomorrow" said two weeks ago is not tomorrow now', () {
        final said = now.subtract(const Duration(days: 14));
        final c = Conversation(
          id: 'old',
          latestDeadline: 'tomorrow',
          lastInboundAt: said.toIso8601String(),
        );
        expect(on(today.addDays(1), c), isEmpty);
        expect(on(localDay(said).addDays(1), c), ['due:old']);
      });

      test('"EOD" three weeks ago is not due today', () {
        final said = now.subtract(const Duration(days: 21));
        final c = Conversation(
          id: 'eod',
          latestDeadline: 'EOD',
          lastInboundAt: said.toIso8601String(),
        );
        expect(on(today, c), isEmpty);
        expect(on(localDay(said), c), ['due:eod']);
      });

      test('no inbound stamp falls back to now', () {
        const c = Conversation(id: 'fresh', latestDeadline: 'tomorrow');
        expect(on(localDay(now).addDays(1), c), ['due:fresh']);
      });

      test('upcomingDays places them by the same rule', () {
        final said = now.subtract(const Duration(days: 14));
        final days = upcomingDays(
          today: today,
          now: now,
          zone: la,
          events: const [],
          conversations: [
            Conversation(
              id: 'old',
              latestDeadline: 'tomorrow',
              lastInboundAt: said.toIso8601String(),
            ),
          ],
          invites: const [],
        );
        expect([for (final (_, s) in days) s.due], [0, 0]);
      });
    });
  });

  group('eventTouchesDay (Los Angeles)', () {
    const oct1 = CalendarDate(2026, 10, 1);

    test('a meeting from 11 PM to 1 AM is on both days', () {
      final e = timed('late', la.localDateTime(oct1, 23, 0).toUtc(),
          length: const Duration(hours: 2));
      expect(eventTouchesDay(e, oct1.addDays(-1), la), isFalse);
      expect(eventTouchesDay(e, oct1, la), isTrue);
      expect(eventTouchesDay(e, oct1.addDays(1), la), isTrue);
      expect(eventTouchesDay(e, oct1.addDays(2), la), isFalse);
    });

    test('ending exactly at midnight does not touch the next day', () {
      final e = timed('to-midnight', la.localDateTime(oct1, 23, 0).toUtc(),
          length: const Duration(hours: 1));
      expect(eventTouchesDay(e, oct1, la), isTrue);
      expect(eventTouchesDay(e, oct1.addDays(1), la), isFalse);
    });

    test('9 PM local is the next day in UTC but sits on its local day', () {
      final start = la.localDateTime(oct1, 21, 0).toUtc();
      expect(start.day, 2);
      final e = timed('evening', start, length: const Duration(hours: 1));
      expect(eventTouchesDay(e, oct1, la), isTrue);
      expect(eventTouchesDay(e, oct1.addDays(1), la), isFalse);
    });

    test('a three-day all-day event touches exactly its three dates', () {
      final e = allDay('trip', const CalendarDate(2026, 10, 5),
          const CalendarDate(2026, 10, 8));
      expect(eventTouchesDay(e, const CalendarDate(2026, 10, 4), la), isFalse);
      expect(eventTouchesDay(e, const CalendarDate(2026, 10, 5), la), isTrue);
      expect(eventTouchesDay(e, const CalendarDate(2026, 10, 6), la), isTrue);
      expect(eventTouchesDay(e, const CalendarDate(2026, 10, 7), la), isTrue);
      expect(eventTouchesDay(e, const CalendarDate(2026, 10, 8), la), isFalse);
    });

    test('11:30 PM on the 25-hour fall-back day stays on that day', () {
      const nov1 = CalendarDate(2026, 11, 1);
      final e = timed('fallback', la.localDateTime(nov1, 23, 30).toUtc());
      expect(eventTouchesDay(e, nov1, la), isTrue);
      expect(eventTouchesDay(e, nov1.addDays(1), la), isFalse);
      expect(eventTouchesDay(e, nov1.addDays(-1), la), isFalse);
    });
  });

  test('mondayOf is the Monday of the week, Monday itself included', () {
    // Mon Oct 5 … Sun Oct 11 2026.
    for (var d = 5; d <= 11; d++) {
      expect(mondayOf(CalendarDate(2026, 10, d)), const CalendarDate(2026, 10, 5),
          reason: 'Oct $d');
    }
    expect(mondayOf(const CalendarDate(2026, 10, 12)),
        const CalendarDate(2026, 10, 12));
    // Across a month and a year.
    expect(mondayOf(const CalendarDate(2027, 1, 1)),
        const CalendarDate(2026, 12, 28));
    // Across spring-forward: dates, not instants, so no hour is lost.
    expect(mondayOf(const CalendarDate(2026, 3, 8)),
        const CalendarDate(2026, 3, 2));
  });

  test('a deadline item carries the day it was matched to', () {
    final items = buildDayItems(
      day: const CalendarDate(2026, 10, 1),
      now: now,
      zone: la,
      events: const [],
      conversations: const [
        Conversation(id: 'yes', latestDeadline: '2026-10-01'),
      ],
    );
    expect(items.whereType<DeadlineItem>().single.day,
        const CalendarDate(2026, 10, 1));
  });

  test('rangeMarkers is the deadlines and returns buildDayItems gives, day '
      'by day, and nothing else', () {
    const conversations = [
      Conversation(id: 'due-thu', subject: 'Contoso quote',
          latestDeadline: '2026-10-01'),
      // Two returns on one day, given out of order: the instant sorts them.
      Conversation(id: 'back-late', bucket: 'later',
          snoozedUntil: '2026-09-30T22:00:00.000000Z'),
      Conversation(id: 'back-early', bucket: 'later',
          snoozedUntil: '2026-09-30T17:00:00.000000Z'),
      // A deadline and a return on one day: the deadline claims it.
      Conversation(id: 'both', bucket: 'later',
          latestDeadline: '2026-10-02',
          snoozedUntil: '2026-10-02T17:00:00.000000Z'),
      // A deadline on one day and a return on another: both stand.
      Conversation(id: 'split', bucket: 'later',
          latestDeadline: '2026-10-01',
          snoozedUntil: '2026-10-03T17:00:00.000000Z'),
      // Outside the range on both sides.
      Conversation(id: 'before', latestDeadline: '2026-09-27'),
      Conversation(id: 'after', latestDeadline: '2026-10-06'),
    ];
    final events = [
      timed('m1', DateTime.utc(2026, 9, 30, 17), subject: 'Fabrikam sync'),
    ];
    const monday = CalendarDate(2026, 9, 28);

    String sig(DayItem i) => switch (i) {
          DeadlineItem(:final conversation, :final deadline, :final day) =>
            'due:${conversation.id}:$deadline:${day?.toIso()}',
          ReturnItem(:final conversation, :final atUtc) =>
            'back:${conversation.id}:${atUtc.toIso8601String()}',
          _ => 'other',
        };
    final expected = [
      for (var i = 0; i < 7; i++)
        for (final item in buildDayItems(
          day: monday.addDays(i),
          events: events,
          conversations: conversations,
          now: now,
          zone: la,
        ))
          if (item is DeadlineItem || item is ReturnItem) sig(item),
    ];
    final got = rangeMarkers(
      from: monday,
      toExclusive: monday.addDays(7),
      conversations: conversations,
      now: now,
      zone: la,
    );
    expect(got.map(sig).toList(), expected);
    expect(describe(got), [
      'back:back-early',
      'back:back-late',
      'due:due-thu',
      'due:split',
      'due:both',
      'back:split',
    ]);
  });

  test('invitesAsOf floors to the quarter hour, in UTC', () {
    expect(invitesAsOf(DateTime.utc(2026, 9, 29, 16, 44, 59, 999, 999)),
        DateTime.utc(2026, 9, 29, 16, 30));
    expect(invitesAsOf(DateTime.utc(2026, 9, 29, 16)),
        DateTime.utc(2026, 9, 29, 16));
    expect(invitesAsOf(DateTime.utc(2026, 9, 29, 16, 15, 0, 1)),
        DateTime.utc(2026, 9, 29, 16, 15));
    final local = DateTime.utc(2026, 9, 29, 16, 7).toLocal();
    final asOf = invitesAsOf(local);
    expect(asOf.isUtc, isTrue);
    expect(asOf, DateTime.utc(2026, 9, 29, 16));
  });

  group('words about time', () {
    test('formatEventTime reads the display zone', () {
      expect(formatEventTime(la, DateTime.utc(2026, 9, 29, 16, 5)), '9:05 AM');
    });

    test('formatEventRange: one meridiem, two, and a later date', () {
      expect(
        formatEventRange(la, DateTime.utc(2026, 9, 29, 17),
            DateTime.utc(2026, 9, 29, 17, 30)),
        '10:00–10:30 AM',
      );
      expect(
        formatEventRange(la, DateTime.utc(2026, 9, 29, 18, 30),
            DateTime.utc(2026, 9, 29, 19, 30)),
        '11:30 AM–12:30 PM',
      );
      expect(
        formatEventRange(la, DateTime.utc(2026, 9, 30, 6),
            DateTime.utc(2026, 9, 30, 8)),
        '11:00 PM–Wed 1:00 AM',
      );
    });

    test('meetingCountdown', () {
      CalendarEvent at(Duration fromNow, {bool isCancelled = false}) =>
          timed('c', now.add(fromNow), isCancelled: isCancelled);
      expect(meetingCountdown(at(const Duration(minutes: 18)), now), 'in 18m');
      // Rounded up: thirty seconds out is a minute, never zero.
      expect(meetingCountdown(at(const Duration(seconds: 30)), now), 'in 1m');
      expect(
        meetingCountdown(at(const Duration(minutes: 17, seconds: 30)), now),
        'in 18m',
      );
      expect(meetingCountdown(at(Duration.zero), now), 'now');
      expect(meetingCountdown(at(const Duration(minutes: -10)), now), 'now');
      expect(meetingCountdown(at(const Duration(hours: 2)), now), isNull);
      expect(meetingCountdown(at(const Duration(minutes: 60)), now), isNull);
      expect(meetingCountdown(at(const Duration(hours: -2)), now), isNull);
      expect(
        meetingCountdown(
            at(const Duration(minutes: 5), isCancelled: true), now),
        isNull,
      );
    });

    test('joinable: from fifteen minutes before until the end', () {
      final e = timed('j', now,
          joinUrl: 'https://teams.example.com/l/meetup-join/fictional');
      final start = e.startUtc!;
      final end = e.endUtc!;
      expect(joinable(e, start.subtract(const Duration(minutes: 15))), isTrue);
      expect(
        joinable(e, start.subtract(const Duration(minutes: 15, seconds: 1))),
        isFalse,
      );
      expect(joinable(e, end.subtract(const Duration(seconds: 1))), isTrue);
      expect(joinable(e, end), isFalse);
      expect(joinable(timed('x', now), now), isFalse,
          reason: 'no join link');
      expect(
        joinable(
            timed('y', now,
                joinUrl: 'https://teams.example.com/l/x', isCancelled: true),
            now),
        isFalse,
      );
    });

    test('dayTitle', () {
      expect(dayTitle(today, today), 'Today · Tuesday, Sep 29');
      expect(dayTitle(today.addDays(1), today), 'Tomorrow · Wednesday, Sep 30');
      expect(dayTitle(today.addDays(-1), today), 'Yesterday · Monday, Sep 28');
      expect(dayTitle(const CalendarDate(2026, 10, 2), today), 'Friday, Oct 2');
    });

    test('dayRowLabel', () {
      expect(dayRowLabel(today, today, const DaySummary(meetings: 1)),
          'Today · 1 meeting');
      expect(
        dayRowLabel(today.addDays(1), today,
            const DaySummary(meetings: 2, due: 1, returns: 1, invites: 2)),
        'Tomorrow · 2 meetings · 1 due · 1 back · 2 invites',
      );
      expect(dayRowLabel(const CalendarDate(2026, 10, 2), today,
          const DaySummary()), 'Fri Oct 2 · clear');
      expect(dayRowLabel(const CalendarDate(2026, 10, 3), today,
          const DaySummary(invites: 1)), 'Sat Oct 3 · 1 invite');
    });
  });

  group('the list column', () {
    test('upcomingDays: today and tomorrow always, then days with something '
        'on them, to the horizon', () {
      final days = upcomingDays(
        today: today,
        now: now,
        zone: la,
        events: [
          // 10:00 PM Sep 30 to 2:00 AM Oct 1 in Los Angeles: both days.
          timed('overnight', DateTime.utc(2026, 10, 1, 5),
              length: const Duration(hours: 4)),
          // Oct 5 and 6 (the end is exclusive).
          allDay('trip', const CalendarDate(2026, 10, 5),
              const CalendarDate(2026, 10, 7)),
          // The horizon's last day, and the day after it.
          timed('edge', DateTime.utc(2026, 10, 13, 17)),
          timed('past-edge', DateTime.utc(2026, 10, 14, 17)),
          // Cancelled: on the day, but not a meeting to count.
          timed('off', DateTime.utc(2026, 10, 9, 17), isCancelled: true),
        ],
        conversations: const [
          Conversation(id: 'd', latestDeadline: '2026-10-08'),
        ],
        invites: [
          InviteEntry(timed('inv', DateTime.utc(2026, 10, 8, 17))),
        ],
      );

      expect([for (final (d, _) in days) d.toIso()], [
        '2026-09-29',
        '2026-09-30',
        '2026-10-01',
        '2026-10-05',
        '2026-10-06',
        '2026-10-08',
        '2026-10-13',
      ]);
      expect(days.first.$2.isEmpty, isTrue);
      expect(days[1].$2, const DaySummary(meetings: 1));
      expect(days[2].$2, const DaySummary(meetings: 1));
      expect(days[3].$2, const DaySummary(meetings: 1));
      expect(days[5].$2, const DaySummary(due: 1, invites: 1));
    });

    test('remainingToday: at most three, still ahead, commitments only', () {
      final left = remainingToday(
        nowUtc: now,
        zone: la,
        events: [
          timed('ended', DateTime.utc(2026, 9, 29, 15)),
          timed('running', DateTime.utc(2026, 9, 29, 15, 45)),
          timed('off', DateTime.utc(2026, 9, 29, 17), isCancelled: true),
          timed('no', DateTime.utc(2026, 9, 29, 17), responseStatus: 'declined'),
          timed('b', DateTime.utc(2026, 9, 29, 19)),
          timed('a', DateTime.utc(2026, 9, 29, 18)),
          timed('c', DateTime.utc(2026, 9, 29, 20)),
          timed('tomorrow', DateTime.utc(2026, 9, 30, 17)),
          allDay('banner', today, today.addDays(1)),
        ],
      );
      expect([for (final e in left) e.id], ['running', 'a', 'b']);
    });
  });

  group('invites', () {
    test('collapseInvites folds a weekly series to its soonest occurrence',
        () {
      final occurrences = [
        for (var i = 16; i >= 0; i--)
          timed('occ-$i', DateTime.utc(2026, 10, 1 + 7 * i, 17),
              seriesMasterId: 'ser-1', subject: 'Weekly sync'),
      ];
      final entries = collapseInvites([
        ...occurrences,
        timed('solo', DateTime.utc(2026, 10, 3, 17)),
      ]);

      expect(entries, hasLength(2));
      final series = entries.first;
      expect(series.event.id, 'occ-0');
      expect(series.occurrences, 17);
      expect(series.isSeries, isTrue);
      expect(series.pinned, isFalse);
      expect(entries.last.event.id, 'solo');
      expect(entries.last.occurrences, 1);
      expect(entries.last.isSeries, isFalse);
    });

    test('a row answers its series only when several plain occurrences are '
        'owed', () {
      final five = collapseInvites([
        for (var i = 4; i >= 0; i--)
          timed('occ-$i', DateTime.utc(2026, 10, 1 + 7 * i, 17),
              seriesMasterId: 'ser-1'),
      ]).single;
      expect(five.occurrences, 5);
      expect(five.answersSeries, isTrue);
      expect(five.respondId, 'ser-1');

      // A moved meeting of a series answered already: owed alone, answered
      // alone, though the row still says it belongs to a series.
      final exception = InviteEntry(CalendarEvent(
        id: 'exc-1',
        subject: 'Weekly sync',
        seriesMasterId: 'ser-2',
        eventType: 'exception',
        startUtc: DateTime.utc(2026, 10, 2, 17),
        endUtc: DateTime.utc(2026, 10, 2, 18),
      ));
      expect(exception.isSeries, isTrue);
      expect(exception.answersSeries, isFalse);
      expect(exception.respondId, 'exc-1');

      // Several owed with an exception shown: still itself.
      final shownException = InviteEntry(
        CalendarEvent(
          id: 'exc-2',
          seriesMasterId: 'ser-3',
          eventType: 'exception',
          startUtc: DateTime.utc(2026, 10, 2, 17),
          endUtc: DateTime.utc(2026, 10, 2, 18),
        ),
        occurrences: 3,
      );
      expect(shownException.answersSeries, isFalse);
      expect(shownException.respondId, 'exc-2');

      final solo = InviteEntry(timed('solo', DateTime.utc(2026, 10, 3, 17)));
      expect(solo.answersSeries, isFalse);
      expect(solo.respondId, 'solo');
    });

    StoredDecision decision(Map<String, String> choices) => StoredDecision(
          model: 'fictional-heads',
          answers: DecisionAnswers({
            for (final MapEntry(:key, :value) in choices.entries)
              key: ChoiceAnswer(
                  choice: value, confidence: 0.9, probabilities: const {}),
          }),
        );

    test('invitePinned: urgency high or urgent, or importance high', () {
      expect(invitePinned([decision({'urgency': 'high'})]), isTrue);
      expect(invitePinned([decision({'urgency': 'urgent'})]), isTrue);
      expect(invitePinned([decision({'importance': 'high'})]), isTrue);
      expect(
        invitePinned(
            [decision({'urgency': 'normal', 'importance': 'normal'})]),
        isFalse,
      );
      expect(invitePinned([null, decision({})]), isFalse);
      expect(invitePinned(const []), isFalse);
      expect(invitePinned([null, decision({'urgency': 'urgent'})]), isTrue);
    });

    test('orderInvites: pinned first, then soonest', () {
      final ordered = orderInvites([
        InviteEntry(timed('a', DateTime.utc(2026, 10, 1, 17))),
        InviteEntry(timed('b', DateTime.utc(2026, 10, 3, 17)), pinned: true),
        InviteEntry(allDay('c', const CalendarDate(2026, 10, 2),
            const CalendarDate(2026, 10, 3))),
      ]);
      expect([for (final e in ordered) e.event.id], ['b', 'a', 'c']);
    });
  });

  test('where the calendar shows', () {
    final mirror = {
      for (final a in CalendarAvailability.values) a: calendarShowsMirror(a),
    };
    expect(mirror, {
      CalendarAvailability.unknown: true,
      CalendarAvailability.available: true,
      CalendarAvailability.scopeMissing: false,
      CalendarAvailability.sdkMode: false,
      CalendarAvailability.unavailable: true,
    });
    final todays = {
      for (final a in CalendarAvailability.values) a: calendarShowsToday(a),
    };
    expect(todays, {
      CalendarAvailability.unknown: false,
      CalendarAvailability.available: true,
      CalendarAvailability.scopeMissing: false,
      CalendarAvailability.sdkMode: false,
      CalendarAvailability.unavailable: true,
    });
  });
}
