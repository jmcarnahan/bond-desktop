import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/widgets/day_grid.dart' show GridSpan;
import 'package:bond_inbox/widgets/day_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Day stop's pane, prop-only: a pinned clock, a named zone, and rows by
/// their text. Bare pumps only — the countdowns hold a periodic timer.
void main() {
  setUpAll(initCalendarZones);

  // Tuesday Sep 29 2026, 9:00 AM in Los Angeles.
  final now = DateTime.utc(2026, 9, 29, 16);
  const today = CalendarDate(2026, 9, 29);
  const join = 'https://teams.example.com/l/meetup-join/fictional';

  CalendarEvent timed(
    String id,
    String subject,
    DateTime start, {
    Duration length = const Duration(minutes: 30),
    bool isCancelled = false,
    String responseStatus = 'accepted',
    String joinUrl = '',
    String location = '',
    bool? responseRequested,
    String organizerName = '',
    String organizerAddress = '',
    String seriesMasterId = '',
  }) =>
      CalendarEvent(
        id: id,
        subject: subject,
        startUtc: start,
        endUtc: start.add(length),
        isCancelled: isCancelled,
        responseStatus: responseStatus,
        joinUrl: joinUrl,
        location: location,
        responseRequested: responseRequested,
        organizerName: organizerName,
        organizerAddress: organizerAddress,
        seriesMasterId: seriesMasterId,
        showAs: 'busy',
      );

  Future<void> pumpPane(
    WidgetTester tester, {
    DayPaneMode mode = DayPaneMode.agenda,
    CalendarDate day = today,
    CalendarAvailability availability = CalendarAvailability.available,
    List<CalendarEvent>? events = const [],
    List<Conversation> conversations = const [],
    List<InviteEntry>? invites = const [],
    void Function(CalendarDate)? onSelectDay,
    VoidCallback? onBackToDay,
    void Function(String, String)? onOpenConversation,
    void Function(String)? onOpenLink,
    VoidCallback? onOpenSettings,
    void Function(String)? onOpenEvent,
    Widget Function(InviteEntry entry)? inviteActions,
    DateTime? at,
    DayView view = DayView.agenda,
    void Function(DayView)? onViewChanged,
    GridSpan gridSpan = GridSpan.day,
    void Function(GridSpan)? onGridSpanChanged,
    Widget? grid,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DayPane(
          mode: mode,
          day: day,
          today: today,
          now: at ?? now,
          zone: CalendarZone.tryNamed('America/Los_Angeles')!,
          availability: availability,
          events: events,
          conversations: conversations,
          invites: invites,
          onSelectDay: onSelectDay ?? (_) {},
          onBackToDay: onBackToDay ?? () {},
          onOpenConversation: onOpenConversation ?? (_, _) {},
          onOpenLink: onOpenLink ?? (_) {},
          onOpenSettings: onOpenSettings ?? () {},
          onOpenEvent: onOpenEvent,
          inviteActions: inviteActions,
          view: view,
          onViewChanged: onViewChanged ?? (_) {},
          gridSpan: gridSpan,
          onGridSpanChanged: onGridSpanChanged ?? (_) {},
          grid: grid,
        ),
      ),
    ));
    await tester.pump();
  }

  group('agenda', () {
    testWidgets('meetings by subject, with their time, place and marks',
        (tester) async {
      final links = <String>[];
      await pumpPane(
        tester,
        onOpenLink: links.add,
        events: [
          timed('soon', 'Contoso kickoff', now.add(const Duration(minutes: 10)),
              joinUrl: join, location: 'Room 4B', responseRequested: true,
              responseStatus: 'notResponded'),
          timed('later', 'Fabrikam review', DateTime.utc(2026, 9, 29, 21),
              joinUrl: join),
        ],
      );

      expect(find.text('Contoso kickoff'), findsOneWidget);
      expect(find.text('Fabrikam review'), findsOneWidget);
      expect(find.text('9:10–9:40 AM'), findsOneWidget);
      expect(find.text('Room 4B'), findsOneWidget);
      expect(find.text('in 10m'), findsOneWidget);
      expect(find.text('RSVP owed'), findsOneWidget);
      expect(find.byTooltip('Online meeting'), findsNWidgets(2));
      // Join inside the fifteen-minute window, and only there.
      expect(find.text('Join'), findsOneWidget);
      await tester.tap(find.text('Join'));
      expect(links, [join]);
      expect(find.text('Now'), findsOneWidget);
    });

    testWidgets('no Join outside the window', (tester) async {
      await pumpPane(tester, events: [
        timed('far', 'Quarterly plan', now.add(const Duration(minutes: 40)),
            joinUrl: join),
      ]);
      expect(find.text('Quarterly plan'), findsOneWidget);
      expect(find.text('Join'), findsNothing);
      expect(find.text('RSVP owed'), findsNothing);
    });

    testWidgets('the overlap line, and the cancelled and declined captions',
        (tester) async {
      await pumpPane(tester, events: [
        timed('a', 'Planning', DateTime.utc(2026, 9, 29, 20),
            length: const Duration(hours: 1)),
        timed('b', 'Budget review', DateTime.utc(2026, 9, 29, 20, 30)),
        timed('c', 'Offsite prep', DateTime.utc(2026, 9, 29, 22),
            isCancelled: true),
        timed('d', 'Vendor pitch', DateTime.utc(2026, 9, 29, 23),
            responseStatus: 'declined'),
      ]);

      expect(find.text('⚠ overlaps Budget review'), findsOneWidget);
      expect(find.text('⚠ overlaps Planning'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      final struck = tester.widget<Text>(find.text('Offsite prep'));
      expect(struck.style?.decoration, TextDecoration.lineThrough);
      expect(find.text('Declined'), findsOneWidget);
      expect(
        find.ancestor(
            of: find.text('Vendor pitch'), matching: find.byType(Opacity)),
        findsOneWidget,
      );
    });

    testWidgets('an empty day, available and still reading', (tester) async {
      await pumpPane(tester);
      expect(find.text('Nothing on your calendar.'), findsOneWidget);

      await pumpPane(tester, availability: CalendarAvailability.unknown);
      expect(find.text('Reading your calendar…'), findsOneWidget);
      expect(find.text('Nothing on your calendar.'), findsNothing);
    });

    testWidgets('scope missing says where to fix it', (tester) async {
      var opened = 0;
      await pumpPane(
        tester,
        availability: CalendarAvailability.scopeMissing,
        events: [timed('x', 'Stale row', DateTime.utc(2026, 9, 29, 20))],
        onOpenSettings: () => opened++,
      );

      expect(
        find.text('Calendar permission needed — Settings › Connection'),
        findsOneWidget,
      );
      expect(find.text('Stale row'), findsNothing);
      await tester.tap(find.text('Open Settings'));
      expect(opened, 1);
    });

    testWidgets('SDK mode shows the sentence and no rows', (tester) async {
      await pumpPane(
        tester,
        availability: CalendarAvailability.sdkMode,
        events: [timed('x', 'Stale row', DateTime.utc(2026, 9, 29, 20))],
      );

      expect(
        find.text('The calendar needs the Bond server connection '
            '(Settings › Connection).'),
        findsOneWidget,
      );
      expect(find.text('Stale row'), findsNothing);
    });

    testWidgets('offline shows what was saved, with a caption', (tester) async {
      await pumpPane(
        tester,
        availability: CalendarAvailability.unavailable,
        events: [timed('x', 'Saved row', DateTime.utc(2026, 9, 29, 20))],
      );

      expect(
        find.text("Can't reach the calendar right now — showing what was saved."),
        findsOneWidget,
      );
      expect(find.text('Saved row'), findsOneWidget);
    });

    testWidgets('a deadline row opens its thread', (tester) async {
      final opened = <(String, String)>[];
      await pumpPane(
        tester,
        conversations: const [
          Conversation(
            id: 'conv-7',
            source: 'teams',
            subject: 'Fabrikam quote',
            latestDeadline: '2026-09-29',
          ),
        ],
        onOpenConversation: (s, id) => opened.add((s, id)),
      );

      expect(find.text('Due'), findsOneWidget);
      await tester.tap(find.text('Fabrikam quote'));
      expect(opened, [('teams', 'conv-7')]);
    });

    testWidgets('Agenda | Grid switches the view, and Day | Week shows only '
        'on the grid', (tester) async {
      final views = <DayView>[];
      await pumpPane(tester, onViewChanged: views.add);
      expect(find.text('Agenda'), findsOneWidget);
      expect(find.text('Grid'), findsOneWidget);
      expect(find.byKey(DayPane.spanDayKey), findsNothing);
      expect(find.byKey(DayPane.spanWeekKey), findsNothing);

      await tester.tap(find.byKey(DayPane.gridKey));
      expect(views, [DayView.grid]);
      // Agenda is what is showing, so pressing it asks for nothing.
      await tester.tap(find.byKey(DayPane.agendaKey));
      expect(views, [DayView.grid]);

      final spans = <GridSpan>[];
      await pumpPane(
        tester,
        view: DayView.grid,
        onViewChanged: views.add,
        onGridSpanChanged: spans.add,
        grid: const SizedBox(key: ValueKey('the-grid')),
        events: [timed('x', 'Agenda only row', DateTime.utc(2026, 9, 29, 20))],
      );
      expect(find.byKey(const ValueKey('the-grid')), findsOneWidget);
      expect(find.text('Agenda only row'), findsNothing);
      expect(find.byKey(DayPane.spanDayKey), findsOneWidget);
      await tester.tap(find.byKey(DayPane.spanWeekKey));
      expect(spans, [GridSpan.week]);
      await tester.tap(find.byKey(DayPane.agendaKey));
      expect(views, [DayView.grid, DayView.agenda]);
    });

    testWidgets('the grid view says Reading until the grid is built, and the '
        'availability sentences stand over it', (tester) async {
      await pumpPane(tester, view: DayView.grid);
      expect(find.text(DayPane.readingText), findsOneWidget);

      await pumpPane(
        tester,
        view: DayView.grid,
        availability: CalendarAvailability.sdkMode,
        grid: const SizedBox(key: ValueKey('the-grid')),
      );
      expect(find.text(DayPane.sdkModeText), findsOneWidget);
      expect(find.byKey(const ValueKey('the-grid')), findsNothing);

      await pumpPane(
        tester,
        view: DayView.grid,
        availability: CalendarAvailability.unavailable,
        grid: const SizedBox(key: ValueKey('the-grid')),
      );
      expect(find.text(DayPane.offlineText), findsOneWidget);
      expect(find.byKey(const ValueKey('the-grid')), findsOneWidget);
    });

    testWidgets('on the week grid the arrows step a week', (tester) async {
      final picked = <CalendarDate>[];
      await pumpPane(
        tester,
        view: DayView.grid,
        gridSpan: GridSpan.week,
        grid: const SizedBox(),
        onSelectDay: picked.add,
      );

      await tester.tap(find.byTooltip('Next week'));
      await tester.tap(find.byTooltip('Previous week'));
      expect(picked, [today.addDays(7), today.addDays(-7)]);

      // Six days from the window's edge, a week back would leave it.
      await pumpPane(
        tester,
        day: today.addDays(-DayPane.daysBack + 6),
        view: DayView.grid,
        gridSpan: GridSpan.week,
        grid: const SizedBox(),
      );
      final prev = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_left));
      expect(prev.onPressed, isNull);
    });

    testWidgets('the arrows stop at the mirror window and Today at today',
        (tester) async {
      final picked = <CalendarDate>[];
      await pumpPane(tester, onSelectDay: picked.add);

      expect(find.text('Today · Tuesday, Sep 29'), findsOneWidget);
      final todayButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Today'));
      expect(todayButton.onPressed, isNull);

      await tester.tap(find.byTooltip('Next day'));
      expect(picked, [today.addDays(1)]);

      await pumpPane(tester, day: today.addDays(-30), onSelectDay: picked.add);
      final prev = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_left));
      expect(prev.onPressed, isNull);
      final todayAgain = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Today'));
      expect(todayAgain.onPressed, isNotNull);

      await pumpPane(tester, day: today.addDays(120));
      final next = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_right));
      expect(next.onPressed, isNull);
    });
  });

  group('invites', () {
    testWidgets('lists the entries in the order given, and goes back',
        (tester) async {
      var back = 0;
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        onBackToDay: () => back++,
        invites: [
          InviteEntry(
            timed('b', 'Board prep', DateTime.utc(2026, 10, 2, 17),
                organizerName: 'Avery Contoso'),
            pinned: true,
          ),
          InviteEntry(
            timed('w', 'Weekly sync', DateTime.utc(2026, 10, 1, 17),
                organizerAddress: 'lead@fabrikam.com', seriesMasterId: 's1'),
            occurrences: 17,
            overlaps: Overlaps(hard: [
              timed('x', 'Design crit', DateTime.utc(2026, 10, 1, 17)),
            ]),
          ),
        ],
      );

      expect(find.text('Invites'), findsOneWidget);
      final board = tester.getTopLeft(find.text('Board prep')).dy;
      final weekly = tester.getTopLeft(find.text('Weekly sync · series')).dy;
      expect(board, lessThan(weekly));
      expect(find.text('Fri Oct 2 · 10:00–10:30 AM'), findsOneWidget);
      expect(find.text('from Avery Contoso'), findsOneWidget);
      expect(find.text('from lead@fabrikam.com'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      expect(find.text('⚠ overlaps Design crit'), findsOneWidget);

      await tester.tap(find.text('‹ Day'));
      expect(back, 1);
    });

    testWidgets('an empty list says so', (tester) async {
      await pumpPane(tester, mode: DayPaneMode.invites);
      expect(find.text('No invites to answer.'), findsOneWidget);
    });

    testWidgets('still reading draws nothing, not a false all-clear',
        (tester) async {
      await pumpPane(tester, mode: DayPaneMode.invites, invites: null);
      expect(find.text('Invites'), findsOneWidget);
      expect(find.text('No invites to answer.'), findsNothing);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('SDK mode says so rather than "no invites"', (tester) async {
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        availability: CalendarAvailability.sdkMode,
      );
      expect(find.text(DayPane.sdkModeText), findsOneWidget);
      expect(find.text('No invites to answer.'), findsNothing);
    });

    testWidgets('scope missing says where to fix it', (tester) async {
      var opened = 0;
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        availability: CalendarAvailability.scopeMissing,
        onOpenSettings: () => opened++,
      );
      expect(find.text(DayPane.scopeMissingText), findsOneWidget);
      expect(find.text('No invites to answer.'), findsNothing);
      await tester.tap(find.text('Open Settings'));
      expect(opened, 1);
    });

    testWidgets('offline keeps the list, with the caption', (tester) async {
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        availability: CalendarAvailability.unavailable,
      );
      expect(find.text(DayPane.offlineText), findsOneWidget);
      expect(find.text('No invites to answer.'), findsOneWidget);
    });
  });

  group('opening an event', () {
    testWidgets('a meeting row and an all-day row open the event',
        (tester) async {
      final opened = <String>[];
      await pumpPane(
        tester,
        onOpenEvent: opened.add,
        events: [
          const CalendarEvent(
            id: 'banner',
            subject: 'Fabrikam offsite',
            isAllDay: true,
            startDate: today,
            endDate: CalendarDate(2026, 9, 30),
          ),
          timed('m1', 'Contoso kickoff', DateTime.utc(2026, 9, 29, 20)),
        ],
      );
      await tester.tap(find.text('Contoso kickoff'));
      await tester.pump();
      await tester.tap(find.text('Fabrikam offsite'));
      await tester.pump();
      expect(opened, ['m1', 'banner']);
    });

    testWidgets('an invite row opens the event', (tester) async {
      final opened = <String>[];
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        onOpenEvent: opened.add,
        invites: [
          InviteEntry(timed('inv-1', 'Budget review',
              DateTime.utc(2026, 10, 1, 17),
              responseStatus: 'none')),
        ],
      );
      await tester.tap(find.text('Budget review'));
      await tester.pump();
      expect(opened, ['inv-1']);
    });

    testWidgets('each invite row carries its actions, and a press on one is '
        'not an open', (tester) async {
      final opened = <String>[];
      final pressed = <String>[];
      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        onOpenEvent: opened.add,
        inviteActions: (entry) => TextButton(
          key: ValueKey('yes-${entry.event.id}'),
          onPressed: () => pressed.add(entry.event.id),
          child: const Text('Yes'),
        ),
        invites: [
          InviteEntry(timed('inv-1', 'Budget review',
              DateTime.utc(2026, 10, 1, 17),
              responseStatus: 'none')),
          InviteEntry(timed('inv-2', 'Fabrikam sync',
              DateTime.utc(2026, 10, 2, 17),
              responseStatus: 'none')),
        ],
      );
      expect(find.text('Yes'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('yes-inv-2')));
      await tester.pump();
      expect(pressed, ['inv-2']);
      expect(opened, isEmpty);
    });

    testWidgets('without a handler the rows stay inert', (tester) async {
      await pumpPane(
        tester,
        events: [
          timed('m1', 'Contoso kickoff', DateTime.utc(2026, 9, 29, 20)),
        ],
      );
      expect(
        find.ancestor(
          of: find.text('Contoso kickoff'),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Contoso kickoff'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
