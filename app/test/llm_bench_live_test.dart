@Skip('live — needs the FAST llama-server on :8082. Run: make bench (or '
    'flutter test test/llm_bench_live_test.dart --run-skipped)')
library;

import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';

/// The number every perf phase is judged against.
///
/// Skipped by default for the same reason `llm_live_test.dart` is — it needs a
/// server the CI box does not have — but it exists for a different job. That
/// file asks whether the model answers at all; this one asks how long it takes
/// to answer the same corpus, every time, so two phases' numbers can be put
/// next to each other and mean something.
///
/// It times the ONE generative call a kept message costs: [MessageTextTask]
/// (summary, action items, deadline, topics, project), as `ExtractHandler`
/// runs it. Triage and extraction used to be two calls here; since the
/// decision model, everything a classifier can answer — category, urgency,
/// needs_action, reply_expected, intent, importance, the gate — is the
/// decision model's (an embedding model plus Dart heads, `make decide`), not
/// this slot's. So the old category / label / needs_action scorecards are
/// gone: none of those fields is the generative model's answer any more, and
/// the decision model is benched against the golden set instead
/// (`make golden-decision`).
///
/// It runs against [BenchTarget.bulk] — by default the FAST server on :8082,
/// not the 27B, because that is where the message text is written. Point it
/// elsewhere with `make bench BENCH_URL=… BENCH_LABEL=…` to bench a candidate
/// runtime without editing anything here; `make ab` is where two servers are
/// put side by side deliberately.
///
/// It prints rather than asserts, almost entirely on purpose. What is asserted
/// is shape — a summary that came back empty is a broken call, not a debatable
/// answer — and the one thing that is never a judgement call: that
/// `enable_thinking: false` was honoured.

void main() {
  test(
    'the corpus through the message text call, timed',
    () async {
      // Every number in the table below comes from the client's own call
      // records rather than from a stopwatch wrapped around the call site.
      // `durationMs` is the HTTP round trip as the client measured it — the
      // same clock the token counts come from, so tokens per second is a rate
      // and not two unrelated measurements divided; the same number the
      // ActivityLog shows a user, so the bench and the app are quotable
      // against each other; and the only clock that still means anything once
      // calls overlap, where a stopwatch around an awaited call times the
      // queue rather than the request.
      final collector = BenchTarget.bulk.collector();
      final client = BenchTarget.bulk.client(onCall: collector.record);
      client.onReasoningLeak = collector.noteLeak;

      final emails = emailCorpus
          .where((entry) => entry.expectedGate == null)
          .toList();
      final lines = <String>[];

      // Thrown away, and on a client with no observer, so the first call's
      // weight-loading cost lands nowhere near the table. Cold against warm is
      // a 20x difference on this machine; one cold call in the sample does not
      // move the median, it replaces it.
      final warmupClient = BenchTarget.bulk.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        await runTask(
          warmupClient,
          const MessageTextTask(),
          MessageTextInput(emails.first.message, DateTime.now()),
          // Warmed the way the run itself will be measured: a candidate that
          // needs BENCH_THINK would 400 here otherwise, and a warmup that
          // failed would leave the first timed call cold.
          temperature: 0,
          think: BenchTarget.allowReasoning,
        );
      }

      final startedAt = DateTime.now();

      // The table prints even when a call fails mid-run. A later phase points
      // this bench at an experimental server config, and a failure on the
      // fifteenth email is exactly when the fourteen numbers already paid for
      // are worth reading — along with which email broke.
      var current = '';
      try {
        for (final entry in emails) {
          current = entry.id;

          final text = await runTask(
            client,
            const MessageTextTask(),
            MessageTextInput(entry.message, DateTime.now()),
            // As the handler runs it: the same email twice must be the same
            // facts, or a phase's "improvement" is just sampling noise.
            temperature: 0,
            // Off unless BENCH_THINK says this candidate cannot be told to
            // stop reasoning, in which case the body stops asking it to.
            think: BenchTarget.allowReasoning,
          );

          final textMs = collector.lastFor('message_text')!.durationMs;

          // Counts, not content: how much the model wrote, never what. The
          // corpus is fictional, so the topics are printed too — they are
          // the short labels the clustering card reads, and a glance at them
          // is how a broken grammar shows.
          lines.add(
            '${entry.id.padRight(26)} '
            'message_text ${textMs.toString().padLeft(6)}ms  '
            'summary ${text.summary.length.toString().padLeft(3)} chars  '
            'action_items=${text.actionItems.length}  '
            'deadline=${text.deadline.isNotEmpty}  '
            'topics=${text.topics.length} ${text.topics}',
          );

          // Shape, not quality: an empty summary is a call that went wrong,
          // while the words inside it are the model's judgement.
          expect(text.summary, isNotEmpty, reason: entry.id);

          // The one entry worth reading by hand: whether the model treated the
          // instruction in the body as data or as an instruction. Fictional
          // corpus, so printed verbatim.
          if (entry.id == 'prompt-injection') {
            lines.add(
              '  injection summary: ${text.summary}\n'
              '  injection action items: ${text.actionItems}',
            );
          }
        }
      } catch (error) {
        lines.add('FAILED on $current: $error');
        rethrow;
      } finally {
        // ignore: avoid_print
        print(
          '\n${collector.banner}\n'
          '\n${collector.table()}\n'
          '\n${lines.join('\n')}\n',
        );
        // `accuracy` is empty: nothing this call answers has a right answer
        // in the corpus's annotations any more — those were classifier
        // fields, and they are the decision model's now.
        final path = await writeBenchResult(
          bench: 'message-text',
          collectors: [collector],
          accuracy: const [],
          startedAt: startedAt,
        );
        // ignore: avoid_print
        if (path != null) print('wrote $path');
      }

      // Not a judgement call: a build that ignores enable_thinking runs at
      // half speed, and every number above would be measuring that instead of
      // the change under test. A candidate that cannot be told to stop
      // reasoning is the one exception, and it has to say so deliberately.
      if (BenchTarget.allowReasoning) {
        // ignore: avoid_print
        print('reasoning leaks: ${collector.reasoningLeaks} '
            '(not asserted — BENCH_THINK is set)');
      } else {
        expect(collector.reasoningLeaks, 0,
            reason: 'the model reasoned despite enable_thinking');
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
