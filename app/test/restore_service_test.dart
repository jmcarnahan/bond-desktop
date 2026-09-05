import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/restore_service.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// One model server for the whole chain: triage, extraction and the needs-you
/// judgement each read the keys they know out of the same map and ignore the
/// rest, so a single answer can serve all three without the test having to
/// script which handler asks in which order.
class FakeLlm extends LlmClient {
  final List<String> userMessages = [];

  FakeLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    userMessages.add(user);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return {
      // Triage.
      'urgency': 'normal',
      'category': 'work',
      'summary': 'Dana asks about the renewal.',
      'needs_action': true,
      'action_items': const ['Look at the DPA'],
      'reply_expected': true,
      'deadline': '',
      // Extraction.
      'evidence': 'Dana wants the DPA looked at.',
      'topics': const ['DPA'],
      'people': const ['Dana'],
      'organizations': const ['Acme'],
      'project': 'Acme renewal',
      'intent': 'request',
      'importance': 'high',
      // Needs-you.
      'needs_you': true,
      'confidence': 'high',
    };
  }
}

/// An embedding server that always answers, so extraction can finish without
/// one running.
EmbeddingsClient fakeEmbeddings() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'embedding': [0.6, 0.8]
                }
              ]
            }),
            200,
          )),
    );

/// Restore end to end: what it writes, in what order, and what the pipeline
/// makes of the message afterwards.
///
/// The order is the part that is contract rather than convenience. The stamp
/// has to land before anything else so a drain already running cannot claim
/// the row and re-gate it mid-restore, and the AI worker's drain has to wait
/// on triage's — an extract handler that reaches an untriaged row reads no
/// reply cue on it and chains no draft, which is the failure the last test
/// here would catch.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed({
    String source = 'email',
    String id = 'm1',
    String from = 'no-reply@example.com',
    String receivedAt = '2026-09-01T10:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': 'This week at Northwind',
      'from_name': 'Alex Rivera',
      'from_address': from,
      'to_json': '["owner@example.com"]',
      'body_text': 'Dana wants a look at the renewal paperwork.',
      'addressed_me': 1,
      'received_at': receivedAt,
    });
  }

  Future<Map<String, Object?>> messageOf(String id,
          {String source = 'email'}) async =>
      (await store.getMessageRow(source, id))!;

  Future<Map<String, Object?>> progressOf(String id,
          {String source = 'email'}) async =>
      (await db.customSelect(
        'SELECT * FROM message_progress '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(source), Variable(id)],
      ).getSingle())
          .data;

  Future<String?> workStatus(String kind, String id,
      {String source = 'email'}) async {
    final rows = await db.customSelect(
      'SELECT status FROM work_items '
      'WHERE task_kind = ? AND source = ? AND entity_id = ?',
      variables: [Variable(kind), Variable(source), Variable(id)],
    ).get();
    return rows.isEmpty ? null : rows.first.data['status'] as String?;
  }

  group('the sequence', () {
    test('the body is fetched before either pump fires, and triage first',
        () async {
      await seed();
      final events = <String>[];
      final service = RestoreService(
        store,
        ensureBody: (id) async => events.add('fetch:$id'),
        pumpTriage: () async => events.add('triage'),
        pumpWork: () async => events.add('work'),
      );

      await service.restore('email', 'm1');
      // The pumps are launched unawaited and chained to each other, so give
      // the microtasks their turn.
      await Future<void>.delayed(Duration.zero);

      expect(events, ['fetch:m1', 'triage', 'work']);
    });

    test('a teams message is never asked for a detail fetch', () async {
      await seed(source: 'teams', id: 't1', from: 'teams:u-1');
      final fetched = <String>[];
      final service = RestoreService(
        store,
        ensureBody: (id) async => fetched.add(id),
      );

      await service.restore('teams', 't1');

      // A chat body arrived whole at ingest; there is no second call that
      // would improve it.
      expect(fetched, isEmpty);
      expect((await messageOf('t1', source: 'teams'))['gate_override'], 'user');
    });

    test('a failed fetch degrades rather than aborting the restore', () async {
      await seed();
      var pumped = 0;
      final service = RestoreService(
        store,
        ensureBody: (_) async => throw StateError('graph is down'),
        pumpTriage: () async => pumped++,
        pumpWork: () async => pumped++,
      );

      await service.restore('email', 'm1');
      await Future<void>.delayed(Duration.zero);

      // Triage classifies from the preview and the queue's own tier-two fetch
      // tries again on the claim, so losing a body is never a reason to leave
      // the message dropped.
      expect((await messageOf('m1'))['gate_override'], 'user');
      expect(await workStatus('extract', 'm1'), 'pending');
      expect(pumped, 2);
    });
  });

  group('what it queues', () {
    test('work the pipeline already finished is offered again', () async {
      await seed();
      for (final kind in ['extract', 'needs_you', 'embed_message']) {
        await store.requeueWork(kind, 'email', 'm1');
      }
      await db.customUpdate(
        "UPDATE work_items SET status = 'done' WHERE entity_id = 'm1'",
      );

      await RestoreService(store).restore('email', 'm1');

      // `requeueWork` and not `enqueueWork`: `INSERT OR IGNORE` against these
      // `done` rows would mean the work is never offered again.
      for (final kind in ['extract', 'needs_you', 'embed_message']) {
        expect(await workStatus(kind, 'm1'), 'pending', reason: kind);
      }
    });

    test('the draft is left to the extract handler to chain', () async {
      await seed();

      await RestoreService(store).restore('email', 'm1');

      expect(await workStatus('draft', 'm1'), null);
    });

    test('the progress row is actually reset, not merely ticked at', () async {
      await seed();
      await store.writeTriageProgress(
        'email',
        'm1',
        state: 'skipped',
        gateReason: 'no_reply',
      );
      expect((await progressOf('m1'))['dropped'], 1);

      await RestoreService(
        store,
        progress: PipelineProgress(store),
      ).restore('email', 'm1');

      final row = await progressOf('m1');
      expect(row['dropped'], 0);
      expect(row['drop_reason'], null);
      expect(row['triage_state'], 'pending');
    });
  });

  test('a restored newsletter runs the whole pipeline instead of re-gating',
      () async {
    await seed();
    // Through the real queue, so the row starts exactly where a gate leaves
    // one: skipped, with the drop cascaded over its progress.
    final llm = FakeLlm();
    final progress = PipelineProgress(store);
    // One gate across both drains, as the app wires it. The gate alone is not
    // what orders them — see the chaining in `RestoreService._pumpBoth` — but
    // without it the two drains would overlap here in a way they never do in
    // the app.
    final gate = DrainGate();
    final queue = TriageQueue(store, llm, progress: progress, gate: gate);
    await queue.pump();
    expect((await messageOf('m1'))['gate_reason'], 'no_reply');
    expect((await progressOf('m1'))['dropped'], 1);

    final worker = AiWorker(
      store,
      gate: gate,
      handlers: [
        ExtractHandler(store, llm, fakeEmbeddings()),
        NeedsYouHandler(store, llm),
      ],
    );

    // The service fires its pumps and forgets them, so the test needs its own
    // hold on the tail of that chain: the second pump signals when its drain
    // has settled, and everything below runs after it.
    final drained = Completer<void>();
    await RestoreService(
      store,
      progress: progress,
      pumpTriage: queue.pump,
      pumpWork: () async {
        await worker.pump();
        drained.complete();
      },
    ).restore('email', 'm1');
    await drained.future;

    final message = await messageOf('m1');
    expect(message['triage_status'], 'triaged',
        reason: 'the gate that took it the first time must not fire again');
    expect(message['gate_reason'], null);
    expect(message['needs_you_verdict'], isNotNull);
    expect(await store.getExtraction('email', 'm1'), isNotNull);
    // Chained by the extract handler rather than queued by the restore.
    expect(await workStatus('draft', 'm1'), 'pending');
  });
}
