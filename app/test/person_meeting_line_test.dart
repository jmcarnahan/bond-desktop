import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/event_view.dart';
import 'package:bond_inbox/widgets/person_meeting_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line at the top of a person's room: the next meeting and the last,
/// each a way into that meeting.
void main() {
  setUpAll(initCalendarZones);

  const today = CalendarDate(2026, 9, 29);

  CalendarEvent meeting(String id, String subject, DateTime start) =>
      CalendarEvent(
        id: id,
        subject: subject,
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
      );

  Future<List<String>> pumpLine(
      WidgetTester tester, PersonMeetings meetings) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PersonMeetingLine(
          meetings: meetings,
          zone: CalendarZone.tryNamed('America/Los_Angeles')!,
          today: today,
          onOpenEvent: opened.add,
        ),
      ),
    ));
    await tester.pump();
    return opened;
  }

  testWidgets('next and last, each opening its meeting', (tester) async {
    final opened = await pumpLine(
      tester,
      PersonMeetings(
        // Wednesday 10:00 AM PDT.
        next: meeting('n', 'Design review', DateTime.utc(2026, 9, 30, 17)),
        // Thursday Sep 17, 12 days back.
        last: meeting('l', 'Kickoff', DateTime.utc(2026, 9, 17, 17)),
      ),
    );
    expect(find.text('Next meeting: Design review · Tomorrow 10:00 AM'),
        findsOneWidget);
    expect(find.text('Last met 12 days ago'), findsOneWidget);
    expect(find.text(' · '), findsOneWidget);

    await tester.tap(find.byKey(PersonMeetingLine.lastKey));
    await tester.pump();
    await tester.tap(find.byKey(PersonMeetingLine.nextKey));
    await tester.pump();
    expect(opened, ['l', 'n']);
  });

  testWidgets('only one of the two, with no separator', (tester) async {
    await pumpLine(
      tester,
      PersonMeetings(
        last: meeting('l', 'Kickoff', DateTime.utc(2026, 9, 28, 17)),
      ),
    );
    expect(find.text('Last met yesterday'), findsOneWidget);
    expect(find.byKey(PersonMeetingLine.nextKey), findsNothing);
    expect(find.text(' · '), findsNothing);
  });

  testWidgets('nothing to say draws nothing', (tester) async {
    await pumpLine(tester, const PersonMeetings());
    expect(find.byType(Text), findsNothing);
  });
}
