import 'dart:async';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show TriageResult;
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What a queue owes the rows it is holding when it is torn down.
///
/// Both queues are rebuilt when the user switches backend — the providers
/// watch the preference — and a rebuild used to mean every message the drain
/// had claimed sat `processing` until the next launch cleared it. Nothing
/// else in the suite notices: the app keeps working perfectly against the new
/// backend, minus whatever the old one was mid-way through.

/// An [LlmClient] that holds its first answer until the test lets go, so a
/// dispose can land while a message is genuinely at the server.
class HeldLlm extends LlmClient {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  int calls = 0;

  HeldLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await release.future;
    return {
      'urgency': 'high',
      'category': 'work',
      'summary': 'Sarah asks about the launch date.',
      'needs_action': true,
      'action_items': const ['Call Sarah'],
    };
  }
}

/// An [LlmClient] that answers at once.
class FastLlm extends HeldLlm {
  FastLlm() {
    release.complete();
  }
}

/// A store whose result writes fail — a disk that filled, a database closed
/// under a teardown. The one way an item can finish without ever clearing its
/// own claim, and so the one thing [TriageQueue.dispose] has to clean up.
class BrokenStore extends MessageStore {
  BrokenStore(super.db);

  @override
  Future<void> writeTriage(
    String source,
    String sourceMessageId, {
    required String status,
    TriageResult? result,
    String? error,
    String? gateReason,
    int? attempts,
  }) =>
      Future.error(StateError('the write failed'));

  @override
  Future<void> writeWork(
    String kind,
    String source,
    String entityId, {
    required String status,
    String? error,
    int? attempts,
  }) =>
      Future.error(StateError('the write failed'));
}

/// A [WorkHandler] that reports when it started and waits to be let go.
class HeldHandler extends WorkHandler {
  @override
  final String kind;

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  final List<String> seen = [];

  HeldHandler(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    if (!started.isCompleted) started.complete();
    await release.future;
  }
}

/// An [LlmClient] that holds EACH call on its own latch, so a test can end
/// the first message while the second is still at the server.
class HeldPerCallLlm extends LlmClient {
  final List<Completer<void>> started = [Completer(), Completer()];
  final List<Completer<void>> release = [Completer(), Completer()];

  int calls = 0;

  HeldPerCallLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    final i = calls++;
    started[i].complete();
    await release[i].future;
    return {
      'urgency': 'high',
      'category': 'work',
      'summary': 'Sarah asks about the launch date.',
      'needs_action': true,
      'action_items': const ['Call Sarah'],
    };
  }
}

/// A store that holds the SECOND triage claim until the test lets go — the
/// shape of the dispose race: a claim already at the store when the queue is
/// told to stop, landing after dispose has taken its first look at what is
/// in flight.
class HeldSecondClaimStore extends MessageStore {
  HeldSecondClaimStore(super.db);

  final Completer<void> holdSecond = Completer<void>();
  int _claims = 0;

  @override
  Future<Map<String, Object?>?> claimPendingTriage({
    List<String> sources = const ['email'],
  }) async {
    if (++_claims == 2) await holdSecond.future;
    return super.claimPendingTriage(sources: sources);
  }
}

/// The work-queue twin of [HeldSecondClaimStore].
class HeldSecondWorkClaimStore extends MessageStore {
  HeldSecondWorkClaimStore(super.db);

  final Completer<void> holdSecond = Completer<void>();
  int _claims = 0;

  @override
  Future<Map<String, Object?>?> claimPendingWork(
    String kind, {
    List<String> sources = const ['email'],
  }) async {
    if (++_claims == 2) await holdSecond.future;
    return super.claimPendingWork(kind, sources: sources);
  }
}

/// A [WorkHandler] wide enough to have a claim in flight while another item
/// runs, holding each item on its own latch.
class HeldPerItemHandler extends WorkHandler {
  @override
  final String kind;

  @override
  int get concurrency => 2;

  final List<Completer<void>> started = [Completer(), Completer()];
  final List<Completer<void>> release = [Completer(), Completer()];

  int _runs = 0;

