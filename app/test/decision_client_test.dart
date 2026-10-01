import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:math' as math;

import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
import 'package:bond_inbox/services/decision/storyline_state.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/decision_heads_fixture.dart';

const String _url = 'http://127.0.0.1:8083/v1/embeddings';
const String _tokenizeUrl = 'http://127.0.0.1:8083/tokenize';
const String _bearer = 'sk-decide-fixture-7c1f';

/// What llama-server says when an input is over its context.
const String _tooLargeBody =
    '{"error":{"code":500,"message":"input (2791 tokens) is too large to '
    'process. increase the physical batch size","type":"server_error"}}';

/// The vector the fake answers for a text: `gate: drop` when the text says
/// DROP, `gate: keep` otherwise — so a test can tell which answer went with
/// which input.
List<double> _vectorForText(String text) => syntheticVector({
      axisOf('gate', text.contains('DROP') ? 1 : 0): 2.0,
    });

/// The vector for a token-array input: `intent: fyi`, which no text gets.
List<double> _vectorForIds() => syntheticVector({axisOf('intent', 4): 3.0});

/// What ModernBERT's `/tokenize` answers for `"a"` with the specials added.
const List<int> _modernBertA = [DecisionClient.clsId, 64, DecisionClient.sepId];

/// A decision server that records every request and answers on script.
///
/// The identity probe (`/tokenize` with `add_special: true`) is recorded in
/// [probes] and NOT in [requests]: every client probes once before its first
/// embedding, and the cases below are about the requests that follow it.
class _FakeDecide {
  final List<http.Request> requests = [];

  /// Every identity probe, in order.
  final List<http.Request> probes = [];

  /// What the probe answers: ModernBERT's ids by default.
  List<int> probeTokens = _modernBertA;

  /// The probe's HTTP status, when not 200.
  int? probeStatus;

  /// Thrown by the probe alone, when set.
  Object? probeError;

  /// The embed endpoint's answer, given the decoded body. Null → the default:
  /// a raw vector per input.
  http.Response Function(Map<String, dynamic> body)? onEmbed;

  /// The ids `/tokenize` returns.
  List<int> tokens = [for (var i = 1; i <= 3000; i++) i];

  /// Thrown instead of answering, when set.
  Object? transportError;

  /// Never answers, when true.
  bool hang = false;

  /// The listing's HTTP status, when not 200.
  int? listingStatus;

  /// Every `GET …/v1/models` (a kind check), in order. Not in [requests].
  final List<http.Request> listings = [];

  /// What the listing answers: llama-server's shape, no `qhash`.
  Map<String, Object?> listing = const {
    'models': [
      {'name': 'bond-decide', 'model': 'bond-decide'},
    ],
    'object': 'list',
    'data': [
      {'id': 'bond-decide', 'object': 'model'},
    ],
  };

  List<http.Request> get embeds => [
        for (final r in requests)
          if (r.url.path.endsWith('/embeddings')) r,
      ];
  List<http.Request> get tokenizes => [
        for (final r in requests)
          if (r.url.path.endsWith('/tokenize')) r,
      ];

  static Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  static http.Response vectors(List<Object?> inputs) => http.Response(
        jsonEncode({
          'object': 'list',
          'data': [
            for (final (i, input) in inputs.indexed)
              {
                'object': 'embedding',
                'index': i,
                'embedding':
                    input is String ? _vectorForText(input) : _vectorForIds(),
              },
          ],
        }),
        200,
      );

  /// The inputs a body carries: one string, a list of strings, or ONE id
  /// list.
  static List<Object?> inputsOf(Map<String, dynamic> body) {
    final input = body['input'];
    if (input is String) return [input];
    final list = input as List;
    if (list.isNotEmpty && list.first is int) return [list];
    return list;
  }

  static bool isProbe(http.Request r) =>
      r.url.path.endsWith('/tokenize') && bodyOf(r)['add_special'] == true;

  MockClient get client => MockClient((request) async {
        if (request.method == 'GET') {
          listings.add(request);
          final status = listingStatus;
          if (status != null) return http.Response('Not Found', status);
          return http.Response(jsonEncode(listing), 200);
        }
        if (isProbe(request)) {
          probes.add(request);
          if (probeError != null) throw probeError!;
        } else {
          requests.add(request);
        }
        if (transportError != null) throw transportError!;
        if (hang) return Completer<http.Response>().future;
        final body = bodyOf(request);
        if (isProbe(request)) {
          return http.Response(
              jsonEncode({'tokens': probeTokens}), probeStatus ?? 200);
        }
        if (request.url.path.endsWith('/tokenize')) {
          return http.Response(jsonEncode({'tokens': tokens}), 200);
        }
        return onEmbed?.call(body) ?? vectors(inputsOf(body));
      });
}

DecisionInput _input(String body, {String subject = 'Venue list'}) =>
    DecisionInput(
      owner: 'Rivera, Sam <sam.rivera@example.org>',
      source: 'email',
      fromName: 'Dana Whitfield',
      fromAddress: 'dana@example.com',
      subject: subject,
      receivedAt: '2026-09-15T17:05:00Z',
      bodyText: body,
      addressedMe: true,
      toCount: 1,
    );

/// A state over [DecisionClient.longStateChars] UTF-16 units. The body cap is
/// 4000 CODE POINTS, so only text outside the BMP gets a state this long:
/// 4000 emoji are 8000 units.
DecisionInput _longInput() => _input('\u{1F4E6}' * 4000);

DateTime _pacific(DateTime utc) => utc.add(const Duration(hours: -7));

