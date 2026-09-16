import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The second wire, and the header that rides on both.
///
/// [LlmWire.bedrockConverse] exists because Anthropic models on Bedrock are
/// served on Converse and nowhere else, and a bakeoff that could not reach
/// them would be a bakeoff missing half its candidates. Everything asserted
/// here was measured against the live service first: the tool-call answer, the
/// token field names, the 429, and the 400 that says `temperature` is not
/// welcome. What the fixtures add is that the client keeps reading them the
/// same way — and, just as load-bearing, that the OPENAI wire did not move
/// while the second one was being added.
void main() {
  const converseHost = 'https://bedrock-runtime.example.com';
  const converseModel = 'us.anthropic.claude-haiku-4-5-20251001-v1:0';
  const converseUrl =
      '$converseHost/model/us.anthropic.claude-haiku-4-5-20251001-v1%3A0'
      '/converse';
  const openAiUrl = 'https://bedrock-runtime.example.com/openai/v1/'
      'chat/completions';

  const Map<String, dynamic> schema = {
    'type': 'object',
    'properties': {
      'pick': {
        'type': 'string',
        'enum': ['alpha', 'beta'],
      },
    },
    'required': ['pick'],
    'additionalProperties': false,
  };

  /// The last request the client sent, captured whole.
  late List<http.Request> sent;

  setUp(() => sent = []);

  MockClient answering(Future<http.Response> Function() respond) =>
      MockClient((request) {
        sent.add(request);
        return respond();
      });

  http.Response json(Object? body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  /// An OpenAI-shaped completion, as either llama-server or Bedrock's
  /// compatible endpoint answers one.
  http.Response openAiCompletion([String content = '{"pick":"alpha"}']) => json({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'stop',
          },
        ],
      });

  /// A Converse answer carrying the blocks named, in the order given.
  http.Response converseAnswer(
    List<Map<String, Object?>> content, {
    Map<String, Object?>? usage,
  }) =>
      json({
        'output': {
          'message': {'role': 'assistant', 'content': content},
        },
        'stopReason': 'tool_use',
        'usage': ?usage,
        'metrics': const {'latencyMs': 904},
      });

  Map<String, Object?> toolUse(Map<String, Object?> input) => {
        'toolUse': {
          'toolUseId': 'tooluse-fixture',
          'name': 'pick_one',
          'input': input,
        },
      };

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  Future<Map<String, dynamic>> askJson(LlmClient client) => client.completeJson(
        system: 'You answer for Alex Rivera.',
        user: 'Sam Chen asked which one to pick.',
        schema: schema,
        schemaName: 'pick_one',
        maxTokens: 128,
      );

  // ── the header, on both wires ─────────────────────────────────────────
  group('the bearer token', () {
    test('is absent when nobody set one — the app\'s own client', () async {
      final client = LlmClient(
        baseUrl: openAiUrl,
        model: 'nvidia.nemotron-nano-3-30b',
        httpClient: answering(() async => openAiCompletion()),
      );

      await askJson(client);

      expect(sent.single.headers.containsKey('Authorization'), isFalse);
      // And the wire itself is untouched: the same body as ever.
      final body = bodyOf(sent.single);
      expect(body['model'], 'nvidia.nemotron-nano-3-30b');
      expect(body['chat_template_kwargs'], {'enable_thinking': false});
      expect((body['response_format'] as Map)['type'], 'json_schema');
    });

    test('rides the OpenAI wire without changing where it goes', () async {
      final client = LlmClient(
        baseUrl: openAiUrl,
        model: 'nvidia.nemotron-nano-3-30b',
        bearerToken: 'test-token',
        httpClient: answering(() async => openAiCompletion()),
      );

      await askJson(client);

      expect(sent.single.headers['Authorization'], 'Bearer test-token');
      expect(sent.single.url.toString(), openAiUrl);
    });
  });

  // ── where a Converse request goes ─────────────────────────────────────
  group('the Converse endpoint', () {
    test('puts the model id in the path, colon and all', () async {
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        bearerToken: 'test-token',
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([toolUse(const {'pick': 'alpha'})]),
        ),
      );

      await askJson(client);

      expect(sent.single.url.toString(), converseUrl);
      expect(sent.single.headers['Authorization'], 'Bearer test-token');
    });

    test('a base URL with a trailing slash lands in the same place', () async {
      final client = LlmClient(
        baseUrl: '$converseHost/',
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([toolUse(const {'pick': 'alpha'})]),
        ),
      );

      await askJson(client);

      expect(sent.single.url.toString(), converseUrl);
    });
  });

  // ── what a Converse request says ──────────────────────────────────────
  group('the Converse body', () {
    Future<Map<String, dynamic>> sendJson() async {
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([toolUse(const {'pick': 'alpha'})]),
        ),
      );
      await askJson(client);
      return bodyOf(sent.single);
    }

    test('carries the prompt as Converse spells it', () async {
      final body = await sendJson();

      expect((body['system'] as List).single, {
        'text': 'You answer for Alex Rivera.',
      });
      final message = (body['messages'] as List).single as Map;
      expect(message['role'], 'user');
      expect((message['content'] as List).single, {
        'text': 'Sam Chen asked which one to pick.',
      });
      expect(body['inferenceConfig'], {'maxTokens': 128});
    });

    test('asks for JSON by forcing one tool', () async {
      final body = await sendJson();

      final toolConfig = body['toolConfig'] as Map<String, dynamic>;
      final spec =
          ((toolConfig['tools'] as List).single as Map)['toolSpec'] as Map;
      expect(spec['name'], 'pick_one');
      expect((spec['inputSchema'] as Map)['json'], schema);
      expect(toolConfig['toolChoice'], {
        'tool': {'name': 'pick_one'},
      });
    });

    test('sends no temperature, and nothing else from the other wire',
        () async {
      // Claude 5 answers HTTP 400 for a `temperature` it calls deprecated,
      // Haiku 4.5 accepts one, and one wire cannot behave two ways — so this
      // wire never sends it and the run says so beside its numbers.
      final body = await sendJson();

      expect((body['inferenceConfig'] as Map).containsKey('temperature'),
          isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('chat_template_kwargs'), isFalse);
      expect(body.containsKey('model'), isFalse);
      expect(body.containsKey('response_format'), isFalse);
      expect(jsonEncode(body), isNot(contains('strict')));
    });

    test('a free-text call offers no tool at all', () async {
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([
            const {'text': 'Alex is out until Monday.'},
          ]),
        ),
      );

      await client.complete(system: 's', user: 'u');

      expect(bodyOf(sent.single).containsKey('toolConfig'), isFalse);
    });
  });

  // ── what comes back ───────────────────────────────────────────────────
  group('the Converse answer', () {
    test('is the tool call\'s own object, counted in Converse\'s own fields',
        () async {
      final seen = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        onCall: seen.add,
        httpClient: answering(
          () async => converseAnswer(
            [toolUse(const {'pick': 'alpha'})],
            usage: const {
              'inputTokens': 702,
              'outputTokens': 33,
              'totalTokens': 735,
            },
          ),
        ),
      );

      expect(await askJson(client), {'pick': 'alpha'});

      expect(seen.single.label, 'pick_one');
      expect(seen.single.outcome, 'ok');
      expect(seen.single.promptTokens, 702);
      expect(seen.single.completionTokens, 33);
      // `metrics.latencyMs` is in the fixture and stays out of these two:
      // it is the whole request's latency, not a generation time, and a
      // non-null server clock would have the bench table quote a rate the
      // server never reported.
      expect(seen.single.serverPromptMs, isNull);
      expect(seen.single.serverPredictedMs, isNull);
    });

    test('a free-text call reads the text block', () async {
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([
            const {'text': 'Alex is out until Monday.'},
          ]),
        ),
      );

      expect(
        await client.complete(system: 's', user: 'u'),
        'Alex is out until Monday.',
      );
    });

    test('a reasoning block trips the wire when thinking was not asked for',
        () async {
      LlmClient reasoning() => LlmClient(
            baseUrl: converseHost,
            model: converseModel,
            wire: LlmWire.bedrockConverse,
            httpClient: answering(
              () async => converseAnswer([
                const {
                  'reasoningContent': {
                    'reasoningText': {'text': 'Weighing the two options.'},
                  },
                },
                const {'text': 'Alpha.'},
              ]),
            ),
          );

      var leaks = 0;
      final loud = reasoning()..onReasoningLeak = () => leaks++;
      await loud.complete(system: 's', user: 'u');
      expect(leaks, 1);

      final asked = reasoning()..onReasoningLeak = () => leaks++;
      await asked.complete(system: 's', user: 'u', think: true);
      expect(leaks, 1, reason: 'a model asked to think did not leak anything');
    });

    test('a forced tool that answered in prose is a format failure', () async {
      final seen = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        onCall: seen.add,
        httpClient: answering(
          () async => converseAnswer([
            const {'text': 'I would pick alpha.'},
          ]),
        ),
      );

      await expectLater(askJson(client), throwsA(isA<LlmFormatException>()));

      expect(seen.single.outcome, 'format');
    });

    test('several text blocks are one answer, in order', () async {
      // Converse may split an assistant turn across blocks; reading only the
      // first would hand the prose bench a silently truncated draft.
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => converseAnswer([
            const {'text': 'Thanks, Sam — '},
            const {'text': 'Friday works for me.'},
          ]),
        ),
      );

      expect(
        await client.complete(system: 's', user: 'u'),
        'Thanks, Sam — Friday works for me.',
      );
    });

    test('a tool call cut off by max_tokens is a format failure, not an answer',
        () async {
      // The other wire fails jsonDecode on a truncated constrained answer;
      // here the service assembles a well-formed PARTIAL object, and only
      // stopReason tells the two apart.
      final seen = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        onCall: seen.add,
        httpClient: answering(
          () async => json({
            'output': {
              'message': {
                'role': 'assistant',
                'content': [
                  toolUse(const {'pick': 'alpha'}),
                ],
              },
            },
            'stopReason': 'max_tokens',
            'usage': const {'inputTokens': 10, 'outputTokens': 512},
          }),
        ),
      );

      await expectLater(
        askJson(client),
        throwsA(isA<LlmFormatException>().having(
            (e) => e.message, 'message', contains('max_tokens'))),
      );
      expect(seen.single.outcome, 'format');
    });

    test('a free-text answer cut off by max_tokens is still returned',
        () async {
      // Same as the OpenAI wire, where a `length` finish returns what was
      // written: a truncated draft is a draft to read, not a failure.
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(
          () async => json({
            'output': {
              'message': {
                'role': 'assistant',
                'content': [
                  const {'text': 'Thanks, Sam — Friday'},
                ],
              },
            },
            'stopReason': 'max_tokens',
          }),
        ),
      );

      expect(
        await client.complete(system: 's', user: 'u'),
        'Thanks, Sam — Friday',
      );
    });
  });

  // ── how a cloud server's failures land ────────────────────────────────
  group('the status mapping', () {
    test('a 429 parks the drain on both wires', () async {
      final seen = <LlmCallRecord>[];
      LlmClient throttled(LlmWire wire) => LlmClient(
            baseUrl: wire == LlmWire.openAi ? openAiUrl : converseHost,
            model: converseModel,
            bearerToken: 'test-token',
            wire: wire,
            onCall: seen.add,
            httpClient: answering(
              () async => json(
                const {'message': 'Too many requests, please wait'},
                429,
              ),
            ),
          );

      await expectLater(
        throttled(LlmWire.openAi).complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>()),
      );
      await expectLater(
        throttled(LlmWire.bedrockConverse).complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(seen.map((r) => r.outcome), ['unavailable', 'unavailable']);
    });

    test('a 400 stays the request\'s fault and carries what was wrong',
        () async {
      // The exact answer Claude 5 gives a Converse call that sends one.
      final seen = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        onCall: seen.add,
        httpClient: answering(
          () async => json(
            const {
              'message': 'The model returned the following errors: '
                  '`temperature` is deprecated for this model.',
            },
            400,
          ),
        ),
      );

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmException>()
            .having((e) => e, 'type', isNot(isA<LlmUnavailableException>()))
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', contains('deprecated'))),
      );

      expect(seen.single.outcome, 'error');
      expect(seen.single.statusCode, 400);
    });

    test('a 403 is the request\'s fault too — a key, not an outage', () async {
      final client = LlmClient(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
        httpClient: answering(() async => json(const {'message': 'no'}, 403)),
      );

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmException>()
            .having((e) => e, 'type', isNot(isA<LlmUnavailableException>()))
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  // ── who the reader is told to go and start ────────────────────────────
  group('an unreachable server names itself in the reader\'s terms', () {
    MockClient refusing() =>
        MockClient((_) async => throw const SocketException('refused'));

    test('a remote server is not something to start on this desk', () async {
      final client = LlmClient(
        baseUrl: openAiUrl,
        model: 'nvidia.nemotron-nano-3-30b',
        bearerToken: 'test-token',
        httpClient: refusing(),
      );

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>().having(
          (e) => e.message,
          'message',
          startsWith('The model server at'),
        )),
      );
    });

    test('a local one still says start it, or change it in Settings',
        () async {
      final client = LlmClient(
        baseUrl: 'http://127.0.0.1:1/v1/chat/completions',
        httpClient: refusing(),
      );

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>().having(
          (e) => e.message,
          'message',
          startsWith('The local model server at'),
        )),
      );
    });
  });
}
