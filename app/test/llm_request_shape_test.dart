import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/corpus.dart';
import 'fixtures/fake_llama_server.dart';

/// What this app actually puts on the wire, and what it makes of what comes
/// back — asserted against a real socket rather than a stubbed client.
///
/// Every claim here is one that a fake `http.Client` could not make and that a
/// live model could only make slowly: the thinking switch, the schema
/// envelope, the system prompt staying byte-identical so llama-server's prefix
/// cache survives, and the charset-less response that decodes as latin-1 the
/// moment anyone stops reading `bodyBytes`.

/// The smallest schema the server will be asked about. Nothing here tests
/// schema conversion — the fake accepts anything — so it stays a stub.
const Map<String, dynamic> _probeSchema = {
  'type': 'object',
  'properties': {
    'answer': {'type': 'string'},
  },
  'required': ['answer'],
  'additionalProperties': false,
};

Map<String, dynamic> _triageAnswer() => {
      'urgency': 'high',
      'category': 'work',
      'summary': 'Sarah is asking about the lock.',
      'needs_action': true,
      'action_items': const ['Call Sarah about the lock'],
    };

void main() {
  late FakeLlamaServer fake;
  late LlmClient client;

  setUp(() async {
    fake = await FakeLlamaServer.start();
    client = LlmClient(baseUrl: fake.chatUrl);
  });

  tearDown(() => fake.close());

  Future<Map<String, dynamic>> probe({
    String system = 'system',
    String user = 'user',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) =>
      client.completeJson(
        system: system,
        user: user,
        schema: _probeSchema,
        schemaName: 'probe',
        maxTokens: maxTokens,
        temperature: temperature,
        think: think,
      );

  group('the thinking switch', () {
    test('is off by default — the one thing that stops Qwen reasoning',
        () async {
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);

      await probe();

      expect(
        fake.requests.single['chat_template_kwargs'],
        {'enable_thinking': false},
      );
    });

    test('is absent entirely when thinking is asked for', () async {
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);

      await probe(think: true);

      // Absent, not `true`: the template branches on the key existing.
      expect(fake.requests.single.containsKey('chat_template_kwargs'), isFalse);
    });
  });

  group('the request body', () {
    test('carries the strict json_schema envelope the grammar needs', () async {
      fake.scriptFor('triage', [_triageAnswer()]);

      await runTask(
        client,
        const TriageTask(),
        TriageInput(corpus.first.message, DateTime(2026, 8, 31)),
      );

      final format =
          fake.requests.single['response_format'] as Map<String, dynamic>;
      expect(format['type'], 'json_schema');
      final schema = format['json_schema'] as Map<String, dynamic>;
      expect(schema['strict'], isTrue);
      expect(schema['name'], 'triage');
      expect(schema['schema'], const TriageTask().schema);
    });

    test('sends max_tokens and temperature as given', () async {
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);

      await probe(maxTokens: 96, temperature: 0.7);

      final body = fake.requests.single;
      expect(body['max_tokens'], 96);
      expect(body['temperature'], 0.7);
    });

    test('names the default model when nothing said otherwise', () async {
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);

      await probe();

      expect(fake.requests.single['model'], LlmClient.defaultModel);
    });

    test('names the model this client was given', () async {
      // The field llama-server ignores and an MLX-based runtime routes on: a
      // client pointed at a multi-model server must be able to say which one.
      final named = LlmClient(baseUrl: fake.chatUrl, model: 'x');
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);

      await named.completeJson(
        system: 's',
        user: 'u',
        schema: _probeSchema,
        schemaName: 'probe',
      );

      expect(fake.requests.single['model'], 'x');
    });

    test('holds the system prompt byte-identical across two emails', () async {
      fake.scriptFor('triage', [_triageAnswer()]);
      final emails = nonGatedCorpus.take(2).toList();
      final now = DateTime(2026, 8, 31);

      for (final entry in emails) {
        await runTask(
          client,
          const TriageTask(),
          TriageInput(entry.message, now),
        );
      }

      String messageAt(int request, int index) =>
          ((fake.requests[request]['messages'] as List)[index]
              as Map<String, dynamic>)['content'] as String;

      // The whole reason the date anchor lives in the user message: one
      // changed character in the system prompt throws away llama-server's KV
      // prefix cache, which costs about two seconds per message.
      expect(messageAt(0, 0), messageAt(1, 0));
      expect(messageAt(0, 1), isNot(messageAt(1, 1)));
    });
  });

  group('the response', () {
    test('decodes as UTF-8 despite the charset the server omits', () async {
      // The exact failure this guards: `http`'s `body` getter falls back to
      // latin-1 when no charset is declared, and llama-server declares none.
      const echoed = '陈丽 — déjà vu ✅';
      fake.scriptFor('probe', [
        {'answer': echoed},
      ]);

      final result = await probe();

      expect(result['answer'], echoed);
    });

    test('a 503 is the server, not the request', () async {
      fake.scriptFor('probe', [503]);

      await expectLater(probe(), throwsA(isA<LlmUnavailableException>()));
    });

    test('a 400 is this app\'s schema and is not a server outage', () async {
      fake.scriptFor('probe', [400]);

      await expectLater(
        probe(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e is LlmUnavailableException, 'unavailable',
                  isFalse),
        ),
      );
    });

    test('usage and timings survive the wire, doubles and all', () async {
      // Through a real socket rather than a mocked client, because the parse
      // being checked reads a JSON number the server encodes — `3800.0` on the
      // wire, an int in the record — and an in-process fake could hand over a
      // Dart int the real server never sends.
      final records = <LlmCallRecord>[];
      final watched = LlmClient(baseUrl: fake.chatUrl, onCall: records.add);
      fake.scriptFor('probe', [
        ScriptedReply(
          const {'answer': 'x'},
          promptTokens: 812,
          completionTokens: 47,
          promptMs: 90,
          predictedMs: 3800,
        ),
      ]);

      await watched.completeJson(
        system: 's',
        user: 'u',
        schema: _probeSchema,
        schemaName: 'probe',
      );

      expect(records.single.promptTokens, 812);
      expect(records.single.completionTokens, 47);
      expect(records.single.serverPromptMs, 90);
      expect(records.single.serverPredictedMs, 3800);
    });

    test('a reply that carries neither block reports neither', () async {
      final records = <LlmCallRecord>[];
      final watched = LlmClient(baseUrl: fake.chatUrl, onCall: records.add);
      fake.scriptFor('probe', [
        {'answer': 'x'},
      ]);

      await watched.completeJson(
        system: 's',
        user: 'u',
        schema: _probeSchema,
        schemaName: 'probe',
      );

      expect(records.single.promptTokens, isNull);
      expect(records.single.serverPredictedMs, isNull);
    });

    test('a hung-up socket is an outage', () async {
      fake.scriptFor('probe', [FakeLlamaServer.drop]);

      await expectLater(probe(), throwsA(isA<LlmUnavailableException>()));
    });
  });

  group('the thinking tripwire', () {
    test('reasoning_content is reported, not fatal', () async {
      fake.scriptFor('probe', [
        const ScriptedReply(
          {'answer': 'ok'},
          reasoningContent: 'Let me think about this email...',
        ),
      ]);
      var leaks = 0;
      client.onReasoningLeak = () => leaks++;

      // The app still works when a model swap ignores enable_thinking — it
      // just runs at half speed, which is a thing to notice rather than throw
      // an inbox away over.
      final result = await probe();

      expect(result['answer'], 'ok');
      expect(leaks, 1);
    });

    test('a clean answer trips nothing', () async {
      fake.scriptFor('probe', [
        {'answer': 'ok'},
      ]);
      var leaks = 0;
      client.onReasoningLeak = () => leaks++;

      await probe();

      expect(leaks, 0);
    });
  });
}
