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
}
