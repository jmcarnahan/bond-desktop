import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/event_providers.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/event_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A backend whose one live read answers what the test set, and records who
/// asked. Every other call is a mistake here.
class _FakeCalendarBackend implements CalendarBackend {
  CalendarEvent? answer;
  Object? error;
  final List<String> calls = [];

  @override
  Future<CalendarEvent> getEvent(String id) async {
    calls.add(id);
    final e = error;
    if (e != null) throw e;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A mirror whose one-event read fails, as a locked or corrupted database
/// would.
class _ThrowingCalendarStore extends CalendarStore {
  _ThrowingCalendarStore(super.db);

  @override
  Future<CalendarEvent?> event(String id) async =>
      throw StateError('the mirror could not be read');
}

/// The event panel's reads, over a real in-memory mirror: the mirror-first
/// lookup and its live fallback, the linked conversations, and a person's
/// next and last meetings.
void main() {
  setUpAll(initCalendarZones);

  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late CalendarZone la;
  late _FakeCalendarBackend backend;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    backend = _FakeCalendarBackend();
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer containerFor(CalendarAvailability availability) {
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      calendarAvailabilityProvider.overrideWith((ref) => availability),
      calendarZoneProvider.overrideWith((ref) async => la),
      calendarBackendProvider.overrideWithValue(backend),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<T> readFuture<T>(
    ProviderContainer container,
    ProviderListenable<Future<T>> provider,
  ) {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    return sub.read();
  }

  final now = DateTime.now().toUtc();
  DateTime inHours(num h) => now.add(Duration(minutes: (h * 60).round()));

  CalendarEvent timed(
    String id,
    DateTime start, {
    String eventType = 'singleInstance',
    String seriesMasterId = '',
    String joinUrl = '',
    List<Attendee> attendees = const [],
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Meeting $id',
        eventType: eventType,
        seriesMasterId: seriesMasterId,
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 30)),
        organizerAddress: 'dana.ortiz@contoso.com',
        joinUrl: joinUrl,
        attendees: attendees,
        responseStatus: 'accepted',
      );

  Future<int> storedCount() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM calendar_events')
          .getSingle())
      .data['n'] as int;

  group('eventByIdProvider', () {
    test('a mirror hit never asks the backend', () async {
      await calendar.upsertEvents([timed('e1', inHours(2))], syncRun: 'r');
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('e1').future,
      );
      expect(lookup.state, EventLookupState.found);
      expect(lookup.event!.id, 'e1');
      expect(lookup.fromMirror, isTrue);
      expect(backend.calls, isEmpty);
    });

    test('a miss reads live, and the answer is not stored', () async {
      backend.answer = timed('far', inHours(24 * 200));
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('far').future,
      );
      expect(lookup.state, EventLookupState.found);
      expect(lookup.fromMirror, isFalse);
      expect(backend.calls, ['far']);
      expect(await calendar.event('far'), isNull);
      expect(await storedCount(), 0);
    });

    test('a deleted event is gone', () async {
      backend.error = const CalendarEventGone();
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('x').future,
      );
      expect(lookup.state, EventLookupState.gone);
    });

    test('without the scope nothing is read at all', () async {
      await calendar.upsertEvents([timed('e1', inHours(2))], syncRun: 'r');
      final lookup = await readFuture(
        containerFor(CalendarAvailability.scopeMissing),
        eventByIdProvider('e1').future,
      );
      expect(lookup.state, EventLookupState.blocked);
      expect(lookup.availability, CalendarAvailability.scopeMissing);
      expect(backend.calls, isEmpty);
    });

