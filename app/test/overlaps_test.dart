import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/ask_hints.dart' show AskHours;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:flutter_test/flutter_test.dart';

/// The overlap maths and the free-slot walk (the reference overlap rules).
/// Every fixture is built on a local wall clock through the zone and handed
/// to the code as UTC, as the mirror stores it.
void main() {
  late CalendarZone la;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  const wed = CalendarDate(2026, 10, 14);

  DateTime at(CalendarDate d, int h, [int m = 0]) {
    final t = la.localDateTime(d, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  CalendarEvent timed(
    String id,
    DateTime start,
    DateTime end, {
    String showAs = 'busy',
    String response = 'accepted',
    bool cancelled = false,
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Contoso $id',
        startUtc: start,
        endUtc: end,
        showAs: showAs,
        responseStatus: response,
        isCancelled: cancelled,
      );

  CalendarEvent allDay(String id, CalendarDate start, CalendarDate end) =>
      CalendarEvent(
        id: id,
        subject: 'Fabrikam offsite',
        isAllDay: true,
        startDate: start,
        endDate: end,
        showAs: 'busy',
      );

  List<String> ids(List<CalendarEvent> events) =>
      events.map((e) => e.id).toList();

  /// Local (hour, minute) labels of each slot's start.
  List<(int, int)> starts(List<FreeSlot> slots) => slots.map((s) {
        final t = la.toLocal(s.startUtc);
        return (t.hour, t.minute);
      }).toList();

  group('instantsOverlap', () {
    test('touching ends do not overlap; one minute in does', () {
      final a1 = at(wed, 15), a2 = at(wed, 16), b2 = at(wed, 17);
      expect(instantsOverlap(a1, a2, a2, b2), isFalse);
      expect(instantsOverlap(a2, b2, a1, a2), isFalse);
      expect(instantsOverlap(a1, a2, at(wed, 15, 59), b2), isTrue);
    });

    test('compares instants across representations', () {
      final local = la.localDateTime(wed, 15, 0);
      final utcEnd = at(wed, 16);
      expect(instantsOverlap(local, utcEnd, at(wed, 15, 30), at(wed, 17)),
          isTrue);
    });
  });

  group('findOverlaps', () {
    test('touching events do not overlap the slot', () {
      final events = [
        timed('before', at(wed, 14), at(wed, 15)),
        timed('after', at(wed, 16), at(wed, 17)),
      ];
      expect(findOverlaps(events, at(wed, 15), at(wed, 16)).isEmpty, isTrue);
    });

    test('busy is hard; a tentative showAs OR a Maybe answer is soft', () {
      final events = [
        timed('busy', at(wed, 15), at(wed, 16)),
        timed('maybe', at(wed, 15, 30), at(wed, 16, 30), showAs: 'tentative'),
        timed('said-maybe', at(wed, 15), at(wed, 15, 30),
            response: 'tentativelyAccepted', showAs: 'busy'),
        timed('oof', at(wed, 14), at(wed, 18), showAs: 'oof'),
      ];
      final o = findOverlaps(events, at(wed, 15), at(wed, 16));
      expect(ids(o.hard), ['busy', 'oof']);
      expect(ids(o.soft), ['maybe', 'said-maybe']);
      expect(o.allDayNotes, isEmpty);
      expect(o.isEmpty, isFalse);
    });

    test('free, workingElsewhere, declined and cancelled are ignored', () {
      final events = [
        timed('free', at(wed, 15), at(wed, 16), showAs: 'free'),
        timed('wfh', at(wed, 15), at(wed, 16), showAs: 'workingElsewhere'),
        timed('no', at(wed, 15), at(wed, 16), response: 'declined'),
        timed('gone', at(wed, 15), at(wed, 16), cancelled: true),
      ];
      expect(findOverlaps(events, at(wed, 15), at(wed, 16)).isEmpty, isTrue);
    });

    test('an all-day event is only ever a note', () {
      final events = [allDay('offsite', wed, wed.addDays(1))];
      final o = findOverlaps(events, at(wed, 15), at(wed, 16));
      expect(o.hard, isEmpty);
      expect(o.soft, isEmpty);
      expect(ids(o.allDayNotes), ['offsite']);
    });

    test('with a zone, an all-day event is noted only on its own dates', () {
      final events = [allDay('offsite', wed, wed.addDays(1))];
      final onDay =
          findOverlaps(events, at(wed, 15), at(wed, 16), zone: la);
      expect(ids(onDay.allDayNotes), ['offsite']);
      // The end date is exclusive: Thursday is clear.
      final thu = wed.addDays(1);
      final nextDay =
          findOverlaps(events, at(thu, 9), at(thu, 10), zone: la);
      expect(nextDay.isEmpty, isTrue);
      // A slot ending exactly at midnight does not touch the next day.
      final lateTue = wed.addDays(-1);
      expect(
          findOverlaps(events, at(lateTue, 23), at(wed, 0), zone: la).isEmpty,
          isTrue);
    });

    test('ignoreEventId skips the event being moved', () {
      final events = [
        timed('moving', at(wed, 15), at(wed, 16)),
        timed('other', at(wed, 15, 30), at(wed, 16, 30)),
      ];
      final o = findOverlaps(events, at(wed, 15), at(wed, 16),
          ignoreEventId: 'moving');
      expect(ids(o.hard), ['other']);
    });

    test('an unreadable timed event is skipped, not guessed', () {
      const broken = CalendarEvent(id: 'broken', showAs: 'busy');
      expect(findOverlaps([broken], at(wed, 0), at(wed, 23)).isEmpty, isTrue);
    });
  });

  group('overlapsForEvent', () {
    test('never overlaps itself', () {
      final me = timed('me', at(wed, 15), at(wed, 16));
      final other = timed('other', at(wed, 15, 45), at(wed, 16, 15),
          showAs: 'tentative');
      final o = overlapsForEvent(me, [me, other]);
      expect(o.hard, isEmpty);
      expect(ids(o.soft), ['other']);
    });

    test('a cancelled or declined event has no overlaps of its own', () {
      final busy = timed('busy', at(wed, 15), at(wed, 16));
      final off = timed('off', at(wed, 15), at(wed, 16), cancelled: true);
      final no = timed('no', at(wed, 15), at(wed, 16), response: 'declined');
      expect(overlapsForEvent(off, [busy, off, no]).isEmpty, isTrue);
      expect(overlapsForEvent(no, [busy, off, no]).isEmpty, isTrue);
      // And neither counts against the meeting that is still on.
      expect(overlapsForEvent(busy, [busy, off, no]).isEmpty, isTrue);
    });

    test('an all-day event has no slot and returns empty', () {
      final banner = allDay('banner', wed, wed.addDays(1));
      final o = overlapsForEvent(
          banner, [timed('busy', at(wed, 9), at(wed, 10))]);
      expect(o.isEmpty, isTrue);
    });
  });

  group('freeSlotsOnDay', () {
    test('basic day: the gaps between meetings', () {
      final events = [
        timed('am', at(wed, 8), at(wed, 12)),
        timed('pm', at(wed, 13), at(wed, 17)),
      ];
      final slots = freeSlotsOnDay(
          events: events, day: wed, durationMinutes: 60, zone: la);
      expect(starts(slots), [(12, 0), (17, 0)]);
      for (final s in slots) {
        expect(s.startUtc.isUtc, isTrue);
        expect(s.duration, const Duration(minutes: 60));
      }
    });

    test('each slot is a distinct opening (16-18 clear → 16:00 and 17:00)',
        () {
      final events = [timed('day', at(wed, 8), at(wed, 16))];
      final slots = freeSlotsOnDay(
          events: events, day: wed, durationMinutes: 60, zone: la);
      expect(starts(slots), [(16, 0), (17, 0)]);
    });

    test('a jump past a 20-minute slot lands back on the quarter-hour grid',
        () {
      final events = [timed('day', at(wed, 8), at(wed, 16))];
      final slots = freeSlotsOnDay(
          events: events, day: wed, durationMinutes: 20, zone: la);
      expect(starts(slots), [(16, 0), (16, 30), (17, 0)]);
    });

    test('limit is respected', () {
      final slots =
          freeSlotsOnDay(events: const [], day: wed, durationMinutes: 30, zone: la);
      expect(slots, hasLength(3));
      expect(
          freeSlotsOnDay(
                  events: const [],
                  day: wed,
                  durationMinutes: 30,
                  zone: la,
                  limit: 5)
              .length,
          5);
      expect(
          freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 30,
              zone: la,
              limit: 0),
          isEmpty);
    });

    test('notBefore is a preference: its own chain first, then nearest earlier',
        () {
      final events = [timed('mid', at(wed, 10), at(wed, 15))];
      // The day's chain: 8, 9, 15, 16, 17.
      expect(
          starts(freeSlotsOnDay(
              events: events,
              day: wed,
              durationMinutes: 60,
              zone: la,
              notBeforeUtc: at(wed, 15))),
          [(15, 0), (16, 0), (17, 0)]);
      // 16:30 itself is offered, not the 17:00 the 08:00 chain lands on; the
      // earlier ones follow nearest first, and 16:00 is not among them
      // because it overlaps the 16:30 already offered.
      expect(
          starts(freeSlotsOnDay(
              events: events,
              day: wed,
              durationMinutes: 60,
              zone: la,
              notBeforeUtc: at(wed, 16, 30))),
          [(16, 30), (15, 0), (9, 0)]);
    });

    test('notBefore offers the preferred opening itself on a clear day', () {
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              limit: 4,
              notBeforeUtc: at(wed, 15, 30))),
          // 15:00 would overlap the 15:30 offer, so the earlier group
          // starts at 14:00.
          [(15, 30), (16, 30), (14, 0), (13, 0)]);
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 45,
              zone: la,
              notBeforeUtc: at(wed, 15))),
          [(15, 0), (15, 45), (16, 30)]);
    });

    test('a notBefore between grid steps is rounded up onto the grid', () {
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              limit: 1,
              notBeforeUtc: at(wed, 15, 7))),
          [(15, 15)]);
    });

    test('with the afternoon gone, the earlier offers are nearest first', () {
      final events = [timed('pm', at(wed, 14), at(wed, 18))];
      expect(
          starts(freeSlotsOnDay(
              events: events,
              day: wed,
              durationMinutes: 60,
              zone: la,
              notBeforeUtc: at(wed, 15))),
          [(13, 0), (12, 0), (11, 0)]);
    });

    test('notBefore with no later opening still offers the earlier ones', () {
      final events = [timed('mid', at(wed, 10), at(wed, 15))];
      expect(
          starts(freeSlotsOnDay(
              events: events,
              day: wed,
              durationMinutes: 60,
              zone: la,
              notBeforeUtc: at(wed, 17, 30))),
          [(17, 0), (16, 0), (15, 0)]);
    });

    test('nowUtc still filters the preferred chain', () {
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              notBeforeUtc: at(wed, 15),
              nowUtc: at(wed, 15, 20))),
          [(15, 30), (16, 30)]);
    });

    test('a window clamp narrows the day: the afternoon starts at noon', () {
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              limit: 10,
              windowStartUtc: at(wed, 12),
              windowEndUtc: at(wed, 17))),
          [(12, 0), (13, 0), (14, 0), (15, 0), (16, 0)]);
    });

    test('a clamp with either bound alone, or outside working hours', () {
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              windowStartUtc: at(wed, 16, 5))),
          [(16, 15)]);
      expect(
          starts(freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              windowEndUtc: at(wed, 10))),
          [(8, 0), (9, 0)]);
      // An evening clamp misses the 08:00–18:00 day entirely.
      expect(
          freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 30,
              zone: la,
              windowStartUtc: at(wed, 19),
              windowEndUtc: at(wed, 22)),
          isEmpty);
      // An overlap shorter than the duration offers nothing either.
      expect(
          freeSlotsOnDay(
              events: const [],
              day: wed,
              durationMinutes: 60,
              zone: la,
              windowStartUtc: at(wed, 17, 30),
              windowEndUtc: at(wed, 21)),
          isEmpty);
    });

    test('nowUtc is a filter: nothing starts in the past', () {
      final slots = freeSlotsOnDay(
          events: const [],
          day: wed,
          durationMinutes: 60,
          zone: la,
          nowUtc: at(wed, 10, 42));
      expect(starts(slots), [(10, 45), (11, 45), (12, 45)]);
    });

    test('tentative blocks an offer by default; it can be told not to',
        () {
      final events = [
        timed('hold', at(wed, 8), at(wed, 17), showAs: 'tentative'),
      ];
      expect(
          starts(freeSlotsOnDay(
              events: events, day: wed, durationMinutes: 60, zone: la)),
          [(17, 0)]);
      expect(
          starts(freeSlotsOnDay(
              events: events,
              day: wed,
              durationMinutes: 60,
              zone: la,
              tentativeBlocks: false)),
          [(8, 0), (9, 0), (10, 0)]);
    });

    test('free, declined, cancelled and all-day events never block', () {
      final events = [
        timed('free', at(wed, 8), at(wed, 18), showAs: 'free'),
        timed('wfh', at(wed, 8), at(wed, 18), showAs: 'workingElsewhere'),
        timed('no', at(wed, 8), at(wed, 18), response: 'declined'),
        timed('gone', at(wed, 8), at(wed, 18), cancelled: true),
        allDay('banner', wed, wed.addDays(1)),
      ];
      expect(
          starts(freeSlotsOnDay(
              events: events, day: wed, durationMinutes: 60, zone: la)),
          [(8, 0), (9, 0), (10, 0)]);
    });

    test('working hours come from MailboxSettings, Graph format and all', () {
      const hours = MailboxSettings(
        workingStart: '09:30:00.0000000',
        workingEnd: '12:00:00',
      );
      final slots = freeSlotsOnDay(
          events: const [],
          day: wed,
          durationMinutes: 60,
          zone: la,
          hours: hours);
      expect(starts(slots), [(9, 30), (10, 30)]);
    });

    test('unreadable or backwards working hours fall back to 08:00-18:00', () {
      for (final hours in const [
        MailboxSettings(workingStart: 'nine', workingEnd: '17:00:00'),
        MailboxSettings(workingStart: '17:00:00', workingEnd: '09:00:00'),
        MailboxSettings(),
      ]) {
        final slots = freeSlotsOnDay(
            events: [timed('x', at(wed, 8), at(wed, 17))],
            day: wed,
            durationMinutes: 60,
            zone: la,
            hours: hours);
        expect(starts(slots), [(17, 0)], reason: '$hours');
      }
    });

    test('an impossible request is empty', () {
      expect(
          freeSlotsOnDay(
              events: const [], day: wed, durationMinutes: 0, zone: la),
          isEmpty);
      expect(
          freeSlotsOnDay(
              events: const [], day: wed, durationMinutes: 11 * 60, zone: la),
          isEmpty);
    });

    group('DST', () {
      /// Every slot is exactly [minutes] long in real time, and its start
      /// label — read back through the zone — is a wall time that exists.
      void expectHonest(List<FreeSlot> slots, int minutes, CalendarDate day) {
        for (final s in slots) {
          expect(s.duration, Duration(minutes: minutes));
          final local = la.toLocal(s.startUtc);
          // Rebuilding the label lands on the same instant OR (the repeated
          // hour of a fall-back night) on its earlier twin: never elsewhere.
          final rebuilt = la.localDateTime(
              CalendarDate(local.year, local.month, local.day),
              local.hour,
              local.minute);
          final gap = s.startUtc.difference(rebuilt).inMinutes;
          expect(gap == 0 || gap == 60, isTrue, reason: '$local');
          expect(CalendarDate(local.year, local.month, local.day), day);
        }
      }

      test('spring forward (2026-03-08): the skipped hour is never offered',
          () {
        const day = CalendarDate(2026, 3, 8);
        const hours =
            MailboxSettings(workingStart: '00:00:00', workingEnd: '06:00:00');
        final slots = freeSlotsOnDay(
            events: const [],
            day: day,
            durationMinutes: 60,
            zone: la,
            hours: hours,
            limit: 20);
        // 00:00 PST to 06:00 PDT is five real hours.
        expect(starts(slots), [(0, 0), (1, 0), (3, 0), (4, 0), (5, 0)]);
        expectHonest(slots, 60, day);
      });

      test('spring forward with the default window: 08:00 is 08:00 PDT', () {
        const day = CalendarDate(2026, 3, 8);
        final slots = freeSlotsOnDay(
            events: const [], day: day, durationMinutes: 45, zone: la);
        expect(starts(slots), [(8, 0), (8, 45), (9, 30)]);
        expect(slots.first.startUtc, DateTime.utc(2026, 3, 8, 15));
        expectHonest(slots, 45, day);
      });

      test('fall back (2026-11-01): the repeated hour is offered twice', () {
        const day = CalendarDate(2026, 11, 1);
        const hours =
            MailboxSettings(workingStart: '00:00:00', workingEnd: '04:00:00');
        final slots = freeSlotsOnDay(
            events: const [],
            day: day,
            durationMinutes: 60,
            zone: la,
            hours: hours,
            limit: 20);
        // 00:00 PDT to 04:00 PST is five real hours; 01:00 happens twice.
        expect(starts(slots), [(0, 0), (1, 0), (1, 0), (2, 0), (3, 0)]);
        expect(slots[1].startUtc, DateTime.utc(2026, 11, 1, 8));
        expect(slots[2].startUtc, DateTime.utc(2026, 11, 1, 9));
        expectHonest(slots, 60, day);
      });

      test('fall back with 90-minute slots stays 90 real minutes', () {
        const day = CalendarDate(2026, 11, 1);
        const hours =
            MailboxSettings(workingStart: '00:00:00', workingEnd: '06:00:00');
        final slots = freeSlotsOnDay(
            events: const [],
            day: day,
            durationMinutes: 90,
            zone: la,
            hours: hours,
            limit: 20);
        expect(slots, hasLength(4)); // seven real hours / 90 min
        expectHonest(slots, 90, day);
      });
    });
  });

  group('freeSlotsInRange', () {
    const dinner =
        AskHours(startHour: 17, startMinute: 30, endHour: 20, endMinute: 30);

    test('daily hours replace the working window, evenings included', () {
      final slots = freeSlotsInRange(
          events: [timed('x', at(wed, 17, 30), at(wed, 18, 30))],
          firstDay: wed,
          lastDay: wed,
          durationMinutes: 90,
          zone: la,
          dailyHours: dinner);
      // 18:30 is the first opening after the busy hour; 20:00 does not fit.
      expect(starts(slots), [(18, 30)]);
      expect(slots.single.endUtc, at(wed, 20));
    });

    test('daily hours on a weekend day the ask named are walked', () {
      const sat = CalendarDate(2026, 10, 17);
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: sat,
          lastDay: sat,
          durationMinutes: 90,
          zone: la,
          dailyHours: dinner,
          skipNonWorkingDays: false);
      expect(slots.map((s) => la.dateOf(s.startUtc)).toSet(), {sat});
      expect(starts(slots).first, (17, 30));
    });

    test('daily hours are still clamped by the window bounds', () {
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: wed,
          lastDay: wed,
          durationMinutes: 60,
          zone: la,
          dailyHours: dinner,
          windowEndUtc: at(wed, 19));
      expect(starts(slots), [(17, 30)]);
    });

    test('daily hours that end where they start offer nothing', () {
      expect(
          freeSlotsInRange(
              events: const [],
              firstDay: wed,
              lastDay: wed,
              durationMinutes: 30,
              zone: la,
              dailyHours: const AskHours(
                  startHour: 23, startMinute: 59, endHour: 23, endMinute: 59)),
          isEmpty);
    });

    test('the mailbox window as AskHours, and its working days', () {
      expect(workingWindowOf(null),
          const AskHours(startHour: 8, startMinute: 0, endHour: 18, endMinute: 0));
      expect(isWorkingDay(null, wed), isTrue);
      expect(isWorkingDay(null, const CalendarDate(2026, 10, 17)), isFalse);
    });

    test('across three days, one opening each', () {
      final events = <CalendarEvent>[];
      for (var i = 0; i < 3; i++) {
        final d = wed.addDays(i);
        events
          ..add(timed('a$i', at(d, 8), at(d, 10 + i)))
          ..add(timed('b$i', at(d, 11 + i), at(d, 18)));
      }
      final slots = freeSlotsInRange(
          events: events,
          firstDay: wed,
          lastDay: wed.addDays(2),
          durationMinutes: 60,
          zone: la);
      expect(slots.map((s) => la.dateOf(s.startUtc)).toList(),
          [wed, wed.addDays(1), wed.addDays(2)]);
      expect(starts(slots), [(10, 0), (11, 0), (12, 0)]);
    });

    test('the limit applies to the whole range', () {
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: wed,
          lastDay: wed.addDays(2),
          durationMinutes: 60,
          zone: la,
          limit: 2);
      expect(slots, hasLength(2));
      expect(slots.every((s) => la.dateOf(s.startUtc) == wed), isTrue);
    });

    test('the weekend is skipped without mailbox hours', () {
      const fri = CalendarDate(2026, 10, 16);
      final busyFri = [timed('f', at(fri, 8), at(fri, 18))];
      final slots = freeSlotsInRange(
          events: busyFri,
          firstDay: fri,
          lastDay: fri.addDays(3),
          durationMinutes: 60,
          zone: la,
          limit: 1);
      expect(la.dateOf(slots.single.startUtc), fri.addDays(3)); // Monday
    });

    test('working days come from MailboxSettings, case-insensitively', () {
      const fri = CalendarDate(2026, 10, 16);
      const hours = MailboxSettings(workingDays: ['Sunday', 'MONDAY']);
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: fri,
          lastDay: fri.addDays(3),
          durationMinutes: 60,
          zone: la,
          hours: hours,
          limit: 1);
      expect(la.dateOf(slots.single.startUtc), fri.addDays(2)); // Sunday
    });

    test('skipNonWorkingDays: false offers the weekend', () {
      const sat = CalendarDate(2026, 10, 17);
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: sat,
          lastDay: sat,
          durationMinutes: 60,
          zone: la,
          skipNonWorkingDays: false,
          limit: 1);
      expect(la.dateOf(slots.single.startUtc), sat);
      expect(
          freeSlotsInRange(
              events: const [],
              firstDay: sat,
              lastDay: sat,
              durationMinutes: 60,
              zone: la),
          isEmpty);
    });

    test('nowUtc filters today; notBefore prefers across days', () {
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: wed,
          lastDay: wed.addDays(1),
          durationMinutes: 60,
          zone: la,
          nowUtc: at(wed, 16, 10));
      expect(slots.map((s) => la.toLocal(s.startUtc).hour).toList(),
          [16, 8, 9]);
      expect(la.dateOf(slots[0].startUtc), wed);
      // The walk resumes on the first step at or after now (16:15); the next
      // opening, 17:15, would end past 18:00, so Thursday fills the rest.
      expect(starts(slots).first, (16, 15));

      final preferred = freeSlotsInRange(
          events: const [],
          firstDay: wed,
          lastDay: wed.addDays(1),
          durationMinutes: 60,
          zone: la,
          notBeforeUtc: at(wed.addDays(1), 16));
      // The earlier group is nearest first: Thursday 15:00, not Wednesday
      // 08:00.
      expect(starts(preferred), [(16, 0), (17, 0), (15, 0)]);
      expect(la.dateOf(preferred[2].startUtc), wed.addDays(1));
    });

    test('a window clamp spanning two days narrows each day', () {
      final slots = freeSlotsInRange(
          events: const [],
          firstDay: wed,
          lastDay: wed.addDays(2),
          durationMinutes: 60,
          zone: la,
          limit: 20,
          windowStartUtc: at(wed, 15),
          windowEndUtc: at(wed.addDays(1), 12));
      expect(slots.map((s) => la.dateOf(s.startUtc)).toList(), [
        wed,
        wed,
        wed,
        wed.addDays(1),
        wed.addDays(1),
        wed.addDays(1),
        wed.addDays(1),
      ]);
      expect(starts(slots),
          [(15, 0), (16, 0), (17, 0), (8, 0), (9, 0), (10, 0), (11, 0)]);
    });

    test('a backwards range is empty', () {
      expect(
          freeSlotsInRange(
              events: const [],
              firstDay: wed,
              lastDay: wed.addDays(-1),
              durationMinutes: 30,
              zone: la),
          isEmpty);
    });
  });
}
