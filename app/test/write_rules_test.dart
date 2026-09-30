import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/write_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  setUp(() => la = CalendarZone.tryNamed('America/Los_Angeles')!);

  const guest = Attendee(name: 'Dana Contoso', address: 'dana@contoso.com');

  // Monday Oct 5 2026, 08:00 in Los Angeles.
  final now = DateTime.utc(2026, 10, 5, 15);
  const today = CalendarDate(2026, 10, 5);

  // Wednesday Oct 7, 10:00–11:00 PDT.
  CalendarEvent meeting({
    bool isOrganizer = false,
    List<Attendee> attendees = const [guest],
    bool isCancelled = false,
    String eventType = '',
    bool? allowNewTimeProposals,
    String subject = 'Design review',
  }) =>
      CalendarEvent(
        id: 'e1',
        subject: subject,
        isOrganizer: isOrganizer,
        attendees: attendees,
        isCancelled: isCancelled,
        eventType: eventType,
        allowNewTimeProposals: allowNewTimeProposals,
        startUtc: DateTime.utc(2026, 10, 7, 17),
        endUtc: DateTime.utc(2026, 10, 7, 18),
      );

  // Thursday Oct 8 and Friday Oct 9, all day (end exclusive).
  const twoDays = CalendarEvent(
    id: 'd1',
    subject: 'Offsite',
    isAllDay: true,
    isOrganizer: true,
    startDate: CalendarDate(2026, 10, 8),
    endDate: CalendarDate(2026, 10, 10),
  );

  NewTime resolve(String text, {CalendarEvent? shown, DateTime? at}) =>
      resolveNewTime(text, shown: shown ?? meeting(), now: at ?? now, zone: la);

  group('roles', () {
    test('attendee, organiser with guests, own event', () {
      expect(eventRoleOf(meeting()), EventRole.attendee);
      expect(eventRoleOf(meeting(isOrganizer: true)),
          EventRole.organiserWithGuests);
      expect(eventRoleOf(meeting(isOrganizer: true, attendees: const [])),
          EventRole.ownEvent);
    });

    test('an attendee copy that lists nobody is still an invite to answer',
        () {
      // An organiser who hides the attendee list sends copies with no one on
      // them; Move and Delete there would act on somebody else's meeting.
      expect(eventRoleOf(meeting(attendees: const [])), EventRole.attendee);
      expect(canRespond(meeting(attendees: const [])), isTrue);
      expect(canMove(meeting(attendees: const [])), isFalse);
    });

    test('the organiser response marks the owner\'s own event', () {
      const e = CalendarEvent(id: 'p1', responseStatus: 'organizer');
      expect(eventRoleOf(e), EventRole.ownEvent);
    });

    test('a room or the organiser on the list is not a guest', () {
      final roomOnly = meeting(isOrganizer: true, attendees: const [
        Attendee(
            name: 'Room 4', address: 'room4@contoso.com', type: 'resource'),
      ]);
      expect(eventRoleOf(roomOnly), EventRole.ownEvent);
      final selfListed = CalendarEvent(
        id: 's1',
        isOrganizer: true,
        organizerAddress: 'Dana@Contoso.com',
        attendees: const [
          Attendee(name: 'Dana', address: 'dana@contoso.com', type: 'required'),
        ],
        startUtc: DateTime.utc(2026, 10, 7, 17),
        endUtc: DateTime.utc(2026, 10, 7, 18),
      );
      expect(eventRoleOf(selfListed), EventRole.ownEvent);
    });

    test('an attendee answers and proposes, never moves', () {
      final e = meeting();
      expect(canRespond(e), isTrue);
      expect(canPropose(e), isTrue);
      expect(canMove(e), isFalse);
    });

    test('an organiser moves, never answers or proposes', () {
      final e = meeting(isOrganizer: true);
      expect(canMove(e), isTrue);
      expect(canRespond(e), isFalse);
      expect(canPropose(e), isFalse);
      expect(canMove(meeting(isOrganizer: true, attendees: const [])), isTrue);
    });

    test('cancelled and series masters close the gates', () {
      expect(canRespond(meeting(isCancelled: true)), isFalse);
      expect(canPropose(meeting(isCancelled: true)), isFalse);
      expect(canMove(meeting(isOrganizer: true, isCancelled: true)), isFalse);
      expect(canMove(meeting(isOrganizer: true, eventType: 'seriesMaster')),
          isFalse);
      expect(canPropose(meeting(eventType: 'seriesMaster')), isFalse);
      // A master is still answered — that answers the series.
      expect(canRespond(meeting(eventType: 'seriesMaster')), isTrue);
    });

    test('proposals: only an explicit false forbids; never all day', () {
      expect(canPropose(meeting(allowNewTimeProposals: null)), isTrue);
      expect(canPropose(meeting(allowNewTimeProposals: true)), isTrue);
      expect(canPropose(meeting(allowNewTimeProposals: false)), isFalse);
      const allDayInvite = CalendarEvent(
        id: 'x',
        isAllDay: true,
        attendees: [guest],
        startDate: CalendarDate(2026, 10, 8),
        endDate: CalendarDate(2026, 10, 9),
      );
      expect(canPropose(allDayInvite), isFalse);
      expect(canRespond(allDayInvite), isTrue);
    });
  });

  group('resolveNewTime', () {
    test('"Thu 3pm" keeps the hour-long length', () {
      final t = resolve('Thu 3pm') as NewTimeTimed;
      expect(t.startUtc, DateTime.utc(2026, 10, 8, 22));
      expect(t.endUtc, DateTime.utc(2026, 10, 8, 23));
      expect(newTimeLabel(t, zone: la), 'Thu Oct 8 · 3:00–4:00 PM');
    });

    test('"tomorrow" keeps the wall time', () {
      final t = resolve('tomorrow') as NewTimeTimed;
      expect(t.startUtc, DateTime.utc(2026, 10, 6, 17));
      expect(t.endUtc, DateTime.utc(2026, 10, 6, 18));
    });

    test('"at 4" keeps the day', () {
      final t = resolve('at 4') as NewTimeTimed;
      expect(la.dateOf(t.startUtc), const CalendarDate(2026, 10, 7));
      expect(la.toLocal(t.startUtc).hour, 16);
      expect(t.endUtc.difference(t.startUtc), const Duration(hours: 1));
    });

    test('"2-2:30pm" takes the range', () {
      final t = resolve('2-2:30pm') as NewTimeTimed;
      expect(t.startUtc, DateTime.utc(2026, 10, 7, 21));
      expect(t.endUtc, DateTime.utc(2026, 10, 7, 21, 30));
    });

    test('a part of the day with no time is a problem, not a guess', () {
      final p = resolve('tomorrow morning') as NewTimeProblem;
      expect(p.reason, "Add a time — e.g. 'tomorrow 10am'.");
    });

    test('a passed time, the same time, a week and nothing are problems', () {
      expect((resolve('today 7am') as NewTimeProblem).reason,
          'That time has passed.');
      expect((resolve('Wed 10am') as NewTimeProblem).reason,
          "That's when it already is.");
      expect((resolve('next week') as NewTimeProblem).reason,
          'Name one day, not a week.');
      expect((resolve('soonish') as NewTimeProblem).reason,
          "Type a day or a time — e.g. 'Thu 3pm'.");
    });

    test('an all-day event moves by whole days and keeps its span', () {
      final t = resolve('Friday', shown: twoDays) as NewTimeAllDay;
      expect(t.startDate, const CalendarDate(2026, 10, 9));
      expect(t.endDate, const CalendarDate(2026, 10, 11));
      expect(newTimeLabel(t, zone: la), 'Fri Oct 9 – Sat Oct 10 · All day');
      expect(
          newTimeLabel(
              const NewTimeAllDay(
                  CalendarDate(2026, 10, 9), CalendarDate(2026, 10, 10)),
              zone: la),
          'Fri Oct 9 · All day');
    });

    test('an all-day event refuses a time', () {
      expect((resolve('Friday 3pm', shown: twoDays) as NewTimeProblem).reason,
          'Name a day — an all-day event moves by whole days.');
      expect((resolve('Thursday', shown: twoDays) as NewTimeProblem).reason,
          "That's when it already is.");
    });

    test('a move across spring-forward keeps the wall time', () {
      // Friday Mar 6 2026, 10:00 PST; the clocks change on Sunday Mar 8.
      final friday = CalendarEvent(
        id: 'f',
        isOrganizer: true,
        startUtc: DateTime.utc(2026, 3, 6, 18),
        endUtc: DateTime.utc(2026, 3, 6, 19),
      );
      final t = resolve('Monday',
          shown: friday, at: DateTime.utc(2026, 3, 5, 16)) as NewTimeTimed;
      expect(la.toLocal(t.startUtc).hour, 10);
      expect(t.startUtc, DateTime.utc(2026, 3, 9, 17));
      expect(t.endUtc, DateTime.utc(2026, 3, 9, 18));
    });
  });

  group('a move by a duration', () {
    Duration? shift(String text) => moveShiftOf(text, now: now, zone: la);

    test('a length with a direction word is a shift, earlier negative', () {
      expect(shift('by an hour'), const Duration(hours: 1));
      expect(shift(' back 30 min'), const Duration(minutes: -30));
      expect(shift('forward 15 minutes'), const Duration(minutes: 15));
      expect(shift('earlier by 30 min'), const Duration(minutes: -30));
      expect(shift('later 45 min'), const Duration(minutes: 45));
      expect(shift('an hour later'), const Duration(hours: 1));
      expect(shift('30 min earlier'), const Duration(minutes: -30));
      expect(shift('push the standup back half an hour'),
          const Duration(minutes: -30));
    });

    test('not a shift: no direction, or a day or time named', () {
      expect(shift(''), isNull);
      expect(shift('an hour'), isNull);
      expect(shift('to 4pm for an hour'), isNull);
      expect(shift('to Thursday'), isNull);
      expect(shift('back to Friday'), isNull);
    });

    test('a shift moves start and end together', () {
      final t = shiftedTime(meeting(), const Duration(minutes: -30), now: now)
          as NewTimeTimed;
      expect(t.startUtc, DateTime.utc(2026, 10, 7, 16, 30));
      expect(t.endUtc, DateTime.utc(2026, 10, 7, 17, 30));
      expect(
          (shiftedTime(twoDays, const Duration(hours: 1), now: now)
                  as NewTimeProblem)
              .reason,
          contains('whole days'));
      expect(
          (shiftedTime(meeting(), const Duration(days: -3), now: now)
                  as NewTimeProblem)
              .reason,
          'That time has passed.');
    });

    test('a bare hour after "to" is caught; a marked one is not', () {
      expect(bareHourAfterTo(' to 4'), isTrue);
      expect(bareHourAfterTo('to 11 '), isTrue);
      expect(bareHourAfterTo('to 4pm'), isFalse);
      expect(bareHourAfterTo('to 4 pm'), isFalse);
      expect(bareHourAfterTo('to 4:30'), isFalse);
      expect(bareHourAfterTo('to 16'), isFalse);
      expect(bareHourAfterTo('to 4 hours'), isFalse);
      expect(bareHourAfterTo('to Thursday'), isFalse);
    });
  });

  group('checkDrop', () {
    // The meeting is Wed Oct 7 17:00–18:00Z; now is Mon Oct 5 15:00Z.
    String? refusal(DateTime start, DateTime end) => switch (
          checkDrop(shown: meeting(), startUtc: start, endUtc: end, now: now)) {
        NewTimeProblem(:final reason) => reason,
        _ => null,
      };

    test('a drop where it already is is refused', () {
      expect(refusal(DateTime.utc(2026, 10, 7, 17), DateTime.utc(2026, 10, 7, 18)),
          "That's when it already is.");
    });

    test('a drop into the past is refused', () {
      expect(refusal(DateTime.utc(2026, 10, 5, 14), DateTime.utc(2026, 10, 5, 15)),
          'That time has passed.');
    });

    test('a drop that ends before it starts is refused', () {
      expect(refusal(DateTime.utc(2026, 10, 7, 19), DateTime.utc(2026, 10, 7, 19)),
          'A meeting needs to end after it starts.');
    });

    test('any other drop is the new time, in UTC', () {
      final t = checkDrop(
        shown: meeting(),
        startUtc: la.localDateTime(const CalendarDate(2026, 10, 7), 11, 0),
        endUtc: la.localDateTime(const CalendarDate(2026, 10, 7), 12, 0),
        now: now,
      ) as NewTimeTimed;
      expect(t.startUtc, DateTime.utc(2026, 10, 7, 18));
      expect(t.endUtc, DateTime.utc(2026, 10, 7, 19));
      expect(t.startUtc.isUtc, isTrue);
    });
  });

  group('sentences', () {
    test('RSVP summaries: one meeting, a series, a proposal, a note', () {
      final shown = meeting();
      expect(
          writeSummary(const RespondToEvent('e1', RsvpResponse.accept),
              shown: shown, series: false, zone: la, today: today),
          'Accept "Design review" · Wednesday, Oct 7 · 10:00–11:00 AM');
      expect(
          writeSummary(const RespondToEvent('m', RsvpResponse.tentative),
              shown: shown, series: true, zone: la, today: today),
          'Maybe every meeting in "Design review"');
      expect(
          writeSummary(
              RespondToEvent('e1', RsvpResponse.decline,
                  comment: 'Clash',
                  proposeStartUtc: DateTime.utc(2026, 10, 8, 22),
                  proposeEndUtc: DateTime.utc(2026, 10, 8, 23)),
              shown: shown,
              series: false,
              zone: la,
              today: today),
          'Decline "Design review" · Wednesday, Oct 7 · 10:00–11:00 AM, '
          'proposing Thu Oct 8 · 3:00–4:00 PM with your note');
    });

    test('move, cancel, delete and create summaries', () {
      final shown = meeting(isOrganizer: true, subject: '  ');
      expect(
          writeSummary(
              MoveEvent.timed('e1',
                  startUtc: DateTime.utc(2026, 10, 8, 22),
                  endUtc: DateTime.utc(2026, 10, 8, 23)),
              shown: shown,
              series: false,
              zone: la,
              today: today),
          'Move "(no subject)" to Thu Oct 8 · 3:00–4:00 PM');
      expect(
          writeSummary(const CancelMeeting('m'),
              shown: meeting(), series: true, zone: la, today: today),
          'Cancel every meeting in "Design review"');
      expect(
          writeSummary(const DeleteEvent('d1'),
              shown: twoDays, series: false, zone: la, today: today),
          'Delete "Offsite" · All day · Thu Oct 8 – Fri Oct 9');
      expect(
          writeSummary(
              CreateEvent(
                  subject: 'Focus',
                  startUtc: DateTime.utc(2026, 10, 8, 22),
                  endUtc: DateTime.utc(2026, 10, 8, 23),
                  transactionId: 'x'),
              shown: meeting(),
              series: false,
              zone: la,
              today: today),
          'Create "Focus" · Thu Oct 8 · 3:00–4:00 PM');
    });

    test('done messages', () {
      final shown = meeting();
      String done(CalendarWrite w) =>
          writeDoneMessage(w, shown: shown, series: false, zone: la);
      expect(done(const RespondToEvent('e1', RsvpResponse.accept)),
          'Accepted "Design review".');
      expect(done(const RespondToEvent('e1', RsvpResponse.tentative)),
          'Said maybe to "Design review".');
      expect(done(const RespondToEvent('e1', RsvpResponse.decline)),
          'Declined "Design review".');
      expect(
          done(RespondToEvent('e1', RsvpResponse.tentative,
              proposeStartUtc: DateTime.utc(2026, 10, 8, 22),
              proposeEndUtc: DateTime.utc(2026, 10, 8, 23))),
          'Proposed a new time for "Design review".');
      expect(
          done(MoveEvent.timed('e1',
              startUtc: DateTime.utc(2026, 10, 8, 22),
              endUtc: DateTime.utc(2026, 10, 8, 23))),
          'Moved "Design review" to Thu Oct 8 · 3:00–4:00 PM.');
      expect(done(const CancelMeeting('e1')), 'Cancelled "Design review".');
      expect(done(const DeleteEvent('e1')), 'Deleted "Design review".');
    });

    test('a series-wide answer, cancel or delete says every meeting; a '
        'proposal and a move never do', () {
      final shown = meeting();
      String done(CalendarWrite w) =>
          writeDoneMessage(w, shown: shown, series: true, zone: la);
      expect(done(const RespondToEvent('m', RsvpResponse.accept)),
          'Accepted every meeting in "Design review".');
      expect(done(const RespondToEvent('m', RsvpResponse.tentative)),
          'Said maybe to every meeting in "Design review".');
      expect(done(const RespondToEvent('m', RsvpResponse.decline)),
          'Declined every meeting in "Design review".');
      expect(done(const CancelMeeting('m')),
          'Cancelled every meeting in "Design review".');
      expect(done(const DeleteEvent('m')),
          'Deleted every meeting in "Design review".');
      expect(
          done(RespondToEvent('e1', RsvpResponse.tentative,
              proposeStartUtc: DateTime.utc(2026, 10, 8, 22),
              proposeEndUtc: DateTime.utc(2026, 10, 8, 23))),
          'Proposed a new time for "Design review".');
      expect(
          done(MoveEvent.timed('e1',
              startUtc: DateTime.utc(2026, 10, 8, 22),
              endUtc: DateTime.utc(2026, 10, 8, 23))),
          'Moved "Design review" to Thu Oct 8 · 3:00–4:00 PM.');
    });

    test('who is emailed', () {
      expect(emailedLine(const []), isNull);
      expect(emailedLine(const ['dana@contoso.com']),
          'This emails: dana@contoso.com');
      final six = [for (var i = 1; i <= 6; i++) 'p$i@fabrikam.com'];
      expect(
          emailedLine(six),
          'This emails: p1@fabrikam.com, p2@fabrikam.com, p3@fabrikam.com, '
          'p4@fabrikam.com, p5@fabrikam.com and 1 more');
      expect(emailedSuffix(const []), '');
      expect(emailedSuffix(const ['dana@contoso.com']),
          ' Emailed dana@contoso.com.');
      expect(emailedSuffix(six), ' Emailed 6 people.');
    });

    test('button labels', () {
      expect(confirmLabelFor(const DeleteEvent('x')), 'Delete');
      expect(confirmLabelFor(const CancelMeeting('x')), 'Cancel meeting');
      expect(confirmLabelFor(const RespondToEvent('x', RsvpResponse.accept)),
          'Send');
      expect(dismissLabelFor(const DeleteEvent('x')), 'Keep it');
      expect(dismissLabelFor(const CancelMeeting('x')), 'Keep it');
      expect(dismissLabelFor(const RespondToEvent('x', RsvpResponse.accept)),
          'Cancel');
    });
  });
}
