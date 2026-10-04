import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/brief_planner.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/test_db.dart';

/// The planner over a real mirror: which meetings it queues after a sync,
/// the two-hour and inputs-hash regeneration rule, the cap, and the
/// housekeeping. It never calls a model, so there is no LLM double here.
void main() {
  setUpAll(initCalendarZones);

  const owner = 'me@contoso.com';
  const dana = 'dana@fabrikam.com';
  const ed = 'ed@northwind.com';

  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late _CountingGatherer gatherer;
  late BriefPlanner planner;
  late CalendarZone la;
  late DateTime now;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    gatherer = _CountingGatherer(
      store,
      calendar,
      ownerAddress: () async => owner,
      zone: () => la,
    );
    planner = BriefPlanner(store, calendar, gatherer);
    now = DateTime.now().toUtc();

    // One thread with Dana in the last day: every meeting with her is
    // eligible on the mail rule.
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c-1',
      'subject': 'Fabrikam renewal',
      'participants_json': jsonEncode([
        {'name': 'Dana', 'email': dana},
      ]),
      'state': 'waiting',
      'message_count': 1,
      'last_message_at':
          MessageStore.isoStamp(now.subtract(const Duration(hours: 2))),
    });
  });

  tearDown(() async {
    await db.close();
  });

  CalendarEvent meeting(
    String id, {
    Duration startsIn = const Duration(hours: 3),
    List<Attendee> attendees = const [Attendee(name: 'Dana Lee', address: dana)],
    bool isCancelled = false,
    String eventType = 'singleInstance',
  }) {
    final start = now.add(startsIn);
    return CalendarEvent(
      id: id,
      subject: 'Meeting $id',
      eventType: eventType,
      startUtc: start,
      endUtc: start.add(const Duration(minutes: 30)),
      responseStatus: 'accepted',
      isCancelled: isCancelled,
      attendees: attendees,
    );
  }

  Future<String?> status(String id) =>
      store.workStatusOf(BriefPlanner.kind, BriefPlanner.source, id);

  Future<int> plan({Duration after = Duration.zero}) =>
      planner.plan(now: now.add(after), zone: la);

  Future<void> readyBrief(String id, {String hash = 'h'}) => calendar.putBrief(
        eventId: id,
        inputsHash: hash,
        status: EventBrief.ready,
        briefJson: '{"headline":"Old."}',
        generatedAt: calendarStamp(now.subtract(const Duration(hours: 3))),
      );

  Future<String> currentHash(String id) async {
    final g = await gatherer.gather(meeting(id), now: now);
    gatherer.gathers--;
    return (g as BriefEligible).input.inputsHash;
  }

  test('queues eligible meetings only, at most six a pass, soonest first',
      () async {
    await calendar.upsertEvents([
      for (var i = 0; i < 8; i++)
        meeting('evt-$i', startsIn: Duration(hours: i + 1)),
      meeting('solo', attendees: const [Attendee(name: 'Me', address: owner)]),
      meeting('off', isCancelled: true),
      meeting('far', startsIn: const Duration(hours: 40)),
    ], syncRun: 'run-1');

    expect(await plan(), BriefPlanner.maxPerPass);
    for (var i = 0; i < 6; i++) {
      expect(await status('evt-$i'), 'pending', reason: 'evt-$i');
    }
    expect(await status('evt-6'), isNull, reason: 'past the cap');
    expect(await status('solo'), isNull);
    expect(await status('off'), isNull);
    expect(await status('far'), isNull);
  });

  test('a series master is never planned', () async {
    await calendar.upsertEvents([
      meeting('master', eventType: 'seriesMaster'),
    ], syncRun: 'run-1');
    expect(await plan(), 0);
    expect(await status('master'), isNull);
  });

  test('a fresh brief is left alone unless its inputs moved', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    final young = calendarStamp(now.subtract(const Duration(minutes: 30)));
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: await currentHash('evt-1'),
      status: EventBrief.ready,
      generatedAt: young,
    );
    expect(await plan(), 0, reason: 'fresh and unchanged');
    expect(await status('evt-1'), isNull);

    // A deck (or its digest) landed: the same young brief, inputs moved.
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: 'something else',
      status: EventBrief.ready,
      generatedAt: young,
    );
    expect(await plan(after: const Duration(minutes: 16)), 1,
        reason: 're-briefed within one recheck, not after two hours');
    expect(await status('evt-1'), 'pending');
  });

  test('a fresh brief whose rewrite failed is not retried on the same '
      'inputs until it ages, and is when they move again', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: 'stale',
      status: EventBrief.ready,
      generatedAt: calendarStamp(now.subtract(const Duration(minutes: 30))),
    );
    expect(await plan(), 1);

    // The rewrite failed: the worker finished the row, and the handler kept
    // the old brief, moving only its stamp (`touchBrief`).
    await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
        status: 'done');
    await calendar.touchBrief('evt-1',
        generatedAt: calendarStamp(now.add(const Duration(minutes: 1))));
    expect(await plan(after: const Duration(minutes: 20)), 0,
        reason: 'these inputs were already tried while the brief is fresh');

    // New mail moves the inputs again.
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c-1',
      'subject': 'Fabrikam renewal',
      'participants_json': jsonEncode([
        {'name': 'Dana', 'email': dana},
      ]),
      'state': 'waiting',
      'message_count': 2,
      'last_message_at':
          MessageStore.isoStamp(now.add(const Duration(minutes: 30))),
    });
    expect(await plan(after: const Duration(minutes: 40)), 1);

    // A failed row on unchanged inputs waits out the two hours.
    await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
        status: 'done');
    final fresh = BriefPlanner(store, calendar, gatherer);
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: await currentHash('evt-1'),
      status: EventBrief.failed,
      generatedAt: calendarStamp(now.add(const Duration(minutes: 40))),
    );
    expect(await fresh.plan(now: now.add(const Duration(minutes: 41)), zone: la),
        0);
    // Two hours and five minutes after the failure; the meeting is still
    // ahead (it starts three hours after `now`).
    expect(
        await fresh.plan(
            now: now.add(const Duration(hours: 2, minutes: 45)), zone: la),
        1);
  });

  test('a ready brief whose rewrite failed IS retried on the same moved '
      'inputs once it is older than two hours', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: 'stale',
      status: EventBrief.ready,
      generatedAt: calendarStamp(now.subtract(const Duration(minutes: 30))),
    );
    expect(await plan(), 1);
    await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
        status: 'done');
    await calendar.touchBrief('evt-1', generatedAt: calendarStamp(now));
    expect(await plan(after: const Duration(minutes: 20)), 0,
        reason: 'tried once while fresh');

    // Two hours and a bit after the failed rewrite's stamp: the same moved
    // inputs are tried again.
    expect(await plan(after: const Duration(hours: 2, minutes: 5)), 1);
    expect(await status('evt-1'), 'pending');
  });

  test('the planner makes no embedding call, even when the files have '
      'passages', () async {
    final chunks = _ChunkStore(db);
    final server = FakeEmbedServer();
    final counting = _CountingGatherer(
      chunks,
      calendar,
      ownerAddress: () async => owner,
      zone: () => la,
      embeddings: server.client,
    );
    final planning = BriefPlanner(chunks, calendar, counting);
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm-1',
      'conversation_key': 'c-1',
      'direction': 'inbound',
      'from_name': 'Dana',
      'from_address': dana,
      'received_at':
          MessageStore.isoStamp(now.subtract(const Duration(hours: 2))),
      'body_text': 'Deck attached.',
      'triage_status': 'done',
    });
    await store.upsertAttachments('email', 'm-1', [
      {
        'attachment_id': 'a-deck',
        'ordinal': 0,
        'kind': 'file',
        'name': 'deck.pptx',
        'is_inline': 0,
      },
    ]);
    await calendar.upsertEvents([meeting('evt-1'), meeting('evt-2')],
        syncRun: 'run-1');

    expect(await planning.plan(now: now, zone: la), 2);
    expect(counting.gathers, 2);
    expect(counting.passageAsks, [false, false]);
    expect(server.calls, 0);
    expect(chunks.knnCalls, 0);

    // The handler's gather (the default) is the one that embeds — once.
    final asked = await counting.gather(meeting('evt-1'), now: now);
    expect((asked as BriefEligible).input.materials.single.passages,
        isNotEmpty);
    expect(server.calls, 1);
  });

  test('an old brief is requeued only when its inputs moved', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    final current = await gatherer.gather(meeting('evt-1'), now: now);
    final hash = (current as BriefEligible).input.inputsHash;
    final old = calendarStamp(now.subtract(const Duration(hours: 3)));

    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: hash,
      status: EventBrief.ready,
      generatedAt: old,
    );
    expect(await plan(), 0, reason: 'same inputs: nothing to rewrite');

    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: 'stale',
      status: EventBrief.ready,
      generatedAt: old,
    );
    // Past the recheck throttle: the row's stamp did not move, so a plan
    // inside fifteen minutes of the last would not gather it again.
    expect(await plan(after: const Duration(minutes: 16)), 1);
    expect(await status('evt-1'), 'pending');
  });

  test('a done work row is revived; a pending one is not counted twice',
      () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    await store.enqueueWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1');
    expect(await plan(), 0, reason: 'already waiting');

    await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
        status: 'done');
    expect(await plan(), 1);
    expect(await status('evt-1'), 'pending');
  });

  test('briefs of events out of the window are deleted', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    for (final id in ['evt-1', 'gone']) {
      await calendar.putBrief(
        eventId: id,
        inputsHash: 'h',
        status: EventBrief.skipped,
        generatedAt: calendarStamp(now),
      );
    }
    await plan();
    expect((await calendar.briefsFor(['evt-1', 'gone'])).keys, ['evt-1']);
  });

  test('nothing is planned while the owner is unknown', () async {
    final blind = BriefPlanner(
      store,
      calendar,
      BriefGatherer(
        store,
        calendar,
        ownerAddress: () async => null,
        zone: () => la,
      ),
    );
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    await calendar.putBrief(
      eventId: 'other',
      inputsHash: 'h',
      status: EventBrief.skipped,
      generatedAt: calendarStamp(now),
    );

    expect(await blind.plan(now: now, zone: la), 0);
    expect(await status('evt-1'), isNull);
    expect((await calendar.briefsFor(['other'])).keys, ['other'],
        reason: 'not even the housekeeping runs');
  });

  group('the recheck throttle', () {
    test('a failed brief waits out the recheck: two plans a minute apart '
        'gather once; sixteen minutes later, again', () async {
      await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
      await calendar.putBrief(
        eventId: 'evt-1',
        inputsHash: await currentHash('evt-1'),
        status: EventBrief.failed,
        generatedAt: calendarStamp(now),
      );

      expect(await plan(), 0);
      expect(gatherer.gathers, 1);
      expect(await plan(after: const Duration(minutes: 1)), 0);
      expect(gatherer.gathers, 1, reason: 'checked a minute ago, row unmoved');
      expect(await plan(after: const Duration(minutes: 16)), 0);
      expect(gatherer.gathers, 2);
    });

    test('a skipped meeting is gathered again on the next pass once its mail '
        'arrives', () async {
      // A Gmail invite: the event syncs a few seconds before its mail.
      await calendar.upsertEvents([
        meeting('evt-ed', attendees: const [Attendee(name: 'Ed', address: ed)]),
      ], syncRun: 'run-1');
      expect(await plan(), 0);
      expect((await calendar.brief('evt-ed'))?.skipReason, 'no_mail');
      expect(gatherer.gathers, 1);

      // Still no mail: gathered again, nothing rewritten or queued.
      expect(await plan(after: const Duration(seconds: 30)), 0);
      expect(gatherer.gathers, 2, reason: 'a skipped row is never throttled');
      expect(await status('evt-ed'), isNull);

      final at = MessageStore.isoStamp(now);
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c-invite',
        'subject': 'Invitation: Northwind',
        'participants_json': jsonEncode([
          {'name': 'Me', 'email': owner},
        ]),
        'state': 'waiting',
        'message_count': 1,
        'last_message_at': at,
      });
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-invite',
        'conversation_key': 'c-invite',
        'direction': 'inbound',
        'from_name': 'Calendar',
        'from_address': 'calendar-notification@example.com',
        'received_at': at,
        'body_text': 'You have been invited.',
        'triage_status': 'done',
        'source_meta_json':
            jsonEncode({'meeting': 'meetingRequest', 'event_id': 'evt-ed'}),
      });
      expect(await plan(after: const Duration(minutes: 1)), 1);
      expect(await status('evt-ed'), 'pending');
    });

    test('a ready brief is gathered on every pass and queued when its hash '
        'moved — the recheck no longer holds a ready row', () async {
      await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
      await readyBrief('evt-1', hash: await currentHash('evt-1'));
      expect(await plan(), 0);
      expect(gatherer.gathers, 1);
      expect(await plan(after: const Duration(seconds: 30)), 0,
          reason: 'unchanged: gathered, nothing queued');
      expect(gatherer.gathers, 2);

      // New mail moves the hash a minute later: queued on this pass, not a
      // quarter of an hour later.
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c-1',
        'subject': 'Fabrikam renewal',
        'participants_json': jsonEncode([
          {'name': 'Dana', 'email': dana},
        ]),
        'state': 'waiting',
        'message_count': 2,
        'last_message_at': MessageStore.isoStamp(now),
      });
      expect(await plan(after: const Duration(minutes: 1)), 1);
      expect(gatherer.gathers, 3);
      expect(await status('evt-1'), 'pending');
    });

    /// m-1 an hour old (inside the wait's age cap) carrying a deck whose
    /// text work is queued and not done: a file being read.
    Future<void> seedPendingDeck() async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-1',
        'conversation_key': 'c-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'from_address': dana,
        'received_at':
            MessageStore.isoStamp(now.subtract(const Duration(hours: 1))),
        'body_text': 'The deck.',
        'triage_status': 'done',
      });
      await store.upsertAttachments('email', 'm-1', [
        {
          'attachment_id': 'a-deck',
          'ordinal': 0,
          'kind': 'file',
          'name': 'deck.pdf',
          'content_type': 'application/pdf',
          'is_inline': 0,
        },
      ]);
      await store.enqueueWork(
          'attachment_text', 'email', attachmentEntityId('m-1', 'a-deck'));
    }

    test('a meeting waiting on its files is queued when the text lands, and '
        'once more on the same inputs when it comes inside the grace',
        () async {
      await seedPendingDeck();
      await calendar.upsertEvents([
        meeting('evt-1', startsIn: const Duration(minutes: 50)),
      ], syncRun: 'run-1');
      expect(await plan(), 1, reason: 'no row yet');
      // The handler found the deck pending and said so.
      await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
          status: 'done');
      await calendar.putBrief(
        eventId: 'evt-1',
        inputsHash: 'ineligible:materials_pending',
        status: EventBrief.skipped,
        generatedAt: calendarStamp(now),
      );
      expect(await plan(after: const Duration(minutes: 1)), 0,
          reason: 'the same inputs were queued already');

      // Inside the grace (twenty minutes before the start), still pending:
      // queued once on the same hash, so it is briefed with what is read.
      expect(await plan(after: const Duration(minutes: 31)), 1);
      expect(await status('evt-1'), 'pending');
      expect(await plan(after: const Duration(minutes: 32)), 0,
          reason: 'already waiting');

      // Or the text lands before then: the hash moves and it is queued.
      await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
          status: 'done');
      final again = BriefPlanner(store, calendar, gatherer);
      expect(await again.plan(now: now, zone: la), 1,
          reason: 'a new planner has queued nothing yet');
      await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
          status: 'done');
      expect(await again.plan(now: now.add(const Duration(minutes: 1)), zone: la),
          0);
      await store.setAttachmentText('email', 'm-1', 'a-deck',
          status: 'done', text: 'Two tiers.');
      expect(await again.plan(now: now.add(const Duration(minutes: 2)), zone: la),
          1);
    });

    test('a materials_pending row is queued when the wait ends without the '
        'hash moving', () async {
      await seedPendingDeck();
      await calendar.upsertEvents([
        meeting('evt-1', startsIn: const Duration(hours: 5)),
      ], syncRun: 'run-1');
      expect(await plan(), 1, reason: 'no row yet');
      await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
          status: 'done');
      await calendar.putBrief(
        eventId: 'evt-1',
        inputsHash: 'ineligible:materials_pending',
        status: EventBrief.skipped,
        generatedAt: calendarStamp(now),
      );
      expect(await plan(after: const Duration(minutes: 1)), 0,
          reason: 'still being read');

      // The text work gives up: the attachment row still says pending, so
      // the hash is the same, but nothing is being read any more.
      final hash = await currentHash('evt-1');
      await db.customStatement("UPDATE work_items SET status = 'error' "
          "WHERE task_kind = 'attachment_text'");
      expect(await currentHash('evt-1'), hash);
      expect(await plan(after: const Duration(minutes: 2)), 1);
      expect(await status('evt-1'), 'pending');

      // A handler that throws before it writes leaves the same row: queued
      // once, not every pass.
      await store.writeWork(BriefPlanner.kind, BriefPlanner.source, 'evt-1',
          status: 'error');
      expect(await plan(after: const Duration(minutes: 3)), 0);
    });

    test('a cleared table gathers at once', () async {
      await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
      await readyBrief('evt-1', hash: await currentHash('evt-1'));
      expect(await plan(), 0);
      expect(gatherer.gathers, 1);

      // Clear AI results empties the derived table.
      await calendar.deleteBriefsExcept(const []);
      expect(await plan(after: const Duration(minutes: 1)), 1);
      expect(gatherer.gathers, 2);
      expect(await status('evt-1'), 'pending');
    });
  });

  group('the ineligible reasons it records', () {
    test('no mail, nobody else and too many people each get a skipped row, '
        'with no work queued', () async {
      await calendar.upsertEvents([
        meeting('evt-ed', attendees: const [Attendee(name: 'Ed', address: ed)]),
        meeting('solo',
            attendees: const [Attendee(name: 'Me', address: owner)]),
        meeting('town-hall', attendees: [
          const Attendee(name: 'Dana Lee', address: dana),
          for (var i = 0; i < briefMaxOthers; i++)
            Attendee(name: 'Guest $i', address: 'guest$i@fabrikam.com'),
        ]),
      ], syncRun: 'run-1');

      expect(await plan(), 0);
      final rows = await calendar.briefsFor(['evt-ed', 'solo', 'town-hall']);
      expect(rows['evt-ed']?.skipReason, 'no_mail');
      expect(rows['solo']?.skipReason, 'no_others');
      expect(rows['town-hall']?.skipReason, 'too_many');
      for (final id in ['evt-ed', 'solo', 'town-hall']) {
        expect(await status(id), isNull, reason: id);
      }
    });

    test('a row that already says so is not rewritten', () async {
      await calendar.upsertEvents([
        meeting('evt-ed', attendees: const [Attendee(name: 'Ed', address: ed)]),
      ], syncRun: 'run-1');
      final old = calendarStamp(now.subtract(const Duration(hours: 3)));
      await calendar.putBrief(
        eventId: 'evt-ed',
        inputsHash: '${EventBrief.ineligiblePrefix}no_mail',
        status: EventBrief.skipped,
        generatedAt: old,
      );
      await plan();
      expect((await calendar.brief('evt-ed'))!.generatedAt, old);
    });

    test('a ready brief is left standing when the mail ages out', () async {
      await calendar.upsertEvents([
        meeting('evt-ed', attendees: const [Attendee(name: 'Ed', address: ed)]),
      ], syncRun: 'run-1');
      await readyBrief('evt-ed');
      await plan();
      final row = (await calendar.brief('evt-ed'))!;
      expect(row.status, EventBrief.ready);
      expect(row.briefJson, '{"headline":"Old."}');
    });

    test('once mail arrives, an old no_mail row is queued like any other',
        () async {
      await calendar.upsertEvents([
        meeting('evt-ed', attendees: const [Attendee(name: 'Ed', address: ed)]),
      ], syncRun: 'run-1');
      await calendar.putBrief(
        eventId: 'evt-ed',
        inputsHash: '${EventBrief.ineligiblePrefix}no_mail',
        status: EventBrief.skipped,
        generatedAt: calendarStamp(now.subtract(const Duration(hours: 3))),
      );
      expect(await plan(), 0);

      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c-ed',
        'subject': 'Northwind',
        'participants_json': jsonEncode([
          {'name': 'Ed', 'email': ed},
        ]),
        'state': 'waiting',
        'message_count': 1,
        'last_message_at':
            MessageStore.isoStamp(now.subtract(const Duration(hours: 1))),
      });
      expect(await plan(after: const Duration(minutes: 16)), 1);
      expect(await status('evt-ed'), 'pending');
    });
  });

  test('queued so the soonest drains first, timed meetings before all-day',
      () async {
    final tomorrow = la.dateOf(now).addDays(1);
    await calendar.upsertEvents([
      // Ids in the opposite order to the starts, so a tie on the stamp
      // (broken by entity id, descending) could not pass this by accident.
      meeting('a-soon', startsIn: const Duration(hours: 1)),
      meeting('b-mid', startsIn: const Duration(hours: 3)),
      meeting('c-late', startsIn: const Duration(hours: 5)),
      CalendarEvent(
        id: 'd-allday',
        subject: 'Offsite',
        isAllDay: true,
        startDate: tomorrow,
        endDate: tomorrow.addDays(1),
        responseStatus: 'accepted',
        attendees: const [Attendee(name: 'Dana Lee', address: dana)],
      ),
    ], syncRun: 'run-1');

    expect(await plan(), 4);
    final drained = <String>[];
    while (true) {
      final item = await store.claimPendingWork(BriefPlanner.kind,
          sources: AiWorker.sources);
      if (item == null) break;
      drained.add(item['entity_id'] as String);
    }
    expect(drained, ['a-soon', 'b-mid', 'c-late', 'd-allday']);
  });
}

