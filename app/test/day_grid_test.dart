import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/widgets/day_grid.dart';
import 'package:bond_inbox/widgets/day_pane.dart' show DayPane;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalender/kalender.dart' show KalenderView;
import 'package:timezone/timezone.dart' as tz;

/// The Day stop's grid over `kalender`, prop-only: a pinned clock, a named
/// zone, tiles found by their key or their text.
///
/// Every test ends by unmounting the grid: the package's time indicator runs
/// periodic timers that cancel only when the view goes, and the controllers
/// must outlive the view (gotcha 54).
void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  setUp(() => la = CalendarZone.tryNamed('America/Los_Angeles')!);

  // Wednesday Oct 7 2026, 8:00 AM in Los Angeles (PDT, UTC-7).
  const day = CalendarDate(2026, 10, 7);
  final clock = DateTime.utc(2026, 10, 7, 15);

  /// The drop tests run as a phone would drag (Android: the long press) and
  /// as this app does (macOS: a plain drag, where the package starts on the
  /// move).
  final platforms = TargetPlatformVariant(
      {TargetPlatform.android, TargetPlatform.macOS});

  /// An event of the owner's own: organiser, nobody invited — movable.
  CalendarEvent own(String id, String subject, DateTime start,
          {Duration length = const Duration(hours: 1)}) =>
      CalendarEvent(
        id: id,
        subject: subject,
        startUtc: start,
        endUtc: start.add(length),
        isOrganizer: true,
        responseStatus: 'organizer',
        organizerAddress: 'owner@contoso.com',
        showAs: 'busy',
      );

  /// Somebody else's meeting on the owner's calendar — locked.
  CalendarEvent theirs(String id, String subject, DateTime start) =>
      CalendarEvent(
        id: id,
        subject: subject,
        startUtc: start,
        endUtc: start.add(const Duration(hours: 1)),
        responseStatus: 'accepted',
        organizerName: 'Dana Fabrikam',
        organizerAddress: 'dana@fabrikam.com',
        attendees: const [
          Attendee(name: 'Owner', address: 'owner@contoso.com'),
        ],
        showAs: 'busy',
      );

  Future<void> pumpGrid(
    WidgetTester tester, {
    CalendarDate on = day,
    GridSpan span = GridSpan.day,
    List<CalendarEvent> events = const [],
    List<DayItem> markers = const [],
    GridProposal? proposal,
    bool locked = false,
    DateTime? now,
    CalendarZone? zone,
    void Function(String)? onOpenEvent,
    void Function(DayItem)? onOpenItem,
    void Function(String, DateTime, DateTime)? onMoveRequested,
    void Function(CalendarDate)? onVisibleDayChanged,
    void Function(DateTime, DateTime)? onCreateRequested,
    int defaultCreateMinutes = 30,
    void Function(DateTime, DateTime)? onProposalChanged,
    VoidCallback? onProposalTapped,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: DayGrid(
            day: on,
            span: span,
            events: events,
            markers: markers,
            proposal: proposal,
            locked: locked,
            zone: zone ?? la,
            clock: () => now ?? clock,
            onOpenEvent: onOpenEvent,
            onOpenItem: onOpenItem,
            onMoveRequested: onMoveRequested,
            onVisibleDayChanged: onVisibleDayChanged,
            onCreateRequested: onCreateRequested,
            defaultCreateMinutes: defaultCreateMinutes,
            onProposalChanged: onProposalChanged,
            onProposalTapped: onProposalTapped,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  /// The spike's drag: hold long enough for a touch drag to start (a long
  /// press on the mobile platforms), move in two steps, drop, and let the
  /// drop land. [hold] false is a desktop drag, which starts on the move.
  Future<void> drag(WidgetTester tester, Finder f, Offset by,
      {bool hold = true}) async {
    final gesture = await tester.startGesture(tester.getCenter(f));
    await tester.pump(Duration(milliseconds: hold ? 600 : 16));
    await gesture.moveBy(Offset(by.dx / 2, by.dy * 20 / 42));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(by.dx / 2, by.dy * 22 / 42));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('a press on empty time', () {
    // A 10:00 tile is the ruler: 42 px an hour below its top is 1:00 PM.
    final ten = DateTime.utc(2026, 10, 7, 17);
    final one = DateTime.utc(2026, 10, 7, 20); // 1:00 PM PDT
    Offset oneOClock(WidgetTester tester) =>
        tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('ruler'))) +
        const Offset(4, 3 * 42 + 2);

    testWidgets('a drag sizes the span, and the grid draws nothing for it',
        (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        events: [own('ruler', 'Ruler', ten, length: const Duration(minutes: 30))],
        onCreateRequested: (s, e) => asked.add((s, e)),
      );
      // A phone holds, then drags; a desktop drags with a mouse, whose
      // slop is a pixel or two, so the span starts where the press did.
      final hold = defaultTargetPlatform == TargetPlatform.android;
      final gesture = await tester.startGesture(oneOClock(tester),
          kind: hold ? PointerDeviceKind.touch : PointerDeviceKind.mouse);
      await tester.pump(Duration(milliseconds: hold ? 600 : 16));
      await gesture.moveBy(const Offset(0, 3));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 39));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(asked, hasLength(1));
      expect(asked.single.$1, one);
      expect(asked.single.$1.isUtc, isTrue);
      expect(asked.single.$2.difference(asked.single.$1),
          greaterThanOrEqualTo(const Duration(minutes: 45)));
      // The grid is a mirror: only the ruler is a tile.
      expect(find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('day-grid-tile-')),
          findsOneWidget);
      await unmount(tester);
    }, variant: platforms);

    testWidgets('a drag that barely moved is the default length too',
        (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        events: [own('ruler', 'Ruler', ten, length: const Duration(minutes: 30))],
        onCreateRequested: (s, e) => asked.add((s, e)),
      );
      final gesture = await tester.startGesture(oneOClock(tester),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(0, 3));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, [(one, one.add(const Duration(minutes: 30)))]);
      await unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a bare tap is the default length from the quarter hour',
        (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        events: [own('ruler', 'Ruler', ten, length: const Duration(minutes: 30))],
        onCreateRequested: (s, e) => asked.add((s, e)),
      );
      await tester.tapAt(oneOClock(tester));
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, [(one, one.add(const Duration(minutes: 30)))]);
      await unmount(tester);
    }, variant: platforms);

    testWidgets('the default length is the host\'s', (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        events: [own('ruler', 'Ruler', ten, length: const Duration(minutes: 30))],
        onCreateRequested: (s, e) => asked.add((s, e)),
        defaultCreateMinutes: 90,
      );
      await tester.tapAt(oneOClock(tester));
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, [(one, one.add(const Duration(minutes: 90)))]);
      await unmount(tester);
    });

    testWidgets('a locked grid creates nothing', (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        locked: true,
        events: [own('ruler', 'Ruler', ten, length: const Duration(minutes: 30))],
        onCreateRequested: (s, e) => asked.add((s, e)),
      );
      await tester.tapAt(oneOClock(tester));
      await tester.pump(const Duration(milliseconds: 300));
      await drag(tester, find.byKey(DayGrid.tileKeyFor('ruler')),
          const Offset(0, 126));
      expect(asked, isEmpty);
      await unmount(tester);
    });

    testWidgets('a tap on a tile opens it, never a create', (tester) async {
      final asked = <(DateTime, DateTime)>[];
      final opened = <String>[];
      await pumpGrid(
        tester,
        events: [own('ruler', 'Ruler', ten)],
        onOpenEvent: opened.add,
        onCreateRequested: (s, e) => asked.add((s, e)),
      );
      await tester.tap(find.byKey(DayGrid.tileKeyFor('ruler')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opened, ['ruler']);
      expect(asked, isEmpty);
      await unmount(tester);
    });
  });

  testWidgets('the axis labels hours only, however tall the grid',
      (tester) async {
    // kalender's own timeline would label every 30, 15 or 5 minutes once
    // the text fits; a desktop window fits them all. The hour lines read
    // "9 AM"; the half hours are lines, not words.
    await pumpGrid(tester);

    expect(find.text('9 AM'), findsOneWidget);
    expect(find.text('3 PM'), findsOneWidget);
    expect(find.text('9:30 AM'), findsNothing);
    expect(find.text('3:15 PM'), findsNothing);
  });

  testWidgets('a timed event and an all-day event render by label',
      (tester) async {
    await pumpGrid(tester, events: [
      own('m1', 'Contoso planning', DateTime.utc(2026, 10, 7, 17)),
      const CalendarEvent(
        id: 'a1',
        subject: 'Fabrikam offsite',
        isAllDay: true,
        startDate: day,
        endDate: CalendarDate(2026, 10, 8),
      ),
    ]);

    expect(find.byKey(DayGrid.tileKeyFor('m1')), findsOneWidget);
    expect(find.text('Contoso planning'), findsOneWidget);
    expect(find.text('10:00–11:00 AM'), findsOneWidget);
    expect(find.byKey(DayGrid.tileKeyFor('a1')), findsOneWidget);
    expect(find.text('Fabrikam offsite'), findsOneWidget);
    // The all-day tile sits in the header, above the timed one.
    expect(
      tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('a1'))).dy,
      lessThan(tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('m1'))).dy),
    );
    await unmount(tester);
  });

  testWidgets('a deadline sits in the header and its tap opens the item',
      (tester) async {
    const conv = Conversation(
      id: 'conv-9',
      source: 'email',
      subject: 'Contoso quote',
    );
    const item = DeadlineItem(conv, 'by Wednesday', day: day);
    final opened = <DayItem>[];
    await pumpGrid(tester, markers: const [item], onOpenItem: opened.add);

    final marker =
        find.byKey(DayGrid.markerKeyFor('email', 'conv-9', kind: 'due'));
    expect(marker, findsOneWidget);
    expect(find.text('Due · Contoso quote · by Wednesday'), findsOneWidget);
    await tester.tap(marker);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, [item]);
    await unmount(tester);
  });

  testWidgets('the proposal is a ghost: drawn, labelled, never dragged',
      (tester) async {
    final moves = <String>[];
    final changed = <(DateTime, DateTime)>[];
    await pumpGrid(
      onProposalChanged: (s, e) => changed.add((s, e)),
      tester,
      proposal: GridProposal(
        startUtc: DateTime.utc(2026, 10, 7, 20),
        endUtc: DateTime.utc(2026, 10, 7, 21),
        label: 'Proposed: Fabrikam sync',
      ),
      onMoveRequested: (id, s, e) => moves.add(id),
    );

    expect(find.byKey(DayGrid.proposalKey), findsOneWidget);
    expect(find.text('Proposed: Fabrikam sync'), findsOneWidget);
    await drag(tester, find.byKey(DayGrid.proposalKey), const Offset(0, 42));
    expect(moves, isEmpty);
    // Not adjustable: even with a handler, a drag asks for nothing.
    expect(changed, isEmpty);
    await unmount(tester);
  }, variant: platforms);

  testWidgets('tapping an event opens it by id', (tester) async {
    final opened = <String>[];
    await pumpGrid(
      tester,
      events: [theirs('t1', 'Fabrikam review', DateTime.utc(2026, 10, 7, 18))],
      onOpenEvent: opened.add,
    );

    await tester.tap(find.byKey(DayGrid.tileKeyFor('t1')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, ['t1']);
    await unmount(tester);
  });

  testWidgets("an attendee's meeting is locked: a drag asks for nothing",
      (tester) async {
    final moves = <(String, DateTime, DateTime)>[];
    await pumpGrid(
      tester,
      events: [theirs('t1', 'Fabrikam review', DateTime.utc(2026, 10, 7, 18))],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );

    await drag(tester, find.byKey(DayGrid.tileKeyFor('t1')), const Offset(0, 42));
    expect(moves, isEmpty);
    // Still drawn where the store put it.
    expect(find.text('11:00 AM–12:00 PM'), findsOneWidget);
    await unmount(tester);
  }, variant: platforms);

  testWidgets('dragging an own event an hour down asks for that hour, and '
      'the tile stays put', (tester) async {
    final moves = <(String, DateTime, DateTime)>[];
    final start = DateTime.utc(2026, 10, 7, 17); // 10:00 AM PDT
    await pumpGrid(
      tester,
      events: [own('m1', 'Contoso planning', start)],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );
    final before = tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('m1')));

    await drag(tester, find.byKey(DayGrid.tileKeyFor('m1')), const Offset(0, 42));

    expect(moves, hasLength(1));
    expect(moves.single.$1, 'm1');
    expect(moves.single.$2, start.add(const Duration(hours: 1)));
    expect(moves.single.$3.difference(moves.single.$2),
        const Duration(hours: 1));
    expect(moves.single.$2.isUtc, isTrue);
    // Not moved by the grid: the store's answer moves it.
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('m1'))), before);
    expect(find.text('10:00–11:00 AM'), findsOneWidget);
    await unmount(tester);
  }, variant: platforms);

  testWidgets('across spring-forward the drop is the wall time the grid '
      'showed', (tester) async {
    // Sunday Mar 8 2026: 2:00 AM PST jumps to 3:00 AM PDT. An own event at
    // 10:00 AM PDT (17:00Z) dragged an hour down is 11:00 AM PDT (18:00Z).
    const dst = CalendarDate(2026, 3, 8);
    final moves = <(String, DateTime, DateTime)>[];
    final start = la.localDateTime(dst, 10, 0).toUtc();
    expect(start, DateTime.utc(2026, 3, 8, 17));
    await pumpGrid(
      tester,
      on: dst,
      now: DateTime.utc(2026, 3, 8, 16),
      events: [own('d1', 'Contoso standup', start)],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );

    await drag(tester, find.byKey(DayGrid.tileKeyFor('d1')), const Offset(0, 42));

    expect(moves, hasLength(1));
    final (_, s, e) = moves.single;
    expect(e.difference(s), const Duration(hours: 1));
    expect(la.toLocal(s).hour, 11);
    expect(la.toLocal(s).day, 8);
    expect(s, DateTime.utc(2026, 3, 8, 18));
    await unmount(tester);
  }, variant: platforms);

  group('a standing proposal', () {
    // Wed 1:00–2:30 PM PDT.
    final start = DateTime.utc(2026, 10, 7, 20);
    final end = DateTime.utc(2026, 10, 7, 21, 30);
    GridProposal dinner({bool adjustable = true}) => GridProposal(
          startUtc: start,
          endUtc: end,
          label: 'Proposed',
          subject: 'Re: dinner on friday',
          adjustable: adjustable,
        );

    testWidgets('names what it is, with Proposed under it', (tester) async {
      await pumpGrid(tester, proposal: dinner());
      expect(
          find.descendant(
              of: find.byKey(DayGrid.proposalKey),
              matching: find.text('Re: dinner on friday')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(DayGrid.proposalKey),
              matching: find.text('Proposed')),
          findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a drag asks for the new span and the tile stays where the '
        'host says', (tester) async {
      final changed = <(DateTime, DateTime)>[];
      await pumpGrid(tester,
          proposal: dinner(), onProposalChanged: (s, e) => changed.add((s, e)));
      final before = tester.getTopLeft(find.byKey(DayGrid.proposalKey));
      await drag(tester, find.byKey(DayGrid.proposalKey), const Offset(0, 42));
      expect(changed, [
        (start.add(const Duration(hours: 1)), end.add(const Duration(hours: 1))),
      ]);
      expect(changed.single.$1.isUtc, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(find.byKey(DayGrid.proposalKey)), before);
      await unmount(tester);
    }, variant: platforms);

    testWidgets('a tap asks for the card', (tester) async {
      var tapped = 0;
      await pumpGrid(tester,
          proposal: dinner(), onProposalTapped: () => tapped++);
      await tester.tap(find.byKey(DayGrid.proposalKey));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tapped, 1);
      await unmount(tester);
    });

    testWidgets('locked, it neither moves nor answers a tap', (tester) async {
      final changed = <(DateTime, DateTime)>[];
      var tapped = 0;
      await pumpGrid(tester,
          proposal: dinner(),
          locked: true,
          onProposalChanged: (s, e) => changed.add((s, e)),
          onProposalTapped: () => tapped++);
      await tester.tap(find.byKey(DayGrid.proposalKey));
      await tester.pump(const Duration(milliseconds: 300));
      await drag(tester, find.byKey(DayGrid.proposalKey), const Offset(0, 42));
      expect(changed, isEmpty);
      expect(tapped, 0);
      await unmount(tester);
    }, variant: platforms);

    testWidgets('in the week it moves to the next day\'s column at the same '
        'wall time, across spring-forward', (tester) async {
      const sat = CalendarDate(2026, 3, 7);
      final s0 = la.localDateTime(sat, 10, 0).toUtc();
      final changed = <(DateTime, DateTime)>[];
      await pumpGrid(
        tester,
        on: sat,
        span: GridSpan.week,
        now: DateTime.utc(2026, 3, 6, 16),
        proposal: GridProposal(
          startUtc: s0,
          endUtc: s0.add(const Duration(hours: 1)),
          label: 'Proposed',
          subject: 'Re: brunch',
          adjustable: true,
        ),
        onProposalChanged: (s, e) => changed.add((s, e)),
      );
      final tile = find.byKey(DayGrid.proposalKey);
      final width = tester.getSize(tile).width;
      await drag(tester, tile, Offset(width + 4, 0));
      expect(changed, hasLength(1));
      final (s, e) = changed.single;
      expect(s, DateTime.utc(2026, 3, 8, 17));
      expect(la.toLocal(s).hour, 10);
      expect(e.difference(s), const Duration(hours: 1));
      await unmount(tester);
    }, variant: platforms);
  });

  testWidgets('the week before spring-forward: a Saturday event dragged to '
      'Sunday keeps its wall time', (tester) async {
    // Saturday Mar 7 2026 10:00 AM PST (18:00Z) → Sunday Mar 8 10:00 AM PDT
    // (17:00Z): one column right, the same height, 23 hours later.
    const sat = CalendarDate(2026, 3, 7);
    final moves = <(String, DateTime, DateTime)>[];
    final start = la.localDateTime(sat, 10, 0).toUtc();
    expect(start, DateTime.utc(2026, 3, 7, 18));
    await pumpGrid(
      tester,
      on: sat,
      span: GridSpan.week,
      now: DateTime.utc(2026, 3, 6, 16),
      events: [own('w1', 'Contoso review', start)],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );
    final tile = find.byKey(DayGrid.tileKeyFor('w1'));
    final width = tester.getSize(tile).width;

    // One column is the tile's width plus the page's right padding (4).
    await drag(tester, tile, Offset(width + 4, 0));

    expect(moves, hasLength(1));
    final (_, s, e) = moves.single;
    expect(e.difference(s), const Duration(hours: 1));
    expect(la.toLocal(s).day, 8);
    expect(la.toLocal(s).hour, 10);
    expect(s, DateTime.utc(2026, 3, 8, 17));
    await unmount(tester);
  }, variant: platforms);

  testWidgets('on macOS a plain drag, with no hold, asks for the hour',
      (tester) async {
    final moves = <(String, DateTime, DateTime)>[];
    final start = DateTime.utc(2026, 10, 7, 17); // 10:00 AM PDT
    await pumpGrid(
      tester,
      events: [own('m1', 'Contoso planning', start)],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );

    await drag(tester, find.byKey(DayGrid.tileKeyFor('m1')),
        const Offset(0, 42),
        hold: false);

    expect(moves, hasLength(1));
    expect(moves.single.$1, 'm1');
    expect(moves.single.$2, start.add(const Duration(hours: 1)));
    expect(moves.single.$3, start.add(const Duration(hours: 2)));
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a drop where the tile already was asks for nothing',
      (tester) async {
    // A click that wobbles: a few pixels snap back to the tile's own quarter
    // hour, and the package still reports the change.
    final moves = <(String, DateTime, DateTime)>[];
    await pumpGrid(
      tester,
      events: [own('m1', 'Contoso planning', DateTime.utc(2026, 10, 7, 17))],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );

    await drag(tester, find.byKey(DayGrid.tileKeyFor('m1')),
        const Offset(0, 4));
    expect(moves, isEmpty);
    await unmount(tester);
  }, variant: platforms);

  testWidgets('a locked grid asks for nothing, even for its own events',
      (tester) async {
    final moves = <(String, DateTime, DateTime)>[];
    await pumpGrid(
      tester,
      locked: true,
      events: [own('m1', 'Contoso planning', DateTime.utc(2026, 10, 7, 17))],
      onMoveRequested: (id, s, e) => moves.add((id, s, e)),
    );

    await drag(tester, find.byKey(DayGrid.tileKeyFor('m1')),
        const Offset(0, 42));
    expect(moves, isEmpty);
    expect(find.text('10:00–11:00 AM'), findsOneWidget);
    await unmount(tester);
  }, variant: platforms);

  /// A swipe left across the body, more than half its width: the next page.
  Future<void> swipeLeft(WidgetTester tester) async {
    await tester.fling(find.byType(DayGrid), const Offset(-600, 0), 1500);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('swiping the day grid pages to the next day', (tester) async {
    final changed = <CalendarDate>[];
    await pumpGrid(tester, onVisibleDayChanged: changed.add);

    await swipeLeft(tester);
    expect(changed, [day.addDays(1)]);
    await unmount(tester);
  });

  testWidgets('swiping the week grid pages to the next Monday',
      (tester) async {
    final changed = <CalendarDate>[];
    await pumpGrid(tester, span: GridSpan.week, onVisibleDayChanged: changed.add);

    await swipeLeft(tester);
    expect(changed, [mondayOf(day).addDays(7)]);
    await unmount(tester);
  });

  testWidgets('a tap on empty time after paging the week forward is in '
      'the next week', (tester) async {
    final changed = <CalendarDate>[];
    final asked = <(DateTime, DateTime)>[];
    await pumpGrid(tester,
        span: GridSpan.week,
        onVisibleDayChanged: changed.add,
        onCreateRequested: (s, e) => asked.add((s, e)));
    await swipeLeft(tester);
    expect(changed, [mondayOf(day).addDays(7)]);

    await tester.tapAt(tester.getCenter(find.byType(DayGrid)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(asked, hasLength(1));
    final d = la.dateOf(asked.single.$1);
    final monday = mondayOf(day).addDays(7);
    expect(d.isBefore(monday), isFalse, reason: '$d');
    expect(d.isBefore(monday.addDays(7)), isTrue, reason: '$d');
    await unmount(tester);
  });

  testWidgets('a tap after the host moves the day is on the new day',
      (tester) async {
    final asked = <(DateTime, DateTime)>[];
    await pumpGrid(tester, onCreateRequested: (s, e) => asked.add((s, e)));
    // The host moves the pane nine days on, as a search does.
    await pumpGrid(tester,
        on: day.addDays(9), onCreateRequested: (s, e) => asked.add((s, e)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(tester.getCenter(find.byType(DayGrid)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(la.dateOf(asked.single.$1), day.addDays(9));
    await unmount(tester);
  });

  testWidgets('the grid pages no further than the mirror window',
      (tester) async {
    // Today is Oct 7; the window's last day is today + daysForward. Opened on
    // that day, a swipe on has nowhere to go.
    final last = day.addDays(DayPane.daysForward);
    final changed = <CalendarDate>[];
    await pumpGrid(tester, on: last, onVisibleDayChanged: changed.add);
    expect(find.byType(DayGrid), findsOneWidget);

    await swipeLeft(tester);
    expect(changed, isEmpty);

    // And the week grid, opened on the window's first week, has no week
    // before it: a swipe back reports nothing earlier than the window.
    final first = day.addDays(-DayPane.daysBack);
    await pumpGrid(tester,
        on: first, span: GridSpan.week, onVisibleDayChanged: changed.add);
    await tester.fling(find.byType(DayGrid), const Offset(600, 0), 1500);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (final d in changed) {
      expect(d.isBefore(mondayOf(first)), isFalse, reason: '$d');
    }
    await unmount(tester);
  });

  testWidgets('a zone change rebuilds the configuration in the new zone',
      (tester) async {
    await pumpGrid(tester);
    final before = tester.widget<KalenderView>(find.byType(KalenderView));
    expect((before.viewConfiguration.initialDateTime! as tz.TZDateTime)
        .location
        .name, 'America/Los_Angeles');

    final auckland = CalendarZone.tryNamed('Pacific/Auckland')!;
    await pumpGrid(tester, zone: auckland);
    final after = tester.widget<KalenderView>(find.byType(KalenderView));
    expect(after.location!.name, 'Pacific/Auckland');
    final initial = after.viewConfiguration.initialDateTime! as tz.TZDateTime;
    expect(initial.location.name, 'Pacific/Auckland',
        reason: 'the first day and the window are local dates');
    expect(auckland.dateOf(initial.toUtc()), day);
    await unmount(tester);
  });

  testWidgets('the first build reports no page change', (tester) async {
    final changed = <CalendarDate>[];
    await pumpGrid(tester, onVisibleDayChanged: changed.add);
    await tester.pump(const Duration(milliseconds: 300));
    expect(changed, isEmpty);

    // Nor does a host that moves the day itself: the jump lands where the
    // host already is.
    await pumpGrid(tester,
        on: day.addDays(1), onVisibleDayChanged: changed.add);
    await tester.pump(const Duration(milliseconds: 300));
    expect(changed, isEmpty);

    // Nor a switch of span either way: Thursday stays Thursday, never the
    // week's Monday.
    final both = [
      own('mon', 'Contoso Monday', DateTime.utc(2026, 10, 5, 17)),
      own('thu', 'Fabrikam Thursday', DateTime.utc(2026, 10, 8, 17)),
    ];
    await pumpGrid(tester,
        on: day.addDays(1),
        span: GridSpan.week,
        events: both,
        onVisibleDayChanged: changed.add);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Contoso Monday'), findsOneWidget);
    await pumpGrid(tester,
        on: day.addDays(1), events: both, onVisibleDayChanged: changed.add);
    await tester.pump(const Duration(milliseconds: 300));
    expect(changed, isEmpty);
    expect(find.text('Fabrikam Thursday'), findsOneWidget);
    expect(find.text('Contoso Monday'), findsNothing);
    await unmount(tester);
  });

  testWidgets('the week shows tiles from two different days', (tester) async {
    await pumpGrid(tester, span: GridSpan.week, events: [
      own('mon', 'Contoso Monday', DateTime.utc(2026, 10, 5, 17)),
      own('fri', 'Fabrikam Friday', DateTime.utc(2026, 10, 9, 17)),
      // The next Monday is another week.
      own('next', 'Next week', DateTime.utc(2026, 10, 12, 17)),
    ]);

    expect(find.text('Contoso Monday'), findsOneWidget);
    expect(find.text('Fabrikam Friday'), findsOneWidget);
    expect(find.text('Next week'), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('mon'))).dx,
      lessThan(tester.getTopLeft(find.byKey(DayGrid.tileKeyFor('fri'))).dx),
    );
    await unmount(tester);
  });
}
