import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/find_time.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart' show FreeSlot;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `find_meeting_times` recorded and scripted; every other method throws.
class _Backend extends Fake implements CalendarBackend {
  final List<List<String>> asked = [];
  final List<int> candidates = [];
  final List<(DateTime, DateTime)> windows = [];
  final List<String> domains = [];
  Object answer = const <MeetingTimeSuggestion>[];

  /// When set, answers each call by its window instead of [answer].
  Object Function(DateTime start, DateTime end)? answerFor;

  /// Calls in flight now, and the most at once.
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
    String activityDomain = 'work',
  }) async {
    asked.add(attendees);
    candidates.add(maxCandidates);
    windows.add((windowStartUtc, windowEndUtc));
    domains.add(activityDomain);
    inFlight += 1;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    // A turn of the event loop, so calls made together overlap.
    await Future<void>.delayed(Duration.zero);
    inFlight -= 1;
    final a = answerFor?.call(windowStartUtc, windowEndUtc) ?? answer;
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

  group('with the ask\'s hints', () {
    const fri = CalendarDate(2026, 10, 16);
    const sat = CalendarDate(2026, 10, 17);
    const dinner =
        AskHours(startHour: 17, startMinute: 30, endHour: 20, endMinute: 30);
    const morning =
        AskHours(startHour: 9, startMinute: 0, endHour: 12, endMinute: 0);

    Future<FindTimeResult> hinted(
      AskHints hints, {
      List<String> addresses = const [],
      FindTimeWindow window = FindTimeWindow.theirs,
      int minutes = 30,
    }) =>
        searchFindTime(
          backend: backend,
          calendar: calendar,
          hours: null,
          addresses: addresses,
          durationMinutes: minutes,
          window: window,
          now: now,
          zone: la,
          hints: hints,
        );

    DateTime local(CalendarDate d, int h, [int m = 0]) =>
        DateTime.fromMicrosecondsSinceEpoch(
            la.localDateTime(d, h, m).microsecondsSinceEpoch,
            isUtc: true);

    test('their day is that day alone', () async {
      final r = await hinted(const AskHints(day: fri));
      expect(r.slots, hasLength(3));
      expect(r.slots.map((s) => la.dateOf(s.startUtc)).toSet(), {fri});
    });

    test('their day with no day read is this week', () async {
      final w = findTimeWindowUtc(FindTimeWindow.theirs,
          now: now, zone: la, hints: const AskHints(hours: dinner));
      final week = findTimeWindowUtc(FindTimeWindow.thisWeek,
          now: now, zone: la, hints: const AskHints(hours: dinner));
      expect(w, week);
    });

    test('evening hours give evening slots from the mirror', () async {
      final r = await hinted(const AskHints(hours: dinner),
          window: FindTimeWindow.thisWeek, minutes: 90);
      expect(r.slots, isNotEmpty);
      for (final s in r.slots) {
        final t = la.toLocal(s.startUtc);
        expect(t.hour * 60 + t.minute, greaterThanOrEqualTo(17 * 60 + 30));
      }
    });

    test('a Saturday the ask named is not skipped', () async {
      final r = await hinted(const AskHints(day: sat, hours: dinner));
      expect(r.slots.map((s) => la.dateOf(s.startUtc)).toSet(), {sat});
    });

    test('Graph is asked over their day and hours, unrestricted for dinner',
        () async {
      await hinted(const AskHints(day: fri, hours: dinner),
          addresses: ['dana@fabrikam.example'], minutes: 90);
      expect(backend.windows.single,
          (local(fri, 17, 30), local(fri, 20, 30)));
      // Graph's personal is working hours plus the weekend; only
      // unrestricted opens the evening.
      expect(backend.domains.single, 'unrestricted');
    });

    test('with hours on one day, Graph is asked once over the hours for '
        'five, and an answer outside them is dropped as a belt', () async {
      backend.answer = [
        MeetingTimeSuggestion(
            startUtc: local(fri, 16), endUtc: local(fri, 17, 30),
            confidence: 100),
        MeetingTimeSuggestion(
            startUtc: local(fri, 18), endUtc: local(fri, 19, 30),
            confidence: 50),
      ];
      final r = await hinted(const AskHints(day: fri, hours: dinner),
          addresses: ['dana@fabrikam.example'], minutes: 90);
      expect(backend.windows.single,
          (local(fri, 17, 30), local(fri, 20, 30)));
      expect(backend.candidates.single, 5);
      expect(r.graphCalls, 1);
      expect(r.source, 'graph');
      expect(r.slots, [FreeSlot(local(fri, 18), local(fri, 19, 30))]);
    });

    test('hours with no day on the week\'s last day are asked from their '
        'opening, never from now', () async {
      // Friday Oct 16 2026, 10:00 AM PDT: "dinner this week" is tonight.
      // One call over the window would start at ten in the morning.
      final r = await searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: null,
        addresses: const ['dana@fabrikam.example'],
        durationMinutes: 90,
        window: FindTimeWindow.thisWeek,
        now: DateTime.utc(2026, 10, 16, 17),
        zone: la,
        hints: const AskHints(hours: dinner),
      );
      expect(backend.windows.single,
          (local(fri, 17, 30), local(fri, 20, 30)));
      expect(backend.candidates.single, 5);
      expect(backend.domains.single, 'unrestricted');
      expect(r.graphCalls, 1);
    });

    test('hours over several days ask Graph one day at a time, inside the '
        'hours', () async {
      const days = [
        CalendarDate(2026, 10, 19),
        CalendarDate(2026, 10, 20),
        CalendarDate(2026, 10, 21),
        CalendarDate(2026, 10, 22),
        CalendarDate(2026, 10, 23),
      ];
      const wed = CalendarDate(2026, 10, 21);
      backend.answerFor = (start, end) => start == local(wed, 17, 30)
          ? [
              MeetingTimeSuggestion(
                  startUtc: local(wed, 18), endUtc: local(wed, 19, 30)),
            ]
          : const MeetingTimes(emptyReason: 'unknown');
      final r = await hinted(const AskHints(hours: dinner),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.nextWeek,
          minutes: 90);
      expect(backend.windows,
          [for (final d in days) (local(d, 17, 30), local(d, 20, 30))]);
      expect(backend.candidates, [5, 5, 5, 5, 5]);
      expect(backend.domains.toSet(), {'unrestricted'});
      expect(r.source, 'graph');
      expect(r.slots, [FreeSlot(local(wed, 18), local(wed, 19, 30))]);
      expect(r.graphCalls, 5);
      expect(backend.maxInFlight, 5, reason: 'the days are asked together');
    });

    group('several days, merged', () {
      const fri = CalendarDate(2026, 10, 23);
      Future<FindTimeResult> week() => hinted(const AskHints(hours: dinner),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.nextWeek,
          minutes: 90);

      test('every day nobody free is the nobody-free note', () async {
        backend.answer = const MeetingTimes(emptyReason: 'attendeesunavailable');
        final r = await week();
        expect(r.source, 'graph');
        expect(r.slots, isEmpty);
        expect(r.note, 'Nobody is free next week — try this week.');
      });

      test('one day unreadable is the unreadable fallback', () async {
        backend.answerFor = (start, _) => start == local(fri, 17, 30)
            ? const MeetingTimes(emptyReason: 'unknown')
            : const MeetingTimes(emptyReason: 'attendeesunavailable');
        final r = await week();
        expect(r.source, 'local');
        expect(r.note, findTimeUnreadableNote);
        expect(r.slots, isNotEmpty);
      });

      test('a day whose call failed is never read as nobody free', () async {
        backend.answerFor = (start, _) => start == local(fri, 17, 30)
            ? const CalendarUnavailable('Graph is busy.')
            : const MeetingTimes(emptyReason: 'attendeesunavailable');
        final r = await week();
        expect(r.failed, isFalse);
        expect(r.source, 'local');
        expect(r.note, findTimeUnreadableNote);
        expect(r.slots, isNotEmpty);
      });

      test('a missing permission on any day is the search\'s own failure',
          () async {
        backend.answerFor = (start, _) => start == local(fri, 17, 30)
            ? const CalendarScopeMissing()
            : [
                MeetingTimeSuggestion(
                    startUtc: local(const CalendarDate(2026, 10, 21), 18),
                    endUtc: local(const CalendarDate(2026, 10, 21), 19, 30)),
              ];
        final r = await week();
        expect(r.failed, isTrue);
        expect(r.slots, isEmpty);
        expect(r.note, 'Calendar permission missing — reconnect in Settings.');
        expect(r.graphCalls, 5);
      });

      test('an account that cannot look others up falls back as one call '
          'would', () async {
        backend.answerFor = (start, _) => start == local(fri, 17, 30)
            ? const CalendarRefused('unsupported_account', 'Personal account.')
            : const MeetingTimes(emptyReason: 'attendeesunavailable');
        final r = await week();
        expect(r.source, 'local');
        expect(r.note, findTimeLocalNote);
      });
    });

    test('a day already over is not asked, and one day failing costs that '
        'day alone', () async {
      // This week from Wednesday 9:00 AM: Wednesday's dinner is still ahead.
      const thu = CalendarDate(2026, 10, 15);
      backend.answerFor = (start, end) => start == local(thu, 17, 30)
          ? [
              MeetingTimeSuggestion(
                  startUtc: local(thu, 18), endUtc: local(thu, 19, 30)),
            ]
          : const CalendarUnavailable('Graph is busy.');
      final r = await hinted(const AskHints(hours: dinner),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.thisWeek,
          minutes: 90);
      expect(backend.windows.first,
          (local(const CalendarDate(2026, 10, 14), 17, 30),
              local(const CalendarDate(2026, 10, 14), 20, 30)));
      expect(r.graphCalls, 3, reason: 'Wednesday, Thursday and Friday');
      expect(r.failed, isFalse);
      expect(r.slots, [FreeSlot(local(thu, 18), local(thu, 19, 30))]);

      // Wednesday 8:00 PM: today's dinner has no room for an hour and a
      // half, and every day failing is the search failing.
      backend.windows.clear();
      backend.answerFor = (_, _) => const CalendarUnavailable('Graph is busy.');
      final late = await searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: null,
        addresses: const ['dana@fabrikam.example'],
        durationMinutes: 90,
        window: FindTimeWindow.thisWeek,
        now: DateTime.utc(2026, 10, 15, 3),
        zone: la,
        hints: const AskHints(hours: dinner),
      );
      expect(backend.windows.first.$1, local(thu, 17, 30));
      expect(late.graphCalls, 2);
      expect(late.failed, isTrue);
      expect(late.note, 'Graph is busy.');
    });

    test('an answer wholly outside the hours asked is an empty answer: your '
        'own openings in those hours, said as unreadable', () async {
      const tue = CalendarDate(2026, 10, 20);
      backend.answer = [
        MeetingTimeSuggestion(
            startUtc: local(tue, 10), endUtc: local(tue, 11, 30)),
      ];
      final r = await hinted(const AskHints(hours: dinner),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.nextWeek,
          minutes: 90);
      expect(r.source, 'local');
      expect(r.note, findTimeUnreadableNote);
      expect(r.slots, isNotEmpty);
      for (final s in r.slots) {
        expect(la.toLocal(s.startUtc).hour, greaterThanOrEqualTo(17));
      }
    });

    test('without hours Graph is still asked for five', () async {
      await hinted(const AskHints(day: fri),
          addresses: ['dana@fabrikam.example']);
      expect(backend.candidates.single, 5);
    });

    test('a week searched under hints still skips its weekend', () async {
      final r = await hinted(const AskHints(hours: dinner),
          window: FindTimeWindow.nextWeek, minutes: 90);
      for (final s in r.slots) {
        expect(la.dateOf(s.startUtc).weekday, lessThan(6));
      }
      expect(r.slots, isNotEmpty);
    });

    test('hours that end where they start offer nothing and ask nobody',
        () async {
      const late = AskHours(
          startHour: 23, startMinute: 59, endHour: 23, endMinute: 59);
      final r = await hinted(const AskHints(day: fri, hours: late),
          addresses: ['dana@fabrikam.example']);
      expect(r.slots, isEmpty);
      expect(backend.asked, isEmpty);
      final own = await hinted(const AskHints(day: fri, hours: late));
      expect(own.slots, isEmpty);
    });

    test('a morning on a weekday stays work time', () async {
      await hinted(const AskHints(day: fri, hours: morning),
          addresses: ['dana@fabrikam.example']);
      expect(backend.windows.single, (local(fri, 9), local(fri, 12)));
      expect(backend.domains.single, 'work');
    });

    test('a weekend day is personal even in working hours', () async {
      await hinted(const AskHints(day: sat, hours: morning),
          addresses: ['dana@fabrikam.example']);
      expect(backend.domains.single, 'personal');
    });

    test('a week with no day named stays work on a Sunday–Thursday mailbox',
        () async {
      const sunToThu = MailboxSettings(workingDays: [
        'sunday',
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
      ]);
      await searchFindTime(
        backend: backend,
        calendar: calendar,
        hours: sunToThu,
        addresses: const ['dana@fabrikam.example'],
        durationMinutes: 30,
        window: FindTimeWindow.thisWeek,
        now: now,
        zone: la,
      );
      // The owner's own walk skips Friday; Graph must not offer it either.
      expect(backend.domains.single, 'work');
    });

    test('the domain follows the days searched, whichever pill asked',
        () async {
      for (final window in [FindTimeWindow.thisWeek, FindTimeWindow.nextWeek]) {
        backend.domains.clear();
        await hinted(const AskHints(day: sat, hours: morning),
            addresses: ['dana@fabrikam.example'], window: window);
        expect(backend.domains.single, 'personal', reason: window.wire);
      }
      backend.domains.clear();
      await hinted(
          const AskHints(day: CalendarDate(2026, 10, 14), hours: dinner),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.thisWeek,
          minutes: 90);
      expect(backend.domains.single, 'unrestricted');
      backend.domains.clear();
      await hinted(const AskHints(day: fri, hours: morning),
          addresses: ['dana@fabrikam.example'],
          window: FindTimeWindow.thisWeek);
      expect(backend.domains.single, 'work');
    });

    test('the pill says their day', () {
      expect(findTimeWindowLabel(FindTimeWindow.theirs,
          const AskHints(day: fri)), 'Fri Oct 16');
      // With a weekday read, the weeks say which day of them they search.
      expect(findTimeWindowLabel(FindTimeWindow.thisWeek,
          const AskHints(day: fri)), 'This Fri');
      expect(findTimeWindowLabel(FindTimeWindow.nextWeek,
          const AskHints(day: fri)), 'Next Fri');
      expect(findTimeWindowLabel(FindTimeWindow.thisWeek,
          const AskHints(hours: dinner)), 'This week');
    });

    group('a week with a weekday read', () {
      const nextFri = CalendarDate(2026, 10, 23);
      const fridayDinner = AskHints(
          day: fri, hours: dinner, minutes: 90, timeWords: 'for dinner');

      test('Next week is next week\'s Friday evening, and Graph is asked '
          'about it alone', () async {
        final r = await hinted(fridayDinner,
            window: FindTimeWindow.nextWeek, minutes: 90);
        expect(r.slots, isNotEmpty);
        expect(r.slots.map((s) => la.dateOf(s.startUtc)).toSet(), {nextFri});
        expect(r.note, isNull);

        await hinted(fridayDinner,
            addresses: ['dana@fabrikam.example'],
            window: FindTimeWindow.nextWeek,
            minutes: 90);
        expect(backend.windows.single,
            (local(nextFri, 17, 30), local(nextFri, 20, 30)));
      });

      test('This week is this week\'s Friday', () {
        final w = findTimeWindowUtc(FindTimeWindow.thisWeek,
            now: now, zone: la, hints: fridayDinner);
        expect(w.firstDay, fri);
        expect(w.lastDay, fri);
        expect(w.startUtc, local(fri, 17, 30));
      });

      test('a Friday with nothing free offers the rest of that week, said',
          () async {
        await calendar.upsertEvents([
          CalendarEvent(
            id: 'fri-busy',
            subject: 'Northwind offsite',
            startUtc: local(nextFri, 17),
            endUtc: local(nextFri, 21),
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');
        final r = await hinted(fridayDinner,
            window: FindTimeWindow.nextWeek, minutes: 90);
        expect(r.slots, isNotEmpty);
        expect(r.note,
            'Nothing free on Friday for dinner that week — the rest of the '
            'week:');
        for (final s in r.slots) {
          final d = la.dateOf(s.startUtc);
          expect(d.isBefore(nextFri), isTrue);
          expect(d.isBefore(const CalendarDate(2026, 10, 19)), isFalse);
          expect(la.toLocal(s.startUtc).hour, greaterThanOrEqualTo(17));
        }
      });

      test('a week pill whose Friday has gone says the date it now means',
          () {
        Map<FindTimeWindow, String> labels(DateTime at) =>
            findTimeWindowLabels(fridayDinner,
                now: at, zone: la, durationMinutes: 90);
        // Wednesday: this week's Friday is ahead.
        expect(labels(now)[FindTimeWindow.thisWeek], 'This Fri');
        expect(labels(now)[FindTimeWindow.nextWeek], 'Next Fri');
        expect(labels(now)[FindTimeWindow.theirs], 'Fri Oct 16');
        // Saturday: the week's Friday has gone.
        final saturday = DateTime.utc(2026, 10, 17, 17);
        expect(labels(saturday)[FindTimeWindow.thisWeek], 'Fri Oct 23');
        expect(labels(saturday)[FindTimeWindow.nextWeek], 'Fri Oct 30');
        // Friday 9:00 PM, tonight's hours over; 3:00 PM, still tonight.
        expect(labels(DateTime.utc(2026, 10, 17, 4))[FindTimeWindow.thisWeek],
            'Fri Oct 23');
        expect(labels(DateTime.utc(2026, 10, 16, 22))[FindTimeWindow.thisWeek],
            'This Fri');
        // The rule alone: covers inside next week's nominal week keeps the
        // weekday; outside it, the date.
        expect(
            findTimeWindowLabel(FindTimeWindow.nextWeek, fridayDinner,
                covers: const CalendarDate(2026, 10, 23),
                today: const CalendarDate(2026, 10, 14)),
            'Next Fri');
        expect(
            findTimeWindowLabel(FindTimeWindow.nextWeek, fridayDinner,
                covers: const CalendarDate(2026, 10, 30),
                today: const CalendarDate(2026, 10, 14)),
            'Fri Oct 30');
      });

      test('a weekend day with nothing free falls back to nothing, and Graph '
          'is asked once', () async {
        const sun = CalendarDate(2026, 10, 18);
        const brunch = AskHours(
            startHour: 10, startMinute: 0, endHour: 13, endMinute: 0);
        await calendar.upsertEvents([
          CalendarEvent(
            id: 'sun-busy',
            subject: 'Family day',
            startUtc: local(sun, 9),
            endUtc: local(sun, 14),
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');
        backend.answer = const MeetingTimes(emptyReason: 'unknown');
        final r = await hinted(
            const AskHints(day: sun, hours: brunch, timeWords: 'for brunch'),
            addresses: ['dana@fabrikam.example'],
            window: FindTimeWindow.thisWeek,
            minutes: 60);
        expect(r.slots, isEmpty, reason: 'no Mon–Fri before the Sunday');
        expect(backend.asked, hasLength(1));
      });

      test('today\'s weekday with the days before it gone is not retried as '
          'a week', () async {
        // Friday Oct 16, 10:00 AM: the rest of the week is today alone.
        await calendar.upsertEvents([
          CalendarEvent(
            id: 'fri-busy',
            subject: 'Northwind offsite',
            startUtc: local(fri, 17),
            endUtc: local(fri, 21),
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');
        backend.answer = const MeetingTimes(emptyReason: 'unknown');
        final r = await searchFindTime(
          backend: backend,
          calendar: calendar,
          hours: null,
          addresses: const ['dana@fabrikam.example'],
          durationMinutes: 90,
          window: FindTimeWindow.thisWeek,
          now: DateTime.utc(2026, 10, 16, 17),
          zone: la,
          hints: fridayDinner,
        );
        expect(r.slots, isEmpty);
        expect(backend.asked, hasLength(1));
        expect(r.graphCalls, 1);
      });

      test('a search that could not run is not retried as a week', () async {
        backend.answer = const CalendarScopeMissing();
        final r = await hinted(fridayDinner,
            addresses: ['dana@fabrikam.example'],
            window: FindTimeWindow.nextWeek,
            minutes: 90);
        expect(backend.asked, hasLength(1));
        expect(r.failed, isTrue);
        expect(r.note, 'Calendar permission missing — reconnect in Settings.');
      });

      test('their hours already over today search nothing and ask nobody',
          () async {
        // Wednesday 1:00 PM; the ask's morning ended at noon.
        final r = await searchFindTime(
          backend: backend,
          calendar: calendar,
          hours: null,
          addresses: const ['dana@fabrikam.example'],
          durationMinutes: 30,
          window: FindTimeWindow.theirs,
          now: DateTime.utc(2026, 10, 14, 20),
          zone: la,
          hints: const AskHints(
              day: CalendarDate(2026, 10, 14), hours: morning),
        );
        expect(r.slots, isEmpty);
        expect(backend.asked, isEmpty);
      });

      test('a week without a weekday read is still the week', () {
        final w = findTimeWindowUtc(FindTimeWindow.nextWeek,
            now: now, zone: la, hints: const AskHints(hours: dinner));
        expect(w.firstDay, const CalendarDate(2026, 10, 19));
        expect(w.lastDay, nextFri);
      });
    });

    group('several days asked for', () {
      const thu = CalendarDate(2026, 10, 15);
      const tue = CalendarDate(2026, 10, 20);
      const afternoon =
          AskHours(startHour: 12, startMinute: 0, endHour: 17, endMinute: 0);
      const either = AskHints(day: thu, days: [thu, tue], hours: afternoon);

      test('their pill asks Graph about those two days alone, none between',
          () async {
        final r = await hinted(either,
            addresses: ['dana@fabrikam.example'], minutes: 30);
        expect(r.graphCalls, 2);
        expect(backend.windows, [
          (local(thu, 12), local(thu, 17)),
          (local(tue, 12), local(tue, 17)),
        ]);
        expect(backend.candidates, [5, 5]);
        // Several days are no one named day: the domain stays work.
        expect(backend.domains.toSet(), {'work'});
      });

      test('with no hours, still one call per day asked for, at the day\'s '
          'hours', () async {
        final r = await hinted(const AskHints(day: thu, days: [thu, tue]),
            addresses: ['dana@fabrikam.example']);
        expect(r.graphCalls, 2);
        expect(backend.windows, [
          (local(thu, 8), local(thu, 18)),
          (local(tue, 8), local(tue, 18)),
        ]);
      });

      test('the window spans the first to the last, and the pill names both',
          () {
        final w = findTimeWindowUtc(FindTimeWindow.theirs,
            now: now, zone: la, hints: either);
        expect(w.firstDay, thu);
        expect(w.lastDay, tue);
        expect(w.startUtc, local(thu, 12));
        expect(w.endUtc, local(tue, 17));
        expect(findTimeWindowLabel(FindTimeWindow.theirs, either),
            'Thu Oct 15 or Tue Oct 20');
      });

      test('the owner alone: each day asked for is walked and the openings '
          'merged by start', () async {
        // Thursday afternoon is busy but for its last half hour, so the
        // first three openings span both days.
        await calendar.upsertEvents([
          CalendarEvent(
            id: 'thu-busy',
            subject: 'Offsite planning',
            startUtc: local(thu, 12),
            endUtc: local(thu, 16, 30),
            showAs: 'busy',
          ),
        ], syncRun: 'run-1');
        final r = await hinted(either);
        expect(r.source, 'local');
        expect(r.slots, hasLength(3));
        expect(r.slots.first.startUtc, local(thu, 16, 30));
        expect(r.slots.map((s) => la.dateOf(s.startUtc)).toSet(), {thu, tue});
        for (var i = 1; i < r.slots.length; i++) {
          expect(r.slots[i].startUtc.isAfter(r.slots[i - 1].startUtc), isTrue);
        }
      });

      test('a weekend day named among several is asked as personal time',
          () async {
        const sun = CalendarDate(2026, 10, 18);
        await hinted(const AskHints(day: sat, days: [sat, sun], hours: morning),
            addresses: ['dana@fabrikam.example']);
        expect(backend.windows, [
          (local(sat, 9), local(sat, 12)),
          (local(sun, 9), local(sun, 12)),
        ]);
        expect(backend.domains, ['personal', 'personal']);
        // A working day among them keeps the search's own domain, and
        // dinner's unrestricted stands on a weekend day too.
        backend.windows.clear();
        backend.domains.clear();
        await hinted(const AskHints(day: thu, days: [thu, sat], hours: morning),
            addresses: ['dana@fabrikam.example']);
        expect(backend.domains, ['work', 'personal']);
        backend.domains.clear();
        await hinted(const AskHints(day: thu, days: [thu, sat], hours: dinner),
            addresses: ['dana@fabrikam.example'], minutes: 90);
        expect(backend.domains, ['unrestricted', 'unrestricted']);
      });

      test('each day named keeps its best slot before one day fills the rest',
          () async {
        // Three good slots on Tuesday outrank Thursday's one; Thursday's
        // still shows, then Tuesday's second.
        backend.answerFor = (start, end) => start == local(tue, 12)
            ? [
                MeetingTimeSuggestion(
                    startUtc: local(tue, 13),
                    endUtc: local(tue, 13, 30),
                    confidence: 100),
                MeetingTimeSuggestion(
                    startUtc: local(tue, 14),
                    endUtc: local(tue, 14, 30),
                    confidence: 90),
                MeetingTimeSuggestion(
                    startUtc: local(tue, 15),
                    endUtc: local(tue, 15, 30),
                    confidence: 80),
              ]
            : [
                MeetingTimeSuggestion(
                    startUtc: local(thu, 16),
                    endUtc: local(thu, 16, 30),
                    confidence: 50),
              ];
        final r = await hinted(either, addresses: ['dana@fabrikam.example']);
        expect(r.slots, [
          FreeSlot(local(thu, 16), local(thu, 16, 30)),
          FreeSlot(local(tue, 13), local(tue, 13, 30)),
          FreeSlot(local(tue, 14), local(tue, 14, 30)),
        ]);
      });

      test('the owner alone: each day named keeps its first opening', () async {
        // Both afternoons open: Thursday's three openings come first by
        // start, yet Tuesday's first still shows.
        final r = await hinted(either);
        expect(r.slots, hasLength(3));
        expect(r.slots.map((s) => la.dateOf(s.startUtc)).toList(),
            [thu, tue, thu]);
        expect(r.slots[0].startUtc, local(thu, 12));
        expect(r.slots[1].startUtc, local(tue, 12));
      });

      test('a week pill with several days behaves as with the first day', () {
        const first = AskHints(day: thu, hours: afternoon);
        expect(
            findTimeWindowUtc(FindTimeWindow.thisWeek,
                now: now, zone: la, hints: either),
            findTimeWindowUtc(FindTimeWindow.thisWeek,
                now: now, zone: la, hints: first));
        expect(
            findTimeWindowUtc(FindTimeWindow.nextWeek,
                now: now, zone: la, hints: either),
            findTimeWindowUtc(FindTimeWindow.nextWeek,
                now: now, zone: la, hints: first));
        expect(findTimeWindowLabel(FindTimeWindow.thisWeek, either),
            'This Thu');
      });
    });
  });
}
