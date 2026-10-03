import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/event_view.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/widgets/meeting_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card under an invite, prop-only: a pinned clock and a named zone.
/// Bare pumps only — the Join row holds a periodic timer.
void main() {
  setUpAll(initCalendarZones);

  // Tuesday Sep 29 2026, 9:00 AM in Los Angeles.
  final now = DateTime.utc(2026, 9, 29, 16);
  const today = CalendarDate(2026, 9, 29);
  const join = 'https://teams.example.com/l/meetup-join/fictional';

  CalendarEvent meeting({
    String id = 'e1',
    DateTime? start,
    String joinUrl = join,
    bool isCancelled = false,
    String eventType = 'singleInstance',
    String seriesMasterId = '',
  }) {
    final s = start ?? DateTime.utc(2026, 9, 30, 17);
    return CalendarEvent(
      id: id,
      subject: 'Design review',
      eventType: eventType,
      seriesMasterId: seriesMasterId,
      startUtc: s,
      endUtc: s.add(const Duration(minutes: 30)),
      joinUrl: joinUrl,
      isCancelled: isCancelled,
      organizerAddress: 'dana.ortiz@contoso.com',
      // The organiser's copy, the one whose tally counts no-replies.
      isOrganizer: true,
      attendees: const [
        Attendee(name: 'Sam Lee', address: 'sam@contoso.com',
            response: 'accepted'),
        Attendee(name: 'Ana Ruiz', address: 'ana@contoso.com'),
      ],
    );
  }

  Future<void> pumpCard(
    WidgetTester tester,
    EventLookup lookup, {
    bool cancellation = false,
    DateTime? at,
    Overlaps? overlaps,
    void Function(String)? onOpenEvent,
    void Function(String)? onOpenLink,
    Widget? actions,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: MeetingCard(
            cancellation: cancellation,
            lookup: lookup,
            zone: CalendarZone.tryNamed('America/Los_Angeles')!,
            now: at ?? now,
            today: today,
            overlaps: overlaps,
            onOpenEvent: onOpenEvent ?? (_) {},
            onOpenLink: onOpenLink ?? (_) {},
            actions: actions,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an invite: when, overlap, tally, Join and Open event',
      (tester) async {
    final opened = <String>[];
    final links = <String>[];
    await pumpCard(
      tester,
      EventLookup.found(meeting()),
      overlaps: Overlaps(soft: [
        CalendarEvent(
          id: 'x',
          subject: '1:1 with Sam',
          startUtc: DateTime.utc(2026, 9, 30, 17),
          endUtc: DateTime.utc(2026, 9, 30, 18),
        ),
      ]),
      onOpenEvent: opened.add,
      onOpenLink: links.add,
    );
    expect(find.text('Design review'), findsOneWidget);
    expect(find.text('Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM'),
        findsOneWidget);
    expect(find.text('⚠ overlaps 1:1 with Sam'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(MeetingCard.tallyKey)).data,
        '1 of 2 accepted · 1 no reply');

    await tester.tap(find.byKey(MeetingCard.joinKey));
    await tester.pump();
    expect(links, [join]);
    await tester.tap(find.byKey(MeetingCard.openEventKey));
    await tester.pump();
    expect(opened, ['e1']);
  });

  testWidgets('no link or a past meeting: no Join, still Open event',
      (tester) async {
    await pumpCard(tester, EventLookup.found(meeting(joinUrl: '')));
    expect(find.byKey(MeetingCard.joinKey), findsNothing);
    expect(find.byKey(MeetingCard.openEventKey), findsOneWidget);

    await pumpCard(tester, EventLookup.found(meeting(
      start: DateTime.utc(2026, 9, 28, 17),
    )));
    expect(find.byKey(MeetingCard.joinKey), findsNothing);
  });

  testWidgets('a series opens its MASTER, and shows the next occurrence',
      (tester) async {
    final opened = <String>[];
    final master = meeting(
      id: 'm',
      eventType: 'seriesMaster',
      start: DateTime.utc(2026, 7, 7, 17),
    );
    await pumpCard(
      tester,
      EventLookup.found(master, occurrences: [
        meeting(
          id: 'o-next',
          eventType: 'occurrence',
          seriesMasterId: 'm',
          start: DateTime.utc(2026, 9, 30, 17),
        ),
      ]),
      onOpenEvent: opened.add,
    );
    expect(find.text('Design review · series'), findsOneWidget);
    expect(find.text('Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM'),
        findsOneWidget);
    await tester.tap(find.byKey(MeetingCard.openEventKey));
    await tester.pump();
    expect(opened, ['m']);
  });

  testWidgets('a cancellation message is one line', (tester) async {
    await pumpCard(tester, EventLookup.found(meeting()), cancellation: true);
    expect(
      tester.widget<Text>(find.byKey(MeetingCard.cancelledKey)).data,
      'Cancelled: Design review · '
      'Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM',
    );
    expect(find.byKey(MeetingCard.joinKey), findsNothing);
    expect(find.byKey(MeetingCard.openEventKey), findsNothing);
  });

  testWidgets('an invite to a meeting since cancelled is one line too',
      (tester) async {
    await pumpCard(tester, EventLookup.found(meeting(isCancelled: true)));
    expect(find.byKey(MeetingCard.cancelledKey), findsOneWidget);
    expect(find.byKey(MeetingCard.openEventKey), findsNothing);
  });

  testWidgets('a request card draws its actions; a cancellation does not',
      (tester) async {
    const actions = Text('RSVP row', key: ValueKey('rsvp'));
    await pumpCard(tester, EventLookup.found(meeting()), actions: actions);
    expect(find.byKey(const ValueKey('rsvp')), findsOneWidget);

    await pumpCard(tester, EventLookup.found(meeting()),
        cancellation: true, actions: actions);
    expect(find.byKey(const ValueKey('rsvp')), findsNothing);

    await pumpCard(tester, EventLookup.found(meeting(isCancelled: true)),
        actions: actions);
    expect(find.byKey(const ValueKey('rsvp')), findsNothing);
  });

  testWidgets('gone says so, in the message kind\'s words', (tester) async {
    await pumpCard(tester, const EventLookup.gone());
    expect(tester.widget<Text>(find.byKey(MeetingCard.goneKey)).data,
        'This meeting is no longer on your calendar.');
    await pumpCard(tester, const EventLookup.gone(), cancellation: true);
    expect(tester.widget<Text>(find.byKey(MeetingCard.goneKey)).data,
        'Cancelled · this meeting is no longer on your calendar.');
  });

  testWidgets('blocked or unreachable draws nothing', (tester) async {
    await pumpCard(
        tester, const EventLookup.blocked(CalendarAvailability.scopeMissing));
    expect(find.byType(Text), findsNothing);
    await pumpCard(tester, const EventLookup.unreachable());
    expect(find.byType(Text), findsNothing);
  });
}
