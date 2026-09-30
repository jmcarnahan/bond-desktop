import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/backend_types.dart'
    show ReconsentRequired;
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// One backend call as the fake saw it: the method, whether it was a dry
/// run, and its arguments by name.
typedef _Call = ({String method, bool dryRun, Map<String, Object?> args});

/// A scripted calendar backend. Each write method takes the next answer from
/// its own queue — a result, or an object to throw — and falls back to a
/// preview (dry run) or an ack (real) naming the id it was given.
class _FakeCalendarBackend implements CalendarBackend {
  final List<_Call> calls = [];
  final Map<String, List<Object>> answers = {};
  final Map<String, CalendarEvent> live = {};
  MailboxSettings settings = const MailboxSettings(
    timeZone: 'Pacific Standard Time',
    timeZoneIana: 'America/Los_Angeles',
  );
  int mailboxCalls = 0;

  List<_Call> callsTo(String method, {bool? dryRun}) => [
        for (final c in calls)
          if (c.method == method && (dryRun == null || c.dryRun == dryRun)) c,
      ];

  Future<CalendarWriteResult> _answer(
    String method,
    String id,
    bool dryRun,
    Map<String, Object?> args,
  ) async {
    calls.add((method: method, dryRun: dryRun, args: args));
    final queue = answers[method];
    if (queue != null && queue.isNotEmpty) {
      final next = queue.removeAt(0);
      if (next is CalendarWriteResult) return next;
      throw next;
    }
    return dryRun
        ? WritePreview(method: 'POST', path: '/me/events/$id')
        : EventWriteAck(id: id);
  }

  @override
  Future<CalendarSyncPage> syncPage({
    String cursor = '',
    String? startUtc,
    String? endUtc,
  }) =>
      throw UnimplementedError();

  @override
  Future<CalendarEvent> getEvent(String id) async {
    calls.add((method: 'get', dryRun: false, args: {'id': id}));
    final e = live[id];
    if (e == null) throw const CalendarEventGone();
    return e;
  }

  @override
  Future<MailboxSettings> mailboxSettings() async {
    mailboxCalls += 1;
    return settings;
  }

  @override
  Future<CalendarWriteResult> respond(
    String id, {
    required String response,
    String? comment,
    bool sendResponse = true,
    DateTime? proposedStartUtc,
    DateTime? proposedEndUtc,
    bool dryRun = false,
  }) =>
      _answer('respond', id, dryRun, {
        'id': id,
        'response': response,
        'comment': comment,
        'sendResponse': sendResponse,
        'proposedStartUtc': proposedStartUtc,
        'proposedEndUtc': proposedEndUtc,
      });

  @override
  Future<CalendarWriteResult> update(
    String id, {
    required String ifMatch,
    DateTime? startUtc,
    DateTime? endUtc,
    CalendarDate? startDate,
    CalendarDate? endDate,
    String? allDayZone,
    String? subject,
    String? location,
    String? showAs,
    bool dryRun = false,
  }) =>
      _answer('update', id, dryRun, {
        'id': id,
        'ifMatch': ifMatch,
        'startUtc': startUtc,
        'endUtc': endUtc,
        'startDate': startDate,
        'endDate': endDate,
        'allDayZone': allDayZone,
      });

  @override
  Future<CalendarWriteResult> cancel(
    String id, {
    String? comment,
    bool dryRun = false,
  }) =>
      _answer('cancel', id, dryRun, {'id': id, 'comment': comment});

  @override
  Future<CalendarWriteResult> delete(String id, {bool dryRun = false}) =>
      _answer('delete', id, dryRun, {'id': id});

  @override
  Future<CalendarWriteResult> create({
    required String subject,
    required DateTime startUtc,
    required DateTime endUtc,
    List<String> attendees = const [],
    bool isOnlineMeeting = false,
    String? body,
    required String transactionId,
    bool dryRun = false,
  }) =>
      _answer('create', 'new-event', dryRun, {
        'subject': subject,
        'attendees': attendees,
        'transactionId': transactionId,
      });

