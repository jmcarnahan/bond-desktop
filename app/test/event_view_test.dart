import 'dart:convert';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/event_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  setUp(() => la = CalendarZone.tryNamed('America/Los_Angeles')!);

  // Tuesday, Sep 29 2026 in Los Angeles (PDT, UTC-7).
  const today = CalendarDate(2026, 9, 29);

  DateTime at(CalendarDate d, int h, [int m = 0]) =>
      la.localDateTime(d, h, m).toUtc();

  CalendarEvent timed(
    String id, {
    required DateTime start,
    Duration length = const Duration(minutes: 30),
    String subject = 'Design review',
    String eventType = 'singleInstance',
    String seriesMasterId = '',
    bool isCancelled = false,
  }) =>
      CalendarEvent(
        id: id,
        subject: subject,
        eventType: eventType,
        seriesMasterId: seriesMasterId,
        startUtc: start,
        endUtc: start.add(length),
        isCancelled: isCancelled,
      );

  Attendee person(
    String name,
    String response, {
    String? address,
    String type = 'required',
  }) =>
      Attendee(
        name: name,
        address: address ??
            '${name.toLowerCase().replaceAll(' ', '.')}@contoso.com',
        type: type,
        response: response,
      );

  // The organiser's copy by default: the one whose responses Exchange keeps.
  CalendarEvent withPeople(List<Attendee> people,
          {String organizer = 'dana.ortiz@contoso.com', bool mine = true}) =>
      CalendarEvent(
        id: 'e',
        organizerAddress: organizer,
        isOrganizer: mine,
        attendees: people,
      );

  group('attendeeTally', () {
    test('mixed answers, one decliner named', () {
      final e = withPeople([
        person('Ana Ruiz', 'accepted'),
        person('Bo Kim', 'accepted'),
        person('Cy Park', 'accepted'),
        person('Di Wu', 'accepted'),
        person('Sam Lee', 'declined'),
        person('Eve Hall', 'none'),
      ]);
      expect(attendeeTally(e), '4 of 6 accepted · Sam declined · 1 no reply');
    });

    test('everyone accepted', () {
      final e = withPeople([
        person('Ana Ruiz', 'accepted'),
        person('Bo Kim', 'accepted'),
        person('Cy Park', 'accepted'),
      ]);
      expect(attendeeTally(e), 'All 3 accepted');
    });

    test('a single invitee who accepted', () {
      expect(attendeeTally(withPeople([person('Ana Ruiz', 'accepted')])),
          'Accepted');
    });

    test('nobody answered', () {
      final e = withPeople([
        person('Ana Ruiz', 'none'),
        person('Bo Kim', 'notResponded'),
      ]);
      expect(attendeeTally(e), '2 no reply');
    });

    test('maybes and several decliners, no acceptances', () {
      final e = withPeople([
        person('Ana Ruiz', 'declined'),
        person('Bo Kim', 'declined'),
        person('Cy Park', 'tentativelyAccepted'),
      ]);
      expect(attendeeTally(e), '1 maybe · 2 declined');
    });

    test('rooms and the organiser are not counted', () {
      final e = withPeople([
        person('Dana Ortiz', 'organizer', address: 'DANA.ORTIZ@contoso.com'),
        person('Room 4', 'accepted', type: 'resource'),
        person('Ana Ruiz', 'accepted'),
        person('Bo Kim', 'none'),
      ]);
      expect(attendeeTally(e), '1 of 2 accepted · 1 no reply');
    });

    test('a decliner with no name is named by address', () {
      final e = withPeople([
        person('', 'declined', address: 'sam@fabrikam.com'),
        person('Ana Ruiz', 'accepted'),
      ]);
      expect(attendeeTally(e), '1 of 2 accepted · sam declined');
    });

    test('a response of organizer is never counted, whatever its address',
        () {
      final e = withPeople([
        person('Dana Ortiz', 'organizer', address: 'dana@fabrikam.com'),
        person('Ana Ruiz', 'accepted'),
      ]);
      expect(attendeeTally(e), 'Accepted');
    });

    test("an attendee's copy counts only definite answers", () {
      // Exchange reports `none` for everyone on an attendee's copy, so a
      // "no reply" bucket there would be a guess.
      final e = withPeople(mine: false, [
        person('Ana Ruiz', 'accepted'),
        person('Bo Kim', 'accepted'),
        person('Eve Hall', 'none'),
        person('Sam Lee', 'declined'),
      ]);
      expect(attendeeTally(e), '2 accepted · Sam declined');
    });

    test("an attendee's copy with no definite answer says nothing", () {
      final e = withPeople(mine: false, [
        person('Ana Ruiz', 'none'),
        person('Bo Kim', 'none'),
        person('Cy Park', 'notResponded'),
      ]);
      expect(attendeeTally(e), isNull);
    });

    test("an attendee's copy skips the organizer response and counts maybes",
        () {
      final e = withPeople(mine: false, [
        person('Dana Ortiz', 'organizer', address: 'dana@fabrikam.com'),
        person('Ana Ruiz', 'tentativelyAccepted'),
        person('Bo Kim', 'declined'),
        person('Cy Park', 'declined'),
      ]);
      expect(attendeeTally(e), '1 maybe · 2 declined');
      expect(
        attendeeTally(withPeople(mine: false, [
          person('Dana Ortiz', 'organizer', address: 'dana@fabrikam.com'),
        ])),
        isNull,
      );
    });

    test('no attendees, or only a room, is null', () {
      expect(attendeeTally(withPeople(const [])), isNull);
      expect(
        attendeeTally(
            withPeople([person('Room 4', 'accepted', type: 'resource')])),
        isNull,
      );
    });
  });

  group('responseLine', () {
    CalendarEvent answered(String status,
            {bool organiser = false, bool? requested, bool cancelled = false}) =>
        CalendarEvent(
          id: 'e',
          responseStatus: status,
          isOrganizer: organiser,
          responseRequested: requested,
          isCancelled: cancelled,
        );

    test('each standing', () {
      expect(responseLine(answered('accepted')), 'You accepted');
      expect(responseLine(answered('tentativelyAccepted')), 'You said maybe');
      expect(responseLine(answered('declined')), 'You declined');
      expect(responseLine(answered('none')), "You haven't answered");
      expect(responseLine(answered('notResponded')), "You haven't answered");
      expect(responseLine(answered('organizer')), 'You organised this');
      expect(responseLine(answered('none', organiser: true)),
          'You organised this');
    });

    test('no answer asked for', () {
      expect(responseLine(answered('none', requested: false)),
          'No answer needed');
    });

    test('cancelled wins over everything', () {
      expect(responseLine(answered('accepted', cancelled: true)), 'Cancelled');
      expect(responseLine(answered('none', organiser: true, cancelled: true)),
          'Cancelled');
    });
  });

  group('eventWhenLine', () {
    test('timed today, tomorrow and later', () {
      expect(
        eventWhenLine(timed('a', start: at(today, 10)), zone: la, today: today),
        'Today · Tuesday, Sep 29 · 10:00–10:30 AM',
      );
      expect(
        eventWhenLine(timed('b', start: at(today.addDays(1), 10)),
            zone: la, today: today),
        'Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM',
      );
      expect(
        eventWhenLine(timed('c', start: at(today.addDays(3), 10)),
            zone: la, today: today),
        'Friday, Oct 2 · 10:00–10:30 AM',
      );
    });

    test('a meeting on the day the clocks go back reads its wall time', () {
      // Sunday, Nov 1 2026: PDT ends at 2 AM, so 10 AM is UTC-8.
      const fallBack = CalendarDate(2026, 11, 1);
      final start = at(fallBack, 10);
      expect(start, DateTime.utc(2026, 11, 1, 18));
      expect(
        eventWhenLine(timed('d', start: start), zone: la, today: today),
        'Sunday, Nov 1 · 10:00–10:30 AM',
      );
    });

    test('all day, one day and several', () {
      const oct1 = CalendarDate(2026, 10, 1);
      expect(
        eventWhenLine(
          const CalendarEvent(
            id: 'x',
            isAllDay: true,
            startDate: oct1,
            endDate: CalendarDate(2026, 10, 2),
          ),
          zone: la,
          today: today,
        ),
        'All day · Thursday, Oct 1',
      );
      expect(
        eventWhenLine(
          const CalendarEvent(
            id: 'y',
            isAllDay: true,
            startDate: oct1,
            endDate: CalendarDate(2026, 10, 4),
          ),
          zone: la,
          today: today,
        ),
        'All day · Thu Oct 1 – Sat Oct 3',
      );
    });

    test('a date outside this year carries its year', () {
      const mar3 = CalendarDate(2025, 3, 3);
      expect(
        eventWhenLine(timed('p', start: at(mar3, 10)), zone: la, today: today),
        'Monday, Mar 3, 2025 · 10:00–10:30 AM',
      );
      expect(
        eventWhenLine(
          const CalendarEvent(
            id: 'q',
            isAllDay: true,
            startDate: mar3,
            endDate: CalendarDate(2025, 3, 4),
          ),
          zone: la,
          today: today,
        ),
        'All day · Monday, Mar 3, 2025',
      );
      expect(
        eventWhenLine(
          const CalendarEvent(
            id: 'r',
            isAllDay: true,
            startDate: mar3,
            endDate: CalendarDate(2025, 3, 6),
          ),
          zone: la,
          today: today,
        ),
        'All day · Mon Mar 3 – Wed Mar 5, 2025',
      );
      // A span across New Year names both years.
      expect(
        eventWhenLine(
          const CalendarEvent(
            id: 's',
            isAllDay: true,
            startDate: CalendarDate(2026, 12, 30),
            endDate: CalendarDate(2027, 1, 3),
          ),
          zone: la,
          today: today,
        ),
        'All day · Wed Dec 30, 2026 – Sat Jan 2, 2027',
      );
      // This year's dates stay as they were.
      expect(
        eventWhenLine(timed('t', start: at(const CalendarDate(2026, 3, 3), 10)),
            zone: la, today: today),
        'Tuesday, Mar 3 · 10:00–10:30 AM',
      );
    });

    test('missing times are an empty line', () {
      expect(eventWhenLine(const CalendarEvent(id: 'z'), zone: la, today: today),
          '');
    });
  });

  group('displayOccurrence', () {
    // Getters, not finals: the zone is only there once setUp has run.
    DateTime nowUtc() => at(today, 12);
    CalendarEvent master0() => timed(
          'm',
          start: at(today.addDays(-60), 9),
          eventType: 'seriesMaster',
        );
    CalendarEvent occ(String id, CalendarDate d, {bool cancelled = false}) =>
        timed(id,
            start: at(d, 9),
            eventType: 'occurrence',
            seriesMasterId: 'm',
            isCancelled: cancelled);

    test('a master shows its first occurrence still ahead, skipping cancelled',
        () {
      final list = [
        occ('past', today.addDays(-7)),
        occ('cancelled', today.addDays(1), cancelled: true),
        occ('next', today.addDays(2)),
        occ('after', today.addDays(9)),
      ];
      expect(displayOccurrence(master0(), list, nowUtc(), la).id, 'next');
    });

    test('one in progress counts as ahead', () {
      final running = timed('running',
          start: at(today, 11, 45),
          eventType: 'occurrence',
          seriesMasterId: 'm');
      expect(
        displayOccurrence(master0(), [running], nowUtc(), la).id,
        'running',
      );
    });

    test('all past shows the last one', () {
      final list = [occ('a', today.addDays(-14)), occ('b', today.addDays(-7))];
      expect(displayOccurrence(master0(), list, nowUtc(), la).id, 'b');
    });

    test('a master with no occurrences, and a plain event, are themselves', () {
      expect(displayOccurrence(master0(), const [], nowUtc(), la).id, 'm');
      final single = timed('s', start: at(today, 9));
      expect(
        displayOccurrence(
          single,
          [occ('a', today.addDays(1))],
          nowUtc(),
          la,
        ).id,
        's',
      );
    });
  });

  group('nextMeetingLabel', () {
    test('today, tomorrow, later, and no subject', () {
      expect(
        nextMeetingLabel(timed('a', start: at(today, 10)),
            zone: la, today: today),
        'Next meeting: Design review · Today 10:00 AM',
      );
      expect(
        nextMeetingLabel(timed('b', start: at(today.addDays(1), 10)),
            zone: la, today: today),
        'Next meeting: Design review · Tomorrow 10:00 AM',
      );
      expect(
        nextMeetingLabel(timed('c', start: at(today.addDays(3), 10)),
            zone: la, today: today),
        'Next meeting: Design review · Fri Oct 2, 10:00 AM',
      );
      expect(
        nextMeetingLabel(timed('d', start: at(today, 10), subject: '  '),
            zone: la, today: today),
        'Next meeting: (no subject) · Today 10:00 AM',
      );
    });
  });

  group('lastMetLabel', () {
    test('today and yesterday', () {
      expect(
        lastMetLabel(timed('a', start: at(today, 8)), zone: la, today: today),
        'Last met today',
      );
      expect(
        lastMetLabel(timed('b', start: at(today.addDays(-1), 16)),
            zone: la, today: today),
        'Last met yesterday',
      );
    });

    test('counted in zone dates across the clocks going back', () {
      // Saturday Oct 24, 11:30 PM PDT is already Oct 25 in UTC; the count is
      // from the LOCAL date, across the Nov 1 change, to Thursday Nov 5.
      const nov5 = CalendarDate(2026, 11, 5);
      final late = timed('c', start: at(const CalendarDate(2026, 10, 24), 23, 30));
      expect(late.startUtc!.day, 25);
      expect(lastMetLabel(late, zone: la, today: nov5), 'Last met 12 days ago');
    });
  });

  group('showsMeetingCard', () {
    Message msg({String? meeting, String? eventId}) => Message(
          id: 'm1',
          outbound: false,
          sourceMetaJson: jsonEncode({
            'meeting': ?meeting,
            'event_id': ?eventId,
          }),
        );

    test('invites and cancellations that name an event', () {
      expect(showsMeetingCard(msg(meeting: 'meetingRequest', eventId: 'e1')),
          isTrue);
      expect(showsMeetingCard(msg(meeting: 'meetingCancelled', eventId: 'e1')),
          isTrue);
      expect(showsMeetingCard(msg(meeting: 'MEETINGREQUEST', eventId: 'e1')),
          isTrue);
    });

    test('responses, a missing id and plain mail do not', () {
      expect(showsMeetingCard(msg(meeting: 'meetingAccepted', eventId: 'e1')),
          isFalse);
      expect(showsMeetingCard(msg(meeting: 'meetingRequest')), isFalse);
      expect(showsMeetingCard(msg(meeting: 'meetingRequest', eventId: '')),
          isFalse);
      expect(showsMeetingCard(msg(eventId: 'e1')), isFalse);
      expect(
        showsMeetingCard(const Message(id: 'm2', outbound: false)),
        isFalse,
      );
    });

    test('isCancellationCard reads the cancelled kind only', () {
      expect(isCancellationCard(msg(meeting: 'meetingCancelled', eventId: 'e')),
          isTrue);
      expect(isCancellationCard(msg(meeting: 'meetingRequest', eventId: 'e')),
          isFalse);
    });
  });
}
