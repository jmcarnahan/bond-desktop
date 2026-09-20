import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/draft_policy.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/clustering_card.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
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

/// An [ActivityLog] that keeps what the handler noted, so the REASON a message
/// was not queued can be read — the progress row has no column for it.
class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};

  @override
  void note(Map<String, Object?> detail) => notes.addAll(detail);
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

  /// The document corpus is now told apart by the ABSENCE of the clustering
  /// instruction, not by a prefix of its own: Qwen embeds a document bare, so
  /// `EmbeddingsClient.documentPrefix` is the empty string and a `startsWith`
  /// on it would match every call this class ever recorded.
  List<String> get documentInputs => [
        for (final input in inputs)
          if (!input.startsWith(EmbeddingsClient.clusteringPrefix)) input,
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

  /// [summary] writes a full triaged result; [triageStatus] alone writes just
  /// the status, for a test whose subject is the worker's claim rather than
  /// what triage said. Either way the row is one triage has spoken about.
  Future<void> seedMessage({
    String id = 'm1',
    String conversationKey = 'conv-1',
    String? summary,
    String? triageStatus,
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
    } else if (triageStatus != null) {
      await store.writeTriage('email', id, status: triageStatus);
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

    test('a file-only chat message reaches the model as what was shared',
        () async {
      // The body is nothing but a marker, so the facts pulled from this
      // message are the facts about the file — and only if the row's
      // attachments are hydrated onto the message the prompt is built from.
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 't1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'from_address': 'teams:u-1',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': '[[att:a1]]',
        'has_attachments': 1,
        'triage_status': 'skipped',
        'gate_reason': 'teams_source',
      });
      await store.upsertAttachments('teams', 't1', [
        {
          'attachment_id': 'a1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Contract-v2.docx',
          'size': 0,
        },
      ]);
      final llm = FakeLlm([answer()]);

      await ExtractHandler(store, llm, FakeEmbeddings().client).run(
        {'task_kind': 'extract', 'source': 'teams', 'entity_id': 't1'},
      );

      expect(llm.userMessages.single, contains('Shared a file: Contract-v2.docx'));
      expect(llm.userMessages.single, isNot(contains('[[att:')));
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

    test('extraction sees the message alone even when the thread has history',
        () async {
      // The context ladder measured on 2026-09-17 tried a thread for
      // extraction on both rungs and neither shipped: the tail bought intent
      // 75 -> 78 but lost people 87 -> 75 and project 66 -> 53, and the digest
      // lost people 87 -> 66. `ExtractionInput` still takes `thread` and
      // `threadDigest`; this pins that the handler passes neither, which is
      // also what keeps the prompt byte-identical to every measured 4B row.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'earlier',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'Re: Launch date',
        'from_name': 'Sarah',
        'from_address': 'sarah@example.com',
        'received_at': '2026-08-29T09:00:00Z',
        'body_text': 'The build cut is scheduled for Wednesday night.',
      });
      await seedMessage();
      await seedConversation();
      final llm = FakeLlm([answer()]);

      await runOne(ExtractHandler(store, llm, FakeEmbeddings().client));

      final sent = llm.userMessages.single;
      expect(sent, contains('<untrusted_data source="inbound_message">'));
      expect(sent, isNot(contains('source="thread"')));
      expect(sent, isNot(contains('thread_digest')));
      expect(sent, isNot(contains('Extract from ONLY this message:')));
      expect(
        sent,
        isNot(contains('The build cut is scheduled for Wednesday night.')),
      );
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

      // The people segment is empty since Round D Phase 2 — the card is four
      // segments by contract whatever the flag says, so the vector is taken
      // over a subject, a topic list and a summary and nothing else.
      expect(
        embeddings.clusteringInputs.single,
        '${EmbeddingsClient.clusteringPrefix}'
        'Launch date |  | launch date | '
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

    test('the hash is over the card the heal path would rebuild', () async {
      // One thread, one card. Extraction used to build from the result in hand
      // and the row's own triage summary while `StorylineService._reembed`
      // built from the thread's newest kept inbound, and both wrote the same
      // `embedded_hash` column — so extracting an older message of a thread
      // stored a hash over a card nothing else would ever produce, and the
      // next heal re-embedded a thread that had not changed. The older message
      // is extracted here deliberately: that is the case that used to differ.
      await seedConversation();
      await seedMessage(summary: 'Sarah needs the lock extended.');
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm2',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'Re: Launch date',
        'from_name': 'Sarah',
        'from_address': 'sarah@x.com',
        'received_at': '2026-08-30T10:00:00Z',
        'body_text': 'And the photography?',
        'triage_status': 'triaged',
      });
      await store.writeTriage(
        'email',
        'm2',
        status: 'triaged',
        result: const TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: 'Sarah is asking about the photography.',
          needsAction: true,
          actionItems: ['Send the photo selects'],
        ),
      );
      await store.writeExtraction(
        'email',
        'm2',
        jsonEncode({
          'topics': ['photography'],
        }),
      );
      final embeddings = FakeEmbeddings();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), embeddings.client));

      final expected = clusteringCardForConversationRow(
        (await store.getConversationRow('email', 'conv-1'))!,
        await store.newestInboundCardData('email', 'conv-1'),
      );
      expect(
        (await store.getConversationAi('email', 'conv-1'))!['embedded_hash'],
        cardHash(expected),
      );
      // And the text that was actually embedded is that card, not the one the
      // extracted message alone would have described.
      expect(
        embeddings.clusteringInputs.single,
        '${EmbeddingsClient.clusteringPrefix}$expected',
      );
      expect(expected, contains('photography'));
    });

    test('a card stored under the retired tag is embedded again', () async {
      // The defect a tag bump would otherwise leave behind. The card has not
      // changed, so the hash matches and the old guard would have skipped —
      // and the thread would carry a vector nothing reads for as long as its
      // card stayed the same, invisible to every sweep.
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        embeddings.client,
      );

      await runOne(handler);
      final hash =
          (await store.getConversationAi('email', 'conv-1'))!['embedded_hash'];
      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedModel: EmbeddingsClient.retiredModelTag,
      );

      await runOne(handler);

      expect(embeddings.clusteringInputs.length, 2);
      final row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embed_model'], EmbeddingsClient.modelTag);
      // The same card, so the same hash: what moved is the space the vector
      // lives in.
      expect(row['embedded_hash'], hash);
    });

    test('the same card under the current tag is not embedded twice', () async {
      await seedConversation();
      await seedMessage();
      final embeddings = FakeEmbeddings();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        embeddings.client,
      );

      await runOne(handler);
      expect(
        (await store.getConversationAi('email', 'conv-1'))!['embed_model'],
        EmbeddingsClient.modelTag,
      );

      await runOne(handler);

      expect(embeddings.clusteringInputs.length, 1);
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

  // The stage the settle machine now waits on. A thread whose card did not
  // change queues no storyline pass, so the handler is the only writer left
  // for the new message's row — and a row left `pending` here would wait out
  // the notification deadline and never close its outcome.
  group('the storyline stage when no pass is queued', () {
    Future<Map<String, Object?>> progressOf(String id) async => (await db
            .customSelect(
              'SELECT * FROM message_progress '
              'WHERE source = ? AND source_message_id = ?',
              variables: [Variable('email'), Variable(id)],
            )
            .getSingle())
        .data;

    test('an unchanged card closes the stage with the thread\'s storyline',
        () async {
      await seedConversation();
      await seedMessage();
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Launch date',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'conv-1',
          addedBy: 'auto');
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbeddings().client,
        progress: PipelineProgress(store),
      );

      // The first message embeds the card and queues the pass, which is what
      // writes the stage for it later — so it is still owed here.
      await runOne(handler);
      expect((await progressOf('m1'))['storyline_state'], 'pending');

      // The second lands the same card: no pass, and the stage is closed
      // with the storyline the thread already sits in.
      await seedMessage(id: 'm2');
      await runOne(handler, id: 'm2');

      final row = await progressOf('m2');
      expect(row['storyline_state'], 'done');
      expect(row['storyline_id'], 'sl-1');
    });

    test('a thread in no storyline still finishes the stage', () async {
      await seedConversation();
      await seedMessage();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbeddings().client,
        progress: PipelineProgress(store),
      );
      await runOne(handler);
      await seedMessage(id: 'm2');
      await runOne(handler, id: 'm2');

      final row = await progressOf('m2');
      expect(row['storyline_state'], 'done');
      expect(row['storyline_id'], isNull);
    });

    test('a message with no thread row is skipped, not owed', () async {
      await seedMessage();

      await runOne(ExtractHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbeddings().client,
        progress: PipelineProgress(store),
      ));

      expect((await progressOf('m1'))['storyline_state'], 'skipped');
    });
  });

  group('the storyline recap trigger', () {
    Future<void> fileInStoryline({String key = 'conv-1'}) async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
    }

    test('a message landing in a member thread queues its storyline\'s recap',
        () async {
      await seedConversation();
      await seedMessage();
      await fileInStoryline();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings().client));

      // The one storyline trigger that is not about membership: a message
      // landing in a thread that is ALREADY filed changes where that storyline
      // stands, which is what the user opens it to read.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
      // The `source` on a storyline work row is a LABEL, not a scope — its
      // entity id is a storyline id, and a storyline spans both connectors.
      expect(work?['source'], 'email');
    });

    test('a thread in no storyline queues nothing', () async {
      await seedConversation();
      await seedMessage();

      await runOne(ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings().client));

      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('an embedding server that is down still queues the recap', () async {
      await seedConversation();
      await seedMessage();
      await fileInStoryline();

      await runOne(
        ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings(vector: null).client),
      );

      // The recap has nothing to do with the vector. Hanging it off a
      // successful embed would mean an afternoon of a down embedding server
      // was an afternoon of storylines silently going stale.
      expect((await store.nextPendingWork('storyline_recap'))?['entity_id'],
          'sl-1');
    });

    test('a chat queues its storyline under the same label mail does',
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
      });
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Acme renewal',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'teams', 'chat-1',
          addedBy: 'auto');

      await ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings().client)
          .run({'task_kind': 'extract', 'source': 'teams', 'entity_id': 't1'});

      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
      expect(work?['source'], 'email');
    });

    test('a thread in two storylines wakes both', () async {
      await seedConversation();
      await seedMessage();
      await fileInStoryline();
      await store.insertStoryline(
        id: 'sl-2',
        title: 'Launch party',
        status: 'suggested',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-2', 'email', 'conv-1',
          addedBy: 'auto');

      await runOne(ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings().client));

      expect(await store.workCounts('storyline_recap'), {'pending': 2});
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
      // The message's OWN text, bare — not the thread's clustering card, and
      // with nothing at all in front of it.
      expect(
        embeddings.documentInputs.single,
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
      // Triaged, because the worker is not handed an `extract` item whose
      // message triage has not spoken about — see
      // `MessageStore.claimPendingWork`.
      await seedMessage(triageStatus: 'triaged');
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

    test('an open ask on the thread keeps it out of Later', () async {
      // The older message is the ask; the one being filed on is a quiet FYI.
      // The thread is the unit being filed, so the ask still counts.
      await seedCurrentConversation();
      await seedMessage();
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-ask',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'from_address': 'sarah@x.com',
        'received_at': '2026-08-28T09:00:00Z',
      });
      await store.writeNeedsYouVerdict('email', 'm-ask',
          verdict: true, reason: 'asks whether Thursday still holds');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), isNull);
    });

    test('and defers once that ask has been answered', () async {
      await seedCurrentConversation();
      await seedMessage();
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm-ask',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'from_address': 'sarah@x.com',
        'received_at': '2026-08-28T09:00:00Z',
      });
      await store.writeNeedsYouVerdict('email', 'm-ask',
          verdict: true, reason: 'asks whether Thursday still holds');
      // The outbound watermark lives on the conversation row, and it is what
      // closes the ask.
      await store.upsertConversation({
        'conversation_key': 'conv-1',
        'state': 'waiting',
        'last_outbound_at': '2026-08-28T17:00:00Z',
      });

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await bucketOf(), 'later');
      expect(await reasonOf(), 'low_value');
    });

    test('a message with no conversation row files nothing', () async {
      await seedMessage(conversationKey: 'orphan');

      await runOne(handlerFor(answer(intent: 'fyi', importance: 'low')));

      expect(await store.getConversationAi('email', 'orphan'), isNull);
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

  /// Extraction is what decides whether a message reaches the drafting model
  /// at all, and it decides on the fast triage's own verdict — the row it
  /// already has in hand. That gate is COARSE on purpose: the 27B behind the
  /// queue makes the real call, and this only stops a backlog of newsletters
  /// from buying hours of its time.
  /// The draft stage as `message_progress` holds it — the bar's fifth segment.
  Future<String?> draftStateOf(String id, {String source = 'email'}) async =>
      (await db
              .customSelect(
                'SELECT draft_state FROM message_progress '
                'WHERE source = ? AND source_message_id = ?',
                variables: [Variable(source), Variable(id)],
              )
              .getSingle())
          .data['draft_state'] as String?;

  Future<List<String>> queuedDrafts() async => [
        for (final row in await db
            .customSelect(
              "SELECT entity_id FROM work_items WHERE task_kind = 'draft' "
              'ORDER BY entity_id',
            )
            .get())
          row.data['entity_id'] as String,
      ];

  Future<void> triageSaid({
    String id = 'm1',
    bool replyExpected = false,
    bool needsAction = false,
    String urgency = 'normal',
    String deadline = '',
  }) =>
      store.writeTriage(
        'email',
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: urgency,
          category: 'work',
          summary: 'what it says',
          needsAction: needsAction,
          actionItems: const [],
          replyExpected: replyExpected,
          deadline: deadline,
        ),
      );

  /// One extraction, under [policy]. No closure at all is the default every
  /// existing caller gets, which the handler answers as [DraftPolicy.all].
  Future<void> extract({
    String id = 'm1',
    DraftPolicy? policy,
    ActivityLog? activityLog,
    void Function()? onDraftQueued,
  }) =>
      runOne(
        ExtractHandler(
          store,
          FakeLlm([answer()]),
          FakeEmbeddings().client,
          progress: PipelineProgress(store),
          activityLog: activityLog,
          onDraftQueued: onDraftQueued,
          draftPolicy: policy == null ? null : () => policy,
        ),
        id: id,
      );

  group('the drafting pre-gate', () {
    test('a message somebody is waiting on is queued, by its own id',
        () async {
      await seedMessage();
      await seedConversation();
      await triageSaid(replyExpected: true);

      await extract();

      // The work is keyed on the MESSAGE — a suggestion answers one thing
      // somebody said, not a thread.
      expect(await queuedDrafts(), ['m1']);
      expect(await draftStateOf('m1'), 'pending');
    });

    test('and so is one that asks the reader to do something', () async {
      await seedMessage();
      await triageSaid(needsAction: true);

      await extract();

      expect(await queuedDrafts(), ['m1']);
    });

    test('a loud message is queued on the noise alone', () async {
      await seedMessage();
      await triageSaid(urgency: 'urgent');

      await extract();

      expect(await queuedDrafts(), ['m1']);
    });

    test('and so is one that names a date', () async {
      await seedMessage();
      await triageSaid(deadline: 'Friday');

      await extract();

      expect(await queuedDrafts(), ['m1']);
    });

    test('a message nobody is waiting on gets no work row and no wait',
        () async {
      await seedMessage();
      await seedConversation();
      await triageSaid();

      await extract();

      // Skipped rather than pending: no work row will ever be written for it,
      // and a bar that waited would wait forever.
      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('m1'), 'skipped');
    });

    test('the needs-you stage alone is enough to queue one', () async {
      // Nothing triage wrote asks for anything: no reply expected, no action,
      // normal urgency, no date. The needs-you stage read the message whole and
      // said it is the user's to answer, and that is the fifth signal — the
      // handler runs ahead of this one in the worker precisely so the verdict
      // is on the row by the time this reads it.
      await seedMessage();
      await seedConversation();
      await triageSaid();
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: true, reason: 'Priya is waiting on your number');

      await extract();

      expect(await queuedDrafts(), ['m1']);
      expect(await draftStateOf('m1'), 'pending');
    });

    test('but a judged no leaves the narrow row exactly where it was', () async {
      await seedMessage();
      await seedConversation();
      await triageSaid();
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: false, reason: 'a heads-up, nothing to answer');

      await extract();

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('m1'), 'skipped');
    });

    test('and so does a verdict nothing ever wrote', () async {
      // NULL — the handler errored, or never ran. The gate degrades to exactly
      // the four-signal shape it had before the stage existed.
      await seedMessage();
      await seedConversation();
      await triageSaid();
      await store.writeNeedsYouVerdict('email', 'm1', verdict: null);

      await extract();

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('m1'), 'skipped');
    });

    test('a verdict on the user\'s own mail does not get past the guard',
        () async {
      // The inbound guard runs first and nothing after it can reopen the
      // question: the user needs no reply to themselves.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'o1',
        'conversation_key': 'conv-1',
        'direction': 'outbound',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Sent it over. — Jo',
      });
      await triageSaid(id: 'o1');
      await store.writeNeedsYouVerdict('email', 'o1', verdict: true);

      await extract(id: 'o1');

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('o1'), 'skipped');
    });

    test('a message that vanished is skipped, not left waiting', () async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'received_at': '2026-08-29T10:00:00Z',
      });
      await db.customUpdate(
        "DELETE FROM messages WHERE source_message_id = 'm1'",
      );

      await extract();

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('m1'), 'skipped');
    });

    test('and a gated one is skipped at the same point extraction is',
        () async {
      await seedMessage();
      await store.writeTriage('email', 'm1',
          status: 'skipped', gateReason: 'newsletter');

      await extract();

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('m1'), 'skipped');
    });

    test('the user\'s own mail is never queued to be answered', () async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'o1',
        'conversation_key': 'conv-1',
        'direction': 'outbound',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Sent it over. — Jo',
      });
      await triageSaid(id: 'o1', replyExpected: true);

      await extract(id: 'o1');

      expect(await queuedDrafts(), isEmpty);
      expect(await draftStateOf('o1'), 'skipped');
    });
  });

  group('suggested replies: the three policies', () {
    /// A message with every signal `asksForAReply` reads, so the only thing
    /// separating the policies in a test is the policy.
    Future<void> seedLoud({String id = 'm1'}) async {
      await seedMessage(id: id);
      await triageSaid(id: id, replyExpected: true, urgency: 'urgent');
    }

    /// A message that asks for a reply but is not worth the big model's idle
    /// time: triage says the sender is waiting and names a date, and nothing
    /// says it is loud or the owner's to answer.
    Future<void> seedOrdinary({String id = 'm1'}) async {
      await seedMessage(id: id);
      await triageSaid(id: id, replyExpected: true, deadline: 'Friday');
    }

    group('all', () {
      test('queues every message that passes the wide pre-gate', () async {
        await seedOrdinary();

        await extract(policy: DraftPolicy.all);

        expect(await queuedDrafts(), ['m1']);
        expect(await draftStateOf('m1'), 'pending');
      });

      test('and skips one with no cue at all, saying why', () async {
        await seedMessage();
        await triageSaid();
        final log = _Recorder();

        await extract(policy: DraftPolicy.all, activityLog: log);

        expect(await queuedDrafts(), isEmpty);
        expect(await draftStateOf('m1'), 'skipped');
        expect(log.notes['draft'], 'no_cue');
      });

      test('is what a handler with no policy closure does', () async {
        // Every existing test, and both live benches, build the handler this
        // way: the pre-round pre-gate, byte for byte.
        await seedOrdinary();

        await extract();

        expect(await queuedDrafts(), ['m1']);
      });
    });

    group('onDemand', () {
      test('queues nothing, however loud the message', () async {
        await seedLoud();
        await store.writeNeedsYouVerdict('email', 'm1',
            verdict: true, reason: 'Priya is waiting on your number');
        final log = _Recorder();

        await extract(policy: DraftPolicy.onDemand, activityLog: log);

        expect(await queuedDrafts(), isEmpty);
        // Skipped, not pending: **Draft reply** is how this message gets an
        // answer, and a bar waiting on a row nothing will write waits forever.
        expect(await draftStateOf('m1'), 'skipped');
        expect(log.notes['draft'], 'on_demand');
      });

      test('and never wakes the draft lane', () async {
        await seedLoud();
        var woken = 0;

        await extract(
          policy: DraftPolicy.onDemand,
          onDraftQueued: () => woken++,
        );

        expect(woken, 0);
      });
    });

    group('needsYou', () {
      test('queues a message the needs-you stage called the owner\'s',
          () async {
        // Nothing triage wrote is loud. The whole-message verdict is the
        // signal.
        await seedMessage();
        await triageSaid();
        await store.writeNeedsYouVerdict('email', 'm1',
            verdict: true, reason: 'Priya is waiting on your number');
        var woken = 0;

        await extract(
          policy: DraftPolicy.needsYou,
          onDraftQueued: () => woken++,
        );

        expect(await queuedDrafts(), ['m1']);
        expect(await draftStateOf('m1'), 'pending');
        expect(woken, 1);
      });

      test('and an urgent one, and a high one', () async {
        await seedMessage(id: 'm1');
        await triageSaid(id: 'm1', urgency: 'urgent');
        await seedMessage(id: 'm2', conversationKey: 'conv-2');
        await triageSaid(id: 'm2', urgency: 'high');

        await extract(policy: DraftPolicy.needsYou, id: 'm1');
        await extract(policy: DraftPolicy.needsYou, id: 'm2');

        expect(await queuedDrafts(), ['m1', 'm2']);
      });

      test('but not a message whose only cue is that a reply is expected',
          () async {
        await seedOrdinary();
        final log = _Recorder();
        var woken = 0;

        await extract(
          policy: DraftPolicy.needsYou,
          activityLog: log,
          onDraftQueued: () => woken++,
        );

        // The wide gate would have taken it — this is the narrowing.
        expect(asksForAReply(await store.getMessageRow('email', 'm1') ?? {}),
            isTrue);
        expect(await queuedDrafts(), isEmpty);
        expect(await draftStateOf('m1'), 'skipped');
        // Its OWN reason, not the mode's: a person reading the activity row
        // has to be able to tell "this mode prefetches nothing" from "this
        // message did not make the cut".
        expect(log.notes['draft'], 'not_prefetched');
        expect(woken, 0);
      });

      test('nor one whose only cue is an action item', () async {
        await seedMessage();
        await triageSaid(needsAction: true);

        await extract(policy: DraftPolicy.needsYou);

        expect(await queuedDrafts(), isEmpty);
      });

      test('nor one whose only cue is a date', () async {
        await seedMessage();
        await triageSaid(deadline: 'Friday');

        await extract(policy: DraftPolicy.needsYou);

        expect(await queuedDrafts(), isEmpty);
      });

      test('a judged no is a no, and so is a verdict nothing wrote', () async {
        await seedMessage(id: 'm1');
        await triageSaid(id: 'm1');
        await store.writeNeedsYouVerdict('email', 'm1',
            verdict: false, reason: 'a heads-up, nothing to answer');
        await seedMessage(id: 'm2', conversationKey: 'conv-2');
        await triageSaid(id: 'm2');
        await store.writeNeedsYouVerdict('email', 'm2', verdict: null);

        await extract(policy: DraftPolicy.needsYou, id: 'm1');
        await extract(policy: DraftPolicy.needsYou, id: 'm2');

        expect(await queuedDrafts(), isEmpty);
      });

      test('the owner\'s own mail never passes, whatever was written about it',
          () async {
        await store.upsertMessage({
          'source': 'email',
          'source_message_id': 'o1',
          'conversation_key': 'conv-1',
          'direction': 'outbound',
          'received_at': '2026-08-29T10:00:00Z',
          'body_text': 'Sent it over. — Jo',
        });
        await triageSaid(id: 'o1', urgency: 'urgent');
        await store.writeNeedsYouVerdict('email', 'o1', verdict: true);

        await extract(policy: DraftPolicy.needsYou, id: 'o1');

        expect(await queuedDrafts(), isEmpty);
        expect(await draftStateOf('o1'), 'skipped');
      });
    });

    test('the gap between the two wide policies is what PIPE_POLICY measures',
        () async {
      // `make bench-pipeline` runs `all` by default, which is the worst case
      // and the shape every row in the ledger was taken at; `needsYou` is what
      // the app ships. The difference between the two is prose calls that were
      // never made, and this is the offline pin under that: one message shape,
      // two policies, one draft row. Nothing about the bench can be run
      // offline, so what is provable here is the behaviour the knob selects.
      await seedOrdinary(id: 'm1');
      await seedOrdinary(id: 'm2');

      await extract(policy: DraftPolicy.all, id: 'm1');
      await extract(policy: DraftPolicy.needsYou, id: 'm2');

      expect(await queuedDrafts(), ['m1']);
      expect(await draftStateOf('m1'), 'pending');
      expect(await draftStateOf('m2'), 'skipped');
    });

    group('the prefetch cap', () {
      /// [count] draft rows already in the queue, across BOTH connectors —
      /// the count the cap reads is over `email`, `teams` and `local`, because
      /// a chat is drafted for exactly as mail is.
      Future<void> queueDrafts(int count) async {
        for (var i = 0; i < count; i++) {
          await store.enqueueWork(
            'draft',
            i.isEven ? 'email' : 'teams',
            'seeded-$i',
          );
        }
      }

      test('the eleventh in flight is skipped, and says so', () async {
        await queueDrafts(DraftPolicy.prefetchCap);
        await seedLoud(id: 'n1');
        final log = _Recorder();

        await extract(
          policy: DraftPolicy.needsYou,
          id: 'n1',
          activityLog: log,
        );

        expect(await draftStateOf('n1'), 'skipped');
        expect(log.notes['draft'], 'prefetch_cap');
        expect((await queuedDrafts()).contains('n1'), isFalse);
      });

      test('a chat backlog counts against it too', () async {
        // The default `sources` on `workCounts` is `['email']` alone. If the
        // cap read that, ten queued chats would leave the mail lane thinking
        // it had the whole budget.
        for (var i = 0; i < DraftPolicy.prefetchCap; i++) {
          await store.enqueueWork('draft', 'teams', 'chat-$i');
        }
        await seedLoud(id: 'n1');

        await extract(policy: DraftPolicy.needsYou, id: 'n1');

        expect(await draftStateOf('n1'), 'skipped');
      });

      test('a draft that finished frees a slot', () async {
        await queueDrafts(DraftPolicy.prefetchCap);
        await db.customUpdate(
          "UPDATE work_items SET status = 'done' "
          "WHERE task_kind = 'draft' AND entity_id = 'seeded-0'",
        );
        await seedLoud(id: 'n1');

        await extract(policy: DraftPolicy.needsYou, id: 'n1');

        // The cap is "in flight", not "ever queued": `done` rows are history.
        expect((await queuedDrafts()).contains('n1'), isTrue);
        expect(await draftStateOf('n1'), 'pending');
      });

      test('a claimed draft still counts', () async {
        await queueDrafts(DraftPolicy.prefetchCap - 1);
        await store.enqueueWork('draft', 'email', 'claimed-1');
        await db.customUpdate(
          "UPDATE work_items SET status = 'processing' "
          "WHERE task_kind = 'draft' AND entity_id = 'claimed-1'",
        );
        await seedLoud(id: 'n1');

        await extract(policy: DraftPolicy.needsYou, id: 'n1');

        expect(await draftStateOf('n1'), 'skipped');
      });

      test('and it binds only the prefetch, never the wide policy', () async {
        // Someone who has asked for every message to be drafted has asked for
        // exactly that; the cap is what makes the DEFAULT bounded.
        await queueDrafts(DraftPolicy.prefetchCap);
        await seedLoud(id: 'n1');

        await extract(policy: DraftPolicy.all, id: 'n1');

        expect((await queuedDrafts()).contains('n1'), isTrue);
      });
    });

    test('the policy is re-read for every message, not captured', () async {
      // One handler, two items, the setting moved in between: the closure is
      // what makes turning the control off stop the NEXT prefetch rather than
      // the next relaunch.
      var policy = DraftPolicy.onDemand;
      final log = _Recorder();
      final handler = ExtractHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbeddings().client,
        progress: PipelineProgress(store),
        activityLog: log,
        draftPolicy: () => policy,
      );
      await seedLoud(id: 'm1');
      await seedMessage(id: 'm2', conversationKey: 'conv-2');
      await triageSaid(id: 'm2', replyExpected: true);

      await runOne(handler, id: 'm1');
      expect(await queuedDrafts(), isEmpty);
      expect(log.notes['draft'], 'on_demand');

      policy = DraftPolicy.all;
      await runOne(handler, id: 'm2');

      expect(await queuedDrafts(), ['m2']);
      expect(await draftStateOf('m2'), 'pending');
    });

    test('a skipped draft stage is TERMINAL, not a pause', () async {
      // Which is what lets the message settle: `skipped` is stamped exactly
      // as `no_reply_needed` is, so the outcome closes with the other stages
      // rather than waiting on a row nothing is going to write.
      await seedOrdinary();

      await extract(policy: DraftPolicy.onDemand);

      final row = (await db
              .customSelect(
                'SELECT draft_state, draft_at FROM message_progress '
                "WHERE source = 'email' AND source_message_id = 'm1'",
              )
              .getSingle())
          .data;

      expect(row['draft_state'], 'skipped');
      expect(row['draft_at'], isNotNull);
    });
  });

  group('through the worker', () {
    test('a queued message is extracted, embedded and marked done', () async {
      await seedConversation();
      // Triaged: the claim holds an `extract` item back while its message is
      // still `pending`, so a fixture that never triages is a fixture the
      // worker will not claim. See `MessageStore.claimPendingWork`.
      await seedMessage(triageStatus: 'triaged');
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

    test('a message queued on its needs-you verdict still faces the 27B',
        () async {
      // The pre-gate only ever WIDENS what gets asked about. Nothing triage
      // wrote asks for anything here, so this message reaches drafting on the
      // verdict alone — and the reply decision behind the queue still closes it
      // with a no, without a drafting call being spent.
      await seedConversation();
      await seedMessage();
      await store.writeTriage(
        'email',
        'm1',
        status: 'triaged',
        result: TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: 'what it says',
          needsAction: false,
          actionItems: const [],
          replyExpected: false,
          deadline: '',
        ),
      );
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: true, reason: 'Priya is waiting on your number');
      await store.enqueueWork('extract', 'email', 'm1');
      final drafting = FakeLlm([
        {'needs_reply': false, 'reason': 'A heads-up; nobody is waiting.'}
      ]);
      final worker = AiWorker(
        store,
        handlers: [
          ExtractHandler(store, FakeLlm([answer()]), FakeEmbeddings().client),
          DraftHandler(store, drafting),
        ],
      );

      await worker.pump();
      await worker.pump();

      expect(await store.workCounts('draft'), {'done': 1});
      expect(drafting.userMessages, hasLength(1),
          reason: 'the decision ran and the drafting model was never reached');
      expect(await store.getDraftForMessage('email', 'm1'), isNull);
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
