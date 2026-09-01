// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The recorder itself: one row and one stream event per [ActivityLog.record],
/// the pending slot that folds a unit of work's model calls onto that row, and
/// the promise the whole design rests on — that none of it can throw into the
/// pipeline it observes.

LlmCallRecord call({
  String label = 'triage',
  int durationMs = 100,
  String outcome = 'ok',
  int? promptTokens,
  int? completionTokens,
  String? error,
}) =>
    LlmCallRecord(
      label: label,
      durationMs: durationMs,
      outcome: outcome,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      error: error,
    );

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ActivityLog log;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    log = ActivityLog(store);
  });

  tearDown(() async {
    log.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> only() async =>
      (await store.recentActivity()).single;

  Map<String, Object?> detailOf(Map<String, Object?> row) =>
      ActivityEvent.fromRow(row).detail;

  group('record', () {
    test('writes exactly one row and emits exactly one event', () async {
      final seen = <ActivityEvent>[];
      final sub = log.events.listen(seen.add);
      addTearDown(sub.cancel);

      await log.record(
        'triage',
        source: 'email',
        entityId: 'm1',
        count: 2,
        durationMs: 900,
        detail: {'urgency': 'high'},
      );
      await pumpEventQueue();

      expect(await store.recentActivity(), hasLength(1));
      expect(seen, hasLength(1));
      expect(seen.single.kind, 'triage');
      expect(seen.single.source, 'email');
      expect(seen.single.entityId, 'm1');
      expect(seen.single.count, 2);
      expect(seen.single.durationMs, 900);
      expect(seen.single.detail, {'urgency': 'high'});
      // The event carries the row's own id, so a panel can key off it.
      expect(seen.single.id, greaterThan(0));
    });

    test('defaults to ok and writes no detail when there is none', () async {
      // A kind the suppression rule does not touch: an empty `sync_mail` is
      // exactly what that rule exists to swallow, so it cannot stand in for a
      // plain row here.
      await log.record('triage');

      final row = await only();
      expect(row['status'], 'ok');
      expect(row['detail_json'], isNull);
    });

    test('a store that cannot be written to does not throw', () async {
      // The one rule the whole class serves: the log must never be able to
      // break the pipeline it observes.
      final closing = testDb();
      final broken = ActivityLog(MessageStore(closing));
      addTearDown(broken.dispose);
      await closing.close();

      // Awaited rather than merely called: the write fails inside the future
      // now, so a synchronous `returnsNormally` would prove nothing.
      await expectLater(broken.record('triage', entityId: 'm1'), completes);
      // And the failed write clears the pending slot rather than leaving it to
      // be attributed to whatever records next.
      expect(broken.pendingStatusOr('ok'), 'ok');
    });
  });

  group('suppression', () {
    test('a sync that brought nothing in writes no row, only a tick', () async {
      final seen = <ActivityEvent>[];
      final sub = log.events.listen(seen.add);
      addTearDown(sub.cancel);

      await log.record('sync_mail', source: 'email', count: 0, durationMs: 40);
      await pumpEventQueue();

      expect(await store.recentActivity(), isEmpty);
      // The tick still fires, because it is what keeps an open panel's
      // relative times moving. It was never stored, so it has no row id.
      expect(seen, hasLength(1));
      expect(seen.single.id, -1);
      expect(seen.single.kind, 'sync_mail');
      // And the fact the row would have carried survives in the pref, which is
      // what the panel's "last sync" tile reads.
      expect(await store.getPref(activityLastSyncMailKey), isNotNull);
    });

    test('a sync that brought something in is a row AND a stamp', () async {
      await log.record('sync_mail', source: 'email', count: 2, detail: {'inbox': 2});

      expect((await only())['count'], 2);
      expect(await store.getPref(activityLastSyncMailKey), isNotNull);
    });

    test('a Teams walk that scanned chats and stored nothing is quiet', () async {
      // A connected tenant always has chats to scan, so if the scan tally
      // counted as "something happened", no Teams sync would ever be quiet.
      await log.record(
        'sync_teams',
        source: 'teams',
        count: 0,
        durationMs: 350,
        detail: {'chats_seen': 5, 'chats_fetched': 2, 'queued_extract': 0},
      );

      expect(await store.recentActivity(), isEmpty);
      expect(await store.getPref(activityLastSyncTeamsKey), isNotNull);

      // The same walk with a stored message keeps its row, scan tally intact.
      await log.record(
        'sync_teams',
        source: 'teams',
        count: 1,
        durationMs: 350,
        detail: {'chats_seen': 5, 'chats_fetched': 2, 'queued_extract': 1},
      );

      expect(detailOf(await only())['chats_seen'], 5);
    });

    test('a detail value that is not a zero is something that happened', () async {
      // A 410 recovery moved no mail and is still the most interesting thing
      // the sync did that week.
      await log.record(
        'sync_mail',
        source: 'email',
        count: 0,
        detail: {'inbox': 0, 'sent': 0, 'resync': true},
      );

      expect(detailOf(await only())['resync'], isTrue);
    });

    test('only an ok pass is ever quiet, and only an ok pass stamps', () async {
      await log.record(
        'sync_mail',
        status: 'error',
        source: 'email',
        count: 0,
        detail: {'error': 'Graph is down'},
      );

      expect((await only())['status'], 'error');
      // A failed sync did not sync. Stamping it would let a broken connector
      // read as fresh.
      expect(await store.getPref(activityLastSyncMailKey), isNull);
    });

    test('a storyline pass is a row only when it filed something', () async {
      log.note({'assigned': 'Deal X'});
      await log.record('storyline', source: 'email', entityId: 'c1');

      expect(detailOf(await only())['assigned'], 'Deal X');

      await log.record('storyline', source: 'email', entityId: 'c2');

      expect(await store.recentActivity(), hasLength(1));
    });

    test('a sweep is a row only when it spent something', () async {
      // The model calls are the cost, and a sweep that made them is worth a
      // row whether or not it ended up proposing anything.
      log.noteLlmCall(call(label: 'storyline', durationMs: 900));
      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      expect(detailOf(await only())['llm_calls'], 1);

      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      expect(await store.recentActivity(), hasLength(1));
      expect(await store.getPref(activityLastSweepKey), isNotNull);
    });
  });

  group('disabled', () {
    test('stores nothing, emits nothing, and never throws', () async {
      final off = ActivityLog.disabled();

      expect(
        () => off
          ..note({'a': 1})
          ..noteStatus('skipped')
          ..noteLlmCall(call())
          ..record('triage', entityId: 'm1'),
        returnsNormally,
      );
      off.dispose();

      expect(await store.recentActivity(), isEmpty);
      expect(await off.events.isEmpty, isTrue);
    });

    test('its pending slot stays empty, so a worker sees its fallback', () async {
      final off = ActivityLog.disabled();
      addTearDown(off.dispose);

      off.noteStatus('skipped');

      expect(off.pendingStatusOr('ok'), 'ok');
    });
  });

  group('the pending slot', () {
    test('note folds facts onto the next row and only that row', () async {
      log.note({'intent': 'question', 'topics': ['rate lock']});
      await log.record('extract', entityId: 'm1');
      await log.record('extract', entityId: 'm2');

      final rows = await store.recentActivity();
      expect(detailOf(rows.last), {
        'intent': 'question',
        'topics': ['rate lock'],
      });
      expect(detailOf(rows.first), isEmpty);
    });

    test('an explicit detail wins over a noted key of the same name', () async {
      log.note({'reason': 'noted'});

      await log.record('extract', detail: {'reason': 'passed in'});

      expect(detailOf(await only())['reason'], 'passed in');
    });

    test('noteStatus is what a handler beats the worker with', () async {
      log.noteStatus('skipped');

      expect(log.pendingStatusOr('ok'), 'skipped');

      await log.record('extract', status: log.pendingStatusOr('ok'));

      expect((await only())['status'], 'skipped');
      // Consumed by the record, so the next item starts clean.
      expect(log.pendingStatusOr('ok'), 'ok');
    });

    test('one model call rides onto the row it was made for', () async {
      log.noteLlmCall(call(
        label: 'triage',
        durationMs: 1700,
        promptTokens: 900,
        completionTokens: 60,
      ));

      await log.record('triage', entityId: 'm1');

      expect(detailOf(await only()), {
        'llm_calls': 1,
        'llm_ms': 1700,
        'prompt_tokens': 900,
        'completion_tokens': 60,
        'llm_label': 'triage',
      });
    });

    test('several calls for one item sum onto one row', () async {
      // A storyline sweep makes more than one call per item, and they belong
      // on the item's row rather than on rows of their own.
      log.noteLlmCall(call(durationMs: 1000, promptTokens: 100, completionTokens: 10));
      log.noteLlmCall(call(durationMs: 500, promptTokens: 40, completionTokens: 5));

      await log.record('storyline_sweep', entityId: 'sweep');

      final detail = detailOf(await only());
      expect(detail['llm_calls'], 2);
      expect(detail['llm_ms'], 1500);
      expect(detail['prompt_tokens'], 140);
      expect(detail['completion_tokens'], 15);
    });

    test('a failed call leaves its reason on the row', () async {
      log.noteLlmCall(call(outcome: 'format', error: 'not JSON'));

      await log.record('triage', status: 'retry', entityId: 'm1');

      expect(detailOf(await only())['llm_error'], 'not JSON');
    });

    test('the tally is cleared by the row it landed on', () async {
      log.noteLlmCall(call());
      await log.record('triage', entityId: 'm1');
      await log.record('triage', entityId: 'm2');

      final rows = await store.recentActivity();
      expect(detailOf(rows.last)['llm_calls'], 1);
      expect(detailOf(rows.first), isEmpty);
    });
  });
}
