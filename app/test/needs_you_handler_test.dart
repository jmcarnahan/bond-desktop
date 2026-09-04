import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// An [LlmClient] that answers from a script and never opens a socket, with a
/// hook that runs at the moment of the call — which is how the drain-order
/// test below observes the mailbox as extraction found it.
class FakeLlm extends LlmClient {
  final Map<String, dynamic> answer;
  final Future<void> Function()? onCall;
  int calls = 0;

  FakeLlm(this.answer, {this.onCall})
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
    calls++;
    await onCall?.call();
    return Map<String, dynamic>.from(answer);
  }
}

/// An [EmbeddingsClient] over a scripted socket, so extraction can finish
/// without a server.
EmbeddingsClient fakeEmbeddings() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.6, 0.8]
              }
            ]
          }),
          200,
        );
      }),
    );

const Map<String, dynamic> extraction = {
  'evidence': 'Dana wants the DPA looked at.',
  'topics': ['DPA'],
  'people': ['Dana'],
  'organizations': ['Acme'],
  'project': 'Acme renewal',
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

  Future<void> seed({
    String source = 'teams',
    String id = 't1',
    String direction = 'inbound',
    int addressedMe = 1,
    String triageStatus = 'pending',
    String? gateReason,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'chat-1',
      'direction': direction,
      'from_name': 'Dana',
      'from_address': 'teams:u-1',
      'to_json': '["lo@x.com"]',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Legal wants a look at the DPA.',
      'addressed_me': addressedMe,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
  }

  Future<void> runOne(
    NeedsYouHandler handler, {
    String source = 'teams',
    String id = 't1',
  }) =>
      handler.run({
        'task_kind': 'needs_you',
        'source': source,
        'entity_id': id,
      });

  Future<Map<String, Object?>> verdictOf(String source, String id) async {
    final row = (await store.getMessageRow(source, id))!;
    return {
      'verdict': row['needs_you_verdict'],
      'reason': row['needs_you_reason'],
    };
  }

  group('the deterministic floor', () {
    test('a direct chat is written down as a yes, with its reason', () async {
      await seed();

      await runOne(NeedsYouHandler(store));

      expect(await verdictOf('teams', 't1'),
          {'verdict': 1, 'reason': 'teams_direct'});
    });

    test('sole-recipient mail is left unjudged, and the item completes',
        () async {
      // The floor says nothing about mail, and "nothing" must stay NULL: a 0
      // here would be a verdict this pass never reached, and would take the
      // row off the worklist the model branch reads.
      await seed(source: 'email', id: 'm1', addressedMe: 1);

      await runOne(NeedsYouHandler(store), source: 'email', id: 'm1');

      expect(await verdictOf('email', 'm1'),
          {'verdict': null, 'reason': null});
    });

    test('a group chat nobody named is left unjudged too', () async {
      await seed(addressedMe: 0);

      await runOne(NeedsYouHandler(store));

      expect((await verdictOf('teams', 't1'))['verdict'], isNull);
    });
  });

  group('guards', () {
    test('a message gated after the enqueue is left unjudged', () async {
      // The race this pins: the judgement is queued at sync time while the
      // message is still `pending`; triage then gates it. A newsletter must
      // not come back carrying a verdict.
      await seed(
        source: 'email',
        id: 'm1',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );

      await runOne(NeedsYouHandler(store), source: 'email', id: 'm1');

      expect((await verdictOf('email', 'm1'))['verdict'], isNull);
    });

    test('a chat skipped-by-birth is still judged', () async {
      // `teams_source` is the legacy tolerance for chats stored before chats
      // were triaged — not a verdict, so it must not gate this pass either.
      await seed(triageStatus: 'skipped', gateReason: 'teams_source');

      await runOne(NeedsYouHandler(store));

      expect((await verdictOf('teams', 't1'))['verdict'], 1);
    });

    test('the owner writing in their own chat is left unjudged', () async {
      await seed(direction: 'outbound');

      await runOne(NeedsYouHandler(store));

      expect((await verdictOf('teams', 't1'))['verdict'], isNull);
    });

    test('a message deleted before the worker reached it completes', () async {
      // Nothing to judge and nothing wrong: the item is done, not failed.
      await runOne(NeedsYouHandler(store), source: 'email', id: 'gone');

      expect(await store.getMessageRow('email', 'gone'), isNull);
    });
  });

  group('drain order', () {
    test('the verdict is on the row before extraction reads it', () async {
      await seed();
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'Acme renewal',
        'state': 'needs_reply',
        'last_message_at': '2026-08-29T10:00:00Z',
      });
      await store.enqueueWork('extract', 'teams', 't1');
      await store.enqueueWork('needs_you', 'teams', 't1');

      Object? verdictWhenExtractRan;
      final llm = FakeLlm(
        extraction,
        onCall: () async {
          verdictWhenExtractRan =
              (await store.getMessageRow('teams', 't1'))!['needs_you_verdict'];
        },
      );
      // Provider order: needs-you, then extraction. The whole reason for it is
      // this assertion — extraction's pre-gate reads the row as it stands, so
      // a verdict written after it would be a verdict extraction never saw.
      final worker = AiWorker(
        store,
        handlers: [
          NeedsYouHandler(store),
          ExtractHandler(store, llm, fakeEmbeddings()),
        ],
      );

      await worker.pump();

      expect(llm.calls, 1, reason: 'extraction really ran');
      expect(verdictWhenExtractRan, 1);
      expect(await store.workCounts('needs_you', sources: const ['teams']),
          {'done': 1});
      expect(await store.workCounts('extract', sources: const ['teams']),
          {'done': 1});
    });
  });
}
