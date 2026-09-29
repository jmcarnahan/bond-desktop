import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late CalendarStore calendar;
  late MessageStore store;

  setUpAll(initCalendarZones);

  setUp(() {
    db = testDb();
    calendar = CalendarStore(db);
    store = MessageStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  final now = DateTime.now().toUtc();
  DateTime inHours(num h) =>
      now.add(Duration(minutes: (h * 60).round()));

  CalendarEvent timed(
    String id, {
    required DateTime start,
    DateTime? end,
    String eventType = 'singleInstance',
    bool isCancelled = false,
    bool isOrganizer = false,
    String responseStatus = 'none',
    bool? responseRequested,
    String organizerAddress = 'dana@contoso.com',
    List<Attendee> attendees = const [],
    String changeKey = 'ck-1',
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Meeting $id',
        eventType: eventType,
        startUtc: start,
        endUtc: end ?? start.add(const Duration(minutes: 30)),
        isCancelled: isCancelled,
        isOrganizer: isOrganizer,
        responseStatus: responseStatus,
        responseRequested: responseRequested,
        organizerAddress: organizerAddress,
        attendees: attendees,
        changeKey: changeKey,
      );

  CalendarEvent allDay(
    String id,
    CalendarDate start, {
    CalendarDate? end,
    String responseStatus = 'none',
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Day $id',
        isAllDay: true,
        startDate: start,
        endDate: end ?? start.addDays(1),
        responseStatus: responseStatus,
      );

  Future<int> count() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM calendar_events')
          .getSingle())
      .data['n'] as int;

  group('writes', () {
    test('an upsert of a known id replaces its fields and its run', () async {
      final start = inHours(3);
      expect(
        await calendar.upsertEvents([timed('evt-1', start: start)],
            syncRun: 'run-a'),
        1,
      );
      await calendar.upsertEvents(
        [timed('evt-1', start: start, changeKey: 'ck-2')],
        syncRun: 'run-b',
      );

      final stored = await calendar.event('evt-1');
      expect(stored!.changeKey, 'ck-2');
      expect(stored.startUtc, DateTime.parse(calendarStamp(start)));
      expect(await count(), 1);
      final run = await db
          .customSelect("SELECT sync_run FROM calendar_events WHERE id = 'evt-1'")
          .getSingle();
      expect(run.data['sync_run'], 'run-b');
    });

    test('ids in skipIds are not written', () async {
      await calendar.upsertEvents([timed('evt-1', start: inHours(3))],
          syncRun: 'run-a');
      final written = await calendar.upsertEvents(
        [
          timed('evt-1', start: inHours(3), changeKey: 'stale'),
          timed('evt-2', start: inHours(4)),
        ],
        syncRun: 'run-a',
        skipIds: {'evt-1'},
      );
      expect(written, 1);
      expect((await calendar.event('evt-1'))!.changeKey, 'ck-1');
      expect(await calendar.event('evt-2'), isNotNull);
    });

    test('deleteEvents ignores ids it never stored', () async {
      await calendar.upsertEvents([
        timed('evt-1', start: inHours(1)),
        timed('evt-2', start: inHours(2)),
      ], syncRun: 'run-a');
      expect(await calendar.deleteEvents(['evt-1', 'never-seen']), 1);
      expect(await calendar.deleteEvents(const []), 0);
      expect(await count(), 1);
    });

    test('sweepRun deletes other runs except the kept ids', () async {
      await calendar.upsertEvents([
        timed('old-1', start: inHours(1)),
        timed('old-2', start: inHours(2)),
      ], syncRun: 'run-a');
      await calendar.upsertEvents([timed('new-1', start: inHours(3))],
          syncRun: 'run-b');

      expect(await calendar.sweepRun('run-b', keepIds: {'old-2'}), 1);
      expect(await calendar.event('old-1'), isNull);
      expect(await calendar.event('old-2'), isNotNull);
      expect(await calendar.event('new-1'), isNotNull);
    });

    test('retagRun moves only the named rows into the run, and nothing else',
        () async {
      await calendar.upsertEvents([
        timed('mine', start: inHours(1), changeKey: 'after-write'),
        timed('theirs', start: inHours(2)),
      ], syncRun: 'run-a');

      expect(await calendar.retagRun(['mine', 'never-seen'], 'run-b'), 1);
      expect(await calendar.retagRun(const [], 'run-b'), 0);
      expect((await calendar.event('mine'))!.changeKey, 'after-write');

      expect(await calendar.sweepRun('run-b'), 1);
      expect(await calendar.event('mine'), isNotNull);
      expect(await calendar.event('theirs'), isNull);
    });
  });

  group('eventsBetween', () {
    // The first Sunday of November 2026: Los Angeles leaves daylight time
    // that morning, so its day is 25 hours long.
    const day = CalendarDate(2026, 11, 1);

    Future<List<String>> idsOnDay(CalendarZone zone, CalendarDate d) async {
      final events = await calendar.eventsBetween(
        startUtc: zone.localDateTime(d, 0, 0).toUtc(),
        endUtc: zone.localDateTime(d.addDays(1), 0, 0).toUtc(),
        fromDate: d,
        toDateExclusive: d.addDays(1),
      );
      return [for (final e in events) e.id];
    }

    for (final name in [
      'America/Los_Angeles',
      'UTC',
      'Pacific/Auckland',
    ]) {
      test('a 23:30 meeting and an all-day event land on their day in $name',
          () async {
        final zone = CalendarZone.tryNamed(name)!;
        final lateStart = zone.localDateTime(day, 23, 30).toUtc();
        await calendar.upsertEvents([
          timed('late', start: lateStart),
          allDay('holiday', day),
        ], syncRun: 'r');

        expect(await idsOnDay(zone, day), ['holiday', 'late']);
        expect(await idsOnDay(zone, day.addDays(1)), isEmpty);
        expect(await idsOnDay(zone, day.addDays(-1)), isEmpty);
      });
    }

    test('a meeting across midnight shows on both days', () async {
      final zone = CalendarZone.utc();
      await calendar.upsertEvents([
        timed(
          'overnight',
          start: DateTime.utc(2026, 11, 1, 23),
          end: DateTime.utc(2026, 11, 2, 1),
        ),
      ], syncRun: 'r');
      expect(await idsOnDay(zone, day), ['overnight']);
      expect(await idsOnDay(zone, day.addDays(1)), ['overnight']);
    });

    test('a meeting ending at midnight is not on the next day', () async {
      final zone = CalendarZone.utc();
      await calendar.upsertEvents([
        timed(
          'to-midnight',
          start: DateTime.utc(2026, 11, 1, 23),
          end: DateTime.utc(2026, 11, 2),
        ),
      ], syncRun: 'r');
      expect(await idsOnDay(zone, day.addDays(1)), isEmpty);
    });

    test('series masters are left out, cancelled events kept', () async {
      final zone = CalendarZone.utc();
      await calendar.upsertEvents([
        timed('master',
            start: DateTime.utc(2026, 11, 1, 9), eventType: 'seriesMaster'),
        timed('occurrence',
            start: DateTime.utc(2026, 11, 1, 9), eventType: 'occurrence'),
        timed('cancelled', start: DateTime.utc(2026, 11, 1, 10),
            isCancelled: true),
      ], syncRun: 'r');
      expect(await idsOnDay(zone, day), ['occurrence', 'cancelled']);
    });

    test('a zero-length event counts when it starts inside the span',
        () async {
      final zone = CalendarZone.utc();
      final at = DateTime.utc(2026, 11, 1, 12);
      await calendar.upsertEvents([
        timed('instant', start: at, end: at),
        timed('at-midnight',
            start: DateTime.utc(2026, 11, 2), end: DateTime.utc(2026, 11, 2)),
      ], syncRun: 'r');
      expect(await idsOnDay(zone, day), ['instant']);
      expect(await idsOnDay(zone, day.addDays(1)), ['at-midnight']);
    });

    test('all-day first, then by start', () async {
      final zone = CalendarZone.utc();
      await calendar.upsertEvents([
        timed('b', start: DateTime.utc(2026, 11, 1, 14)),
        timed('a', start: DateTime.utc(2026, 11, 1, 9)),
        allDay('multi', day.addDays(-1), end: day.addDays(2)),
      ], syncRun: 'r');
      expect(await idsOnDay(zone, day), ['multi', 'a', 'b']);
    });
  });

  group('invitesOwed', () {
    test('keeps only future invites still owed an answer', () async {
      final today = CalendarDate.ofDateTime(now);
      await calendar.upsertEvents([
        timed('owed', start: inHours(5)),
        timed('owed-soon', start: inHours(1), responseStatus: 'notResponded'),
        timed('asked-explicitly', start: inHours(6), responseRequested: true),
        timed('no-reply-wanted', start: inHours(5), responseRequested: false),
        timed('accepted', start: inHours(5), responseStatus: 'accepted'),
        timed('mine', start: inHours(5), isOrganizer: true),
        timed('cancelled', start: inHours(5), isCancelled: true),
        timed('past', start: inHours(-2)),
        timed('master', start: inHours(5), eventType: 'seriesMaster'),
        allDay('all-day-today', today),
        allDay('all-day-yesterday', today.addDays(-1)),
      ], syncRun: 'r');

      final owed = await calendar.invitesOwed(nowUtc: now, today: today);
      final ids = [for (final e in owed) e.id];
      expect(ids.toSet(),
          {'owed', 'owed-soon', 'asked-explicitly', 'all-day-today'});
      // Soonest first: today's all-day event sorts at its UTC midnight.
      expect(ids.first, 'all-day-today');
      expect(ids.indexOf('owed-soon'), lessThan(ids.indexOf('owed')));
      expect(ids.indexOf('owed'), lessThan(ids.indexOf('asked-explicitly')));
      for (final e in owed) {
        expect(e.needsResponse, isTrue, reason: e.id);
      }
    });
  });

  group('meetings with a person', () {
    const dana = Attendee(name: 'Dana', address: 'dana@contoso.com');
    const sam = Attendee(name: 'Sam', address: 'sam@fabrikam.com');

    setUp(() async {
      await calendar.upsertEvents([
        timed('past-with-sam',
            start: inHours(-5), attendees: const [sam], organizerAddress: ''),
        timed('recent-with-sam',
            start: inHours(-2), attendees: const [sam], organizerAddress: ''),
        timed('running-now',
            start: inHours(-0.25), attendees: const [sam], organizerAddress: ''),
        timed('next-with-sam',
            start: inHours(2), attendees: const [sam], organizerAddress: ''),
        timed('later-with-sam',
            start: inHours(5), attendees: const [sam], organizerAddress: ''),
        timed('declined-with-sam',
            start: inHours(1),
            attendees: const [sam],
            organizerAddress: '',
            responseStatus: 'declined'),
        timed('cancelled-with-sam',
            start: inHours(1.5),
            attendees: const [sam],
            organizerAddress: '',
            isCancelled: true),
        timed('dana-organises',
            start: inHours(3),
            attendees: const [dana],
            organizerAddress: 'DANA@contoso.com'),
      ], syncRun: 'r');
    });

    test('nextMeetingWith matches attendees case-insensitively', () async {
      final next = await calendar.nextMeetingWith(
        [' Sam@Fabrikam.com '],
        nowUtc: now,
      );
      expect(next?.id, 'next-with-sam');
    });

    test('nextMeetingWith matches the organiser', () async {
      final next = await calendar
          .nextMeetingWith(['nobody@example.com', 'dana@contoso.com'], nowUtc: now);
      expect(next?.id, 'dana-organises');
    });

    test('lastMetWith is the latest meeting that has ended', () async {
      final last =
          await calendar.lastMetWith(['sam@fabrikam.com'], nowUtc: now);
      expect(last?.id, 'recent-with-sam');
    });

    test('no addresses means no answer', () async {
      expect(await calendar.nextMeetingWith(const [], nowUtc: now), isNull);
      expect(await calendar.lastMetWith(['  '], nowUtc: now), isNull);
      expect(
        await calendar.nextMeetingWith(['stranger@example.com'], nowUtc: now),
        isNull,
      );
    });
  });

  group('messagesForEvent', () {
    Future<void> seed(String id, String? meta, DateTime receivedAt) =>
        store.upsertMessage({
          'source': 'email',
          'source_message_id': id,
          'conversation_key': 'conv-$id',
          'direction': 'inbound',
          'subject': 'Invitation: Planning',
          'from_name': 'Dana',
          'from_address': 'dana@contoso.com',
          'received_at': MessageStore.isoStamp(receivedAt),
          'body_text': 'Body of $id',
          'triage_status': 'pending',
          'source_meta_json': meta,
        });

    test('finds the linked messages newest first, past malformed meta',
        () async {
      final link = jsonEncode({'meeting': 'meetingRequest', 'event_id': 'evt-1'});
      await seed('m-old', link, now.subtract(const Duration(hours: 5)));
      await seed('m-new', link, now.subtract(const Duration(hours: 1)));
      await seed('m-other',
          jsonEncode({'meeting': 'meetingRequest', 'event_id': 'evt-2'}),
          now.subtract(const Duration(hours: 2)));
      await seed('m-broken', '{not json', now.subtract(const Duration(hours: 3)));
      await seed('m-none', null, now.subtract(const Duration(hours: 4)));

      final refs = await calendar.messagesForEvent('evt-1');
      expect([for (final r in refs) r.sourceMessageId], ['m-new', 'm-old']);
      expect(refs.first.source, 'email');
      expect(refs.first.conversationKey, 'conv-m-new');
      expect(await calendar.messagesForEvent('evt-missing'), isEmpty);
    });
  });
}
