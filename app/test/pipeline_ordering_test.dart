import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The ordering invariant, end to end: a message is never extracted or judged
/// for needs-you before triage has spoken about it.
///
/// Everything below is the real thing except the two servers. One store, one
/// [DrainGate] shared by the triage queue and the AI worker exactly as
/// `app_providers` shares it, the real [ExtractHandler] and [NeedsYouHandler],
/// and the queue's `onDrained` wired to the worker's pump the way the provider
/// wires it. What the test drives is the ORDER the two drains run in, which is
/// the one thing the unit tests on either side cannot see.

/// An [LlmClient] that answers per task and records the order it was asked in.
///
/// The order is the assertion in most of this file, so the recording is by
/// `schemaName` — `triage`, `extraction`, `needs_you` — rather than by call
/// count, which cannot tell a drain that ran twice from one that ran backwards.
class FakeLlm extends LlmClient {
  final Map<String, Map<String, dynamic>> answers;
  final List<String> calls = [];

  FakeLlm(this.answers)
      : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    calls.add(schemaName);
    // A real call suspends, and both drains have to be able to interleave at
    // the await if they are going to.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final answer = answers[schemaName];
    if (answer == null) {
      throw StateError('no scripted answer for $schemaName');
    }
    return Map<String, dynamic>.from(answer);
  }
}

/// An [EmbeddingsClient] over a scripted socket, so extraction can finish
/// without a server — and so that "nothing was embedded" is a fact about the
/// inputs it was handed rather than about a connection that failed.
class FakeEmbeddings {
  final List<String> inputs = [];

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          inputs.add(body['input'] as String);
          return http.Response(
            jsonEncode({
              'data': [
                {'embedding': const [0.6, 0.8]}
              ]
            }),
            200,
          );
        }),
      );
}

const Map<String, dynamic> _triageAnswer = {
  'urgency': 'high',
  'category': 'work',
  'summary': 'Sarah is asking whether Thursday still holds.',
  'needs_action': true,
  'action_items': ['Confirm the launch date'],
  'reply_expected': true,
  'deadline': '',
};

const Map<String, dynamic> _extractionAnswer = {
  'evidence': 'Sarah is asking whether the launch date holds.',
  'topics': ['launch date'],
  'people': ['Sarah Chen'],
  'organizations': ['Northline'],
  'project': 'Website redesign',
  'intent': 'request',
  'importance': 'high',
};

