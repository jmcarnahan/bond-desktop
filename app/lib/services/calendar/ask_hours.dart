import 'package:flutter/foundation.dart' show immutable;

import 'when_resolver.dart' show DayPart, DayPartBounds;

/// A wall-clock window on whatever day it is applied to: a meal's hours, a
/// part of the day's, or two hours from a time the ask named.
///
/// Its own file so the free-slot walk (`overlaps.dart`) can name the type
/// without importing the ask reader; `ask_hints.dart` re-exports it, so
/// every other importer reads it from there as before.
@immutable
class AskHours {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;

  const AskHours({
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
  });

  /// [part]'s own bounds ([DayPartBounds]).
  factory AskHours.fromDayPart(DayPart part) => AskHours(
        startHour: part.start.$1,
        startMinute: part.start.$2,
        endHour: part.end.$1,
        endMinute: part.end.$2,
      );

  int get startInMinutes => startHour * 60 + startMinute;
  int get endInMinutes => endHour * 60 + endMinute;

  @override
  bool operator ==(Object other) =>
      other is AskHours &&
      other.startHour == startHour &&
      other.startMinute == startMinute &&
      other.endHour == endHour &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(startHour, startMinute, endHour, endMinute);

  @override
  String toString() => 'AskHours($startHour:$startMinute–$endHour:$endMinute)';
}
