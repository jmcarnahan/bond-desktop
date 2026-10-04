import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/models/calendar_models.dart' show CalendarDate;
import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';

/// The 40 fictional scheduling asks both readers are scored on
/// (`test/fixtures/ask_reads/asks.jsonl`): the offline rules score
/// (`ask_read_fixture_test.dart`) and the live model score
/// (`ask_read_eval_live_test.dart`, `make ask-read-eval`). `expect` is what a
/// PERFECT reading yields once Dart resolves it — so a row the resolvers
/// themselves cannot read ("the 14th") expects what Dart can give and is
/// marked `hard`.

/// Where the fixture lives, relative to `app/` (the test runner's working
/// directory).
const String askReadsPath = 'test/fixtures/ask_reads/asks.jsonl';

/// One fixture ask.
class AskCase {
  AskCase(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get subject => json['subject'] as String;
  String get body => json['body'] as String;
  DateTime get sentAt => DateTime.parse(json['sent_at'] as String);
  DateTime get now => DateTime.parse(json['now'] as String);
  CalendarZone get zone => CalendarZone.tryNamed(json['zone'] as String)!;
  Map<String, dynamic> get expected => json['expect'] as Map<String, dynamic>;
  bool get hard => json['hard'] == true;

  /// The expectation in [askOutcome]'s shape.
  String get want {
    final e = expected;
    if (e['none'] == true) return 'none';
    return _outcome(
      days: [for (final d in e['days'] as List) d as String],
      start: e['start'] as String?,
      end: e['end'] as String?,
      minutes: e['minutes'] as int?,
    );
  }

  /// The rules' reading of this ask ([readAskHints]).
  AskHints rules() => readAskHints(
      subject: subject, body: body, now: now, zone: zone, sentAt: sentAt);
}

/// Every row of the fixture, in file order.
List<AskCase> loadAskCases() => [
      for (final line in File(askReadsPath).readAsLinesSync())
        if (line.trim().isNotEmpty)
          AskCase(jsonDecode(line) as Map<String, dynamic>),
    ];

/// [hints] in one comparable line: `none`, or `{days · hh:mm–hh:mm · Nm}`
/// with `-` for what is absent.
String askOutcome(AskHints hints) {
  if (!hints.any) return 'none';
  final h = hints.hours;
  String hm(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  return _outcome(
    days: [for (final d in hints.days) _date(d)],
    start: h == null ? null : hm(h.startHour, h.startMinute),
    end: h == null ? null : hm(h.endHour, h.endMinute),
    minutes: hints.minutes,
  );
}

String _date(CalendarDate d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _outcome({
  required List<String> days,
  String? start,
  String? end,
  int? minutes,
}) =>
    '{${days.isEmpty ? '-' : days.join(' ')} · '
    '${start == null ? '-' : '$start–$end'} · '
    '${minutes == null ? '-' : '${minutes}m'}}';
