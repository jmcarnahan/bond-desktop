import 'dart:convert';

import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/decision_heads_fixture.dart';

/// `DecisionClient.embedRaw`: the calendar command head's raw vectors, under
/// every wire rule the nine heads' own call keeps (app/CLAUDE.md, the
/// decision client).
void main() {
  const url = 'http://127.0.0.1:8083/v1/embeddings';
  const modernBertA = [DecisionClient.clsId, 64, DecisionClient.sepId];

  late List<Map<String, dynamic>> embeds;
  late int probes;
  late List<LlmCallRecord> records;

  /// A distinct raw vector per text: its length on axis 0, ballast so the
  /// norm is far from 1.
  List<double> vectorFor(String text) =>
      syntheticVector({0: text.length.toDouble()});

  late http.Response Function(Map<String, dynamic> body)? onEmbed;

  MockClient server() => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/tokenize')) {
          probes++;
          return http.Response(jsonEncode({'tokens': modernBertA}), 200);
        }
        embeds.add(body);
        final answer = onEmbed;
        if (answer != null) return answer(body);
        final input = body['input'];
        final texts = input is String ? [input] : (input as List).cast<String>();
        return http.Response(
          jsonEncode({
            'data': [
              for (final (i, t) in texts.indexed)
                {'index': i, 'embedding': vectorFor(t)},
            ],
          }),
          200,
        );
      });

  DecisionClient client() => DecisionClient(
        resolveTarget: () =>
            const LlmTarget(baseUrl: url, model: 'bond-decide'),
        heads: syntheticHeads,
        client: server(),
        onCall: records.add,
      );

  setUp(() {
    embeds = [];
    probes = 0;
    records = [];
    onEmbed = null;
  });

  test('sends the text as the input, raw vectors asked for', () async {
    await client().embedRaw(['move my 3pm with Dana Contoso to friday']);
    expect(probes, 1, reason: 'the identity probe goes first');
    expect(embeds.single, {
      'model': 'bond-decide',
      'input': 'move my 3pm with Dana Contoso to friday',
      'embd_normalize': -1,
    });
  });

  test('two texts come back as two vectors, in order, with one record',
      () async {
    final c = client();
    final vectors = await c.embedRaw(['decline the offsite', 'am I free?']);
    expect(vectors, hasLength(2));
    expect(vectors[0], vectorFor('decline the offsite'));
    expect(vectors[1], vectorFor('am I free?'));
    expect(vectors.every((v) => v.length == syntheticHidden), isTrue);
    expect(records, hasLength(1));
    expect(records.single.label, 'command_head');
    expect(records.single.outcome, 'ok');

    // The probe passed once for this target and is not asked again.
    await c.embedRaw(['book lunch with Sam Fabrikam']);
    expect(probes, 1);
  });

  test('report: false tells the observer nothing', () async {
    await client().embedRaw(['cancel standup'], report: false);
    expect(records, isEmpty);
  });

  test('no texts, no request', () async {
    expect(await client().embedRaw(const []), isEmpty);
    expect(probes, 0);
    expect(embeds, isEmpty);
  });

  test('a normalised vector is refused as the server ignoring the field',
      () async {
    onEmbed = (_) {
      final v = List<double>.filled(syntheticHidden, 0.0)..[0] = 1.0;
      return http.Response(
          jsonEncode({
            'data': [
              {'index': 0, 'embedding': v},
            ],
          }),
          200);
    };
    await expectLater(client().embedRaw(['move my 3pm']),
        throwsA(isA<DecisionMisconfiguredException>()));
    expect(records.single.outcome, 'unavailable');
  });

  test('a 503 is the decision server not answering', () async {
    onEmbed = (_) => http.Response('loading model', 503);
    await expectLater(client().embedRaw(['move my 3pm']),
        throwsA(isA<DecisionUnavailableException>()));
  });
}
