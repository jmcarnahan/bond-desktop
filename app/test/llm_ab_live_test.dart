@Skip('live — needs llama-server on :8080 AND :8082. Run: make ab')
library;

import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';

/// What routing the message text to the fast server costs, in words rather
/// than seconds.
///
/// `llm_bench_live_test.dart` says how fast the app's path is now. This says
/// what the choice of server changes: the same corpus, the same prompt, the
/// same clock anchor, through [MessageTextTask] — the one generative call a
/// kept message costs — on BOTH servers, printing where the two differ.
///
/// It used to compare triage and extraction labels (category, urgency,
/// needs_action, intent, importance). Those are the decision model's now, not
/// either generative server's, so what is left to compare is text, and text
/// is compared by counts: how many topics the two sides share, whether they
/// named the same number of action items, whether they read the same
/// deadline. None of those is accuracy — two defensible models word the same
/// topic differently — so nothing here asserts agreement. Someone reads the
/// table and decides whether the routing holds up. What IS asserted is shape
/// (a summary that came back empty is broken, not debatable) and, per server,
/// that `enable_thinking: false` was honoured: a reasoning leak makes every
/// latency below a measurement of the leak.
///
/// The big server goes first on every entry. Neither ordering is fair — the
/// second call of a pair runs against a warmer machine — but a FIXED order at
/// least makes the bias the same for every entry, and the per-server
/// latencies here are context for the bench's numbers rather than a
/// replacement for them.

/// How many of [a]'s topics also appear in [b], compared lowercased and
/// trimmed. The task already lowercases; the trim is belt and braces.
int topicOverlap(List<String> a, List<String> b) {
  final other = {for (final t in b) t.trim().toLowerCase()};
  return a.where((t) => other.contains(t.trim().toLowerCase())).length;
}

/// One corpus entry written twice.
class _Pair {
  final String id;
  final MessageTextResult big;
  final MessageTextResult fast;

  const _Pair({required this.id, required this.big, required this.fast});

  int get sharedTopics => topicOverlap(big.topics, fast.topics);
  bool get sameActionCount => big.actionItems.length == fast.actionItems.length;

  /// Both empty counts as the same: neither side found a deadline.
  bool get sameDeadline =>
      big.deadline.trim().toLowerCase() == fast.deadline.trim().toLowerCase();
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
        final input = MessageTextInput(emails.first.message, DateTime.now());
        // Warmed the way the run itself will be measured: a candidate that
        // needs BENCH_THINK would 400 here otherwise, and a warmup that failed
        // would leave the first timed call cold.
        await runTask(bigWarmup, const MessageTextTask(), input,
            temperature: 0, think: BenchTarget.allowReasoning);
        await runTask(fastWarmup, const MessageTextTask(), input,
            temperature: 0, think: BenchTarget.allowReasoning);
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
          // ONE clock for both calls. The prompt anchors "by tomorrow"
          // against it, so a second DateTime.now() would be a difference
          // between the runs that has nothing to do with the models.
          final input = MessageTextInput(entry.message, DateTime.now());

          // Latency is not timed here: each client's collector already holds
          // the HTTP round trip for every call, measured on the same clock as
          // the token counts it will be divided by.
          final bigText = await runTask(
            big,
            const MessageTextTask(),
            input,
            // As the handler runs it, on both sides: a difference has to be
            // the models differing, not one of them sampling. And one
            // reasoning switch for both servers: an A/B where only one side
            // was asked to stop reasoning would compare a model against
            // itself thinking.
            temperature: 0,
            think: BenchTarget.allowReasoning,
          );

          final fastText = await runTask(
            fast,
            const MessageTextTask(),
            input,
            temperature: 0,
            think: BenchTarget.allowReasoning,
          );

          final pair = _Pair(id: entry.id, big: bigText, fast: fastText);
          pairs.add(pair);

          // Counts only, and the `<<` marks where the two sides named a
          // different number of action items or a different deadline.
          final differs = !pair.sameActionCount || !pair.sameDeadline;
          lines.add(
            '${entry.id.padRight(26)} '
            'big  summary ${bigText.summary.length.toString().padLeft(3)} '
            'actions=${bigText.actionItems.length} '
            'topics=${bigText.topics.length}  '
            'fast summary ${fastText.summary.length.toString().padLeft(3)} '
            'actions=${fastText.actionItems.length} '
            'topics=${fastText.topics.length}  '
            'shared_topics=${pair.sharedTopics} '
            'same_deadline=${pair.sameDeadline}'
            '${differs ? '  <<' : ''}',
          );

          // Shape, not quality: an empty summary is a call that went wrong, on
          // whichever server produced it.
          expect(bigText.summary, isNotEmpty, reason: '${entry.id} big');
          expect(fastText.summary, isNotEmpty, reason: '${entry.id} fast');

          // The entry that decides whether the small model is safe to route
          // untrusted mail through: both answers verbatim (the corpus is
          // fictional), for a human to judge whether either treated the
          // instruction in the body as an instruction rather than as data.
          if (entry.id == 'prompt-injection') {
            injection.addAll([
              '=== PROMPT INJECTION — both servers, verbatim ===',
              '--- ${BenchTarget.prose.label} ---',
              'summary:      ${bigText.summary}',
              'action_items: ${bigText.actionItems}',
              '--- ${BenchTarget.bulk.label} ---',
              'summary:      ${fastText.summary}',
              'action_items: ${fastText.actionItems}',
            ]);
          }
        }
      } catch (error) {
        lines.add('FAILED on $current: $error');
        rethrow;
      } finally {
        final n = pairs.length;
        final actionCount = pairs.where((p) => p.sameActionCount);
        final deadline = pairs.where((p) => p.sameDeadline);
        // Any shared topic at all: two models that both said "invoice" have
        // read the message the same way even if the other two labels differ.
        final anyTopic = pairs.where((p) => p.sharedTopics > 0);
        final sharedTopics =
            pairs.fold<int>(0, (sum, p) => sum + p.sharedTopics);
        final bigTopics =
            pairs.fold<int>(0, (sum, p) => sum + p.big.topics.length);

        // Computed once and both printed and written down: the table above is
        // for whoever is watching the run, the file for whoever compares this
        // candidate against the next one.
        final agreement = {
          'action_count_equal': pct(actionCount.length, n),
          'deadline_equal': pct(deadline.length, n),
          'any_topic_shared': pct(anyTopic.length, n),
          'big_topics_shared': pct(sharedTopics, bigTopics),
        };

        // ignore: avoid_print
        print(
          '\n| agreement | rate |\n'
          '| --- | --- |\n'
          '| action item count (equal) | ${agreement['action_count_equal']} |\n'
          '| deadline (equal) | ${agreement['deadline_equal']} |\n'
          '| any topic shared | ${agreement['any_topic_shared']} |\n'
          '| big topics also in fast | ${agreement['big_topics_shared']} |\n'
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
          bench: 'message-text-ab',
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
