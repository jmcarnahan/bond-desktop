import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_lexicon.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/command/command_router.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// `find_meeting_times` answers one slot at the start of whatever window it
/// is asked about; the planner's own tests cover the rest.
class _Backend extends Fake implements CalendarBackend {
  @override
  Future<List<MeetingTimeSuggestion>> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) async =>
      [
        MeetingTimeSuggestion(
          startUtc: windowStartUtc,
          endUtc: windowStartUtc.add(Duration(minutes: durationMinutes)),
          confidence: 100,
        ),
      ];
}

class _Writer implements CalendarWriter {
  final List<CalendarWrite> previews = [];

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previews.add(write);
    const p = WritePreview(method: 'POST', path: '/me/events');
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) =>
      throw UnimplementedError();
}

/// The directory: scripted hits per query, every query recorded.
class _People extends Fake implements PeopleBackend {
  final Map<String, List<Person>> hits = {};
  final List<String> queries = [];

  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    queries.add(query);
    return hits[query] ?? const [];
  }
}

/// A command head as the router sees one: a scripted guess, a null, or a
/// throw.
class _Head implements CommandClassifier {
  _Head(this.answer);

  final CommandGuess? Function() answer;
  final List<String> asked = [];

  @override
  Future<CommandGuess?> classify(String text) async {
    asked.add(text);
    return answer();
  }
}

