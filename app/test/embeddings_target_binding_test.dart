import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_test/flutter_test.dart';

/// Late binding for the embedding client: which server a request lands on, and
/// what it calls the model when it gets there.
///
/// Two real loopback servers rather than a mocked http client, because the
/// property under test is that the URL AND the model field move together — a
/// resolver that answered the new port with the old model name would look
/// correct to anything that only checked one of them, and would ask a router
/// for a model it does not serve.

/// A loopback server that records the `model` of every request and answers a
/// one-element embedding.
class _Recorder {
  final HttpServer server;
  final List<String> models = [];

  _Recorder(this.server) {
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      models.add('${(body as Map)['model']}');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'data': [
            {'embedding': [0.5]},
          ],
        }));
      await request.response.close();
    });
  }

  static Future<_Recorder> start() async =>
      _Recorder(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get url => 'http://127.0.0.1:${server.port}/v1/embeddings';

  Future<void> close() => server.close(force: true);
}

void main() {
  test('each call lands on the server the resolver named, with its model',
      () async {
    final first = await _Recorder.start();
    final second = await _Recorder.start();
    addTearDown(first.close);
    addTearDown(second.close);

    var onSecond = false;
    final client = EmbeddingsClient(
      resolveTarget: () => onSecond
          ? LlmTarget(baseUrl: second.url, model: 'bond-embed')
          : LlmTarget(baseUrl: first.url, model: 'embed'),
    );

    expect((await client.embedResult('one')).outcome, EmbedOutcome.ok);
    onSecond = true;
    expect((await client.embedResult('two')).outcome, EmbedOutcome.ok);

    expect(first.models, ['embed']);
    expect(second.models, ['bond-embed']);
  });

  test('with no resolver it is the constructed URL and the old model name',
      () async {
    final server = await _Recorder.start();
    addTearDown(server.close);

    final client = EmbeddingsClient(baseUrl: server.url);
    expect(client.target, LlmTarget(baseUrl: server.url, model: 'embed'));

    expect((await client.embedResult('one')).outcome, EmbedOutcome.ok);
    expect(server.models, [EmbeddingsClient.requestModel]);
  });

  test('a resolver that throws falls back to the constructed target', () async {
    final server = await _Recorder.start();
    addTearDown(server.close);

    final client = EmbeddingsClient(
      baseUrl: server.url,
      resolveTarget: () => throw StateError('container gone'),
    );

    expect((await client.embedResult('one')).outcome, EmbedOutcome.ok);
    expect(server.models, ['embed']);
  });

  test('describeUnavailable replaces the make-embed advice', () async {
    // A port nothing is listening on: bound, read for its number, released.
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dead = 'http://127.0.0.1:${probe.port}/v1/embeddings';
    await probe.close(force: true);

    final managed = EmbeddingsClient(
      baseUrl: dead,
      describeUnavailable: () =>
          'is not running — see Settings › Models › Local server',
    );
    final result = await managed.embedResult('one');
    expect(result.outcome, EmbedOutcome.unavailable);
    expect(
      result.reason,
      'is not running — see Settings › Models › Local server',
    );
  });

  test('a describer that answers null keeps the default sentence', () async {
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dead = 'http://127.0.0.1:${probe.port}/v1/embeddings';
    await probe.close(force: true);

    final client = EmbeddingsClient(
      baseUrl: dead,
      describeUnavailable: () => null,
    );
    final result = await client.embedResult('one');
    expect(result.outcome, EmbedOutcome.unavailable);
    expect(result.reason, 'is not reachable — run: make embed');
  });

  test('a describer that throws keeps the default sentence too', () async {
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dead = 'http://127.0.0.1:${probe.port}/v1/embeddings';
    await probe.close(force: true);

    final client = EmbeddingsClient(
      baseUrl: dead,
      describeUnavailable: () => throw StateError('container gone'),
    );
    expect(
      (await client.embedResult('one')).reason,
      'is not reachable — run: make embed',
    );
  });
}