/// The real gatherer, counting its gathers: the recheck throttle is about
/// how often this runs.
class _CountingGatherer extends BriefGatherer {
  _CountingGatherer(
    super.store,
    super.calendar, {
    required super.ownerAddress,
    required super.zone,
    super.embeddings,
  });

  int gathers = 0;

  /// The `passages` flag of every gather, in order.
  final List<bool> passageAsks = [];

  @override
  Future<BriefGather> gather(
    CalendarEvent event, {
    required DateTime now,
    bool passages = true,
  }) {
    gathers++;
    passageAsks.add(passages);
    return super.gather(event, now: now, passages: passages);
  }
}

/// [MessageStore] whose files always have chunks and whose KNN answers one
/// passage per file, so a gather that asked for passages would embed.
class _ChunkStore extends MessageStore {
  _ChunkStore(super.db);

  int knnCalls = 0;

  @override
  Future<bool> hasAttachmentChunks(
    String source, {
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
  }) async =>
      true;

  @override
  Future<List<AttachmentChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required String source,
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
    int limit = 6,
  }) async {
    knnCalls++;
    return [
      for (final id in attachmentIds)
        AttachmentChunkHit(
          ref: AttachmentRef(source: source, messageId: 'm-1', attachmentId: id),
          chunkId: 1,
          seq: 0,
          locator: 'slide 1',
          text: 'Words.',
          outbound: false,
        ),
    ];
  }
}
