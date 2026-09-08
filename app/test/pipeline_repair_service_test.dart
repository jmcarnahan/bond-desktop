import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/pipeline_repair_service.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Retry: what it puts back on a queue, and what it refuses to touch.
///
/// The load-bearing property is that the list it returns is TRUE. A screen
/// shows the person what was retried, so a stage named there must actually
/// have moved — which means a terminal stage is never claimed, and neither is
/// a stage that was already in flight and that `requeueWork` therefore left
/// exactly where it was.
///
/// The pumps are the other half. They fire even when nothing was requeued,
/// because the commonest way a row stops is a queue nobody is turning, and a
/// Retry that did nothing in that case would be a button that lies.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One message and the `message_progress` row that comes with it, then
  /// whatever this test wants the two rows to say.
  Future<void> seed({
    String source = 'email',
    String id = 'm1',
    String conversationKey = 'c1',
    String triageStatus = 'triaged',
    String triageState = 'done',
    String extractState = 'done',
    String storylineState = 'done',
    String draftState = 'done',
    String outcome = 'pending',
    bool dropped = false,
    int? needsYouVerdict,
    String progressUpdatedAt = '2026-09-01T09:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': 'Renewal paperwork',
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'body_text': 'Could you look at the DPA before Friday?',
      'received_at': '2026-09-01T08:00:00Z',
      'triage_status': triageStatus,
    });
    if (needsYouVerdict != null) {
      await store.writeNeedsYouVerdict(
        source,
        id,
        verdict: needsYouVerdict == 1,
        reason: 'asks for the DPA by Friday',
      );
    }
    await db.customUpdate(
      'UPDATE message_progress SET triage_state = ?, extract_state = ?, '
      'storyline_state = ?, draft_state = ?, outcome = ?, dropped = ?, '
      'updated_at = ? WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(triageState),
        Variable(extractState),
        Variable(storylineState),
        Variable(draftState),
        Variable(outcome),
        Variable(dropped ? 1 : 0),
        Variable(progressUpdatedAt),
        Variable(source),
        Variable(id),
      ],
    );
  }

  Future<Map<String, Object?>> progressOf(String id,
          {String source = 'email'}) async =>
      (await db.customSelect(
        'SELECT * FROM message_progress '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(source), Variable(id)],
      ).getSingle())
          .data;

  Future<String?> workStatus(String kind, String id,
      {String source = 'email'}) =>
      store.workStatusOf(kind, source, id);

  Future<List<ActivityEvent>> activity() async => [
        for (final row in await store.recentActivity(limit: 5))
          ActivityEvent.fromRow(row),
      ];

  group('what it puts back', () {
    test('an errored row owes every stage after it', () async {
      await seed(
        triageStatus: 'error',
        triageState: 'error',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
      );
      final pumped = <String>[];
      final service = PipelineRepairService(
        store,
        // A real recorder, because the progress write IS part of the retry.
        progress: PipelineProgress(store),
        activityLog: ActivityLog(store),
        pumpTriage: () async => pumped.add('triage'),
        pumpWork: () async => pumped.add('work'),
      );

      final stages = await service.retryOwed('email', 'm1');
      // The pumps are launched unawaited and chained, so give the microtasks
      // their turn.
      await Future<void>.delayed(Duration.zero);

      expect(stages, ['triage', 'extract', 'needs_you', 'storyline', 'draft']);
      expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
          'pending');
      expect(await workStatus('extract', 'm1'), 'pending');
      expect(await workStatus('needs_you', 'm1'), 'pending');
      // Storyline work is filed under the conversation key, never the message.
      expect(await workStatus('storyline', 'c1'), 'pending');
      expect(await workStatus('storyline', 'm1'), isNull);
      expect(await workStatus('draft', 'm1'), 'pending');
      // A retry is a progress write: the stalled clock starts again.
      expect((await progressOf('m1'))['updated_at'],
          isNot('2026-09-01T09:00:00Z'));
      // Triage before the worker, for the reason RestoreService chains them.
      expect(pumped, ['triage', 'work']);
    });

    test('it says what it did, in the log as well as in the answer', () async {
      await seed(
        triageState: 'error',
        triageStatus: 'error',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
      );
      final service =
          PipelineRepairService(store, activityLog: ActivityLog(store));

      final stages = await service.retryOwed('email', 'm1');

      final event = (await activity()).firstWhere((e) => e.kind == 'retry');
      expect(event.entityId, 'm1');
      expect(event.source, 'email');
      expect(event.count, stages.length);
      expect(event.detail['stages'], stages);
    });
  });

  group('what it refuses to touch', () {
    test('a finished row owes nothing, and the pumps still fire', () async {
      await seed(outcome: 'done', needsYouVerdict: 1);
      final pumped = <String>[];
      final service = PipelineRepairService(
        store,
        activityLog: ActivityLog(store),
        pumpTriage: () async => pumped.add('triage'),
        pumpWork: () async => pumped.add('work'),
      );

      final stages = await service.retryOwed('email', 'm1');
      await Future<void>.delayed(Duration.zero);

      expect(stages, isEmpty);
      for (final kind in const ['extract', 'needs_you', 'draft']) {
        expect(await workStatus(kind, 'm1'), isNull);
      }
      expect(await workStatus('storyline', 'c1'), isNull);
      // Nothing happened, so nothing is claimed to have happened.
      expect(await activity(), isEmpty);
      // A row can be stalled on a queue that is simply not draining, and
      // turning that queue is the whole repair.
      expect(pumped, ['triage', 'work']);
    });

    test('a stage already in flight is left alone, and not claimed', () async {
      await seed(extractState: 'pending', needsYouVerdict: 1);
      await store.enqueueWork('extract', 'email', 'm1');
      await store.writeWork('extract', 'email', 'm1', status: 'processing');
      final service = PipelineRepairService(store);

      final stages = await service.retryOwed('email', 'm1');

      // `requeueWork` leaves a `processing` row where it is — resetting it
      // would hand a worker's item to a second drain — so naming the stage
      // would be claiming credit for work already under way.
      expect(stages, isEmpty);
      expect(await workStatus('extract', 'm1'), 'processing');
    });

    test('a dropped row is Restore\'s business, not this one\'s', () async {
      await seed(
        dropped: true,
        outcome: 'dropped',
        triageState: 'skipped',
        extractState: 'skipped',
        storylineState: 'skipped',
        draftState: 'skipped',
      );
      final service =
          PipelineRepairService(store, activityLog: ActivityLog(store));

      expect(await service.retryOwed('email', 'm1'), isEmpty);
      expect(await workStatus('extract', 'm1'), isNull);
      expect(await activity(), isEmpty);
    });

    test('a message nothing is stored under owes nothing', () async {
      final service = PipelineRepairService(store);

      expect(await service.retryOwed('email', 'ghost'), isEmpty);
    });

    test('a service with no log and no pumps still works', () async {
      await seed(extractState: 'pending', needsYouVerdict: 1);

      expect(await PipelineRepairService(store).retryOwed('email', 'm1'),
          ['extract']);
    });
  });

  group('the tick', () {
    late ProgressBus bus;
    late List<ProgressTick> ticks;

    setUp(() {
      bus = ProgressBus();
      ticks = [];
      bus.ticks.listen(ticks.add);
    });

    tearDown(() => bus.dispose());

    test('one tick goes out, under the first stage owed', () async {
      await seed(
        triageState: 'error',
        triageStatus: 'error',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
      );
      final service = PipelineRepairService(
        store,
        progress: PipelineProgress(store, bus: bus),
      );

      await service.retryOwed('email', 'm1');

      expect(ticks, hasLength(1));
      // Honest rather than nominal: triage is the stage about to run.
      expect(ticks.single.stage, 'triage');
      expect(ticks.single.state, 'pending');
      expect(ticks.single.sourceMessageId, 'm1');
      expect(ticks.single.receivedAt, '2026-09-01T08:00:00Z');
    });

    test('a row that owes nothing ticks nothing', () async {
      await seed(outcome: 'done', needsYouVerdict: 1);
      final service = PipelineRepairService(
        store,
        progress: PipelineProgress(store, bus: bus),
      );

      await service.retryOwed('email', 'm1');

      expect(ticks, isEmpty);
    });
  });
}
