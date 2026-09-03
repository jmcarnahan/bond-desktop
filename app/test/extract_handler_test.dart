import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// An [LlmClient] that answers from a script and never opens a socket.
class FakeLlm extends LlmClient {
  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    temperatures.add(temperature);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// An [EmbeddingsClient] over a scripted socket. [vector] null means the
/// server is down.
class FakeEmbeddings {
  final List<String> inputs = [];
  final List<double>? vector;

  FakeEmbeddings({this.vector = const [0.6, 0.8]});

  /// One extraction now embeds TWICE, into two corpora that must never be
  /// compared: the thread's clustering card, and the message's own search
  /// card. Every count below is over one of them, because a bare total would
  /// pass whichever of the two calls actually happened.
  List<String> get clusteringInputs => [
        for (final input in inputs)
          if (input.startsWith(EmbeddingsClient.clusteringPrefix)) input,
      ];

  List<String> get documentInputs => [
        for (final input in inputs)
          if (input.startsWith(EmbeddingsClient.documentPrefix)) input,
      ];

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          inputs.add(body['input'] as String);
          final v = vector;
          if (v == null) return http.Response('down', 503);
          return http.Response(
            jsonEncode({
              'data': [
                {'embedding': v}
              ]
            }),
            200,
          );
        }),
      );
}

