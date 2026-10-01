import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_stats.dart';
import 'fixtures/fake_decision_client.dart' show fakeAnswers;
import 'fixtures/golden_gate.dart';
import 'fixtures/golden_harness.dart';
import 'fixtures/golden_prices.dart';
import 'fixtures/golden_run.dart';
import 'fixtures/golden_set.dart';

/// Everything the live golden replay decides, decided offline.
///
/// `llm_golden_live_test.dart` needs a server and a set this repo does not
/// carry, so it can never run in the gate. What it does AROUND the calls can,
/// and this is where that is pinned: how a result becomes a run-file section,
/// how the needs-you verdict is derived from the model's two answers, what a
/// run cost and how fast it went. The pool it runs on is a `bench_stats`
/// fixture and is tested there.
///
/// A silent break in any of these is the worst kind: the run still completes,
/// the file still parses, and the accuracy number quoted in the ledger is
/// simply about something else.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';

  late GoldenSet set;

  setUp(() {
    set = GoldenSet.fromJson(
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>,
    );
  });

  // ── the app's own gates, replayed offline ─────────────────────────────
  group('the gate replay answers from what the set carries', () {
    GoldenItem itemOf(String id) =>
        set.items.firstWhere((item) => item.id == id);

    test('the owner\'s own message is dropped before a gate reads it', () {
      final out = gateReplay(itemOf('email:fx-outbound'), ownerAddress: null);
      expect(out.verdict, 'drop');
      expect(out.reason, 'outbound');
    });

    test('a chat with nothing left in it is empty', () {
      final out = gateReplay(itemOf('teams:fx-empty-body'), ownerAddress: null);
      expect(out.verdict, 'drop');
      expect(out.reason, 'empty');
    });

    test('a named human asking a question is kept, and names no reason', () {
      final out = gateReplay(itemOf('email:fx-keep-tail'), ownerAddress: null);
      expect(out.verdict, 'keep');
      expect(out.reason, isNull);
    });

    test('a header-only gold drop is kept — tier 2 is not in the set', () {
      // The gold calls this one a newsletter on its List-Unsubscribe, and the
      // set carries no headers, so `gateFor` reaches the header block with an
      // empty map. The replay KEEPS it, and that is the whole point of the
      // unmeasured line the run prints: this is the input's limit, not a gate
      // that regressed.
      final out = gateReplay(
        itemOf('email:fx-drop-notification'),
        ownerAddress: null,
      );
      expect(out.verdict, 'keep');
      expect(out.reason, isNull);
    });

    test('mail from the owner\'s own address is self', () {
      final item = itemOf('email:fx-keep-tail');
      final owner = item.message.fromAddress;
      expect(owner, isNotNull,
          reason: 'the fixture item is the one that carries a sender');
      final out = gateReplay(item, ownerAddress: owner);
      expect(out.verdict, 'drop');
      expect(out.reason, 'self');
    });

    test('the model calling it a notification does not move the verdict', () {
      final out = gateReplay(
        itemOf('email:fx-keep-tail'),
        ownerAddress: null,
        modelCategory: 'notification',
      );
      expect(out.verdict, 'keep');
      expect(out.reason, isNull);
      // Carried into the run file for a reader, and nowhere else.
      expect(out.modelCategory, 'notification');
    });

    test('every item gets a verdict, and only a drop names a reason', () {
      for (final item in set.items) {
        final out = gateReplay(item, ownerAddress: null);
        expect(out.verdict, anyOf('keep', 'drop'));
        if (out.verdict == 'drop') {
          expect(out.reason, isNotNull, reason: item.id);
          expect(out.reason, isNotEmpty, reason: item.id);
        } else {
          expect(out.reason, isNull, reason: item.id);
        }
      }
    });

    test('a row with only a gate is attempted, and carries three keys', () {
      final entry = GoldenRunEntry(
        id: 'email:fx-keep-tail',
        stratum: 'storyline-core',
        difficulty: 'easy',
      )..gate = const GoldenGateOut(verdict: 'keep');

      expect(entry.attempted, isTrue);
      final json = entry.toScoreRunJson();
      final gate = json['gate']! as Map<String, Object?>;
      expect(
        gate.keys,
        unorderedEquals(<String>['verdict', 'reason', 'model_category']),
      );
      expect(gate['verdict'], 'keep');
      // Null rather than absent: the scorer reads either as "not attempted"
      // on a keep, and a reader should see that the replay answered.
      expect(gate['reason'], isNull);
      expect(gate['model_category'], isNull);
      expect(json.containsKey('triage'), isFalse);
    });

    test('a run file gives up its categories, and a row without triage is '
        'skipped', () async {
      final dir = await Directory.systemTemp.createTemp('golden-gate-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/run.json');
      await file.writeAsString(jsonEncode(<Object?>[
        {
          'id': 'email:one',
          'triage': {'category': 'work'},
        },
        {
          'id': 'email:two',
          'triage': {'category': 'notification'},
        },
        {'id': 'email:three'},
        'not a row at all',
      ]));

      expect(
        await loadGoldenTriageCategories(file.path),
        {'email:one': 'work', 'email:two': 'notification'},
      );
    });

    test('a path with no run file says what to pass', () async {
      await expectLater(
        loadGoldenTriageCategories(
          '${Directory.systemTemp.path}/golden-gate-absent-run.json',
        ),
        throwsStateError,
      );
    });

    test('a JSON object is not a run file', () async {
      final dir = await Directory.systemTemp.createTemp('golden-gate-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/run.json');
      await file.writeAsString(jsonEncode({'id': 'email:one'}));

      await expectLater(
        loadGoldenTriageCategories(file.path),
        throwsStateError,
      );
    });
  });

  // ── results into run-file sections ────────────────────────────────────
  group('a stage result becomes the section the scorer reads', () {
    test('the message text copies every field', () {
      final out = textOut(const MessageTextResult(
        summary: 'The allowance is capped.',
        actionItems: ['Answer by Friday'],
        deadline: 'Friday',
        topics: ['allowance'],
        project: 'River Street office',
      ));
      expect(out.summary, 'The allowance is capped.');
      expect(out.actionItems, ['Answer by Friday']);
      expect(out.deadline, 'Friday');
      expect(out.topics, ['allowance']);
      expect(out.project, 'River Street office');
    });

    test('a message that named no deadline keeps the empty string', () {
      // Never null: the run file's one trap is that an empty deadline is the
      // ANSWER "this message named none", while a null is a stage that never
      // ran, and the scorer reads the difference.
      final out = textOut(const MessageTextResult(summary: ''));
      expect(out.deadline, '');
    });

    test('the text completes the classifier sections, with no label or '
        'evidence', () {
      final entry = GoldenRunEntry(id: 'g1', stratum: 's', difficulty: 'd')
        ..classifier = classifierOut(
          fakeAnswers(needsYou: 0.9),
          rule: DecisionGateRule.policy,
        )
        ..text = const GoldenTextOut(
          summary: 'The allowance is capped.',
          actionItems: ['Answer by Friday'],
          deadline: 'Friday',
          topics: ['allowance'],
          project: 'River Street office',
        )
        ..needsYou = decidedNeedsYouOut(fakeAnswers(needsYou: 0.9));
      final json = entry.toScoreRunJson();
      final triage = json['triage']! as Map;
      expect(triage['summary'], 'The allowance is capped.');
      expect(triage['action_items'], ['Answer by Friday']);
      expect(triage['deadline'], 'Friday');
      expect(triage['category'], 'work');
      expect(triage.containsKey('label'), isFalse);
      final extract = json['extract']! as Map;
      expect(extract['topics'], ['allowance']);
      expect(extract['project'], 'River Street office');
      expect(extract['intent'], 'fyi');
      expect(extract.containsKey('evidence'), isFalse);
      expect(extract.containsKey('people'), isFalse);
      // The ladder's typed section wins the key.
      expect(json['needs_you'], containsPair('verdict', true));
      expect(json['needs_you'], containsPair('confidence', 'high'));
    });

    test('without text the classifier sections stay classification-only', () {
      final entry = GoldenRunEntry(id: 'g1', stratum: 's', difficulty: 'd')
        ..classifier = classifierOut(
          fakeAnswers(),
          rule: DecisionGateRule.policy,
        );
      final json = entry.toScoreRunJson();
      expect((json['triage']! as Map).containsKey('summary'), isFalse);
      expect((json['extract']! as Map).containsKey('topics'), isFalse);
    });

    test('the verdict is the probability against the slider, never null', () {
      GoldenNeedsYouOut at(double p, {double? threshold}) => threshold == null
          ? decidedNeedsYouOut(fakeAnswers(needsYou: p))
          : decidedNeedsYouOut(fakeAnswers(needsYou: p), threshold: threshold);
      // At the shipped default, 0.35.
      expect(at(0.35).verdict, isTrue);
      expect(at(0.34).verdict, isFalse);
      expect(at(0.5).verdict, isTrue);
      expect(at(0.97).confidence, 'high');
      expect(at(0.05).confidence, 'high');
      // A sweep moves the cut.
      expect(at(0.5, threshold: 0.55).verdict, isFalse);
      expect(at(0.55, threshold: 0.55).verdict, isTrue);
    });

    test("a decided item carries the app's templated reason as evidence", () {
      final yes = fakeAnswers(needsYou: 0.9, intent: 'approval');
      expect(decidedNeedsYouOut(yes).evidence, needsYouYesReason(yes));
      // A no carries the same template: the app writes it beside the
      // probability whatever its value.
      final no = fakeAnswers(needsYou: 0.1, intent: 'approval');
      expect(decidedNeedsYouOut(no).evidence, needsYouYesReason(no));
      expect(
        (GoldenRunEntry(id: 'g', stratum: 's', difficulty: 'd')
              ..needsYou = decidedNeedsYouOut(yes))
            .toScoreRunJson()['needs_you'],
        containsPair('evidence', needsYouYesReason(yes)),
      );
    });

    test('the text scores on its own when the decision failed', () {
      final json = (GoldenRunEntry(id: 'g', stratum: 's', difficulty: 'd')
            ..text = const GoldenTextOut(
              summary: 'The allowance is capped.',
              actionItems: ['Answer by Friday'],
              deadline: 'Friday',
              topics: ['allowance'],
              project: 'River Street office',
            ))
          .toScoreRunJson();
      expect(json['triage'], {
        'deadline': 'Friday',
        'summary': 'The allowance is capped.',
        'action_items': ['Answer by Friday'],
      });
      expect(json['extract'], {
        'project': 'River Street office',
        'topics': ['allowance'],
      });
    });

    test('a draft flattens its options and keeps its evidence', () {
      final out = draftOut(const DraftResult(
        evidence: 'the capped allowance',
        replyBody: 'Yes, that works.',
        options: [
          DraftOption(stance: 'Accept the cap', body: 'That works for us.'),
          DraftOption(stance: 'Ask for more', body: 'Could we revisit it?'),
        ],
      ));
      expect(out.body, 'Yes, that works.');
      expect(out.evidence, 'the capped allowance');
      expect(out.options, [
        'Accept the cap: That works for us.',
        'Ask for more: Could we revisit it?',
      ]);
    });

    test('a reply decision is the decision model at replyYes', () {
      final yes = decisionOut(fakeAnswers(replyExpected: 0.8));
      expect(yes.needsReply, isTrue);
      expect(yes.p, closeTo(0.8, 1e-9));
      expect(yes.source, 'decision_model');

      final no = decisionOut(fakeAnswers(replyExpected: 0.3));
      expect(no.needsReply, isFalse);
      expect(no.p, closeTo(0.3, 1e-9));

      // The bar itself is a yes, as the draft lane reads it.
      expect(
        decisionOut(fakeAnswers(replyExpected: DecisionPolicy.replyYes))
            .needsReply,
        isTrue,
      );
    });
  });

  // ── which rows a run file carries ─────────────────────────────────────
  group('a row is written when anything was attempted', () {
    GoldenRunEntry entry() =>
        GoldenRunEntry(id: 'email:fx-reply', stratum: 's', difficulty: 'easy');

    test('an untouched entry is not a row', () {
      expect(entry().attempted, isFalse);
    });

    test('a failed call with no section is still a row', () {
      final e = entry()
        ..calls['triage'] = const GoldenCall(ms: 12, outcome: 'unavailable');
      expect(e.attempted, isTrue);
    });

    test('a needs-you answer with no call is still a row', () {
      expect(
        (entry()..needsYou = decidedNeedsYouOut(fakeAnswers(needsYou: 0.9)))
            .attempted,
        isTrue,
      );
    });
  });

  // ── the keys bench_compare reads back ─────────────────────────────────
  test('the result keys bench_compare reads are the ones a run writes', () {
    // The tool lives in tool/ and cannot import a test fixture, so the two
    // sides share nothing but these literals; this holds them together.
    final source = File('tool/bench_compare.dart').readAsStringSync();
    for (final key in const [msgsPerMinKey, costKey, per1kKey]) {
      expect(source, contains("'$key'"), reason: 'bench_compare no longer reads $key');
    }
    final cost = costSummary(
      tasks: const [],
      url: 'http://localhost:8082/v1/chat/completions',
      model: 'qwen3-4b',
      items: 1,
    );
    expect(cost.containsKey(per1kKey), isTrue);
  });

  // ── the prose file's shape ────────────────────────────────────────────
  test('a decision-only entry scores as triage.reply_expected', () {
    final entry = GoldenRunEntry(
      id: 'email:fx-reply',
      stratum: 'triage-spread',
      difficulty: 'medium',
    )..decision = const GoldenDecisionOut(needsReply: true, p: 0.75);
    final json = entry.toScoreRunJson();
    expect(json['triage'], {'reply_expected': true});
    expect(json['decision'], {
      'source': 'decision_model',
      'p': 0.75,
      'needs_reply': true,
    });
  });

  // ── what a call cost ──────────────────────────────────────────────────
  test('a call record becomes the cost the run file carries', () {
    final call = callOf(_record('triage',
        ms: 2176, promptTokens: 1240, completionTokens: 96));
    expect(call.ms, 2176);
    expect(call.promptTokens, 1240);
    expect(call.completionTokens, 96);
    expect(call.outcome, 'ok');
  });

  test('a runtime that reported no usage keeps its nulls', () {
    final call = callOf(_record('extraction', ms: 900, outcome: 'format'));
    expect(call.promptTokens, isNull);
    expect(call.completionTokens, isNull);
    expect(call.outcome, 'format');
  });

  // ── prices ────────────────────────────────────────────────────────────
  group('a local server is free and an unpriced one is unknown', () {
    test('localhost costs nothing whatever the model is called', () {
      expect(
        costFor(
          url: 'http://localhost:8082/v1/chat/completions',
          model: 'anything-at-all',
          promptTokens: 1000000,
          completionTokens: 1000000,
        ),
        0.0,
      );
      expect(
        costFor(
          url: 'http://127.0.0.1:8082/v1/chat/completions',
          model: 'qwen3-4b',
          promptTokens: 500,
          completionTokens: 500,
        ),
        0.0,
      );
    });

    test('a remote model nobody priced is null, never zero', () {
      expect(
        costFor(
          url: 'https://bedrock-runtime.example.com/v1/chat/completions',
          model: 'some.model-nobody-priced',
          promptTokens: 1000,
          completionTokens: 1000,
        ),
        isNull,
      );
    });

    test('a priced model is input plus output per million', () {
      expect(
        costFor(
          url: 'https://bedrock-runtime.example.com/v1/chat/completions',
          model: 'nvidia.nemotron-nano-3-30b',
          promptTokens: 1000000,
          completionTokens: 1000000,
        ),
        closeTo(0.30, 1e-9),
      );
    });

    test('a url nothing can parse a host out of is not local', () {
      // The one direction of error this table must never make: "I could not
      // read where this went" must not resolve to "it was free".
      expect(isLocalUrl('not a url at all'), isFalse);
      expect(isLocalUrl(''), isFalse);
      expect(isLocalUrl('http://localhost:8082/v1'), isTrue);
    });
  });

  // ── the cost summary ──────────────────────────────────────────────────
  group('a run prices itself per stage and per thousand messages', () {
    TaskMetrics metrics(String task, int prompt, int completion) =>
        TaskMetrics(task)
          ..add(_record(task,
              ms: 1000, promptTokens: prompt, completionTokens: completion));

    test('a local run costs zero, and says so rather than saying nothing', () {
      final cost = costSummary(
        tasks: [metrics('triage', 1000000, 1000000)],
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3-4b',
        items: 100,
      );
      expect(cost['prices_dated'], pricesDated);
      expect((cost['per_stage'] as Map)['triage'], {
        'usd': 0.0,
        'prompt_tokens': 1000000,
        'completion_tokens': 1000000,
      });
      expect(cost['total_usd'], 0.0);
      expect(cost['per_1k_messages_usd'], 0.0);
    });

    test('one unpriced stage leaves the whole total unknown', () {
      final cost = costSummary(
        tasks: [metrics('triage', 1000000, 1000000)],
        url: 'https://bedrock-runtime.example.com/v1/chat/completions',
        model: 'some.model-nobody-priced',
        items: 100,
      );
      expect((cost['per_stage'] as Map)['triage'], {
        'usd': null,
        'prompt_tokens': 1000000,
        'completion_tokens': 1000000,
      });
      expect(cost['total_usd'], isNull);
      expect(cost['per_1k_messages_usd'], isNull);
    });

    test('a priced run sums its stages and scales to a thousand messages', () {
      final cost = costSummary(
        tasks: [
          metrics('triage', 1000000, 1000000),
          metrics('extraction', 1000000, 0),
        ],
        url: 'https://bedrock-runtime.example.com/v1/chat/completions',
        model: 'nvidia.nemotron-nano-3-30b',
        items: 100,
      );
      final perStage = cost['per_stage'] as Map<String, Object?>;
      expect((perStage['triage'] as Map)['usd'], closeTo(0.30, 1e-9));
      expect((perStage['extraction'] as Map)['usd'], closeTo(0.06, 1e-9));
      expect(cost['total_usd'], closeTo(0.36, 1e-9));
      // 0.36 over a hundred messages is 3.60 per thousand.
      expect(cost['per_1k_messages_usd'], closeTo(3.60, 1e-9));
    });

    test('a run over no messages quotes no per-thousand figure', () {
      final cost = costSummary(
        tasks: [metrics('triage', 1000, 1000)],
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3-4b',
        items: 0,
      );
      expect(cost['total_usd'], 0.0);
      expect(cost['per_1k_messages_usd'], isNull);
    });
  });

  // ── throughput and the knobs ──────────────────────────────────────────
  test('messages a minute is the whole run over the wall clock', () {
    expect(msgsPerMinute(100, const Duration(minutes: 10)), 10.0);
    expect(msgsPerMinute(100, Duration.zero), 0);
  });

  test('GOLDEN_K must name a concurrency somebody could run', () {
    expect(checkK(1), 1);
    expect(checkK(4), 4);
    for (final bad in const [0, -1]) {
      expect(
        () => checkK(bad),
        throwsA(isA<ArgumentError>()
            .having((e) => e.name, 'name', contains('GOLDEN_K'))),
        reason: 'k=$bad',
      );
    }
  });

  // ── a throttled call is retried, everything else is not ───────────────
  group('a throttled call is retried with backoff', () {
    late List<Duration> waited;

    setUp(() => waited = []);

    Future<void> record(Duration delay) async => waited.add(delay);

    test('succeeds on the third try, having doubled the wait once', () async {
      var calls = 0;
      var retries = 0;

      final answer = await retryingUnavailable<String>(
        () async {
          calls++;
          if (calls < 3) {
            throw const LlmUnavailableException('throttled');
          }
          return 'ok';
        },
        wait: record,
        onRetry: () => retries++,
      );

      expect(answer, 'ok');
      expect(calls, 3);
      expect(retries, 2);
      expect(waited, const [Duration(seconds: 2), Duration(seconds: 4)]);
    });

    test('gives up after the last attempt and rethrows what it saw', () async {
      var calls = 0;

      await expectLater(
        retryingUnavailable<String>(
          () async {
            calls++;
            throw const LlmUnavailableException('throttled');
          },
          wait: record,
        ),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(calls, 4);
      // One fewer sleep than attempts: nothing waits after the last failure.
      expect(waited, hasLength(3));
    });

    test('a plain rejection is this side\'s bug and is not repeated',
        () async {
      var calls = 0;

      await expectLater(
        retryingUnavailable<String>(
          () async {
            calls++;
            throw const LlmException('rejected', 400);
          },
          wait: record,
        ),
        throwsA(isA<LlmException>()
            .having((e) => e.statusCode, 'statusCode', 400)),
      );

      expect(calls, 1);
      expect(waited, isEmpty);
    });

    test('an answer in the wrong shape is not repeated either', () async {
      var calls = 0;

      await expectLater(
        retryingUnavailable<String>(
          () async {
            calls++;
            throw const LlmFormatException('not JSON');
          },
          wait: record,
        ),
        throwsA(isA<LlmFormatException>()),
      );

      expect(calls, 1);
      expect(waited, isEmpty);
    });

    test('an attempt count nobody could run is refused', () {
      expect(
        () => retryingUnavailable<String>(() async => 'ok', attempts: 0),
        throwsArgumentError,
      );
    });
  });

  // ── the decision model on the golden set ─────────────────────────────
  group('the decision leg', () {
    DecisionAnswers answers(Map<String, Map<String, double>> probs) {
      final fields = <String, ChoiceAnswer>{};
      for (final field in decisionFields) {
        final options = decisionOptions[field]!;
        final p = {
          for (final o in options) o: probs[field]?[o] ?? 0.0,
        };
        if (!probs.containsKey(field)) p[options.first] = 1.0;
        final top = p.entries.reduce((a, b) => b.value > a.value ? b : a);
        fields[field] = ChoiceAnswer(
          choice: top.key,
          confidence: top.value,
          probabilities: p,
        );
      }
      return DecisionAnswers(fields);
    }

    test('the state is render_state over the packer parts, tail and all', () {
      final state = goldenDecisionState(
        {
          'now': '2026-09-09 (Wednesday)',
          'directness_line': 'Addressed to: only you.',
          'message_block': 'From: A <a@example.com>\n\nBody:\nhi',
          'ctx_tail3': {
            'thread_tail': [
              {'who': 'You', 'received_at': 'x', 'text': 'earlier'},
              {'who': null, 'text': 'second'},
            ],
          },
        },
        owner: 'Sam <sam@example.com>',
      );
      expect(
        state,
        'The reader, the owner of this inbox, is Sam <sam@example.com>. Any '
        'mention of that name or address refers to the reader.\n\n'
        'Today is 2026-09-09 (Wednesday).\n\n'
        'Addressed to: only you.\n\n'
        'Recent thread before this message, oldest first, for context only:\n'
        'You: earlier\n---\n: second\n\n'
        'The message to judge:\nFrom: A <a@example.com>\n\nBody:\nhi',
      );
    });

    test('no tail, no owner: no tail section and no owner line', () {
      expect(
        goldenDecisionState({
          'now': 'n',
          'directness_line': 'd',
          'message_block': 'm',
          'ctx_tail3': {'thread_tail': <Object?>[]},
        }),
        'Today is n.\n\nd\n\nThe message to judge:\nm',
      );
    });

    test('the policy gate keeps cold outreach and maps other', () {
      final cold = answers({
        'gate': {'keep': 0.1, 'drop': 0.9},
        'drop_reason': {'cold_outreach': 0.8, 'other': 0.2},
      });
      expect(
        classifierOut(cold, rule: DecisionGateRule.policy).gateVerdict,
        'keep',
      );
      final argmax = classifierOut(cold, rule: DecisionGateRule.argmax);
      expect(argmax.gateVerdict, 'drop');
      expect(argmax.gateReason, 'cold_outreach');

      final other = answers({
        'gate': {'keep': 0.25, 'drop': 0.75},
        'drop_reason': {'other': 0.9},
      });
      final out = classifierOut(other, rule: DecisionGateRule.policy);
      expect(out.gateVerdict, 'drop');
      expect(out.gateReason, 'model_other');
      expect(
        classifierOut(other, rule: DecisionGateRule.argmax).gateReason,
        'other',
      );
    });

    test('a drop below 0.70 is kept by policy and dropped by argmax', () {
      final a = answers({
        'gate': {'keep': 0.4, 'drop': 0.6},
        'drop_reason': {'newsletter': 1},
      });
      expect(classifierOut(a, rule: DecisionGateRule.policy).gateVerdict,
          'keep');
      expect(classifierOut(a, rule: DecisionGateRule.policy).gateReason,
          isNull);
      expect(classifierOut(a, rule: DecisionGateRule.argmax).gateVerdict,
          'drop');
    });

    test('booleans at 0.5, needs-you at the slider default, its confidence '
        'off the top probability', () {
      final a = answers({
        'needs_action': {'yes': 0.5, 'no': 0.5},
        'reply_expected': {'yes': 0.49, 'no': 0.51},
        'needs_you': {'yes': 0.35, 'no': 0.65},
        'category': {'work': 1},
        'urgency': {'high': 1},
        'intent': {'question': 1},
        'importance': {'normal': 1},
      });
      final out = classifierOut(a, rule: DecisionGateRule.policy);
      expect(out.needsAction, isTrue);
      expect(out.replyExpected, isFalse);
      // The app's own rule: 0.35 is the slider's default, and a message at
      // the line needs you.
      expect(out.needsYouVerdict, isTrue);
      expect(out.needsYouConfidence, 'medium');
      expect(
        classifierOut(
          answers({
            'needs_you': {'yes': 0.34, 'no': 0.66},
          }),
          rule: DecisionGateRule.policy,
        ).needsYouVerdict,
        isFalse,
      );
      expect(decisionConfidenceWord(0.9), 'high');
      expect(decisionConfidenceWord(0.1), 'high');
      expect(decisionConfidenceWord(0.6), 'low');
      expect(out.category, 'work');
      expect(out.urgency, 'high');
      expect(out.intent, 'question');
      expect(out.importance, 'normal');
    });

    test('the run row carries the scored keys and no text field', () {
      final entry = GoldenRunEntry(id: 'x', stratum: 's', difficulty: 'd')
        ..classifier = classifierOut(
          answers({
            'gate': {'keep': 0.2, 'drop': 0.8},
            'drop_reason': {'newsletter': 1},
          }),
          rule: DecisionGateRule.policy,
        );
      final json = entry.toScoreRunJson();
      expect(json['gate'], {'verdict': 'drop', 'reason': 'newsletter'});
      expect((json['triage'] as Map).keys.toSet(),
          {'category', 'urgency', 'needs_action', 'reply_expected'});
      expect((json['extract'] as Map).keys.toSet(), {'intent', 'importance'});
      expect((json['needs_you'] as Map).keys.toSet(),
          {'verdict', 'confidence'});
      expect(json.containsKey('decision_model'), isTrue);
      expect(entry.attempted, isTrue);
    });
  });

  // ── the new files must stay safe for a public repo ────────────────────
  test('nothing new names a host that is not example.com', () {
    // The same check `golden_set_test.dart` holds the fixtures to, over the
    // files this phase added. Naming a real vendor here to exclude it would
    // put that name into a public file, which is the leak the check exists to
    // prevent — so the rule is a whitelist of one.
    final text = [
      'test/llm_golden_live_test.dart',
      'test/fixtures/golden_gate.dart',
      'test/fixtures/golden_harness.dart',
      'test/fixtures/golden_prices.dart',
    ].map((path) => File(path).readAsStringSync()).join('\n');

    final addresses = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9._%+\-]+')
        .allMatches(text)
        .map((m) => m.group(0)!);
    for (final address in addresses) {
      expect(address.endsWith('example.com'), isTrue,
          reason: 'a real-looking address leaked into a public file');
    }

    final hosts = RegExp(r'\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|ai)\b',
            caseSensitive: false)
        .allMatches(text)
        .map((m) => m.group(0)!.toLowerCase())
        .toSet();
    for (final host in hosts) {
      expect(host.endsWith('example.com'), isTrue,
          reason: 'a real-looking host leaked into a public file');
    }
  });
}

/// A call record in the shape the client emits one, for the arithmetic above.
LlmCallRecord _record(
  String label, {
  required int ms,
  int? promptTokens,
  int? completionTokens,
  String outcome = 'ok',
}) =>
    LlmCallRecord(
      label: label,
      durationMs: ms,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      outcome: outcome,
    );
