import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which zone the calendar displays in, and the one place local wall times are
/// built.
///
/// The fallback order is D13's: the OS zone, then the mailbox's, then UTC, and
/// an unknown or unreadable name falls through rather than failing. The OS
/// reader is injected, so nothing here depends on the test machine's zone.
void main() {
  setUpAll(initCalendarZones);

  group('resolveCalendarZone', () {
    test('the OS zone wins when it is known', () async {
      final zone = await resolveCalendarZone(
        mailboxIana: 'Europe/London',
        osZone: () async => 'Pacific/Auckland',
      );
      expect(zone.iana, 'Pacific/Auckland');
    });

    test('an unknown OS zone falls through to the mailbox', () async {
      final zone = await resolveCalendarZone(
        mailboxIana: 'Europe/London',
        osZone: () async => 'Mars/Olympus_Mons',
      );
      expect(zone.iana, 'Europe/London');
    });

    test('an empty or null OS answer falls through to the mailbox', () async {
      expect(
        (await resolveCalendarZone(
          mailboxIana: 'Europe/London',
          osZone: () async => '',
        ))
            .iana,
        'Europe/London',
      );
      expect(
        (await resolveCalendarZone(
          mailboxIana: 'Europe/London',
          osZone: () async => null,
        ))
            .iana,
        'Europe/London',
      );
    });

    test('both unknown is UTC', () async {
      final zone = await resolveCalendarZone(
        mailboxIana: '',
        osZone: () async => 'Nowhere/Special',
      );
      expect(zone, CalendarZone.utc());
      // The database names it Etc/UTC; either way it is offset zero.
      expect(zone.toLocal(DateTime.utc(2026, 7, 1, 12)).hour, 12);
    });

    test('a throwing OS reader is no answer, not a failure', () async {
      final zone = await resolveCalendarZone(
        mailboxIana: 'America/Los_Angeles',
        osZone: () async => throw StateError('no plugin'),
      );
      expect(zone.iana, 'America/Los_Angeles');
    });

    test('an old backward-link name the OS may still report is known', () {
      // macOS has reported India's zone by its pre-2008 name.
      expect(CalendarZone.tryNamed('Asia/Calcutta'), isNotNull);
    });

    test('initCalendarZones is idempotent', () async {
      await initCalendarZones();
      await initCalendarZones();
      expect(CalendarZone.tryNamed('America/Los_Angeles'), isNotNull);
    });
  });

  group('CalendarZone', () {
    test('tryNamed never throws', () {
      expect(CalendarZone.tryNamed(null), isNull);
      expect(CalendarZone.tryNamed(''), isNull);
      expect(CalendarZone.tryNamed('   '), isNull);
      expect(CalendarZone.tryNamed('Not/AZone'), isNull);
      expect(CalendarZone.utc().iana, endsWith('UTC'));
    });

    test('localDateTime builds 09:00 from components on a spring-forward day',
        () {
      final la = CalendarZone.tryNamed('America/Los_Angeles')!;
      // 2026-03-08 is the US spring-forward Sunday: 02:00 PST jumps to 03:00
      // PDT. The day before is UTC−8, the day itself from 03:00 is UTC−7.
      final before = la.localDateTime(const CalendarDate(2026, 3, 7), 9, 0);
      final onTheDay = la.localDateTime(const CalendarDate(2026, 3, 8), 9, 0);
      final early = la.localDateTime(const CalendarDate(2026, 3, 8), 1, 0);

      expect(before.toUtc(), DateTime.utc(2026, 3, 7, 17));
      expect(onTheDay.toUtc(), DateTime.utc(2026, 3, 8, 16));
      expect(early.toUtc(), DateTime.utc(2026, 3, 8, 9));
      // The wall clock says 09:00 — not the 10:00 that midnight + 9 h gives.
      expect(onTheDay.hour, 9);
      expect(onTheDay.day, 8);
      // Local midnight to local 09:00 is only eight hours on this day.
      final midnight = la.localDateTime(const CalendarDate(2026, 3, 8), 0, 0);
      expect(onTheDay.difference(midnight), const Duration(hours: 8));
    });

    test('toLocal and dateOf read an instant on the zone\'s wall', () {
      final auckland = CalendarZone.tryNamed('Pacific/Auckland')!;
      // 2026-10-01 20:00 UTC is already 2 October in Auckland (UTC+13).
      final utc = DateTime.utc(2026, 10, 1, 20);
      expect(auckland.toLocal(utc).day, 2);
      expect(auckland.dateOf(utc), const CalendarDate(2026, 10, 2));
      expect(auckland.toLocal(utc).toUtc(), utc);
    });
  });
}
