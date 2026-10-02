import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_parser.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `find_meeting_times` as the planner calls it: the arguments recorded, the
/// answer (or the throw) scripted. Every other backend method is unused here
/// and throws.
class _Backend extends Fake implements CalendarBackend {
  final List<Map<String, Object?>> finds = [];
  Object answer = const <MeetingTimeSuggestion>[];

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
    String activityDomain = 'work',
  }) async {
    finds.add({
      'attendees': attendees,
      'duration': durationMinutes,
      'start': windowStartUtc,
      'end': windowEndUtc,
      'max': maxCandidates,
    });
    final a = answer;
    if (a is List<MeetingTimeSuggestion>) return MeetingTimes(suggestions: a);
    // An empty answer with Graph's reason.
    if (a is MeetingTimes) return a;
    throw a;
  }
}

/// A dry run that answers with [notifies] (or [fail]), recording each write.
class _Writer implements CalendarWriter {
  final List<CalendarWrite> previews = [];
  List<String> notifies = const [];
  String? fail;

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previews.add(write);
    final f = fail;
    if (f != null) return PreviewFailed(f);
    final p = WritePreview(method: 'POST', path: '/me/events', notifies: notifies);
    return PreviewReady(p, needsConfirm: needsConfirm(write, p));
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) =>
      throw UnimplementedError('the planner never commits');
}

