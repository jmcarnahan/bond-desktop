import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

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
  String evidence = 'Sarah is asking to extend the rate lock.',
  List<String> topics = const ['rate lock'],
  String project = 'Willow St purchase',
  String intent = 'request',
  String importance = 'high',
}) =>
    {
      'evidence': evidence,
      'topics': topics,
      'people': const ['Sarah Chen'],
      'organizations': const ['Harborline'],
      'project': project,
      'intent': intent,
      'importance': importance,
    };

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedMessage({
    String id = 'm1',
    String conversationKey = 'conv-1',
    String? summary,
  }) {
    store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': 'Re: Rate lock',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Can we extend the lock through Friday?',
    });
    if (summary != null) {
      store.writeTriage(
        'email',
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: 'high',
          category: 'borrower',
          summary: summary,
          needsAction: true,
          actionItems: const ['Extend the lock'],
        ),
      );
    }
  }

  void seedConversation({String key = 'conv-1'}) {
    store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Rate lock',
      'participants_json': jsonEncode([
        {'name': 'Sarah Chen', 'email': 'sarah@x.com'},
        {'name': null, 'email': 'escrow@title.com'},
      ]),
      'state': 'needs_reply',
      'last_message_at': '2026-08-29T10:00:00Z',
    });
  }

  Future<void> runOne(ExtractHandler handler, {String id = 'm1'}) =>
      handler.run({'task_kind': 'extract', 'source': 'email', 'entity_id': id});

  group('extraction', () {
    test('stores the model answer as JSON', () async {
      seedMessage();
      final llm = FakeLlm([answer()]);
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, llm, embeddings.client));

      final stored =
          jsonDecode(store.getExtraction('email', 'm1')!) as Map<String, dynamic>;
      expect(stored['evidence'], 'Sarah is asking to extend the rate lock.');
      expect(stored['topics'], ['rate lock']);
      expect(stored['intent'], 'request');
      expect(stored['importance'], 'high');
    });

    test('runs at temperature 0 — the same email twice is the same facts',
        () async {
      seedMessage();
      final llm = FakeLlm([answer()]);

      await runOne(ExtractHandler(store, llm, FakeEmbeddings().client));

      expect(llm.temperatures, [0.0]);
    });

    test('a message that vanished is done, not failed', () async {
      final llm = FakeLlm([answer()]);

      await runOne(ExtractHandler(store, llm, FakeEmbeddings().client));

      expect(llm.userMessages, isEmpty);
      expect(store.getExtraction('email', 'm1'), isNull);
    });

    test('a model failure surfaces, so the worker can retry it', () async {
      seedMessage();
      final llm = FakeLlm([const LlmFormatException('not json')]);

      await expectLater(
        runOne(ExtractHandler(store, llm, FakeEmbeddings().client)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(store.getExtraction('email', 'm1'), isNull);
    });
  });

  group('conversation card', () {
    test('embeds the card and records the hash and the model', () async {
      seedConversation();
      seedMessage(summary: 'Sarah needs the lock extended.');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(
        embeddings.inputs.single,
        '${EmbeddingsClient.clusteringPrefix}'
        'Rate lock | Sarah Chen, escrow@title.com | rate lock | '
        'Sarah needs the lock extended.',
      );
      final row = store.getConversationAi('email', 'conv-1')!;
      expect(row['embedding'], encodeEmbedding(const [0.6, 0.8]));
      expect(row['embed_model'], EmbeddingsClient.modelTag);
      expect(row['embedded_hash'], isNotNull);
      expect(
        decodeEmbedding(row['embedding'] as Uint8List),
        [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)],
      );
    });

    test('an unchanged card is not embedded twice', () async {
      seedConversation();
      seedMessage();
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
      expect(embeddings.inputs.length, 1);
    });

    test('a changed card is re-embedded', () async {
      seedConversation();
      seedMessage();
      final embeddings = FakeEmbeddings();
      final handler = ExtractHandler(
        store,
        FakeLlm([
          answer(),
          answer(topics: const ['appraisal', 'closing date']),
        ]),
        embeddings.client,
      );

      await runOne(handler);
      await runOne(handler);

      expect(embeddings.inputs.length, 2);
      expect(embeddings.inputs.last, contains('appraisal, closing date'));
    });

    test('an embedding server that is down does not cost the extraction',
        () async {
      seedConversation();
      seedMessage();
      final embeddings = FakeEmbeddings(vector: null);

      // Not a throw: the worker would mark the item failed and re-run the
      // model call that already succeeded, to retry an optimisation.
      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(store.getExtraction('email', 'm1'), isNotNull);
      final row = store.getConversationAi('email', 'conv-1');
      // No row, no hash: nothing was written, so the next pass tries again.
      expect(row?['embedding'], isNull);
      expect(row?['embedded_hash'], isNull);
    });

    test('a message with no conversation row embeds nothing', () async {
      seedMessage(conversationKey: 'orphan');
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      expect(store.getExtraction('email', 'm1'), isNotNull);
      expect(embeddings.inputs, isEmpty);
      expect(store.getConversationAi('email', 'orphan'), isNull);
    });

    test('an embedding write leaves a bucket a later phase wrote alone',
        () async {
      seedConversation();
      seedMessage();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer(), answer(topics: const ['appraisal'])]),
        FakeEmbeddings().client,
      );
      await runOne(handler);
      db.execute(
        "UPDATE conversation_ai SET bucket = 'now' "
        'WHERE source = ? AND conversation_key = ?',
        ['email', 'conv-1'],
      );

      await runOne(handler);

      expect(store.getConversationAi('email', 'conv-1')!['bucket'], 'now');
    });
  });

  group('bucket at extraction time', () {
    /// The same thread as [seedConversation], but with `last_inbound_at`
    /// stamped — the handler only files a thread on its NEWEST inbound
    /// message, and that is the column it checks against.
    void seedCurrentConversation({
      String state = 'waiting',
      String lastInboundAt = '2026-08-29T10:00:00Z',
    }) {
      store.upsertConversation({
        'conversation_key': 'conv-1',
        'subject': 'Rate lock',
        'state': state,
        'last_message_at': lastInboundAt,
        'last_inbound_at': lastInboundAt,
      });
    }

    String? bucketOf() =>
        store.getConversationAi('email', 'conv-1')?['bucket'] as String?;
    String? reasonOf() =>
        store.getConversationAi('email', 'conv-1')?['bucket_reason'] as String?;

    ExtractHandler handlerFor(Map<String, dynamic> result) =>
        ExtractHandler(store, FakeLlm([result]), FakeEmbeddings().client);

    test('a low-value fyi is deferred as the fact lands', () async {
      // Without this the row would appear in the inbox, sit there while the
      // queue drained, and then jump to Later under the reader's eyes.
      seedCurrentConversation();
      seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(bucketOf(), 'later');
      expect(reasonOf(), 'low_value');
    });

    test('a request is not', () async {
      seedCurrentConversation();
      seedMessage();

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(bucketOf(), isNull);
    });

    test('a thread awaiting the LO is never deferred', () async {
      seedCurrentConversation(state: 'needs_reply');
      seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(bucketOf(), isNull);
    });

    test('a later sender rule defers whatever the model said', () async {
      seedCurrentConversation();
      seedMessage();
      store.setSenderPref('sarah@x.com', 'later');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(bucketOf(), 'later');
      expect(reasonOf(), 'sender_pref');
    });

    test('a keep sender rule beats a low-value verdict', () async {
      seedCurrentConversation();
      seedMessage();
      store.setSenderPref('sarah@x.com', 'keep');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(bucketOf(), isNull);
    });

    test('it never overrules a bucket a person asked for', () async {
      seedCurrentConversation();
      seedMessage();
      store.setConversationBucket('email', 'conv-1',
          bucket: 'later', reason: 'user');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(bucketOf(), 'later');
      expect(reasonOf(), 'user');
    });

    test('nor an exemption a person asked for', () async {
      seedCurrentConversation();
      seedMessage();
      store.setConversationBucket('email', 'conv-1',
          bucket: null, reason: 'user');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(bucketOf(), isNull);
      expect(reasonOf(), 'user');
    });

    test('it withdraws its own earlier guess when the verdict changes',
        () async {
      seedCurrentConversation();
      seedMessage();
      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));
      expect(bucketOf(), 'later');

      await runOne(handlerFor(answer(intent: 'request', importance: 'high')));

      expect(bucketOf(), isNull);
      expect(reasonOf(), isNull);
    });

    test('an older message does not get to file the thread', () async {
      // The queue drains newest-first, but a backlog can still hand this
      // handler a month-old message. Letting it decide would file the thread
      // on what its conversation stopped being about.
      seedCurrentConversation(lastInboundAt: '2026-09-01T10:00:00Z');
      seedMessage();

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(bucketOf(), isNull);
      // The extraction itself still landed — only the filing was declined.
      expect(store.getExtraction('email', 'm1'), isNotNull);
    });

    test('a message with no conversation row files nothing', () async {
      seedMessage(conversationKey: 'orphan');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(store.getConversationAi('email', 'orphan'), isNull);
    });
  });

  group('buildConversationCard', () {
    test('is four segments, empty ones included', () {
      expect(
        buildConversationCard(
          subject: 'Rate lock',
          participants: const ['Sarah', 'Tom'],
          topics: const ['lock', 'appraisal'],
          summary: 'Extend by Friday.',
        ),
        'Rate lock | Sarah, Tom | lock, appraisal | Extend by Friday.',
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
      seedConversation();
      seedMessage();
      store.enqueueWork('extract', 'email', 'm1');
      final embeddings = FakeEmbeddings();
      final worker = AiWorker(
        store,
        handlers: [ExtractHandler(store, FakeLlm([answer()]), embeddings.client)],
      );

      await worker.pump();

      expect(store.workCounts('extract'), {'done': 1});
      expect(store.getExtraction('email', 'm1'), isNotNull);
      expect(embeddings.inputs.length, 1);
    });

    test('a model server that is down leaves the item queued', () async {
      seedMessage();
      store.enqueueWork('extract', 'email', 'm1');
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

      expect(store.workCounts('extract'), {'pending': 1});
      expect(store.getExtraction('email', 'm1'), isNull);
    });
  });
}
