import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/day_providers.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The Day stop's reads, over a real in-memory mirror: what a day holds, the
/// availability gate, and the invites folded, pinned and overlapped.
void main() {
  setUpAll(initCalendarZones);

  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late CalendarZone la;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer containerFor(CalendarAvailability availability,
      {bool processingOn = true}) {
    final container = ProviderContainer(overrides: [
      processingProvider
          .overrideWith((ref) => ProcessingNotifier(processingOn)),
      dbProvider.overrideWithValue(db),
      calendarAvailabilityProvider.overrideWith((ref) => availability),
      calendarZoneProvider.overrideWith((ref) async => la),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Reads an autoDispose future provider with a listener held, so it is not
  /// disposed between the read and the answer.
  Future<T> readFuture<T>(
    ProviderContainer container,
    ProviderListenable<Future<T>> provider,
  ) {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    return sub.read();
  }

  CalendarEvent timed(
    String id,
    DateTime start, {
    String responseStatus = 'none',
    String seriesMasterId = '',
    String eventType = 'singleInstance',
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Meeting $id',
        eventType: eventType,
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        responseStatus: responseStatus,
        seriesMasterId: seriesMasterId,
        organizerAddress: 'lead@contoso.com',
        showAs: 'busy',
      );

  group('dayEventsProvider', () {
    // A fixed day: nothing here is judged against the clock.
    const day = CalendarDate(2026, 10, 15);

    Future<void> seedDay() => calendar.upsertEvents([
          timed('morning', la.localDateTime(day, 9, 0).toUtc(),
              responseStatus: 'accepted'),
          timed('next-day', la.localDateTime(day.addDays(1), 9, 0).toUtc(),
              responseStatus: 'accepted'),
          const CalendarEvent(
            id: 'banner',
            subject: 'Fabrikam offsite',
            isAllDay: true,
            startDate: day,
            endDate: CalendarDate(2026, 10, 16),
          ),
        ], syncRun: 'run-1');

    test('answers the day, all-day first, when the calendar is shown',
        () async {
      await seedDay();
      final events = await readFuture(
        containerFor(CalendarAvailability.available),
        dayEventsProvider(day).future,
      );
      expect([for (final e in events) e.id], ['banner', 'morning']);
    });

    test('answers nothing in SDK mode or without the scope', () async {
      await seedDay();
      for (final a in [
        CalendarAvailability.sdkMode,
        CalendarAvailability.scopeMissing,
      ]) {
        final events =
            await readFuture(containerFor(a), dayEventsProvider(day).future);
        expect(events, isEmpty, reason: '$a');
      }
    });
  });

  group('dayBriefsProvider', () {
    const day = CalendarDate(2026, 10, 15);

    Future<void> brief(String eventId, String status, String headline) =>
        calendar.putBrief(
          eventId: eventId,
          inputsHash: 'h-$eventId',
          status: status,
          briefJson: jsonEncode(MeetingBrief(
            headline: headline,
            questions: const ['What is still open?'],
          ).toJson()),
          generatedAt: '2026-10-15T08:00:00.000000Z',
        );

    test('answers the ready briefs by event id and drops an empty glance',
        () async {
      await calendar.upsertEvents([
        timed('briefed', la.localDateTime(day, 9, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('blank', la.localDateTime(day, 10, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('failed', la.localDateTime(day, 11, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('tomorrow', la.localDateTime(day.addDays(1), 9, 0).toUtc(),
            responseStatus: 'accepted'),
      ], syncRun: 'run-1');
      await brief('briefed', EventBrief.ready, 'The Q3 numbers are due.');
      await brief('blank', EventBrief.ready, '');
      await brief('failed', EventBrief.failed, 'Not drawn.');
      await brief('tomorrow', EventBrief.ready, 'Another day.');

      final briefs = await readFuture(
        containerFor(CalendarAvailability.available),
        dayBriefsProvider(day).future,
      );
      expect(briefs.keys, ['briefed']);
      expect(briefs['briefed']!.headline, 'The Q3 numbers are due.');
      expect(briefs['briefed']!.questions, ['What is still open?']);
    });

    test('a materials_pending brief is a note for its day', () async {
      await calendar.upsertEvents([
        timed('pending', la.localDateTime(day, 9, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('no-mail', la.localDateTime(day, 10, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('briefed', la.localDateTime(day, 11, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('tomorrow', la.localDateTime(day.addDays(1), 9, 0).toUtc(),
            responseStatus: 'accepted'),
      ], syncRun: 'run-1');
      Future<void> skipped(String id, String why) => calendar.putBrief(
            eventId: id,
            inputsHash: '${EventBrief.ineligiblePrefix}$why',
            status: EventBrief.skipped,
            generatedAt: '2026-10-15T08:00:00.000000Z',
          );
      await skipped('pending', 'materials_pending');
      await skipped('no-mail', 'no_mail');
      await brief('briefed', EventBrief.ready, 'The Q3 numbers are due.');
      await skipped('tomorrow', 'materials_pending');

      final container = containerFor(CalendarAvailability.available);
      final waiting =
          await readFuture(container, dayBriefsWaitingProvider(day).future);
      expect(waiting, {'pending'});
      final briefs = await readFuture(container, dayBriefsProvider(day).future);
      expect(briefs.keys, ['briefed'], reason: 'a note is not a brief');
    });

    test('no notes while processing is off', () async {
      await calendar.upsertEvents([
        timed('pending', la.localDateTime(day, 9, 0).toUtc(),
            responseStatus: 'accepted'),
      ], syncRun: 'run-1');
      await calendar.putBrief(
        eventId: 'pending',
        inputsHash: '${EventBrief.ineligiblePrefix}materials_pending',
        status: EventBrief.skipped,
        generatedAt: '2026-10-15T08:00:00.000000Z',
      );

      final off = await readFuture(
        containerFor(CalendarAvailability.available, processingOn: false),
        dayBriefsWaitingProvider(day).future,
      );
      expect(off, isEmpty);
      final on = await readFuture(
        containerFor(CalendarAvailability.available),
        dayBriefsWaitingProvider(day).future,
      );
      expect(on, {'pending'}, reason: 'the same row, processing on');
    });
  });

  group('weekEventsProvider', () {
    // Monday Oct 12 2026; the week runs to Sunday Oct 18 inclusive.
    const monday = CalendarDate(2026, 10, 12);

    test('covers the seven local days from Monday, and a Sunday-night '
        'meeting that is Monday in UTC stays in its own week', () async {
      await calendar.upsertEvents([
        timed('mon', la.localDateTime(monday, 9, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('sun', la.localDateTime(monday.addDays(6), 9, 0).toUtc(),
            responseStatus: 'accepted'),
        // Sunday Oct 18, 9:00 PM PDT = Monday Oct 19, 04:00Z.
        timed('sun-night', la.localDateTime(monday.addDays(6), 21, 0).toUtc(),
            responseStatus: 'accepted'),
        // Sunday Oct 11, 9:00 PM PDT = Monday Oct 12, 04:00Z: last week.
        timed('last-sun-night',
            la.localDateTime(monday.addDays(-1), 21, 0).toUtc(),
            responseStatus: 'accepted'),
        timed('next-mon', la.localDateTime(monday.addDays(7), 9, 0).toUtc(),
            responseStatus: 'accepted'),
        const CalendarEvent(
          id: 'banner',
          subject: 'Fabrikam offsite',
          isAllDay: true,
          startDate: CalendarDate(2026, 10, 14),
          endDate: CalendarDate(2026, 10, 15),
        ),
      ], syncRun: 'run-1');
      expect(
          la
              .localDateTime(monday.addDays(6), 21, 0)
              .isAtSameMomentAs(DateTime.utc(2026, 10, 19, 4)),
          isTrue);

      final events = await readFuture(
        containerFor(CalendarAvailability.available),
        weekEventsProvider(monday).future,
      );
      expect({for (final e in events) e.id},
          {'mon', 'sun', 'sun-night', 'banner'});

      final next = await readFuture(
        containerFor(CalendarAvailability.available),
        weekEventsProvider(monday.addDays(7)).future,
      );
      expect({for (final e in next) e.id}, {'next-mon'});
    });

    test('answers nothing in SDK mode', () async {
      await calendar.upsertEvents([
        timed('mon', la.localDateTime(monday, 9, 0).toUtc(),
            responseStatus: 'accepted'),
      ], syncRun: 'run-1');
      final events = await readFuture(
        containerFor(CalendarAvailability.sdkMode),
        weekEventsProvider(monday).future,
      );
      expect(events, isEmpty);
    });
  });

  group('invitesOwedProvider', () {
    test('folds a series, pins what the mail says is pressing, and finds '
        'overlaps', () async {
      // Relative to the clock: the store only answers invites still ahead.
      final base = DateTime.now().toUtc().add(const Duration(hours: 2));
      DateTime inDays(int d) => base.add(Duration(days: d));

      await calendar.upsertEvents([
        for (final d in [1, 8, 15])
          timed('occ-$d', inDays(d),
              seriesMasterId: 'ser-1', eventType: 'occurrence'),
        timed('solo', inDays(3)),
        timed('hot', inDays(5)),
        // Accepted, so not owed — but it sits on top of `solo`.
        timed('clash', inDays(3), responseStatus: 'accepted'),
      ], syncRun: 'run-1');

      // The invite mail for `hot`, read as urgent by the decision model.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-hot',
        'conversation_key': 'conv-hot',
        'direction': 'inbound',
        'subject': 'Invitation: Contoso escalation',
        'from_name': 'Avery',
        'from_address': 'avery@contoso.com',
        'received_at': MessageStore.isoStamp(DateTime.now().toUtc()),
        'body_text': 'Please join.',
        'triage_status': 'done',
        'source_meta_json':
            jsonEncode({'meeting': 'meetingRequest', 'event_id': 'hot'}),
      });
      await store.writeDecision(
        'email',
        'm-hot',
        fakeDecision(fakeAnswers(urgency: 'high')),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );

      final entries = await readFuture(
        containerFor(CalendarAvailability.available),
        invitesOwedProvider(invitesAsOf(DateTime.now())).future,
      );

      expect([for (final e in entries) e.event.id], ['hot', 'occ-1', 'solo']);
      final hot = entries.first;
      expect(hot.pinned, isTrue);
      final series = entries[1];
      expect(series.occurrences, 3);
      expect(series.isSeries, isTrue);
      expect(series.pinned, isFalse);
      final solo = entries[2];
      expect(solo.pinned, isFalse);
      expect([for (final e in solo.overlaps.hard) e.id], ['clash']);
      expect(overlapLine(solo.overlaps), '⚠ overlaps Meeting clash');
    });

    test('a series is pinned by its master\'s invite mail too', () async {
      final base = DateTime.now().toUtc().add(const Duration(hours: 2));
      await calendar.upsertEvents([
        timed('occ-a', base.add(const Duration(days: 1)),
            seriesMasterId: 'ser-2', eventType: 'occurrence'),
        timed('occ-b', base.add(const Duration(days: 8)),
            seriesMasterId: 'ser-2', eventType: 'occurrence'),
      ], syncRun: 'run-1');
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-ser',
        'conversation_key': 'conv-ser',
        'direction': 'inbound',
        'subject': 'Invitation: Weekly Fabrikam sync',
        'from_name': 'Avery',
        'from_address': 'avery@fabrikam.com',
        'received_at': MessageStore.isoStamp(DateTime.now().toUtc()),
        'body_text': 'Recurring.',
        'triage_status': 'done',
        'source_meta_json':
            jsonEncode({'meeting': 'meetingRequest', 'event_id': 'ser-2'}),
      });
      await store.writeDecision(
        'email',
        'm-ser',
        fakeDecision(fakeAnswers(importance: 'high')),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );

      final entries = await readFuture(
        containerFor(CalendarAvailability.available),
        invitesOwedProvider(invitesAsOf(DateTime.now())).future,
      );
      expect(entries, hasLength(1));
      expect(entries.single.occurrences, 2);
      expect(entries.single.pinned, isTrue);
    });

    test('the "as of" argument is the clock: an invite that has started by '
        'then is gone', () async {
      final start = DateTime.now().toUtc().add(const Duration(hours: 2));
      await calendar.upsertEvents([timed('soon', start)], syncRun: 'run-1');
      final container = containerFor(CalendarAvailability.available);

      final before = await readFuture(
        container,
        invitesOwedProvider(invitesAsOf(DateTime.now())).future,
      );
      expect([for (final e in before) e.event.id], ['soon']);

      final after = await readFuture(
        container,
        invitesOwedProvider(
          invitesAsOf(start.add(const Duration(minutes: 30))),
        ).future,
      );
      expect(after, isEmpty);
    });

    test('answers nothing in SDK mode', () async {
      await calendar.upsertEvents([
        timed('solo', DateTime.now().toUtc().add(const Duration(days: 2))),
      ], syncRun: 'run-1');
      final entries = await readFuture(
        containerFor(CalendarAvailability.sdkMode),
        invitesOwedProvider(invitesAsOf(DateTime.now())).future,
      );
      expect(entries, isEmpty);
    });
  });
}
