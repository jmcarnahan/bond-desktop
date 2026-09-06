import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_llama_server.dart';

/// Which socket the POST lands on, and under which name.
///
/// Real loopback servers rather than a fake `http.Client`: the whole claim of
/// late binding is about the URL a request is sent to, and only a socket can
/// answer that. Two servers make the claim falsifiable — a client that ignored
/// its resolver would still succeed against one.

/// The address nothing listens on. Constructed into every client whose
/// resolver is supposed to be the thing that decides, so a resolver that was
/// skipped fails loudly instead of quietly working.
const String neverDialled = 'http://127.0.0.1:1/never-dialled';

Map<String, dynamic> answer() => {'ok': true};

Future<Map<String, dynamic>> ask(LlmClient client) => client.completeJson(
      system: 'system',
      user: 'user',
      schema: const {'type': 'object'},
      schemaName: 'probe',
    );

void main() {
  late FakeLlamaServer a;
  late FakeLlamaServer b;

  setUp(() async {
    a = await FakeLlamaServer.start();
    b = await FakeLlamaServer.start();
    a.scriptFor('probe', [answer()]);
    b.scriptFor('probe', [answer()]);
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('a client with no resolver posts where it was constructed', () async {
    final client = LlmClient(baseUrl: a.chatUrl, model: 'built-in');

    await ask(client);

    expect(a.requests.single['model'], 'built-in');
    expect(b.requests, isEmpty);
  });

  test('the resolver decides the URL and the model', () async {
    var target = LlmTarget(baseUrl: a.chatUrl, model: 'model-a');
    final client = LlmClient(
      baseUrl: neverDialled,
      model: 'never-sent',
      resolveTarget: () => target,
    );

    await ask(client);

    expect(a.requests.single['model'], 'model-a');
    expect(b.requests, isEmpty);
  });

  test('a change applies to the next call, not the one in flight', () async {
    var target = LlmTarget(baseUrl: a.chatUrl, model: 'model-a');
    final client = LlmClient(
      baseUrl: neverDialled,
      model: 'never-sent',
      resolveTarget: () => target,
    );

    await ask(client);
    target = LlmTarget(baseUrl: b.chatUrl, model: 'model-b');
    await ask(client);

    expect(a.requests, hasLength(1));
    expect(b.requests.single['model'], 'model-b');
    // And the getter follows the resolver, which is what the settings screen
    // and `llm_routing_test.dart` read.
    expect(client.baseUrl, b.chatUrl);
    expect(client.model, 'model-b');
  });

  test('a resolver that throws falls back to the constructed target', () async {
    final client = LlmClient(
      baseUrl: a.chatUrl,
      model: 'built-in',
      resolveTarget: () => throw StateError('gone'),
    );

    // The call succeeds rather than propagating the resolver's failure: a
    // container torn down mid-drain must degrade to the compiled default.
    await ask(client);

    expect(a.requests.single['model'], 'built-in');
    expect(client.baseUrl, a.chatUrl);
  });

  test('the record names the model and the URL', () async {
    final records = <LlmCallRecord>[];
    final client = LlmClient(
      baseUrl: neverDialled,
      model: 'never-sent',
      resolveTarget: () => LlmTarget(baseUrl: a.chatUrl, model: 'model-a'),
      onCall: records.add,
    );

    await ask(client);

    expect(records.single.outcome, 'ok');
    expect(records.single.model, 'model-a');
    expect(records.single.baseUrl, a.chatUrl);

    // And a failure carries them too — the row for a call that never landed
    // still has to say which server it was aimed at.
    records.clear();
    a.scriptFor('probe', [FakeLlamaServer.drop]);
    await expectLater(ask(client), throwsA(isA<LlmUnavailableException>()));

    expect(records.single.outcome, 'unavailable');
    expect(records.single.model, 'model-a');
    expect(records.single.baseUrl, a.chatUrl);
  });

  test('both halves of a target move together', () async {
    // A resolver that answers differently every time it is asked. If the
    // client read the target twice per request — once for the body's model
    // name, once for the URL — a request would arrive at one server carrying
    // the other's name, which is an HTTP 400 on a runtime that routes on it.
    var asked = 0;
    final client = LlmClient(
      baseUrl: neverDialled,
      model: 'never-sent',
      resolveTarget: () {
        final even = asked++ % 2 == 0;
        return even
            ? LlmTarget(baseUrl: a.chatUrl, model: 'model-a')
            : LlmTarget(baseUrl: b.chatUrl, model: 'model-b');
      },
    );

    for (var i = 0; i < 4; i++) {
      await ask(client);
    }

    expect(asked, 4, reason: 'resolved once per request, not twice');
    for (final request in a.requests) {
      expect(request['model'], 'model-a');
    }
    for (final request in b.requests) {
      expect(request['model'], 'model-b');
    }
    expect(a.requests, hasLength(2));
    expect(b.requests, hasLength(2));
  });
}