void main() {
  late CalendarZone la;
  late DateTime now;
  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late ActivityLog activity;
  late _Writer writer;
  late _People directory;
  late ScriptedLlm llm;
  late CommandRouter router;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    // Wednesday 2026-10-14 10:42 in Los Angeles.
    now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
  });

  const today = CalendarDate(2026, 10, 14);
  const thu = CalendarDate(2026, 10, 15);
  const fri = CalendarDate(2026, 10, 16);
  const dana = KnownPerson(name: 'Dana Whitfield', address: 'dana@contoso.com');
  const known = [dana];

  DateTime at(CalendarDate d, int h, [int m = 0]) {
    final t = la.localDateTime(d, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  CalendarEvent mine(String id, CalendarDate d, int h, String subject) =>
      CalendarEvent(
        id: id,
        subject: subject,
        isOrganizer: true,
        organizerAddress: 'me@contoso.com',
        startUtc: at(d, h),
        endUtc: at(d, h, 30),
        changeKey: 'ck',
      );

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    activity = ActivityLog(store);
    writer = _Writer();
    directory = _People();
    llm = ScriptedLlm();
    router = CommandRouter(
      classifiers: const [LexiconClassifier()],
      planner: CommandPlanner(
        calendar: calendar,
        backend: _Backend(),
        writer: writer,
        mailbox: () async => null,
      ),
      intentClient: () => llm,
      people: directory,
      activityLog: activity,
    );
  });

  tearDown(() async {
    activity.dispose();
    await db.close();
  });

  Future<CommandOutcome> submit(
    String text, {
    List<CalendarEvent> events = const [],
    List<KnownPerson> people = known,
    List<CommandBind> binds = const [],
    CommandOutcome? resume,
  }) =>
      router.submit(text,
          now: now,
          zone: la,
          today: today,
          people: people,
          events: events,
          binds: binds,
          resume: resume);

  /// A press on [out]'s choice [i], the host's way: every bind so far plus
  /// this one, resuming the outcome it answered.
  Future<CommandOutcome> press(
    String text,
    CommandOutcome out,
    int i, {
    List<CommandBind> before = const [],
    List<CalendarEvent> events = const [],
  }) =>
      submit(text,
          events: events,
          binds: [...before, (out.plan as NeedsChoice).options[i].bind],
          resume: out);

  Map<String, dynamic> intent({
    String action = 'create',
    String when = '',
    List<String> people = const [],
    String subject = '',
    String eventRef = '',
    int duration = -1,
  }) =>
      {
        'action': action,
        'subject': subject,
        'people': people,
        'event_ref': eventRef,
        'when': when,
        'duration_min': duration,
        'constraints': const <String>[],
      };

  test('the preview is the synchronous parse, and never asks a model', () {
    final p = router.preview('move my 3pm to Thursday',
        now: now, zone: la, people: known, events: const []);
    expect(p.action, CommandAction.move);
    expect(p.when.day, thu);
    expect(llm.calls, isEmpty);
  });

  test('a clear command makes no model call at all', () async {
    final three = mine('three', today, 15, 'Design sync');
    final out = await submit('move my 3pm to Thursday', events: [three]);
    expect(llm.calls, isEmpty);
    expect(out.path, CommandPath.lexicon);
    final plan = out.plan as CalendarProposal;
    expect((plan.write as MoveEvent).startUtc, at(thu, 15));
  });

  test('an unclear one asks calendar_intent once, and Dart resolves the date',
      () async {
    llm.answer(
        'calendar_intent',
        intent(
          when: 'next Tuesday 3pm',
          people: ['Dana'],
          subject: 'design sync',
        ));
    const text = 'design sync w/ Dana next Tuesday 3pm pls';
    final out = await submit(text);
    expect(llm.callsFor('calendar_intent'), 1);
    expect(llm.calls, hasLength(1));
    expect(llm.userMessages.single, contains('Now: Wed 14 Oct 2026'));
    expect(out.path, CommandPath.generative);
    expect(out.parsed.action, CommandAction.create);
    final plan = out.plan as CalendarProposal;
    final create = plan.write as CreateEvent;
    // The model sent words; the instant is the resolver's.
    final resolved = resolveWhen('next Tuesday 3pm',
        now: now, zone: la, mode: WhenMode.booking);
    expect(create.startUtc, resolved.startUtc);
    expect(create.startUtc, at(const CalendarDate(2026, 10, 20), 15));
    expect(create.attendees, ['dana@contoso.com']);
    expect(create.subject, 'design sync');
  });

  test("a phrase the model did not copy from the request is dropped",
      () async {
    // The model "helpfully" normalises a date and invents a person.
    llm.answer(
        'calendar_intent',
        intent(
          when: 'Oct 20 3pm',
          people: ['Priya Shah'],
        ));
    final out = await submit('catch up w/ Dana sometime');
    expect(llm.calls, hasLength(1));
    expect(out.parsed.when.isEmpty, isTrue);
    expect(out.parsed.people.unresolved, isEmpty);
    expect(directory.queries, isEmpty);
    // No time in the request: openings, never a proposal at a made-up time.
    expect(out.plan, isA<SlotChoice>());
    expect(writer.previews, isEmpty);
  });

  group('the model unavailable', () {
    test('an unreadable request says the model is off', () async {
      llm.answer('calendar_intent', const LlmUnavailableException('down'));
      final out = await submit('design sync notes');
      expect((out.plan as CannotDo).reason, modelOffSentence);
      expect(out.path, CommandPath.lexicon);
    });

    test('a weak but readable one falls back to the rules', () async {
      llm.answer('calendar_intent', const LlmUnavailableException('down'));
      final out = await submit('invite Dana to lunch Friday');
      expect(llm.calls, hasLength(1));
      expect(out.path, CommandPath.lexicon);
      expect(out.parsed.action, CommandAction.create);
      expect(out.plan, isA<SlotChoice>());
    });
  });

  group('names the mail does not know', () {
    test('one directory hit with a mailbox binds', () async {
      directory.hits['Priya'] = const [
        Person(id: 'u1', displayName: 'Priya Shah', mail: 'priya@contoso.com'),
      ];
      final out = await submit('book planning with Priya Friday 2pm');
      expect(directory.queries, ['Priya']);
      final create = (out.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['priya@contoso.com']);
      expect(create.startUtc, at(fri, 14));
    });

    test('several ask, and the pressed one binds without a second search',
        () async {
      directory.hits['Sam'] = const [
        Person(id: 'u1', displayName: 'Sam Ortiz', mail: 'sam@contoso.com'),
        Person(id: 'u2', displayName: 'Sam Lee', mail: 'slee@fabrikam.com'),
      ];
      final first = await submit('book planning with Sam Friday 2pm');
      final choice = first.plan as NeedsChoice;
      expect(choice.question, 'Which Sam?');
      expect(choice.options.map((o) => o.label), [
        'Sam Ortiz · sam@contoso.com',
        'Sam Lee · slee@fabrikam.com',
      ]);

      final second = await press('book planning with Sam Friday 2pm', first, 1);
      expect(directory.queries, ['Sam']);
      final create = (second.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['slee@fabrikam.com']);
    });

    test('a create whose name nobody has: the words go back into the subject',
        () async {
      final out = await submit('book lunch with Design team Friday 2pm');
      expect(directory.queries, ['Design']);
      final create = (out.plan as CalendarProposal).write as CreateEvent;
      expect(create.subject, 'lunch with Design team');
      expect(create.attendees, isEmpty);
      expect(create.startUtc, at(fri, 14));
      // With no time: openings for the same title, never a refusal.
      final slots = await submit('book lunch with Design team Friday');
      expect((slots.plan as SlotChoice).title,
          'Pick a time for "lunch with Design team"');
    });

    test('a find-a-time or a question about a name nobody has: a sentence',
        () async {
      final find = await submit('find time with Priya tomorrow');
      expect(directory.queries, ['Priya']);
      expect((find.plan as CannotDo).reason,
          "I don't know who Priya is — name someone from your mail.");
      final ask = await submit('when did I last meet Priya');
      expect((ask.plan as CannotDo).reason,
          "I don't know who Priya is — name someone from your mail.");
    });

    test('a hit binds by its mail first; a guest #EXT# name or no address '
        'at all is not bindable', () async {
      expect(
          directoryAddress(const Person(
              id: 'u1',
              displayName: 'Priya Shah',
              mail: 'Priya@Contoso.com',
              userPrincipalName: 'pshah@contoso.onmicrosoft.com')),
          'priya@contoso.com');
      expect(
          directoryAddress(const Person(
              id: 'u2',
              displayName: 'Priya Shah',
              userPrincipalName: 'pshah@contoso.com')),
          'pshah@contoso.com');
      expect(
          directoryAddress(const Person(
              id: 'u3',
              displayName: 'Guest',
              userPrincipalName: 'guest_fabrikam.com#EXT#@contoso.com')),
          isNull);
      expect(directoryAddress(const Person(id: 'u4', displayName: 'Room')),
          isNull);

      // Two hits for one person, one a guest placeholder: one bindable, so
      // it binds without asking.
      directory.hits['Priya'] = const [
        Person(
            id: 'u1',
            displayName: 'Priya Shah',
            userPrincipalName: 'priya_fabrikam.com#EXT#@contoso.com'),
        Person(id: 'u2', displayName: 'Priya Shah', mail: 'priya@fabrikam.com'),
      ];
      final out = await submit('book planning with Priya Friday 2pm');
      final create = (out.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['priya@fabrikam.com']);
    });

    test('a pick settles the NAME it answers, even when the display name '
        'does not contain it', () async {
      directory.hits['Bob'] = const [
        Person(id: 'u1', displayName: 'Robert Smith', mail: 'rsmith@contoso.com'),
        Person(id: 'u2', displayName: 'Bob Jones', mail: 'bjones@contoso.com'),
      ];
      const text = 'book planning with Bob Friday 2pm';
      final first = await submit(text);
      final choice = first.plan as NeedsChoice;
      expect(choice.options.first.bind.answers, 'Bob');
      final second = await press(text, first, 0);
      final create = (second.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['rsmith@contoso.com']);
      expect(second.parsed.people.unresolved, isEmpty);
      expect(directory.queries, ['Bob']);
    });

    test('two ambiguous names, two presses: a plan, not a loop', () async {
      directory.hits['Sam'] = const [
        Person(id: 'u1', displayName: 'Sam Ortiz', mail: 'sam@contoso.com'),
        Person(id: 'u2', displayName: 'Sam Lee', mail: 'slee@fabrikam.com'),
      ];
      directory.hits['Bob'] = const [
        Person(id: 'u3', displayName: 'Robert Smith', mail: 'rsmith@contoso.com'),
        Person(id: 'u4', displayName: 'Bob Jones', mail: 'bjones@contoso.com'),
      ];
      const text = 'book planning with Sam and Bob Friday 2pm';
      final first = await submit(text);
      expect((first.plan as NeedsChoice).question, 'Which Sam?');
      final sam = (first.plan as NeedsChoice).options[1].bind;
      final second = await press(text, first, 1);
      expect((second.plan as NeedsChoice).question, 'Which Bob?');
      final third = await press(text, second, 0, before: [sam]);
      final create = (third.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['slee@fabrikam.com', 'rsmith@contoso.com']);
      // Each name searched once, the presses included.
      expect(directory.queries, ['Sam', 'Bob']);
    });
  });

  test('a choice press re-plans without asking the model again', () async {
    directory.hits['Sam'] = const [
      Person(id: 'u1', displayName: 'Sam Ortiz', mail: 'sam@contoso.com'),
      Person(id: 'u2', displayName: 'Sam Lee', mail: 'slee@fabrikam.com'),
    ];
    llm.answer(
        'calendar_intent',
        intent(
          when: 'next Tuesday 3pm',
          people: ['Sam'],
          subject: 'design sync',
        ));
    const text = 'design sync w/ Sam next Tuesday 3pm pls';
    final first = await submit(text);
    expect(llm.calls, hasLength(1));
    expect(first.path, CommandPath.generative);
    expect((first.plan as NeedsChoice).question, 'Which Sam?');
    final second = await press(text, first, 0);
    expect(llm.calls, hasLength(1), reason: 'the press asked nobody');
    expect(second.path, CommandPath.generative);
    final create = (second.plan as CalendarProposal).write as CreateEvent;
    expect(create.attendees, ['sam@contoso.com']);
    expect(create.subject, 'design sync');
    expect(create.startUtc, at(const CalendarDate(2026, 10, 20), 15));
  });

  group('the literal-phrase guard', () {
    test('a name the model shortened is not in the request, so nobody is '
        'bound by it', () async {
      const danB = KnownPerson(name: 'Dan Brooks', address: 'dan@contoso.com');
      llm.answer('calendar_intent', intent(people: ['Dan']));
      final out =
          await submit('lunch with Danielle Friday 2pm', people: const [danB]);
      expect(llm.calls, hasLength(1));
      expect(directory.queries, isNot(contains('Dan')));
      expect(out.parsed.people.matched, isEmpty);
      final create = (out.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, isEmpty);
    });

    test('a name genuinely copied is kept and looked up', () async {
      directory.hits['danielle'] = const [
        Person(
            id: 'u1', displayName: 'Danielle Ortiz', mail: 'dortiz@contoso.com'),
      ];
      llm.answer('calendar_intent', intent(people: ['danielle']));
      final out = await submit('lunch friday 2pm danielle');
      expect(directory.queries, ['danielle']);
      final create = (out.plan as CalendarProposal).write as CreateEvent;
      expect(create.attendees, ['dortiz@contoso.com']);
    });
  });

  test('a clear verb with a slot missing and words left over asks the model '
      'once — and an answer that adds nothing leaves the path lexicon',
      () async {
    final three = mine('three', today, 15, 'Design sync');
    llm.answer('calendar_intent', intent(action: 'move'));
    final out =
        await submit('move my 3pm somewhere quieter', events: [three]);
    expect(llm.callsFor('calendar_intent'), 1);
    expect(llm.calls, hasLength(1));
    expect(out.path, CommandPath.lexicon);
    expect((out.plan as CannotDo).reason, sayWhenSentence);
  });

  test('a bound event wins over the tie it answered', () async {
    final a = mine('a', thu, 9, 'Standup');
    final b = mine('b', fri, 9, 'Standup');
    final first = await submit('move the standup to 4pm', events: [a, b]);
    expect(first.plan, isA<NeedsChoice>());
    final second = await submit('move the standup to 4pm',
        events: [a, b],
        binds: [(person: null, event: b, answers: null)],
        resume: first);
    final move = (second.plan as CalendarProposal).write as MoveEvent;
    expect(move.eventId, 'b');
    expect(move.startUtc, at(fri, 16));
  });

  group('the command head in front of the lexicon', () {
    CommandRouter headed(_Head head) => CommandRouter(
          classifiers: [head, const LexiconClassifier()],
          planner: CommandPlanner(
            calendar: calendar,
            backend: _Backend(),
            writer: writer,
            mailbox: () async => null,
          ),
          intentClient: () => llm,
          people: directory,
          activityLog: activity,
        );

    Future<CommandOutcome> headedSubmit(CommandRouter r, String text,
            {List<CalendarEvent> events = const []}) =>
        r.submit(text,
            now: now, zone: la, today: today, people: known, events: events);

    test('a head above its bar wins over the lexicon, on the head path',
        () async {
      final head = _Head(() =>
          const CommandGuess(CommandAction.move, 0.9, CommandPath.head));
      final three = mine('three', today, 15, 'Design sync');
      // The lexicon reads nothing here ("put … on" is not one of its rules).
      expect(classifyByLexicon('put my 3pm on Thursday').action,
          CommandAction.unknown);
      final out = await headedSubmit(headed(head), 'put my 3pm on Thursday',
          events: [three]);
      expect(head.asked, ['put my 3pm on Thursday']);
      expect(out.path, CommandPath.head);
      expect(out.parsed.action, CommandAction.move);
      expect(llm.calls, isEmpty, reason: 'a head at 0.9 needs no model');
      final rows = [
        for (final r in await store.recentActivity(limit: 10))
          if (r['kind'] == 'calendar_command') r,
      ];
      final detail = jsonDecode(rows.single['detail_json'] as String)
          as Map<String, dynamic>;
      expect(detail['path'], 'head');
      expect(detail['action'], 'move');
    });

    test('a head under its bar (unknown) falls through to the lexicon',
        () async {
      final head = _Head(() =>
          const CommandGuess(CommandAction.unknown, 0.41, CommandPath.head));
      final three = mine('three', today, 15, 'Design sync');
      final out = await headedSubmit(headed(head), 'move my 3pm to Thursday',
          events: [three]);
      expect(head.asked, hasLength(1));
      expect(out.path, CommandPath.lexicon);
      expect(out.parsed.action, CommandAction.move);
    });

    test('a head that is not there (null) or throws falls through', () async {
      final three = mine('three', today, 15, 'Design sync');
      for (final head in [
        _Head(() => null),
        _Head(() => throw StateError('the decision server went away')),
      ]) {
        final out = await headedSubmit(
            headed(head), 'move my 3pm to Thursday',
            events: [three]);
        expect(out.path, CommandPath.lexicon);
        expect(out.parsed.action, CommandAction.move);
      }
    });

    test("the preview takes the head's guess when the caller has one", () {
      final p = router.preview('put my 3pm on Thursday',
          now: now,
          zone: la,
          people: known,
          events: const [],
          guess:
              const CommandGuess(CommandAction.move, 0.9, CommandPath.head));
      expect(p.action, CommandAction.move);
      expect(p.guess.path, CommandPath.head);
    });
  });

  test('every Enter writes one activity row, in enum words only', () async {
    final three = mine('three', today, 15, 'Design sync');
    await submit('move my 3pm to Thursday', events: [three]);
    final rows = [
      for (final r in await store.recentActivity(limit: 10))
        if (r['kind'] == 'calendar_command') r,
    ];
    final detail =
        jsonDecode(rows.single['detail_json'] as String) as Map<String, dynamic>;
    expect(detail, {'action': 'move', 'path': 'lexicon', 'outcome': 'proposal'});
    // Nothing the person typed rides along.
    expect(rows.single.toString(), isNot(contains('Design')));
    expect(rows.single.toString(), isNot(contains('3pm')));
  });
}
