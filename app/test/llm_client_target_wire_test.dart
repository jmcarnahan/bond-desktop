import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The wire and the token, arriving on the RESOLVED TARGET.
///
/// Before Round E both were fixed at construction and nothing in `lib/` set
/// either. Now a user's target spec carries them: one client per stage, built
/// on the OpenAI wire with no token, and what it actually puts on the wire is
/// whatever the target it resolved says. Two claims matter most here. One is
/// that the target WINS — a Converse target turns an OpenAI-built client's
/// next request into a Converse one, path and body — and that null keeps the
/// constructor's, which is the bench path and must not have moved. The other
/// is that the bearer reaches the `Authorization` header and NOTHING else: not
/// a record, not a message, not the string anything logs.
void main() {
  const converseHost = 'https://bedrock-runtime.example.com';
  const converseModel = 'us.example.big-model-v1:0';
  const openAiUrl = 'http://localhost:18100/v1/chat/completions';

  /// A fixture, not a credential: no service has ever issued this string.
  const token = 'fixture-token-not-a-real-credential';

  const Map<String, dynamic> schema = {
    'type': 'object',
    'properties': {
      'pick': {'type': 'string'},
    },
    'required': ['pick'],
    'additionalProperties': false,
  };

  late List<http.BaseRequest> sent;
  late List<LlmCallRecord> records;

  setUp(() {
    sent = [];
    records = [];
  });

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

  http.Response openAiCompletion([String content = '{"pick":"alpha"}']) => json({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'stop',
          },
        ],
      });

  http.Response converseAnswer() => json({
        'output': {
          'message': {
            'role': 'assistant',
            'content': [
              {
                'toolUse': {
                  'toolUseId': 'tooluse-fixture',
                  'name': 'pick_one',
                  'input': {'pick': 'alpha'},
                },
              },
            ],
          },
        },
        'stopReason': 'tool_use',
      });

  /// A client built exactly as `stageLlmClientProvider` builds one: the OpenAI
  /// wire, no token, and a resolver that decides everything else.
  LlmClient stageClient(
    LlmTarget Function() resolve,
    http.Client http_, {
    bool observe = true,
  }) =>
      LlmClient(
        baseUrl: 'http://127.0.0.1:1/never-dialled',
        model: 'never-sent',
        httpClient: http_,
        resolveTarget: resolve,
        onCall: observe ? records.add : null,
      );

  Future<Map<String, dynamic>> ask(LlmClient client) => client.completeJson(
        system: 'You answer for Alex Rivera.',
        user: 'Sam Chen asked which one to pick.',
        schema: schema,
        schemaName: 'pick_one',
        maxTokens: 128,
      );

  group('the wire comes off the target', () {
    test('a Converse target puts a Converse request out of an OpenAI client',
        () async {
      final client = stageClient(
        () => const LlmTarget(
          baseUrl: converseHost,
          model: converseModel,
          wire: LlmWire.bedrockConverse,
        ),
        answering(() async => converseAnswer()),
      );

      expect(await ask(client), {'pick': 'alpha'});

      // The model id is in the PATH on this wire, percent-encoded and all.
      expect(
        sent.single.url.toString(),
        '$converseHost/model/us.example.big-model-v1%3A0/converse',
      );
      final body =
          jsonDecode((sent.single as http.Request).body) as Map<String, dynamic>;
      // The Converse body, not the OpenAI one: no `model`, no
      // `chat_template_kwargs`, a forced tool call instead of a
      // `response_format`.
      expect(body.containsKey('model'), isFalse);
      expect(body.containsKey('chat_template_kwargs'), isFalse);
      expect(body.containsKey('response_format'), isFalse);
      expect(body['toolConfig'], isA<Map>());
      expect(body['system'], [
        {'text': 'You answer for Alex Rivera.'},
      ]);
    });

    test('a target with no wire keeps the constructor\'s — the bench path',
        () async {
      // A bench constructs ON Converse and resolves nothing but a URL and a
      // model, which is the shape `fixtures/bench_target.dart` builds.
      final client = LlmClient(
        baseUrl: 'http://127.0.0.1:1/never-dialled',
        model: 'never-sent',
        wire: LlmWire.bedrockConverse,
        httpClient: answering(() async => converseAnswer()),
        resolveTarget: () =>
            const LlmTarget(baseUrl: converseHost, model: converseModel),
      );

      expect(await ask(client), {'pick': 'alpha'});
      expect(
        sent.single.url.toString(),
        '$converseHost/model/us.example.big-model-v1%3A0/converse',
      );
    });

    test('and the app\'s own client stays on the OpenAI wire', () async {
      final client = stageClient(
        () => const LlmTarget(baseUrl: openAiUrl, model: 'qwen3.8'),
        answering(() async => openAiCompletion()),
      );

      await ask(client);

      expect(sent.single.url.toString(), openAiUrl);
      final body =
          jsonDecode((sent.single as http.Request).body) as Map<String, dynamic>;
      expect(body['model'], 'qwen3.8');
      expect(body['chat_template_kwargs'], {'enable_thinking': false});
      expect((body['response_format'] as Map)['type'], 'json_schema');
    });

    test('the next call after the resolver changes wire goes on the new one',
        () async {
      var target = const LlmTarget(baseUrl: openAiUrl, model: 'qwen3.8');
      final client = stageClient(
        () => target,
        MockClient((request) async {
          sent.add(request);
          return request.url.path.endsWith('/converse')
              ? converseAnswer()
              : openAiCompletion();
        }),
      );

      await ask(client);
      target = const LlmTarget(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
      );
      await ask(client);

      // Late binding on the wire as well as on the URL: pointing a stage
      // somewhere moves the NEXT request, and never the one in flight.
      expect(sent.first.url.toString(), openAiUrl);
      expect(sent.last.url.toString(), endsWith('/converse'));
    });
  });

  group('the bearer comes off the target', () {
    test('and becomes the Authorization header', () async {
      final client = stageClient(
        () => const LlmTarget(
          baseUrl: openAiUrl,
          model: 'qwen3.8',
          bearer: token,
        ),
        answering(() async => openAiCompletion()),
      );

      await ask(client);

      expect(sent.single.headers['Authorization'], 'Bearer $token');
      // And the request itself is unchanged by it: a token is a header and
      // never a field.
      final body =
          jsonDecode((sent.single as http.Request).body) as Map<String, dynamic>;
      expect(jsonEncode(body), isNot(contains(token)));
    });

    test('a target with none sends none', () async {
      final client = stageClient(
        () => const LlmTarget(baseUrl: openAiUrl, model: 'qwen3.8'),
        answering(() async => openAiCompletion()),
      );

      await ask(client);

      expect(sent.single.headers.containsKey('Authorization'), isFalse);
    });

    test('the constructor\'s is the fallback, not the winner', () async {
      final client = LlmClient(
        baseUrl: 'http://127.0.0.1:1/never-dialled',
        model: 'never-sent',
        bearerToken: 'constructor-fixture-token',
        httpClient: answering(() async => openAiCompletion()),
        resolveTarget: () => const LlmTarget(
          baseUrl: openAiUrl,
          model: 'qwen3.8',
          bearer: token,
        ),
      );

      await ask(client);

      expect(sent.single.headers['Authorization'], 'Bearer $token');
    });

    test('a target with no bearer falls back to the constructor\'s', () async {
      final client = LlmClient(
        baseUrl: 'http://127.0.0.1:1/never-dialled',
        model: 'never-sent',
        bearerToken: token,
        httpClient: answering(() async => openAiCompletion()),
        resolveTarget: () =>
            const LlmTarget(baseUrl: openAiUrl, model: 'qwen3.8'),
      );

      await ask(client);

      expect(sent.single.headers['Authorization'], 'Bearer $token');
    });
  });

  group('the bearer reaches nothing else', () {
    /// Every string a record carries, so an assertion is about the whole
    /// record rather than the fields somebody remembered to check.
    String flatten(LlmCallRecord record) => [
          record.label,
          record.model,
          record.baseUrl,
          record.outcome,
          record.error,
        ].join('|');

    test('not a successful call\'s record', () async {
      final client = stageClient(
        () => const LlmTarget(
          baseUrl: openAiUrl,
          model: 'qwen3.8',
          bearer: token,
        ),
        answering(() async => openAiCompletion()),
      );

      await ask(client);

      expect(records.single.outcome, 'ok');
      expect(flatten(records.single), isNot(contains(token)));
      expect(records.single.baseUrl, openAiUrl);
    });

    test('not a rejected call\'s message or record', () async {
      final client = stageClient(
        () => const LlmTarget(
          baseUrl: openAiUrl,
          model: 'qwen3.8',
          bearer: token,
        ),
        answering(() async => json({'message': 'bad model name'}, 400)),
      );

      await expectLater(
        ask(client),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP 400'), isNot(contains(token))),
          ),
        ),
      );

      expect(records.single.outcome, 'error');
      expect(flatten(records.single), isNot(contains(token)));
    });

    test('not an unreachable server\'s message or record', () async {
      final client = stageClient(
        () => const LlmTarget(
          baseUrl: openAiUrl,
          model: 'qwen3.8',
          bearer: token,
        ),
        MockClient((_) async => throw const SocketException('refused')),
      );

      await expectLater(
        ask(client),
        throwsA(
          isA<LlmUnavailableException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('is not reachable'),
              // A token is a sign of somebody else's machine, which is what
              // decides the wording — and the wording must not quote it.
              contains('check the network'),
              isNot(contains(token)),
            ),
          ),
        ),
      );

      expect(records.single.outcome, 'unavailable');
      expect(flatten(records.single), isNot(contains(token)));
    });

    test('and not the string the target prints as', () async {
      const target = LlmTarget(
        baseUrl: openAiUrl,
        model: 'qwen3.8',
        bearer: token,
      );
      final client = stageClient(
        () => target,
        answering(() async => openAiCompletion()),
      );

      // `LlmTarget.toString` reaches logs and failure messages, so it says the
      // model and the URL and deliberately nothing else.
      expect(client.target.toString(), 'qwen3.8 @ $openAiUrl');
      expect(target.toString(), isNot(contains(token)));
      expect(client.baseUrl, openAiUrl);
      expect(client.model, 'qwen3.8');
    });
  });

  test('the nouns follow the target, not the client', () async {
    // A local server gets "start it, or change it in Settings"; somebody
    // else's does not, because a cloud endpoint is not something the reader
    // can go and launch. The client is the same one in both cases.
    final local = stageClient(
      () => const LlmTarget(baseUrl: openAiUrl, model: 'qwen3.8'),
      MockClient((_) async => throw const SocketException('refused')),
      observe: false,
    );
    await expectLater(
      ask(local),
      throwsA(
        isA<LlmUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('start it, or change it in Settings'),
        ),
      ),
    );

    final remote = stageClient(
      () => const LlmTarget(
        baseUrl: converseHost,
        model: converseModel,
        wire: LlmWire.bedrockConverse,
      ),
      MockClient((_) async => throw const SocketException('refused')),
      observe: false,
    );
    await expectLater(
      ask(remote),
      throwsA(
        isA<LlmUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('check the network and the URL'),
        ),
      ),
    );
  });
}
