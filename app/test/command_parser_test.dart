import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_parser.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// One command read into its slots, synchronously. `now` is FIXED: Wednesday
/// 2026-10-14 10:42 in Los Angeles. Fictional people and meetings.
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

  final events = <CalendarEvent>[];
  setUp(() {
    events
      ..clear()
      ..addAll([
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
        CalendarEvent(
          id: 'standup',
          subject: 'Standup',
          startUtc: at(const CalendarDate(2026, 10, 19), 9),
          endUtc: at(const CalendarDate(2026, 10, 19), 9, 15),
        ),
      ]);
  });

  ParsedCommand parse(String text) =>
      parseCommand(text, now: now, zone: la, people: people, events: events);

  group('slot coverage per action', () {
    // text → (action, day, time, people addresses, first event id or null)
    final table = <String,
        (CommandAction, CalendarDate?, (int, int)?, List<String>, String?)>{
      'book design sync with Dana Thu 3pm': (
        CommandAction.create,
        const CalendarDate(2026, 10, 15),
        (15, 0),
        ['dana@contoso.com'],
        null,
      ),
      'move my 3pm to Thursday': (
        CommandAction.move,
        const CalendarDate(2026, 10, 15),
        (15, 0),
        [],
        'three',
      ),
      "cancel Monday's standup": (
        CommandAction.cancel,
        const CalendarDate(2026, 10, 19),
        null,
        [],
        'standup',
      ),
      'accept the design sync': (
        CommandAction.rsvpYes,
        null,
        null,
        [],
        'three',
      ),
      'find 30 min with Lee next week': (
        CommandAction.findTime,
        const CalendarDate(2026, 10, 19),
        null,
        ['lee@fabrikam.com'],
        null,
      ),
      'am I free Friday at 2': (
        CommandAction.askFree,
        const CalendarDate(2026, 10, 16),
        (14, 0),
        [],
        null,
      ),
      "what's on tomorrow": (
        CommandAction.askAgenda,
        const CalendarDate(2026, 10, 15),
        null,
        [],
        null,
      ),
      'when did I last meet Dana': (
        CommandAction.askPerson,
        null,
        null,
        ['dana@contoso.com'],
        null,
      ),
    };

    for (final MapEntry(key: text, value: want) in table.entries) {
      test(text, () {
        final p = parse(text);
        final (action, day, time, addresses, event) = want;
        expect(p.action, action);
        expect(p.when.day, day);
        expect(p.when.time, time);
        expect([for (final m in p.people.matched) m.address], addresses);
        expect(p.events.isEmpty ? null : p.events.first.event.id, event);
      });
    }
  });

  group('the leftover subject', () {
    test('verb, when, people and filler out; the rest is the subject', () {
      expect(parse('book design sync with Dana Thu 3pm').subject,
          'design sync');
      expect(parse('please schedule a budget review meeting for me tomorrow '
              'in my calendar')
          .subject,
          'budget review');
    });

    test('quoted text is the subject verbatim, and never a when', () {
      final p = parse('book "Friday retro" Thu 3pm');
      expect(p.subject, 'Friday retro');
      expect(p.quotedSubject, isTrue);
      expect(p.when.day, const CalendarDate(2026, 10, 15));
    });

    test('a duration is read and taken out', () {
      final p = parse('book 45 min planning with Lee tomorrow');
      expect(p.duration, const Duration(minutes: 45));
      expect(p.subject, 'planning');
    });
  });

  group('the move split', () {
    test('"to" divides which meeting from where it goes', () {
      final p = parse('move my 3pm with Dana to tomorrow morning');
      expect(p.eventWhen.time, (15, 0));
      expect(p.eventWhen.day, isNull);
      expect(p.targetText, 'to tomorrow morning');
      expect(p.events.first.event.id, 'three');
    });

    test("a possessive when is the meeting, and the rest the target", () {
      final p = parse("reschedule tomorrow's 1:1");
      expect(p.eventWhen.day, const CalendarDate(2026, 10, 15));
      expect(p.targetText.trim(), '1:1');
      expect(p.unresolved, contains(CommandSlot.when));
    });

    test('with no reference, the whole text is the target', () {
      final p = parse('push the design sync to 4pm');
      expect(p.eventWhen.isEmpty, isTrue);
      expect(p.targetText, 'to 4pm');
      expect(p.events.first.event.id, 'three');
    });
  });

  group('unresolved', () {
    test('no verb: the action', () {
      expect(parse('design sync notes').unresolved,
          contains(CommandSlot.action));
    });

    test('create with no day or time: the when; with no words: the subject',
        () {
      final p = parse('book a meeting');
      expect(p.unresolved, {CommandSlot.when, CommandSlot.subject});
    });

    test('an agenda defaults to today, so its when is never unresolved', () {
      final p = parse("what's on");
      expect(p.unresolved, isEmpty);
      expect(agendaDay(p), today);
    });

    test('find a time or ask about a person with nobody named: the people',
        () {
      expect(parse('find time next week').unresolved,
          {CommandSlot.people});
      expect(parse('when did I last meet').unresolved, {CommandSlot.people});
    });

    test('an ambiguous name is not unresolved — the planner asks', () {
      final p = parseCommand('find time with Dana',
          now: now,
          zone: la,
          people: const [
            dana,
            KnownPerson(name: 'Dana Kim', address: 'dkim@fabrikam.com'),
          ],
          events: events);
      expect(p.unresolved, isEmpty);
      expect(p.people.ambiguous.single, hasLength(2));
    });

    test('a move, cancel or answer with no matching meeting: the event', () {
      expect(parse('cancel the budget review').unresolved,
          {CommandSlot.event});
    });
  });

  group('leftoverAfterResolvers', () {
    test('words left AND a slot unresolved', () {
      final p = parse('cancel the budget review');
      expect(p.leftoverWords, ['budget', 'review']);
      expect(p.leftoverAfterResolvers, isTrue);
    });

    test('nothing unresolved: false, whatever is left', () {
      expect(parse('cancel the design sync').leftoverAfterResolvers, isFalse);
    });

    test("a create's leftover words are its subject, so explained", () {
      final p = parse('book design review');
      expect(p.unresolved, {CommandSlot.when});
      expect(p.leftoverAfterResolvers, isFalse);
    });

    test('no words left: false', () {
      expect(parse('book a meeting').leftoverAfterResolvers, isFalse);
    });
  });

  test('a given guess wins over the lexicon, and sets the mode', () {
    final p = parseCommand('Wednesday',
        now: now,
        zone: la,
        people: people,
        events: events,
        guess: const CommandGuess(
            CommandAction.askAgenda, 0.95, CommandPath.head));
    expect(p.guess.path, CommandPath.head);
    // Question mode: "Wednesday" on a Wednesday is today.
    expect(p.when.day, today);
    expect(p.guess.mode, WhenMode.question);
  });
}
