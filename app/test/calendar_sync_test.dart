import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/backend_types.dart'
    show NotSignedIn;
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// One `syncPage` call as the fake saw it.
typedef _Call = ({String cursor, String? startUtc, String? endUtc});

/// A scripted calendar: each `syncPage` call takes the next step — a page, a
/// throw, or a closure (for a page held open on a completer).
class _FakeCalendarBackend implements CalendarBackend {
  final List<Object> steps = [];
  final List<_Call> calls = [];
  int mailboxCalls = 0;
  Future<MailboxSettings> Function() mailbox = () async =>
      const MailboxSettings(
        timeZone: 'Pacific Standard Time',
        timeZoneIana: 'America/Los_Angeles',
      );

  @override
  Future<CalendarSyncPage> syncPage({
    String cursor = '',
    String? startUtc,
    String? endUtc,
  }) async {
    calls.add((cursor: cursor, startUtc: startUtc, endUtc: endUtc));
    if (steps.isEmpty) {
      throw StateError('no scripted step for call ${calls.length}');
    }
    final step = steps.removeAt(0);
    if (step is CalendarSyncPage) return step;
    if (step is Future<CalendarSyncPage> Function()) return step();
    throw step;
  }

  @override
  Future<MailboxSettings> mailboxSettings() {
    mailboxCalls += 1;
    return mailbox();
  }

  @override
  Future<CalendarEvent> getEvent(String id) => throw UnimplementedError();

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
      throw UnimplementedError();

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
      throw UnimplementedError();

  @override
  Future<CalendarWriteResult> cancel(
    String id, {
    String? comment,
    bool dryRun = false,
  }) =>
      throw UnimplementedError();

  @override
  Future<CalendarWriteResult> delete(String id, {bool dryRun = false}) =>
      throw UnimplementedError();

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
      throw UnimplementedError();

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

/// A store whose run-state write can be made to fail, for the new-run
/// branch's atomicity: the cursor clear before it must roll back with it.
class _FailingRunStore extends MessageStore {
  _FailingRunStore(super.db);

  bool failRunWrite = false;

  @override
  Future<void> setPref(String key, String value) {
    if (failRunWrite && key == calendarRunKey) {
      throw StateError('the disk is full');
    }
    return super.setPref(key, value);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late _FakeCalendarBackend backend;
  late DateTime clock;
  late ActivityLog activity;

  // The window is derived from the injected clock, never from the machine's,
  // so a literal here cannot rot.
  final t0 = DateTime.utc(2026, 10, 5, 15);

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    backend = _FakeCalendarBackend();
    clock = t0;
    activity = ActivityLog(store);
  });

  tearDown(() async {
    activity.dispose();
    await db.close();
  });

  CalendarSync build({
    Future<CalendarSyncStatus?> Function()? precheck,
    MessageStore? over,
  }) =>
      CalendarSync(
        backend,
        over ?? store,
        calendar,
        activityLog: activity,
        clock: () => clock,
        precheck: precheck,
      );

  CalendarEvent event(String id, {String changeKey = 'ck'}) => CalendarEvent(
        id: id,
        subject: 'Standup $id',
        startUtc: t0.add(const Duration(days: 1)),
        endUtc: t0.add(const Duration(days: 1, minutes: 15)),
        changeKey: changeKey,
      );

  CalendarSyncPage page({
    List<String> ids = const [],
    List<String> removed = const [],
    String cursor = '',
    bool complete = true,
    String windowStart = '',
    String windowEnd = '',
  }) =>
      CalendarSyncPage(
        events: [for (final id in ids) event(id)],
        removed: removed,
        cursor: cursor,
        complete: complete,
        windowStart: windowStart,
        windowEnd: windowEnd,
      );

  Future<String?> storedCursor() =>
      store.getDeltaLink('primary', source: 'calendar');

  Future<Map<String, dynamic>> runState() async =>
      jsonDecode((await store.getPref(calendarRunKey))!)
          as Map<String, dynamic>;

  Future<List<String>> storedIds() async => [
        for (final r in await db
            .customSelect('SELECT id FROM calendar_events ORDER BY id')
            .get())
          r.data['id'] as String,
      ];

  Future<String?> storedRun() async =>
      (await runState())['run'] as String?;

