import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The streamed draft call, against a server that only exists in this file.
///
/// The shape asserted below is llama-server's, probed at plan time rather than
/// guessed (build b10621): one `data:` line per token group, a chunk with an
/// empty delta and a finish reason, then ONE choices-less chunk carrying
/// `usage` and `timings`, then `data: [DONE]`. vLLM sends the same minus
/// `timings`. Everything else here is about the promise the method makes:
/// streaming changes the DELIVERY and nothing else — the same answer, the same
/// exceptions, one record on the observer.

/// One `data:` event, the way a server writes it: a blank line after each.
String event(Object? payload) =>
    'data: ${payload is String ? payload : jsonEncode(payload)}\n\n';

Map<String, Object?> contentChunk(String text) => {
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'content': text},
          'finish_reason': null,
        },
      ],
    };

/// The final chunk llama.cpp sends: no choices, both counter blocks.
Map<String, Object?> usageChunk({bool timings = true}) => {
      'object': 'chat.completion.chunk',
      'choices': <Object?>[],
      'usage': {'prompt_tokens': 1200, 'completion_tokens': 40},
      if (timings) 'timings': {'prompt_ms': 8800.5, 'predicted_ms': 2200.25},
    };

/// A client whose server answers with [lines], and the requests it saw.
({LlmClient client, List<Map<String, Object?>> bodies}) streamingClient(
  List<String> lines, {
  LlmCallObserver? onCall,
  LlmWire wire = LlmWire.openAi,
  Duration? timeout,
  int statusCode = 200,
}) {
  final bodies = <Map<String, Object?>>[];
  final client = LlmClient(
    baseUrl: 'http://localhost:9/v1/chat/completions',
    model: 'test-model',
    timeout: timeout,
    wire: wire,
    onCall: onCall,
    httpClient: MockClient.streaming((request, body) async {
      bodies.add(
        jsonDecode(await body.bytesToString()) as Map<String, Object?>,
      );
      return http.StreamedResponse(
        Stream.fromIterable(lines.map(utf8.encode)),
        statusCode,
      );
    }),
  );
  return (client: client, bodies: bodies);
}

/// A well-formed draft, delivered in four content deltas.
const List<String> draftDeltas = [
  '{"evidence":"Tom asks about Friday."',
  ',"options":[{"stance":"Accept","reply_body":"Friday works."}]',
  ',"reply_body":"Hi Tom,\\n\\nFriday works."',
  '}',
];

const Map<String, dynamic> draftSchema = {
  'type': 'object',
  'properties': {
    'evidence': {'type': 'string'},
    'options': {'type': 'array'},
    'reply_body': {'type': 'string'},
  },
  'required': ['evidence', 'options', 'reply_body'],
  'additionalProperties': false,
};

Future<Map<String, dynamic>> draft(
  LlmClient client, {
  required void Function(String) onText,
}) =>
    client.completeJsonStreamed(
      system: 'rules',
      user: 'thread',
      schema: draftSchema,
      schemaName: 'draft_reply',
      maxTokens: 768,
      temperature: 0,
      onText: onText,
    );

