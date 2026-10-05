import 'dart:async';
import 'dart:convert';

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

/// The decision role's second kind: Kev behind the systemone wrapper on the
/// owner's server (contract §3.4), and how the client tells it from
/// ModernBERT on llama-server. Every server here is a `MockClient`; the
/// names and texts are fictional.

const String _box = 'https://box.example';
const String _kevUrl = '$_box/decide/v1/systemone';
const String _encoderUrl = '$_box/decide/v1/embeddings';
const String _kevModel = 'bond-decide-kev4b-fixture';
const String _bearer = 'sk-kev-fixture-3a9d';

/// A decision server of either kind, recording everything it is sent.
class _FakeServer {
  /// Every request but the listing, in order.
  final List<http.Request> requests = [];

  /// Every `GET …/v1/models`.
  final List<http.Request> listings = [];

  /// What the listing answers: a Kev wrapper's, by default.
  Map<String, Object?> listing = {
    'models': [
      {
        'name': _kevModel,
        'qhash': decisionQhash,
        'renderer': decisionRendererVersion,
      },
    ],
  };

  /// The listing's status, when not 200.
  int listingStatus = 200;

  /// The listing's raw body, in place of [listing], when set.
  String? listingRaw;

  /// `/tokenize`'s status, when not 200.
  int tokenizeStatus = 200;

  /// Thrown instead of answering anything, when set.
  Object? transportError;

  /// The systemone endpoint's status, when not 200.
  int askStatus = 200;

  /// The systemone endpoint's answer for a decoded body. Null → [answer].
  Map<String, Object?> Function(Map<String, dynamic> body)? onAsk;

  /// Held open until completed, when set: the concurrency test's gate.
  Completer<void>? gate;
  int inFlight = 0;
  int maxInFlight = 0;

  List<http.Request> get asks => [
        for (final r in requests)
          if (r.url.path.endsWith('/v1/systemone')) r,
      ];

  static Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  /// p(yes) for a storyline state: 0.9 when it says SAME, else 0.2, so a
  /// test can tell which state each answer went with.
  static double yesFor(String state) => state.contains('SAME') ? 0.9 : 0.2;

  /// The default answer: every option's probability, the first option
  /// favoured for a message field and a state-dependent p(yes) for a
  /// storyline question.
  static Map<String, Object?> answer(Map<String, dynamic> body) {
    final state = body['state'] as String;
    final questions = body['questions'] as Map<String, dynamic>;
    return {
      'answers': {
        for (final MapEntry(:key, :value) in questions.entries)
          key: () {
            final options =
                ((value as Map)['criteria'] as Map).keys.cast<String>().toList();
            final Map<String, double> p;
            if (StorylineQuestion.values.any((q) => q.id == key)) {
              final yes = yesFor(state);
              p = {'yes': yes, 'no': 1 - yes};
            } else {
              final rest = 0.4 / (options.length - 1);
              p = {for (final o in options) o: o == options.first ? 0.6 : rest};
            }
            final best = p.entries.reduce((a, b) => b.value > a.value ? b : a);
            return {
              'type': 'choice',
              'choice': best.key,
              'confidence': best.value,
              'probabilities': p,
            };
          }(),
      },
    };
  }

  MockClient get client => MockClient((request) async {
        if (transportError case final e?) throw e;
        if (request.method == 'GET') {
          listings.add(request);
          return http.Response(
              listingRaw ?? jsonEncode(listing), listingStatus);
        }
        requests.add(request);
        final body = bodyOf(request);
        final path = request.url.path;
        if (path.endsWith('/tokenize')) {
          if (tokenizeStatus != 200) {
            return http.Response('not here', tokenizeStatus);
          }
          return http.Response(
            jsonEncode({
              'tokens': [DecisionClient.clsId, 64, DecisionClient.sepId],
            }),
            200,
          );
        }
        if (path.endsWith('/embeddings')) {
          final input = body['input'];
          final n = input is List ? input.length : 1;
          return http.Response(
            jsonEncode({
              'data': [
                for (var i = 0; i < n; i++)
                  {'index': i, 'embedding': syntheticVector()},
              ],
            }),
            200,
          );
        }
        if (askStatus != 200) return http.Response('busy', askStatus);
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        try {
          if (gate case final g?) await g.future;
          return http.Response(
            jsonEncode((onAsk ?? answer)(body)),
            200,
          );
        } finally {
          inFlight--;
        }
      });
}

