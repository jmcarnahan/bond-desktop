@Skip('live — needs llama-server on :8080 AND :8082. Run: make ab')
library;

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';

/// What phase 3 actually cost, in labels rather than seconds.
///
/// `llm_bench_live_test.dart` says how fast the app's path is now. This says
/// what moving to it changed: the same corpus, the same prompts, the same
/// clock anchor, through triage and extraction on BOTH servers, printing where
/// the 4B and the 27B disagree.
///
/// Nothing here asserts agreement, and that is the design. A category is a
/// judgement — two defensible models will differ on the awkward third of any
/// mailbox — so a threshold pinned in a test would fail on the next model swap
/// for no defect. Someone reads the table and decides whether the routing
/// holds up. What IS asserted is shape (a call that came back empty is broken,
/// not debatable) and, per server, that `enable_thinking: false` was honoured:
/// a reasoning leak makes every latency below a measurement of the leak.
///
/// The big server goes first on every entry. Neither ordering is fair — the
/// second call of a pair runs against a warmer machine — but a FIXED order at
/// least makes the bias the same for all seventeen, and the per-server
/// latencies here are context for the bench's numbers rather than a
/// replacement for them.

/// Urgency, weakest first. Two models that answer `high` and `urgent` have
/// broadly agreed; `low` and `urgent` have not, and a plain exact-match rate
/// cannot tell those two disagreements apart.
const List<String> _urgencyOrder = ['low', 'normal', 'high', 'urgent'];

const List<String> _importanceOrder = ['low', 'normal', 'high'];

/// Whether [a] and [b] sit at most one step apart in [order]. A value the
/// order does not contain counts as a disagreement — it is a validator
/// fallback, not a label the model chose.
bool withinOne(List<String> order, String a, String b) {
  final ia = order.indexOf(a);
  final ib = order.indexOf(b);
  if (ia < 0 || ib < 0) return false;
  return (ia - ib).abs() <= 1;
}

/// One corpus entry judged twice.
class _Pair {
  final String id;
  final TriageResult bigTriage;
  final TriageResult fastTriage;
  final ExtractionResult bigExtract;
  final ExtractionResult fastExtract;

  const _Pair({
    required this.id,
    required this.bigTriage,
    required this.fastTriage,
    required this.bigExtract,
    required this.fastExtract,
  });
}

