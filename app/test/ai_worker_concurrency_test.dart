import 'dart:async';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'fixtures/test_db.dart';

/// What the worker does with more than one item of a kind at the server at
/// once, and what a park means now that the kinds do not share a server.
///
/// `ai_worker_test.dart` covers the drain's decisions with a serial stand-in
/// handler; this file uses the real [ExtractHandler] — the only handler that
/// raises [WorkHandler.concurrency] — so the number it declares is exercised
/// rather than asserted about in isolation.

/// An [LlmClient] that answers from a script, never opens a socket, and counts
/// how many answers it is producing at once.
class FakeLlm extends LlmClient {
  /// Consumed in order. A `Map` is returned, an `Exception` is thrown, and a
  /// `Future` is awaited first and then treated as whichever of those it
  /// yields — which is the only way to hold one request open while the drain
  /// gets on with the others. The last entry repeats once the script runs out.
  final List<Object> script;

  final List<String> userMessages = [];
  int inFlight = 0;
  int maxInFlight = 0;

  FakeLlm(List<Object> script)
      : script = [...script],
        super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      // A real call suspends. Without a suspension here every item would run
      // to completion before the next one launched, and the ceiling this file
      // measures would always read 1.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      var step = script.length > 1 ? script.removeAt(0) : script.first;
      if (step is Future<Object>) step = await step;
      if (step is Exception) throw step;
      return Map<String, dynamic>.from(step as Map);
    } finally {
      inFlight--;
    }
  }
}

/// Stands in for [DraftHandler]: a second kind, on a second server, whose own
/// model is answering perfectly well while extraction's is not.
class DraftStub extends WorkHandler {
  final List<String> seen = [];

