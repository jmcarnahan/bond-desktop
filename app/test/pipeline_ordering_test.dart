import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/scripted_llm.dart';
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
  ({TriageQueue triage, AiWorker worker, ScriptedLlm llm, FakeEmbeddings embed})
      pipeline({Map<String, Map<String, dynamic>>? answers}) {
    final gate = DrainGate();
    // The order is the assertion in most of this file, so the reading is
    // `schemas` — `triage`, `extraction`, `needs_you` — rather than a call
    // count, which cannot tell a drain that ran twice from one that ran
    // backwards.
    final llm = ScriptedLlm(
      answers: answers ??
          const {
            'triage': _triageAnswer,
            'extraction': _extractionAnswer,
            'needs_you': _needsYouAnswer,
          },
    );
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
      onDrained: (triaged) => worker.pump(first: triaged),
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
    expect(p.llm.schemas, isEmpty, reason: 'no model was asked anything');
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
    expect(p.llm.schemas, isEmpty);
    expect(await store.getExtraction('email', 'm1'), isNull);
    expect(p.embed.inputs, isEmpty);
    expect(await embeddingOf('conv-1'), isNull);
    expect(await storylineRows(), 0);
  });

  test('a skipped ref is closed by the priority pass, with no model call',
      () async {
    // A gate is a verdict, so a gated message rides `onDrained` into the
    // priority lane beside the kept ones. What the pass does with it is close
    // its rows: the handlers honour the gate, and the whole point of gating
    // is that the 4B is never dialled for a newsletter.
    await seedFreshMessage(from: 'noreply@example.com');
    final p = pipeline();

    await p.triage.pump();
    await pumpEventQueue();

    expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
        'skipped');
    expect(await statusOf('extract', 'm1'), 'done');
    expect(await statusOf('needs_you', 'm1'), 'done');
    expect(p.llm.schemas, isEmpty);
    expect(p.embed.inputs, isEmpty);
    expect(await store.getExtraction('email', 'm1'), isNull);
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
    expect(p.llm.schemas.first, 'triage');
    expect(p.llm.schemas.where((c) => c == 'triage').length, 1);
    expect(p.llm.schemas.where((c) => c == 'extraction').length, 1);
    expect(p.llm.schemas, contains('needs_you'));

    // The fan-out extraction owns: the thread is embedded and queued for
    // filing, which is what must not happen for gated mail.
    expect(await embeddingOf('conv-1'), isNotNull);
    expect(await storylineRows(), 1);
  });

  test('a priority ref is refused before triage and taken after it', () async {
    await seedFreshMessage();
    final p = pipeline();

    // The caller names the message as urgent while it is still untriaged,
    // which is the one way a priority claim could become a hole in the
    // invariant. `claimWorkItem` carries the same guard the walk's claim
    // carries, so the pass finds nothing to take.
    await p.worker.pump(first: const [(source: 'email', id: 'm1')]);

    expect(await statusOf('extract', 'm1'), 'pending');
    expect(await statusOf('needs_you', 'm1'), 'pending');
    expect(p.llm.schemas, isEmpty);
    expect(await store.getExtraction('email', 'm1'), isNull);

    // Triage speaks, and the pairs it wrote ride back to the worker through
    // `onDrained` as the priority refs of the next pass.
    await p.triage.pump();
    await pumpEventQueue();

    expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
        'triaged');
    expect(await statusOf('extract', 'm1'), 'done');
    expect(await statusOf('needs_you', 'm1'), 'done');
    expect(p.llm.schemas.first, 'triage');
    expect(p.llm.schemas.where((c) => c == 'extraction').length, 1);
    expect(p.llm.schemas.where((c) => c == 'needs_you').length, 1);
    expect(await store.getExtraction('email', 'm1'), isNotNull);
  });

  test('a priority claim does not hand a backlog item out twice', () async {
    // Two messages, both already triaged, so both are claimable — and the
    // newer one is named as urgent. Whichever of the priority pass and the
    // handler walk reaches a row second finds nothing pending to match.
    await seedFreshMessage(id: 'm1');
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm2',
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-29T11:00:00Z',
      'body_text': 'And the copy deck?',
    });
    await store.enqueueWork('extract', 'email', 'm2');
    await store.enqueueWork('needs_you', 'email', 'm2');
    for (final id in ['m1', 'm2']) {
      await store.writeTriage('email', id, status: 'triaged');
    }

    final p = pipeline();
    await p.worker.pump(first: const [(source: 'email', id: 'm2')]);

    for (final id in ['m1', 'm2']) {
      expect(await statusOf('extract', id), 'done');
      expect(await statusOf('needs_you', id), 'done');
    }
    // Two messages, two of each call: a row claimed by both paths would show
    // up here as a third.
    expect(p.llm.schemas.where((c) => c == 'extraction').length, 2);
    expect(p.llm.schemas.where((c) => c == 'needs_you').length, 2);
    expect(p.llm.schemas, isNot(contains('triage')));
  });

  test('a drain with nothing pending does not wake the worker', () async {
    // No message at all, so nothing was written and there is nothing for the
    // worker to collect. A knock here would be a drain per poll for a mailbox
    // that has not moved.
    var pumps = 0;
    final gate = DrainGate();
    final llm = ScriptedLlm(answers: const {'triage': _triageAnswer});
    final triage = TriageQueue(
      store,
      llm,
      gate: gate,
      onDrained: (_) async => pumps++,
    );
    addTearDown(triage.dispose);

    await triage.pump();

    expect(pumps, 0);
    expect(llm.schemas, isEmpty);
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
