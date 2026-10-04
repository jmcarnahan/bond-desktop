import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/meeting_brief_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The `meeting_brief` handler over a real store and a [ScriptedLlm]: what it
/// stores for each outcome, when it spends no call, and which failures park
/// the lane rather than fail the item.
void main() {
  setUpAll(initCalendarZones);

  const owner = 'me@contoso.com';
  const dana = 'dana@fabrikam.com';

  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late BriefGatherer gatherer;
  late DateTime now;
  late int stored;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    gatherer = BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => owner,
      zone: () => CalendarZone.tryNamed('America/Los_Angeles')!,
    );
    now = DateTime.now().toUtc();
    stored = 0;
  });

  tearDown(() async {
    await db.close();
  });

  MeetingBriefHandler handler(ScriptedLlm llm) => MeetingBriefHandler(
        calendar,
        gatherer,
        client: () => llm,
        clock: () => now,
        onStored: () => stored++,
      );

  Map<String, Object?> item(String id, {bool asked = false}) => {
        'task_kind': 'meeting_brief',
        'source': 'calendar',
        'entity_id': id,
        if (asked) 'payload_json': const BriefRequest(asked: true).encode(),
      };

  Future<void> seedEvent({
    String id = 'evt-1',
    Duration startsIn = const Duration(hours: 3),
    List<Attendee> attendees = const [
      Attendee(name: 'Me', address: owner),
      Attendee(name: 'Dana Lee', address: dana),
    ],
    String responseStatus = 'accepted',
    bool isCancelled = false,
  }) async {
    final start = now.add(startsIn);
    await calendar.upsertEvents([
      CalendarEvent(
        id: id,
        subject: 'Fabrikam sync',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: responseStatus,
        isCancelled: isCancelled,
        attendees: attendees,
      ),
    ], syncRun: 'run-1');
  }

  /// A ready brief already stored for [id], written three hours ago from
  /// inputs that no longer match.
  Future<String> seedReady(String id) async {
    final json = jsonEncode(const MeetingBrief(
      headline: 'The old brief.',
      points: [],
      openAsks: [],
      prep: [],
    ).toJson());
    await calendar.putBrief(
      eventId: id,
      inputsHash: 'stale',
      status: EventBrief.ready,
      briefJson: json,
      generatedAt: calendarStamp(now.subtract(const Duration(hours: 3))),
    );
    return json;
  }

  Future<void> seedThread({Duration ago = const Duration(hours: 2)}) async {
    final at = MessageStore.isoStamp(now.subtract(ago));
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c-1',
      'subject': 'Fabrikam renewal',
      'participants_json': jsonEncode([
        {'name': 'Dana', 'email': dana},
      ]),
      'state': 'needs_reply',
      'message_count': 1,
      'last_message_at': at,
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm-1',
      'conversation_key': 'c-1',
      'direction': 'inbound',
      'from_name': 'Dana',
      'from_address': dana,
      'received_at': at,
      'body_text': 'Can you send the quote before we meet?',
      'triage_status': 'done',
    });
  }

  const answer = {
    'evidence': 'A renewal call; Dana is waiting on the quote.',
    'headline': 'Dana is waiting on the quote.',
    'points': [
      {'text': 'The quote is owed.', 'thread': 1},
    ],
    'open_asks': [
      {'person': 'Dana', 'ask': 'Send the quote', 'thread': 1},
    ],
    'materials': [],
    'questions': ['Is the price final?'],
    'prep': ['Have the quote ready'],
  };

  test('writes a ready brief with the thread list it points into', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});

    await handler(llm).run(item('evt-1'));

    expect(llm.schemas, ['meeting_brief']);
    expect(llm.temperatures, [0.2]);
    expect(llm.budgets['meeting_brief'], 2700);
    final row = (await calendar.brief('evt-1'))!;
    expect(row.status, EventBrief.ready);
    expect(row.inputsHash, isNot(startsWith(EventBrief.ineligiblePrefix)));
    final brief = row.brief!;
    expect(brief.headline, 'Dana is waiting on the quote.');
    expect(brief.points.single.thread, 0);
    final ref = brief.threadAt(0)!;
    expect((ref.source, ref.conversationKey, ref.subject),
        ('email', 'c-1', 'Fabrikam renewal'));
    expect(stored, 1);
  });

  test('the stored brief carries its material refs and the activity counts '
      'them, the people and the text', () async {
    await seedEvent();
    await seedThread();
    await store.upsertAttachments('email', 'm-1', [
      {
        'attachment_id': 'a-quote',
        'ordinal': 0,
        'kind': 'file',
        'name': 'quote.pdf',
        'content_type': 'application/pdf',
        'is_inline': 0,
      },
    ]);
    await store.setAttachmentText('email', 'm-1', 'a-quote',
        status: 'done', text: 'Tier B is 12k a year.');
    final llm = ScriptedLlm(answers: {
      'meeting_brief': {
        ...answer,
        'materials': [
          {
            'file': 1,
            'points': ['Tier B is 12k a year.'],
          },
          {
            'file': 2,
            'points': ['There is no second file.'],
          },
        ],
      },
    });
    final log = ActivityLog(store);
    final briefs = MeetingBriefHandler(
      calendar,
      gatherer,
      client: () => llm,
      activityLog: log,
      clock: () => now,
    );

    await briefs.run(item('evt-1'));
    await log.record('meeting_brief', source: 'calendar', entityId: 'evt-1');

    expect(llm.userMessages.single,
        contains('Materials sent ahead, numbered ("you" is the owner):'));
    expect(llm.userMessages.single, contains('Tier B is 12k a year.'),
        reason: "the file's text reaches the model");
    expect(llm.userMessages.single, contains('People, numbered, the organiser '
        'first:'));
    final brief = (await calendar.brief('evt-1'))!.brief!;
    expect(brief.evidence, 'A renewal call; Dana is waiting on the quote.');
    expect(brief.questions, ['Is the price final?']);
    expect(brief.materials.single.file, 0,
        reason: 'the number past the list is dropped');
    final ref = brief.materialAt(0)!;
    expect((ref.source, ref.messageId, ref.attachmentId, ref.name),
        ('email', 'm-1', 'a-quote', 'quote.pdf'));

    final rows = [
      for (final r in await store.recentActivity())
        if (r['kind'] == 'meeting_brief') r,
    ];
    final detail =
        jsonDecode(rows.single['detail_json'] as String) as Map<String, Object?>;
    expect(detail['materials'], 1);
    expect(detail['questions'], 1);
    expect(detail['threads'], 1);
    expect(detail['people'], 1);
    expect(detail['text_chars'], 'Tier B is 12k a year.'.length);
  });

  /// m-1 flagged as carrying a file nobody has listed yet.
  Future<void> flagUnlisted() => db.customStatement(
      "UPDATE messages SET has_attachments = 1 WHERE source_message_id = 'm-1'");

  test('unlisted attachments are fetched once before the brief is written',
      () async {
    await seedEvent();
    await seedThread();
    await flagUnlisted();
    final fetched = <(String, List<String>)>[];
    final llm = ScriptedLlm(answers: {
      'meeting_brief': {
        ...answer,
        'materials': [
          {
            'file': 1,
            'points': ['The quote is attached.'],
          },
        ],
      },
    });
    final log = ActivityLog(store);
    final briefs = MeetingBriefHandler(
      calendar,
      gatherer,
      client: () => llm,
      activityLog: log,
      clock: () => now,
      // The detail fetch lists the file, as the sync's would, and here its
      // text is read at once: a file still pending would make the brief
      // wait (the pending tests below).
      fetchDetails: (source, ids) async {
        fetched.add((source, ids));
        await store.upsertAttachments('email', 'm-1', [
          {
            'attachment_id': 'a-quote',
            'ordinal': 0,
            'kind': 'file',
            'name': 'quote.pdf',
            'content_type': 'application/pdf',
            'is_inline': 0,
          },
        ]);
        await store.setAttachmentText('email', 'm-1', 'a-quote',
            status: 'done', text: 'The quote.');
        return ids.length;
      },
    );

    await briefs.run(item('evt-1'));
    await log.record('meeting_brief', source: 'calendar', entityId: 'evt-1');

    expect([for (final (source, ids) in fetched) '$source:${ids.join(',')}'],
        ['email:m-1']);
    expect(llm.userMessages.single, contains('quote.pdf'),
        reason: 'the second gather sees the file the fetch listed');
    final brief = (await calendar.brief('evt-1'))!.brief!;
    expect(brief.materialAt(0)?.name, 'quote.pdf');
    final rows = [
      for (final r in await store.recentActivity())
        if (r['kind'] == 'meeting_brief') r,
    ];
    final detail =
        jsonDecode(rows.single['detail_json'] as String) as Map<String, Object?>;
    expect(detail['fetched'], 1);
    expect(detail['materials'], 1);

    // Listed now: the next run fetches nothing.
    await briefs.run(item('evt-1', asked: true));
    expect(fetched, hasLength(1));
  });

  test('a failing fetch still writes the brief', () async {
    await seedEvent();
    await seedThread();
    await flagUnlisted();
    var calls = 0;
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    final briefs = MeetingBriefHandler(
      calendar,
      gatherer,
      client: () => llm,
      clock: () => now,
      fetchDetails: (source, ids) async {
        calls++;
        throw StateError('Graph is down');
      },
    );

    await briefs.run(item('evt-1'));

    expect(calls, 1, reason: 'asked once, never retried in the run');
    final row = (await calendar.brief('evt-1'))!;
    expect(row.status, EventBrief.ready);
    expect(row.brief!.materialRefs, isEmpty);
  });

  test('one failed fetch costs only its own message: the other\'s file is '
      'gathered again and briefed', () async {
    await seedEvent();
    await seedThread();
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm-2',
      'conversation_key': 'c-1',
      'direction': 'inbound',
      'from_name': 'Dana',
      'from_address': dana,
      'received_at': MessageStore.isoStamp(
          now.subtract(const Duration(minutes: 90))),
      'body_text': 'And the terms.',
      'triage_status': 'done',
      'has_attachments': 1,
    });
    await flagUnlisted();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    final log = ActivityLog(store);
    final briefs = MeetingBriefHandler(
      calendar,
      gatherer,
      client: () => llm,
      activityLog: log,
      clock: () => now,
      // The provider's shape: one id at a time through `fetchEach`, and
      // m-2's fetch fails as a 502 would.
      fetchDetails: (source, ids) =>
          MeetingBriefHandler.fetchEach(ids, (id) async {
        if (id == 'm-2') throw StateError('Bad gateway');
        await store.upsertAttachments('email', id, [
          {
            'attachment_id': 'a-quote',
            'ordinal': 0,
            'kind': 'file',
            'name': 'quote.pdf',
            'content_type': 'application/pdf',
            'is_inline': 0,
          },
        ]);
        await store.setAttachmentText('email', id, 'a-quote',
            status: 'done', text: 'The quote.');
      }),
    );

    await briefs.run(item('evt-1'));
    await log.record('meeting_brief', source: 'calendar', entityId: 'evt-1');

    expect(llm.userMessages.single, contains('quote.pdf'),
        reason: 'm-1 fetched, so the meeting was gathered again');
    final rows = [
      for (final r in await store.recentActivity())
        if (r['kind'] == 'meeting_brief') r,
    ];
    expect(jsonDecode(rows.single['detail_json'] as String),
        containsPair('fetched', 1));
  });

  test('an invite sent two days ago whose file is only now being read is '
      'waited for', () async {
    await seedEvent();
    // The owner's own invite, two days old: well past the two-hour backstop
    // if it were measured from the mail.
    await seedThread(ago: const Duration(days: 2));
    await flagUnlisted();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    final briefs = MeetingBriefHandler(
      calendar,
      gatherer,
      client: () => llm,
      clock: () => now,
      // What `ensureMessageBody` does: lists the file and queues its text,
      // which nothing has read yet.
      fetchDetails: (source, ids) async {
        await store.upsertAttachments('email', 'm-1', [
          {
            'attachment_id': 'a-pricing',
            'ordinal': 0,
            'kind': 'file',
            'name': 'pricing.pdf',
            'content_type': 'application/pdf',
            'is_inline': 0,
          },
        ]);
        await store.enqueueWork('attachment_text', 'email',
            attachmentEntityId('m-1', 'a-pricing'));
        return ids.length;
      },
    );

    await briefs.run(item('evt-1'));

    expect(llm.calls, isEmpty);
    final row = (await calendar.brief('evt-1'))!;
    expect(row.status, EventBrief.skipped);
    expect(row.skipReason, 'materials_pending');
  });

  group('waiting for the files', () {
    /// A file listed on m-1 and not read yet; with [queue], its text work
    /// is queued, which is what "being read" means.
    Future<void> attachPending({
      String id = 'a-deck',
      String name = 'deck.pptx',
      int ordinal = 0,
      bool queue = true,
    }) async {
      await store.upsertAttachments('email', 'm-1', [
        {
          'attachment_id': id,
          'ordinal': ordinal,
          'kind': 'file',
          'name': name,
          'content_type': 'application/pdf',
          'is_inline': 0,
        },
      ]);
      if (queue) {
        await store.enqueueWork(
            'attachment_text', 'email', attachmentEntityId('m-1', id));
      }
    }

    // The thread's mail is an hour old in this group: inside the wait's
    // age cap (`BriefGatherer.pendingMaxAge`).
    Future<void> seedYoungThread() =>
        seedThread(ago: const Duration(hours: 1));

    test('pending files and no brief yet: a skipped materials_pending row, '
        'no model call', () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending();
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});
      final log = ActivityLog(store);
      final briefs = MeetingBriefHandler(
        calendar,
        gatherer,
        client: () => llm,
        activityLog: log,
        clock: () => now,
        onStored: () => stored++,
      );

      await briefs.run(item('evt-1'));
      await log.record('meeting_brief', source: 'calendar', entityId: 'evt-1');

      expect(llm.calls, isEmpty);
      final row = (await calendar.brief('evt-1'))!;
      expect(row.status, EventBrief.skipped);
      expect(row.skipReason, 'materials_pending');
      expect(stored, 1);
      final rows = [
        for (final r in await store.recentActivity())
          if (r['kind'] == 'meeting_brief') r,
      ];
      expect(jsonDecode(rows.single['detail_json'] as String),
          containsPair('reason', 'materials_pending'));

      // The text lands: the next run writes the brief.
      await store.setAttachmentText('email', 'm-1', 'a-deck',
          status: 'done', text: 'Two tiers.');
      await briefs.run(item('evt-1'));
      expect(llm.calls, hasLength(1));
      expect((await calendar.brief('evt-1'))!.status, EventBrief.ready);
    });

    test('a file that will never be read is not pending', () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending();
      await store.setAttachmentText('email', 'm-1', 'a-deck',
          status: 'skipped');
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});

      await handler(llm).run(item('evt-1'));

      expect(llm.calls, hasLength(1));
      expect((await calendar.brief('evt-1'))!.status, EventBrief.ready);
    });

    test('pending files inside the grace are briefed with what is read',
        () async {
      await seedEvent(startsIn: const Duration(minutes: 15));
      await seedYoungThread();
      await attachPending();
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});

      await handler(llm).run(item('evt-1'));

      expect(llm.calls, hasLength(1));
      expect(llm.userMessages.single, contains('(unread)'));
      expect((await calendar.brief('evt-1'))!.status, EventBrief.ready);
    });

    test('an asked-for brief does not wait for the files', () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending();
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});

      await handler(llm).run(item('evt-1', asked: true));

      expect(llm.calls, hasLength(1));
      expect(llm.userMessages.single, contains('(unread)'));
      expect((await calendar.brief('evt-1'))!.status, EventBrief.ready);
    });

    test('pending files over a ready brief: the brief is rewritten anyway',
        () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending();
      await seedReady('evt-1');
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});

      await handler(llm).run(item('evt-1'));

      expect(llm.calls, hasLength(1));
      final row = (await calendar.brief('evt-1'))!;
      expect(row.status, EventBrief.ready);
      expect(row.brief!.headline, 'Dana is waiting on the quote.');
    });
  
    test('an unqueued file is queued once and waited for', () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending(queue: false);
      final llm = ScriptedLlm(answers: {'meeting_brief': answer});
      final log = ActivityLog(store);
      final briefs = MeetingBriefHandler(
        calendar,
        gatherer,
        client: () => llm,
        activityLog: log,
        clock: () => now,
      );
      final entity = attachmentEntityId('m-1', 'a-deck');
      expect(await store.workStatusOf('attachment_text', 'email', entity),
          isNull);

      await briefs.run(item('evt-1'));
      await log.record('meeting_brief', source: 'calendar', entityId: 'evt-1');

      expect(await store.workStatusOf('attachment_text', 'email', entity),
          'pending');
      expect(llm.calls, isEmpty);
      expect((await calendar.brief('evt-1'))!.skipReason, 'materials_pending');
      final rows = [
        for (final r in await store.recentActivity())
          if (r['kind'] == 'meeting_brief') r,
      ];
      expect(jsonDecode(rows.single['detail_json'] as String),
          containsPair('queued_text', 1));

      // Queued now: the next run finds a work row, queues nothing more and
      // still waits; once the text work gives up, it briefs.
      await briefs.run(item('evt-1'));
      expect(llm.calls, isEmpty);
      await db.customStatement("UPDATE work_items SET status = 'error' "
          "WHERE task_kind = 'attachment_text'");
      await briefs.run(item('evt-1'));
      expect(llm.calls, hasLength(1));
      expect((await calendar.brief('evt-1'))!.status, EventBrief.ready);
    });

    test('a waiting brief costs no embedding and no text read', () async {
      await seedEvent();
      await seedYoungThread();
      await attachPending();
      await attachPending(id: 'a-memo', name: 'memo.pdf', ordinal: 1);
      await store.setAttachmentText('email', 'm-1', 'a-memo',
          status: 'done', text: 'The memo.');
      final counting = _CountingStore(db);
      final server = FakeEmbedServer();
      final briefs = MeetingBriefHandler(
        calendar,
        BriefGatherer(
          counting,
          calendar,
          ownerAddress: () async => owner,
          zone: () => CalendarZone.tryNamed('America/Los_Angeles')!,
          embeddings: server.client,
        ),
        client: () => ScriptedLlm.never(),
        clock: () => now,
      );

      await briefs.run(item('evt-1'));

      expect((await calendar.brief('evt-1'))!.skipReason, 'materials_pending');
      expect(server.calls, 0);
      expect(counting.textReads, 0);
      expect(counting.chunkChecks, 0);
    });
  });

  test('an ineligible meeting is skipped with its reason, and no call',
      () async {
    await seedEvent(attendees: const [Attendee(name: 'Me', address: owner)]);
    final llm = ScriptedLlm.never();

    await handler(llm).run(item('evt-1'));

    final row = (await calendar.brief('evt-1'))!;
    expect(row.status, EventBrief.skipped);
    expect(row.skipReason, 'no_others');
    expect(llm.calls, isEmpty);
  });

  test('an event gone from the mirror is skipped as gone', () async {
    await handler(ScriptedLlm.never()).run(item('evt-missing'));
    expect((await calendar.brief('evt-missing'))!.skipReason, 'gone');
  });

  test('the same inputs a second time spend no second call', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    final h = handler(llm);

    await h.run(item('evt-1'));
    await h.run(item('evt-1'));

    expect(llm.callsFor('meeting_brief'), 1);
  });

  test('asked (Regenerate) writes again over unchanged inputs; a planner '
      'row does not', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    final h = handler(llm);

    await h.run(item('evt-1'));
    await h.run(item('evt-1'));
    expect(llm.callsFor('meeting_brief'), 1, reason: 'skipped unchanged');

    await h.run(item('evt-1', asked: true));
    expect(llm.callsFor('meeting_brief'), 2);
  });

  test('the request payload reads asked only for a literal true', () {
    expect(BriefRequest.fromPayload('{"asked":true}').asked, isTrue);
    expect(BriefRequest.fromPayload('{"asked":"true"}').asked, isFalse);
    expect(BriefRequest.fromPayload('not json').asked, isFalse);
    expect(BriefRequest.fromPayload(null).asked, isFalse);
    expect(const BriefRequest(asked: true).encode(), '{"asked":true}');
    expect(BriefRequest.none.encode(), isNull);
  });

  group('a ready brief is never destroyed', () {
    test('by a format failure: still ready, the old text, a new stamp',
        () async {
      await seedEvent();
      await seedThread();
      final json = await seedReady('evt-1');
      final llm = ScriptedLlm(answers: {
        'meeting_brief': const LlmFormatException('not JSON'),
      });

      await expectLater(
        handler(llm).run(item('evt-1')),
        throwsA(isA<LlmFormatException>()),
      );
      final row = (await calendar.brief('evt-1'))!;
      expect(row.status, EventBrief.ready);
      expect(row.briefJson, json);
      expect(row.inputsHash, 'stale');
      expect(row.generatedAt, calendarStamp(now),
          reason: 'the stamp moves, so the two-hour rule throttles retries');
      expect(llm.calls, hasLength(1));
    });

    test('by a skip: a meeting that has started keeps its brief', () async {
      await seedEvent(startsIn: const Duration(minutes: -5));
      final json = await seedReady('evt-1');

      await handler(ScriptedLlm.never()).run(item('evt-1'));

      final row = (await calendar.brief('evt-1'))!;
      expect(row.status, EventBrief.ready);
      expect(row.briefJson, json);
      expect(row.generatedAt, calendarStamp(now));
    });
  });

  group('a ready brief ends with the meeting', () {
    for (final (name, declined, cancelled) in [
      ('declined', true, false),
      ('cancelled', false, true),
    ]) {
      test('$name: the brief is replaced by a skip', () async {
        await seedEvent(
          responseStatus: declined ? 'declined' : 'accepted',
          isCancelled: cancelled,
        );
        await seedReady('evt-1');

        await handler(ScriptedLlm.never()).run(item('evt-1'));

        final row = (await calendar.brief('evt-1'))!;
        expect(row.status, EventBrief.skipped);
        expect(row.skipReason, name);
        expect(row.briefJson, isNull);
        expect(row.brief, isNull);
      });
    }

    test('gone: the brief is replaced by a skip', () async {
      await seedReady('evt-missing');
      await handler(ScriptedLlm.never()).run(item('evt-missing'));
      final row = (await calendar.brief('evt-missing'))!;
      expect(row.status, EventBrief.skipped);
      expect(row.briefJson, isNull);
    });
  });

  test('with the owner unknown the handler retries rather than writing a '
      'brief', () async {
    await seedEvent();
    await seedThread();
    final unknown = BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => null,
      zone: () => CalendarZone.tryNamed('America/Los_Angeles')!,
    );
    final llm = ScriptedLlm.never();
    final h = MeetingBriefHandler(calendar, unknown,
        client: () => llm, clock: () => now);

    await expectLater(
        h.run(item('evt-1')), throwsA(isA<BriefOwnerUnknown>()));
    expect(await calendar.brief('evt-1'), isNull);
    expect(llm.calls, isEmpty);
  });

  test("a series master is briefed as its next occurrence, under the "
      "occurrence's id", () async {
    await seedThread();
    final first = now.subtract(const Duration(days: 7));
    final next = now.add(const Duration(hours: 3));
    const people = [
      Attendee(name: 'Me', address: owner),
      Attendee(name: 'Dana Lee', address: dana),
    ];
    await calendar.upsertEvents([
      CalendarEvent(
        id: 'master',
        subject: 'Weekly',
        eventType: 'seriesMaster',
        startUtc: first,
        endUtc: first.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        attendees: people,
      ),
      CalendarEvent(
        id: 'occ-1',
        subject: 'Weekly',
        eventType: 'occurrence',
        seriesMasterId: 'master',
        startUtc: next,
        endUtc: next.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        attendees: people,
      ),
    ], syncRun: 'run-1');
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});

    await handler(llm).run(item('master'));

    expect((await calendar.brief('occ-1'))?.status, EventBrief.ready);
    expect(await calendar.brief('master'), isNull);
  });

  test('a dead model server propagates, so the lane parks', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {
      'meeting_brief': const LlmUnavailableException('the server is off'),
    });

    await expectLater(
      handler(llm).run(item('evt-1')),
      throwsA(isA<LlmUnavailableException>()),
    );
    expect(await calendar.brief('evt-1'), isNull,
        reason: 'a park is not an outcome for the brief');
  });

  test('a format failure writes a failed row and still throws', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {
      'meeting_brief': const LlmFormatException('not JSON'),
    });

    await expectLater(
      handler(llm).run(item('evt-1')),
      throwsA(isA<LlmFormatException>()),
    );
    expect((await calendar.brief('evt-1'))!.status, EventBrief.failed);
  });

  test('an empty headline is a failure, not a brief', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {
      'meeting_brief': {...answer, 'headline': '   '},
    });

    await expectLater(
      handler(llm).run(item('evt-1')),
      throwsA(isA<LlmFormatException>()),
    );
    expect((await calendar.brief('evt-1'))!.status, EventBrief.failed);
  });

  test('on a worker, an unavailable server parks the item pending', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {
      'meeting_brief': const LlmUnavailableException('the server is off'),
    });
    await store.enqueueWork('meeting_brief', 'calendar', 'evt-1');
    final worker = AiWorker(store, handlers: [handler(llm)]);
    addTearDown(worker.dispose);

    await worker.pump();

    // The row was CLAIMED (the call reached the model) and handed back.
    // Without `calendar` in `AiWorker.sources` it would sit pending here
    // having never been claimed, and this test would pass for nothing.
    expect(llm.schemas, ['meeting_brief']);
    expect(await store.workStatusOf('meeting_brief', 'calendar', 'evt-1'),
        'pending');
  });

  test('drains on a draft-lane-shaped worker: the brief ready, the row done',
      () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});
    await store.enqueueWork('meeting_brief', 'calendar', 'evt-1');
    final worker =
        AiWorker(store, handlers: [_IdleDraft(), handler(llm)]);
    addTearDown(worker.dispose);

    await worker.pump();

    expect((await calendar.brief('evt-1'))?.status, EventBrief.ready);
    expect(await store.workStatusOf('meeting_brief', 'calendar', 'evt-1'),
        'done');
  });
}

/// The draft lane's first handler, with nothing to do: the brief handler sits
/// behind it exactly as it does in the app.
class _IdleDraft extends WorkHandler {
  @override
  String get kind => 'draft';

  @override
  Future<void> run(Map<String, Object?> item) async {}
}

/// A store that counts the heavy gather's reads: a file's text and the
/// chunk check before an embedding.
class _CountingStore extends MessageStore {
  _CountingStore(super.db);

  int textReads = 0;
  int chunkChecks = 0;

  @override
  Future<String?> attachmentTextOf(
    String source,
    String sourceMessageId,
    String attachmentId,
  ) {
    textReads++;
    return super.attachmentTextOf(source, sourceMessageId, attachmentId);
  }

  @override
  Future<bool> hasAttachmentChunks(
    String source, {
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
  }) async {
    chunkChecks++;
    return true;
  }
}
