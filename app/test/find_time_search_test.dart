import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/find_time.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `find_meeting_times` recorded and scripted; every other method throws.
class _Backend extends Fake implements CalendarBackend {
  final List<List<String>> asked = [];
  Object answer = const <MeetingTimeSuggestion>[];

  @override
  Future<List<MeetingTimeSuggestion>> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) async {
    asked.add(attendees);
    final a = answer;
    if (a is List<MeetingTimeSuggestion>) return a;
    throw a;
  }
}

/// The search behind Find a time: everyone's calendars when somebody is on
/// it, the owner's own mirror when nobody is or the account cannot look
/// others up, a sentence for any other failure, and overlaps from the
/// mirror. Wed Oct 14 2026 in Los Angeles; fictional meetings.
void main() {
  late CalendarZone la;
  late BondDatabase db;
  late CalendarStore calendar;
  late _Backend backend;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  setUp(() {
    db = testDb();
    calendar = CalendarStore(db);
    backend = _Backend();
  });

  tearDown(() async {
    await db.close();
  });

  // Wed Oct 14 2026, 9:00 AM PDT.
  final now = DateTime.utc(2026, 10, 14, 16);
  // Wed 10:00–10:30 AM PDT.
  final ten = DateTime.utc(2026, 10, 14, 17);

  Future<FindTimeResult> search(List<String> addresses) => searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: null,
        addresses: addresses,
        durationMinutes: 30,
        window: FindTimeWindow.thisWeek,
        now: now,
        zone: la,
      );

  test('with people: everyone\'s calendars, and the mirror\'s overlaps',
      () async {
    await calendar.upsertEvents([
      CalendarEvent(
        id: 'busy-1',
        subject: 'Budget review',
        startUtc: ten,
        endUtc: ten.add(const Duration(minutes: 30)),
        showAs: 'busy',
      ),
    ], syncRun: 'run-1');
    backend.answer = [
      MeetingTimeSuggestion(
          startUtc: ten, endUtc: ten.add(const Duration(minutes: 30))),
    ];
    final r = await search(['dana@fabrikam.example']);
    expect(backend.asked.single, ['dana@fabrikam.example']);
    expect(r.source, 'graph');
    expect(r.note, isNull);
    expect(r.slots.single.startUtc, ten);
    expect(r.overlaps[r.slots.single]!.hard.single.id, 'busy-1');
  });

  test('nobody else: never asks the server, reads the mirror', () async {
    final r = await search(const []);
    expect(backend.asked, isEmpty);
    expect(r.source, 'local');
    expect(r.slots, hasLength(3));
    expect(r.note, isNull);
    for (final s in r.slots) {
      expect(s.startUtc.isBefore(now), isFalse);
    }
  });

  test('an account that cannot look others up falls back, and says so',
      () async {
    backend.answer =
        const CalendarRefused('unsupported_account', 'Personal account.');
    final r = await search(['dana@fabrikam.example']);
    expect(r.source, 'local');
    expect(r.note, findTimeLocalNote);
    expect(r.slots, isNotEmpty);
  });

  test('any other failure is its sentence and no slots', () async {
    backend.answer = const CalendarRefused('invalid_arguments', 'Bad window.');
    final r = await search(['dana@fabrikam.example']);
    expect(r.slots, isEmpty);
    expect(r.note, 'Bad window.');

    backend.answer = StateError('boom');
    final r2 = await search(['dana@fabrikam.example']);
    expect(r2.slots, isEmpty);
    expect(r2.note, "Couldn't reach the calendar to find a time.");
  });
}
