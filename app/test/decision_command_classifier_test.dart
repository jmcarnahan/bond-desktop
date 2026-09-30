import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/services/calendar/command/command_heads.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/command/decision_command_classifier.dart';
import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart'
    show DecisionHeads;
import 'package:bond_inbox/services/llm/llm_client.dart' show LlmCallRecord;
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/command_heads_fixture.dart';
import 'fixtures/decision_heads_fixture.dart';

/// The command head as a classifier, over a REAL decision client pointed at
/// a `MockClient` (which answers `/tokenize` too) and a hand-made head as
/// wide as the encoder: a text saying "move" lights the move axis, anything
/// else lights nothing, so the head is unsure.
void main() {
  const url = 'http://127.0.0.1:8083/v1/embeddings';
  const modernBertA = [DecisionClient.clsId, 64, DecisionClient.sepId];

  late List<String> embedded;
  late int status;

  /// Every call record the client wrote.
  late List<LlmCallRecord> records;

  /// Each embed request's answer waits on this when set.
  late List<Completer<void>>? holds;

  final head = CommandHeads.load(
      jsonEncode(commandHeadsJson(dim: syntheticHidden)));

  List<double> vectorFor(String text) =>
      syntheticVector({if (text.contains('move')) 1: 12.0});

  DecisionClient client() => DecisionClient(
        resolveTarget: () =>
            const LlmTarget(baseUrl: url, model: 'bond-decide'),
        heads: syntheticHeads,
        onCall: records.add,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/tokenize')) {
            return http.Response(jsonEncode({'tokens': modernBertA}), 200);
          }
          final text = body['input'] as String;
          embedded.add(text);
          final gate = Completer<void>();
          holds?.add(gate);
          if (holds != null) await gate.future;
          if (status != 200) return http.Response('loading model', status);
          return http.Response(
            jsonEncode({
              'data': [
                {'index': 0, 'embedding': vectorFor(text)},
              ],
            }),
            200,
          );
        }),
      );

  setUp(() {
    embedded = [];
    status = 200;
    holds = null;
    records = [];
  });

  DecisionCommandClassifier classifier({
    Future<CommandHeads?> Function()? heads,
    bool Function()? ready,
    DecisionHeads? Function()? installed,
    Duration timeout = const Duration(milliseconds: 800),
  }) {
    final c = client();
    return DecisionCommandClassifier(
      client: () => c,
      heads: heads ?? () async => head,
      decisionReady: ready ?? () => true,
      installedHeads: installed ?? syntheticHeads,
      timeout: timeout,
    );
  }

  test('a confident head answers on the head path', () async {
    final g = await classifier().classify('move my 3pm with Dana Contoso');
    expect(g, isNotNull);
    expect(g!.action, CommandAction.move);
    expect(g.path, CommandPath.head);
    expect(g.confidence, greaterThan(0.8));
  });

  test('an unsure head says unknown, for the router to pass over', () async {
    final g = await classifier().classify('lunch thing w Priya Northwind');
    expect(g!.action, CommandAction.unknown);
    expect(g.path, CommandPath.head);
  });

  test('no head asset, or a refused one, is no answer and no request',
      () async {
    expect(await classifier(heads: () async => null).classify('move it'),
        isNull);
    expect(
        await classifier(
                heads: () async => throw const CommandHeadsRefused('bad'))
            .classify('move it'),
        isNull);
    expect(embedded, isEmpty);
  });

  test('a head fitted for another width is no answer', () async {
    final narrow = CommandHeads.load(commandHeadsText());
    expect(await classifier(heads: () async => narrow).classify('move it'),
        isNull);
  });

  test('a decision server that is down is no answer, never a throw',
      () async {
    status = 503;
    final c = classifier();
    expect(await c.classify('move my 3pm'), isNull);
    expect(await c.classifyPreview('move my 3pm'), isNull);
  });

  test('the preview keeps one request out, and only the newest text is sent '
      'after it', () async {
    holds = [];
    final c = classifier();
    final first = c.classifyPreview('move the standup');
    await pumpEventQueue();
    expect(embedded, ['move the standup']);

    final second = c.classifyPreview('move the standup to');
    final third = c.classifyPreview('move the standup to friday');
    await pumpEventQueue();
    expect(embedded, hasLength(1), reason: 'one request out at a time');

    holds!.first.complete();
    expect(await first, isNull,
        reason: 'its text is no longer the newest by the time it answers');
    expect(await second, isNull, reason: 'overtaken while it waited');
    await pumpEventQueue();
    expect(embedded, ['move the standup', 'move the standup to friday']);

    holds!.last.complete();
    final g = await third;
    expect(g!.action, CommandAction.move);
  });

  test('a request that outlives its caller still holds the one slot: a '
      'newer preview starts none, and is sent once when it settles',
      () async {
    holds = [];
    final c = classifier(timeout: const Duration(milliseconds: 20));
    // The caller gives up at the timeout; the request is still out.
    expect(await c.classifyPreview('move the standup'), isNull);
    expect(embedded, ['move the standup']);

    final newer = c.classifyPreview('move the standup to friday');
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(embedded, ['move the standup'],
        reason: 'no second request while the first is out');

    holds!.first.complete();
    await pumpEventQueue();
    expect(embedded, ['move the standup', 'move the standup to friday'],
        reason: 'the newest text, once, after the first settled');
    holds!.last.complete();
    expect((await newer)!.action, CommandAction.move);
    expect(embedded, hasLength(2));
  });

  test('the decision role not ready: no request, no call record', () async {
    final c = classifier(ready: () => false);
    expect(await c.classify('move my 3pm'), isNull);
    expect(await c.classifyPreview('move my 3pm'), isNull);
    expect(embedded, isEmpty);
    expect(records, isEmpty, reason: 'no command_head row for a model '
        'nobody could have asked');
    // Ready, the same classifier's client records its call.
    expect(await classifier().classify('move my 3pm'), isNotNull);
    expect(records.map((r) => r.label), ['command_head']);
  });

  test('a head fitted on another decision model than the installed one is '
      'refused before any request', () async {
    final other = CommandHeads.load(jsonEncode(commandHeadsJson(
        dim: syntheticHidden, encoderModel: 'bond-decide-older')));
    final c = classifier(heads: () async => other);
    expect(await c.classify('move my 3pm'), isNull);
    expect(await c.classifyPreview('move my 3pm'), isNull);
    // No installed heads at all: nothing to compare with, nothing asked.
    expect(await classifier(installed: () => null).classify('move my 3pm'),
        isNull);
    expect(embedded, isEmpty);
    expect(records, isEmpty);
  });

  test('an unexpected error is no answer, never a throw', () async {
    final c = classifier(heads: () async => throw StateError('a bug'));
    expect(await c.classify('move my 3pm'), isNull);
    expect(await c.classifyPreview('move my 3pm'), isNull);
    final t = classifier(
        heads: () async => throw TimeoutException('slow asset'));
    expect(await t.classify('move my 3pm'), isNull);
    expect(embedded, isEmpty);
  });
}
