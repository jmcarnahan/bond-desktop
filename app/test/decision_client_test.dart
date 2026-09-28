import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;

import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
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

/// A decision server that records every request and answers on script.
class _FakeDecide {
  final List<http.Request> requests = [];

  /// The embed endpoint's answer, given the decoded body. Null → the default:
  /// a raw vector per input.
  http.Response Function(Map<String, dynamic> body)? onEmbed;

  /// The ids `/tokenize` returns.
  List<int> tokens = [for (var i = 1; i <= 3000; i++) i];

  /// Thrown instead of answering, when set.
  Object? transportError;

  /// Never answers, when true.
  bool hang = false;

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

  MockClient get client => MockClient((request) async {
        requests.add(request);
        if (transportError != null) throw transportError!;
        if (hang) return Completer<http.Response>().future;
        final body = bodyOf(request);
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

      expect(records, hasLength(1));
      expect(records.single.label, 'decision');
      expect(records.single.outcome, 'ok');
      expect(records.single.model, 'bond-decide');
      expect(records.single.baseUrl, _url);
      expect(records.single.statusCode, 200);
      expect(records.single.error, isNull);
    });

    Future<void> expectFormat(
      http.Response Function(Map<String, dynamic>) answer,
      String words,
    ) async {
      server.onEmbed = answer;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<LlmFormatException>()
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
      expect(records.single.outcome, 'format');
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
        throwsA(isA<LlmFormatException>()
            .having((e) => e.message, 'message', contains('bad vector index'))),
      );
    });

    test('a batch answered with the wrong number of vectors is refused',
        () async {
      server.onEmbed = (body) => _FakeDecide.vectors(
          _FakeDecide.inputsOf(body).take(1).toList());
      await expectLater(
        client().decideBatch([_input('a'), _input('b'), _input('c')]),
        throwsA(isA<LlmFormatException>()
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

    test('401 and 403 are the key', () async {
      for (final status in [401, 403]) {
        expect(await failure(status: status),
            isA<LlmUnauthorizedException>(),
            reason: '$status');
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
      for (final status in [400, 404]) {
        expect(await failure(status: status), isA<LlmFormatException>(),
            reason: '$status');
      }
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
      expect(e.message, contains(_url));
      expect(records.single.error, isNot(contains('127.0.0.1')));
      expect(records.single.error, contains('<endpoint>'));
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
    });

    test('a throwing observer never breaks the call', () async {
      final result = await client(onCall: (_) => throw StateError('observer'))
          .decide(_input('a'));
      expect(result.answers['gate'].choice, 'keep');
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
        throwsA(isA<LlmFormatException>()),
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

    test('a tokenize answer that is not a list of ids is a format error',
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
            fake.requests.add(request);
            if (request.url.path.endsWith('/tokenize')) {
              return http.Response(jsonEncode(body), 200);
            }
            return _FakeDecide.vectors(
                _FakeDecide.inputsOf(_FakeDecide.bodyOf(request)));
          }),
        );
        await expectLater(c.decide(_longInput()),
            throwsA(isA<LlmFormatException>()),
            reason: jsonEncode(body));
        expect(fake.embeds, isEmpty, reason: 'no id request after a bad list');
      }
    });

    test('tokenize failures map like any other request', () async {
      for (final (status, matcher) in [
        (401, isA<LlmUnauthorizedException>()),
        (500, isA<DecisionUnavailableException>()),
        (404, isA<LlmFormatException>()),
      ]) {
        final c = DecisionClient(
          resolveTarget: () => target,
          heads: syntheticHeads,
          client: MockClient((request) async =>
              request.url.path.endsWith('/tokenize')
                  ? http.Response('nope', status)
                  : _FakeDecide.vectors(
                      _FakeDecide.inputsOf(_FakeDecide.bodyOf(request)))),
        );
        await expectLater(c.decide(_longInput()), throwsA(matcher),
            reason: '$status');
      }
    });

    test('the id request refused as too long is a format error', () async {
      server.onEmbed = (_) => http.Response(_tooLargeBody, 500);
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<LlmFormatException>()),
      );
      expect(server.requests, hasLength(3));
      expect(records.single.outcome, 'format');
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
}
