import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/meeting_brief_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
  }) async {
    final start = now.add(startsIn);
    await calendar.upsertEvents([
      CalendarEvent(
        id: id,
        subject: 'Fabrikam sync',
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
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

  Future<void> seedThread() async {
    final at = MessageStore.isoStamp(now.subtract(const Duration(hours: 2)));
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
    'headline': 'Dana is waiting on the quote.',
    'points': [
      {'text': 'The quote is owed.', 'thread': 1},
    ],
    'open_asks': [
      {'person': 'Dana', 'ask': 'Send the quote', 'thread': 1},
    ],
    'prep': ['Have the quote ready'],
  };

  test('writes a ready brief with the thread list it points into', () async {
    await seedEvent();
    await seedThread();
    final llm = ScriptedLlm(answers: {'meeting_brief': answer});

    await handler(llm).run(item('evt-1'));

    expect(llm.schemas, ['meeting_brief']);
    expect(llm.temperatures, [0.2]);
    expect(llm.budgets['meeting_brief'], 700);
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