void main() {
  late CalendarZone la;
  late DateTime now;
  late BondDatabase db;
  late CalendarStore calendar;
  late _Backend backend;
  late _Writer writer;
  late CommandPlanner planner;
  MailboxSettings? mailbox;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    // Wednesday 2026-10-14 10:42 in Los Angeles.
    now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
  });

  const today = CalendarDate(2026, 10, 14);
  const thu = CalendarDate(2026, 10, 15);
  const fri = CalendarDate(2026, 10, 16);
  const run = '2026-10-01T00:00:00.000000Z';
  const danaAddress = 'dana@contoso.com';
  const dana = KnownPerson(name: 'Dana Whitfield', address: danaAddress);
  const lee = KnownPerson(name: 'Lee Park', address: 'lee@fabrikam.com');

  DateTime at(CalendarDate d, int h, [int m = 0]) {
    final t = la.localDateTime(d, h, m);
    return DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch,
        isUtc: true);
  }

  CalendarEvent timed(
    String id,
    CalendarDate d,
    int h, {
    int minutes = 30,
    int startMinute = 0,
    String subject = 'Sync',
    bool organiser = true,
    List<String> guests = const [],
    String eventType = '',
    String organizerAddress = 'me@contoso.com',
  }) =>
      CalendarEvent(
        id: id,
        subject: subject,
        eventType: eventType,
        isOrganizer: organiser,
        organizerAddress: organizerAddress,
        showAs: 'busy',
        startUtc: at(d, h, startMinute),
        endUtc: at(d, h, startMinute).add(Duration(minutes: minutes)),
        changeKey: 'ck',
        attendees: [for (final g in guests) Attendee(name: g, address: g)],
      );

  setUp(() {
    db = testDb();
    calendar = CalendarStore(db);
    backend = _Backend();
    writer = _Writer();
    mailbox = null;
    planner = CommandPlanner(
      calendar: calendar,
      backend: backend,
      writer: writer,
      mailbox: () async => mailbox,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> store(List<CalendarEvent> events) =>
      calendar.upsertEvents(events, syncRun: run);

  Future<CommandPlan> plan(
    String text, {
    List<KnownPerson> people = const [dana, lee],
    List<CalendarEvent> events = const [],
  }) {
    final p =
        parseCommand(text, now: now, zone: la, people: people, events: events);
    return planner.plan(p, now: now, zone: la, today: today);
  }

  test('an unknown action cannot be done, and says what to try', () async {
    final r = await plan('design sync notes');
    expect((r as CannotDo).reason, didntCatchSentence);
  });

  group('move', () {
    test('to a day keeps the wall time, dry-runs, and names the overlap',
        () async {
      final three = timed('three', today, 15,
          subject: 'Design sync', guests: [danaAddress]);
      final clash = timed('clash', thu, 15, minutes: 60, subject: 'Budget');
      await store([three, clash]);
      final r = await plan('move my 3pm to Thursday', events: [three, clash])
          as CalendarProposal;
      final w = r.write as MoveEvent;
      expect(w.eventId, 'three');
      expect(w.startUtc, at(thu, 15));
      expect(w.endUtc, at(thu, 15, 30));
      expect(r.startUtc, at(thu, 15));
      expect(r.overlaps!.hard.map((e) => e.id), ['clash']);
      expect(r.targetEvent!.id, 'three');
      expect(r.summary, 'Move "Design sync" to Thu Oct 15 · 3:00–3:30 PM');
      expect(r.doneMessage, 'Moved "Design sync" to Thu Oct 15 · 3:00–3:30 PM.');
      expect(writer.previews, [w]);
    });

    test("an attendee's meeting cannot be moved", () async {
      final theirs = timed('t', thu, 11,
          subject: 'Kickoff', organiser: false, guests: ['me@contoso.com']);
      final r = await plan('move the kickoff to Friday', events: [theirs]);
      expect((r as CannotDo).reason, 'Only the organiser can move that meeting.');
      expect(writer.previews, isEmpty);
    });

    test('to a part of a day offers openings for its length, never a time',
        () async {
      final three = timed('three', today, 15, subject: 'Design sync');
      await store([three, timed('busy', thu, 9, minutes: 60)]);
      final r = await plan('move my 3pm to tomorrow morning', events: [three])
          as SlotChoice;
      expect(r.source, 'local');
      expect(r.targetEvent!.id, 'three');
      expect(r.slots.first.startUtc, at(thu, 10));
      expect(r.slots.every((s) => s.duration == const Duration(minutes: 30)),
          isTrue);
      final w = r.buildWrite(r.slots.first) as MoveEvent;
      expect(w.eventId, 'three');
      expect(writer.previews, isEmpty);
    });

    test('by a duration SHIFTS the meeting and keeps its length', () async {
      final three = timed('three', today, 15, subject: 'Design sync');
      await store([three]);
      final later = await plan('move my 3pm by an hour', events: [three])
          as CalendarProposal;
      final w = later.write as MoveEvent;
      expect(w.startUtc, at(today, 16));
      expect(w.endUtc, at(today, 16, 30));

      final back = await plan('move my 3pm back 30 min', events: [three])
          as CalendarProposal;
      final b = back.write as MoveEvent;
      expect(b.startUtc, at(today, 14, 30));
      expect(b.endUtc, at(today, 15));

      final after = await plan('move my 3pm 15 minutes later', events: [three])
          as CalendarProposal;
      expect((after.write as MoveEvent).startUtc, at(today, 15, 15));
      expect((after.write as MoveEvent).endUtc, at(today, 15, 45));
    });

    test('with nowhere to go: say when', () async {
      final three = timed('three', today, 15, subject: 'Design sync');
      final r = await plan('move my 3pm', events: [three]);
      expect((r as CannotDo).reason, sayWhenSentence);
      expect(sayWhenSentence,
          "Say when it moves to — e.g. 'to 4pm' or 'by an hour'.");
      // A length with no direction is not a shift, and never a new length.
      final lone = await plan('move my 3pm an hour', events: [three]);
      expect((lone as CannotDo).reason, sayWhenSentence);
      expect(writer.previews, isEmpty);
    });

    test('to a bare hour: add am or pm', () async {
      final three = timed('three', today, 15, subject: 'Design sync');
      final r = await plan('move my 3pm to 4', events: [three]);
      expect((r as CannotDo).reason, "Add am or pm — e.g. 'to 4pm'.");
      expect(writer.previews, isEmpty);
      final ok =
          await plan('move my 3pm to 4pm', events: [three]) as CalendarProposal;
      expect((ok.write as MoveEvent).startUtc, at(today, 16));
    });

    test('a named time that no meeting has is no meeting, not the nearest '
        'one', () async {
      final vendor = timed('vendor', today, 16, subject: 'Vendor call');
      final cancel = await plan('cancel my 3pm', events: [vendor]);
      expect((cancel as CannotDo).reason,
          "I couldn't find that meeting in the next two weeks.");
      final thursday =
          timed('thu', thu, 10, subject: 'Sync', guests: [danaAddress]);
      final move =
          await plan('move my 3pm with Dana to Friday', events: [thursday]);
      expect(move, isA<CannotDo>());
      expect((move as CannotDo).reason, startsWith("I couldn't find that"));
      expect(writer.previews, isEmpty);
    });

    test('two meetings tied for the reference: a choice', () async {
      final a = timed('a', thu, 9, subject: 'Standup');
      final b = timed('b', fri, 9, subject: 'Standup');
      final r =
          await plan('move the standup to 4pm', events: [a, b]) as NeedsChoice;
      expect(r.question, 'Which meeting?');
      expect(r.options.map((o) => o.bind.event!.id), ['a', 'b']);
      expect(r.options.first.label, 'Standup · Thu Oct 15 · 9:00–9:30 AM');
    });
  });

  group('create', () {
    test('with a day and a time: a proposal that says who it emails',
        () async {
      writer.notifies = const [danaAddress];
      final r = await plan('book design sync with Dana Thu 3pm')
          as CalendarProposal;
      final w = r.write as CreateEvent;
      expect(w.subject, 'design sync');
      expect(w.startUtc, at(thu, 15));
      expect(w.endUtc, at(thu, 15, 30));
      expect(w.attendees, [danaAddress]);
      expect(w.isOnlineMeeting, isTrue);
      expect(r.notifies, [danaAddress]);
      expect(r.needsConfirm, isTrue);
      expect(r.summary, 'Create "design sync" · Thu Oct 15 · 3:00–3:30 PM');
      expect(r.doneMessage, 'Created "design sync".');
    });

    test('a time with no day is today; one that has passed says so',
        () async {
      final r = await plan('book planning at 3pm') as CalendarProposal;
      expect((r.write as CreateEvent).startUtc, at(today, 15));
      final gone = await plan('book planning at 9am');
      expect((gone as CannotDo).reason, contains('has passed today'));
    });

    test('a dry run that fails is a sentence, not a proposal', () async {
      writer.fail = "Couldn't reach the calendar. Nothing was changed.";
      final r = await plan('book planning Thu 3pm');
      expect((r as CannotDo).reason,
          "Couldn't reach the calendar. Nothing was changed.");
    });

    test('a day with no time: the owner\'s own openings, in working hours',
        () async {
      mailbox = const MailboxSettings(
          workingStart: '10:00:00', workingEnd: '16:00:00');
      await store([timed('busy', fri, 10, minutes: 60)]);
      final r = await plan('book planning Friday') as SlotChoice;
      expect(r.source, 'local');
      expect(r.title, 'Pick a time for "planning"');
      expect(r.slots.first.startUtc, at(fri, 11));
      for (final s in r.slots) {
        expect(s.startUtc.isBefore(at(fri, 10)), isFalse);
        expect(s.endUtc.isAfter(at(fri, 16)), isFalse);
      }
      expect(backend.finds, isEmpty);
      // Never inventing a time: nothing was dry-run, let alone written.
      expect(writer.previews, isEmpty);
      final w = r.buildWrite(r.slots.first) as CreateEvent;
      expect(w.startUtc, at(fri, 11));
      expect(w.attendees, isEmpty);
    });

    test('with people and no time: find_meeting_times with bare addresses',
        () async {
      backend.answer = [
        MeetingTimeSuggestion(
            startUtc: at(fri, 13), endUtc: at(fri, 13, 30), confidence: 100),
        MeetingTimeSuggestion(
            startUtc: at(fri, 15), endUtc: at(fri, 15, 30), confidence: 100),
      ];
      final r = await plan('book planning with Dana Friday') as SlotChoice;
      expect(backend.finds.single['attendees'], [danaAddress]);
      expect(backend.finds.single['duration'], 30);
      expect(backend.finds.single['max'], 3);
      expect(backend.finds.single['start'], at(fri, 8));
      expect(backend.finds.single['end'], at(fri, 18));
      expect(r.source, 'graph');
      expect(r.title, 'Pick a time for "planning" with Dana Whitfield');
      expect(r.slots, [
        FreeSlot(at(fri, 13), at(fri, 13, 30)),
        FreeSlot(at(fri, 15), at(fri, 15, 30)),
      ]);
      final w = r.buildWrite(r.slots.last) as CreateEvent;
      expect(w.attendees, [danaAddress]);
      expect(w.isOnlineMeeting, isTrue);
    });

    test('nobody free: a sentence', () async {
      // Graph read everyone and nobody is free: a true no.
      backend.answer = const MeetingTimes(emptyReason: 'attendeesunavailable');
      final r = await plan('book planning with Dana Friday');
      expect((r as CannotDo).reason, noCommonTimeSentence);
    });

    test('an unreadable attendee: the owner\'s own openings, and it says so',
        () async {
      // Empty with any other reason (or none) is a calendar Graph could not
      // read, so "nobody is free" would be false.
      for (final reason in const ['attendeesunavailableorunknown', '']) {
        backend.answer = MeetingTimes(emptyReason: reason);
        final r = await plan('book planning with Dana Friday') as SlotChoice;
        expect(r.source, 'local', reason: reason);
        expect(r.title, endsWith(unreadableSuffix), reason: reason);
        expect(r.slots, isNotEmpty, reason: reason);
      }
    });

    test('a personal account: the owner\'s own openings, and it says so',
        () async {
      backend.answer =
          const CalendarRefused('unsupported_account', 'Work accounts only.');
      final r = await plan('book planning with Dana Friday') as SlotChoice;
      expect(r.source, 'local');
      expect(r.title, contains('only your calendar could be checked'));
      expect(r.slots, isNotEmpty);
    });

    test('with no when at all: the next five working days', () async {
      final r = await plan('book planning') as SlotChoice;
      expect(r.source, 'local');
      expect(r.slots.first.startUtc.isAfter(now), isTrue);
    });

    test('two people behind one name: which one', () async {
      const danaK = KnownPerson(name: 'Dana Kim', address: 'dkim@fabrikam.com');
      final r = await plan('book planning with Dana Friday',
          people: const [dana, danaK]) as NeedsChoice;
      expect(r.question, 'Which Dana?');
      expect(r.options.map((o) => o.label), [
        'Dana Whitfield · dana@contoso.com',
        'Dana Kim · dkim@fabrikam.com',
      ]);
      expect(r.options.last.bind.person, danaK);
    });
  });

  group('cancel, by role', () {
    test("tomorrow's standup with no standup tomorrow is no meeting, never "
        "tomorrow's other one", () async {
      final sync = timed('sync', thu, 10, subject: 'Sync', guests: [danaAddress]);
      final standup = timed('standup', fri, 9, subject: 'Standup');
      final r =
          await plan("cancel tomorrow's standup", events: [sync, standup]);
      expect(r, isA<CannotDo>());
      expect((r as CannotDo).reason, startsWith("I couldn't find that meeting"));
      expect(writer.previews, isEmpty);
    });

    test('an organiser with guests cancels the meeting', () async {
      final e = timed('e', thu, 11, subject: 'Review', guests: [danaAddress]);
      final r = await plan('cancel the review', events: [e]) as CalendarProposal;
      expect(r.write, isA<CancelMeeting>());
      expect(r.needsConfirm, isTrue);
      expect(r.summary, startsWith('Cancel "Review"'));
    });

    test("the owner's own event is deleted", () async {
      final e = timed('e', thu, 11, subject: 'Focus block');
      final r =
          await plan('cancel the focus block', events: [e]) as CalendarProposal;
      expect(r.write, isA<DeleteEvent>());
      expect(r.summary, startsWith('Delete "Focus block"'));
    });

    test("an attendee can't cancel, but can decline — and is told so",
        () async {
      final e = timed('e', thu, 11,
          subject: 'Kickoff', organiser: false, guests: ['me@contoso.com']);
      final r =
          await plan('cancel the kickoff', events: [e]) as CalendarProposal;
      final w = r.write as RespondToEvent;
      expect(w.response, RsvpResponse.decline);
      expect(r.summary, startsWith("You can't cancel it"));
      expect(r.summary, contains('Decline "Kickoff"'));
    });
  });

  group('answers to an invite', () {
    test('an occurrence of a series is answered alone, and the line says '
        'so', () async {
      // The bar's candidates are mirror rows, and the mirror holds a series'
      // occurrences, never its master: the answer goes to the one matched.
      final occurrence = CalendarEvent(
        id: 'occ-1',
        subject: 'Weekly sync',
        eventType: 'occurrence',
        seriesMasterId: 'm',
        isOrganizer: false,
        organizerAddress: 'dana@contoso.com',
        showAs: 'busy',
        startUtc: at(thu, 9),
        endUtc: at(thu, 9, 30),
        changeKey: 'ck',
        attendees: const [
          Attendee(name: 'me@contoso.com', address: 'me@contoso.com'),
        ],
      );
      final r = await plan('accept the weekly sync', events: [occurrence])
          as CalendarProposal;
      final w = r.write as RespondToEvent;
      expect(w.eventId, 'occ-1');
      expect(w.response, RsvpResponse.accept);
      expect(r.summary, startsWith('Accept "Weekly sync"'));
      expect(r.summary, endsWith(oneOfSeriesSuffix));
      expect(r.summary, isNot(contains('every meeting')));
      expect(r.doneMessage, 'Accepted "Weekly sync".');
      expect(r.needsConfirm, isTrue);
    });

    test('a single meeting says nothing about a series', () async {
      final e = timed('e', thu, 9,
          subject: 'Offsite', organiser: false, guests: ['me@contoso.com']);
      final r =
          await plan('accept the offsite', events: [e]) as CalendarProposal;
      expect(r.summary, isNot(contains('series')));
    });

    test('maybe and no', () async {
      final e = timed('e', thu, 9,
          subject: 'Offsite', organiser: false, guests: ['me@contoso.com']);
      final maybe = await plan('tentative for the offsite', events: [e])
          as CalendarProposal;
      expect((maybe.write as RespondToEvent).response, RsvpResponse.tentative);
      final no =
          await plan('decline the offsite', events: [e]) as CalendarProposal;
      expect((no.write as RespondToEvent).response, RsvpResponse.decline);
    });

    test('your own meeting has nothing to answer', () async {
      final e = timed('e', thu, 9, subject: 'Offsite');
      final r = await plan('accept the offsite', events: [e]);
      expect((r as CannotDo).reason, contains('your own meeting'));
    });
  });

  group('find a time', () {
    test('with people: find_meeting_times over the window', () async {
      backend.answer = [
        MeetingTimeSuggestion(
            startUtc: at(thu, 13), endUtc: at(thu, 14), confidence: 90),
      ];
      final r = await plan('find an hour with Lee tomorrow') as SlotChoice;
      expect(backend.finds.single['attendees'], ['lee@fabrikam.com']);
      expect(backend.finds.single['duration'], 60);
      expect(r.title, 'Pick a time with Lee Park');
      final w = r.buildWrite(r.slots.single) as CreateEvent;
      expect(w.subject, 'Meeting with Lee Park');
      expect(w.endUtc, at(thu, 14));
    });

    test('a name nobody has: who is that?', () async {
      final r = await plan('find time with Priya');
      expect((r as CannotDo).reason,
          "I don't know who Priya is — name someone from your mail.");
    });
  });

  group('questions', () {
    test('am I free at a time: yes or no, naming the clash', () async {
      await store([timed('b', fri, 14, minutes: 60, subject: 'Budget review')]);
      final no = await plan('am I free Friday at 2') as Answer;
      expect(no.text, 'No — on Fri Oct 16 at 2:00 PM you have Budget review.');
      expect(no.links.single.eventId, 'b');
      final yes = await plan('am I free Friday at 4') as Answer;
      expect(yes.text, startsWith('Yes'));
    });

    test('what is free in a window: the openings', () async {
      await store([timed('b', thu, 12, minutes: 60)]);
      final r = await plan("what's free tomorrow afternoon") as Answer;
      expect(r.text, startsWith('Free tomorrow: 1:00–1:30 PM'));
    });

    test('the agenda: the day\'s meetings, each linked', () async {
      await store([
        timed('b', thu, 9, minutes: 60, subject: 'Budget review'),
        timed('s', thu, 14, subject: 'Sync with Dana'),
      ]);
      final r = await plan("what's on tomorrow") as Answer;
      expect(r.text,
          'Tomorrow: 9:00–10:00 AM Budget review · 2:00–2:30 PM Sync with Dana');
      expect(r.links.map((l) => l.eventId), ['b', 's']);
      final empty = await plan("what's on Friday") as Answer;
      expect(empty.text, 'Nothing on Fri Oct 16.');
      final none = await plan("what's on") as Answer;
      expect(none.text, 'Nothing today.');
    });

    test('next and last met with a person', () async {
      await store([
        timed('past', const CalendarDate(2026, 10, 2), 10,
            subject: 'Kickoff', guests: [danaAddress]),
        timed('next', fri, 10, subject: 'Design sync', guests: [danaAddress]),
      ]);
      final last = await plan('when did I last meet Dana') as Answer;
      expect(last.text, 'Dana Whitfield — Last met 12 days ago · Kickoff');
      expect(last.links.single.eventId, 'past');
      final next = await plan('next meeting with Dana') as Answer;
      expect(next.text, startsWith('Dana Whitfield — Next meeting: Design sync'));
      expect(next.links.single.eventId, 'next');
    });

    test('asking about nobody: who with?', () async {
      final r = await plan('when did I last meet', people: const []);
      expect((r as CannotDo).reason, whoWithSentence);
    });
  });
}