void main() {
  test(
    'the corpus through both servers, compared',
    () async {
      // One collector per client, never one shared: the whole question here is
      // how the two servers differ, and a single bucket would average them
      // into a machine that does not exist.
      final bigCalls = BenchTarget.prose.collector();
      final fastCalls = BenchTarget.bulk.collector();
      final big = BenchTarget.prose.client(onCall: bigCalls.record);
      final fast = BenchTarget.bulk.client(onCall: fastCalls.record);
      // Counted per client, so a leak names the server that leaked rather than
      // leaving both under suspicion.
      big.onReasoningLeak = bigCalls.noteLeak;
      fast.onReasoningLeak = fastCalls.noteLeak;

      final emails =
          emailCorpus.where((entry) => entry.expectedGate == null).toList();

      // Thrown away, on observer-less clients, so neither table opens with a
      // cold call. Both sides get the same treatment or the comparison is
      // between one warm machine and one that was still loading weights.
      final bigWarmup = BenchTarget.prose.client();
      final fastWarmup = BenchTarget.bulk.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        final input = TriageInput(emails.first.message, DateTime.now());
        await runTask(bigWarmup, const TriageTask(), input);
        await runTask(fastWarmup, const TriageTask(), input);
      }

      final startedAt = DateTime.now();

      final pairs = <_Pair>[];
      final lines = <String>[];
      final injection = <String>[];

      // The tables print even when a call fails mid-run: a failure on the
      // fifteenth email is exactly when the fourteen comparisons already paid
      // for are worth reading, along with which email broke.
      var current = '';
      try {
        for (final entry in emails) {
          current = entry.id;
          // ONE clock for all four calls. The prompts anchor "by tomorrow"
          // against it, so a second DateTime.now() would be a difference
          // between the runs that has nothing to do with the models.
          final now = DateTime.now();

          // Latency is not timed here: each client's collector already holds
          // the HTTP round trip for every call, measured on the same clock as
          // the token counts it will be divided by.
          final bigTriage = await runTask(
            big,
            const TriageTask(),
            TriageInput(entry.message, now),
          );

          final fastTriage = await runTask(
            fast,
            const TriageTask(),
            TriageInput(entry.message, now),
          );

          final bigExtract = await runTask(
            big,
            const ExtractTask(),
            ExtractionInput(entry.message, now),
            // As the handler runs it, on both sides: a disagreement has to be
            // the models differing, not one of them sampling.
            temperature: 0,
          );

          final fastExtract = await runTask(
            fast,
            const ExtractTask(),
            ExtractionInput(entry.message, now),
            temperature: 0,
          );

          pairs.add(_Pair(
            id: entry.id,
            bigTriage: bigTriage,
            fastTriage: fastTriage,
            bigExtract: bigExtract,
            fastExtract: fastExtract,
          ));

          lines.add(
            '${entry.id.padRight(26)} '
            'big  ${bigTriage.category}/${bigTriage.urgency}/'
            'needs_action=${bigTriage.needsAction}  '
            'fast ${fastTriage.category}/${fastTriage.urgency}/'
            'needs_action=${fastTriage.needsAction}'
            '${bigTriage.category == fastTriage.category ? '' : '  <<'}',
          );

          // Shape, not quality: an empty label is a call that went wrong, on
          // whichever server produced it.
          expect(bigTriage.category, isNotEmpty, reason: '${entry.id} big');
          expect(fastTriage.category, isNotEmpty, reason: '${entry.id} fast');
          expect(bigTriage.urgency, isNotEmpty, reason: '${entry.id} big');
          expect(fastTriage.urgency, isNotEmpty, reason: '${entry.id} fast');
          expect(bigExtract.intent, isNotEmpty, reason: '${entry.id} big');
          expect(fastExtract.intent, isNotEmpty, reason: '${entry.id} fast');
          expect(bigExtract.importance, isNotEmpty, reason: '${entry.id} big');
          expect(fastExtract.importance, isNotEmpty,
              reason: '${entry.id} fast');

          // The entry that decides whether the small model is safe to route
          // untrusted mail through: both answers verbatim, for a human to
          // judge whether either treated the instruction in the body as an
          // instruction rather than as data.
          if (entry.id == 'prompt-injection') {
            injection.addAll([
              '=== PROMPT INJECTION — both servers, verbatim ===',
              '--- ${BenchTarget.prose.label} ---',
              'summary:      ${bigTriage.summary}',
              'action_items: ${bigTriage.actionItems}',
              'evidence:     ${bigExtract.evidence}',
              '--- ${BenchTarget.bulk.label} ---',
              'summary:      ${fastTriage.summary}',
              'action_items: ${fastTriage.actionItems}',
              'evidence:     ${fastExtract.evidence}',
            ]);
          }
        }
      } catch (error) {
        lines.add('FAILED on $current: $error');
        rethrow;
      } finally {
        final n = pairs.length;
        final category =
            pairs.where((p) => p.bigTriage.category == p.fastTriage.category);
        final urgency = pairs.where((p) =>
            withinOne(_urgencyOrder, p.bigTriage.urgency, p.fastTriage.urgency));
        final needsAction = pairs
            .where((p) => p.bigTriage.needsAction == p.fastTriage.needsAction);
        final intent =
            pairs.where((p) => p.bigExtract.intent == p.fastExtract.intent);
        final importance = pairs.where((p) => withinOne(_importanceOrder,
            p.bigExtract.importance, p.fastExtract.importance));

        // Computed once and both printed and written down: the table above is
        // for whoever is watching the run, the file for whoever compares this
        // candidate against the next one.
        final agreement = {
          'category_exact': pct(category.length, n),
          'urgency_within_one': pct(urgency.length, n),
          'needs_action_exact': pct(needsAction.length, n),
          'intent_exact': pct(intent.length, n),
          'importance_within_one': pct(importance.length, n),
        };

        // ignore: avoid_print
        print(
          '\n| agreement | rate |\n'
          '| --- | --- |\n'
          '| category (exact) | ${agreement['category_exact']} |\n'
          '| urgency (within one) | ${agreement['urgency_within_one']} |\n'
          '| needs_action (exact) | ${agreement['needs_action_exact']} |\n'
          '| intent (exact) | ${agreement['intent_exact']} |\n'
          '| importance (within one) | ${agreement['importance_within_one']} |\n'
          '\n${bigCalls.banner}\n'
          '\n${bigCalls.table()}\n'
          '\n${fastCalls.banner}\n'
          '\n${fastCalls.table()}\n'
          '\n${lines.join('\n')}\n'
          '\n${injection.join('\n')}\n',
        );

        // `accuracy` is empty on purpose: everything above is model against
        // model, and calling an agreement rate an accuracy would put two
        // models' shared mistake in the column that says they were right.
        final path = await writeBenchResult(
          bench: 'triage-extract-ab',
          collectors: [bigCalls, fastCalls],
          accuracy: const [],
          startedAt: startedAt,
          extra: {'agreement': agreement},
        );
        // ignore: avoid_print
        if (path != null) print('wrote $path');
      }

      // Per server, and not a judgement call either way: a build that ignores
      // enable_thinking runs at half speed, and every latency above would be
      // measuring that instead of the model. A candidate that cannot be told
      // to stop reasoning is the one exception, and it has to say so
      // deliberately.
      if (BenchTarget.allowReasoning) {
        // ignore: avoid_print
        print('reasoning leaks: ${bigCalls.label} ${bigCalls.reasoningLeaks}, '
            '${fastCalls.label} ${fastCalls.reasoningLeaks} '
            '(not asserted — BENCH_THINK is set)');
      } else {
        expect(bigCalls.reasoningLeaks, 0,
            reason: 'the 27B reasoned despite enable_thinking');
        expect(fastCalls.reasoningLeaks, 0,
            reason: 'the fast model reasoned despite enable_thinking');
      }
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
