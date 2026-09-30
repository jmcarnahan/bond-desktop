import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/find_time.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/widgets/find_time_pane.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

/// Answers every dry run with [notifies] and every commit with success.
class _FakeWriter implements CalendarWriter {
  _FakeWriter({this.notifies = const []});

  final List<String> notifies;
  final List<CalendarWrite> previewed = [];
  final List<CalendarWrite> committed = [];

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
    final p = WritePreview(method: 'POST', path: '/x', notifies: notifies);
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    committed.add(write);
    return WriteOutcome.ok();
  }
}

typedef _Call = ({List<String> addresses, int minutes, FindTimeWindow window});

/// The Find a time pane, prop-only: its people, length and week pills
/// re-search; its slots go into the reply as one line or out as an invite
/// through the confirm strip. Fictional people; the zone is Los Angeles,
/// and Tue Oct 20 2026 is in PDT.
void main() {
  late CalendarZone la;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  const today = CalendarDate(2026, 10, 14);
  // Tue Oct 20, 10:00–10:30 AM and 2:00–2:30 PM in Los Angeles.
  final a = FreeSlot(
      DateTime.utc(2026, 10, 20, 17), DateTime.utc(2026, 10, 20, 17, 30));
  final b = FreeSlot(
      DateTime.utc(2026, 10, 20, 21), DateTime.utc(2026, 10, 20, 21, 30));

  const dana = (name: 'Dana Lee', address: 'dana@fabrikam.example');
  const sam = (name: 'Sam Ortiz', address: 'sam@fabrikam.example');

  late List<_Call> calls;
  late List<String> put;
  late List<String> done;
  late List<bool> invitedFlags;

  setUp(() {
    calls = [];
    put = [];
    done = [];
    invitedFlags = [];
  });

  Future<void> pumpPane(
    WidgetTester tester, {
    FindTimeResult Function(_Call call)? answer,
    CalendarWriter? writer,
    List<FindTimePerson> people = const [dana, sam],
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 700,
          child: FindTimePane(
            subject: 'Quarterly planning',
            participants: people,
            zone: la,
            today: today,
            search: ({
              required addresses,
              required durationMinutes,
              required window,
            }) async {
              final call = (
                addresses: addresses,
                minutes: durationMinutes,
                window: window,
              );
              calls.add(call);
              return (answer ??
                  (_) => FindTimeResult(slots: [a, b], source: 'graph'))(call);
            },
            onPutInReply: put.add,
            writer: writer ?? _FakeWriter(),
            onDone: (message, undo, invited) {
              done.add(message);
              invitedFlags.add(invited);
            },
            onBack: () {},
            onHome: () {},
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(FindTimePane.debounce);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('searches on open with everyone, and draws the slots with '
      'their overlaps', (tester) async {
    await pumpPane(tester, answer: (_) => FindTimeResult(
          slots: [a, b],
          source: 'graph',
          overlaps: {
            a: Overlaps(hard: [
              CalendarEvent(
                  id: 'x',
                  subject: 'Budget review',
                  startUtc: a.startUtc,
                  endUtc: a.endUtc),
            ]),
            b: const Overlaps(),
          },
        ));
    expect(calls.single.addresses, [dana.address, sam.address]);
    expect(calls.single.minutes, 30);
    expect(calls.single.window, FindTimeWindow.thisWeek);
    expect(find.text('Tue Oct 20 · 10:00–10:30 AM'), findsOneWidget);
    expect(find.text('Tue Oct 20 · 2:00–2:30 PM'), findsOneWidget);
    expect(find.byKey(FindTimePane.overlapKeyFor(0)), findsOneWidget);
    expect(find.text('⚠ overlaps Budget review'), findsOneWidget);
    expect(find.byKey(FindTimePane.overlapKeyFor(1)), findsNothing);
  });

  testWidgets('the length and week pills search again with what they say',
      (tester) async {
    await pumpPane(tester);
    await tester.tap(find.byKey(FindTimePane.durationKeyFor(45)));
    await tester.pump();
    expect(find.byKey(FindTimePane.lookingKey), findsOneWidget);
    await settle(tester);
    expect(calls.last.minutes, 45);

    await tester.tap(find.byKey(FindTimePane.windowKeyFor(
        FindTimeWindow.nextWeek)));
    await settle(tester);
    expect(calls.last.window, FindTimeWindow.nextWeek);
    expect(calls.last.minutes, 45);
    expect(calls, hasLength(3));
  });

  testWidgets('changes inside the debounce make one search', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.byKey(FindTimePane.durationKeyFor(45)));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(FindTimePane.durationKeyFor(60)));
    await settle(tester);
    expect(calls, hasLength(2));
    expect(calls.last.minutes, 60);
  });

  testWidgets('leaving people out searches with fewer, then with nobody',
      (tester) async {
    await pumpPane(tester);
    await tester.tap(find.byKey(FindTimePane.removePersonKeyFor(sam.address)));
    await settle(tester);
    expect(calls.last.addresses, [dana.address]);

    await tester.tap(find.byKey(FindTimePane.removePersonKeyFor(dana.address)));
    await settle(tester);
    expect(calls.last.addresses, isEmpty);
    expect(find.byKey(FindTimePane.justYouKey), findsOneWidget);
  });

  testWidgets('Put these in the reply writes one line naming every slot '
      'with its zone', (tester) async {
    await pumpPane(tester);
    await tester.tap(find.byKey(FindTimePane.putAllKey));
    await tester.pump();
    expect(put, [
      'Would any of these work? · Tue 20 Oct 10:00–10:30 AM PDT · '
          'Tue 20 Oct 2:00–2:30 PM PDT',
    ]);
  });

  testWidgets('Send invite waits on the strip naming who it emails, and '
      'Enter sends it to the people on the pane', (tester) async {
    final writer = _FakeWriter(notifies: [dana.address, sam.address]);
    await pumpPane(tester, writer: writer);
    await tester.tap(find.byKey(FindTimePane.inviteKeyFor(1)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WriteConfirmStrip), findsOneWidget);
    expect(
        find.text('This emails: ${dana.address}, ${sam.address}'),
        findsOneWidget);
    expect(writer.committed, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    final write = writer.committed.single as CreateEvent;
    expect(write.attendees, [dana.address, sam.address]);
    expect(write.subject, 'Re: Quarterly planning');
    expect(write.startUtc, b.startUtc);
    expect(write.isOnlineMeeting, isTrue);
    expect(done.single, startsWith('Created "Re: Quarterly planning".'));
    expect(invitedFlags, [true]);
  });

  testWidgets('with nobody on it the slot is added to the calendar, and the '
      'host is told nobody was invited', (tester) async {
    final writer = _FakeWriter();
    await pumpPane(tester, writer: writer, people: const []);
    expect(find.text('Add to calendar'), findsWidgets);
    await tester.tap(find.byKey(FindTimePane.inviteKeyFor(0)));
    await tester.pump();
    await tester.pump();
    final write = writer.committed.single as CreateEvent;
    expect(write.attendees, isEmpty);
    expect(done, hasLength(1));
    expect(invitedFlags, [false]);
  });

  testWidgets('before the zone resolves the pane waits, and keeps Back',
      (tester) async {
    var backs = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 700,
          child: FindTimePane.waiting(onBack: () => backs++, onHome: () {}),
        ),
      ),
    ));
    expect(find.byKey(FindTimePane.waitingKey), findsOneWidget);
    await tester.tap(find.byKey(FindTimePane.backKey));
    expect(backs, 1);
  });

  testWidgets('nothing found says so and points at the other week',
      (tester) async {
    await pumpPane(tester,
        answer: (_) => const FindTimeResult(source: 'graph'));
    expect(find.byKey(FindTimePane.emptyKey), findsOneWidget);
    expect(find.text('No time when everyone is free this week. '
        'Try next week.'), findsOneWidget);
    expect(find.byKey(FindTimePane.putAllKey), findsNothing);
  });

  testWidgets('the note says when only your calendar was read',
      (tester) async {
    await pumpPane(tester,
        answer: (_) => FindTimeResult(
            slots: [a], source: 'local', note: findTimeLocalNote));
    expect(find.byKey(FindTimePane.noteKey), findsOneWidget);
    expect(find.text(findTimeLocalNote), findsOneWidget);
    expect(find.text('Tue Oct 20 · 10:00–10:30 AM'), findsOneWidget);
  });

  testWidgets('a failed search shows its sentence and no false all-clear',
      (tester) async {
    await pumpPane(tester,
        answer: (_) => const FindTimeResult(
            source: 'graph', note: "Couldn't reach the calendar."));
    expect(find.text("Couldn't reach the calendar."), findsOneWidget);
    expect(find.byKey(FindTimePane.emptyKey), findsNothing);
  });

  group('the windows', () {
    // Wed Oct 14 2026, 3:00 PM PDT.
    final wed = DateTime.utc(2026, 10, 14, 22);

    test('this week runs from now to Friday 6 PM; next week is Mon–Fri',
        () {
      final w = findTimeWindowUtc(FindTimeWindow.thisWeek, now: wed, zone: la);
      expect(w.startUtc, wed);
      expect(w.endUtc, DateTime.utc(2026, 10, 17, 1)); // Fri 6 PM PDT
      expect(w.lastDay, const CalendarDate(2026, 10, 16));
      final n = findTimeWindowUtc(FindTimeWindow.nextWeek, now: wed, zone: la);
      expect(n.startUtc, DateTime.utc(2026, 10, 19, 15)); // Mon 8 AM PDT
      expect(n.endUtc, DateTime.utc(2026, 10, 24, 1));
    });

    test('on a weekend this week means the coming one', () {
      final sat = DateTime.utc(2026, 10, 17, 18);
      final w = findTimeWindowUtc(FindTimeWindow.thisWeek, now: sat, zone: la);
      expect(w.startUtc, DateTime.utc(2026, 10, 19, 15));
      final n = findTimeWindowUtc(FindTimeWindow.nextWeek, now: sat, zone: la);
      expect(n.startUtc, DateTime.utc(2026, 10, 26, 15));
    });

    test('this week is over once the meeting no longer fits before Friday '
        '6 PM', () {
      // Fri Oct 16 2026, 5:45 PM PDT: fifteen minutes left.
      final late = DateTime.utc(2026, 10, 17, 0, 45);
      final monday = DateTime.utc(2026, 10, 19, 15); // Mon 8 AM PDT
      expect(
          findTimeWindowUtc(FindTimeWindow.thisWeek,
                  now: late, zone: la, durationMinutes: 30)
              .startUtc,
          monday,
          reason: '30 min does not fit in 15');
      expect(
          findTimeWindowUtc(FindTimeWindow.thisWeek,
                  now: late, zone: la, durationMinutes: 15)
              .startUtc,
          late,
          reason: '15 min fits exactly');
      expect(
          findTimeWindowUtc(FindTimeWindow.nextWeek,
                  now: late, zone: la, durationMinutes: 30)
              .startUtc,
          DateTime.utc(2026, 10, 26, 15),
          reason: 'next week moves with this week');
    });

    test('across the clocks going back, 8 AM stays 8 AM', () {
      // Fri Oct 30 2026 after hours: next week holds Nov 2 (PST).
      final fri = DateTime.utc(2026, 10, 31, 2); // Fri 7 PM PDT
      final w = findTimeWindowUtc(FindTimeWindow.thisWeek, now: fri, zone: la);
      expect(w.startUtc, DateTime.utc(2026, 11, 2, 16)); // Mon 8 AM PST
    });
  });

  test('the invite subject and the reply line', () {
    expect(findTimeSubject('Planning'), 'Re: Planning');
    expect(findTimeSubject('RE: Planning'), 'RE: Planning');
    expect(findTimeSubject('  '), 'Meeting');
    expect(findTimeSubject(null), 'Meeting');
  });
}
