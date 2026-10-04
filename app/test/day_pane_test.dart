import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/reminder_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/widgets/command_plan_card.dart';
import 'package:bond_inbox/widgets/day_grid.dart' show GridSpan;
import 'package:bond_inbox/widgets/day_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A writer the long-answer card never reaches: an [Answer] writes nothing.
class _NoWriter implements CalendarWriter {
  @override
  Future<PreviewResult> preview(CalendarWrite write) =>
      throw UnimplementedError();

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) =>
      throw UnimplementedError();
}

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
    Map<String, MeetingBrief> briefs = const {},
    Set<String> briefsWaiting = const {},
    Set<String> expandedBriefs = const {},
    void Function(String)? onToggleBrief,
    Widget Function(String)? briefBody,
    Widget? commandBar,
    Widget? planCard,
    List<Reminder> reminders = const [],
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
          briefs: briefs,
          briefsWaiting: briefsWaiting,
          expandedBriefs: expandedBriefs,
          onToggleBrief: onToggleBrief,
          briefBody: briefBody,
          commandBar: commandBar,
          planCard: planCard,
          reminders: reminders,
        ),
      ),
    ));
    await tester.pump();
  }

  group('agenda', () {
    testWidgets('a written brief is a glance under its meeting, and a '
        'cancelled or declined meeting shows none', (tester) async {
      await pumpPane(
        tester,
        events: [
          timed('briefed', 'Fabrikam sync', DateTime.utc(2026, 9, 29, 20)),
          timed('plain', 'Contoso standup', DateTime.utc(2026, 9, 29, 21)),
          timed('off', 'Fabrikam retro', DateTime.utc(2026, 9, 29, 22),
              isCancelled: true),
          timed('no', 'Northwind review', DateTime.utc(2026, 9, 29, 23),
              responseStatus: 'declined'),
        ],
        briefs: const {
          'briefed': MeetingBrief(headline: 'Dana is waiting on the quote.'),
          'off': MeetingBrief(headline: 'Should not show.'),
          'no': MeetingBrief(headline: 'Should not show either.'),
        },
        onToggleBrief: (_) {},
      );

      final teaser = find.byKey(DayPane.briefTeaserKeyFor('briefed'));
      expect(teaser, findsOneWidget);
      expect(tester.widget<Text>(teaser).data, 'Dana is waiting on the quote.');
      expect(tester.widget<Text>(teaser).maxLines, 3);
      expect(find.byKey(DayPane.briefTeaserKeyFor('plain')), findsNothing);
      expect(find.byKey(DayPane.briefTeaserKeyFor('off')), findsNothing,
          reason: 'a cancelled meeting shows no glance');
      expect(find.byKey(DayPane.briefToggleKeyFor('off')), findsNothing);
      expect(find.byKey(DayPane.briefTeaserKeyFor('no')), findsNothing,
          reason: 'a declined meeting offers no brief either');
      expect(find.byKey(DayPane.briefToggleKeyFor('no')), findsNothing);
    });

    testWidgets('a pending note draws in the glance slot without a chevron',
        (tester) async {
      const note = 'Reading the files sent ahead — brief coming.';
      await pumpPane(
        tester,
        events: [
          timed('pending', 'Fabrikam sync', DateTime.utc(2026, 9, 29, 20),
              location: 'Room 4'),
          timed('both', 'Contoso review', DateTime.utc(2026, 9, 29, 21)),
          timed('off', 'Northwind call', DateTime.utc(2026, 9, 29, 22),
              isCancelled: true),
        ],
        briefs: const {
          'both': MeetingBrief(headline: 'The written brief wins.'),
        },
        briefsWaiting: const {'pending', 'both', 'off'},
        onToggleBrief: (_) {},
      );

      final shown = find.byKey(DayPane.briefNoteKeyFor('pending'));
      expect(shown, findsOneWidget);
      expect(tester.widget<Text>(shown).data, note);
      expect(tester.widget<Text>(shown).maxLines, 1);
      expect(find.byKey(DayPane.briefToggleKeyFor('pending')), findsNothing,
          reason: 'nothing to open yet');
      expect(find.byKey(DayPane.briefTeaserKeyFor('pending')), findsNothing);
      // In the glance slot: under the subject, above the location.
      expect(tester.getTopLeft(find.text('Fabrikam sync')).dy,
          lessThan(tester.getTopLeft(shown).dy));
      expect(tester.getTopLeft(shown).dy,
          lessThan(tester.getTopLeft(find.text('Room 4')).dy));

      expect(find.byKey(DayPane.briefNoteKeyFor('both')), findsNothing,
          reason: 'a written brief wins');
      expect(find.byKey(DayPane.briefTeaserKeyFor('both')), findsOneWidget);
      expect(find.byKey(DayPane.briefNoteKeyFor('off')), findsNothing,
          reason: 'a cancelled meeting offers no brief');
    });

    testWidgets('no note once the meeting has started', (tester) async {
      await pumpPane(
        tester,
        events: [
          // `now` is 16:00Z: one under way, one starting this instant, one
          // still ahead.
          timed('under-way', 'Fabrikam sync', DateTime.utc(2026, 9, 29, 15, 45)),
          timed('starting', 'Contoso review', DateTime.utc(2026, 9, 29, 16)),
          timed('ahead', 'Northwind call', DateTime.utc(2026, 9, 29, 20)),
        ],
        briefsWaiting: const {'under-way', 'starting', 'ahead'},
      );
      expect(find.byKey(DayPane.briefNoteKeyFor('under-way')), findsNothing);
      expect(find.byKey(DayPane.briefNoteKeyFor('starting')), findsNothing);
      expect(find.byKey(DayPane.briefNoteKeyFor('ahead')), findsOneWidget);
    });

    testWidgets('the glance shows up to three lines and a toggle; toggling '
        'asks the host', (tester) async {
      final toggled = <String>[];
      final opened = <String>[];
      await pumpPane(
        tester,
        events: [
          timed('briefed', 'Fabrikam sync', DateTime.utc(2026, 9, 29, 20)),
        ],
        briefs: const {
          'briefed': MeetingBrief(
            headline: 'Dana is waiting on the quote; the Q3 deck arrived '
                'Monday and nobody has answered its pricing question.',
          ),
        },
        onToggleBrief: toggled.add,
        onOpenEvent: opened.add,
      );

      final glance = tester.widget<Text>(
          find.byKey(DayPane.briefTeaserKeyFor('briefed')));
      expect(glance.maxLines, 3);
      expect(glance.overflow, TextOverflow.ellipsis);
      final toggle = find.byKey(DayPane.briefToggleKeyFor('briefed'));
      expect(toggle, findsOneWidget);
      expect(tester.widget<IconButton>(toggle).tooltip, 'Show the brief');
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      // The chevron is the one focus stop and spoken toggle; the glance is a
      // pointer shortcut.
      final glanceInk = tester.widget<InkWell>(find
          .ancestor(
            of: find.byKey(DayPane.briefTeaserKeyFor('briefed')),
            matching: find.byType(InkWell),
          )
          .first);
      expect(glanceInk.canRequestFocus, isFalse);
      expect(glanceInk.excludeFromSemantics, isTrue);

      await tester.tap(toggle);
      await tester.pump();
      expect(toggled, ['briefed']);
      expect(opened, isEmpty, reason: 'the chevron is not the row');

      await tester.tap(find.byKey(DayPane.briefTeaserKeyFor('briefed')));
      await tester.pump();
      expect(toggled, ['briefed', 'briefed']);
      expect(opened, isEmpty, reason: 'the glance is not the row either');

      await tester.tap(find.text('Fabrikam sync'));
      await tester.pump();
      expect(opened, ['briefed'], reason: 'the row still opens the event');
      expect(toggled, hasLength(2));
    });

    testWidgets('expanded draws the brief body under the row', (tester) async {
      final asked = <String>[];
      await pumpPane(
        tester,
        events: [
          timed('briefed', 'Fabrikam sync', DateTime.utc(2026, 9, 29, 20)),
          timed('other', 'Contoso standup', DateTime.utc(2026, 9, 29, 21)),
        ],
        briefs: const {
          'briefed': MeetingBrief(headline: 'Dana is waiting on the quote.'),
          'other': MeetingBrief(headline: 'Nothing open.'),
        },
        expandedBriefs: const {'briefed'},
        onToggleBrief: (_) {},
        briefBody: (id) {
          asked.add(id);
          return Text('body of $id', key: ValueKey('body-$id'));
        },
      );

      expect(find.byKey(const ValueKey('body-briefed')), findsOneWidget);
      expect(find.byKey(const ValueKey('body-other')), findsNothing);
      expect(asked.toSet(), {'briefed'});
      final toggle = find.byKey(DayPane.briefToggleKeyFor('briefed'));
      expect(tester.widget<IconButton>(toggle).tooltip, 'Hide the brief');
      // Under the row, from the subject column.
      final body = tester.getTopLeft(find.byKey(const ValueKey('body-briefed')));
      final glance =
          tester.getBottomLeft(find.byKey(DayPane.briefTeaserKeyFor('briefed')));
      expect(body.dy, greaterThan(glance.dy));
      expect(body.dx,
          tester.getTopLeft(find.text('Fabrikam sync')).dx);
    });

    testWidgets('no brief, no glance, no toggle', (tester) async {
      await pumpPane(
        tester,
        events: [
          timed('plain', 'Contoso standup', DateTime.utc(2026, 9, 29, 21)),
        ],
        onToggleBrief: (_) {},
        expandedBriefs: const {'plain'},
        briefBody: (id) => Text('body of $id'),
      );
      expect(find.byKey(DayPane.briefTeaserKeyFor('plain')), findsNothing);
      expect(find.byKey(DayPane.briefToggleKeyFor('plain')), findsNothing);
      expect(find.text('body of plain'), findsNothing);
    });

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

    testWidgets('a reminder row says when and where it lives, and opens its '
        'thread', (tester) async {
      final opened = <(String, String)>[];
      await pumpPane(
        tester,
        reminders: [
          Reminder(
            id: 'rem-1',
            kind: ReminderKind.replyBy,
            source: 'email',
            conversationKey: 'conv-9',
            title: 'Reply to Contoso: Q3 numbers',
            // 2:00 PM in Los Angeles, today.
            remindAt: DateTime.utc(2026, 9, 29, 21).toIso8601String(),
            status: ReminderStatus.active,
            createdFrom: ReminderOrigin.bar,
            createdAt: '2026-09-29T15:00:00.000000Z',
            updatedAt: '2026-09-29T15:00:00.000000Z',
          ),
        ],
        onOpenConversation: (s, id) => opened.add((s, id)),
      );

      expect(find.byKey(DayPane.reminderRowKeyFor('rem-1')), findsOneWidget);
      expect(find.text('Reminder · in To Do'), findsOneWidget);
      expect(find.text('2:00 PM'), findsOneWidget);
      await tester.tap(find.text('Reply to Contoso: Q3 numbers'));
      expect(opened, [('email', 'conv-9')]);
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

  group('an empty day', () {
    testWidgets('an empty day offline says nothing is saved, not that '
        'nothing is on', (tester) async {
      await pumpPane(tester, availability: CalendarAvailability.unavailable);
      expect(find.text(nothingSavedText), findsOneWidget);
      expect(find.text(DayPane.emptyText), findsNothing);
    });
  });

  group('the command bar', () {
    const bar = SizedBox(key: ValueKey('bar'), height: 20);
    const card = SizedBox(key: ValueKey('card'), height: 20);

    testWidgets('the bar and its card sit under the title in the agenda and '
        'the grid, the card below the bar', (tester) async {
      for (final view in DayView.values) {
        await pumpPane(
          tester,
          view: view,
          grid: const SizedBox(key: ValueKey('grid')),
          commandBar: bar,
          planCard: card,
        );
        expect(find.byKey(const ValueKey('bar')), findsOneWidget,
            reason: view.name);
        expect(find.byKey(const ValueKey('card')), findsOneWidget,
            reason: view.name);
        final title = tester.getTopLeft(find.text(dayTitle(today, today))).dy;
        final barTop = tester.getTopLeft(find.byKey(const ValueKey('bar'))).dy;
        final cardTop =
            tester.getTopLeft(find.byKey(const ValueKey('card'))).dy;
        final pills = tester.getTopLeft(find.byKey(DayPane.agendaKey)).dy;
        expect(title < barTop && barTop < cardTop && cardTop < pills, isTrue,
            reason: view.name);
      }
    });

    testWidgets('a long answer is capped and scrolls inside its card, and '
        'nothing overflows', (tester) async {
      final long = [
        for (var i = 0; i < 60; i++)
          'Thu Oct ${i % 28 + 1} 9:00–9:30 AM Fictional sync number $i',
      ].join(' · ');
      await pumpPane(
        tester,
        commandBar: bar,
        planCard: CommandPlanCard(
          plan: Answer(long),
          zone: CalendarZone.tryNamed('America/Los_Angeles')!,
          today: today,
          writer: _NoWriter(),
          onDone: (_, _) {},
          onDismiss: () {},
          onPickSlot: (_, _) async {},
          onChoose: (_) async {},
        ),
      );
      expect(tester.takeException(), isNull);
      final card = tester.getSize(find.byType(CommandPlanCard));
      // 40% of the pane's 852 px is 340.8, so the 320 px cap holds.
      expect(card.height, lessThanOrEqualTo(CommandPlanCard.maxHeight));
      expect(
          find.descendant(
              of: find.byType(CommandPlanCard),
              matching: find.byType(SingleChildScrollView)),
          findsOneWidget);
      // The day is still there under it.
      expect(find.byKey(DayPane.agendaKey), findsOneWidget);
    });

    test('the cap is 40% of a short pane, and 320 px of a tall one', () {
      expect(CommandPlanCard.maxHeightIn(500), 200);
      expect(CommandPlanCard.maxHeightIn(2000), 320);
      expect(CommandPlanCard.maxHeightIn(double.infinity), 320);
    });

    testWidgets('null draws neither, and the invites view has neither',
        (tester) async {
      await pumpPane(tester);
      expect(find.byKey(const ValueKey('bar')), findsNothing);

      await pumpPane(
        tester,
        mode: DayPaneMode.invites,
        commandBar: bar,
        planCard: card,
      );
      expect(find.byKey(const ValueKey('bar')), findsNothing);
      expect(find.byKey(const ValueKey('card')), findsNothing);
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
