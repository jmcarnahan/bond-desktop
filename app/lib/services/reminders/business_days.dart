import '../calendar/calendar_zone.dart';

/// The [days]-th working day (Monday to Friday) after [from]'s local date in
/// [zone], at [hour]:00 on that day's wall clock, as a UTC instant — when a
/// "follow up in 2 days" reminder fires.
///
/// Counted on DATES, never by adding a [Duration]: [CalendarDate.addDays]
/// steps the wall date and [CalendarZone.localDateTime] builds the time from
/// components, so a DST weekend between the two leaves 09:00 at 09:00. A
/// [from] on a weekend counts from that date too, so Saturday + 1 is Monday.
/// Holidays are not known here; a reminder on one is a reminder the owner
/// moves in To Do.
DateTime nextBusinessDaysAt({
  required int days,
  required DateTime from,
  required CalendarZone zone,
  int hour = 9,
}) {
  var date = zone.dateOf(from);
  var counted = 0;
  while (counted < days) {
    date = date.addDays(1);
    if (date.weekday <= DateTime.friday) counted++;
  }
  return zone.localDateTime(date, hour, 0).toUtc();
}
