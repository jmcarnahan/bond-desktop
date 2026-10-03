import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/brief_planner.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('a fresh brief is left alone, whatever changed', () async {
    await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
    await calendar.putBrief(
      eventId: 'evt-1',
      inputsHash: 'something else',
      status: EventBrief.ready,
      generatedAt: calendarStamp(now.subtract(const Duration(minutes: 30))),
    );
    expect(await plan(), 0);
    expect(await status('evt-1'), isNull);
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
    test('two plans a minute apart gather once; sixteen minutes later, again',
        () async {
      await calendar.upsertEvents([meeting('evt-1')], syncRun: 'run-1');
      await readyBrief('evt-1', hash: await currentHash('evt-1'));

      expect(await plan(), 0);
      expect(gatherer.gathers, 1);
      expect(await plan(after: const Duration(minutes: 1)), 0);
      expect(gatherer.gathers, 1, reason: 'checked a minute ago, row unmoved');
      expect(await plan(after: const Duration(minutes: 16)), 0);
      expect(gatherer.gathers, 2);
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
  });

  int gathers = 0;

  @override
  Future<BriefGather> gather(CalendarEvent event, {required DateTime now}) {
    gathers++;
    return super.gather(event, now: now);
  }
}