    test('a scope refusal on the live read is blocked', () async {
      backend.error = const CalendarScopeMissing();
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('x').future,
      );
      expect(lookup.state, EventLookupState.blocked);
      expect(lookup.availability, CalendarAvailability.scopeMissing);
    });

    test('a transient failure, or an unavailable server, is unreachable',
        () async {
      backend.error = const CalendarTransient('boom', statusCode: 503);
      final c = containerFor(CalendarAvailability.available);
      expect((await readFuture(c, eventByIdProvider('x').future)).state,
          EventLookupState.unreachable);

      backend.error = const CalendarUnavailable('offline');
      expect((await readFuture(c, eventByIdProvider('y').future)).state,
          EventLookupState.unreachable);

      backend.error = StateError('anything else');
      expect((await readFuture(c, eventByIdProvider('z').future)).state,
          EventLookupState.unreachable);
    });

    test('a master comes with its occurrences in start order', () async {
      await calendar.upsertEvents([
        timed('m', inHours(-500), eventType: 'seriesMaster'),
        timed('o2', inHours(48), eventType: 'occurrence', seriesMasterId: 'm'),
        timed('o1', inHours(24), eventType: 'occurrence', seriesMasterId: 'm'),
      ], syncRun: 'r');
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('m').future,
      );
      expect([for (final o in lookup.occurrences) o.id], ['o1', 'o2']);
    });

    test('a master read live still gets its mirrored occurrences', () async {
      // calendarView mirrors the occurrences under their master's id but not
      // the master row, so an invite naming the master is read live.
      await calendar.upsertEvents([
        timed('o2', inHours(48), eventType: 'occurrence', seriesMasterId: 'm'),
        timed('o1', inHours(24), eventType: 'occurrence', seriesMasterId: 'm'),
      ], syncRun: 'r');
      backend.answer = timed('m', inHours(-500), eventType: 'seriesMaster');
      final lookup = await readFuture(
        containerFor(CalendarAvailability.available),
        eventByIdProvider('m').future,
      );
      expect(lookup.state, EventLookupState.found);
      expect(lookup.fromMirror, isFalse);
      expect(backend.calls, ['m']);
      expect([for (final o in lookup.occurrences) o.id], ['o1', 'o2']);
    });

    test('a live re-read that cannot reach the server keeps what it found; '
        'a gone one does not', () async {
      backend.answer = timed('m', inHours(-500), eventType: 'seriesMaster');
      final c = containerFor(CalendarAvailability.available);
      final sub = c.listen(eventByIdProvider('m'), (_, _) {});
      addTearDown(sub.close);
      expect((await c.read(eventByIdProvider('m').future)).state,
          EventLookupState.found);

      // A sync moved some row, the panel re-reads, and the server is down.
      backend.error = const CalendarTransient('boom', statusCode: 503);
      c.read(calendarRevisionProvider.notifier).state++;
      final kept = await c.read(eventByIdProvider('m').future);
      expect(backend.calls, ['m', 'm']);
      expect(kept.state, EventLookupState.found);
      expect(kept.event!.id, 'm');

      // Deleted meanwhile: that is news, and it is said.
      backend.error = const CalendarEventGone();
      c.read(calendarRevisionProvider.notifier).state++;
      expect((await c.read(eventByIdProvider('m').future)).state,
          EventLookupState.gone);

      // And with nothing found before, unreachable is unreachable.
      backend.error = const CalendarTransient('boom', statusCode: 503);
      c.read(calendarRevisionProvider.notifier).state++;
      expect((await c.read(eventByIdProvider('m').future)).state,
          EventLookupState.unreachable);
    });

    test('a mirror read that throws is unreachable, not a failed future',
        () async {
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        calendarAvailabilityProvider
            .overrideWith((ref) => CalendarAvailability.available),
        calendarZoneProvider.overrideWith((ref) async => la),
        calendarBackendProvider.overrideWithValue(backend),
        calendarStoreProvider.overrideWithValue(_ThrowingCalendarStore(db)),
      ]);
      addTearDown(container.dispose);
      final lookup =
          await readFuture(container, eventByIdProvider('e1').future);
      expect(lookup.state, EventLookupState.unreachable);
      expect(lookup.availability, CalendarAvailability.available);
      expect(backend.calls, isEmpty);
    });
  });

  group('eventLinksProvider', () {
    Future<void> message(
      String id,
      String conversation,
      String eventId, {
      String source = 'email',
      required DateTime at,
    }) =>
        store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': conversation,
          'direction': 'inbound',
          'subject': 'Invitation: Planning',
          'from_name': 'Dana Ortiz',
          'from_address': 'dana.ortiz@contoso.com',
          'received_at': MessageStore.isoStamp(at),
          'body_text': 'Body of $id',
          'triage_status': 'pending',
          'source_meta_json':
              jsonEncode({'meeting': 'meetingRequest', 'event_id': eventId}),
        });

    Future<void> conversation(String key, String subject,
            {String source = 'email'}) =>
        store.upsertConversation({
          'source': source,
          'conversation_key': key,
          'subject': subject,
        });

    Future<void> storyline(String id, String key) async {
      final stamp = MessageStore.isoStamp(now);
      await db.customStatement(
        'INSERT INTO storylines (id, title, status, created_at, updated_at) '
        "VALUES ('$id', 'Planning', 'active', '$stamp', '$stamp')",
      );
      await db.customStatement(
        'INSERT INTO storyline_members '
        '(storyline_id, source, conversation_key, added_at) '
        "VALUES ('$id', 'email', '$key', '$stamp')",
      );
    }

    test('one link per conversation, newest first, with its storyline',
        () async {
      await calendar.upsertEvents([timed('e1', inHours(2))], syncRun: 'r');
      await message('m1', 'conv-a', 'e1', at: inHours(-5));
      await message('m2', 'conv-a', 'e1', at: inHours(-4));
      await message('m3', 'conv-b', 'e1', at: inHours(-1));
      await conversation('conv-a', 'Planning');
      await conversation('conv-b', '  Planning (updated)  ');
      await storyline('sl-1', 'conv-a');

      final links = await readFuture(
        containerFor(CalendarAvailability.available),
        eventLinksProvider('e1').future,
      );
      expect([for (final l in links) l.conversationKey], ['conv-b', 'conv-a']);
      expect(links.first.title, 'Planning (updated)');
      expect(links.first.storylineId, isNull);
      expect(links.last.storylineId, 'sl-1');
      expect(links.every((l) => !l.isMeetingChat), isTrue);
    });

    test('an occurrence also lists what names its series', () async {
      await calendar.upsertEvents([
        timed('m', inHours(-500), eventType: 'seriesMaster'),
        timed('o1', inHours(24), eventType: 'occurrence', seriesMasterId: 'm'),
      ], syncRun: 'r');
      await message('m1', 'conv-series', 'm', at: inHours(-10));
      await message('m2', 'conv-one', 'o1', at: inHours(-2));
      await conversation('conv-series', 'Weekly sync');
      await conversation('conv-one', 'Weekly sync (moved)');

      final links = await readFuture(
        containerFor(CalendarAvailability.available),
        eventLinksProvider('o1').future,
      );
      expect([for (final l in links) l.conversationKey],
          ['conv-one', 'conv-series']);
    });

    test('a message whose conversation row is missing is skipped', () async {
      await calendar.upsertEvents([timed('e1', inHours(2))], syncRun: 'r');
      await message('m1', 'conv-lost', 'e1', at: inHours(-1));
      final links = await readFuture(
        containerFor(CalendarAvailability.available),
        eventLinksProvider('e1').future,
      );
      expect(links, isEmpty);
    });

    test('the Teams meeting chat, only when it was synced', () async {
      const chat = '19:meeting_abc123@thread.v2';
      final url = 'https://teams.microsoft.com/l/meetup-join/'
          '${Uri.encodeComponent(chat).toLowerCase()}/0';
      await calendar.upsertEvents(
        [timed('e1', inHours(2), joinUrl: url)],
        syncRun: 'r',
      );
      final c = containerFor(CalendarAvailability.available);
      expect(await readFuture(c, eventLinksProvider('e1').future), isEmpty);

      await conversation(chat, '', source: 'teams');
      c.invalidate(eventLinksProvider('e1'));
      final links = await readFuture(c, eventLinksProvider('e1').future);
      expect(links, hasLength(1));
      expect(links.single.source, 'teams');
      expect(links.single.conversationKey, chat);
      expect(links.single.isMeetingChat, isTrue);
      expect(links.single.title, 'Meeting chat');
    });

    test('nothing for an event that is not found', () async {
      backend.error = const CalendarEventGone();
      final links = await readFuture(
        containerFor(CalendarAvailability.available),
        eventLinksProvider('gone').future,
      );
      expect(links, isEmpty);
    });
  });

  group('personMeetingsProvider', () {
    test('personMeetingsKey lowercases, dedupes and sorts', () {
      expect(
        personMeetingsKey([
          'Sam.Lee@contoso.com',
          null,
          '',
          ' dana@contoso.com',
          'sam.lee@contoso.com',
        ]),
        'dana@contoso.com,sam.lee@contoso.com',
      );
    });

    test('the next meeting and the last one with them', () async {
      final sam = [
        const Attendee(
          name: 'Sam Lee',
          address: 'sam.lee@contoso.com',
          response: 'accepted',
        ),
      ];
      await calendar.upsertEvents([
        timed('past', inHours(-30), attendees: sam),
        timed('older', inHours(-80), attendees: sam),
        timed('next', inHours(3), attendees: sam),
        timed('later', inHours(30), attendees: sam),
        timed('other', inHours(1)),
      ], syncRun: 'r');
      final key = (
        addresses: personMeetingsKey(['sam.lee@contoso.com']),
        asOf: now,
      );
      final meetings = await readFuture(
        containerFor(CalendarAvailability.available),
        personMeetingsProvider(key).future,
      );
      expect(meetings.next!.id, 'next');
      expect(meetings.last!.id, 'past');

      final gated = await readFuture(
        containerFor(CalendarAvailability.sdkMode),
        personMeetingsProvider(key).future,
      );
      expect(gated.isEmpty, isTrue);

      // A grant without the calendar scope never sees the rows the table may
      // still hold from before.
      final noScope = await readFuture(
        containerFor(CalendarAvailability.scopeMissing),
        personMeetingsProvider(key).future,
      );
      expect(noScope.isEmpty, isTrue);

      final nobody = await readFuture(
        containerFor(CalendarAvailability.available),
        personMeetingsProvider((addresses: '', asOf: now)).future,
      );
      expect(nobody.isEmpty, isTrue);
    });
  });
}