  @override
  Future<List<MeetingTimeSuggestion>> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) =>
      throw UnimplementedError();
}

/// The real sync with its network half stubbed: the forced sync after a
/// write only counts, so no tick outlives the test's database, and the write
/// guard's notes are recorded as well as kept.
class _RecordingSync extends CalendarSync {
  _RecordingSync(super.backend, super.store, super.calendar);

  final List<String> noted = [];
  int forced = 0;

  /// Makes the local half of a write fail after the server's half succeeded.
  bool failStore = false;

  @override
  Future<void> storeWritten(CalendarEvent event) {
    if (failStore) throw StateError('the mirror is unwritable');
    return super.storeWritten(event);
  }

  @override
  void noteWrite(String eventId) {
    noted.add(eventId);
    super.noteWrite(eventId);
  }

  @override
  Future<CalendarSyncOutcome> syncNow({bool force = false}) {
    if (force) forced += 1;
    return Future.value(const CalendarSyncOutcome(CalendarSyncStatus.skipped));
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late _FakeCalendarBackend backend;
  late _RecordingSync sync;
  late ActivityLog activity;
  late CalendarWrites writes;
  late int changed;

  final t0 = DateTime.utc(2026, 10, 5, 15);
  const run = '2026-10-01T00:00:00.000000Z';

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    backend = _FakeCalendarBackend();
    sync = _RecordingSync(backend, store, calendar);
    activity = ActivityLog(store);
    changed = 0;
    writes = CalendarWrites(
      backend,
      calendar,
      sync,
      store,
      activityLog: activity,
      clock: () => t0,
      onChanged: () => changed += 1,
    );
    // A run in progress, as a first sync leaves it.
    await store.setPref(
      calendarRunKey,
      jsonEncode({
        'start': '2026-09-05T00:00:00Z',
        'end': '2027-02-03T00:00:00Z',
        'run': run,
        'swept': true,
      }),
    );
  });

  tearDown(() async {
    activity.dispose();
    await db.close();
  });

  CalendarEvent timed(
    String id, {
    String changeKey = 'ck-1',
    String seriesMasterId = '',
    String eventType = '',
    bool isOrganizer = true,
    List<Attendee> attendees = const [],
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Budget review',
        seriesMasterId: seriesMasterId,
        eventType: eventType,
        isOrganizer: isOrganizer,
        startUtc: t0.add(const Duration(days: 1)),
        endUtc: t0.add(const Duration(days: 1, hours: 1)),
        changeKey: changeKey,
        attendees: attendees,
      );

  Future<String?> syncRunOf(String id) async {
    final rows = await db
        .customSelect('SELECT sync_run FROM calendar_events WHERE id = ?',
            variables: [Variable(id)])
        .get();
    return rows.isEmpty ? null : rows.first.data['sync_run'] as String?;
  }

  Future<List<Map<String, Object?>>> writeRows() async => [
        for (final r in await store.recentActivity(limit: 50))
          if (r['kind'] == 'calendar_write') r,
      ];

  const dana = 'dana@contoso.com';
  const privately = WritePreview(method: 'PATCH', path: '/me/events/e1');
  const toDana =
      WritePreview(method: 'PATCH', path: '/me/events/e1', notifies: [dana]);

  group('the confirm policy', () {
    test('anyone emailed, a delete and a cancel confirm; a private move does '
        'not', () async {
      await calendar.upsertEvents([timed('e1')], syncRun: run);
      final move = MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1)));

      backend.answers['update'] = [privately];
      final private = await writes.preview(move) as PreviewReady;
      expect(private.needsConfirm, isFalse);

      backend.answers['update'] = [toDana];
      final emails = await writes.preview(move) as PreviewReady;
      expect(emails.needsConfirm, isTrue);
      expect(emails.preview.notifies, [dana]);

      final delete = await writes.preview(const DeleteEvent('e1'));
      expect((delete as PreviewReady).needsConfirm, isTrue);
      final cancel = await writes.preview(const CancelMeeting('e1'));
      expect((cancel as PreviewReady).needsConfirm, isTrue);
      expect(needsConfirm(const DeleteEvent('x'), privately), isTrue);
    });

    test('every RSVP confirms, even one whose dry run lists nobody', () {
      // Every answer is sent and so emails the organiser; the confirm must
      // not hinge on the server listing them.
      expect(needsConfirm(const RespondToEvent('x', RsvpResponse.accept),
              privately),
          isTrue);
      expect(
          needsConfirm(
              RespondToEvent('x', RsvpResponse.decline,
                  proposeStartUtc: t0, proposeEndUtc: t0.add(
                      const Duration(hours: 1))),
              privately),
          isTrue);
    });

    test('a preview is a dry run and changes nothing', () async {
      await calendar.upsertEvents([timed('e1')], syncRun: run);
      await writes.preview(const DeleteEvent('e1'));
      expect(backend.calls.single.dryRun, isTrue);
      expect(await calendar.event('e1'), isNotNull);
      expect(changed, 0);
      expect(sync.noted, isEmpty);
    });

    test('an RSVP previews with send on and a blank note dropped', () async {
      await writes.preview(const RespondToEvent('e1', RsvpResponse.accept,
          comment: '   '));
      final call = backend.callsTo('respond').single;
      expect(call.dryRun, isTrue);
      expect(call.args['response'], 'accept');
      expect(call.args['sendResponse'], isTrue);
      expect(call.args['comment'], isNull);
    });
  });

  group('a move', () {
    test('previews and commits with the STORED change key', () async {
      await calendar.upsertEvents([timed('e1', changeKey: 'stored-key')],
          syncRun: run);
      final move = MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1)));
      await writes.preview(move);
      await writes.commit(move, preview: privately);

      final updates = backend.callsTo('update');
      expect(updates, hasLength(2));
      expect(updates.map((c) => c.args['ifMatch']), everyElement('stored-key'));
      expect(updates.first.dryRun, isTrue);
      expect(updates.last.dryRun, isFalse);
    });

    test('a series master out of the mirror is read live for its key',
        () async {
      backend.live['master'] = timed('master', changeKey: 'live-key');
      await writes.preview(MoveEvent.timed('master',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1))));
      expect(backend.callsTo('update').single.args['ifMatch'], 'live-key');
    });

    test('the answered row is stored with its new key under the current run',
        () async {
      await calendar.upsertEvents([timed('e1')], syncRun: 'an-older-run');
      final newStart = t0.add(const Duration(days: 2));
      final newEnd = t0.add(const Duration(days: 2, hours: 1));
      backend.answers['update'] = [
        EventWriteAck(
          id: 'e1',
          event: CalendarEvent(
            id: 'e1',
            subject: 'Budget review',
            isOrganizer: true,
            startUtc: newStart,
            endUtc: newEnd,
            changeKey: 'ck-2',
          ),
        ),
      ];
      final outcome = await writes.commit(
        MoveEvent.timed('e1', startUtc: newStart, endUtc: newEnd),
        preview: privately,
      );

      expect(outcome.ok, isTrue);
      expect(outcome.eventId, 'e1');
      final stored = await calendar.event('e1');
      expect(stored!.changeKey, 'ck-2');
      expect(stored.startUtc, newStart);
      expect(await syncRunOf('e1'), run);
      expect(sync.noted, contains('e1'));
      expect(changed, 1);
      expect(sync.forced, 1);
    });

    test('a private move offers the old times back, and the undo reads the '
        'NEW key', () async {
      final before = timed('e1', changeKey: 'ck-1');
      await calendar.upsertEvents([before], syncRun: run);
      final newStart = t0.add(const Duration(days: 2));
      final newEnd = t0.add(const Duration(days: 2, hours: 1));
      backend.answers['update'] = [
        EventWriteAck(
          id: 'e1',
          event: CalendarEvent(
            id: 'e1',
            isOrganizer: true,
            startUtc: newStart,
            endUtc: newEnd,
            changeKey: 'ck-2',
          ),
        ),
      ];
      final outcome = await writes.commit(
        MoveEvent.timed('e1', startUtc: newStart, endUtc: newEnd),
        preview: privately,
      );
      final undo = outcome.undo as MoveEvent;
      expect(undo.eventId, 'e1');
      expect(undo.startUtc, before.startUtc);
      expect(undo.endUtc, before.endUtc);

      final back = await writes.commit(undo, isUndo: true);
      expect(back.ok, isTrue);
      expect(back.undo, isNull);
      expect(backend.callsTo('update').last.args['ifMatch'], 'ck-2');
      final rows = await writeRows();
      expect(jsonDecode(rows.first['detail_json'] as String)['undo'], isTrue);
    });

    test('a move that emailed someone offers no undo', () async {
      await calendar.upsertEvents([timed('e1')], syncRun: run);
      final outcome = await writes.commit(
        MoveEvent.timed('e1',
            startUtc: t0.add(const Duration(days: 2)),
            endUtc: t0.add(const Duration(days: 2, hours: 1))),
        preview: toDana,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.undo, isNull);
    });

    test('an all-day move sends the cached mailbox zone', () async {
      await calendar.upsertEvents([
        const CalendarEvent(
          id: 'd1',
          isAllDay: true,
          isOrganizer: true,
          startDate: CalendarDate(2026, 10, 8),
          endDate: CalendarDate(2026, 10, 9),
          changeKey: 'ck-d',
        ),
      ], syncRun: run);
      await store.setPref(
        calendarMailboxKey,
        jsonEncode({
          'settings': const MailboxSettings(
            timeZone: 'Eastern Standard Time',
            timeZoneIana: 'America/New_York',
          ).toJson(),
          'fetched_at': calendarStamp(t0),
        }),
      );
      await writes.preview(const MoveEvent.allDay('d1',
          startDate: CalendarDate(2026, 10, 9),
          endDate: CalendarDate(2026, 10, 10)));
      final call = backend.callsTo('update').single;
      expect(call.args['allDayZone'], 'Eastern Standard Time');
      expect(call.args['startDate'], const CalendarDate(2026, 10, 9));
      expect(call.args['startUtc'], isNull);
      expect(call.args['ifMatch'], 'ck-d');
      expect(backend.mailboxCalls, 0);
    });

    test('an all-day move with no cached zone reads the mailbox, and none at '
        'all refuses', () async {
      await calendar.upsertEvents([
        const CalendarEvent(
          id: 'd1',
          isAllDay: true,
          isOrganizer: true,
          startDate: CalendarDate(2026, 10, 8),
          endDate: CalendarDate(2026, 10, 9),
        ),
      ], syncRun: run);
      const move = MoveEvent.allDay('d1',
          startDate: CalendarDate(2026, 10, 9),
          endDate: CalendarDate(2026, 10, 10));
      await writes.preview(move);
      expect(backend.mailboxCalls, 1);
      expect(backend.callsTo('update').single.args['allDayZone'],
          'Pacific Standard Time');

      backend.settings = const MailboxSettings();
      final none = await writes.preview(move);
      expect((none as PreviewFailed).message,
          "Couldn't read your mailbox's time zone. Nothing was changed.");
      expect(backend.callsTo('update'), hasLength(1));
    });
  });

  group('the local effect', () {
    test('an RSVP to a master answers its occurrences in the mirror', () async {
      await calendar.upsertEvents([
        timed('occ-1', seriesMasterId: 'master', isOrganizer: false),
        timed('occ-2', seriesMasterId: 'master', isOrganizer: false),
        timed('other', isOrganizer: false),
      ], syncRun: run);
      final outcome = await writes.commit(
        const RespondToEvent('master', RsvpResponse.accept),
        preview: const WritePreview(
            method: 'POST', path: '/x', notifies: ['sam@fabrikam.com']),
      );
      expect(outcome.ok, isTrue);
      expect(outcome.undo, isNull);
      expect((await calendar.event('occ-1'))!.responseStatus, 'accepted');
      expect((await calendar.event('occ-2'))!.responseStatus, 'accepted');
      expect((await calendar.event('other'))!.responseStatus, 'none');
      expect(sync.noted, containsAll(['occ-1', 'occ-2']));
      expect(changed, 1);
    });

    test('tentative and decline store their Graph words', () async {
      await calendar.upsertEvents(
          [timed('a', isOrganizer: false), timed('b', isOrganizer: false)],
          syncRun: run);
      await writes.commit(const RespondToEvent('a', RsvpResponse.tentative));
      await writes.commit(const RespondToEvent('b', RsvpResponse.decline));
      expect((await calendar.event('a'))!.responseStatus,
          'tentativelyAccepted');
      expect((await calendar.event('b'))!.responseStatus, 'declined');
    });

    test('a cancel and a delete remove the event and its occurrences',
        () async {
      await calendar.upsertEvents([
        timed('occ-1', seriesMasterId: 'master'),
        timed('occ-2', seriesMasterId: 'master'),
        timed('single'),
        timed('keep'),
      ], syncRun: run);
      await writes.commit(const CancelMeeting('master', comment: 'Sorry'));
      expect(backend.callsTo('cancel').single.args['comment'], 'Sorry');
      await writes.commit(const DeleteEvent('single'));
      expect(await calendar.event('occ-1'), isNull);
      expect(await calendar.event('occ-2'), isNull);
      expect(await calendar.event('single'), isNull);
      expect(await calendar.event('keep'), isNotNull);
      expect(sync.noted, containsAll(['occ-1', 'occ-2', 'master', 'single']));
    });

    test('a create stores its row; one with no row only notes the id',
        () async {
      final start = t0.add(const Duration(days: 3));
      final end = start.add(const Duration(minutes: 30));
      backend.answers['create'] = [
        EventWriteAck(
          id: 'made',
          event: CalendarEvent(
              id: 'made', isOrganizer: true, startUtc: start, endUtc: end),
        ),
        const EventWriteAck(id: 'unplaced'),
      ];
      final first = await writes.commit(
          CreateEvent.propose(subject: 'Focus', startUtc: start, endUtc: end));
      expect(first.eventId, 'made');
      expect(await calendar.event('made'), isNotNull);
      expect(await syncRunOf('made'), run);

      await writes.commit(
          CreateEvent.propose(subject: 'Focus', startUtc: start, endUtc: end));
      expect(await calendar.event('unplaced'), isNull);
      expect(sync.noted, containsAll(['made', 'unplaced']));
    });
  });

  test('a write the server took stays a success when the mirror cannot '
      'follow: no "Nothing was changed", no Try again', () async {
    await calendar.upsertEvents([timed('e1')], syncRun: run);
    backend.answers['update'] = [
      EventWriteAck(id: 'e1', event: timed('e1', changeKey: 'ck-2')),
    ];
    sync.failStore = true;
    final outcome = await writes.commit(
      MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1))),
      preview: privately,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.retry, isNull);
    expect(sync.forced, 1, reason: 'the forced sync repairs the mirror');
  });

  test('a change callback that throws after the server took the write is '
      'still a success with no Try again', () async {
    await calendar.upsertEvents([timed('e1')], syncRun: run);
    final throwing = CalendarWrites(
      backend,
      calendar,
      sync,
      store,
      activityLog: activity,
      clock: () => t0,
      onChanged: () => throw StateError('a reader went away'),
    );
    final outcome = await throwing.commit(
      MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1))),
      preview: privately,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.retry, isNull);
    expect(outcome.undo, isA<MoveEvent>());
    expect(sync.forced, 1);
    expect((await writeRows()).single['status'], 'ok');
  });

  group('undo', () {
    test('a private create is undone by deleting it; one inviting anybody has '
        'no undo', () async {
      final start = t0.add(const Duration(days: 3));
      final end = start.add(const Duration(minutes: 30));
      backend.answers['create'] = [
        const EventWriteAck(id: 'made-1'),
        const EventWriteAck(id: 'made-2'),
      ];
      final alone = await writes.commit(
        CreateEvent.propose(subject: 'Focus', startUtc: start, endUtc: end),
        preview: const WritePreview(method: 'POST', path: '/me/events'),
      );
      expect(alone.undo, isA<DeleteEvent>());
      expect(alone.undo!.eventId, 'made-1');

      final invited = await writes.commit(
        CreateEvent.propose(
            subject: 'Sync', startUtc: start, endUtc: end, attendees: [dana]),
        preview: const WritePreview(
            method: 'POST', path: '/me/events', notifies: [dana]),
      );
      expect(invited.undo, isNull);
    });

    test('a commit with no preview offers none: nobody showed it emailed '
        'nobody', () async {
      final start = t0.add(const Duration(days: 3));
      final end = start.add(const Duration(minutes: 30));
      backend.answers['create'] = [const EventWriteAck(id: 'made')];
      final outcome = await writes.commit(
          CreateEvent.propose(subject: 'Focus', startUtc: start, endUtc: end));
      expect(outcome.ok, isTrue);
      expect(outcome.undo, isNull);
    });

    test('an RSVP, a cancel and a delete have none', () async {
      await calendar.upsertEvents([timed('e1'), timed('e2')], syncRun: run);
      expect(
          (await writes.commit(
                  const RespondToEvent('e1', RsvpResponse.accept)))
              .undo,
          isNull);
      expect((await writes.commit(const DeleteEvent('e1'))).undo, isNull);
      expect((await writes.commit(const CancelMeeting('e2'))).undo, isNull);
    });
  });

  group('failures', () {
    test('a changed event is re-read and stored, then said', () async {
      await calendar.upsertEvents([timed('e1', changeKey: 'old')],
          syncRun: run);
      backend.live['e1'] = timed('e1', changeKey: 'fresh');
      backend.answers['update'] = [const CalendarEventChanged()];
      final outcome = await writes.commit(MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1))));
      expect(outcome.ok, isFalse);
      expect(outcome.message,
          'This event changed in Outlook — check it and try again.');
      expect(outcome.retry, isNull);
      expect((await calendar.event('e1'))!.changeKey, 'fresh');
      expect(changed, 1);
      final detail = jsonDecode((await writeRows()).first['detail_json']
          as String) as Map<String, dynamic>;
      expect(detail['outcome'], 'changed');
    });

    test('a changed event in a preview is re-read too', () async {
      await calendar.upsertEvents([timed('e1', changeKey: 'old')],
          syncRun: run);
      backend.live['e1'] = timed('e1', changeKey: 'fresh');
      backend.answers['update'] = [const CalendarEventChanged()];
      final result = await writes.preview(MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1))));
      expect(result, isA<PreviewFailed>());
      expect((await calendar.event('e1'))!.changeKey, 'fresh');
    });

    test('not the organiser, a missing scope and reconnect say so', () async {
      backend.answers['delete'] = [
        const CalendarNotOrganizer(),
        const CalendarScopeMissing(),
        const ReconsentRequired(),
      ];
      final a = await writes.preview(const DeleteEvent('e1')) as PreviewFailed;
      expect(a.message, 'Only the organiser can change this meeting.');
      expect(a.retry, isNull);
      final b = await writes.preview(const DeleteEvent('e1')) as PreviewFailed;
      expect(b.message,
          'Calendar write permission missing — reconnect in Settings.');
      final c = await writes.preview(const DeleteEvent('e1')) as PreviewFailed;
      expect(c.message,
          'Reconnect Microsoft in Settings, then try again. Nothing was '
          'changed.');
    });

    test('a gone event is dropped from the mirror', () async {
      await calendar.upsertEvents(
          [timed('e1'), timed('occ', seriesMasterId: 'e1')],
          syncRun: run);
      backend.answers['cancel'] = [const CalendarEventGone()];
      final outcome = await writes.commit(const CancelMeeting('e1'));
      expect(outcome.message, 'This event no longer exists.');
      expect(await calendar.event('e1'), isNull);
      expect(await calendar.event('occ'), isNull);
      expect(changed, 1);
    });

    test('a refusal says its reason\'s first sentence', () async {
      backend.answers['respond'] = [
        const CalendarRefused('invalid_options',
            'Proposals are not allowed on this event. See the handoff §4.'),
        const CalendarRefused('invalid_options', 'No full stop here'),
        const CalendarRefused('invalid_options', ''),
      ];
      const w = RespondToEvent('e1', RsvpResponse.accept);
      expect((await writes.preview(w) as PreviewFailed).message,
          'Proposals are not allowed on this event.');
      expect((await writes.preview(w) as PreviewFailed).message,
          'No full stop here.');
      expect((await writes.preview(w) as PreviewFailed).message,
          'The calendar refused this (invalid_options).');
    });

    test('unavailable says its sentence; an argument error is invalid',
        () async {
      backend.answers['delete'] = [
        const CalendarUnavailable('Switch to MCP mode for a calendar.'),
        ArgumentError('half a proposal'),
      ];
      expect(
          (await writes.preview(const DeleteEvent('e1')) as PreviewFailed)
              .message,
          'Switch to MCP mode for a calendar.');
      expect(
          (await writes.preview(const DeleteEvent('e1')) as PreviewFailed)
              .message,
          "This can't be sent as it stands. Nothing was changed.");
    });

    test('a transient failure retries the SAME write, and a create keeps its '
        'transaction id', () async {
      final start = t0.add(const Duration(days: 3));
      final create = CreateEvent.propose(
          subject: 'Focus',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)));
      backend.answers['create'] = [
        const CalendarTransient('dropped', statusCode: 503),
        const EventWriteAck(id: 'made'),
      ];
      final failed = await writes.commit(create);
      expect(failed.ok, isFalse);
      // A real write lost in transit may have landed: never "Nothing was
      // changed", and the mirror is sent to look.
      expect(failed.message,
          "Couldn't confirm the calendar got this — check it before trying "
          'again.');
      expect(identical(failed.retry, create), isTrue);
      expect(changed, 0);
      expect(sync.forced, 1);
      final detail = jsonDecode((await writeRows()).first['detail_json']
          as String) as Map<String, dynamic>;
      expect(detail['outcome'], 'transient');

      final again = await writes.commit(failed.retry!);
      expect(again.ok, isTrue);
      final ids = backend.callsTo('create').map((c) => c.args['transactionId']);
      expect(ids.toSet(), {create.transactionId});
      expect(ids, hasLength(2));
    });

    test('a transient preview offers the retry too, and says nothing was '
        'changed', () async {
      backend.answers['delete'] = [StateError('socket closed')];
      const w = DeleteEvent('e1');
      final result = await writes.preview(w) as PreviewFailed;
      expect(result.message,
          "Couldn't reach the calendar. Nothing was changed.");
      expect(identical(result.retry, w), isTrue);
      expect(sync.forced, 0);
    });

    test('a transient RSVP commit offers no Try again — a second answer '
        'emails the organiser twice — and forces a sync', () async {
      backend.answers['respond'] = [
        const CalendarTransient('dropped', statusCode: 503),
      ];
      final outcome =
          await writes.commit(const RespondToEvent('e1', RsvpResponse.accept));
      expect(outcome.ok, isFalse);
      expect(outcome.message,
          "Couldn't confirm the calendar got this — check it before trying "
          'again.');
      expect(outcome.retry, isNull);
      expect(sync.forced, 1);
    });

    test('a transient cancel and delete commit offer no Try again either',
        () async {
      backend.answers['cancel'] = [StateError('socket closed')];
      backend.answers['delete'] = [StateError('socket closed')];
      expect((await writes.commit(const CancelMeeting('e1'))).retry, isNull);
      expect((await writes.commit(const DeleteEvent('e1'))).retry, isNull);
    });

    test('a transient move commit retries the SAME move: if_match turns a '
        'landed first try into event_changed', () async {
      await calendar.upsertEvents([timed('e1')], syncRun: run);
      backend.answers['update'] = [
        const CalendarTransient('dropped', statusCode: 503),
      ];
      final move = MoveEvent.timed('e1',
          startUtc: t0.add(const Duration(days: 2)),
          endUtc: t0.add(const Duration(days: 2, hours: 1)));
      final outcome = await writes.commit(move, preview: privately);
      expect(outcome.ok, isFalse);
      expect(identical(outcome.retry, move), isTrue);
      expect(sync.forced, 1);
    });
  });

  group('the activity row', () {
    test('counts and enum words only, never the subject or an address',
        () async {
      await calendar.upsertEvents([
        timed('e1',
            isOrganizer: false,
            attendees: const [Attendee(name: 'Dana Contoso', address: dana)]),
      ], syncRun: run);
      await writes.commit(
        const RespondToEvent('e1', RsvpResponse.decline,
            comment: 'Budget review clashes'),
        preview: toDana,
      );
      final row = (await writeRows()).single;
      expect(row['status'], 'ok');
      final detail =
          jsonDecode(row['detail_json'] as String) as Map<String, dynamic>;
      expect(detail.keys.toSet(), {'action', 'outcome', 'notified'});
      expect(detail['action'], 'decline');
      expect(detail['outcome'], 'ok');
      expect(detail['notified'], 1);
      final text = row.toString();
      expect(text, isNot(contains('Budget review')));
      expect(text, isNot(contains(dana)));
      expect(text, isNot(contains('e1')));
    });

    test('a failure records its outcome word', () async {
      backend.answers['delete'] = [const CalendarNotOrganizer()];
      await writes.commit(const DeleteEvent('e1'));
      final row = (await writeRows()).single;
      expect(row['status'], 'failed');
      final detail =
          jsonDecode(row['detail_json'] as String) as Map<String, dynamic>;
      expect(detail['outcome'], 'not_organizer');
      expect(detail['action'], 'delete');
    });

    test('a proposal is recorded as propose', () async {
      await writes.commit(RespondToEvent('e1', RsvpResponse.tentative,
          proposeStartUtc: t0.add(const Duration(days: 1)),
          proposeEndUtc: t0.add(const Duration(days: 1, hours: 1))));
      final detail = jsonDecode((await writeRows()).single['detail_json']
          as String) as Map<String, dynamic>;
      expect(detail['action'], 'propose');
    });
  });

  test('CreateEvent.propose makes a fresh 32-hex transaction id each time', () {
    final start = t0;
    final a = CreateEvent.propose(
        subject: 'x', startUtc: start, endUtc: start.add(const Duration(hours: 1)));
    final b = CreateEvent.propose(
        subject: 'x', startUtc: start, endUtc: start.add(const Duration(hours: 1)));
    expect(a.transactionId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(b.transactionId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(a.transactionId, isNot(b.transactionId));
  });

  test('firstSentence', () {
    expect(firstSentence('One. Two.'), 'One.');
    expect(firstSentence('  Only one  '), 'Only one.');
    expect(firstSentence(''), '');
  });
}