void main() {
  group('completeJsonStreamed', () {
    test('asks the server to stream, and to count while it does', () async {
      final fake = streamingClient([
        for (final delta in draftDeltas) event(contentChunk(delta)),
        event(usageChunk()),
        event('[DONE]'),
      ]);

      await draft(fake.client, onText: (_) {});

      final body = fake.bodies.single;
      expect(body['stream'], true);
      // Without this the last chunk carries no usage and the call cannot be
      // given a tokens-per-second number at all.
      expect(
        (body['stream_options'] as Map)['include_usage'],
        true,
      );
      // And everything the plain call sends is still on the wire.
      expect(body['max_tokens'], 768);
      expect(body['temperature'], 0);
      expect(
        ((body['response_format'] as Map)['json_schema'] as Map)['name'],
        'draft_reply',
      );
      expect(
        (body['chat_template_kwargs'] as Map)['enable_thinking'],
        false,
      );
    });

    test('hands over every delta in order and returns the whole object',
        () async {
      final fake = streamingClient([
        for (final delta in draftDeltas) event(contentChunk(delta)),
        event(usageChunk()),
        event('[DONE]'),
      ]);

      final seen = <String>[];
      final answer = await draft(fake.client, onText: seen.add);

      expect(seen, draftDeltas);
      expect(answer['evidence'], 'Tom asks about Friday.');
      expect(answer['reply_body'], 'Hi Tom,\n\nFriday works.');
      expect((answer['options'] as List).length, 1);
    });

    test('reads usage and timings off the choices-less last chunk', () async {
      final records = <LlmCallRecord>[];
      final fake = streamingClient(
        [
          for (final delta in draftDeltas) event(contentChunk(delta)),
          event(usageChunk()),
          event('[DONE]'),
        ],
        onCall: records.add,
      );

      await draft(fake.client, onText: (_) {});

      final record = records.single;
      expect(record.outcome, 'ok');
      expect(record.label, 'draft_reply');
      expect(record.promptTokens, 1200);
      expect(record.completionTokens, 40);
      // Doubles on the wire, whole milliseconds on the record.
      expect(record.serverPromptMs, 8800);
      expect(record.serverPredictedMs, 2200);
      expect(record.firstTokenMs, isNotNull);
      expect(record.firstTokenMs!, lessThanOrEqualTo(record.durationMs));
    });

    test('a stream that reported no usage leaves the counts null', () async {
      final records = <LlmCallRecord>[];
      final fake = streamingClient(
        [
          for (final delta in draftDeltas) event(contentChunk(delta)),
          event('[DONE]'),
        ],
        onCall: records.add,
      );

      await draft(fake.client, onText: (_) {});

      expect(records.single.promptTokens, isNull);
      expect(records.single.completionTokens, isNull);
      expect(records.single.serverPredictedMs, isNull);
      expect(records.single.outcome, 'ok');
    });

    test('a plain call reports no first token at all', () async {
      // The column has to stay honest: a call that did not stream has no
      // time-to-first-token, and a zero there would read as instant.
      final records = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        onCall: records.add,
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"pick":"alpha"}'},
                },
              ],
            }),
            200,
          );
        }),
      );

      await client.completeJson(
        system: 's',
        user: 'u',
        schema: const {
          'type': 'object',
          'properties': {
            'pick': {'type': 'string'},
          },
          'required': ['pick'],
        },
        schemaName: 'probe',
      );

      expect(records.single.outcome, 'ok');
      expect(records.single.firstTokenMs, isNull);
    });

    test('the reasoning tripwire fires once, not once per token', () async {
      final fake = streamingClient([
        for (var i = 0; i < 3; i++)
          event({
            'choices': [
              {
                'delta': {'reasoning_content': 'thinking hard'},
              },
            ],
          }),
        for (final delta in draftDeltas) event(contentChunk(delta)),
        event('[DONE]'),
      ]);
      var leaks = 0;
      fake.client.onReasoningLeak = () => leaks++;

      await draft(fake.client, onText: (_) {});

      expect(leaks, 1);
    });

    test('a 503 parks, a 429 parks, a 400 is fatal — as on the plain path',
        () async {
      for (final status in [503, 500]) {
        final fake = streamingClient(['weights loading'], statusCode: status);
        await expectLater(
          draft(fake.client, onText: (_) {}),
          throwsA(
            isA<LlmUnavailableException>().having(
              (e) => e.message,
              'message',
              contains('is not ready (HTTP $status)'),
            ),
          ),
        );
      }

      final throttled = streamingClient(['slow down'], statusCode: 429);
      await expectLater(
        draft(throttled.client, onText: (_) {}),
        throwsA(
          isA<LlmUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('is throttling requests'),
          ),
        ),
      );

      final rejected = streamingClient(['bad schema'], statusCode: 400);
      await expectLater(
        draft(rejected.client, onText: (_) {}),
        throwsA(
          isA<LlmException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('rejected the '
                  'request (HTTP 400)')),
        ),
      );
    });

    test('a mid-stream error object fails the call', () async {
      // The request was already 200 by then, so the only place a server can
      // say so is the stream itself.
      final fake = streamingClient([
        event(contentChunk('{"evidence":"')),
        event({
          'error': {'message': 'context shift failed'},
        }),
      ]);

      await expectLater(
        draft(fake.client, onText: (_) {}),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('failed mid-stream'),
          ),
        ),
      );
    });

    test('a stream that stops mid-object is a format failure, as a truncated '
        'plain answer is', () async {
      final records = <LlmCallRecord>[];
      final fake = streamingClient(
        [event(contentChunk('{"evidence":"Tom asks')), event('[DONE]')],
        onCall: records.add,
      );

      await expectLater(
        draft(fake.client, onText: (_) {}),
        throwsA(isA<LlmFormatException>()),
      );
      expect(records.single.outcome, 'format');
    });

    test('a stalled stream times out with the plain path\'s own message',
        () async {
      const short = Duration(milliseconds: 300);
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);

      final streaming = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        timeout: short,
        httpClient: MockClient.streaming(
          (request, body) async => http.StreamedResponse(stalled.stream, 200),
        ),
      );
      final plain = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        timeout: short,
        httpClient: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('{}', 200);
        }),
      );

      Object? streamedError;
      try {
        await draft(streaming, onText: (_) {});
      } catch (e) {
        streamedError = e;
      }
      Object? plainError;
      try {
        await plain.completeJson(
          system: 's',
          user: 'u',
          schema: draftSchema,
          schemaName: 'draft_reply',
        );
      } catch (e) {
        plainError = e;
      }

      expect(streamedError, isA<LlmException>());
      expect(streamedError, isNot(isA<LlmUnavailableException>()));
      expect('$streamedError', '$plainError');
    });

    test('a listener that throws costs its own preview, not the draft',
        () async {
      final fake = streamingClient([
        for (final delta in draftDeltas) event(contentChunk(delta)),
        event('[DONE]'),
      ]);

      final answer = await draft(
        fake.client,
        onText: (_) => throw StateError('the composer fell over'),
      );

      expect(answer['reply_body'], 'Hi Tom,\n\nFriday works.');
    });

    test('a line that is not JSON is skipped rather than fatal', () async {
      final fake = streamingClient([
        ': keep-alive comment\n\n',
        'data: {not json at all\n\n',
        for (final delta in draftDeltas) event(contentChunk(delta)),
        event('[DONE]'),
      ]);

      final answer = await draft(fake.client, onText: (_) {});

      expect(answer['evidence'], 'Tom asks about Friday.');
    });

    test('[DONE] ends the read, without waiting for the socket to close',
        () async {
      // A proxy that holds the connection open after the last event would
      // otherwise cost the whole ceiling on an answer already in hand.
      final never = StreamController<List<int>>();
      addTearDown(never.close);
      final records = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        timeout: const Duration(seconds: 30),
        onCall: records.add,
        httpClient: MockClient.streaming(
          (request, body) async => http.StreamedResponse(never.stream, 200),
        ),
      );

      final answer = draft(client, onText: (_) {});
      for (final delta in draftDeltas) {
        never.add(utf8.encode(event(contentChunk(delta))));
      }
      never.add(utf8.encode(event(usageChunk())));
      never.add(utf8.encode(event('[DONE]')));

      // No timeout, and no waiting on a stream that is still open.
      expect((await answer)['reply_body'], 'Hi Tom,\n\nFriday works.');
      expect(records.single.completionTokens, 40);
      expect(never.isClosed, isFalse);
    });

    test('the subscription is cancelled on every exit', () async {
      var cancelled = false;
      final source = StreamController<List<int>>();
      source.onCancel = () => cancelled = true;
      final client = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        httpClient: MockClient.streaming(
          (request, body) async => http.StreamedResponse(source.stream, 200),
        ),
      );

      final answer = draft(client, onText: (_) {});
      source.add(utf8.encode(event(contentChunk(draftDeltas.first))));
      source.add(utf8.encode(event(contentChunk(draftDeltas[1]))));
      // The connection drops mid-answer: the server said nothing about this
      // request, so it parks rather than costing the message.
      source.addError(http.ClientException('connection closed'));

      await expectLater(answer, throwsA(isA<LlmUnavailableException>()));
      expect(cancelled, isTrue);
    });

    test('an error body that never ends is bounded by the same ceiling',
        () async {
      // The error path has to be as unhangable as the answer path: a 500 whose
      // body is held open is the same wedged server.
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = LlmClient(
        baseUrl: 'http://localhost:9/v1/chat/completions',
        timeout: const Duration(milliseconds: 300),
        httpClient: MockClient.streaming(
          (request, stream) async => http.StreamedResponse(body.stream, 500),
        ),
      );

      await expectLater(
        draft(client, onText: (_) {}),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('did not answer within'),
          ),
        ),
      );
    });

    test('Converse has nothing to stream, so it sends one plain call',
        () async {
      final fake = streamingClient(
        [
          jsonEncode({
            'output': {
              'message': {
                'content': [
                  {
                    'toolUse': {
                      'input': {
                        'evidence': 'e',
                        'options': <Object?>[],
                        'reply_body': 'b',
                      },
                    },
                  },
                ],
              },
            },
          }),
        ],
        wire: LlmWire.bedrockConverse,
      );

      var called = false;
      final answer = await draft(fake.client, onText: (_) => called = true);

      expect(answer['reply_body'], 'b');
      expect(called, isFalse);
      // The seam is documented as degrading to a plain call, and a `stream`
      // key Bedrock never asked for would be an unknown field on that body.
      expect(fake.bodies.single.containsKey('stream'), isFalse);
      expect(fake.bodies.single.containsKey('stream_options'), isFalse);
    });
  });
}
