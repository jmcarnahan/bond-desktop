import 'dart:convert';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_handler.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The gap this closes: an embedding server that is down used to mean a thread
/// was never considered for a storyline again.
///
/// The only `requeueWork('storyline', …)` in the app sits in the extraction
/// handler, and it sat BEHIND a successful embed — so no server meant no
/// vector, no requeue, and a thread that had already spent its extraction call
/// silently left the clustering pipeline. Nothing failed, nothing retried,
/// nothing said so.

/// An [LlmClient] that answers from a per-schema script, so an extraction and
/// a membership confirmation can be scripted independently of the order the
/// drain happens to reach them in.
class FakeLlm extends LlmClient {
  final Map<String, List<Object>> scripts;
  final List<String> schemas = [];

  FakeLlm(this.scripts) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  int callsFor(String schemaName) =>
      schemas.where((s) => s == schemaName).length;

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
    schemas.add(schemaName);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final script = scripts[schemaName];
    if (script == null || script.isEmpty) {
      throw StateError('no scripted answer for $schemaName');
    }
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// An embedding server in one of the three states the client can now tell
/// apart: answering, not running, or answering something that is not a vector.
enum EmbedServer { up, down, nonsense }

EmbeddingsClient embeddings(EmbedServer state, {List<double>? vector}) =>
    EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((request) async {
        switch (state) {
          // 503 is a server still loading — the client reads it as
          // unavailable, which is the whole point of the distinction.
          case EmbedServer.down:
            return http.Response('loading', 503);
          case EmbedServer.nonsense:
            return http.Response('<html>not a vector</html>', 200);
          case EmbedServer.up:
            return http.Response(
              jsonEncode({
                'data': [
                  {'embedding': vector ?? const [1.0, 0.0]}
                ]
              }),
              200,
            );
        }
      }),
    );

/// A [WorkHandler] that records what it was given and does nothing else —
/// standing in for the draft handler, which is only here to prove the drain
/// carried on past the parked kind.
class ScriptedHandler extends WorkHandler {
  @override
  final String kind;

  final List<String> seen = [];

  ScriptedHandler(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    seen.add(item['entity_id'] as String? ?? '');
  }
}

Map<String, dynamic> extractAnswer() => {
      'evidence': 'Sarah is asking whether the launch date holds.',
      'topics': const ['launch date'],
      'people': const ['Sarah Chen'],
      'organizations': const ['Northline'],
      'project': 'Website redesign',
      'intent': 'request',
      'importance': 'high',
    };

Map<String, dynamic> confirmAnswer() => const {
      'evidence': 'Both concern the website redesign.',
      'belongs': true,
      'confidence': 'high',
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread({String key = 'conv-1', String id = 'm1'}) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Launch date',
      'state': 'waiting',
      'last_message_at': '2026-08-28T10:00:00Z',
      'participants_json': jsonEncode([
        {'name': 'Sarah Chen', 'email': 'sarah@x.com'},
      ]),
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'Can we still ship on Thursday?',
      'triage_status': 'triaged',
    });
  }

  Future<Map<String, Object?>?> workRow(String kind, String entityId) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM work_items WHERE task_kind = ? AND entity_id = ?',
          variables: [Variable(kind), Variable(entityId)],
        )
        .get();
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single.data);
  }

  AiWorker workerWith(
    EmbedServer state,
    FakeLlm llm, {
    List<double>? vector,
    ScriptedHandler? draft,
  }) =>
      AiWorker(
        store,
        handlers: [
          ExtractHandler(store, llm, embeddings(state, vector: vector)),
          StorylineAssignHandler(StorylineService(store, llm)),
          ?draft,
        ],
      );

  group('an embedding server that is down', () {
    test('keeps the extraction and queues the storyline pass anyway', () async {
      await seedThread();
      await store.enqueueWork('extract', 'email', 'm1');
      final llm = FakeLlm({'extraction': [extractAnswer()]});

      await workerWith(EmbedServer.down, llm).pump();

      // The extraction is the work and it succeeded.
      expect(await store.getExtraction('email', 'm1'), isNotNull);
      // No vector and no hash, so the next extraction embeds again rather
      // than reading its own stale answer.
      final ai = await store.getConversationAi('email', 'conv-1');
      expect(ai?['embedding'], isNull);
      expect(ai?['embedded_hash'], isNull);
      // And the thread is still in the clustering pipeline.
      expect((await workRow('storyline', 'conv-1'))?['status'], 'pending');
    });

    test('parks the storyline pass without spending an attempt, and the rest '
        'of the drain carries on', () async {
      await seedThread();
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('draft', 'email', 'conv-1');
      final draft = ScriptedHandler('draft');
      final llm = FakeLlm({'extraction': [extractAnswer()]});

      await workerWith(EmbedServer.down, llm, draft: draft).pump();

      final row = (await workRow('storyline', 'conv-1'))!;
      expect(row['status'], 'pending');
      // Nothing about the thread failed — it is not ready — so a park must
      // not eat one of its two attempts.
      expect(row['attempts'], 0);
      // A park is per KIND: drafting runs on another server and the session is
      // fine, so the drain moves on rather than stopping.
      expect(draft.seen, ['conv-1']);
    });

    test('and the next pass, once the server is back, files the thread',
        () async {
      await seedThread();
      await store.enqueueWork('extract', 'email', 'm1');
      final llm = FakeLlm({
        'extraction': [extractAnswer(), extractAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      await workerWith(EmbedServer.down, llm).pump();

      // A storyline for it to join, and the vector the extraction pass writes
      // the moment `make embed` is running again.
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        charter: 'The redesign of the Northline Studio website.',
        status: 'active',
        createdBy: 'auto',
      );
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'member',
        'subject': 'Homepage copy',
        'state': 'waiting',
        'last_message_at': '2026-08-27T10:00:00Z',
      });
      await store.upsertConversationAi(
        'email',
        'member',
        embedding: encodeEmbedding(const [1.0, 0.0]),
        embeddedHash: 'h-member',
        embedModel: EmbeddingsClient.modelTag,
      );
      await store.addStorylineMember('sl-1', 'email', 'member', addedBy: 'auto');
      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: encodeEmbedding(const [1.0, 0.0]),
        embeddedHash: 'h-conv-1',
        embedModel: EmbeddingsClient.modelTag,
      );

      await workerWith(EmbedServer.up, llm).pump();

      // The requeued row is what got it here: without it there would be
      // nothing left in the queue to run once the server came back.
      expect((await workRow('storyline', 'conv-1'))!['status'], 'done');
      expect(
        (await store.membersOf('sl-1')).map((m) => m.conversationKey),
        containsAll(['member', 'conv-1']),
      );
    });
  });

  group('an embedding server that answered nonsense', () {
    test('queues nothing — the next pass would only park again', () async {
      await seedThread();
      await store.enqueueWork('extract', 'email', 'm1');
      final llm = FakeLlm({'extraction': [extractAnswer()]});

      await workerWith(EmbedServer.nonsense, llm).pump();

      expect(await store.getExtraction('email', 'm1'), isNotNull);
      // A server that answers nonsense answers the same nonsense next time,
      // so a queued pass could only park forever.
      expect(await workRow('storyline', 'conv-1'), isNull);
    });
  });
}
