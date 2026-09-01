import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
  late Database db;
  late MessageStore store;
  late ActivityLog log;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
    log = ActivityLog(store);
  });

  tearDown(() {
    log.dispose();
    db.close();
  });

  Map<String, Object?> only() => store.recentActivity().single;

  Map<String, Object?> detailOf(Map<String, Object?> row) =>
      ActivityEvent.fromRow(row).detail;

  group('record', () {
    test('writes exactly one row and emits exactly one event', () async {
      final seen = <ActivityEvent>[];
      final sub = log.events.listen(seen.add);
      addTearDown(sub.cancel);

      log.record(
        'triage',
        source: 'email',
        entityId: 'm1',
        count: 2,
        durationMs: 900,
        detail: {'urgency': 'high'},
      );
      await pumpEventQueue();

      expect(store.recentActivity(), hasLength(1));
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

    test('defaults to ok and writes no detail when there is none', () {
      // A kind the suppression rule does not touch: an empty `sync_mail` is
      // exactly what that rule exists to swallow, so it cannot stand in for a
      // plain row here.
      log.record('triage');

      final row = only();
      expect(row['status'], 'ok');
      expect(row['detail_json'], isNull);
    });

    test('a store that cannot be written to does not throw', () async {
      // The one rule the whole class serves: the log must never be able to
      // break the pipeline it observes.
      final closing = openDbAt(':memory:');
      final broken = ActivityLog(MessageStore(closing));
      addTearDown(broken.dispose);
      closing.close();

      expect(() => broken.record('triage', entityId: 'm1'), returnsNormally);
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

      log.record('sync_mail', source: 'email', count: 0, durationMs: 40);
      await pumpEventQueue();

      expect(store.recentActivity(), isEmpty);
      // The tick still fires, because it is what keeps an open panel's
      // relative times moving. It was never stored, so it has no row id.
      expect(seen, hasLength(1));
      expect(seen.single.id, -1);
      expect(seen.single.kind, 'sync_mail');
      // And the fact the row would have carried survives in the pref, which is
      // what the panel's "last sync" tile reads.
      expect(store.getPref(activityLastSyncMailKey), isNotNull);
    });

    test('a sync that brought something in is a row AND a stamp', () {
      log.record('sync_mail', source: 'email', count: 2, detail: {'inbox': 2});

      expect(only()['count'], 2);
      expect(store.getPref(activityLastSyncMailKey), isNotNull);
    });

    test('a detail value that is not a zero is something that happened', () {
      // A 410 recovery moved no mail and is still the most interesting thing
      // the sync did that week.
      log.record(
        'sync_mail',
        source: 'email',
        count: 0,
        detail: {'inbox': 0, 'sent': 0, 'resync': true},
      );

      expect(detailOf(only())['resync'], isTrue);
    });

    test('only an ok pass is ever quiet, and only an ok pass stamps', () {
      log.record(
        'sync_mail',
        status: 'error',
        source: 'email',
        count: 0,
        detail: {'error': 'Graph is down'},
      );

      expect(only()['status'], 'error');
      // A failed sync did not sync. Stamping it would let a broken connector
      // read as fresh.
      expect(store.getPref(activityLastSyncMailKey), isNull);
    });

    test('a storyline pass is a row only when it filed something', () {
      log.note({'assigned': 'Deal X'});
      log.record('storyline', source: 'email', entityId: 'c1');

      expect(detailOf(only())['assigned'], 'Deal X');

      log.record('storyline', source: 'email', entityId: 'c2');

      expect(store.recentActivity(), hasLength(1));
    });

    test('a sweep is a row only when it spent something', () {
      // The model calls are the cost, and a sweep that made them is worth a
      // row whether or not it ended up proposing anything.
      log.noteLlmCall(call(label: 'storyline', durationMs: 900));
      log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      expect(detailOf(only())['llm_calls'], 1);

      log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      expect(store.recentActivity(), hasLength(1));
      expect(store.getPref(activityLastSweepKey), isNotNull);
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

      expect(store.recentActivity(), isEmpty);
      expect(await off.events.isEmpty, isTrue);
    });

    test('its pending slot stays empty, so a worker sees its fallback', () {
      final off = ActivityLog.disabled();
      addTearDown(off.dispose);

      off.noteStatus('skipped');

      expect(off.pendingStatusOr('ok'), 'ok');
    });
  });

  group('the pending slot', () {
    test('note folds facts onto the next row and only that row', () {
      log.note({'intent': 'question', 'topics': ['rate lock']});
      log.record('extract', entityId: 'm1');
      log.record('extract', entityId: 'm2');

      final rows = store.recentActivity();
      expect(detailOf(rows.last), {
        'intent': 'question',
        'topics': ['rate lock'],
      });
      expect(detailOf(rows.first), isEmpty);
    });

    test('an explicit detail wins over a noted key of the same name', () {
      log.note({'reason': 'noted'});

      log.record('extract', detail: {'reason': 'passed in'});

      expect(detailOf(only())['reason'], 'passed in');
    });

    test('noteStatus is what a handler beats the worker with', () {
      log.noteStatus('skipped');

      expect(log.pendingStatusOr('ok'), 'skipped');

      log.record('extract', status: log.pendingStatusOr('ok'));

      expect(only()['status'], 'skipped');
      // Consumed by the record, so the next item starts clean.
      expect(log.pendingStatusOr('ok'), 'ok');
    });

    test('one model call rides onto the row it was made for', () {
      log.noteLlmCall(call(
        label: 'triage',
        durationMs: 1700,
        promptTokens: 900,
        completionTokens: 60,
      ));

      log.record('triage', entityId: 'm1');

      expect(detailOf(only()), {
        'llm_calls': 1,
        'llm_ms': 1700,
        'prompt_tokens': 900,
        'completion_tokens': 60,
        'llm_label': 'triage',
      });
    });

    test('several calls for one item sum onto one row', () {
      // A storyline sweep makes more than one call per item, and they belong
      // on the item's row rather than on rows of their own.
      log.noteLlmCall(call(durationMs: 1000, promptTokens: 100, completionTokens: 10));
      log.noteLlmCall(call(durationMs: 500, promptTokens: 40, completionTokens: 5));

      log.record('storyline_sweep', entityId: 'sweep');

      final detail = detailOf(only());
      expect(detail['llm_calls'], 2);
      expect(detail['llm_ms'], 1500);
      expect(detail['prompt_tokens'], 140);
      expect(detail['completion_tokens'], 15);
    });

    test('a failed call leaves its reason on the row', () {
      log.noteLlmCall(call(outcome: 'format', error: 'not JSON'));

      log.record('triage', status: 'retry', entityId: 'm1');

      expect(detailOf(only())['llm_error'], 'not JSON');
    });

    test('the tally is cleared by the row it landed on', () {
      log.noteLlmCall(call());
      log.record('triage', entityId: 'm1');
      log.record('triage', entityId: 'm2');

      final rows = store.recentActivity();
      expect(detailOf(rows.last)['llm_calls'], 1);
      expect(detailOf(rows.first), isEmpty);
    });
  });
}
