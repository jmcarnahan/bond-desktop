import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/find_time.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart' show FreeSlot;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `find_meeting_times` recorded and scripted; every other method throws.
class _Backend extends Fake implements CalendarBackend {
  final List<List<String>> asked = [];
  final List<int> candidates = [];
  Object answer = const <MeetingTimeSuggestion>[];

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) async {
    asked.add(attendees);
    candidates.add(maxCandidates);
    final a = answer;
    if (a is List<MeetingTimeSuggestion>) return MeetingTimes(suggestions: a);
    // An empty answer with Graph's reason.
    if (a is MeetingTimes) return a;
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

  group('ranked by who is free', () {
    // Wed 10:00, 11:00, 12:00, 1:00 and 2:00 PM PDT, half an hour each.
    MeetingTimeSuggestion at(
      int hourUtc, {
      double confidence = 50,
      String organizer = 'free',
      Map<String, String> attendees = const {},
    }) =>
        MeetingTimeSuggestion(
          startUtc: DateTime.utc(2026, 10, 14, hourUtc),
          endUtc: DateTime.utc(2026, 10, 14, hourUtc, 30),
          confidence: confidence,
          organizerAvailability: organizer,
          attendeeAvailability: attendees,
        );
    FreeSlot slotAt(int hourUtc) => FreeSlot(DateTime.utc(2026, 10, 14, hourUtc),
        DateTime.utc(2026, 10, 14, hourUtc, 30));

    test('asks for five, keeps three, everyone-free first', () async {
      backend.answer = [
        at(17, attendees: {'dana@fabrikam.example': 'busy'}),
        at(18, attendees: {'dana@fabrikam.example': 'busy'}),
        at(19, attendees: {'dana@fabrikam.example': 'Free'}),
        at(20, attendees: {'dana@fabrikam.example': 'tentative'}),
        at(21, attendees: {'dana@fabrikam.example': 'busy'}),
      ];
      final r = await search(['dana@fabrikam.example']);
      expect(backend.candidates.single, 5);
      expect(r.slots, hasLength(3));
      // The third suggestion leads: the only one both people can make.
      expect(r.slots.first, slotAt(19));
      expect(r.availability[slotAt(19)]!.caption, 'Everyone free');
      expect(r.availability[slotAt(19)]!.everyone, isTrue);
      // The rest tie on one free; the sooner start breaks the tie.
      expect(r.slots[1], slotAt(17));
      expect(r.slots[2], slotAt(18));
      expect(r.availability[slotAt(17)]!.caption, '1 of 2 free');
      expect(r.availability.keys.toSet(), r.slots.toSet());
    });

    test('a tie on who is free breaks on confidence', () async {
      backend.answer = [
        at(17, confidence: 40, attendees: {'dana@fabrikam.example': 'free'}),
        at(18, confidence: 90, attendees: {'dana@fabrikam.example': 'free'}),
      ];
      final r = await search(['dana@fabrikam.example']);
      expect(r.slots, [slotAt(18), slotAt(17)]);
    });

    test('the count is out of the people asked, and nobody twice', () async {
      const owner = 'me@contoso.example';
      backend.answer = [
        // Graph answers for only one of the two asked, and lists the
        // owner's own address among the attendees.
        at(17, attendees: {
          'Dana@fabrikam.example': 'free',
          owner: 'free',
        }),
      ];
      final r = await searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: null,
        addresses: const ['dana@fabrikam.example', 'lee@northwind.example'],
        durationMinutes: 30,
        window: FindTimeWindow.thisWeek,
        now: now,
        zone: la,
      );
      final a = r.availability[slotAt(17)]!;
      expect(a.caption, '2 of 3 free');
      expect(a.everyone, isFalse);
    });

    test('a mirror result carries no head counts', () async {
      final r = await search(const []);
      expect(r.source, 'local');
      expect(r.slots, isNotEmpty);
      expect(r.availability, isEmpty);
    });
  });

  group('an empty answer', () {
    test('an unreadable attendee falls back to the owner\'s free times with '
        'the note', () async {
      for (final reason in const [
        'attendeesunavailableorunknown',
        'organizerunavailable',
        'locationsunavailable',
        'unknown',
        '',
      ]) {
        backend.answer = MeetingTimes(emptyReason: reason);
        final r = await search(['dana@fabrikam.example']);
        expect(r.source, 'local', reason: reason);
        expect(r.note, findTimeUnreadableNote, reason: reason);
        expect(r.slots, hasLength(3), reason: 'the mirror\'s openings');
        expect(r.availability, isEmpty);
      }
    });

    test('attendees all busy says nobody is free and shows no slots',
        () async {
      backend.answer = const MeetingTimes(emptyReason: 'attendeesunavailable');
      final r = await search(['dana@fabrikam.example']);
      expect(r.source, 'graph');
      expect(r.slots, isEmpty);
      expect(r.note, 'Nobody is free this week — try next week.');

      final next = await searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: null,
        addresses: const ['dana@fabrikam.example'],
        durationMinutes: 30,
        window: FindTimeWindow.nextWeek,
        now: now,
        zone: la,
      );
      expect(next.note, 'Nobody is free next week — try this week.');
    });

    test('the rule: only attendeesunavailable is a no', () {
      expect(findTimeEmptyFallback('AttendeesUnavailable'),
          FindTimeEmpty.nobodyFree);
      expect(findTimeEmptyFallback('attendeesunavailableorunknown'),
          FindTimeEmpty.unreadable);
      expect(findTimeEmptyFallback(''), FindTimeEmpty.unreadable);
    });
  });
}