  @override
  String get kind => 'draft';

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Map<String, dynamic> extraction() => {
      'evidence': 'Sarah is asking to extend the rate lock.',
      'topics': const ['rate lock'],
      'people': const ['Sarah Chen'],
      'organizations': const ['Harborline'],
      'project': 'Willow St purchase',
      'intent': 'request',
      'importance': 'high',
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// The embedding server, absent. Every message below is seeded without a
  /// conversation row, so the card step returns before it would dial anything
  /// — this client exists only so the handler can be constructed.
  EmbeddingsClient noEmbeddings() => EmbeddingsClient(
        baseUrl: 'http://127.0.0.1:1/never-dialled',
        httpClient: MockClient((_) async => http.Response('down', 503)),
      );

  /// One message plus its queued extraction. No conversation row on purpose:
  /// what this file is about is the drain, and a thread would drag the fold-up
  /// and the embedding in with it.
  Future<void> seedQueued(String id) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'orphan-$id',
      'direction': 'inbound',
      // Per-id, so a prompt can be traced back to the message that produced
      // it — which is how the exactly-once assertion below is made.
      'subject': 'Re: Rate lock $id',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Can we extend the lock through Friday?',
    });
    await store.enqueueWork('extract', 'email', id);
  }

  Future<List<Map<String, Object?>>> workRows(String kind) async => [
        for (final row in await db
            .customSelect(
              'SELECT * FROM work_items WHERE task_kind = ?',
              variables: [Variable(kind)],
            )
            .get())
          Map<String, Object?>.from(row.data),
      ];

  ExtractHandler extractWith(FakeLlm llm) =>
      ExtractHandler(store, llm, noEmbeddings());

  group('per-handler concurrency', () {
    test('extraction runs three at a time and finishes all of them', () async {
      for (var i = 0; i < 6; i++) {
        await seedQueued('m$i');
      }
      final llm = FakeLlm([extraction()]);

      await AiWorker(store, handlers: [extractWith(llm)]).pump();

      // Three is what ExtractHandler declares, and this is where that number
      // stops being a comment: six independent messages keep the fast server
      // batching instead of idling between them.
      expect(llm.maxInFlight, 3);
      expect(llm.userMessages.length, 6);
      expect(await store.workCounts('extract'), {'done': 6});
    });

    test('two drains over one backlog take every item exactly once', () async {
      for (var i = 0; i < 9; i++) {
        await seedQueued('m$i');
      }
      // Two workers rather than two pumps of one: `_draining` guards a worker
      // against itself, and each carries its own [DrainGate], so these drains
      // genuinely overlap. It is the case the atomic claim exists for —
      // choosing an item and writing its `processing` are one statement, so
      // whichever claim lands second cannot be handed a row the first took.
      final first = FakeLlm([extraction()]);
      final second = FakeLlm([extraction()]);

      await Future.wait([
        AiWorker(store, handlers: [extractWith(first)]).pump(),
        AiWorker(store, handlers: [extractWith(second)]).pump(),
      ]);

      final asked = [...first.userMessages, ...second.userMessages];
      expect(asked.length, 9);
      for (var i = 0; i < 9; i++) {
        expect(
          asked.where((user) => user.contains('Re: Rate lock m$i')).length,
          1,
          reason: 'm$i',
        );
      }
      expect(await store.workCounts('extract'), {'done': 9});
    });

    test('a handler that declares nothing is still serial', () async {
      for (final id in ['d1', 'd2', 'd3']) {
        await store.enqueueWork('draft', 'email', id);
      }
      final draft = DraftStub();

      await AiWorker(store, handlers: [draft]).pump();

      // The default matters as much as the override: a draft is on-demand
      // prose on the 27B, and three of those at once would make the one the
      // user is waiting on slower, not faster.
      expect(draft.concurrency, 1);
      expect(await store.workCounts('draft'), {'done': 3});
    });
  });

  group('parking, per kind and per drain', () {
    test('a downed server parks its kind; the next kind still drains',
        () async {
      for (var i = 0; i < 5; i++) {
        await seedQueued('m$i');
      }
      await store.enqueueWork('draft', 'email', 'd1');
      final llm = FakeLlm([const LlmUnavailableException('not reachable')]);
      final draft = DraftStub();

      await AiWorker(store, handlers: [extractWith(llm), draft]).pump();

      // Three went out together and all three found the same dead server;
      // nothing was wrong with any of the five, so none spends an attempt.
      expect(await store.workCounts('extract'), {'pending': 5});
      for (final row in await workRows('extract')) {
        expect(row['attempts'], 0, reason: row['entity_id'] as String?);
      }
      // And the draft server is a DIFFERENT server. "Extraction's llama-server
      // is not running" is no evidence at all about the 27B's.
      expect(draft.seen, ['d1']);
      expect(await store.workCounts('draft'), {'done': 1});
    });

    test('a dead session parks the whole drain, later kinds included',
        () async {
      for (var i = 0; i < 5; i++) {
        await seedQueued('m$i');
      }
      await store.enqueueWork('draft', 'email', 'd1');
      final llm = FakeLlm([const NotSignedIn()]);
      final draft = DraftStub();

      await AiWorker(store, handlers: [extractWith(llm), draft]).pump();

      // The session is what every kind's Graph-dependent work runs on, so
      // there is no server left that could answer anything usefully.
      expect(await store.workCounts('extract'), {'pending': 5});
      expect(draft.seen, isEmpty);
      expect(await store.workCounts('draft'), {'pending': 1});
    });

    test('missing consent parks the whole drain the same way', () async {
      await seedQueued('m0');
      await store.enqueueWork('draft', 'email', 'd1');
      final llm = FakeLlm([const ReconsentRequired()]);
      final draft = DraftStub();

      await AiWorker(store, handlers: [extractWith(llm), draft]).pump();

      expect(await store.workCounts('extract'), {'pending': 1});
      expect(draft.seen, isEmpty);
    });

    test('the items already in flight when a kind parks keep their results',
        () async {
      for (var i = 0; i < 6; i++) {
        await seedQueued('m$i');
      }
      // The first and third of the batch are held open until the second has
      // found the server gone, so the park lands on siblings that are still
      // mid-request — the state a serial drain could never be in.
      final held = Completer<Object>();
      final llm = FakeLlm([
        held.future,
        const LlmUnavailableException('not reachable'),
        held.future,
      ]);

      final drain = AiWorker(store, handlers: [extractWith(llm)]).pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      held.complete(extraction());
      await drain;

      // Three requests and no more: the park stopped the launcher, so the
      // remaining three items were never claimed. The two answers were paid
      // for either way and are kept rather than thrown away with the park.
      expect(llm.userMessages.length, 3);
      expect(await store.workCounts('extract'), {'done': 2, 'pending': 4});
      for (final row in await workRows('extract')) {
        if (row['status'] != 'pending') continue;
        expect(row['attempts'], 0, reason: row['entity_id'] as String?);
      }
    });
  });

  group('failure policy under concurrency', () {
    test('a schema 400 marks one item and the rest of the batch carries on',
        () async {
      for (var i = 0; i < 4; i++) {
        await seedQueued('m$i');
      }
      final llm = FakeLlm([
        const LlmException('JSON schema conversion failed', 400),
        extraction(),
      ]);

      await AiWorker(store, handlers: [extractWith(llm)]).pump();

      // Unchanged by concurrency: a 400 is this app's schema being wrong, so
      // it is fatal on the first attempt — and it is about that ONE request,
      // so the three beside it finish normally.
      expect(await store.workCounts('extract'), {'error': 1, 'done': 3});
      final failed = (await workRows('extract'))
          .where((r) => r['status'] == 'error')
          .single;
      expect(failed['attempts'], 1);
      expect(failed['error'], contains('JSON schema conversion failed'));
    });

    test('any other failure is still retried once, then left as an error',
        () async {
      await seedQueued('m0');
      final llm = FakeLlm([const LlmFormatException('not json')]);

      await AiWorker(store, handlers: [extractWith(llm)]).pump();

      expect(llm.userMessages.length, 2);
      final row = (await workRows('extract')).single;
      expect(row['status'], 'error');
      expect(row['attempts'], 2);
    });
  });

  test('resetInterrupted still returns claimed items to the queue', () async {
    for (var i = 0; i < 4; i++) {
      await seedQueued('m$i');
      await store.writeWork('extract', 'email', 'm$i', status: 'processing');
    }
    final llm = FakeLlm([extraction()]);
    final worker = AiWorker(store, handlers: [extractWith(llm)]);

    // A crash mid-batch now leaves up to three rows claimed rather than one,
    // which is exactly the case this startup sweep exists for.
    expect(await store.nextPendingWork('extract'), isNull);
    await worker.resetInterrupted();
    expect(await store.nextPendingWork('extract'), isNotNull);

    await worker.pump();

    expect(await store.workCounts('extract'), {'done': 4});
  });
}
