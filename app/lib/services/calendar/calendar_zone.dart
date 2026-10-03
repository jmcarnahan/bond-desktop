import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../models/calendar_models.dart';

/// The display zone, and the one place local wall times are built.
///
/// The calendar stores instants in UTC and all-day events as bare dates (D13).
/// Everything a person SEES — "9:00", "Thursday", the Now line — is those
/// values read through one IANA zone, and this file decides which zone and
/// owns the conversions, so a DST day is handled in exactly one place.
///
/// The FULL database (`latest_all`), not the smaller default set: the default
/// leaves out the backward-compatible links, and macOS still reports some
/// zones by their old names (`Asia/Calcutta`), which the default set would
/// answer with "unknown" and silently drop the viewer to the mailbox zone.
///
/// This is the only file allowed to import `flutter_timezone`.

bool _zonesReady = false;

/// Loads the IANA database. Idempotent: the first call does the work, every
/// later call returns at once. `main.dart` calls it before `runApp`; tests
/// call it in `setUpAll`.
Future<void> initCalendarZones() async {
  if (_zonesReady) return;
  tz_data.initializeTimeZones();
  _zonesReady = true;
}

/// One IANA zone, as the calendar displays and builds local times in it.
@immutable
class CalendarZone {
  final tz.Location location;

  const CalendarZone(this.location);

  /// The IANA name, e.g. `America/Los_Angeles`.
  String get iana => location.name;

  /// UTC: the last resort, and a zone with no DST to get wrong.
  static CalendarZone utc() => CalendarZone(tz.UTC);

  /// [iana] as a zone, or null for an empty or unknown name. Never throws:
  /// the names come from the OS and from the mailbox, and neither is a
  /// promise that this database knows them.
  static CalendarZone? tryNamed(String? iana) {
    if (iana == null || iana.trim().isEmpty) return null;
    try {
      return CalendarZone(tz.getLocation(iana.trim()));
    } on Object {
      return null;
    }
  }

  /// [utc] on this zone's wall clock. The instant is unchanged; only how it
  /// reads (its year, month, day, hour) moves.
  tz.TZDateTime toLocal(DateTime utc) => tz.TZDateTime.from(utc, location);

  /// [hour]:[minute] on [date] in this zone, built from components — so on a
  /// spring-forward day 09:00 is 09:00 and not 10:00, which is what adding
  /// nine hours to local midnight would give. A wall time the clocks skip
  /// (02:30 on a spring-forward night) resolves the way the `timezone`
  /// package resolves it; nothing here invents a different rule.
  tz.TZDateTime localDateTime(CalendarDate date, int hour, int minute) =>
      tz.TZDateTime(location, date.year, date.month, date.day, hour, minute);

  /// The day [utc] falls on in this zone.
  CalendarDate dateOf(DateTime utc) => CalendarDate.ofDateTime(toLocal(utc));

  @override
  bool operator ==(Object other) => other is CalendarZone && other.iana == iana;

  @override
  int get hashCode => iana.hashCode;

  @override
  String toString() => 'CalendarZone($iana)';
}

/// The OS's IANA zone name, or null when the platform cannot say.
///
/// `flutter_timezone` 5.x answers a `TimezoneInfo` whose `identifier` is the
/// IANA name (older majors answered a bare String). Any failure — a missing
/// plugin under `flutter test`, a platform that returns nothing — is null,
/// so the resolver falls through to the mailbox's zone.
Future<String?> osZoneName() async {
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    return info.identifier;
  } on Object catch (e) {
    debugPrint('the OS time zone could not be read: $e');
    return null;
  }
}

/// The zone the calendar displays in: the OS zone, then the mailbox's
/// [mailboxIana], then UTC (D13). The machine the person is sitting at wins
/// over the mailbox, because a traveller's laptop is right about where they
/// are and their mailbox settings are not.
///
/// An unknown or empty name falls through to the next; a reader that throws
/// is treated as having no answer. Never throws. [osZone] is the seam tests
/// use; the default asks the OS through [osZoneName].
Future<CalendarZone> resolveCalendarZone({
  String? mailboxIana,
  Future<String?> Function()? osZone,
}) async {
  await initCalendarZones();
  String? os;
  try {
    os = await (osZone ?? osZoneName)();
  } on Object {
    os = null;
  }
  return CalendarZone.tryNamed(os) ??
      CalendarZone.tryNamed(mailboxIana) ??
      CalendarZone.utc();
}