DecisionInput _input(String body) => DecisionInput(
      owner: 'Rivera, Sam <sam.rivera@example.org>',
      source: 'email',
      fromName: 'Dana Whitfield',
      fromAddress: 'dana@example.com',
      subject: 'Venue list',
      receivedAt: '2026-09-15T17:05:00Z',
      bodyText: body,
      addressedMe: true,
      toCount: 1,
    );

DateTime _pacific(DateTime utc) => utc.add(const Duration(hours: -7));

/// A heads file this Mac does not have.
DecisionHeads _noHeads() => throw const DecisionNotInstalledException(
    'The decision heads file is not on this Mac.');

void main() {
  late _FakeServer server;
  late List<LlmCallRecord> records;
  late LlmTarget target;

  DecisionClient client({
    bool yourServer = true,
    DecisionHeads Function()? heads,
    String? servedFile,
  }) =>
      DecisionClient(
        resolveTarget: () => target,
        heads: heads ?? _noHeads,
        client: server.client,
        onCall: records.add,
        toLocal: _pacific,
        isYourServer: (_) => yourServer,
        servedFile: (_) => servedFile,
      );

  setUp(() {
    server = _FakeServer();
    records = [];
    target = const LlmTarget(baseUrl: _kevUrl, model: _kevModel);
  });

  group('the kind', () {
    test('a managed target is encoder-heads, and /v1/models is never asked',
        () async {
      target = const LlmTarget(
        baseUrl: 'http://127.0.0.1:8090/v1/embeddings',
        model: 'bond-decide',
      );
      // Managed: the router's file is the manifest's, so the heads pairing
      // reads no listing either.
      final result = await client(
        yourServer: false,
        heads: syntheticHeads,
        servedFile: 'bond-decide-synthetic-f16.gguf',
      ).decide(_input('a'));
      expect(server.listings, isEmpty);
      expect(server.asks, isEmpty);
      expect(result.model, syntheticHeads().model);
    });

    test('a listed qhash is a systemone server: it answers, and no heads, '
        '/tokenize or /embeddings are touched', () async {
      final result = await client().decide(_input('a'));
      expect(server.listings.single.url.toString(), '$_box/decide/v1/models');
      expect(server.requests.map((r) => r.url.toString()), [_kevUrl]);
      expect(result.model, _kevModel);
      // No encoder, so no vector: a Needs You label taken here matches only
      // its own message.
      expect(result.vector, isNull);
    });

    test('a listing with no qhash is encoder-heads, and the identity probe '
        'runs as before', () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      server.listing = {
        'models': [
          {'name': 'bond-decide', 'model': 'bond-decide'},
        ],
        'data': [
          {'id': 'bond-decide'},
        ],
      };
      final result =
          await client(heads: syntheticHeads).decide(_input('a'));
      expect(server.listings.single.url.toString(), '$_box/decide/v1/models');
      expect(server.requests.map((r) => r.url.path),
          ['/decide/tokenize', '/decide/v1/embeddings']);
      expect(result.model, syntheticHeads().model);
    });

    test("Your ModernBERT's listed file is paired with the heads from the "
        'same listing, asked once', () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      Map<String, Object?> listing(String file) => {
            'models': [
              {'name': 'bond-decide', 'model': '/srv/models/$file'},
            ],
            'data': [
              {'id': 'bond-decide'},
            ],
          };
      server.listing = listing('bond-decide-synthetic-f16.gguf');
      await client(heads: syntheticHeads).decide(_input('a'));
      expect(server.listings, hasLength(1));

      server.listing = listing('bond-decide-mbl-v2swap-f16.gguf');
      await expectLater(
        client(heads: syntheticHeads).decide(_input('a')),
        throwsA(isA<DecisionModelMismatchException>().having(
            (e) => e.message,
            'message',
            contains('(bond-decide-mbl-v2swap-f16.gguf)'))),
      );
    });

    test('a server with no listing (404) is encoder-heads', () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      server.listingStatus = 404;
      await client(heads: syntheticHeads).decide(_input('a'));
      expect(server.requests.map((r) => r.url.path),
          ['/decide/tokenize', '/decide/v1/embeddings']);
    });

    test('another question set is refused, naming both hashes', () async {
      server.listing = {
        'models': [
          {
            'name': _kevModel,
            'qhash': '0000aaaa1111bbbb',
            'renderer': decisionRendererVersion,
          },
        ],
      };
      final e = await client()
          .decide(_input('a'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<DecisionMisconfiguredException>());
      expect(parkReasonFor(e!), 'decision_misconfigured');
      expect((e as LlmException).message,
          allOf(contains('0000aaaa1111bbbb'), contains(decisionQhash)));
      expect(server.asks, isEmpty);
    });

    test('another renderer is refused', () async {
      server.listing = {
        'models': [
          {'name': _kevModel, 'qhash': decisionQhash, 'renderer': 'bond-x/9'},
        ],
      };
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>().having(
            (e) => e.message, 'message', contains('bond-x/9'))),
      );
      expect(server.asks, isEmpty);
    });

    test('a refused key on the listing reads as the key', () async {
      server.listingStatus = 401;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionUnauthorizedException>()),
      );
    });

    test('a listing that is not ready parks as unavailable', () async {
      server.listingStatus = 503;
      final e = await client()
          .decide(_input('a'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<DecisionUnavailableException>());
      expect(e, isNot(isA<DecisionMisconfiguredException>()));
      expect(parkReasonFor(e!), 'decision_unavailable');
    });

    test('the kind is asked once, and asked again after the server stopped '
        'answering', () async {
      final c = client();
      await c.decide(_input('a'));
      await c.decide(_input('b'));
      expect(server.listings, hasLength(1));

      server.askStatus = 503;
      await expectLater(c.decide(_input('c')),
          throwsA(isA<DecisionUnavailableException>()));
      expect(server.listings, hasLength(1));

      server.askStatus = 200;
      await c.decide(_input('d'));
      expect(server.listings, hasLength(2));
    });

    test('a failed kind check is not kept', () async {
      server.listingStatus = 503;
      final c = client();
      await expectLater(c.decide(_input('a')),
          throwsA(isA<DecisionUnavailableException>()));
      server.listingStatus = 200;
      await c.decide(_input('a'));
      expect(server.listings, hasLength(2));
    });

    test('the bearer rides the listing and every ask', () async {
      target = const LlmTarget(
          baseUrl: _kevUrl, model: _kevModel, bearer: _bearer);
      await client().decide(_input('a'));
      expect(server.listings.single.headers['Authorization'],
          'Bearer $_bearer');
      expect(server.asks.single.headers['Authorization'], 'Bearer $_bearer');
    });

    for (final status in [400, 406, 410]) {
      test('a listing answered $status is no listing: encoder-heads',
          () async {
        target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
        server.listingStatus = status;
        await client(heads: syntheticHeads).decide(_input('a'));
        expect(server.requests.map((r) => r.url.path),
            ['/decide/tokenize', '/decide/v1/embeddings']);
      });
    }

    test('a 200 listing that is not JSON is no listing: encoder-heads',
        () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      server.listingRaw = '<html>front door</html>';
      await client(heads: syntheticHeads).decide(_input('a'));
      expect(server.requests.map((r) => r.url.path),
          ['/decide/tokenize', '/decide/v1/embeddings']);
    });

    test('an empty model list is no systemone entry: encoder-heads',
        () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      server.listing = {'models': <Object>[]};
      await client(heads: syntheticHeads).decide(_input('a'));
      expect(server.requests.map((r) => r.url.path),
          ['/decide/tokenize', '/decide/v1/embeddings']);
    });

    test('no listing and no /tokenize parks as today', () async {
      target = const LlmTarget(baseUrl: _encoderUrl, model: 'bond-decide');
      server.listingStatus = 404;
      server.tokenizeStatus = 404;
      await expectLater(
        client(heads: syntheticHeads).decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>().having(
            (e) => e.message, 'message', contains('does not offer /tokenize'))),
      );
    });

    test('a systemone route that is gone parks as misconfigured, and the '
        'kind is asked again next time', () async {
      // An embeddings address, so the route can turn out to be either kind.
      target = const LlmTarget(baseUrl: _encoderUrl, model: _kevModel);
      final c = client(heads: syntheticHeads);
      expect((await c.decide(_input('a'))).model, _kevModel);
      expect(server.listings, hasLength(1));

      server.askStatus = 404;
      final e = await c
          .decide(_input('b'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<DecisionMisconfiguredException>());
      expect(parkReasonFor(e!), 'decision_misconfigured');

      // The route now serves ModernBERT: re-detected, not stuck on Kev. It
      // lists the ModernBERT its heads were trained with, or the heads
      // pairing would refuse it.
      server.askStatus = 200;
      server.listing = {
        'data': [
          {'id': 'bond-decide-synthetic'},
        ],
      };
      final result = await c.decide(_input('c'));
      expect(server.listings, hasLength(2));
      expect(result.model, syntheticHeads().model);
    });

    test("Your server's sentences never say make decide; this Mac's do",
        () async {
      server.listingStatus = 503;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionUnavailableException>().having(
            (e) => e.message, 'message', isNot(contains('make decide')))),
      );
      server.listingStatus = 200;
      server.transportError = http.ClientException('refused');
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionUnavailableException>().having(
            (e) => e.message, 'message', isNot(contains('make decide')))),
      );

      target = const LlmTarget(
        baseUrl: 'http://127.0.0.1:8090/v1/embeddings',
        model: 'bond-decide',
      );
      await expectLater(
        client(yourServer: false, heads: syntheticHeads).decide(_input('a')),
        throwsA(isA<DecisionUnavailableException>().having(
            (e) => e.message, 'message', contains('Run: make decide.'))),
      );
    });

    test('detectKind fills the cache kindOf reads, and says null when the '
        'server does not answer', () async {
      final c = client();
      expect(
          await c.detectKind(url: _kevUrl, model: _kevModel, bearer: _bearer),
          DecisionServerKind.systemOne);
      expect(server.listings.single.headers['Authorization'],
          'Bearer $_bearer');
      expect(c.kindOf(url: _kevUrl, model: _kevModel),
          DecisionServerKind.systemOne);
      // The first decision needs no listing of its own.
      await c.decide(_input('a'));
      expect(server.listings, hasLength(1));

      server.listingStatus = 503;
      final other = client();
      expect(await other.detectKind(url: _kevUrl, model: _kevModel), isNull);
      expect(other.kindOf(url: _kevUrl, model: _kevModel), isNull);
    });

    test('the endpoints sit beside the address, prefix kept', () {
      expect(DecisionClient.systemOneUrlFor(_kevUrl, 'models').toString(),
          '$_box/decide/v1/models');
      expect(
          DecisionClient.systemOneUrlFor(_encoderUrl, 'systemone').toString(),
          _kevUrl);
      expect(
          DecisionClient.systemOneUrlFor('http://127.0.0.1:18302/v1/systemone',
                  'models')
              .toString(),
          'http://127.0.0.1:18302/v1/models');
      expect(() => DecisionClient.systemOneUrlFor('$_box/decide', 'models'),
          throwsA(isA<DecisionMisconfiguredException>()));
    });
  });

  group('decide', () {
    test('asks the nine message questions in one request: the rendered '
        'state, the plain text, null criteria in option order', () async {
      final input = _input('Could you send the list?');
      await client().decide(input);

      final body = _FakeServer.bodyOf(server.asks.single);
      expect(body.keys, ['state', 'questions']);
      expect(body['state'], renderDecisionState(input, toLocal: _pacific));
      // Compared as JSON text, so the order of the ids and of every
      // question's criteria is part of what is pinned.
      expect(
        jsonEncode(body['questions']),
        jsonEncode({
          for (final q in systemOneMessageQuestions)
            q.id: {
              'type': 'choice',
              'instructions': q.instructions,
              'criteria': {for (final o in q.options) o: null},
            },
        }),
      );
      expect((body['questions'] as Map).keys, decisionFields);
    });

    test('maps the probabilities into the nine answers, as they came',
        () async {
      server.onAsk = (body) {
        final answer = _FakeServer.answer(body);
        ((answer['answers'] as Map)['needs_you'] as Map)['probabilities'] = {
          'yes': 0.31,
          'no': 0.69,
        };
        ((answer['answers'] as Map)['urgency'] as Map)['probabilities'] = {
          'low': 0.1,
          'normal': 0.2,
          'high': 0.6,
          'urgent': 0.1,
        };
        return answer;
      };
      final input = _input('a');
      final result = await client().decide(input);

      expect(result.answers.fields.keys, decisionFields);
      expect(result.answers.p('needs_you', 'yes'), 0.31);
      expect(result.answers['needs_you'].choice, 'no');
      expect(result.answers['urgency'].choice, 'high');
      expect(result.answers['urgency'].confidence, 0.6);
      expect(result.answers['urgency'].probabilities.keys,
          decisionOptions['urgency']);
      expect(result.answers['gate'].choice, 'keep');
      expect(result.state, renderDecisionState(input, toLocal: _pacific));
      expect(result.model, _kevModel);
      expect(result.truncated, false);
      expect(records.single.label, 'decision');
      expect(records.single.outcome, 'ok');
    });

    test('decideBatch asks once per state, in order, at most eight at once',
        () async {
      server.gate = Completer<void>();
      final inputs = [for (var i = 0; i < 20; i++) _input('message $i')];
      final pending = client().decideBatch(inputs);
      await pumpEventQueue();
      expect(server.inFlight, DecisionClient.systemOneInFlight);
      server.gate!.complete();
      final results = await pending;

      expect(server.maxInFlight, DecisionClient.systemOneInFlight);
      expect(server.asks, hasLength(20));
      expect(
        results.map((r) => r.state),
        [for (final i in inputs) renderDecisionState(i, toLocal: _pacific)],
      );
      expect(records, hasLength(1));
      expect(records.single.label, 'decision');
    });
  });

  group('ask', () {
    test('one request per state carrying the one question, p(yes) as it '
        'came', () async {
      final states = ['SAME effort', 'another'];
      final p = await client().ask(StorylineQuestion.memberOf, states);

      expect(p, [0.9, 0.2]);
      expect(server.asks, hasLength(2));
      for (final (i, r) in server.asks.indexed) {
        final body = _FakeServer.bodyOf(r);
        expect(body['state'], states[i]);
        expect(
          jsonEncode(body['questions']),
          jsonEncode({
            'member_of': {
              'type': 'choice',
              'instructions': StorylineQuestion.memberOf.instructions,
              'criteria': {'yes': null, 'no': null},
            },
          }),
        );
      }
      expect(records.single.label, 'decision:member_of');
    });

    test('askPairs asks both orders and averages them', () async {
      const a = 'Thread A: SAME';
      const b = 'Thread B';
      final p = await client().askPairs([(a, b)]);

      expect(server.asks.map((r) => _FakeServer.bodyOf(r)['state']), [
        renderStorylinePair(a, b),
        renderStorylinePair(b, a),
      ]);
      // Both orders contain the marker, so both answer 0.9.
      expect(p.single, closeTo(0.9, 1e-12));

      server.requests.clear();
      server.onAsk = (body) {
        final state = body['state'] as String;
        final yes = state.startsWith(renderStorylinePair(a, b)) ? 0.8 : 0.4;
        return {
          'answers': {
            'same_effort': {
              'type': 'choice',
              'choice': yes >= 0.5 ? 'yes' : 'no',
              'confidence': yes >= 0.5 ? yes : 1 - yes,
              'probabilities': {'yes': yes, 'no': 1 - yes},
            },
          },
        };
      };
      final averaged = await client().askPairs([(a, b)]);
      expect(averaged.single, closeTo(0.6, 1e-12));
    });
  });

  group('a malformed answer parks as misconfigured', () {
    Future<void> expectFormat(
      void Function(Map<String, Object?> answers) spoil,
    ) async {
      server.onAsk = (body) {
        final answer = _FakeServer.answer(body);
        spoil(answer['answers'] as Map<String, Object?>);
        return answer;
      };
      final e = await client()
          .decide(_input('a'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<DecisionMisconfiguredException>());
      expect(parkReasonFor(e!), 'decision_misconfigured');
      expect(records.last.outcome, 'unavailable');
    }

    Map<String, Object?> probabilitiesOf(
            Map<String, Object?> answers, String id) =>
        (answers[id] as Map)['probabilities'] as Map<String, Object?>;

    test('an asked id missing', () async {
      await expectFormat((answers) => answers.remove('intent'));
    });

    test('options other than the question\'s', () async {
      await expectFormat((answers) {
        final p = probabilitiesOf(answers, 'gate');
        p['maybe'] = p.remove('drop');
      });
    });

    test('a probability outside 0 to 1', () async {
      await expectFormat((answers) {
        probabilitiesOf(answers, 'needs_you')
          ..['yes'] = 1.2
          ..['no'] = -0.2;
      });
    });

    test('probabilities that do not sum to 1', () async {
      await expectFormat((answers) {
        probabilitiesOf(answers, 'needs_you')
          ..['yes'] = 0.5
          ..['no'] = 0.4;
      });
    });

    test('no answers at all', () async {
      server.onAsk = (_) => {'result': 'ok'};
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<DecisionMisconfiguredException>()),
      );
    });

    test('a state the wrapper refuses (422) fails that message alone',
        () async {
      server.askStatus = 422;
      await expectLater(
        client().decide(_input('a')),
        throwsA(isA<LlmFormatException>()),
      );
      expect(records.last.outcome, 'format');
    });
  });

  group('checkServer', () {
    test('a Kev server passes, and its kind is known afterwards', () async {
      final c = client();
      expect(c.kindOf(url: _kevUrl, model: _kevModel), isNull);
      expect(
        await c.checkServer(url: _kevUrl, model: _kevModel, bearer: _bearer),
        isNull,
      );
      expect(server.listings.single.headers['Authorization'],
          'Bearer $_bearer');
      expect(c.kindOf(url: _kevUrl, model: _kevModel),
          DecisionServerKind.systemOne);
      // A pass spares the first decision its kind check.
      await c.decide(_input('a'));
      expect(server.listings, hasLength(1));
    });

    test('ModernBERT passes as encoder-heads after its identity probe',
        () async {
      server.listing = {
        'data': [
          {'id': 'bond-decide'},
        ],
      };
      final c = client();
      expect(await c.checkServer(url: _encoderUrl, model: 'bond-decide'),
          isNull);
      expect(server.requests.single.url.path, '/decide/tokenize');
      expect(c.kindOf(url: _encoderUrl, model: 'bond-decide'),
          DecisionServerKind.encoderHeads);
    });

    test('a Kev server on another question set is refused with its '
        'sentence, and no kind is kept', () async {
      server.listing = {
        'models': [
          {
            'name': _kevModel,
            'qhash': '0000aaaa1111bbbb',
            'renderer': decisionRendererVersion,
          },
        ],
      };
      final c = client();
      final refusal =
          await c.checkServer(url: _kevUrl, model: _kevModel, bearer: _bearer);
      expect(refusal, contains('another version of the decision model'));
      expect(refusal, isNot(contains(_bearer)));
      expect(c.kindOf(url: _kevUrl, model: _kevModel), isNull);
    });
  });
}