  Future<String?> syncRunOf(String id) async {
    final rows = await db
        .customSelect('SELECT sync_run FROM calendar_events WHERE id = ?',
            variables: [Variable(id)])
        .get();
    return rows.isEmpty ? null : rows.first.data['sync_run'] as String?;
  }

  /// Lets a held tick reach its `syncPage` call.
  Future<void> untilCalled(int n) async {
    for (var i = 0; i < 200 && backend.calls.length < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(backend.calls, hasLength(n));
  }

  Future<List<Map<String, Object?>>> calendarRows() async => [
        for (final r in await store.recentActivity(limit: 50))
          if (r['kind'] == 'sync_calendar') r,
      ];

  group('a run', () {
    test('the first tick sends the window and persists state and cursor',
        () async {
      backend.steps.add(page(ids: ['a', 'b'], cursor: 'd1'));
      final outcome = await build().syncNow();

      expect(outcome.status, CalendarSyncStatus.synced);
      expect(outcome.upserts, 2);
      expect(outcome.newRun, isTrue);
      expect(outcome.complete, isTrue);
      expect(backend.calls.single.cursor, '');
      // Thirty days back and 120 ahead at UTC midnights, end exclusive.
      expect(backend.calls.single.startUtc, '2026-09-05T00:00:00Z');
      expect(backend.calls.single.endUtc, '2027-02-03T00:00:00Z');
      expect(await storedCursor(), 'd1');
      final state = await runState();
      expect(state['start'], '2026-09-05T00:00:00Z');
      expect(state['end'], '2027-02-03T00:00:00Z');
      expect(state['run'], calendarStamp(t0));
      expect(state['swept'], isTrue);
    });

    test('a window the first page echoes is the one persisted', () async {
      backend.steps.add(page(
        cursor: 'd1',
        windowStart: '2026-09-04T00:00:00Z',
        windowEnd: '2027-02-02T00:00:00Z',
      ));
      await build().syncNow();
      final state = await runState();
      expect(state['start'], '2026-09-04T00:00:00Z');
      expect(state['end'], '2027-02-02T00:00:00Z');
    });

    test('loops while incomplete, continuing without a window', () async {
      backend.steps
        ..add(page(ids: ['a'], cursor: 'c1', complete: false))
        ..add(page(ids: ['b'], cursor: 'd1'));
      final outcome = await build().syncNow();

      expect([for (final c in backend.calls) c.cursor], ['', 'c1']);
      expect(backend.calls[1].startUtc, isNull);
      expect(backend.calls[1].endUtc, isNull);
      expect(outcome.pages, 2);
      expect(outcome.upserts, 2);
      expect(await storedCursor(), 'd1');
    });

    test('the page cap leaves the cursor and the sweep for a later tick',
        () async {
      await calendar.upsertEvents([event('ancient')], syncRun: 'old-run');
      for (var i = 1; i <= CalendarSync.maxPagesPerTick; i++) {
        backend.steps.add(page(ids: ['e$i'], cursor: 'c$i', complete: false));
      }
      final sync = build();
      final first = await sync.syncNow();

      expect(first.pages, CalendarSync.maxPagesPerTick);
      expect(first.complete, isFalse);
      expect(backend.calls, hasLength(CalendarSync.maxPagesPerTick));
      expect(await storedCursor(), 'c10');
      expect((await runState())['swept'], isFalse);
      expect(await storedIds(), contains('ancient'));

      backend.steps.add(page(ids: ['e11'], cursor: 'd1'));
      final second = await sync.syncNow(force: true);

      expect(backend.calls.last.cursor, 'c10');
      expect(second.newRun, isFalse);
      expect(second.complete, isTrue);
      expect(second.swept, 1);
      expect(await storedIds(), isNot(contains('ancient')));
      expect(await storedIds(), hasLength(11));
      expect((await runState())['swept'], isTrue);
    });

    test('removed ids are deleted and unknown ones ignored', () async {
      final sync = build();
      backend.steps.add(page(ids: ['a', 'b'], cursor: 'd1'));
      await sync.syncNow();
      backend.steps.add(page(removed: ['a', 'ghost'], cursor: 'd2'));
      final outcome = await sync.syncNow(force: true);

      expect(outcome.removed, 1);
      expect(await storedIds(), ['b']);
    });

    test('a page handing back the cursor it was sent stops the tick',
        () async {
      backend.steps
        ..add(page(ids: ['a'], cursor: 'c1', complete: false))
        ..add(page(cursor: 'c1', complete: false));
      final outcome = await build().syncNow();

      expect(outcome.status, CalendarSyncStatus.synced);
      expect(outcome.pages, 2);
      expect(outcome.complete, isFalse);
      expect(backend.calls, hasLength(2));
      expect(await storedCursor(), 'c1');
    });

    test('an expired cursor restarts the same window and sweeps what the new '
        'run did not return', () async {
      final sync = build();
      backend.steps.add(page(ids: ['a', 'b'], cursor: 'd1'));
      await sync.syncNow();
      final before = await runState();

      clock = clock.add(const Duration(minutes: 5));
      backend.steps
        ..add(const CalendarCursorExpired())
        ..add(page(ids: ['a'], cursor: 'c1', complete: false))
        ..add(page(cursor: 'd2'));
      final outcome = await sync.syncNow(force: true);

      expect([for (final c in backend.calls) c.cursor], ['', 'd1', '', 'c1']);
      expect(backend.calls[2].startUtc, before['start']);
      expect(backend.calls[2].endUtc, before['end']);
      expect(outcome.newRun, isTrue);
      expect(outcome.swept, 1);
      expect(await storedIds(), ['a']);
      final after = await runState();
      expect(after['start'], before['start']);
      expect(after['run'], isNot(before['run']));
      expect(after['swept'], isTrue);
      expect(await storedCursor(), 'd2');
    });

    test('an empty cursor with complete starts a new run next tick', () async {
      final sync = build();
      backend.steps.add(page(ids: ['a'], cursor: 'd1'));
      await sync.syncNow();
      backend.steps.add(page(ids: ['a'], cursor: ''));
      await sync.syncNow(force: true);
      expect(await storedCursor(), isNull);

      backend.steps.add(page(ids: ['a'], cursor: 'd3'));
      final third = await sync.syncNow(force: true);
      expect(backend.calls.last.cursor, '');
      expect(backend.calls.last.startUtc, isNotNull);
      expect(third.newRun, isTrue);
    });

    test('the window rolls once its start is a week stale', () async {
      final sync = build();
      backend.steps.add(page(cursor: 'd1'));
      await sync.syncNow();

      clock = t0.add(const Duration(days: 6));
      backend.steps.add(page(cursor: 'd2'));
      final kept = await sync.syncNow(force: true);
      expect(kept.newRun, isFalse);
      expect(backend.calls.last.cursor, 'd1');

      clock = t0.add(const Duration(days: 8));
      backend.steps.add(page(cursor: 'd3'));
      final rolled = await sync.syncNow(force: true);
      expect(rolled.newRun, isTrue);
      expect(backend.calls.last.cursor, '');
      expect(backend.calls.last.startUtc, '2026-09-13T00:00:00Z');
    });

    test('a new run clears the cursor and writes its state together or not '
        'at all', () async {
      // A stale window over a live cursor: this tick must start a new run.
      final old = jsonEncode({
        'start': '2026-08-01T00:00:00Z',
        'end': '2026-12-01T00:00:00Z',
        'run': 'old-run',
        'swept': true,
      });
      await store.setPref(calendarRunKey, old);
      await store.setDeltaLink('primary', 'd-old', source: 'calendar');
      final failing = _FailingRunStore(db)..failRunWrite = true;

      final outcome = await build(over: failing).syncNow();

      expect(outcome.status, CalendarSyncStatus.failed);
      expect(outcome.message, 'StateError');
      expect(backend.calls, isEmpty);
      // The cursor clear ran first and was rolled back with the failed write:
      // never the old cursor under a new run id, never a new run without it.
      expect(await storedCursor(), 'd-old');
      expect(await store.getPref(calendarRunKey), old);

      failing.failRunWrite = false;
      backend.steps.add(page(cursor: 'd1'));
      final retried = await build(over: failing).syncNow();
      expect(retried.newRun, isTrue);
      expect(backend.calls.single.cursor, '');
      expect(await storedRun(), calendarStamp(t0));
      expect(await storedCursor(), 'd1');
    });

    test('an expiry on a first page is a failure and restarts nothing',
        () async {
      backend.steps.add(const CalendarCursorExpired());
      final outcome = await build().syncNow();

      expect(outcome.status, CalendarSyncStatus.failed);
      expect(outcome.message, 'CalendarCursorExpired');
      expect(backend.calls, hasLength(1));
      expect(await storedCursor(), isNull);
      final state = await runState();
      expect(state['run'], calendarStamp(t0));
      expect(state['swept'], isFalse);
    });

    test('a second expiry in the same tick is a failure', () async {
      final sync = build();
      backend.steps.add(page(ids: ['a'], cursor: 'd1'));
      await sync.syncNow();

      clock = clock.add(const Duration(minutes: 5));
      backend.steps
        ..add(const CalendarCursorExpired())
        ..add(page(ids: ['a'], cursor: 'c1', complete: false))
        ..add(const CalendarCursorExpired());
      final outcome = await sync.syncNow(force: true);

      expect(outcome.status, CalendarSyncStatus.failed);
      expect([for (final c in backend.calls) c.cursor], ['', 'd1', '', 'c1']);
      // What the restarted run had read stays; the next tick carries on.
      expect(await storedCursor(), 'c1');
      expect(await storedRun(), calendarStamp(clock));
    });
  });

  group('the generation check', () {
    test('a tick in flight across a wipe writes nothing back', () async {
      final gate = Completer<CalendarSyncPage>();
      backend.steps.add(() => gate.future);
      final sync = build();

      final tick = sync.syncNow();
      await untilCalled(1);
      await store.wipeAll();
      gate.complete(page(ids: ['a', 'b'], cursor: 'd1'));
      final outcome = await tick;

      expect(outcome.status, CalendarSyncStatus.skipped);
      expect(sync.availability, CalendarAvailability.unknown);
      expect(await storedIds(), isEmpty);
      final cursors = await db
          .customSelect(
              "SELECT COUNT(*) AS n FROM sync_state WHERE source = 'calendar'")
          .getSingle();
      expect((cursors.data['n'] as num).toInt(), 0);
      expect(await store.getPref(calendarRunKey), isNull);
      expect(await store.getPref(calendarMailboxKey), isNull);
      expect(backend.mailboxCalls, 0);

      // Nothing was learned, so nothing is throttled: the next tick starts
      // the new mailbox's run at once.
      backend.steps.add(page(ids: ['c'], cursor: 'd2'));
      final next = await sync.syncNow();
      expect(next.status, CalendarSyncStatus.synced);
      expect(next.newRun, isTrue);
      expect(await storedIds(), ['c']);
    });

    test('a tick whose run another tick replaced writes nothing', () async {
      final gate = Completer<CalendarSyncPage>();
      backend.steps.add(() => gate.future);
      final orphan = build();

      final tick = orphan.syncNow();
      await untilCalled(1);
      // What a rebuilt provider's fresh sync, or anything else that starts
      // its own run, leaves behind.
      await store.setPref(
        calendarRunKey,
        jsonEncode({
          'start': '2026-09-05T00:00:00Z',
          'end': '2027-02-03T00:00:00Z',
          'run': 'newer-run',
          'swept': false,
        }),
      );
      gate.complete(page(ids: ['a'], cursor: 'd1'));

      expect((await tick).status, CalendarSyncStatus.skipped);
      expect(await storedIds(), isEmpty);
      expect(await storedCursor(), isNull);
      expect(await storedRun(), 'newer-run');
    });
  });

  group('when it runs', () {
    test('unforced ticks inside the throttle ask the backend nothing',
        () async {
      final sync = build();
      backend.steps.add(page(cursor: 'd1'));
      await sync.syncNow();
      final synced = sync.lastOutcome;

      clock = clock.add(const Duration(seconds: 60));
      final skipped = await sync.syncNow();
      expect(skipped.status, CalendarSyncStatus.skipped);
      expect(backend.calls, hasLength(1));
      expect(sync.lastOutcome, same(synced));

      backend.steps.add(page(cursor: 'd2'));
      final forced = await sync.syncNow(force: true);
      expect(forced.status, CalendarSyncStatus.synced);
      expect(backend.calls, hasLength(2));

      clock = clock.add(CalendarSync.throttle + const Duration(seconds: 1));
      backend.steps.add(page(cursor: 'd3'));
      expect((await sync.syncNow()).status, CalendarSyncStatus.synced);
      expect(backend.calls, hasLength(3));
    });

    test('a call while one runs joins it, forced or not', () async {
      final gate = Completer<CalendarSyncPage>();
      backend.steps.add(() => gate.future);
      final sync = build();

      final first = sync.syncNow();
      final second = sync.syncNow(force: true);
      expect(identical(first, second), isTrue);

      gate.complete(page(cursor: 'd1'));
      expect((await first).status, CalendarSyncStatus.synced);
      expect(backend.calls, hasLength(1));
    });

    test('every answer backs off, not only a synced one', () async {
      CalendarSyncStatus? pre;
      final sync = build(precheck: () async => pre);

      backend.steps.add(const CalendarTransient('dropped'));
      expect((await sync.syncNow()).status, CalendarSyncStatus.failed);
      clock = clock.add(const Duration(seconds: 60));
      expect((await sync.syncNow()).status, CalendarSyncStatus.skipped);
      expect(backend.calls, hasLength(1));

      pre = CalendarSyncStatus.scopeMissing;
      expect((await sync.syncNow(force: true)).status,
          CalendarSyncStatus.scopeMissing);
      clock = clock.add(const Duration(seconds: 60));
      expect((await sync.syncNow()).status, CalendarSyncStatus.skipped);

      clock = clock.add(CalendarSync.throttle);
      expect((await sync.syncNow()).status, CalendarSyncStatus.scopeMissing);

      pre = null;
      backend.steps.add(page(cursor: 'd1'));
      expect((await sync.syncNow(force: true)).status,
          CalendarSyncStatus.synced);
      expect(backend.calls, hasLength(2));
    });

    test('the precheck answers without a backend call', () async {
      for (final status in [
        CalendarSyncStatus.sdkMode,
        CalendarSyncStatus.scopeMissing,
        CalendarSyncStatus.unavailable,
      ]) {
        final outcome =
            await build(precheck: () async => status).syncNow(force: true);
        expect(outcome.status, status);
      }
      expect(backend.calls, isEmpty);
    });
  });

  group('failures', () {
    test('a failure never throws and keeps the progress made', () async {
      backend.steps
        ..add(page(ids: ['a'], cursor: 'c1', complete: false))
        ..add(const CalendarTransient('Graph answered 503', statusCode: 503));
      final sync = build();
      final outcome = await sync.syncNow();

      expect(outcome.status, CalendarSyncStatus.failed);
      // The type, never the sentence, which can carry an endpoint.
      expect(outcome.message, 'CalendarTransient');
      expect(await storedCursor(), 'c1');
      expect(await storedIds(), ['a']);
      expect(sync.availability, CalendarAvailability.unknown);
    });

    test('a scope missing is recorded once, not every tick', () async {
      final sync = build();
      backend.steps
        ..add(const CalendarScopeMissing())
        ..add(const CalendarScopeMissing());
      expect((await sync.syncNow()).status, CalendarSyncStatus.scopeMissing);
      expect((await sync.syncNow(force: true)).status,
          CalendarSyncStatus.scopeMissing);

      final rows = await calendarRows();
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'error');
      expect(jsonDecode(rows.single['detail_json'] as String),
          {'outcome': 'scope_missing'});
    });

    test('availability follows each outcome, and a failure keeps it',
        () async {
      CalendarSyncStatus? pre;
      final sync = build(precheck: () async => pre);
      expect(sync.availability, CalendarAvailability.unknown);

      backend.steps.add(page(cursor: 'd1'));
      await sync.syncNow();
      expect(sync.availability, CalendarAvailability.available);

      backend.steps.add(const CalendarTransient('dropped'));
      await sync.syncNow(force: true);
      expect(sync.availability, CalendarAvailability.available);

      backend.steps.add(const NotSignedIn());
      await sync.syncNow(force: true);
      expect(sync.availability, CalendarAvailability.unavailable);

      pre = CalendarSyncStatus.scopeMissing;
      await sync.syncNow(force: true);
      expect(sync.availability, CalendarAvailability.scopeMissing);

      pre = CalendarSyncStatus.sdkMode;
      await sync.syncNow(force: true);
      expect(sync.availability, CalendarAvailability.sdkMode);

      // The first run's row and the one scope-missing row; nothing for the
      // failure, the sign-out or SDK mode.
      final rows = await calendarRows();
      expect([for (final r in rows) r['status']]..sort(), ['error', 'ok']);
    });
  });