  HeldPerItemHandler(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) async {
    final i = _runs++;
    started[i].complete();
    await release[i].future;
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedMessage(String id) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': 'Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-28T10:0$id:00Z',
      'body_text': 'Can we still ship on Thursday?',
      'triage_status': 'pending',
    });
  }

  Future<String?> triageStatus(String id) async =>
      (await store.getMessageRow('email', id))?['triage_status'] as String?;

  group('TriageQueue.dispose', () {
    test('keeps the answer already paid for and claims nothing more',
        () async {
      await seedMessage('1');
      await seedMessage('2');
      final llm = HeldLlm();
      final queue = TriageQueue(store, llm, concurrency: 1);

      final pumping = queue.pump();
      await llm.started.future;

      final disposing = queue.dispose();
      llm.release.complete();
      await disposing;
      await pumping;

      // The request was at the server and its answer is paid for, so it is
      // written rather than thrown away — and the message behind it (the drain
      // runs newest first) was never claimed, so it is simply still waiting.
      expect(llm.calls, 1);
      expect(await triageStatus('2'), 'triaged');
      expect(await triageStatus('1'), 'pending');
      expect((await store.triageCounts())['processing'], isNull);
    });

    test('hands back a claim whose result could not be written', () async {
      await seedMessage('1');
      final broken = BrokenStore(db);
      final queue = TriageQueue(broken, FastLlm(), concurrency: 1);

      await expectLater(queue.pump(), throwsA(isA<StateError>()));
      // The row is stranded: the claim was taken and nothing ever cleared it.
      expect(await triageStatus('1'), 'processing');

      await queue.dispose();

      expect(await triageStatus('1'), 'pending');
      // Nothing about the message failed, so it does not spend an attempt.
      expect(
        (await store.getMessageRow('email', '1'))!['triage_attempts'],
        0,
      );
    });

    test('and a fresh queue over the same store picks it up', () async {
      await seedMessage('1');
      final queue = TriageQueue(BrokenStore(db), FastLlm(), concurrency: 1);
      await expectLater(queue.pump(), throwsA(isA<StateError>()));
      await queue.dispose();

      // What a backend switch does: the old queue goes, a new one over the
      // same rows arrives, and the work is where it was.
      final replacement = TriageQueue(store, FastLlm(), concurrency: 1);
      await replacement.pump();
      await replacement.dispose();

      expect(await triageStatus('1'), 'triaged');
    });

    test('waits for a claim that was already at the store when it stopped',
        () async {
      await seedMessage('1');
      await seedMessage('2');
      final held = HeldSecondClaimStore(db);
      final llm = HeldPerCallLlm();
      final queue = TriageQueue(held, llm, concurrency: 2);

      final pumping = queue.pump();
      // Newest first: call 0 is message 2, and the claim for message 1 is now
      // suspended inside the store.
      await llm.started[0].future;

      var disposed = false;
      final disposing = queue.dispose().whenComplete(() => disposed = true);

      // The suspended claim lands AFTER dispose took its first look at what
      // was in flight — the message it claims is now genuinely running.
      held.holdSecond.complete();
      await llm.started[1].future;

      // The first message finishes. A dispose that only waited for that
      // snapshot would now hand back message 1's claim — flipping a message
      // that is still at the server to `pending`, for a second queue to
      // claim and pay for again.
      llm.release[0].complete();
      await pumpEventQueue();
      expect(disposed, isFalse);
      expect(await triageStatus('1'), 'processing');

      llm.release[1].complete();
      await disposing;
      await pumping;

      expect(llm.calls, 2);
      expect(await triageStatus('1'), 'triaged');
      expect(await triageStatus('2'), 'triaged');
      expect((await store.triageCounts())['processing'], isNull);
    });

    test('is safe with nothing claimed, and twice', () async {
      final queue = TriageQueue(store, FastLlm());

      await queue.dispose();
      await queue.dispose();
    });
  });

  group('AiWorker.dispose', () {
    Future<Map<String, Object?>> workRow(String kind, String id) async =>
        Map<String, Object?>.from(
          (await db
                  .customSelect(
                    'SELECT * FROM work_items '
                    'WHERE task_kind = ? AND entity_id = ?',
                    variables: [Variable(kind), Variable(id)],
                  )
                  .get())
              .single
              .data,
        );

    test('keeps the item already in flight and claims nothing more', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('extract', 'email', 'm2');
      final handler = HeldHandler('extract');
      final worker = AiWorker(store, handlers: [handler]);

      final pumping = worker.pump();
      await handler.started.future;

      final disposing = worker.dispose();
      handler.release.complete();
      await disposing;
      await pumping;

      expect(handler.seen, hasLength(1));
      expect((await workRow('extract', handler.seen.single))['status'], 'done');
      expect(await store.workCounts('extract'), containsPair('pending', 1));
      expect(await store.workCounts('extract'), isNot(contains('processing')));
    });

    test('waits for a claim that was already at the store when it stopped',
        () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('extract', 'email', 'm2');
      final held = HeldSecondWorkClaimStore(db);
      final handler = HeldPerItemHandler('extract');
      final worker = AiWorker(held, handlers: [handler]);

      final pumping = worker.pump();
      await handler.started[0].future;

      var disposed = false;
      final disposing = worker.dispose().whenComplete(() => disposed = true);

      held.holdSecond.complete();
      await handler.started[1].future;

      handler.release[0].complete();
      await pumpEventQueue();
      expect(disposed, isFalse);

      handler.release[1].complete();
      await disposing;
      await pumping;

      expect((await workRow('extract', 'm1'))['status'], 'done');
      expect((await workRow('extract', 'm2'))['status'], 'done');
      expect(await store.workCounts('extract'), isNot(contains('processing')));
    });

    test('hands back a claim whose result could not be written', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        BrokenStore(db),
        handlers: [ScriptedOk('extract')],
      );

      await expectLater(worker.pump(), throwsA(isA<StateError>()));
      expect((await workRow('extract', 'm1'))['status'], 'processing');

      await worker.dispose();

      final row = await workRow('extract', 'm1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 0);
    });

    test('and a fresh worker over the same store picks it up', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(BrokenStore(db), handlers: [ScriptedOk('extract')]);
      await expectLater(worker.pump(), throwsA(isA<StateError>()));
      await worker.dispose();

      final replacement = AiWorker(store, handlers: [ScriptedOk('extract')]);
      await replacement.pump();
      await replacement.dispose();

      expect((await workRow('extract', 'm1'))['status'], 'done');
    });
  });
}

/// A [WorkHandler] that suspends once and succeeds.
class ScriptedOk extends WorkHandler {
  @override
  final String kind;

  ScriptedOk(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) =>
      Future<void>.delayed(const Duration(milliseconds: 1));
}
