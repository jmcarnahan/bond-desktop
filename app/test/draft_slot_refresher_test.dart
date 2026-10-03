import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/draft_slot_refresher.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The stale-times redraft: an untouched draft whose offered times have
/// started, or that a busy mirror event now blocks, is deleted and its draft
/// re-queued; an edited one never is. Wed Oct 14 2026, 9:00 AM in Los
/// Angeles; fictional meetings.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late CalendarZone la;
  late DraftSlotRefresher refresher;

  // Wed Oct 14 2026, 9:00 AM PDT.
  final now = DateTime.utc(2026, 10, 14, 16);
  // Thu Oct 15, 10:00 and 14:00 PDT.
  final thuTen = DateTime.utc(2026, 10, 15, 17);
  final thuTwo = DateTime.utc(2026, 10, 15, 21);
  const half = Duration(minutes: 30);

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    refresher = DraftSlotRefresher(
        store: store, calendar: calendar, log: ActivityLog(store));
  });

  tearDown(() async => db.close());

  /// A draft against [id] offering [starts] (30 minutes each).
  Future<void> draft(
    String id, {
    required List<DateTime> starts,
    String status = 'suggested',
    bool improved = false,
  }) =>
      store.upsertDraft(
        source: 'email',
        conversationKey: 'c-$id',
        replyToMessageId: id,
        body: 'Happy to meet.\n\nWould any of these work? · …',
        status: status,
        contextJson: DraftProvenance.none.copyWith(calendar: {
          'slots': [
            for (final s in starts)
              {
                'start_utc': MessageStore.isoStamp(s),
                'end_utc': MessageStore.isoStamp(s.add(half)),
              },
          ],
          'source': 'graph',
          'window': 'this_week',
          'graph_calls': 1,
          'read': 'rules',
          'minutes': 30,
          if (improved) 'improved': true,
        }).encode(),
      );

  Future<void> event(String id, DateTime start, {String showAs = 'busy'}) =>
      calendar.upsertEvents([
        CalendarEvent(
          id: id,
          subject: 'Planning',
          startUtc: start,
          endUtc: start.add(half),
          showAs: showAs,
        ),
      ], syncRun: 'run-1');

  Future<String?> workStatus(String id) async {
    final rows = await db
        .customSelect(
          "SELECT status FROM work_items WHERE task_kind = 'draft' "
          "AND source = 'email' AND entity_id = ?",
          variables: [Variable(id)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['status'] as String?;
  }

  Future<int> refresh() => refresher.refresh(now: now, zone: la);

  test('a slot in the past re-queues the draft', () async {
    await draft('m1', starts: [now.subtract(const Duration(hours: 1)), thuTen]);
    await draft('m2', starts: [thuTen, thuTwo]);

    expect(await refresh(), 1);
    expect(await store.getDraftForMessage('email', 'm1'), isNull);
    expect(await store.getDraftForMessage('email', 'm2'), isNotNull,
        reason: 'its times still stand');
  });

  test('a slot starting now is gone too', () async {
    await draft('m1', starts: [now]);
    expect(await refresh(), 1);
  });

  test('a new busy event over a slot re-queues it', () async {
    await draft('m1', starts: [thuTen, thuTwo]);
    await event('e1', thuTwo.add(const Duration(minutes: 15)));

    expect(await refresh(), 1);
    expect(await store.getDraftForMessage('email', 'm1'), isNull);
  });

  test('out of office blocks; a free or tentative event does not', () async {
    await draft('m1', starts: [thuTen]);
    await draft('m2', starts: [thuTwo]);
    await event('free', thuTen, showAs: 'free');
    await event('maybe', thuTwo, showAs: 'tentative');
    await event('away', thuTen.add(const Duration(days: 1)), showAs: 'oof');
    expect(await refresh(), 0,
        reason: 'tentative is the Day column\'s soft overlap: said, never '
            'refused');

    await draft('m3', starts: [thuTen.add(const Duration(days: 1))]);
    expect(await refresh(), 1);
    expect(await store.getDraftForMessage('email', 'm3'), isNull);
  });

  test('a meeting ending as the slot starts does not overlap it', () async {
    await draft('m1', starts: [thuTen]);
    await event('before', thuTen.subtract(half));
    expect(await refresh(), 0);
  });

  test('a cancelled or declined meeting blocks nothing', () async {
    await draft('m1', starts: [thuTen]);
    await calendar.upsertEvents([
      CalendarEvent(
          id: 'gone',
          startUtc: thuTen,
          endUtc: thuTen.add(half),
          showAs: 'busy',
          isCancelled: true),
      CalendarEvent(
          id: 'no',
          startUtc: thuTen,
          endUtc: thuTen.add(half),
          showAs: 'busy',
          responseStatus: 'declined'),
    ], syncRun: 'run-1');
    expect(await refresh(), 0);
  });

  test('an edited draft is never touched', () async {
    await draft('m1', starts: [now.subtract(const Duration(hours: 1))],
        status: 'edited');
    await draft('m2', starts: [now.subtract(const Duration(hours: 1))],
        status: 'sent');

    expect(await refresh(), 0);
    expect((await store.getDraftForMessage('email', 'm1'))!['status'],
        'edited');
    expect(await workStatus('m1'), isNull);
  });

  test('a stale improved draft is left alone', () async {
    // The owner pressed Improve (maybe a cloud call on the day's ledger):
    // like an edited draft, it is never thrown away.
    await draft('m1',
        starts: [now.subtract(const Duration(hours: 1))], improved: true);
    expect(await refresh(), 0);
    expect(await store.getDraftForMessage('email', 'm1'), isNotNull);
    expect(await workStatus('m1'), isNull);
  });

  test('an asked-for draft keeps its payload through the re-queue', () async {
    const asked = '{"asked":true,"pinned_attachment_ids":["a1"]}';
    await store.requeueWork('draft', 'email', 'm1', payloadJson: asked);
    await db.customUpdate(
      "UPDATE work_items SET status = 'done' WHERE entity_id = 'm1'",
    );
    await draft('m1', starts: [now.subtract(const Duration(hours: 1))]);

    expect(await refresh(), 1);
    expect(await workStatus('m1'), 'pending');
    expect(await store.workPayload('draft', 'email', 'm1'), asked);
  });

  test('a draft that offers no times is never touched', () async {
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c-m1',
      replyToMessageId: 'm1',
      body: 'Thanks.',
    );
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c-m2',
      replyToMessageId: 'm2',
      body: 'Thanks.',
      contextJson: '{not json',
    );
    expect(await refresh(), 0);
    expect(await store.getDraftForMessage('email', 'm1'), isNotNull);
    expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
  });

  test('the cap of five', () async {
    for (var i = 0; i < 7; i++) {
      await draft('m$i', starts: [now.subtract(const Duration(hours: 1))]);
    }
    expect(await refresh(), DraftSlotRefresher.maxPerPass);
    expect(DraftSlotRefresher.maxPerPass, 5);
    expect(await refresh(), 2, reason: 'the rest go on the next pass');
  });

  test('the work row exists after', () async {
    // A draft queued and written: its work row is done.
    await store.requeueWork('draft', 'email', 'm1');
    await db.customUpdate(
      "UPDATE work_items SET status = 'done' WHERE entity_id = 'm1'",
    );
    await draft('m1', starts: [now.subtract(const Duration(hours: 1))]);
    await draft('m2', starts: [now.subtract(const Duration(hours: 1))]);

    expect(await refresh(), 2);
    expect(await workStatus('m1'), 'pending', reason: 'the done row revived');
    expect(await workStatus('m2'), 'pending', reason: 'a row made');
  });

  test('the activity row carries a count only', () async {
    await draft('m1', starts: [now.subtract(const Duration(hours: 1))]);
    await draft('m2', starts: [now.subtract(const Duration(hours: 1))]);
    await refresh();

    final rows = [
      for (final r in await store.recentActivity())
        if (r['kind'] == 'draft') r,
    ];
    expect(rows, hasLength(1));
    expect(rows.single['status'], 'requeued');
    expect(rows.single['count'], 2);
    expect(rows.single['entity_id'], isNull);
    expect(jsonDecode(rows.single['detail_json'] as String),
        {'reason': 'slots_stale'});

    // Nothing stale: no row at all.
    await refresh();
    expect(
        [
          for (final r in await store.recentActivity())
            if (r['kind'] == 'draft') r,
        ],
        hasLength(1));
  });
}
