import 'package:bond_inbox/models/calendar_models.dart' show CalendarDate;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/reminders/business_days.dart';
import 'package:flutter_test/flutter_test.dart';

/// The follow-up's "in N working days, at 09:00": counted on wall dates in
/// the owner's zone, Monday to Friday, and built from components so a DST
/// weekend leaves 09:00 at 09:00.
void main() {
  late CalendarZone la;
  late CalendarZone auckland;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    auckland = CalendarZone.tryNamed('Pacific/Auckland')!;
  });

  /// [y]-[m]-[d] at [h]:00 on [zone]'s wall, as UTC.
  DateTime at(CalendarZone zone, int y, int m, int d, [int h = 14]) =>
      zone.localDateTime(CalendarDate(y, m, d), h, 0).toUtc();

  test('Friday + 2 is Tuesday at 09:00', () {
    // Friday 2026-10-02, mid-afternoon in Los Angeles.
    final due = nextBusinessDaysAt(
        days: 2, from: at(la, 2026, 10, 2), zone: la);
    final local = la.toLocal(due);
    expect((local.year, local.month, local.day), (2026, 10, 6));
    expect(local.weekday, DateTime.tuesday);
    expect((local.hour, local.minute), (9, 0));
    expect(due.isUtc, isTrue);
  });

  test('Saturday + 1 is Monday', () {
    final due = nextBusinessDaysAt(
        days: 1, from: at(la, 2026, 10, 3), zone: la);
    final local = la.toLocal(due);
    expect((local.year, local.month, local.day), (2026, 10, 5));
    expect(local.weekday, DateTime.monday);
    expect(local.hour, 9);
  });

  test('five working days from a Wednesday is the next Wednesday', () {
    final due = nextBusinessDaysAt(
        days: 5, from: at(la, 2026, 10, 7), zone: la);
    final local = la.toLocal(due);
    expect((local.year, local.month, local.day), (2026, 10, 14));
    expect(local.weekday, DateTime.wednesday);
  });

  test('across the fall-back weekend in Los Angeles it is still 09:00', () {
    // Clocks go back on Sunday 2026-11-01. Friday Oct 30 + 1 is Monday Nov 2,
    // 09:00 PST = 17:00 UTC (it was 16:00 UTC under PDT the week before).
    final due = nextBusinessDaysAt(
        days: 1, from: at(la, 2026, 10, 30), zone: la);
    final local = la.toLocal(due);
    expect((local.year, local.month, local.day), (2026, 11, 2));
    expect((local.hour, local.minute), (9, 0));
    expect(due, DateTime.utc(2026, 11, 2, 17));
    final before = nextBusinessDaysAt(
        days: 1, from: at(la, 2026, 10, 22), zone: la);
    expect(before, DateTime.utc(2026, 10, 23, 16));
  });

  test('Pacific/Auckland reads its own wall date, a day ahead of UTC', () {
    // Monday 2026-10-05 07:00 in Auckland is still Sunday in UTC; the count
    // starts from Auckland's Monday, so + 1 is Tuesday there.
    final due = nextBusinessDaysAt(
        days: 1, from: at(auckland, 2026, 10, 5, 7), zone: auckland);
    final local = auckland.toLocal(due);
    expect((local.year, local.month, local.day), (2026, 10, 6));
    expect((local.hour, local.minute), (9, 0));
    // NZDT is UTC+13 in October.
    expect(due, DateTime.utc(2026, 10, 5, 20));
  });

  test('another hour is honoured', () {
    final due = nextBusinessDaysAt(
        days: 1, from: at(la, 2026, 10, 5), zone: la, hour: 15);
    expect(la.toLocal(due).hour, 15);
  });
}
