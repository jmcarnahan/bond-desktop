import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/command/event_matcher.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which meeting a command means, scored against the mirror. `now` is FIXED:
/// Wednesday 2026-10-14 10:42 in Los Angeles. Fictional meetings.
void main() {
  late CalendarZone la;
  late DateTime now;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
  });

  const today = CalendarDate(2026, 10, 14);
  const dana = KnownPerson(name: 'Dana Whitfield', address: 'dana@contoso.com');

  DateTime at(CalendarDate d, int h, [int m = 0]) {
    final t = la.localDateTime(d, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  CalendarEvent meeting(
    String id,
    CalendarDate d,
    int h, {
    String subject = 'Sync',
    List<String> with_ = const [],
    String eventType = '',
    bool cancelled = false,
  }) =>
      CalendarEvent(
        id: id,
        subject: subject,
        eventType: eventType,
        isCancelled: cancelled,
        startUtc: at(d, h),
        endUtc: at(d, h, 30),
        attendees: [for (final a in with_) Attendee(name: a, address: a)],
      );

  WhenResolution when(String text) =>
      resolveWhen(text, now: now, zone: la, mode: WhenMode.booking);

  List<EventCandidate> match(
    List<CalendarEvent> events, {
    String text = '',
    String subject = '',
    List<KnownPerson> people = const [],
  }) =>
      matchEvents(
        subjectWords: subject,
        when: when(text),
        people: PeopleMatch(matched: people),
        events: events,
        zone: la,
        now: now,
      );

  test('a named time picks the meeting that starts then', () {
    final c = match([
      meeting('a', today, 14),
      meeting('b', today, 15),
    ], text: 'my 3pm');
    // Today's 3pm: the time (3) and "today" for a time with no day (1).
    expect(c.first.event.id, 'b');
    expect(c.first.score, 4);
    expect(topCandidates(c), hasLength(1));
  });

  test("a time with no day prefers today's over a later day's", () {
    final c = match([
      meeting('thu', today.addDays(1), 15),
      meeting('wed', today, 15),
    ], text: 'my 3pm');
    expect(c.map((x) => x.event.id), ['wed', 'thu']);
  });

  test('a named day scores, and searches the whole day', () {
    final c = match([
      meeting('morning', today.addDays(1), 9),
      meeting('dinner', today.addDays(1), 19),
      meeting('other', today.addDays(2), 9, subject: 'Standup'),
    ], text: 'tomorrow', subject: 'standup');
    expect(c.map((x) => x.event.id), ['morning', 'dinner']);
    expect(c.first.score, 2);
  });

  test('a named person on the attendee list or organising scores 2 each', () {
    final c = match([
      meeting('with', today.addDays(3), 10, with_: ['dana@contoso.com']),
      CalendarEvent(
        id: 'org',
        subject: 'Planning',
        organizerAddress: 'Dana@contoso.com',
        startUtc: at(today.addDays(4), 10),
        endUtc: at(today.addDays(4), 11),
      ),
      meeting('none', today.addDays(3), 11),
    ], people: [dana]);
    expect(c.map((x) => x.event.id), ['with', 'org']);
    expect(c.every((x) => x.score == 2), isTrue);
    // A tie at the top: both come back, and the planner asks.
    expect(topCandidates(c), hasLength(2));
  });

  test('subject words overlap, "1:1" in any spelling', () {
    final c = match([
      meeting('design', today.addDays(2), 10, subject: 'Design sync'),
      meeting('oneonone', today.addDays(2), 11, subject: 'Dana / Lee 1:1'),
      meeting('budget', today.addDays(2), 12, subject: 'Budget review'),
    ], subject: 'design sync');
    expect(c.single.event.id, 'design');
    expect(c.single.score, 2);
    expect(
        match([meeting('o', today.addDays(2), 11, subject: 'Dana / Lee 1:1')],
                subject: 'one-on-one')
            .single
            .score,
        1);
  });

  test('with no day, the next fourteen days from now only', () {
    final c = match([
      meeting('past', today, 9, subject: 'Design sync'),
      meeting('soon', today.addDays(3), 9, subject: 'Design sync'),
      meeting('late', today.addDays(20), 9, subject: 'Design sync'),
    ], subject: 'design');
    expect(c.map((x) => x.event.id), ['soon']);
  });

  test('series masters and cancelled meetings are never candidates', () {
    final c = match([
      meeting('master', today.addDays(1), 9,
          subject: 'Standup', eventType: 'seriesMaster'),
      meeting('gone', today.addDays(1), 9,
          subject: 'Standup', cancelled: true),
      meeting('occ', today.addDays(1), 9,
          subject: 'Standup', eventType: 'occurrence'),
    ], subject: 'standup');
    expect(c.map((x) => x.event.id), ['occ']);
  });

  test('a named time is a filter: a meeting at another time is never a '
      'candidate, however well the rest matches', () {
    // 10:42 on a Wednesday, and today's only meeting is at 4 PM: "my 3pm"
    // must not fall back to it on the strength of being today's.
    expect(
        match([meeting('vendor', today, 16, subject: 'Vendor call')],
            text: 'my 3pm'),
        isEmpty);
    // Dana's Thursday 10 AM scores 2 for Dana, but "my 3pm" rules it out.
    expect(
        match([
          meeting('thu', today.addDays(1), 10, with_: ['dana@contoso.com']),
        ], text: 'my 3pm', people: [dana]),
        isEmpty);
    // An all-day event starts at no time.
    const allDay = CalendarEvent(
      id: 'o',
      subject: 'Offsite',
      isAllDay: true,
      startDate: CalendarDate(2026, 10, 14),
      endDate: CalendarDate(2026, 10, 15),
    );
    expect(match([allDay], text: 'my 3pm', subject: 'offsite'), isEmpty);
  });

  test('nothing scored is no candidate', () {
    expect(match([meeting('a', today.addDays(1), 9)], subject: 'budget'),
        isEmpty);
  });

  test('the choice label spells out the date', () {
    final e = meeting('x', today.addDays(1), 15, subject: 'Design sync');
    expect(eventChoiceLabel(e, la, today),
        'Design sync · Thu Oct 15 · 3:00–3:30 PM');
    const allDay = CalendarEvent(
      id: 'o',
      subject: 'Offsite',
      isAllDay: true,
      startDate: CalendarDate(2026, 10, 16),
      endDate: CalendarDate(2026, 10, 17),
    );
    expect(eventChoiceLabel(allDay, la, today), 'Offsite · Fri Oct 16 · All day');
  });
}
