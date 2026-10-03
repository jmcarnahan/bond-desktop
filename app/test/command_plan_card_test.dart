import 'dart:async';

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
import 'package:bond_inbox/services/calendar/write_rules.dart'
    show writeSummary;
import 'package:bond_inbox/theme/tokens.dart' show BondColors;
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

/// Previews private, and commits only when the test completes [hold]: a
/// write still in the air while the host does something else.
class _HeldWriter implements CalendarWriter {
  final Completer<WriteOutcome> hold = Completer();
  final List<CalendarWrite> committed = [];

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    const p = WritePreview(method: 'POST', path: '/x');
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) {
    committed.add(write);
    return hold.future;
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
      bool subjectEditable = false,
      ValueChanged<String>? onSubjectChanged,
      int flash = 0,
      ValueChanged<bool>? onWritingChanged,
      List<KnownPerson> people = const [],
      Future<List<KnownPerson>> Function(String query)? searchPeople,
      ValueChanged<List<String>>? onAttendeesChanged,
      List<String> initialAttendees = const [],
      String? initialSubject,
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
            subjectEditable: subjectEditable,
            onSubjectChanged: onSubjectChanged,
            flash: flash,
            onWritingChanged: onWritingChanged,
            people: people,
            searchPeople: searchPeople,
            onAttendeesChanged: onAttendeesChanged,
            initialAttendees: initialAttendees,
            initialSubject: initialSubject,
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

  group('a blank event', () {
    CalendarProposal blank() {
      final write = CreateEvent.propose(
          subject: 'New event', startUtc: start, endUtc: end);
      return CalendarProposal(
        write: write,
        preview: const WritePreview(method: 'POST', path: '/x'),
        summary: writeSummary(write,
            shown: const CalendarEvent(id: ''),
            series: false,
            zone: la,
            today: today),
        doneMessage: 'Added.',
        needsConfirm: false,
        startUtc: start,
        endUtc: end,
      );
    }

    testWidgets('the name field is drawn only when the host asks',
        (tester) async {
      await pumpCard(tester, blank());
      expect(find.byKey(CommandPlanCard.subjectKey), findsNothing);
      await pumpCard(tester, blank(), subjectEditable: true);
      expect(find.byKey(CommandPlanCard.subjectKey), findsOneWidget);
      // Never on a move, whatever the host says.
      await pumpCard(tester, move(), subjectEditable: true);
      expect(find.byKey(CommandPlanCard.subjectKey), findsNothing);
    });

    testWidgets('typing re-words the summary, and the press writes the name '
        'under the proposal\'s own transaction id', (tester) async {
      final writer = _FakeWriter();
      final p = blank();
      await pumpCard(tester, p, writer: writer, subjectEditable: true);
      expect(
          tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data,
          contains('New event'));

      await tester.enterText(find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await tester.pump();
      final summary =
          tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data!;
      expect(summary, contains('Dentist'));
      expect(summary, isNot(contains('New event')));

      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await tester.pump();
      await tester.pump();
      final written = writer.committed.single as CreateEvent;
      expect(written.subject, 'Dentist');
      expect(written.transactionId, (p.write as CreateEvent).transactionId);
      expect(written.attendees, isEmpty);
      expect(written.startUtc, start);
      // The toast says the typed name, not the proposal's.
      expect(done.single.message, contains('Dentist'));
    });

    testWidgets('the name is reported as it is typed', (tester) async {
      final names = <String>[];
      await pumpCard(tester, blank(),
          subjectEditable: true, onSubjectChanged: names.add);
      await tester.enterText(find.byKey(CommandPlanCard.subjectKey), 'Dentist');
      await tester.pump();
      expect(names, ['Dentist']);
    });

    testWidgets('an emptied name writes the default', (tester) async {
      final writer = _FakeWriter();
      await pumpCard(tester, blank(), writer: writer, subjectEditable: true);
      await tester.enterText(find.byKey(CommandPlanCard.subjectKey), '  ');
      await tester.pump();
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await tester.pump();
      await tester.pump();
      expect((writer.committed.single as CreateEvent).subject, 'New event');
    });

    String fieldText(WidgetTester tester, Key key) =>
        tester.widget<TextField>(find.byKey(key)).controller!.text;

    String summaryText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(CommandPlanCard.summaryKey)).data!;

    testWidgets('the name field starts empty under its hint, and the summary '
        'says the default meanwhile', (tester) async {
      await pumpCard(tester, blank(), subjectEditable: true);
      expect(fieldText(tester, CommandPlanCard.subjectKey), isEmpty);
      expect(find.text('Name this event'), findsOneWidget);
      expect(summaryText(tester), contains('"New event"'));
    });

    testWidgets('typing key by key gives the typed name, never one appended '
        'to the default', (tester) async {
      final names = <String>[];
      await pumpCard(tester, blank(),
          subjectEditable: true, onSubjectChanged: names.add);
      await tester.showKeyboard(find.byKey(CommandPlanCard.subjectKey));
      // Each key lands where the cursor is, as a keyboard's would — not
      // `enterText`, which replaces the whole field.
      for (final ch in 'Lunch'.split('')) {
        final v = tester
            .widget<TextField>(find.byKey(CommandPlanCard.subjectKey))
            .controller!
            .value;
        final at = v.selection.isValid
            ? v.selection
            : TextSelection.collapsed(offset: v.text.length);
        tester.testTextInput.updateEditingValue(v.replaced(at, ch));
        await tester.pump();
        expect(summaryText(tester), isNot(contains('New event')));
      }
      expect(fieldText(tester, CommandPlanCard.subjectKey), 'Lunch');
      expect(summaryText(tester), contains('"Lunch"'));
      expect(names, ['L', 'Lu', 'Lun', 'Lunc', 'Lunch']);
    });

    testWidgets('a re-proposal under a typed name starts with that name',
        (tester) async {
      final write = CreateEvent.propose(
          subject: 'Lunch', startUtc: start, endUtc: end);
      await pumpCard(
        tester,
        CalendarProposal(
          write: write,
          preview: const WritePreview(method: 'POST', path: '/x'),
          summary: 'Create "Lunch"',
          doneMessage: 'Added.',
          needsConfirm: false,
          startUtc: start,
          endUtc: end,
        ),
        subjectEditable: true,
      );
      expect(fieldText(tester, CommandPlanCard.subjectKey), 'Lunch');
    });

    testWidgets('the fields are off while the write is out', (tester) async {
      final writer = _HeldWriter();
      await pumpCard(tester, blank(), writer: writer, subjectEditable: true);
      bool enabled(Key key) =>
          tester.widget<TextField>(find.byKey(key)).enabled ?? true;
      expect(enabled(CommandPlanCard.subjectKey), isTrue);
      await tester.tap(find.byKey(CommandPlanCard.doKey));
      await tester.pump();
      await tester.pump();
      expect(writer.committed, hasLength(1));
      expect(enabled(CommandPlanCard.subjectKey), isFalse);
      expect(enabled(CommandPlanCard.withKey), isFalse);
      writer.hold.complete(const WriteOutcome.ok());
      await tester.pump();
      await tester.pump();
      expect(enabled(CommandPlanCard.subjectKey), isTrue);
    });

    group('a ghost tap flashes the card and leaves what is in it standing',
        () {
      testWidgets('a typed name', (tester) async {
        final names = <String>[];
        await pumpCard(tester, blank(),
            subjectEditable: true, onSubjectChanged: names.add);
        await tester.enterText(find.byKey(CommandPlanCard.subjectKey), 'Lunch');
        await tester.pump();
        await pumpCard(tester, blank(),
            subjectEditable: true, onSubjectChanged: names.add, flash: 1);
        await tester.pump(const Duration(milliseconds: 100));
        expect(fieldText(tester, CommandPlanCard.subjectKey), 'Lunch');
        expect(summaryText(tester), contains('"Lunch"'));
        expect(names, ['Lunch']);
      });

      testWidgets('a standing confirm strip', (tester) async {
        final writer = _FakeWriter(notifies: const ['dana@contoso.com']);
        final p = move(notifies: const ['dana@contoso.com']);
        await pumpCard(tester, p, writer: writer);
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(WriteConfirmStrip), findsOneWidget);
        await pumpCard(tester, p, writer: writer, flash: 1);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(WriteConfirmStrip), findsOneWidget);
        await tester.ensureVisible(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.pump();
        await tester.pump();
        expect(writer.committed.single, isA<MoveEvent>());
      });

      testWidgets('a write in the air, which still says when it is done',
          (tester) async {
        final writing = <bool>[];
        final writer = _HeldWriter();
        final p = move();
        await pumpCard(tester, p,
            writer: writer, onWritingChanged: writing.add);
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(writing, [true]);
        await pumpCard(tester, p,
            writer: writer, onWritingChanged: writing.add, flash: 1);
        await tester.pump(const Duration(milliseconds: 100));
        writer.hold.complete(const WriteOutcome.ok());
        await tester.pump();
        await tester.pump();
        expect(writing, [true, false]);
        expect(done, hasLength(1));
      });
    });

    group('the With line', () {
      const dana = KnownPerson(name: 'Dana Reyes', address: 'dana@example.com');
      const danaPark =
          KnownPerson(name: 'Dana Park', address: 'dana.park@fabrikam.com');
      const sam = KnownPerson(name: 'Sam Okafor', address: 'sam@contoso.com');
      const priya =
          KnownPerson(name: 'Priya Shah', address: 'priya@example.org');
      const directory = [dana, danaPark, sam];

      late List<List<String>> attendees;
      setUp(() => attendees = []);

      Future<void> type(WidgetTester tester, String text) async {
        await tester.enterText(find.byKey(CommandPlanCard.withKey), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.pump();
      }

      Future<void> pumpBlank(WidgetTester tester,
              {CalendarWriter? writer,
              Future<List<KnownPerson>> Function(String)? searchPeople,
              List<String> initialAttendees = const []}) =>
          pumpCard(tester, blank(),
              writer: writer,
              subjectEditable: true,
              people: directory,
              searchPeople: searchPeople,
              onAttendeesChanged: attendees.add,
              initialAttendees: initialAttendees);

      testWidgets('only on a blank event', (tester) async {
        await pumpCard(tester, blank());
        expect(find.byKey(CommandPlanCard.withKey), findsNothing);
        await pumpCard(tester, blank(), subjectEditable: true);
        expect(find.byKey(CommandPlanCard.withKey), findsOneWidget);
        expect(find.text('With — a name or address'), findsOneWidget);
      });

      testWidgets('a known first name is a chip, told up as its address',
          (tester) async {
        await pumpBlank(tester);
        await type(tester, 'Sam');
        expect(find.byKey(CommandPlanCard.chipKeyFor('sam@contoso.com')),
            findsOneWidget);
        expect(find.text('Sam Okafor'), findsOneWidget);
        expect(attendees.last, ['sam@contoso.com']);
        expect(fieldText(tester, CommandPlanCard.withKey), isEmpty);
      });

      testWidgets('a comma takes the name too', (tester) async {
        await pumpBlank(tester);
        await tester.enterText(find.byKey(CommandPlanCard.withKey), 'Sam,');
        await tester.pump();
        expect(attendees.last, ['sam@contoso.com']);
      });

      testWidgets('a bare address is a chip under that address',
          (tester) async {
        await pumpBlank(tester);
        await type(tester, 'Lee@Northwind.com');
        expect(find.byKey(CommandPlanCard.chipKeyFor('lee@northwind.com')),
            findsOneWidget);
        expect(attendees.last, ['lee@northwind.com']);
      });

      testWidgets('a first name two people share asks which, and a press '
          'picks one', (tester) async {
        await pumpBlank(tester);
        await type(tester, 'Dana');
        expect(find.text('Dana Reyes · dana@example.com'), findsOneWidget);
        expect(find.text('Dana Park · dana.park@fabrikam.com'), findsOneWidget);
        expect(attendees, isEmpty);
        await tester.tap(find.text('Dana Park · dana.park@fabrikam.com'));
        await tester.pump();
        expect(find.byKey(CommandPlanCard.candidateKeyFor(0)), findsNothing);
        expect(attendees.last, ['dana.park@fabrikam.com']);
      });

      testWidgets('an unknown name is looked up, and one hit is a chip',
          (tester) async {
        final asked = <String>[];
        await pumpBlank(tester, searchPeople: (q) async {
          asked.add(q);
          return [priya];
        });
        await type(tester, 'Priya');
        expect(asked, ['Priya']);
        expect(attendees.last, ['priya@example.org']);
        expect(find.byKey(CommandPlanCard.unknownPersonKey), findsNothing);
      });

      testWidgets('several hits are buttons to pick from', (tester) async {
        await pumpBlank(tester,
            searchPeople: (q) async => [
                  priya,
                  const KnownPerson(
                      name: 'Priya Rao', address: 'priya.rao@contoso.com'),
                ]);
        await type(tester, 'Priya');
        expect(find.byKey(CommandPlanCard.candidateKeyFor(1)), findsOneWidget);
        expect(attendees, isEmpty);
      });

      testWidgets('a name nobody has is said in the planner\'s words',
          (tester) async {
        await pumpBlank(tester, searchPeople: (q) async => const []);
        await type(tester, 'Priya');
        expect(find.text(unknownPersonSentence('Priya')), findsOneWidget);
        expect(attendees, isEmpty);
        // With no directory search at all, the same.
        await pumpCard(tester, blank(),
            subjectEditable: true, people: directory);
        await type(tester, 'Morgan');
        expect(find.text(unknownPersonSentence('Morgan')), findsOneWidget);
      });

      testWidgets('a name known only in part is not the part it knows',
          (tester) async {
        await pumpBlank(tester, searchPeople: (q) async => const []);
        await type(tester, 'Dana Kim');
        expect(find.text(unknownPersonSentence('Dana Kim')), findsOneWidget);
        expect(attendees, isEmpty);
      });

      testWidgets('with a guest the card says who it may email, the press '
          'waits on the strip, and Send writes the guest under the same '
          'transaction id', (tester) async {
        final writer = _FakeWriter();
        final p = blank();
        await pumpCard(tester, p,
            writer: writer, subjectEditable: true, people: directory);
        await type(tester, 'Sam');
        expect(find.text('This may email: sam@contoso.com'), findsOneWidget);
        expect(
          find.descendant(
              of: find.byKey(CommandPlanCard.doKey),
              matching: find.text('Send')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(WriteConfirmStrip), findsOneWidget);
        expect(
            find.descendant(
                of: find.byType(WriteConfirmStrip),
                matching: find.text('This may email: sam@contoso.com')),
            findsOneWidget);
        expect(writer.committed, isEmpty);
        await tester.ensureVisible(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.pump();
        await tester.pump();
        final written = writer.committed.single as CreateEvent;
        expect(written.attendees, ['sam@contoso.com']);
        expect(written.isOnlineMeeting, isTrue);
        expect(written.transactionId, (p.write as CreateEvent).transactionId);
        expect(done.single.message, contains('Emails go to sam@contoso.com'));
        expect(done.single.undo, isNull);
      });

      testWidgets('with nobody the press writes at once', (tester) async {
        final writer = _FakeWriter();
        await pumpCard(tester, blank(),
            writer: writer, subjectEditable: true, people: directory);
        expect(find.byKey(CommandPlanCard.emailsKey), findsNothing);
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(WriteConfirmStrip), findsNothing);
        expect((writer.committed.single as CreateEvent).attendees, isEmpty);
      });

      testWidgets('the × takes a chip off and says so', (tester) async {
        final writer = _FakeWriter();
        await pumpBlank(tester, writer: writer);
        await type(tester, 'Sam');
        await tester.tap(find.byTooltip('Remove sam@contoso.com'));
        await tester.pump();
        expect(find.byKey(CommandPlanCard.chipKeyFor('sam@contoso.com')),
            findsNothing);
        expect(attendees.last, isEmpty);
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(WriteConfirmStrip), findsNothing);
        expect((writer.committed.single as CreateEvent).attendees, isEmpty);
      });

      testWidgets('a re-proposal\'s card starts from the name as typed, not '
          'its write\'s subject', (tester) async {
        await pumpCard(tester, blank(),
            subjectEditable: true, initialSubject: 'Dentist');
        expect(fieldText(tester, CommandPlanCard.subjectKey), 'Dentist');
      });

      testWidgets('a name typed without Enter is taken at the press: a '
          'known one invites them', (tester) async {
        final writer = _FakeWriter();
        await pumpBlank(tester, writer: writer);
        await tester.enterText(find.byKey(CommandPlanCard.withKey), 'Sam');
        await tester.pump();
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(WriteConfirmStrip), findsOneWidget,
            reason: 'an invite confirms; it is not a private event');
        await tester.ensureVisible(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.pump();
        await tester.pump();
        expect((writer.committed.single as CreateEvent).attendees,
            ['sam@contoso.com']);
      });

      testWidgets('a name typed without Enter that nobody has stops the '
          'press, said', (tester) async {
        final writer = _FakeWriter();
        await pumpBlank(tester,
            writer: writer, searchPeople: (q) async => const []);
        await tester.enterText(find.byKey(CommandPlanCard.withKey), 'Quinn');
        await tester.pump();
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(CommandPlanCard.unknownPersonKey), findsOneWidget);
        expect(writer.committed, isEmpty);
        expect(find.byType(WriteConfirmStrip), findsNothing);
      });

      testWidgets('Do it waits while a directory lookup is out',
          (tester) async {
        final lookup = Completer<List<KnownPerson>>();
        await pumpBlank(tester, searchPeople: (q) => lookup.future);
        await type(tester, 'Priya');
        final button =
            tester.widget<FilledButton>(find.byKey(CommandPlanCard.doKey));
        expect(button.onPressed, isNull);
        lookup.complete([priya]);
        await tester.pump();
        await tester.pump();
        expect(
            tester
                .widget<FilledButton>(find.byKey(CommandPlanCard.doKey))
                .onPressed,
            isNotNull);
        expect(attendees.last, ['priya@example.org']);
      });

      testWidgets('a directory search that fails says so, never that nobody '
          'has the name', (tester) async {
        await pumpBlank(tester,
            searchPeople: (q) async => throw StateError('offline'));
        await type(tester, 'Priya');
        expect(find.text(CommandPlanCard.directoryFailedText), findsOneWidget);
        expect(find.textContaining("I don't know who"), findsNothing);
        expect(attendees, isEmpty);
      });

      testWidgets('a re-proposal\'s guests start as chips', (tester) async {
        final writer = _FakeWriter();
        await pumpBlank(tester,
            writer: writer, initialAttendees: const ['dana@example.com']);
        expect(find.byKey(CommandPlanCard.chipKeyFor('dana@example.com')),
            findsOneWidget);
        expect(find.text('Dana Reyes'), findsOneWidget);
        await tester.tap(find.byKey(CommandPlanCard.doKey));
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
        await tester.pump();
        await tester.pump();
        expect((writer.committed.single as CreateEvent).attendees,
            ['dana@example.com']);
      });
    });
  });

  testWidgets('the host is told while the real write goes out', (tester) async {
    final writing = <bool>[];
    final writer = _FakeWriter(notifies: const ['dana@contoso.com']);
    await pumpCard(tester, move(notifies: const ['dana@contoso.com']),
        writer: writer, onWritingChanged: writing.add);
    await tester.tap(find.byKey(CommandPlanCard.doKey));
    await tester.pump();
    expect(writing, isEmpty, reason: 'the dry run and the strip are not it');
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await tester.pump();
    await tester.pump();
    expect(writing, [true, false]);
  });

  testWidgets('a flash runs once and comes to rest', (tester) async {
    Color border() => ((tester
                .widget<Container>(find.byKey(CommandPlanCard.flashKey))
                .decoration! as BoxDecoration)
            .border! as Border)
        .top
        .color;
    await pumpCard(tester, move());
    expect(border(), BondColors.border);
    await pumpCard(tester, move(), flash: 1);
    await tester.pump(const Duration(milliseconds: 50));
    expect(border(), isNot(BondColors.border));
    await tester.pump(const Duration(milliseconds: 700));
    expect(border(), BondColors.border);
  });

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
