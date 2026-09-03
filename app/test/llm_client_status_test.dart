import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How [LlmClient] classifies non-200 answers. The distinction carries the
/// whole failure policy: [LlmUnavailableException] parks the drain and leaves
/// every queued item pending, while a plain [LlmException] is counted against
/// the ITEM — so misreading "the server is not ready yet" as an item failure
/// errors an entire backlog in seconds (llama-server answers 503 to every
/// request while its weights load).
void main() {
  LlmClient clientAnswering(int status, [String body = '']) => LlmClient(
        baseUrl: 'http://127.0.0.1:1/v1/chat/completions',
        httpClient: MockClient((_) async => http.Response(body, status)),
      );

  Future<String> ask(LlmClient client) =>
      client.complete(system: 's', user: 'u');

  test('a 503 while the model loads parks the drain, costing no item', () {
    final client =
        clientAnswering(503, '{"error":{"code":503,"message":"Loading model"}}');
    expect(ask(client), throwsA(isA<LlmUnavailableException>()));
  });

  test('any 5xx is the server\'s condition, not the request\'s', () {
    expect(ask(clientAnswering(500)), throwsA(isA<LlmUnavailableException>()));
    expect(ask(clientAnswering(502)), throwsA(isA<LlmUnavailableException>()));
  });

  test('a 400 stays an item failure — it is always this app\'s bug', () {
    final client = clientAnswering(400, 'schema conversion failed');
    expect(
      ask(client),
      throwsA(isA<LlmException>()
          .having((e) => e, 'type', isNot(isA<LlmUnavailableException>()))
          .having((e) => e.statusCode, 'statusCode', 400)),
    );
  });

  /// What the observer sees. It is the activity log's only source of model
  /// numbers, and it fires on the way out of every path above — so a failure
  /// that skipped it would silently cost the panel a whole class of event.
  group('the call observer', () {
    late List<LlmCallRecord> seen;

    setUp(() => seen = []);

    LlmClient watching(Future<http.Response> Function() respond) => LlmClient(
          baseUrl: 'http://127.0.0.1:1/v1/chat/completions',
          httpClient: MockClient((_) => respond()),
          onCall: seen.add,
        );

    http.Response completion({
      Map<String, Object?>? usage,
      Map<String, Object?>? timings,
    }) =>
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '{"ok":true}'}
              }
            ],
            'usage': ?usage,
            'timings': ?timings,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );

    test('a success carries the schema name and the token counts', () async {
      final client = watching(() async => completion(
            usage: const {'prompt_tokens': 812, 'completion_tokens': 47},
          ));

      await client.completeJson(
        system: 's',
        user: 'u',
        schema: const {'type': 'object'},
        schemaName: 'triage',
      );

      expect(seen.single.label, 'triage');
      expect(seen.single.outcome, 'ok');
      expect(seen.single.promptTokens, 812);
      expect(seen.single.completionTokens, 47);
      expect(seen.single.durationMs, isNonNegative);
    });

    test('a response with no usage block reports no tokens', () async {
      final client = watching(() async => completion());

      await client.completeJson(
        system: 's',
        user: 'u',
        schema: const {'type': 'object'},
      );

      expect(seen.single.label, 'result');
      expect(seen.single.promptTokens, isNull);
      expect(seen.single.completionTokens, isNull);
    });

    test('llama-server\'s own timings arrive as doubles and survive it',
        () async {
      // The real server sends these as doubles, not ints. A parse that read
      // them with `as int?` would return null against every live server while
      // passing any fixture that sent whole numbers — so the fixture sends
      // what the server sends.
      final client = watching(() async => completion(
            usage: const {'prompt_tokens': 812, 'completion_tokens': 47},
            timings: const {'prompt_ms': 90.5, 'predicted_ms': 3800.0},
          ));

      await client.complete(system: 's', user: 'u');

      expect(seen.single.serverPromptMs, 90);
      expect(seen.single.serverPredictedMs, 3800);
    });

    test('a runtime that sends no timings still reports its tokens', () async {
      // An MLX-based server answers with usage and no timings at all. The
      // bench falls back to wall-clock speed for it, which only works if the
      // absence reads as null rather than as zero milliseconds.
      final client = watching(() async => completion(
            usage: const {'prompt_tokens': 812, 'completion_tokens': 47},
          ));

      await client.complete(system: 's', user: 'u');

      expect(seen.single.promptTokens, 812);
      expect(seen.single.serverPromptMs, isNull);
      expect(seen.single.serverPredictedMs, isNull);
    });

    test('free text is labelled by the call, not by a schema', () async {
      final client = watching(() async => completion());

      await client.complete(system: 's', user: 'u');

      expect(seen.single.label, 'complete');
      expect(seen.single.outcome, 'ok');
    });

    test('a server that is not running reports unavailable', () async {
      final client = watching(() async => throw const SocketException('refused'));

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(seen.single.outcome, 'unavailable');
      expect(seen.single.statusCode, isNull);
    });

    test('a 5xx reports unavailable too — it is the server, not the item',
        () async {
      final client = watching(() async => http.Response('loading', 503));

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(seen.single.outcome, 'unavailable');
    });

    test('a 400 reports the status code alongside the error', () async {
      final client = watching(() async => http.Response('bad schema', 400));

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmException>()),
      );

      expect(seen.single.outcome, 'error');
      expect(seen.single.statusCode, 400);
      expect(seen.single.error, contains('bad schema'));
    });

    test('an answer that is not JSON reports format', () async {
      final client = watching(() async => http.Response('<html>oops</html>', 200));

      await expectLater(
        client.complete(system: 's', user: 'u'),
        throwsA(isA<LlmFormatException>()),
      );

      expect(seen.single.outcome, 'format');
    });

    test('the observer fires once per round trip, never twice', () async {
      final client = watching(() async => completion());

      await client.complete(system: 's', user: 'u');
      await client.complete(system: 's', user: 'u');

      expect(seen, hasLength(2));
    });
  });
}
