import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_llama_server.dart';

/// Asking a server what it serves.
///
/// Two halves, tested apart on purpose. The URL derivation is pure and is
/// where a hand-typed address actually breaks, so it is pinned without a
/// socket. The reading of an answer is pinned against a real server for the
/// live case and a `MockClient` for the failures a real server will not
/// perform on demand.

void main() {
  group('modelsUrlFor', () {
    test('modelsUrlFor derives the listing endpoint', () {
      for (final (input, expected) in [
        (
          'http://localhost:8080/v1/chat/completions',
          'http://localhost:8080/v1/models',
        ),
        (
          'http://localhost:8081/v1/embeddings',
          'http://localhost:8081/v1/models',
        ),
        ('http://localhost:8080/v1', 'http://localhost:8080/v1/models'),
        ('http://h:8080', 'http://h:8080/v1/models'),
        ('http://h:8080/', 'http://h:8080/v1/models'),
        (
          'http://h/proxy/v1/chat/completions',
          'http://h/proxy/v1/models',
        ),
        // Query and fragment belong to the endpoint that was typed, not to
        // the listing this derives.
        (
          'http://h:8080/v1/chat/completions?key=abc#frag',
          'http://h:8080/v1/models',
        ),
        // Trimmed, because a pasted URL carries whitespace.
        (
          '  http://h:8080/v1/chat/completions  ',
          'http://h:8080/v1/models',
        ),
      ]) {
        expect(ModelServerProbe.modelsUrlFor(input).toString(), expected,
            reason: input);
      }
    });

    test('modelsUrlFor refuses what it cannot read', () {
      for (final input in [
        '',
        '   ',
        'not a url',
        'ftp://h/v1/chat',
        // Ollama's native path. Guessing a listing endpoint from it would
        // probe a stranger; saying no is the honest answer.
        'http://h/api/generate',
      ]) {
        expect(ModelServerProbe.modelsUrlFor(input), isNull, reason: input);
      }
    });
  });

  group('probe', () {
    test('a live server lists what it loaded', () async {
      final fake = await FakeLlamaServer.start();
      addTearDown(fake.close);
      fake.modelIds = ['qwen3.8', 'qwen3-4b'];
      final probe = ModelServerProbe();
      addTearDown(probe.close);

      final result = await probe.probe(fake.chatUrl);

      expect(result.reachable, isTrue);
      expect(result.modelIds, ['qwen3.8', 'qwen3-4b']);
      expect(result.error, isNull);
      expect(result.probedUrl.toString(), fake.modelsUrl);
    });

    test('a closed port is not reachable', () async {
      final probe = ModelServerProbe();
      addTearDown(probe.close);

      final result = await probe.probe('http://127.0.0.1:1/v1/chat/completions');

      expect(result.reachable, isFalse);
      expect(result.modelIds, isEmpty);
      expect(result.error, isNotNull);
    });

    test('a non-200 is not reachable', () async {
      final probe = ModelServerProbe(
        httpClient: MockClient((_) async => http.Response('nope', 404)),
      );

      final result = await probe.probe('http://h:8080/v1/chat/completions');

      expect(result.reachable, isFalse);
      expect(result.error, contains('404'));
    });

    test('a body that is not JSON is not reachable', () async {
      final probe = ModelServerProbe(
        httpClient: MockClient((_) async => http.Response('<html>', 200)),
      );

      final result = await probe.probe('http://h:8080/v1/chat/completions');

      expect(result.reachable, isFalse);
      expect(result.error, contains('JSON'));
    });

    test('a 200 with no list is not reachable', () async {
      final probe = ModelServerProbe(
        httpClient: MockClient((_) async => http.Response('{"ok": true}', 200)),
      );

      final result = await probe.probe('http://h:8080/v1/chat/completions');

      expect(result.reachable, isFalse);
      expect(result.modelIds, isEmpty);
      expect(result.error, isNotNull);
    });

    test('an empty list is still reachable', () async {
      final probe = ModelServerProbe(
        httpClient: MockClient((_) async => http.Response('{"data": []}', 200)),
      );

      final result = await probe.probe('http://h:8080/v1/chat/completions');

      // A live server with nothing loaded is a different thing from a server
      // that is not there, and the screen has to be able to say so.
      expect(result.reachable, isTrue);
      expect(result.modelIds, isEmpty);
      expect(result.error, isNull);
    });

    test('a timeout is not reachable', () async {
      final probe = ModelServerProbe(
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return http.Response('{"data": []}', 200);
        }),
      );

      final result = await probe.probe('http://h:8080/v1/chat/completions');

      expect(result.reachable, isFalse);
      expect(result.error, contains('No answer'));
    });

    test('a URL it cannot read is refused without a request', () async {
      var asked = false;
      final probe = ModelServerProbe(
        httpClient: MockClient((_) async {
          asked = true;
          return http.Response('{"data": []}', 200);
        }),
      );

      final result = await probe.probe('http://h/api/generate');

      expect(result.reachable, isFalse);
      expect(result.probedUrl, isNull);
      expect(asked, isFalse);
    });
  });
}