const Map<String, dynamic> _needsYouAnswer = {
  'evidence': 'Sarah asks the owner to confirm the date.',
  'needs_you': true,
  'confidence': 'high',
};

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One fresh inbound message, exactly as a delta page leaves it: `pending`,
  /// with both follow-on items already queued. That is the state the race was
  /// lost in — the sync enqueues before triage has said anything.
  Future<void> seedFreshMessage({
    String from = 'sarah@example.com',
    String id = 'm1',
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'conv-1',
      'subject': 'Launch date',
      'state': 'needs_reply',
      'last_message_at': '2026-08-29T10:00:00Z',
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': from,
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Can we still ship on Thursday?',
    });
    await store.enqueueWork('extract', 'email', id);
    await store.enqueueWork('needs_you', 'email', id);
  }

  Future<String?> statusOf(String kind, String id) async =>
      (await db.customSelect(
        'SELECT status FROM work_items '
        'WHERE task_kind = ? AND source = ? AND entity_id = ?',
        variables: [Variable(kind), const Variable('email'), Variable(id)],
      ).getSingle())
          .data['status'] as String?;

  Future<int> storylineRows() async =>
      (await db.customSelect(
        "SELECT COUNT(*) AS n FROM work_items WHERE task_kind = 'storyline'",
      ).getSingle())
          .data['n'] as int;

  Future<Object?> embeddingOf(String key) async {
    final rows = await db.customSelect(
      'SELECT embedding FROM conversation_ai '
      'WHERE source = ? AND conversation_key = ?',
      variables: [const Variable('email'), Variable(key)],
    ).get();
    return rows.isEmpty ? null : rows.single.data['embedding'];
  }

  /// The two drains as the app builds them: one store, one gate, the queue's
  /// `onDrained` pumping the worker. Returned rather than held in fields so a
  /// test can pump either one first, which is the whole subject.
  ({TriageQueue triage, AiWorker worker, FakeLlm llm, FakeEmbeddings embed})
      pipeline({Map<String, Map<String, dynamic>>? answers}) {
    final gate = DrainGate();
    final llm = FakeLlm(answers ??
        const {
          'triage': _triageAnswer,
          'extraction': _extractionAnswer,
          'needs_you': _needsYouAnswer,
        });
    final embed = FakeEmbeddings();
    final worker = AiWorker(
      store,
      gate: gate,
      handlers: [
        NeedsYouHandler(store, llm),
        ExtractHandler(store, llm, embed.client),
      ],
    );
    addTearDown(worker.dispose);
    final triage = TriageQueue(
      store,
      llm,
      gate: gate,
      // No `ensureBody`: there is no Graph here, and the seeded row already
      // carries the body a detail fetch would have written.
      onDrained: () => worker.pump(),
    );
    addTearDown(triage.dispose);
    return (triage: triage, worker: worker, llm: llm, embed: embed);
  }

  test('the worker pumped first leaves an untriaged message alone', () async {
    await seedFreshMessage();
    final p = pipeline();

    await p.worker.pump();

    // Pending, not done: the items were never claimed, so the next drain —
    // the one `onDrained` fires — still has them to take.
    expect(await statusOf('extract', 'm1'), 'pending');
    expect(await statusOf('needs_you', 'm1'), 'pending');
    expect(p.llm.calls, isEmpty, reason: 'no model was asked anything');
    expect(await store.getExtraction('email', 'm1'), isNull);
    expect(p.embed.inputs, isEmpty);
    expect(await embeddingOf('conv-1'), isNull);
    expect(await storylineRows(), 0,
        reason: 'no embedding changed, so no thread was queued for filing');
  });

  test('a gated message is closed by the worker triage woke, unextracted',
      () async {
    await seedFreshMessage(from: 'noreply@example.com');
    final p = pipeline();

    // The worker goes first and finds nothing to do, exactly as it does in
    // the app when it wins the gate.
    await p.worker.pump();
    await p.triage.pump();
    await pumpEventQueue();

    final row = (await store.getMessageRow('email', 'm1'))!;
    expect(row['triage_status'], 'skipped');
    expect(row['gate_reason'], 'no_reply');

    // Closed by the worker the drain woke, not left pending: the handlers
    // honour the gate and write the items `done` with a skipped note.
    expect(await statusOf('extract', 'm1'), 'done');
    expect(await statusOf('needs_you', 'm1'), 'done');

    // And the point of the whole round: a newsletter costs no model call, no
    // extraction, no embedding and no storyline pass.
    expect(p.llm.calls, isEmpty);
    expect(await store.getExtraction('email', 'm1'), isNull);
    expect(p.embed.inputs, isEmpty);
    expect(await embeddingOf('conv-1'), isNull);
    expect(await storylineRows(), 0);
  });

  test('a kept message is extracted exactly once, and only after triage',
      () async {
    await seedFreshMessage();
    final p = pipeline();

    await p.worker.pump();
    // Nothing yet — pinned here so the assertion below is about ORDER rather
    // than about the end state, which two drains could reach either way.
    expect(await store.getExtraction('email', 'm1'), isNull);

    await p.triage.pump();
    await pumpEventQueue();

    expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
        'triaged');
    expect(await store.getExtraction('email', 'm1'), isNotNull);
    expect(await statusOf('extract', 'm1'), 'done');
    expect(await statusOf('needs_you', 'm1'), 'done');

    // Triage first, and exactly one extraction: a second claim would mean the
    // item was handed out twice.
    expect(p.llm.calls.first, 'triage');
    expect(p.llm.calls.where((c) => c == 'triage').length, 1);
    expect(p.llm.calls.where((c) => c == 'extraction').length, 1);
    expect(p.llm.calls, contains('needs_you'));

    // The fan-out extraction owns: the thread is embedded and queued for
    // filing, which is what must not happen for gated mail.
    expect(await embeddingOf('conv-1'), isNotNull);
    expect(await storylineRows(), 1);
  });

  test('a drain with nothing pending does not wake the worker', () async {
    // No message at all, so nothing was written and there is nothing for the
    // worker to collect. A knock here would be a drain per poll for a mailbox
    // that has not moved.
    var pumps = 0;
    final gate = DrainGate();
    final llm = FakeLlm(const {'triage': _triageAnswer});
    final triage = TriageQueue(
      store,
      llm,
      gate: gate,
      onDrained: () async => pumps++,
    );
    addTearDown(triage.dispose);

    await triage.pump();

    expect(pumps, 0);
    expect(llm.calls, isEmpty);
  });

  test('the two drains share one gate, so neither runs inside the other',
      () async {
    // `onDrained` is called AFTER `DrainGate.run` returns, on purpose: the
    // worker's own pump queues on the same gate, and a call from inside would
    // wait forever on a gate the caller is holding. The proof is that this
    // completes at all.
    await seedFreshMessage();
    final p = pipeline();

    await expectLater(p.triage.pump(), completes);
    await pumpEventQueue();

    expect(await statusOf('extract', 'm1'), 'done');
  });
}
