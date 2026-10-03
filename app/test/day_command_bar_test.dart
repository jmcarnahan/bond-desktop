import 'dart:async';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_parser.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/theme/tokens.dart' show BondTone;
import 'package:bond_inbox/widgets/chips.dart' show BondChip;
import 'package:bond_inbox/widgets/day_command_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

/// The Day command bar, prop-only, over the REAL synchronous parser with a
/// fixed clock: Wednesday 2026-10-14 10:42 in Los Angeles. Fictional people
/// and meetings.
void main() {
  late CalendarZone la;
  late DateTime now;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
  });

  const today = CalendarDate(2026, 10, 14);
  const dana = KnownPerson(name: 'Dana Whitfield', address: 'dana@contoso.com');
  const lee = KnownPerson(name: 'Lee Park', address: 'lee@fabrikam.com');
  const people = [dana, lee];

  DateTime at(CalendarDate d, int h, [int m = 0]) {
    final t = la.localDateTime(d, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  List<CalendarEvent> events() => [
        CalendarEvent(
          id: 'three',
          subject: 'Design sync',
          isOrganizer: true,
          startUtc: at(today, 15),
          endUtc: at(today, 15, 30),
          attendees: const [
            Attendee(name: 'Dana Whitfield', address: 'dana@contoso.com'),
          ],
        ),
      ];

  late List<String> submitted;
  late int cleared;
  late int screenEscapes;

  setUp(() {
    submitted = [];
    cleared = 0;
    screenEscapes = 0;
  });

  Widget bar({
    bool busy = false,
    String? initialText,
    bool planStands = false,
    Future<CommandGuess?> Function(String text)? refine,
  }) =>
      MaterialApp(
        home: Scaffold(
          // The screen's own Escape, which the bar must leave alone when it
          // has nothing to clear.
          body: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  screenEscapes++,
            },
            child: SizedBox(
              width: 800,
              child: DayCommandBar(
                preview: (text, {guess}) => parseCommand(text,
                    now: now,
                    zone: la,
                    people: people,
                    events: events(),
                    guess: guess),
                refine: refine,
                submit: (text) async => submitted.add(text),
                zone: la,
                clock: () => now,
                initialText: initialText,
                onCleared: () => cleared++,
                busy: busy,
                planStands: planStands,
              ),
            ),
          ),
        ),
      );

  String chip(WidgetTester tester, String kind) =>
      tester.widget<BondChip>(find.byKey(DayCommandBar.chipKeyFor(kind))).label!;

  BondTone tone(WidgetTester tester, String kind) =>
      tester.widget<BondChip>(find.byKey(DayCommandBar.chipKeyFor(kind))).tone;

  Finder field() => find.byKey(DayCommandBar.fieldKey);

  testWidgets('the hint names an example, and empty text draws no preview',
      (tester) async {
    await tester.pumpWidget(bar());
    expect(find.text(DayCommandBar.hint), findsOneWidget);
    expect(find.byKey(DayCommandBar.previewKey), findsNothing);
  });

  testWidgets('the preview waits out the debounce, then follows each '
      'keystroke', (tester) async {
    await tester.pumpWidget(bar());

    await tester.enterText(field(), 'move');
    await tester.pump();
    expect(find.byKey(DayCommandBar.previewKey), findsNothing,
        reason: 'nothing is read inside the 150 ms wait');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'action'), 'Move');
    // A move with nowhere to go yet asks where, tinted.
    expect(chip(tester, 'when'), 'to when?');
    expect(tone(tester, 'when'), BondTone.attention);

    await tester.enterText(field(), 'move my 3pm with Dana to tomorrow morning');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'action'), 'Move');
    expect(chip(tester, 'when'), 'Thu Oct 15 morning');
    expect(chip(tester, 'people'), 'Dana Whitfield');
    expect(chip(tester, 'event'), 'Design sync · 3:00 PM');

    await tester.enterText(
        field(), 'book 45 min with Dana and Lee tomorrow at 2pm');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'action'), 'Create');
    expect(chip(tester, 'when'), 'Thu Oct 15 · 2:00 PM');
    expect(chip(tester, 'people'), 'Dana Whitfield, Lee Park');
    expect(chip(tester, 'duration'), '45 min');
    expect(find.byKey(DayCommandBar.chipKeyFor('event')), findsNothing);

    // A name nobody in the mail has reads as a question, not a person.
    await tester.enterText(field(), 'find time with Priya next week');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'people'), 'Priya?');

    await tester.enterText(field(), '');
    await tester.pump();
    expect(find.byKey(DayCommandBar.previewKey), findsNothing);
    expect(submitted, isEmpty, reason: 'typing never submits');
  });

  testWidgets('Enter submits once', (tester) async {
    await tester.pumpWidget(bar());
    await tester.enterText(field(), "what's on tomorrow");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, ["what's on tomorrow"]);
    expect(chip(tester, 'action'), 'Agenda',
        reason: 'Enter reads the preview at once, without the wait');
  });

  testWidgets("a move's when chip is where it goes; the time it is at rides "
      'on the meeting', (tester) async {
    await tester.pumpWidget(bar());

    await tester.enterText(field(), 'move my 3pm to Thursday');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'when'), 'Thu Oct 15');
    expect(tone(tester, 'when'), BondTone.neutral);
    expect(chip(tester, 'event'), 'Design sync · 3:00 PM');

    // A bare hour is not a destination yet.
    await tester.enterText(field(), 'move my 3pm to 4');
    await tester.pump(DayCommandBar.debounce);
    expect(tone(tester, 'when'), BondTone.attention);
    expect(chip(tester, 'event'), 'Design sync · 3:00 PM');

    // A shift says which way, and is not a length.
    await tester.enterText(field(), 'move my 3pm by an hour');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'when'), '1 h later');
    expect(tone(tester, 'when'), BondTone.neutral);
    expect(find.byKey(DayCommandBar.chipKeyFor('duration')), findsNothing);
    await tester.enterText(field(), 'move my 3pm back 30 min');
    await tester.pump(DayCommandBar.debounce);
    expect(chip(tester, 'when'), '30 min earlier');
  });

  testWidgets('editing the text away from what was submitted drops the plan',
      (tester) async {
    await tester.pumpWidget(bar());
    await tester.enterText(field(), "what's on tomorrow");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(cleared, 0);
    await tester.enterText(field(), "what's on Friday");
    await tester.pump();
    expect(cleared, 1);
    // Once: further typing has no plan left to drop.
    await tester.enterText(field(), "what's on Friday at");
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('Escape with nothing to clear is left for the screen; with a '
      'plan standing it drops the plan', (tester) async {
    await tester.pumpWidget(bar());
    await tester.tap(field());
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cleared, 0);
    expect(screenEscapes, 1);

    await tester.pumpWidget(bar(planStands: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cleared, 1);
    expect(screenEscapes, 1, reason: 'the bar took this one');
  });

  testWidgets('Escape clears the text and the preview and tells the host',
      (tester) async {
    await tester.pumpWidget(bar());
    await tester.enterText(field(), 'cancel my 3pm');
    await tester.pump(DayCommandBar.debounce);
    expect(find.byKey(DayCommandBar.previewKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
    expect(find.byKey(DayCommandBar.previewKey), findsNothing);
    expect(cleared, 1);
    expect(submitted, isEmpty);
    expect(screenEscapes, 0, reason: 'there was text to clear');
  });

  testWidgets('while busy, Enter does nothing and the field spins',
      (tester) async {
    await tester.pumpWidget(bar(busy: true));
    expect(find.byKey(DayCommandBar.busyKey), findsOneWidget);
    await tester.enterText(field(), "what's on tomorrow");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isEmpty);
  });

  testWidgets('handed text is written in and submitted once, a frame later',
      (tester) async {
    // The post-frame callback runs at the end of the frame that mounted it.
    await tester.pumpWidget(bar(initialText: "what's on tomorrow"));
    await tester.pump();
    expect(submitted, ["what's on tomorrow"]);
    expect(tester.widget<TextField>(field()).controller!.text,
        "what's on tomorrow");
    expect(chip(tester, 'action'), 'Agenda');

    // The host rebuilding with the same words does not ask again; cleared
    // and handed over again, it does.
    await tester.pumpWidget(bar(initialText: "what's on tomorrow"));
    await tester.pump();
    expect(submitted, hasLength(1));
    await tester.pumpWidget(bar());
    await tester.pumpWidget(bar(initialText: "what's on tomorrow"));
    await tester.pump();
    expect(submitted, hasLength(2));
  });

  group("the head's refine", () {
    // The lexicon has no rule for "put … on", so it names no action here.
    const unread = 'put the standup on friday 3pm';

    testWidgets('an answer for the words in the field re-reads the preview '
        'under its guess', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(bar(refine: (text) async {
        asked.add(text);
        return const CommandGuess(CommandAction.move, 0.93, CommandPath.head);
      }));
      await tester.enterText(field(), unread);
      await tester.pump(DayCommandBar.debounce);
      expect(find.byKey(DayCommandBar.chipKeyFor('action')), findsNothing,
          reason: "the lexicon's chips come first, and it read no action");
      expect(asked, isEmpty, reason: 'the head waits a further 200 ms');
      await tester.pump(DayCommandBar.refineDebounce);
      await tester.pump();
      expect(asked, [unread]);
      expect(chip(tester, 'action'), 'Move');
    });

    testWidgets('an unknown or a throw leaves the lexicon\'s chips',
        (tester) async {
      var throwNext = false;
      await tester.pumpWidget(bar(refine: (text) async {
        if (throwNext) throw StateError('head down');
        return const CommandGuess(
            CommandAction.unknown, 0.4, CommandPath.head);
      }));
      await tester.enterText(field(), 'move my 3pm to Thursday');
      await tester.pump(DayCommandBar.debounce);
      await tester.pump(DayCommandBar.refineDebounce);
      await tester.pump();
      expect(chip(tester, 'action'), 'Move');
      throwNext = true;
      await tester.enterText(field(), unread);
      await tester.pump(DayCommandBar.debounce);
      await tester.pump(DayCommandBar.refineDebounce);
      await tester.pump();
      expect(find.byKey(DayCommandBar.chipKeyFor('action')), findsNothing);
    });

    testWidgets('an answer for older words is dropped; the bar asks for '
        'each settled text and leaves the one-out gate to the head',
        (tester) async {
      final pending = <String, Completer<CommandGuess?>>{};
      final asked = <String>[];
      await tester.pumpWidget(bar(refine: (text) {
        asked.add(text);
        return (pending[text] = Completer<CommandGuess?>()).future;
      }));

      await tester.enterText(field(), unread);
      await tester.pump(DayCommandBar.debounce);
      await tester.pump(DayCommandBar.refineDebounce);
      expect(asked, [unread]);

      // The words move on while the head is out. The bar asks again: how
      // many requests reach the server is the classifier's gate
      // (`DecisionCommandClassifier.classifyPreview`), not a second one here.
      const newer = 'put the retro on monday 10am';
      await tester.enterText(field(), newer);
      await tester.pump(DayCommandBar.debounce);
      await tester.pump(DayCommandBar.refineDebounce);
      expect(asked, [unread, newer]);

      pending[unread]!.complete(
          const CommandGuess(CommandAction.cancel, 0.95, CommandPath.head));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(DayCommandBar.chipKeyFor('action')), findsNothing,
          reason: 'the answer was for words no longer in the field');

      pending[newer]!.complete(
          const CommandGuess(CommandAction.move, 0.91, CommandPath.head));
      // One pump lands the answer, the next draws it.
      await tester.pump();
      await tester.pump();
      expect(chip(tester, 'action'), 'Move');
    });
  });

  group('chip labels', () {
    test('durations', () {
      expect(durationLabel(const Duration(minutes: 30)), '30 min');
      expect(durationLabel(const Duration(hours: 1)), '1 h');
      expect(durationLabel(const Duration(minutes: 90)), '1 h 30 min');
    });

    test('an ambiguous name counts who it could be', () {
      const other =
          KnownPerson(name: 'Dana Okafor', address: 'dana@fabrikam.com');
      expect(
        peopleChipLabel(const PeopleMatch(ambiguous: [
          [dana, other],
        ])),
        'Dana? (2)',
      );
    });

    test('meetings tied at the top are counted, not named', () {
      final e = events().single;
      expect(eventChipLabel([EventCandidate(e, 2)]), 'Design sync');
      expect(
        eventChipLabel([EventCandidate(e, 2), EventCandidate(e, 2)]),
        '2 matches',
      );
      expect(eventChipLabel(const []), isNull);
    });
  });
}
