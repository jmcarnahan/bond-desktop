import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/day_items.dart'
    show offlineCaption;
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/widgets/command_plan_card.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every dry run with [notifies] and every commit with success —
/// with an Undo for a move, as the real writer offers one.
class _FakeWriter implements CalendarWriter {
  _FakeWriter({this.notifies = const []});

  final List<String> notifies;
  final List<CalendarWrite> previewed = [];
  final List<CalendarWrite> committed = [];

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
    final p = WritePreview(method: 'PATCH', path: '/x', notifies: notifies);
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    committed.add(write);
    return WriteOutcome.ok(
      undo: write is MoveEvent
          ? MoveEvent.timed(write.eventId,
              startUtc: DateTime.utc(2026, 10, 14, 22),
              endUtc: DateTime.utc(2026, 10, 14, 22, 30))
          : null,
    );
  }
}

/// Every plan kind the card draws, prop-only. Fictional meetings; the zone
/// is Los Angeles, and Oct 15 2026 is a Thursday.
void main() {
  late CalendarZone la;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  const today = CalendarDate(2026, 10, 14);
  // Thu Oct 15, 3:00–3:30 PM in Los Angeles.
  final start = DateTime.utc(2026, 10, 15, 22);
  final end = DateTime.utc(2026, 10, 15, 22, 30);

  late List<({String message, CalendarWrite? undo})> done;
  late int dismissed;
  late List<FreeSlot> picked;
  late List<CommandOption> chosen;
  late List<String> opened;

  setUp(() {
    done = [];
    dismissed = 0;
    picked = [];
    chosen = [];
    opened = [];
  });

  Future<void> pumpCard(WidgetTester tester, CommandPlan plan,
      {CalendarWriter? writer,
      CalendarAvailability availability =
          CalendarAvailability.available}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          child: CommandPlanCard(
            plan: plan,
            zone: la,
            today: today,
            writer: writer ?? _FakeWriter(),
            onDone: (message, undo) =>
                done.add((message: message, undo: undo)),
            onDismiss: () => dismissed++,
            onPickSlot: (choice, slot) async => picked.add(slot),
            onChoose: (option) async => chosen.add(option),
            onOpenEvent: opened.add,
            availability: availability,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  CalendarProposal move({List<String> notifies = const []}) {
    final write = MoveEvent.timed('own-1', startUtc: start, endUtc: end);
    return CalendarProposal(
      write: write,
      preview: WritePreview(method: 'PATCH', path: '/x', notifies: notifies),
      summary: 'Move "Design sync" to Thu Oct 15 · 3:00–3:30 PM?',
      doneMessage: 'Moved "Design sync".',
      needsConfirm: notifies.isNotEmpty,
      startUtc: start,
      endUtc: end,
      overlaps: Overlaps(hard: [
        CalendarEvent(
            id: 'x', subject: 'Budget review', startUtc: start, endUtc: end),
      ]),
      notifies: notifies,
    );
  }

  testWidgets('a proposal that emails says who, and waits on the strip',
      (tester) async {
    final writer = _FakeWriter(notifies: const ['dana@contoso.com']);
    await pumpCard(tester, move(notifies: const ['dana@contoso.com']),
        writer: writer);

    expect(find.text('Move "Design sync" to Thu Oct 15 · 3:00–3:30 PM?'),
        findsOneWidget);
    expect(find.text('⚠ overlaps Budget review'), findsOneWidget);
    expect(find.text('This emails: dana@contoso.com'), findsOneWidget);
    expect(
      find.descendant(
          of: find.byKey(CommandPlanCard.doKey), matching: find.text('Send')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WriteConfirmStrip), findsOneWidget);
    expect(writer.committed, isEmpty);
    // Said once, by the strip, while it is up.
    expect(find.byKey(CommandPlanCard.emailsKey), findsNothing);

    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await tester.pump();
    await tester.pump();
    expect(writer.committed.single, isA<MoveEvent>());
    expect(done.single.message, startsWith('Moved "Design sync".'));
  });

  testWidgets('a private proposal goes straight on and hands up its Undo',
      (tester) async {
    final writer = _FakeWriter();
    await pumpCard(tester, move(), writer: writer);
    expect(find.byKey(CommandPlanCard.emailsKey), findsNothing);
    expect(
      find.descendant(
          of: find.byKey(CommandPlanCard.doKey), matching: find.text('Do it')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(writer.previewed, hasLength(1),
        reason: 'the press runs the dry run again');
    expect(writer.committed, hasLength(1));
    expect(done.single.undo, isA<MoveEvent>());

    await tester.tap(find.byKey(CommandPlanCard.cancelKey));
    expect(dismissed, 1);
  });

  testWidgets('slots are buttons by date and time, and a press hands the '
      'slot up', (tester) async {
    final slots = [
      FreeSlot(start, end),
      FreeSlot(start.add(const Duration(hours: 1)),
          end.add(const Duration(hours: 1))),
    ];
    await pumpCard(
      tester,
      SlotChoice(
        slots: slots,
        buildWrite: (s) => CreateEvent.propose(
            subject: 'Design sync', startUtc: s.startUtc, endUtc: s.endUtc),
        title: 'Pick a time for "Design sync"',
        source: 'local',
      ),
    );

    expect(find.text('Pick a time for "Design sync"'), findsOneWidget);
    expect(find.text('Thu Oct 15 · 3:00–3:30 PM'), findsOneWidget);
    expect(find.text('Thu Oct 15 · 4:00–4:30 PM'), findsOneWidget);
    expect(find.text(CommandPlanCard.localCaption), findsOneWidget);

    await tester.tap(find.byKey(CommandPlanCard.slotKeyFor(1)));
    await tester.pump();
    expect(picked.single, slots[1]);
  });

  testWidgets('a choice is a button per option, and a press hands it up',
      (tester) async {
    const a = KnownPerson(name: 'Dana Whitfield', address: 'dana@contoso.com');
    const b = KnownPerson(name: 'Dana Okafor', address: 'dana@fabrikam.com');
    await pumpCard(
      tester,
      const NeedsChoice('Which Dana?', [
        CommandOption(
            label: 'Dana Whitfield · dana@contoso.com',
            bind: (person: a, event: null, answers: null)),
        CommandOption(
            label: 'Dana Okafor · dana@fabrikam.com',
            bind: (person: b, event: null, answers: null)),
      ]),
    );

    expect(find.text('Which Dana?'), findsOneWidget);
    await tester.tap(find.byKey(CommandPlanCard.optionKeyFor(1)));
    await tester.pump();
    expect(chosen.single.bind.person, b);

    await tester.tap(find.byKey(CommandPlanCard.cancelKey));
    expect(dismissed, 1);
  });

  testWidgets("an answer's links open their meeting, and ✕ dismisses",
      (tester) async {
    await pumpCard(
      tester,
      const Answer(
        'Thu Oct 15: 3:00–3:30 PM Design sync',
        links: [(label: 'Design sync', eventId: 'own-1')],
      ),
    );

    expect(find.text('Thu Oct 15: 3:00–3:30 PM Design sync'), findsOneWidget);
    await tester.tap(find.byKey(CommandPlanCard.linkKeyFor('own-1')));
    await tester.pump();
    expect(opened, ['own-1']);

    await tester.tap(find.byKey(CommandPlanCard.cancelKey));
    expect(dismissed, 1);
  });

  testWidgets('offline, a plan drawn from the mirror says it is the saved '
      'calendar; a reason does not', (tester) async {
    await pumpCard(tester, move(),
        availability: CalendarAvailability.unavailable);
    expect(find.text(offlineCaption), findsOneWidget);

    await pumpCard(tester, move());
    expect(find.text(offlineCaption), findsNothing);

    await pumpCard(tester, const CannotDo('That meeting is cancelled.'),
        availability: CalendarAvailability.unavailable);
    expect(find.text(offlineCaption), findsNothing,
        reason: 'a refusal read nothing from the calendar');
  });

  testWidgets('a reason is said, and ✕ dismisses', (tester) async {
    await pumpCard(
        tester, const CannotDo('Only the organiser can move that meeting.'));
    final reason = tester.widget<Text>(find.byKey(CommandPlanCard.reasonKey));
    expect(reason.data, 'Only the organiser can move that meeting.');
    await tester.tap(find.byKey(CommandPlanCard.cancelKey));
    expect(dismissed, 1);
  });
}