  group('the write guard', () {
    test('an event written during the tick is not overwritten or swept',
        () async {
      await calendar.upsertEvents([event('mine', changeKey: 'after-write')],
          syncRun: 'old-run');
      final gate = Completer<CalendarSyncPage>();
      backend.steps.add(() => gate.future);
      final sync = build();

      final tick = sync.syncNow();
      await Future<void>.delayed(Duration.zero);
      clock = clock.add(const Duration(seconds: 1));
      sync.noteWrite('mine');
      gate.complete(CalendarSyncPage(
        events: [event('mine', changeKey: 'before-write'), event('other')],
        cursor: 'd1',
      ));
      final outcome = await tick;

      expect(outcome.upserts, 1);
      expect(outcome.swept, 0);
      expect((await calendar.event('mine'))!.changeKey, 'after-write');
      expect(await storedIds(), ['mine', 'other']);
    });

    test('a write noted before a page was requested does not block it',
        () async {
      await calendar.upsertEvents([event('mine', changeKey: 'after-write')],
          syncRun: 'old-run');
      late final CalendarSync sync;
      // The write lands while the FIRST page is in the air; the second page
      // is requested after it, so it already carries the write.
      backend.steps
        ..add(() async {
          sync.noteWrite('mine');
          clock = clock.add(const Duration(seconds: 1));
          return page(ids: ['a'], cursor: 'c1', complete: false);
        })
        ..add(CalendarSyncPage(
          events: [event('mine', changeKey: 'newer')],
          cursor: 'd1',
        ));
      sync = build();
      final outcome = await sync.syncNow();

      expect(outcome.upserts, 2);
      expect((await calendar.event('mine'))!.changeKey, 'newer');
    });

    test('a skipped write is re-tagged with the run and survives a sweep long '
        'after the guard', () async {
      await calendar.upsertEvents([event('mine', changeKey: 'after-write')],
          syncRun: 'old-run');
      late final CalendarSync sync;
      backend.steps.add(() async {
        clock = clock.add(const Duration(seconds: 1));
        sync.noteWrite('mine');
        return CalendarSyncPage(
          events: [event('mine', changeKey: 'before-write'), event('other')],
          cursor: 'c1',
          complete: false,
        );
      });
      // The server's "a later page failed": the tick stops short of complete.
      backend.steps.add(page(cursor: 'c1', complete: false));
      sync = build();
      final first = await sync.syncNow();

      expect(first.upserts, 1);
      expect(first.complete, isFalse);
      expect((await calendar.event('mine'))!.changeKey, 'after-write');
      expect(await syncRunOf('mine'), await storedRun());

      // Past the guard's span, so the sweep's keep list no longer names it:
      // only the re-tag keeps it.
      clock = clock.add(const Duration(minutes: 11));
      backend.steps.add(page(cursor: 'd1'));
      final second = await sync.syncNow();

      expect(second.complete, isTrue);
      expect(second.swept, 0);
      expect(await storedIds(), ['mine', 'other']);
      expect((await calendar.event('mine'))!.changeKey, 'after-write');
    });

    test('a write older than the tick does not block the page', () async {
      await calendar.upsertEvents([event('mine', changeKey: 'after-write')],
          syncRun: 'old-run');
      final sync = build()..noteWrite('mine');
      clock = clock.add(const Duration(seconds: 1));
      backend.steps.add(CalendarSyncPage(
        events: [event('mine', changeKey: 'newer')],
        cursor: 'd1',
      ));
      await sync.syncNow();
      expect((await calendar.event('mine'))!.changeKey, 'newer');
    });
  });