Map<String, dynamic> answer({
  String evidence = 'Jordan is asking whether the launch date holds.',
  List<String> topics = const ['launch date'],
  String project = 'Website redesign',
  String intent = 'request',
  String importance = 'high',
}) =>
    {
      'evidence': evidence,
      'topics': topics,
      'people': const ['Sarah Chen'],
      'organizations': const ['Northline'],
      'project': project,
      'intent': intent,
      'importance': importance,
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seedMessage({
    String id = 'm1',
    String conversationKey = 'conv-1',
    String? summary,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Can we still ship on Thursday?',
    });
    if (summary != null) {
      await store.writeTriage(
        'email',
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: 'high',
          category: 'work',
          summary: summary,
          needsAction: true,
          actionItems: const ['Ship on Thursday'],
        ),
      );
    }
  }

  Future<void> seedConversation({String key = 'conv-1'}) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Launch date',
      'participants_json': jsonEncode([
        {'name': 'Sarah Chen', 'email': 'sarah@x.com'},
        {'name': null, 'email': 'billing@vendor.example.com'},
      ]),
      'state': 'needs_reply',
      'last_message_at': '2026-08-29T10:00:00Z',
    });
  }

  Future<void> runOne(ExtractHandler handler, {String id = 'm1'}) =>
      handler.run({'task_kind': 'extract', 'source': 'email', 'entity_id': id});

  group('extraction', () {
    test('a message triage gated after enqueue costs no model call', () async {
      // The race this pins: extraction is enqueued at sync time while the
      // message is still `pending`; triage then gates it. The handler must
      // honour the verdict, or every newsletter gets an embedding and the
      // sweep clusters them into junk storyline suggestions.
      await seedMessage();
      await seedConversation();
      await store.writeTriage('email', 'm1',
          status: 'skipped', gateReason: 'newsletter');
      final llm = FakeLlm([answer()]);
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, llm, embeddings.client));

      expect(llm.userMessages, isEmpty, reason: 'gated mail is not extracted');
      expect(await store.getExtraction('email', 'm1'), isNull);
      expect(embeddings.inputs, isEmpty);
    });

    test('a teams row is skipped-by-birth, not gated — it still extracts',
        () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 't1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'from_address': 'teams:u-1',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Legal wants a look at the DPA.',
        'triage_status': 'skipped',
        'gate_reason': 'teams_source',
      });
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'Acme renewal',
        'state': 'needs_reply',
        'last_message_at': '2026-08-29T10:00:00Z',
      });
      final llm = FakeLlm([answer()]);

      await ExtractHandler(store, llm, FakeEmbeddings().client).run(
        {'task_kind': 'extract', 'source': 'teams', 'entity_id': 't1'},
      );

      expect(llm.userMessages, hasLength(1));
      expect(await store.getExtraction('teams', 't1'), isNotNull);
    });

    test('stores the model answer as JSON', () async {
      await seedMessage();
      final llm = FakeLlm([answer()]);
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, llm, embeddings.client));

      final stored =
          jsonDecode((await store.getExtraction('email', 'm1'))!) as Map<String, dynamic>;
      expect(stored['evidence'], 'Jordan is asking whether the launch date holds.');
      expect(stored['topics'], ['launch date']);
      expect(stored['intent'], 'request');
      expect(stored['importance'], 'high');
    });

    test('runs at temperature 0 — the same email twice is the same facts',
        () async {
      await seedMessage();
      final llm = FakeLlm([answer()]);

      await runOne(ExtractHandler(store, llm, FakeEmbeddings().client));

      expect(llm.temperatures, [0.0]);
    });

    test('a message that vanished is done, not failed', () async {
      final llm = FakeLlm([answer()]);

      await runOne(ExtractHandler(store, llm, FakeEmbeddings().client));

      expect(llm.userMessages, isEmpty);
      expect(await store.getExtraction('email', 'm1'), isNull);
    });

    test('a model failure surfaces, so the worker can retry it', () async {
      await seedMessage();
      final llm = FakeLlm([const LlmFormatException('not json')]);

      await expectLater(
        runOne(ExtractHandler(store, llm, FakeEmbeddings().client)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getExtraction('email', 'm1'), isNull);
    });
  });

  group('conversation card', () {
    test('embeds the card and records the hash and the model', () async {
      await seedConversation();
      await seedMessage(summary: 'Sarah needs the lock extended.');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(
        embeddings.clusteringInputs.single,
        '${EmbeddingsClient.clusteringPrefix}'
        'Launch date | Sarah Chen, billing@vendor.example.com | launch date | '
        'Sarah needs the lock extended.',
      );
      final row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embedding'], encodeEmbedding(const [0.6, 0.8]));
      expect(row['embed_model'], EmbeddingsClient.modelTag);
      expect(row['embedded_hash'], isNotNull);
      expect(
        decodeEmbedding(row['embedding'] as Uint8List),
        [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)],
      );
    });

    test('an unchanged card is not embedded twice', () async {
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        embeddings.client,
      );

      await runOne(handler);
      await runOne(handler);

      // The whole reason a hash is stored: the tenth message of a thread must
      // not spend an embedding call to arrive at the same vector.
      expect(embeddings.clusteringInputs.length, 1);
      // The per-message card has its own hash, and the same guard.
      expect(embeddings.documentInputs.length, 1);
    });

    test('a changed card is re-embedded', () async {
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings();
      final handler = ExtractHandler(
        store,
        FakeLlm([
          answer(),
          answer(topics: const ['homepage copy', 'launch date']),
        ]),
        embeddings.client,
      );

      await runOne(handler);
      await runOne(handler);

      expect(embeddings.clusteringInputs.length, 2);
      expect(
        embeddings.clusteringInputs.last,
        contains('homepage copy, launch date'),
      );
    });

    test('an embedding server that is down does not cost the extraction',
        () async {
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings(vector: null);

      // Not a throw: the worker would mark the item failed and re-run the
      // model call that already succeeded, to retry an optimisation.
      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(await store.getExtraction('email', 'm1'), isNotNull);
      final row = await store.getConversationAi('email', 'conv-1');
      // No row, no hash: nothing was written, so the next pass tries again.
      expect(row?['embedding'], isNull);
      expect(row?['embedded_hash'], isNull);
    });

    test('a message with no conversation row embeds nothing', () async {
      await seedMessage(conversationKey: 'orphan');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(await store.getExtraction('email', 'm1'), isNotNull);
      expect(embeddings.clusteringInputs, isEmpty);
      expect(await store.getConversationAi('email', 'orphan'), isNull);
    });

    test('an embedding write leaves a bucket a later phase wrote alone',
        () async {
      await seedConversation();
      await seedMessage();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer(), answer(topics: const ['homepage copy'])]),
        FakeEmbeddings().client,
      );
      await runOne(handler);
      await db.customUpdate(
        "UPDATE conversation_ai SET bucket = 'now' "
        'WHERE source = ? AND conversation_key = ?',
        variables: [const Variable('email'), const Variable('conv-1')],
      );

      await runOne(handler);

      expect(
        (await store.getConversationAi('email', 'conv-1'))!['bucket'],
        'now',
      );
    });
  });

  group('message vector at extraction time', () {
    Future<Map<String, Object?>?> vectorRow(String id) async {
      final rows = await db
          .customSelect(
            'SELECT * FROM message_vectors WHERE source_message_id = ?',
            variables: [Variable<String>(id)],
          )
          .get();
      return rows.isEmpty ? null : Map<String, Object?>.from(rows.first.data);
    }

    test('a successful extraction also makes the message searchable',
        () async {
      // The fast path: by the time a message has been extracted it is also
      // findable, without the `embed_message` queue having had to drain.
      await seedConversation();
      await seedMessage(summary: 'Sarah needs the lock extended.');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      final row = (await vectorRow('m1'))!;
      expect(row['embed_model'], EmbeddingsClient.documentModelTag);
      expect(row['received_at'], '2026-08-29T10:00:00Z');
      expect(row['embedded_hash'], isNotNull);
      // The message's OWN text, under the document prefix — not the thread's
      // clustering card.
      expect(
        embeddings.documentInputs.single,
        '${EmbeddingsClient.documentPrefix}'
        'Launch date | From: Sarah <sarah@x.com> | '
        'Sarah needs the lock extended. | Can we still ship on Thursday?',
      );
    });

    test('an orphan thread still gets its message vector', () async {
      // The conversation card needs a conversation row; the message card does
      // not. A thread whose conversation never landed must still be findable.
      await seedMessage(conversationKey: 'orphan');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(await vectorRow('m1'), isNotNull);
    });

    test('an embedding server that is down does not cost the extraction',
        () async {
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings(vector: null);

      // Not a throw, for `_refreshCard`'s reason: the facts are already
      // stored, and failing the item would re-run the model call that
      // succeeded in order to retry an optimisation.
      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(await store.getExtraction('email', 'm1'), isNotNull);
      expect(await vectorRow('m1'), isNull);
    });

    test('and through the worker, the item is still done', () async {
      await seedConversation();
      await seedMessage();
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        store,
        handlers: [
          ExtractHandler(
            store,
            FakeLlm([answer()]),
            FakeEmbeddings(vector: null).client,
          )
        ],
      );

      await worker.pump();

      // `done`, and not `pending`: an unreachable EMBEDDING server must never
      // park the extraction queue, which talks to a different server.
      expect(await store.workCounts('extract'), {'done': 1});
      expect(await store.getExtraction('email', 'm1'), isNotNull);
      expect(await vectorRow('m1'), isNull);
    });
  });

  group('bucket at extraction time', () {
    /// The same thread as [seedConversation], but with `last_inbound_at`
    /// stamped — the handler only files a thread on its NEWEST inbound
    /// message, and that is the column it checks against.
    Future<void> seedCurrentConversation({
      String state = 'waiting',
      String lastInboundAt = '2026-08-29T10:00:00Z',
    }) async {
      await store.upsertConversation({
        'conversation_key': 'conv-1',
        'subject': 'Launch date',
        'state': state,
        'last_message_at': lastInboundAt,
        'last_inbound_at': lastInboundAt,
      });
    }

    Future<String?> bucketOf() async =>
        (await store.getConversationAi('email', 'conv-1'))?['bucket'] as String?;
    Future<String?> reasonOf() async =>
        (await store.getConversationAi('email', 'conv-1'))?['bucket_reason']
            as String?;

    ExtractHandler handlerFor(Map<String, dynamic> result) =>
        ExtractHandler(store, FakeLlm([result]), FakeEmbeddings().client);

    test('a low-value fyi is deferred as the fact lands', () async {
      // Without this the row would appear in the inbox, sit there while the
      // queue drained, and then jump to Later under the reader's eyes.
      await seedCurrentConversation();
      await seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), 'later');
      expect(await reasonOf(), 'low_value');
    });

    test('a request is not', () async {
      await seedCurrentConversation();
      await seedMessage();

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(await bucketOf(), isNull);
    });

    test('a thread awaiting the LO is never deferred', () async {
      await seedCurrentConversation(state: 'needs_reply');
      await seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), isNull);
    });

    test('a later sender rule defers whatever the model said', () async {
      await seedCurrentConversation();
      await seedMessage();
      await store.setSenderPref('sarah@x.com', 'later');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(await bucketOf(), 'later');
      expect(await reasonOf(), 'sender_pref');
    });

    test('a keep sender rule beats a low-value verdict', () async {
      await seedCurrentConversation();
      await seedMessage();
      await store.setSenderPref('sarah@x.com', 'keep');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), isNull);
    });

    test('it never overrules a bucket a person asked for', () async {
      await seedCurrentConversation();
      await seedMessage();
      await store.setConversationBucket('email', 'conv-1',
          bucket: 'later', reason: 'user');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(await bucketOf(), 'later');
      expect(await reasonOf(), 'user');
    });

    test('nor an exemption a person asked for', () async {
      await seedCurrentConversation();
      await seedMessage();
      await store.setConversationBucket('email', 'conv-1',
          bucket: null, reason: 'user');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), isNull);
      expect(await reasonOf(), 'user');
    });

    test('it withdraws its own earlier guess when the verdict changes',
        () async {
      await seedCurrentConversation();
      await seedMessage();
      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));
      expect(await bucketOf(), 'later');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(await bucketOf(), isNull);
      expect(await reasonOf(), isNull);
    });

    test('an older message does not get to file the thread', () async {
      // The queue drains newest-first, but a backlog can still hand this
      // handler a month-old message. Letting it decide would file the thread
      // on what its conversation stopped being about.
      await seedCurrentConversation(lastInboundAt: '2026-09-01T10:00:00Z');
      await seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), isNull);
      // The extraction itself still landed — only the filing was declined.
      expect(await store.getExtraction('email', 'm1'), isNotNull);
    });

    test('a message with no conversation row files nothing', () async {
      await seedMessage(conversationKey: 'orphan');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await store.getConversationAi('email', 'orphan'), isNull);
    });
  });

  group('buildConversationCard', () {
    test('is four segments, empty ones included', () {
      expect(
        buildConversationCard(
          subject: 'Launch date',
          participants: const ['Sarah', 'Tom'],
          topics: const ['launch', 'homepage copy'],
          summary: 'Shipping Thursday.',
        ),
        'Launch date | Sarah, Tom | launch, homepage copy | Shipping Thursday.',
      );
      // Fixed shape, so the same thread always produces the same card — which
      // is what makes the hash a usable "has anything changed" test.
      expect(
        buildConversationCard(
          subject: null,
          participants: const [],
          topics: const [],
          summary: null,
        ),
        ' |  |  | ',
      );
    });
  });

  group('cardHash', () {
    test('is stable for the same text and differs for different text', () {
      expect(cardHash('a card'), cardHash('a card'));
      expect(cardHash('a card'), isNot(cardHash('a card ')));
      expect(cardHash('a card'), isNot(cardHash('another card')));
    });

    test('carries the length, then sixteen hex digits', () {
      expect(cardHash(''), matches(RegExp(r'^0-[0-9a-f]{16}$')));
      expect(cardHash('abc'), startsWith('3-'));
    });

    test('handles text outside ASCII', () {
      expect(cardHash('café — naïve'), isNot(cardHash('cafe - naive')));
    });
  });

  group('through the worker', () {
    test('a queued message is extracted, embedded and marked done', () async {
      await seedConversation();
      await seedMessage();
      await store.enqueueWork('extract', 'email', 'm1');
      final embeddings = FakeEmbeddings();
      final worker = AiWorker(
        store,
        handlers: [ExtractHandler(store, FakeLlm([answer()]), embeddings.client)],
      );

      await worker.pump();

      expect(await store.workCounts('extract'), {'done': 1});
      expect(await store.getExtraction('email', 'm1'), isNotNull);
      expect(embeddings.clusteringInputs.length, 1);
      expect(embeddings.documentInputs.length, 1);
    });

    test('a model server that is down leaves the item queued', () async {
      await seedMessage();
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        store,
        handlers: [
          ExtractHandler(
            store,
            FakeLlm([const LlmUnavailableException('not reachable')]),
            FakeEmbeddings().client,
          )
        ],
      );

      await worker.pump();

      expect(await store.workCounts('extract'), {'pending': 1});
      expect(await store.getExtraction('email', 'm1'), isNull);
    });
  });
}
