import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/llm/meeting_brief_task.dart';
import 'package:bond_inbox/services/llm/prompt_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brief task with no model: the prompt, the schema's house shape, the
/// user message it lays out, and the clamps [MeetingBriefTask.validate]
/// applies to whatever comes back.
void main() {
  BriefInput input({
    List<BriefThread>? threads,
    List<BriefAsk> asks = const [],
    List<BriefThread> waiting = const [],
    List<BriefStoryline> storylines = const [],
    List<String> files = const [],
    String? lastMet,
    String? invitePreview,
    DateTime? now,
  }) {
    final t = threads ??
        [
          BriefThread(
            source: 'email',
            conversationKey: 'c-1',
            subject: 'Fabrikam renewal',
            state: 'needs_reply',
            lastAt: '2026-09-28T10:00:00.000000Z',
            snippets: [wrapUntrusted('message', 'Dana: can you send the quote?')],
            ranked: true,
          ),
          const BriefThread(
            source: 'email',
            conversationKey: 'c-2',
            subject: 'Kickoff notes',
            state: 'waiting',
            lastAt: '2026-09-27T10:00:00.000000Z',
          ),
        ];
    return BriefInput(
      event: const CalendarEvent(id: 'evt-1', subject: 'Fabrikam sync'),
      whenLocal: 'Wed 30 Sep 2026 · 10:00–10:30 AM PDT',
      nowLocal: 'Tue 29 Sep 2026, 3:05 PM PDT',
      now: now,
      attendees: const ['Dana Lee', 'sam@fabrikam.com'],
      threads: t,
      openAsks: asks,
      waitingOn: waiting,
      storylines: storylines,
      files: files,
      lastMet: lastMet,
      invitePreview: invitePreview,
      inputsHash: 'h',
    );
  }

  group('the prompt and schema', () {
    test('the system prompt is constant and ends with the untrusted clause',
        () {
      const task = MeetingBriefTask();
      expect(task.systemPrompt, const MeetingBriefTask(threadCount: 3).systemPrompt);
      expect(task.systemPrompt.endsWith(untrustedDataClause), isTrue);
      expect(task.schemaName, 'meeting_brief');
      // Nothing per call in it: no date, no meeting.
      expect(task.systemPrompt, isNot(contains('Fabrikam')));
      expect(task.systemPrompt, isNot(contains('2026')));
    });

    test('the prompt tells the model to name the day, never a relative one',
        () {
      expect(const MeetingBriefTask().systemPrompt,
          contains('Never write today, tomorrow or yesterday; name the day.'));
    });

    test('the schema is flat, strict and names every key', () {
      final schema = const MeetingBriefTask().schema;
      expect(schema.containsKey(r'$defs'), isFalse);
      expect(schema['additionalProperties'], false);
      expect(schema['required'], ['headline', 'points', 'open_asks', 'prep']);
      final props = schema['properties'] as Map;
      expect(props.keys.toSet(), {'headline', 'points', 'open_asks', 'prep'});

      final points = props['points'] as Map;
      final pointItem = points['items'] as Map;
      expect(pointItem['required'], ['text', 'thread']);
      expect(pointItem['additionalProperties'], false);
      expect((pointItem['properties'] as Map)['thread'], containsPair('type', 'integer'));
      // No maxItems on an array of objects, no maxLength anywhere: the
      // grammar converter refuses both, and validate holds the ceilings.
      expect(points.containsKey('maxItems'), isFalse);
      final asks = props['open_asks'] as Map;
      expect((asks['items'] as Map)['required'], ['person', 'ask', 'thread']);
      expect(asks.containsKey('maxItems'), isFalse);
      expect((props['prep'] as Map)['maxItems'], MeetingBriefTask.maxPrep);
      expect(schema.toString(), isNot(contains('maxLength')));
    });

    test('the call budget', () {
      expect(MeetingBriefTask.temperature, 0.2);
      expect(MeetingBriefTask.maxTokens, 700);
    });
  });

  group('the user message', () {
    test("each thread's last message is an age from now, not a stamp", () {
      final msg = const MeetingBriefTask().buildUserMessage(
          input(now: DateTime.utc(2026, 9, 28, 13)));
      expect(msg, contains('[1] waiting on the owner · last message '
          '3 hours ago'));
      expect(msg, contains('[2] waiting on them · last message 1 day ago'));
      expect(msg, isNot(contains('2026-09-28T10')));
    });

    test('with no clock, a hand-built input shows the stored stamp', () {
      final msg = const MeetingBriefTask().buildUserMessage(input());
      expect(msg, contains('last message 2026-09-28T10:00:00.000000Z'));
    });

    test('the meeting, then numbered threads with fenced subjects and '
        'snippets', () {
      final msg = const MeetingBriefTask().buildUserMessage(input(
        lastMet: 'Last met 3 days ago',
      ));
      final lines = msg.split('\n');
      expect(lines[0], 'Now: Tue 29 Sep 2026, 3:05 PM PDT');
      expect(lines[1], 'Meeting: Wed 30 Sep 2026 · 10:00–10:30 AM PDT');
      expect(msg, isNot(contains('Tomorrow')));
      expect(msg, contains(wrapUntrusted('meeting_subject', 'Fabrikam sync')));
      expect(msg, contains(wrapUntrusted('attendees', 'Dana Lee, sam@fabrikam.com')));
      expect(msg, contains('Last met 3 days ago.'));
      expect(msg, contains('[1] waiting on the owner'));
      expect(msg, contains('marked urgent or important'));
      expect(msg, contains('[2] waiting on them'));
      expect(msg, contains(wrapUntrusted('subject', 'Fabrikam renewal')));
      expect(msg, contains(wrapUntrusted('subject', 'Kickoff notes')));
      expect(msg, contains('Dana: can you send the quote?'));
      expect(msg.indexOf('[1]'), lessThan(msg.indexOf('[2]')));
    });

    test('asks, waiting, storylines, files and the invite, each fenced; an '
        'empty section is left out', () {
      final base = input();
      final msg = const MeetingBriefTask().buildUserMessage(input(
        asks: [
          BriefAsk(
            person: 'Dana Lee',
            ask: wrapUntrusted('ask', 'Can you send the quote?'),
            intent: 'request',
            threadIndex: 0,
          ),
        ],
        waiting: [base.threads[1]],
        storylines: [
          BriefStoryline(
            id: 's-1',
            title: 'Fabrikam renewal',
            summary: wrapUntrusted('storyline', 'Pricing agreed, paperwork next.'),
          ),
        ],
        files: const ['quote.pdf', 'terms.docx'],
        invitePreview: wrapUntrusted('invite', 'Agenda: renewal.'),
      ));
      expect(msg, contains('Open asks'));
      expect(msg, contains('a request in thread [1]'));
      expect(msg, contains(wrapUntrusted('person', 'Dana Lee')));
      expect(msg, contains(wrapUntrusted('ask', 'Can you send the quote?')));
      expect(msg, contains('Waiting on them (the owner wrote last): [2]'));
      expect(msg, contains(wrapUntrusted('storyline_title', 'Fabrikam renewal')));
      expect(msg, contains('Pricing agreed'));
      expect(msg, contains(wrapUntrusted('files', 'quote.pdf\nterms.docx')));
      expect(msg, contains(wrapUntrusted('invite', 'Agenda: renewal.')));

      final bare = const MeetingBriefTask().buildUserMessage(input());
      expect(bare, isNot(contains('Open asks')));
      expect(bare, isNot(contains('Storylines')));
      expect(bare, isNot(contains('Files')));
      expect(bare, isNot(contains('From the invite')));
      expect(bare, isNot(contains('Last met')));
    });

    test('no threads says so', () {
      final msg =
          const MeetingBriefTask().buildUserMessage(input(threads: const []));
      expect(msg, contains('Threads: none.'));
    });
  });

  group('validate', () {
    test('1-based thread numbers become 0-based, and a number outside the '
        'list becomes -1', () {
      final brief = const MeetingBriefTask(threadCount: 2).validate({
        'headline': 'Dana is waiting on the quote.',
        'points': [
          {'text': 'The quote is owed.', 'thread': 1},
          {'text': 'Kickoff notes are out.', 'thread': 2},
          {'text': 'Invented thread.', 'thread': 7},
          {'text': 'No thread.', 'thread': -1},
          {'text': 'Zero is not a number in the list.', 'thread': 0},
        ],
        'open_asks': [
          {'person': 'Dana', 'ask': 'Send the quote', 'thread': 1},
          {'person': 'Sam', 'ask': 'Confirm terms', 'thread': 3},
        ],
        'prep': ['Have the quote ready'],
      });
      expect([for (final p in brief.points) p.thread], [0, 1, -1, -1, -1]);
      expect([for (final a in brief.openAsks) a.thread], [0, -1]);
      expect(brief.threads, isEmpty,
          reason: 'the handler attaches the thread list, not the task');
    });

    test('clamps every string and every list, and drops empty strings', () {
      final brief = const MeetingBriefTask(threadCount: 1).validate({
        'headline': '  ${'h' * 300}  ',
        'points': [
          for (var i = 0; i < 8; i++) {'text': 'p$i ${'x' * 300}', 'thread': 1},
          {'text': '   ', 'thread': 1},
        ],
        'open_asks': [
          {'person': 'Dana', 'ask': '', 'thread': 1},
          for (var i = 0; i < 6; i++)
            {'person': 'P' * 200, 'ask': 'a$i ${'y' * 300}', 'thread': 1},
        ],
        'prep': ['', '  ', 'one', 'two', 'three', 'four', 'z' * 200],
      });
      expect(brief.headline.length, MeetingBriefTask.headlineCap);
      expect(brief.points, hasLength(MeetingBriefTask.maxPoints));
      expect(brief.points.every((p) => p.text.length <= MeetingBriefTask.pointCap),
          isTrue);
      expect(brief.openAsks, hasLength(MeetingBriefTask.maxAsks));
      expect(brief.openAsks.first.ask, startsWith('a0'));
      expect(brief.openAsks.every((a) => a.ask.length <= MeetingBriefTask.askCap),
          isTrue);
      expect(brief.openAsks.first.person.length, MeetingBriefTask.personCap);
      expect(brief.prep, ['one', 'two', 'three']);
    });

    test('a clamp at an emoji never leaves half of it', () {
      // The emoji's two code units straddle the headline cap.
      final head = 'h' * (MeetingBriefTask.headlineCap - 1);
      final brief = const MeetingBriefTask().validate({
        'headline': '$head\u{1F600}tail',
      });
      expect(brief.headline, head);
    });

    test('never throws on a malformed answer', () {
      final brief = const MeetingBriefTask().validate({
        'headline': 42,
        'points': 'nope',
        'open_asks': [1, 'two', null],
        'prep': {'a': 1},
      });
      expect(brief.headline, '');
      expect(brief.points, isEmpty);
      expect(brief.openAsks, isEmpty);
      expect(brief.prep, isEmpty);
    });

    test('a stored brief round-trips with its thread list', () {
      final brief = const MeetingBriefTask(threadCount: 1).validate({
        'headline': 'One thing open.',
        'points': [
          {'text': 'The quote.', 'thread': 1},
        ],
        'open_asks': const [],
        'prep': const ['Bring numbers'],
      }).withThreads(const [
        BriefThreadRef(
          source: 'email',
          conversationKey: 'c-1',
          subject: 'Fabrikam renewal',
        ),
      ]);
      final back = MeetingBrief.fromJson(brief.toJson());
      expect(back.headline, 'One thing open.');
      expect(back.threadAt(back.points.single.thread)?.conversationKey, 'c-1');
      expect(back.prep, ['Bring numbers']);
    });
  });
}