  group('mailbox settings', () {
    test('fetched after a sync, then cached for a day', () async {
      final sync = build();
      backend.steps.add(page(cursor: 'd1'));
      await sync.syncNow();
      expect(backend.mailboxCalls, 1);
      final cached = await CalendarSync.readMailboxSettings(store);
      expect(cached?.timeZoneIana, 'America/Los_Angeles');

      clock = clock.add(const Duration(hours: 23));
      backend.steps.add(page(cursor: 'd2'));
      await sync.syncNow();
      expect(backend.mailboxCalls, 1);

      clock = clock.add(const Duration(hours: 2));
      backend.steps.add(page(cursor: 'd3'));
      await sync.syncNow();
      expect(backend.mailboxCalls, 2);
    });

    test('a missing scope is cached as no settings; other failures are not',
        () async {
      final sync = build();
      backend.mailbox = () async => throw const CalendarTransient('dropped');
      backend.steps.add(page(cursor: 'd1'));
      expect((await sync.syncNow()).status, CalendarSyncStatus.synced);
      expect(await store.getPref(calendarMailboxKey), isNull);

      backend.mailbox = () async => throw const CalendarScopeMissing(
            CalendarScopeMissing.mailboxSettings,
          );
      backend.steps.add(page(cursor: 'd2'));
      await sync.syncNow(force: true);
      expect(backend.mailboxCalls, 2);
      final stored =
          jsonDecode((await store.getPref(calendarMailboxKey))!) as Map;
      expect(stored['settings'], isNull);
      expect(stored['fetched_at'], isA<String>());
      expect(await CalendarSync.readMailboxSettings(store), isNull);

      backend.steps.add(page(cursor: 'd3'));
      await sync.syncNow(force: true);
      expect(backend.mailboxCalls, 2);
    });

    test('the tick that writes the cache says so, even when nothing moved',
        () async {
      final sync = build();
      backend.mailbox = () async => throw const CalendarTransient('dropped');
      backend.steps.add(page(ids: ['a'], cursor: 'd1'));
      final first = await sync.syncNow();
      expect(first.changed, isTrue);
      expect(first.settingsRefreshed, isFalse);

      backend.mailbox = () async => const MailboxSettings(
            timeZone: 'Pacific Standard Time',
            timeZoneIana: 'America/Los_Angeles',
          );
      backend.steps.add(page(cursor: 'd2'));
      final quiet = await sync.syncNow(force: true);
      expect(quiet.changed, isFalse);
      expect(quiet.settingsRefreshed, isTrue);
      expect(sync.lastOutcome?.settingsRefreshed, isTrue);

      backend.steps.add(page(cursor: 'd3'));
      final cached = await sync.syncNow(force: true);
      expect(cached.settingsRefreshed, isFalse);
      // The activity row still follows the mirror alone: the first run's.
      expect(await calendarRows(), hasLength(1));
    });

    test('an unreadable cache reads as none', () async {
      await store.setPref(calendarMailboxKey, '{not json');
      expect(await CalendarSync.readMailboxSettings(store), isNull);
    });
  });

