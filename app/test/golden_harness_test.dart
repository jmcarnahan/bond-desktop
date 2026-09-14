import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_stats.dart';
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

  // ── results into run-file sections ────────────────────────────────────
  group('a stage result becomes the section the scorer reads', () {
    test('triage copies every field', () {
      final out = triageOut(const TriageResult(
        urgency: 'high',
        category: 'work',
        label: 'lease addendum',
        summary: 'The allowance is capped.',
        needsAction: true,
        actionItems: ['Answer by Friday'],
        replyExpected: true,
        deadline: 'Friday',
      ));
      expect(out.urgency, 'high');
      expect(out.category, 'work');
      expect(out.label, 'lease addendum');
      expect(out.summary, 'The allowance is capped.');
      expect(out.needsAction, isTrue);
      expect(out.actionItems, ['Answer by Friday']);
      expect(out.replyExpected, isTrue);
      expect(out.deadline, 'Friday');
    });

    test('a message that named no deadline keeps the empty string', () {
      // Never null: the run file's one trap is that an empty deadline is the
      // ANSWER "this message named none", while a null is a stage that never
      // ran, and the scorer reads the difference.
      final out = triageOut(TriageResult.fallback());
      expect(out.deadline, '');
    });

    test('extraction copies every field', () {
      final out = extractOut(const ExtractionResult(
        evidence: 'capped at 18,000',
        topics: ['allowance'],
        people: ['Dana Whitfield'],
        organizations: ['Harbor Lane'],
        project: 'River Street office',
        intent: 'request',
        importance: 'high',
      ));
      expect(out.evidence, 'capped at 18,000');
      expect(out.topics, ['allowance']);
      expect(out.people, ['Dana Whitfield']);
      expect(out.organizations, ['Harbor Lane']);
      expect(out.project, 'River Street office');
      expect(out.intent, 'request');
      expect(out.importance, 'high');
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

    test('a reply decision copies its verdict and its reason', () {
      final out = decisionOut(const ReplyDecisionResult(
        needsReply: true,
        reason: 'The sender asks a direct question.',
      ));
      expect(out.needsReply, isTrue);
      expect(out.reason, 'The sender asks a direct question.');
    });
  });

  // ── the verdict the handler would have written ────────────────────────
  group('needs-you records the handler’s verdict, not the model’s boolean', () {
    test('a confident yes is a yes', () {
      final out = needsYouOut(const NeedsYouResult(
        evidence: 'A direct question.',
        needsYou: true,
        confidence: 'high',
      ));
      expect(out.verdict, isTrue);
      expect(out.confidence, 'high');
      expect(out.evidence, 'A direct question.');
      expect(out.floor, isFalse);
    });

    test('a low-confidence yes is a no, with the confidence kept', () {
      final out = needsYouOut(const NeedsYouResult(
        evidence: 'Possibly about the owner.',
        needsYou: true,
        confidence: 'low',
      ));
      expect(out.verdict, isFalse);
      expect(out.confidence, 'low');
    });

    test('a no stays a no however confident', () {
      final out = needsYouOut(const NeedsYouResult(
        evidence: 'A broadcast.',
        needsYou: false,
        confidence: 'high',
      ));
      expect(out.verdict, isFalse);
    });

    test('the floor answers yes and claims no confidence at all', () {
      final out = floorOut();
      expect(out.verdict, isTrue);
      expect(out.confidence, isNull);
      expect(out.floor, isTrue);

      final json = (GoldenRunEntry(
        id: 'teams:fx-floor',
        stratum: 'needsyou-hard',
        difficulty: 'medium',
      )..needsYou = out)
          .toScoreRunJson()['needs_you'] as Map<String, Object?>;
      expect(json.containsKey('confidence'), isFalse);
      expect(json['floor'], isTrue);
      expect(json['verdict'], isTrue);
    });

    test('an item the floor settles is one the fixture can point at', () {
      // The live replay branches on exactly this, so the mapping is only
      // meaningful if the flag it reads means what it claims.
      expect(set.byId['teams:fx-floor']!.floorSaysYes, isTrue);
      expect(set.byId['email:fx-reply']!.floorSaysYes, isFalse);
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

    test('a floor answer with no call is still a row', () {
      expect((entry()..needsYou = floorOut()).attempted, isTrue);
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
    )..decision = decisionOut(const ReplyDecisionResult(
        needsReply: true,
        reason: 'A direct question is open.',
      ));
    final json = entry.toScoreRunJson();
    expect(json['triage'], {'reply_expected': true});
    expect(json['decision'], {
      'needs_reply': true,
      'reason': 'A direct question is open.',
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

  // ── the new files must stay safe for a public repo ────────────────────
  test('nothing new names a host that is not example.com', () {
    // The same check `golden_set_test.dart` holds the fixtures to, over the
    // files this phase added. Naming a real vendor here to exclude it would
    // put that name into a public file, which is the leak the check exists to
    // prevent — so the rule is a whitelist of one.
    final text = [
      'test/llm_golden_live_test.dart',
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
