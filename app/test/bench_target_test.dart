import 'dart:convert';

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/bench_target.dart';

/// The two pieces of a bench target that can be typed wrong.
///
/// Everything else on [BenchTarget] is a string handed straight to an HTTP
/// client, which fails loudly and immediately when it is wrong. `BENCH_K` is
/// parsed, and a parse that was lenient about a stray comma would drop a round
/// from a drain race — leaving a table that looks complete, reads plausibly,
/// and is missing the concurrency the whole run was for. `BENCH_WIRE` is the
/// other: it picks which request shape a run puts on the wire, and a lenient
/// reading would send one endpoint the other one's body. The live benches are
/// the only callers and they run on a machine with a model server, so this is
/// the only place either failure can be caught before someone quotes a table.

void main() {
  group('BENCH_WIRE', () {
    test('names one of the two wires there are', () {
      expect(parseWire('openai'), LlmWire.openAi);
      expect(parseWire('converse'), LlmWire.bedrockConverse);
    });

    test('refuses a name that is nearly one of them', () {
      // Every one of these has an obvious intent and no safe guess: an
      // OpenAI body posted to a Converse endpoint answers 404, and the run
      // would read as a broken candidate rather than a mistyped define.
      for (final garbage in ['', 'Converse', 'bedrock', 'openAI', 'json']) {
        expect(() => parseWire(garbage), throwsArgumentError,
            reason: 'BENCH_WIRE=$garbage');
      }
    });

    test('a target says openai unless it was told otherwise', () {
      const target = BenchTarget(
        slot: 'bulk',
        label: 'local',
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3-4b',
      );
      expect(target.wireName, 'openai');
      expect(target.wire, LlmWire.openAi);
    });

    test('a converse target posts to the model path it names', () async {
      const target = BenchTarget(
        slot: 'prose',
        label: 'bedrock/claude-haiku-4-5',
        url: 'https://bedrock-runtime.example.com',
        model: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
        wireName: 'converse',
      );
      expect(target.wire, LlmWire.bedrockConverse);

      final urls = <String>[];
      final client = target.client(
        httpClient: MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response(
            jsonEncode(const {
              'output': {
                'message': {
                  'role': 'assistant',
                  'content': [
                    {'text': 'ok'},
                  ],
                },
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      await client.complete(system: 's', user: 'u');

      expect(urls.single,
          'https://bedrock-runtime.example.com/model/'
          'us.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse');
    });

    test('the key goes to Bedrock hosts and nowhere else', () {
      // The key belongs to the cloud account, so a `.env` that carries one
      // must not change a single byte of what any other run sends — local,
      // LAN, a `.local` name, or a host that merely contains the word.
      const key = 'test-key';
      expect(
        bearerFor(
          'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions',
          key,
        ),
        key,
      );
      expect(bearerFor('https://bedrock-runtime.us-east-1.amazonaws.com', key),
          key);
      for (final other in [
        'http://localhost:8082/v1/chat/completions',
        'http://127.0.0.1:8082/v1/chat/completions',
        'http://0.0.0.0:8082/v1/chat/completions',
        'http://192.168.1.20:8082/v1/chat/completions',
        'http://studio.local:8082/v1/chat/completions',
        'https://amazonaws.com.example.com/v1/chat/completions',
        'https://notamazonaws.com/v1/chat/completions',
        'not a url',
      ]) {
        expect(bearerFor(other, key), isNull, reason: other);
      }
      // No key at all is no key anywhere.
      expect(bearerFor('https://bedrock-runtime.us-east-1.amazonaws.com', ''),
          isNull);
    });

    test('a target reads its key through the same guard', () {
      const local = BenchTarget(
        slot: 'bulk',
        label: 'local',
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3-4b',
      );
      expect(local.bearerToken, isNull);
      // With no BENCH_BEARER define — the gate's own case — a remote target
      // has none either; the guard above is what a defined key goes through.
      expect(BenchTarget.bearer, isEmpty);
    });
  });

  group('BENCH_K', () {
    test('reads the rounds in the order they are written', () {
      // Order is preserved rather than sorted: the drain divides every later
      // round's speedup by the K=1 wall, and a run written `3,1` deliberately
      // races the warm machine first.
      expect(parseDrainK('1,3'), [1, 3]);
      expect(parseDrainK(' 1 , 3 , 6 '), [1, 3, 6]);
      expect(parseDrainK('4'), [4]);
    });

    test('defaults to the shipping pair', () {
      expect(parseDrainK(), [1, 3]);
    });

    test('refuses anything it would have to guess about', () {
      // Each of these has a plausible lenient reading, and every one of those
      // readings silently runs fewer rounds than were asked for.
      for (final garbage in ['1,3,', '1;3', '1,three', '0,3', '-1', '', '1,0']) {
        expect(() => parseDrainK(garbage), throwsArgumentError,
            reason: 'BENCH_K=$garbage');
      }
    });
  });
}