  group('activity', () {
    test('a changed sync writes one row of counts; a quiet delta writes none',
        () async {
      final sync = build();
      backend.steps.add(page(ids: ['a', 'b'], cursor: 'd1'));
      await sync.syncNow();
      backend.steps.add(page(cursor: 'd2'));
      await sync.syncNow(force: true);

      final rows = await calendarRows();
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'ok');
      expect(rows.single['count'], 2);
      expect(jsonDecode(rows.single['detail_json'] as String), {
        'removed': 0,
        'swept': 0,
        'pages': 1,
        'run': 'new',
      });
    });
  });

  group('calendarPrecheck', () {
    Future<CalendarSyncStatus?> check({
      bool sdk = false,
      Set<String> granted = const {},
      bool throws = false,
    }) =>
        calendarPrecheck(sdk, (scope) async {
          if (throws) throw StateError('probe failed');
          return granted.contains(scope);
        });

    test('SDK mode has no calendar', () async {
      expect(await check(sdk: true, granted: {'calendars.read'}),
          CalendarSyncStatus.sdkMode);
    });

    test('a grant with the scope goes on', () async {
      expect(await check(granted: {'calendars.read', 'mail.read'}), isNull);
    });

    test('a session that answers mail but not calendars lacks the scope',
        () async {
      expect(await check(granted: {'mail.read'}),
          CalendarSyncStatus.scopeMissing);
    });

    test('a session that answers nothing is unavailable, not missing a scope',
        () async {
      expect(await check(), CalendarSyncStatus.unavailable);
    });

    test('a probe that throws is unavailable', () async {
      expect(await check(throws: true), CalendarSyncStatus.unavailable);
    });
  });
}