void main() {
  late _FakeDecide server;
  late List<LlmCallRecord> records;
  late LlmTarget target;

  DecisionClient client({
    LlmTarget Function()? resolve,
    void Function(LlmCallRecord)? onCall,
    Duration timeout = const Duration(seconds: 15),
  }) =>
      DecisionClient(
        resolveTarget: resolve ?? () => target,
        heads: syntheticHeads,
        client: server.client,
        onCall: onCall ?? records.add,
        timeout: timeout,
        toLocal: _pacific,
      );

  setUp(() {
    server = _FakeDecide();
    records = [];
    target = const LlmTarget(baseUrl: _url, model: 'bond-decide');
  });

  group('the request', () {
    test('POSTs the rendered state as one string, raw vectors asked for',
        () async {
      final input = _input('Could you send the list?');
      await client().decide(input);

      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), _url);
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(_FakeDecide.bodyOf(request), {
        'model': 'bond-decide',
        'input': renderDecisionState(input, toLocal: _pacific),
        'embd_normalize': -1,
      });
    });

    test('carries the bearer only when the target has one', () async {
      await client().decide(_input('a'));
      expect(server.requests.last.headers.containsKey('Authorization'), false);

      target = const LlmTarget(baseUrl: _url, model: 'm', bearer: '');
      await client().decide(_input('a'));
      expect(server.requests.last.headers.containsKey('Authorization'), false);

      target = const LlmTarget(baseUrl: _url, model: 'm', bearer: _bearer);
      await client().decide(_input('a'));
      expect(server.requests.last.headers['Authorization'], 'Bearer $_bearer');
    });

    test('a throwing resolver falls back to the compiled default', () async {
      await client(resolve: () => throw StateError('container gone'))
          .decide(_input('a'));
      expect(server.requests.single.url.toString(), DecisionClient.defaultBaseUrl);
      expect(_FakeDecide.bodyOf(server.requests.single)['model'],
          DecisionClient.defaultModel);
    });
  });

  group('the answer', () {
    test('a raw vector becomes the heads\' answers, with the state it read',
        () async {
      final input = _input('Please DROP this one.');
      final result = await client().decide(input);
      expect(result.answers['gate'].choice, 'drop');
      expect(result.state, renderDecisionState(input, toLocal: _pacific));
      expect(result.model, 'bond-decide-synthetic');
      expect(result.truncated, false);
      expect(result.latencyMs, greaterThanOrEqualTo(0));
      // The raw vector rides on the result, for the owner's Needs You labels.
      final state = renderDecisionState(input, toLocal: _pacific);
      expect(result.vector, hasLength(1024));
      expect(result.vector, _vectorForText(state));

      expect(records, hasLength(1));
      expect(records.single.label, 'decision');
      expect(records.single.outcome, 'ok');
      expect(records.single.model, 'bond-decide');
      expect(records.single.baseUrl, _url);
      expect(records.single.statusCode, 200);
      expect(records.single.error, isNull);
    });

    /// Every one of these is the server, not the message: a server that
    /// answers one message this way answers them all this way, so the pass
    /// parks under `decision_unavailable` instead of spending attempts.
    Future<void> expectFormat(
      http.Response Function(Map<String, dynamic>) answer,
      String words,
    ) async {
      server.onEmbed = answer;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>()
            .having((e) => e.message, 'message', contains(words))),
      );
    }

    test('a normalised vector is refused: the server ignored the field',
        () async {
      final unit = List<double>.filled(1024, 0.0)..[0] = 1.0;
      await expectFormat(
        (_) => http.Response(
            jsonEncode({
              'data': [
                {'index': 0, 'embedding': unit},
              ],
            }),
            200),
        'normalised',
      );
      // A misconfiguration parks, so it is recorded as the server's.
      expect(records.single.outcome, 'unavailable');
    });

    test('a vector of the wrong width is refused', () async {
      await expectFormat(
        (_) => http.Response(
            jsonEncode({
              'data': [
                {'index': 0, 'embedding': List.filled(768, 2.0)},
              ],
            }),
            200),
        '768',
      );
    });

    test('a body that is not JSON is refused', () async {
      await expectFormat((_) => http.Response('<html>', 200), 'not JSON');
    });

    test('an out-of-range or repeated index is refused', () async {
      await expectFormat(
        (_) => http.Response(
            jsonEncode({
              'data': [
                {'index': 1, 'embedding': _vectorForText('a')},
              ],
            }),
            200),
        'bad vector index',
      );
      server.onEmbed = (_) => http.Response(
          jsonEncode({
            'data': [
              {'index': 0, 'embedding': _vectorForText('a')},
              {'index': 0, 'embedding': _vectorForText('b')},
            ],
          }),
          200);
      await expectLater(
        client().decideBatch([_input('a'), _input('b')]),
        throwsA(isA<DecisionMisconfiguredException>()
            .having((e) => e.message, 'message', contains('bad vector index'))),
      );
    });

    test('a batch result carries each message its own raw vector', () async {
      final inputs = [_input('First note.'), _input('Please DROP this one.')];
      final results = await client().decideBatch(inputs);
      for (var i = 0; i < inputs.length; i++) {
        expect(
          results[i].vector,
          _vectorForText(renderDecisionState(inputs[i], toLocal: _pacific)),
        );
      }
    });

    test('a batch answered with the wrong number of vectors is refused',
        () async {
      server.onEmbed = (body) => _FakeDecide.vectors(
          _FakeDecide.inputsOf(body).take(1).toList());
      await expectLater(
        client().decideBatch([_input('a'), _input('b'), _input('c')]),
        throwsA(isA<DecisionMisconfiguredException>()
            .having((e) => e.message, 'message', contains('1 vectors for 3'))),
      );
    });

    test('a nested or missing embedding is refused', () async {
      await expectFormat(
        (_) => http.Response(
            jsonEncode({
              'data': [
                {
                  'index': 0,
                  'embedding': [List.filled(1024, 2.0)],
                },
              ],
            }),
            200),
        'no flat vector',
      );
      await expectFormat(
        (_) => http.Response(jsonEncode({'data': []}), 200),
        '0 vectors for 1',
      );
    });
  });

  group('failures', () {
    Future<Object> failure({int? status, String body = 'nope'}) async {
      if (status != null) server.onEmbed = (_) => http.Response(body, status);
      try {
        await client().decide(_input('a'));
      } catch (e) {
        return e;
      }
      fail('expected a throw');
    }

    test("401 and 403 are the key, under the decision server's own word",
        () async {
      for (final status in [401, 403]) {
        final e = await failure(status: status);
        expect(e, isA<DecisionUnauthorizedException>(), reason: '$status');
        // Still an unauthorized, so every arm that parks on one still does.
        expect(e, isA<LlmUnauthorizedException>());
        expect(parkReasonFor(e), 'decision_unauthorized');
      }
      // LlmClient's own choice: the subclass parks, so it reads unavailable.
      expect(records.map((r) => r.outcome), ['unavailable', 'unavailable']);
    });

    test('429 and every 5xx park as the decision model', () async {
      for (final status in [429, 500, 502, 503]) {
        final e = await failure(status: status);
        expect(e, isA<DecisionUnavailableException>(), reason: '$status');
        expect((e as LlmException).message, contains('make decide'));
      }
      expect(records.map((r) => r.outcome), everyElement('unavailable'));
      expect(records.map((r) => r.statusCode), [429, 500, 502, 503]);
    });

    test('any other 4xx is this request', () async {
      for (final status in [400, 422]) {
        expect(await failure(status: status), isA<LlmFormatException>(),
            reason: '$status');
      }
    });

    test('no /v1/embeddings is the server, and its passes are forgotten',
        () async {
      final c = client();
      for (final status in [404, 405]) {
        server.onEmbed = (_) => http.Response('Not Found', status);
        try {
          await c.decide(_input('a'));
          fail('expected a throw');
        } catch (e) {
          expect(e, isA<DecisionMisconfiguredException>(), reason: '$status');
          expect(parkReasonFor(e), 'decision_misconfigured');
          expect((e as LlmException).message,
              contains('does not offer /v1/embeddings'));
        }
      }
      // A park, so the identity probe's pass went with it: the server that
      // answers next is probed again, once per failed call and once more.
      server.onEmbed = null;
      await c.decide(_input('a'));
      expect(server.probes, hasLength(3));
    });

    test('a dead socket, a dropped client and a timeout all park', () async {
      server.transportError = const SocketException('refused');
      expect(await failure(), isA<DecisionUnavailableException>());

      server.transportError = http.ClientException('connection refused');
      expect(await failure(), isA<DecisionUnavailableException>());

      // A TLS handshake that failed: the server cannot be reached safely.
      server.transportError = const HandshakeException('bad certificate');
      expect(await failure(), isA<DecisionUnavailableException>());

      server
        ..transportError = null
        ..hang = true;
      try {
        await client(timeout: const Duration(milliseconds: 20))
            .decide(_input('a'));
        fail('expected a throw');
      } catch (e) {
        expect(e, isA<DecisionUnavailableException>());
      }
      expect(records.map((r) => r.outcome), everyElement('unavailable'));
    });

    test('the unavailable sentence says how to fix it, and the record keeps '
        'no URL', () async {
      server.transportError = const SocketException('refused');
      final e = await failure() as LlmException;
      expect(e.message, contains('not answering'));
      expect(e.message, contains('make decide'));
      // The first request a fresh client makes is the identity probe, so a
      // dead server is named at its /tokenize.
      expect(e.message, contains(_tokenizeUrl));
      expect(records.single.error, isNot(contains('127.0.0.1')));
      expect(records.single.error, contains('<endpoint>'));
    });

    test('a key no header can carry is refused before anything is sent',
        () async {
      for (final bad in [
        'sk-line\nbreak',
        'sk-tab\tkey',
        'sk-caf\u00e9',
        'sk key',
      ]) {
        target = LlmTarget(baseUrl: _url, model: 'm', bearer: bad);
        final before = server.requests.length;
        final e = await failure();
        expect(e, isA<DecisionUnauthorizedException>(), reason: bad);
        expect((e as LlmException).message, accessKeyCharsText);
        expect(e.message, isNot(contains(bad)));
        expect(server.requests.length, before, reason: 'nothing sent');
      }
    });

    test('a header dart:io refuses while sending reads as the key', () async {
      target = const LlmTarget(baseUrl: _url, model: 'm', bearer: _bearer);
      for (final error in <Object>[
        const FormatException('Invalid HTTP header field value'),
        ArgumentError('header'),
      ]) {
        server.transportError = error;
        final e = await failure();
        expect(e, isA<DecisionUnauthorizedException>());
        expect((e as LlmException).message, accessKeyCharsText);
        expect(e.message, isNot(contains(_bearer)));
      }
    });

    test('the bearer is never in an exception or a record', () async {
      target = const LlmTarget(baseUrl: _url, model: 'm', bearer: _bearer);
      for (final status in [401, 500, 400]) {
        // A proxy that echoes the header back into its error body.
        final e = await failure(
          status: status,
          body: 'bad header Authorization: Bearer $_bearer',
        ) as LlmException;
        expect(e.message, isNot(contains(_bearer)), reason: '$status');
        expect(e.toString(), isNot(contains(_bearer)));
      }
      for (final r in records) {
        expect('${r.error} ${r.baseUrl} ${r.model}', isNot(contains(_bearer)));
      }
    });

    test('the park word is its own, and it is still an unavailable', () {
      const e = DecisionUnavailableException('down');
      expect(parkReasonFor(e), 'decision_unavailable');
      expect(e, isA<LlmUnavailableException>());
      // The other words did not move.
      expect(parkReasonFor(const LlmUnauthorizedException('k')), 'unauthorized');
      expect(parkReasonFor(const EmbedUnavailableException('e')),
          'embed_unavailable');
      expect(parkReasonFor(const LlmUnavailableException('m')),
          'model_unavailable');
      expect(parkReasonFor(const ModelNotInstalledException('n')),
          'not_installed');
      expect(parkReasonFor(const DecisionNotInstalledException('n')),
          'decision_not_installed');
      expect(parkReasonFor(const DecisionUnauthorizedException('k')),
          'decision_unauthorized');
      // A misconfiguration parks under its own word: waiting fixes nothing.
      expect(parkReasonFor(const DecisionMisconfiguredException('m')),
          'decision_misconfigured');
      expect(const DecisionMisconfiguredException('m'),
          isA<DecisionUnavailableException>());
    });

    test('a throwing observer never breaks the call', () async {
      final result = await client(onCall: (_) => throw StateError('observer'))
          .decide(_input('a'));
      expect(result.answers['gate'].choice, 'keep');
    });
  });

  group('the identity probe', () {
    test('asks /tokenize for "a" with the specials, once, before the first '
        'embedding', () async {
      target = const LlmTarget(
          baseUrl: _url, model: 'bond-decide', bearer: _bearer);
      final c = client();
      await c.decide(_input('a'));
      await c.decide(_input('b'));
      await c.decideBatch([_input('c'), _input('d')]);

      expect(server.probes, hasLength(1));
      final probe = server.probes.single;
      expect(probe.url.toString(), _tokenizeUrl);
      expect(probe.headers['Authorization'], 'Bearer $_bearer');
      expect(_FakeDecide.bodyOf(probe), {
        'model': 'bond-decide',
        'content': 'a',
        'add_special': true,
      });
      expect(server.embeds, hasLength(3));
      // One decision, one record: the probe rides the call it preceded.
      expect(records, hasLength(3));
    });

    test('another model on the same address is probed again', () async {
      final c = client();
      await c.decide(_input('a'));
      target = const LlmTarget(baseUrl: _url, model: 'bond-embed');
      await c.decide(_input('a'));
      expect(server.probes.map((r) => _FakeDecide.bodyOf(r)['model']),
          ['bond-decide', 'bond-embed']);
    });

    test("a tokenizer that is not ModernBERT's is the wrong server, and "
        'nothing is embedded', () async {
      // Qwen3-Embedding: no [CLS], and 1024 raw numbers that would pass
      // every vector check.
      server.probeTokens = [64, 151643];
      final c = client();
      await expectLater(
        c.decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>()
            .having((e) => parkReasonFor(e), 'park word',
                'decision_misconfigured')
            .having((e) => e.message, 'message',
                contains('is not the decision model'))
            .having((e) => e.message, 'message',
                contains('http://127.0.0.1:8083'))),
      );
      expect(server.embeds, isEmpty);
      expect(records.single.outcome, 'unavailable');
      // A failure is not cached: the next call asks again.
      await expectLater(c.decideBatch([_input('a')]),
          throwsA(isA<DecisionMisconfiguredException>()));
      expect(server.probes, hasLength(2));

      for (final tokens in [
        <int>[],
        [DecisionClient.clsId, 64],
        [64, DecisionClient.sepId],
      ]) {
        server.probeTokens = tokens;
        await expectLater(client().decide(_input('a')),
            throwsA(isA<DecisionMisconfiguredException>()),
            reason: '$tokens');
      }
    });

    test('no /tokenize is the wrong server too', () async {
      for (final status in [404, 405]) {
        server.probeStatus = status;
        await expectLater(
          client().decide(_input('a')),
          throwsA(isA<DecisionMisconfiguredException>().having(
              (e) => e.message, 'message', contains('does not offer /tokenize'))),
          reason: '$status',
        );
      }
      expect(server.embeds, isEmpty);
    });

    test('a probe that cannot reach the server parks, and the next call '
        'probes again', () async {
      final c = client();
      server.probeError = const SocketException('refused');
      await expectLater(c.decide(_input('a')),
          throwsA(isA<DecisionUnavailableException>()
              .having((e) => parkReasonFor(e), 'park word',
                  'decision_unavailable')));
      expect(server.embeds, isEmpty);

      server.probeError = null;
      await c.decide(_input('a'));
      expect(server.probes, hasLength(2));
      expect(server.embeds, hasLength(1));
    });

    test('a pass is forgotten when the server stops answering, so the '
        'server that comes back is probed again', () async {
      final c = client();
      await c.decide(_input('a'));
      expect(server.probes, hasLength(1));

      // The pass is cached, so the embedding is the request that fails.
      server.transportError = const SocketException('refused');
      await expectLater(c.decide(_input('a')),
          throwsA(isA<DecisionUnavailableException>()));
      expect(server.probes, hasLength(1));

      server.transportError = null;
      await c.decide(_input('a'));
      expect(server.probes, hasLength(2));
    });

    test('a probe the key is refused on reads as the key', () async {
      server.probeStatus = 401;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionUnauthorizedException>()),
      );
    });

    test("checkServer is Connect's question: null for the decision model, "
        'the sentence otherwise', () async {
      final c = client();
      expect(
        await c.checkServer(url: _url, model: 'bond-decide', bearer: _bearer),
        isNull,
      );
      expect(server.probes.single.headers['Authorization'], 'Bearer $_bearer');
      // A pass spares the first decision its probe.
      target = const LlmTarget(
          baseUrl: _url, model: 'bond-decide', bearer: _bearer);
      await c.decide(_input('a'));
      expect(server.probes, hasLength(1));

      server.probeTokens = [64];
      final refusal =
          await client().checkServer(url: _url, model: 'bond-embed');
      expect(refusal, contains('is not the decision model'));
      expect(refusal, isNot(contains(_bearer)));
      expect(server.embeds, hasLength(1));
    });
  });

  group('the heads pairing', () {
    DecisionClient paired({String? Function(LlmTarget)? servedFile}) =>
        DecisionClient(
          resolveTarget: () => target,
          heads: syntheticHeads,
          client: server.client,
          onCall: records.add,
          toLocal: _pacific,
          servedFile: servedFile,
        );

    Map<String, Object?> listingOf(String path) => {
          'models': [
            {'name': path, 'model': path},
          ],
          'object': 'list',
          'data': [
            {'id': path, 'object': 'model'},
          ],
        };

    test("a served file whose name carries the heads' model passes, once",
        () async {
      server.listing = listingOf(
          '/Users/sam/models/local_bond-decide/bond-decide-synthetic-f16.gguf');
      final c = paired();

      await c.decide(_input('a'));
      await c.decide(_input('b'));

      expect(server.listings, hasLength(1));
      expect(server.embeds, hasLength(2));
    });

    test('a file of another model is refused, parks, and names the file only',
        () async {
      server.listing = listingOf(
          '/Users/sam/models/local_bond-decide/bond-decide-mbl-v2swap-f16.gguf');

      final e = await paired().decide(_input('a')).then<Object>(
          (_) => fail('expected a throw'),
          onError: (Object e) => e);

      expect(e, isA<DecisionModelMismatchException>());
      expect(e, isA<DecisionMisconfiguredException>());
      expect(parkReasonFor(e), 'decision_misconfigured');
      expect(
        (e as LlmException).message,
        'The decision model file (bond-decide-mbl-v2swap-f16.gguf) does not '
        'match its heads file (bond-decide-synthetic). Install them together.',
      );
      expect(server.embeds, isEmpty);
    });

    test('a sibling run whose name only STARTS with the heads model is '
        'refused', () async {
      // Another fine-tune of the same line: a substring or prefix match would
      // pass it, and its vectors are not the ones these heads were fitted on.
      server.listing = listingOf('/Users/sam/models/local_bond-decide/'
          'bond-decide-synthetic-cont2-f16.gguf');
      await expectLater(
        paired().decide(_input('a')),
        throwsA(isA<DecisionModelMismatchException>()),
      );
      expect(server.embeds, isEmpty);
    });

    test('the pairing rule: the model, at most one quant, then .gguf', () {
      const model = 'bond-decide-mbl-v3';
      for (final file in [
        'bond-decide-mbl-v3',
        'bond-decide-mbl-v3.gguf',
        'bond-decide-mbl-v3-f16.gguf',
        'bond-decide-mbl-v3-BF16.gguf',
        'bond-decide-mbl-v3-q8_0.gguf',
      ]) {
        expect(DecisionClient.servesHeadsModel(file, model), isTrue,
            reason: file);
      }
      for (final file in [
        'bond-decide-mbl-v3-cont2-f16.gguf',
        'bond-decide-mbl-v3-cont2',
        'bond-decide-mbl-v31-f16.gguf',
        'x-bond-decide-mbl-v3-f16.gguf',
        'bond-decide-mbl-v2-f16.gguf',
      ]) {
        expect(DecisionClient.servesHeadsModel(file, model), isFalse,
            reason: file);
      }
    });

    test("a served bond-decide- alias is paired like a file: the heads' "
        'model passes', () async {
      server.listing = listingOf('bond-decide-synthetic');
      await paired().decide(_input('a'));
      expect(server.embeds, hasLength(1));
    });

    test('a served bond-decide- alias of another model is refused', () async {
      server.listing = listingOf('bond-decide-mbl-v3');
      await expectLater(
        paired().decide(_input('a')),
        throwsA(isA<DecisionModelMismatchException>().having(
            (e) => e.message,
            'message',
            'The decision model file (bond-decide-mbl-v3) does not match its '
                'heads file (bond-decide-synthetic). Install them together.')),
      );
      expect(server.embeds, isEmpty);
    });

    test('a listing that names no file skips the check', () async {
      // The default listing: an alias, no path.
      final c = paired();
      await c.decide(_input('a'));
      expect(server.embeds, hasLength(1));

      // No listing at all.
      server.listingStatus = 404;
      await paired().decide(_input('a'));
      expect(server.embeds, hasLength(2));
    });

    test("a managed target's file is the manifest's, and no listing is asked",
        () async {
      await expectLater(
        paired(servedFile: (_) => 'bond-decide-mbl-v3-f16.gguf')
            .decide(_input('a')),
        throwsA(isA<DecisionModelMismatchException>()),
      );
      await paired(servedFile: (_) => 'bond-decide-synthetic-f16.gguf')
          .decide(_input('a'));
      expect(server.listings, isEmpty);
    });
  });

  group('truncation', () {
    test('a refused text becomes tokenize, then ids — once each, no retry',
        () async {
      server.onEmbed = (body) => body['input'] is String
          ? http.Response(_tooLargeBody, 500)
          : _FakeDecide.vectors(_FakeDecide.inputsOf(body));
      final input = _input('Short by characters, long in tokens.');

      final result = await client().decide(input);

      expect(server.requests.map((r) => r.url.toString()),
          [_url, _tokenizeUrl, _url]);
      final state = renderDecisionState(input, toLocal: _pacific);
      expect(_FakeDecide.bodyOf(server.requests[1]), {
        'content': state,
        'add_special': false,
        'model': 'bond-decide',
      });
      final ids = _FakeDecide.bodyOf(server.requests[2]);
      expect(ids['input'], [
        DecisionClient.clsId,
        for (var i = 1; i <= 2046; i++) i,
        DecisionClient.sepId,
      ]);
      expect(ids['embd_normalize'], -1);
      expect(ids['model'], 'bond-decide');

      expect(result.truncated, true);
      expect(result.state, state);
      expect(result.answers['intent'].choice, 'fyi');
      expect(records, hasLength(1));
      expect(records.single.outcome, 'ok');
    });

    test('the tokenize address keeps a path prefix', () async {
      target = const LlmTarget(
        baseUrl: 'https://box.example/decide/v1/embeddings',
        model: 'bond-decide',
      );
      server.onEmbed = (body) => body['input'] is String
          ? http.Response(_tooLargeBody, 500)
          : _FakeDecide.vectors(_FakeDecide.inputsOf(body));
      await client().decide(_input('a'));
      expect(server.tokenizes.single.url.toString(),
          'https://box.example/decide/tokenize');
      expect(
        DecisionClient.tokenizeUrlFor('http://127.0.0.1:8083/embeddings')
            .toString(),
        _tokenizeUrl,
      );
      expect(
        DecisionClient.tokenizeUrlFor(
                'http://127.0.0.1:8083/v1/embeddings?x=1')
            .toString(),
        _tokenizeUrl,
      );
      expect(
        () => DecisionClient.tokenizeUrlFor('http://127.0.0.1:8083/v1/other'),
        throwsA(isA<DecisionMisconfiguredException>()),
      );
    });

    test('a state over the character line goes straight to tokenize',
        () async {
      final input = _longInput();
      expect(renderDecisionState(input, toLocal: _pacific).length,
          greaterThan(DecisionClient.longStateChars));

      final result = await client().decide(input);

      expect(server.requests.map((r) => r.url.path),
          ['/tokenize', '/v1/embeddings']);
      expect(_FakeDecide.bodyOf(server.embeds.single)['input'], isA<List>());
      expect(result.truncated, true);
    });

    test('a short token list is sent whole, and nothing was truncated',
        () async {
      server.tokens = [7, 8, 9];
      final result = await client().decide(_longInput());
      expect(_FakeDecide.bodyOf(server.embeds.single)['input'],
          [DecisionClient.clsId, 7, 8, 9, DecisionClient.sepId]);
      // Long by characters, but every id fitted: it read the whole state.
      expect(result.truncated, false);
    });

    test('exactly maxTokens - 2 ids is not a truncation', () async {
      server.tokens = [for (var i = 1; i <= 2046; i++) i];
      expect((await client().decide(_longInput())).truncated, false);
      server.tokens = [for (var i = 1; i <= 2047; i++) i];
      expect((await client().decide(_longInput())).truncated, true);
    });

    test('a tokenize answer that is not a list of ids parks as misconfigured',
        () async {
      for (final body in [
        {'tokens': 'abc'},
        {'tokens': [1, 'two', 3]},
        {'tokens': [1.5]},
        {'nothing': true},
      ]) {
        final fake = _FakeDecide();
        final c = DecisionClient(
          resolveTarget: () => target,
          heads: syntheticHeads,
          client: MockClient((request) async {
            // No listing: the heads pairing is skipped.
            if (request.method == 'GET') return http.Response('', 404);
            if (_FakeDecide.isProbe(request)) {
              return http.Response(jsonEncode({'tokens': _modernBertA}), 200);
            }
            fake.requests.add(request);
            if (request.url.path.endsWith('/tokenize')) {
              return http.Response(jsonEncode(body), 200);
            }
            return _FakeDecide.vectors(
                _FakeDecide.inputsOf(_FakeDecide.bodyOf(request)));
          }),
        );
        await expectLater(c.decide(_longInput()),
            throwsA(isA<DecisionMisconfiguredException>()),
            reason: jsonEncode(body));
        expect(fake.embeds, isEmpty, reason: 'no id request after a bad list');
      }
    });

    test('tokenize failures map like any other request, but a missing '
        '/tokenize is the server', () async {
      for (final (status, matcher) in [
        (401, isA<LlmUnauthorizedException>()),
        (500, isA<DecisionUnavailableException>()),
        (400, isA<LlmFormatException>()),
        (
          404,
          isA<DecisionMisconfiguredException>().having(
              (e) => e.message, 'message', contains('does not offer /tokenize')),
        ),
        (405, isA<DecisionMisconfiguredException>()),
      ]) {
        final c = DecisionClient(
          resolveTarget: () => target,
          heads: syntheticHeads,
          client: MockClient((request) async => request.method == 'GET'
              ? http.Response('', 404)
              : _FakeDecide.isProbe(request)
              ? http.Response(jsonEncode({'tokens': _modernBertA}), 200)
              : request.url.path.endsWith('/tokenize')
                  ? http.Response('nope', status)
                  : _FakeDecide.vectors(
                      _FakeDecide.inputsOf(_FakeDecide.bodyOf(request)))),
        );
        await expectLater(c.decide(_longInput()), throwsA(matcher),
            reason: '$status');
      }
    });

    test('the id request refused as too long parks as misconfigured',
        () async {
      server.onEmbed = (_) => http.Response(_tooLargeBody, 500);
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>()),
      );
      expect(server.requests, hasLength(3));
      expect(records.single.outcome, 'unavailable');
    });
  });

  group('decideBatch', () {
    test('nothing to decide sends nothing', () async {
      expect(await client().decideBatch(const []), isEmpty);
      expect(server.requests, isEmpty);
      expect(records, isEmpty);
    });

    test('short states go in one array, answers in input order', () async {
      // Answered in REVERSE array order with indexes, so a client that read
      // positions instead of indexes would pair the wrong answers.
      server.onEmbed = (body) {
        final inputs = _FakeDecide.inputsOf(body);
        return http.Response(
          jsonEncode({
            'data': [
              for (var i = inputs.length - 1; i >= 0; i--)
                {
                  'index': i,
                  'embedding': _vectorForText(inputs[i] as String),
                },
            ],
          }),
          200,
        );
      };
      final inputs = [
        _input('keep me'),
        _input('DROP me'),
        _input('keep me too'),
      ];

      final results = await client().decideBatch(inputs);

      expect(server.requests, hasLength(1));
      final sent = _FakeDecide.bodyOf(server.requests.single)['input'] as List;
      expect(sent, [
        for (final input in inputs) renderDecisionState(input, toLocal: _pacific),
      ]);
      expect(results.map((r) => r.answers['gate'].choice),
          ['keep', 'drop', 'keep']);
      expect(results.map((r) => r.state), sent);
      expect(records, hasLength(1));
      expect(records.single.outcome, 'ok');
    });

    test('a long state is routed on its own', () async {
      final inputs = [_input('keep me'), _longInput(), _input('DROP me')];

      final results = await client().decideBatch(inputs);

      expect(server.requests.map((r) => r.url.path),
          ['/v1/embeddings', '/tokenize', '/v1/embeddings']);
      expect(
          (_FakeDecide.bodyOf(server.requests.first)['input'] as List).length,
          2);
      expect(results.map((r) => r.truncated), [false, true, false]);
      expect(results.map((r) => r.answers['gate'].choice),
          ['keep', 'keep', 'drop']);
      expect(results[1].answers['intent'].choice, 'fyi');
      expect(records, hasLength(1));
    });

    test('an array refused as too large falls back to one by one', () async {
      server.onEmbed = (body) {
        final input = body['input'];
        // The array, and the one text that is too long in tokens, are
        // refused; everything else answers.
        if (input is List && input.first is String) {
          return http.Response(_tooLargeBody, 500);
        }
        if (input is String && input.contains('TOKENS')) {
          return http.Response(_tooLargeBody, 500);
        }
        return _FakeDecide.vectors(_FakeDecide.inputsOf(body));
      };
      final inputs = [
        _input('keep me'),
        _input('many TOKENS'),
        _input('DROP me'),
      ];

      final results = await client().decideBatch(inputs);

      expect(server.requests.map((r) => r.url.path), [
        '/v1/embeddings', // the array, refused
        '/v1/embeddings', // keep me
        '/v1/embeddings', // many TOKENS, refused
        '/tokenize',
        '/v1/embeddings', // its ids
        '/v1/embeddings', // DROP me
      ]);
      expect(results.map((r) => r.truncated), [false, true, false]);
      expect(results.map((r) => r.answers['gate'].choice),
          ['keep', 'keep', 'drop']);
      expect(records, hasLength(1));
      expect(records.single.outcome, 'ok');
    });

    test('short states go in arrays of at most sixteen, order kept', () async {
      final inputs = [
        for (var i = 0; i < 40; i++)
          _input(i % 3 == 0 ? 'DROP number $i' : 'keep number $i'),
      ];

      final results = await client().decideBatch(inputs);

      expect(
        [
          for (final r in server.requests)
            (_FakeDecide.bodyOf(r)['input'] as List).length,
        ],
        [16, 16, 8],
      );
      final sent = [
        for (final r in server.requests)
          ...(_FakeDecide.bodyOf(r)['input'] as List),
      ];
      expect(sent, [
        for (final input in inputs) renderDecisionState(input, toLocal: _pacific),
      ]);
      expect(results.map((r) => r.answers['gate'].choice), [
        for (var i = 0; i < 40; i++) i % 3 == 0 ? 'drop' : 'keep',
      ]);
      expect(records, hasLength(1));
    });

    test('a failure fails the batch, with one record', () async {
      server.transportError = const SocketException('refused');
      await expectLater(
        client().decideBatch([_input('a'), _input('b')]),
        throwsA(isA<DecisionUnavailableException>()),
      );
      expect(records.single.outcome, 'unavailable');
    });
  });

  group('storyline questions', () {
    /// Answers every text with `yes` logit 2.0 on [question] when the text
    /// STARTS with [yesPrefix], and an untouched (tied) head otherwise; an id
    /// list gets the tie too.
    void answerYesFor(StorylineQuestion question, String yesPrefix) {
      server.onEmbed = (body) {
        final inputs = _FakeDecide.inputsOf(body);
        return http.Response(
          jsonEncode({
            'data': [
              for (final (i, input) in inputs.indexed)
                {
                  'index': i,
                  'embedding': syntheticVector({
                    if (input is String && input.startsWith(yesPrefix))
                      yesAxisOf(question): 2.0,
                  }),
                },
            ],
          }),
          200,
        );
      };
    }

    /// p(yes) for a `yes` logit of 2.0 at [question]'s synthetic temperature.
    double pHigh(StorylineQuestion question) {
      final t = syntheticTemperature(question.id);
      final e = math.exp(2.0 / t);
      return e / (e + 1);
    }

    test('ask sends the states as one raw-vector array, and reads p(yes) off '
        "the question's head", () async {
      answerYesFor(StorylineQuestion.memberOf, 'Storyline title: Lisbon');
      final states = [
        renderStorylineMembership(
          title: 'Lisbon offsite',
          charter: 'Plan the Q3 Lisbon offsite',
          threadText: 'Subject: Venue list',
        ),
        renderStorylineMembership(
          title: 'Quarterly invoices',
          charter: null,
          threadText: 'Subject: Venue list',
        ),
      ];

      final p = await client().ask(StorylineQuestion.memberOf, states);

      expect(server.probes, hasLength(1));
      expect(server.requests, hasLength(1));
      expect(_FakeDecide.bodyOf(server.requests.single), {
        'model': 'bond-decide',
        'input': states,
        'embd_normalize': -1,
      });
      expect(p[0], closeTo(pHigh(StorylineQuestion.memberOf), 1e-9));
      expect(p[1], closeTo(0.5, 1e-12));
      expect(records.single.label, 'decision:member_of');
      expect(records.single.outcome, 'ok');
    });

    test('a single state goes as one string, as decide sends it', () async {
      final state = renderStorylineCharter(title: 'Lisbon offsite');
      await client().ask(StorylineQuestion.charterSpecific, [state]);
      expect(_FakeDecide.bodyOf(server.requests.single)['input'], state);
      expect(records.single.label, 'decision:charter_specific');
    });

    test('nothing to ask sends nothing', () async {
      expect(await client().ask(StorylineQuestion.sameEffort, []), isEmpty);
      expect(await client().askPairs([]), isEmpty);
      expect(server.probes, isEmpty);
      expect(server.requests, isEmpty);
      expect(records, isEmpty);
    });

    test('askPairs asks both orders together and averages them', () async {
      // Only the order with ALPHA first says yes, so the mean is between.
      answerYesFor(StorylineQuestion.sameEffort, 'Thread A:\nALPHA');
      final pairs = [
        ('ALPHA thread', 'BETA thread'),
        ('GAMMA thread', 'DELTA thread'),
      ];

      final p = await client().askPairs(pairs);

      expect(server.requests, hasLength(1));
      expect(_FakeDecide.bodyOf(server.requests.single)['input'], [
        renderStorylinePair('ALPHA thread', 'BETA thread'),
        renderStorylinePair('BETA thread', 'ALPHA thread'),
        renderStorylinePair('GAMMA thread', 'DELTA thread'),
        renderStorylinePair('DELTA thread', 'GAMMA thread'),
      ]);
      expect(p, hasLength(2));
      expect(p[0],
          closeTo((pHigh(StorylineQuestion.sameEffort) + 0.5) / 2, 1e-9));
      expect(p[1], closeTo(0.5, 1e-12));
      expect(records.single.label, 'decision:same_effort');
    });

    test('pairs are batched at sixteen inputs, order kept', () async {
      answerYesFor(StorylineQuestion.sameEffort, 'Thread A:\nALPHA');
      final pairs = [
        for (var i = 0; i < 9; i++)
          (i.isEven ? 'ALPHA $i' : 'other $i', 'BETA $i'),
      ];

      final p = await client().askPairs(pairs);

      expect(
        [
          for (final r in server.requests)
            (_FakeDecide.bodyOf(r)['input'] as List).length,
        ],
        [16, 2],
      );
      for (var i = 0; i < 9; i++) {
        expect(
          p[i],
          closeTo(
            i.isEven
                ? (pHigh(StorylineQuestion.sameEffort) + 0.5) / 2
                : 0.5,
            1e-9,
          ),
          reason: 'pair $i',
        );
      }
      expect(records, hasLength(1));
    });

    test('a pair too long in tokens is truncated on its own, and the rest '
        'still answers', () async {
      server.onEmbed = (body) {
        final input = body['input'];
        if (input is List && input.first is String) {
          return http.Response(_tooLargeBody, 500);
        }
        if (input is String && input.contains('LONG')) {
          return http.Response(_tooLargeBody, 500);
        }
        return _FakeDecide.vectors(_FakeDecide.inputsOf(body));
      };

      final p = await client().askPairs([('LONG thread', 'short thread')]);

      expect(server.requests.map((r) => r.url.path), [
        '/v1/embeddings', // both orders, refused
        '/v1/embeddings', // A-then-B, refused
        '/tokenize',
        '/v1/embeddings', // its ids
        '/v1/embeddings', // B-then-A, refused
        '/tokenize',
        '/v1/embeddings', // its ids
      ]);
      final ids = _FakeDecide.bodyOf(server.requests[3])['input'] as List;
      expect(ids.first, DecisionClient.clsId);
      expect(ids.last, DecisionClient.sepId);
      expect(ids, hasLength(2048));
      // The id vectors carry nothing on same_effort's axes: a tie.
      expect(p.single, closeTo(0.5, 1e-12));
      expect(records.single.outcome, 'ok');
    });

    group('failures map as decide maps them', () {
      Future<Object> failure({
        int? status,
        http.Response Function(Map<String, dynamic>)? onEmbed,
        DecisionClient? using,
      }) async {
        if (status != null) {
          server.onEmbed = (_) => http.Response('nope', status);
        }
        if (onEmbed != null) server.onEmbed = onEmbed;
        try {
          await (using ?? client())
              .ask(StorylineQuestion.memberOf, ['a state']);
        } catch (e) {
          return e;
        }
        fail('expected a throw');
      }

      test('401 and 403 are the key', () async {
        for (final status in [401, 403]) {
          final e = await failure(status: status);
          expect(e, isA<DecisionUnauthorizedException>(), reason: '$status');
          expect(parkReasonFor(e), 'decision_unauthorized');
        }
        expect(records.map((r) => r.label), everyElement('decision:member_of'));
        expect(records.map((r) => r.outcome), everyElement('unavailable'));
      });

      test('429 and every 5xx park as unavailable', () async {
        for (final status in [429, 500, 503]) {
          final e = await failure(status: status);
          expect(e, isA<DecisionUnavailableException>(), reason: '$status');
          expect(parkReasonFor(e), 'decision_unavailable');
        }
      });

      test('any other 4xx is this request', () async {
        expect(await failure(status: 400), isA<LlmFormatException>());
        expect(records.single.outcome, 'format');
      });

      test('a dead socket parks', () async {
        server.transportError = const SocketException('refused');
        expect(await failure(), isA<DecisionUnavailableException>());
      });

      test('a normalised vector or the wrong width is misconfigured', () async {
        final unit = List<double>.filled(syntheticHidden, 0.0)..[0] = 1.0;
        for (final embedding in [unit, List<double>.filled(768, 2.0)]) {
          final e = await failure(
            onEmbed: (_) => http.Response(
              jsonEncode({
                'data': [
                  {'index': 0, 'embedding': embedding},
                ],
              }),
              200,
            ),
          );
          expect(e, isA<DecisionMisconfiguredException>());
          expect(parkReasonFor(e), 'decision_misconfigured');
        }
      });

      test('a server that is not the decision model is misconfigured',
          () async {
        server.probeTokens = [101, 64, 102];
        final e = await failure();
        expect(e, isA<DecisionMisconfiguredException>());
        expect(server.requests, isEmpty);
      });

      test('a refused heads file parks before anything is sent', () async {
        final e = await failure(
          using: DecisionClient(
            resolveTarget: () => target,
            heads: () => throw const DecisionMisconfiguredException(
                DecisionHeads.olderModelText),
            client: server.client,
            onCall: records.add,
          ),
        );
        expect(e, isA<DecisionMisconfiguredException>());
        expect(parkReasonFor(e), 'decision_misconfigured');
        expect(server.probes, isEmpty);
        expect(records.single.label, 'decision:member_of');
      });

      test('an unavailable target is not installed, and sends nothing',
          () async {
        final e = await failure(
          using: DecisionClient(
            resolveTarget: () => const LlmTarget(
              baseUrl: _url,
              model: 'bond-decide',
              unavailable: 'The decision model is not installed.',
            ),
            heads: syntheticHeads,
            client: server.client,
          ),
        );
        expect(e, isA<DecisionNotInstalledException>());
        expect(parkReasonFor(e), 'decision_not_installed');
        expect(server.probes, isEmpty);
      });
    });
  });

  test('a target that says it cannot answer throws '
      'DecisionUnavailableException and sends nothing', () async {
    final c = DecisionClient(
      resolveTarget: () => const LlmTarget(
        baseUrl: 'http://127.0.0.1:8080/v1/embeddings',
        model: 'bond-decide',
        unavailable:
            'The decision model is not installed. Run: make decide-install',
      ),
      heads: syntheticHeads,
      client: MockClient((request) async {
        fail('no request may leave for an unavailable target');
      }),
    );

    await expectLater(
      c.decide(_input('a')),
      throwsA(isA<DecisionNotInstalledException>()
          // The cause wins the park word: the rail says not installed
          // rather than a decision server that is not answering.
          .having((e) => parkReasonFor(e), 'park word',
              'decision_not_installed')
          .having(
            (e) => e.message,
            'message',
            contains('make decide-install'),
          )),
    );
    await expectLater(
      c.decide(_longInput()),
      throwsA(isA<DecisionUnavailableException>()),
    );
  });
}
