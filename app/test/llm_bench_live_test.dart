@Skip('live — needs the FAST llama-server on :8082. Run: make bench (or '
    'flutter test test/llm_bench_live_test.dart --run-skipped)')
library;

import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';

/// The number every perf phase is judged against.
///
/// Skipped by default for the same reason `llm_live_test.dart` is — it needs a
/// server the CI box does not have — but it exists for a different job. That
/// file asks whether the model answers at all; this one asks how long it takes
/// to answer the same seventeen emails, every time, so two phases' numbers can
/// be put next to each other and mean something.
///
/// It runs against [BenchTarget.bulk] — by default the FAST server on :8082,
/// not the 27B, because since phase 3 that is where triage and extraction
/// actually happen. Benching them on the server the app no longer uses for
/// them would compare a phase's number against a path nobody takes; `make ab`
/// is where two servers are put side by side deliberately. Point it elsewhere
/// with `make bench BENCH_URL=… BENCH_LABEL=…` to bench a candidate runtime
/// without editing anything here.
///
/// It prints rather than asserts, almost entirely on purpose. A small model's
/// category is a judgement, and a test that pinned it would fail on the next
/// model swap for no defect. What is asserted is shape — a result that came
/// back empty is a broken call, not a debatable label — and the one thing that
/// is never a judgement call: that `enable_thinking: false` was honoured.

void main() {
  test(
    'the corpus through triage and extraction, timed',
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
          const TriageTask(),
          TriageInput(emails.first.message, DateTime.now()),
        );
      }

      final startedAt = DateTime.now();

      // Where the model disagreed with the corpus. Scored and printed, not
      // asserted: a category and a label are judgements, and pinning them
      // would fail the bench on the next model swap for no defect. An entry
      // the corpus has no opinion about is never judged at all, so a rate is
      // over what was asked rather than over the corpus's annotation coverage.
      final categoryCard = Scorecard('category (exact)');
      final labelCard = Scorecard('label (contains)');
      final needsActionCard = Scorecard('needs_action (exact)');

      // The table prints even when a call fails mid-run. A later phase points
      // this bench at an experimental server config, and a failure on the
      // fifteenth email is exactly when the fourteen numbers already paid for
      // are worth reading — along with which email broke.
      var current = '';
      try {
        for (final entry in emails) {
          current = entry.id;
          final now = DateTime.now();

          final triage = await runTask(
            client,
            const TriageTask(),
            TriageInput(entry.message, now),
          );

          final extraction = await runTask(
            client,
            const ExtractTask(),
            ExtractionInput(entry.message, now),
            // As the handler runs it: the same email twice must be the same
            // facts, or a phase's "improvement" is just sampling noise.
            temperature: 0,
          );

          final triageMs = collector.lastFor('triage')!.durationMs;
          final extractMs = collector.lastFor('extraction')!.durationMs;

          // What the corpus says this message is, next to what the model said
          // it is. `expectedLabel` is a loose fragment on purpose — "dinner
          // plans" and "friday dinner" are both right — so the match is
          // `contains`, and a miss is printed rather than thrown.
          final categoryMiss = entry.expectedCategory != null &&
              entry.expectedCategory != triage.category;
          final labelMiss = entry.expectedLabel != null &&
              !triage.label.toLowerCase().contains(entry.expectedLabel!);
          if (entry.expectedCategory != null) {
            categoryCard.judge(
              current,
              matched: entry.expectedCategory == triage.category,
              detail: 'category '
                  '${entry.expectedCategory} != ${triage.category}',
            );
          }
          if (entry.expectedLabel != null) {
            labelCard.judge(
              current,
              matched: triage.label.toLowerCase().contains(entry.expectedLabel!),
              detail: 'label '
                  '"${entry.expectedLabel}" not in "${triage.label}"',
            );
          }
          if (entry.expectsNeedsAction != null) {
            needsActionCard.judge(
              current,
              matched: entry.expectsNeedsAction == triage.needsAction,
              detail: 'needs_action '
                  '${entry.expectsNeedsAction} != ${triage.needsAction}',
            );
          }

          lines.add(
            '${entry.id.padRight(26)} '
            'triage ${triageMs.toString().padLeft(6)}ms  '
            'extract ${extractMs.toString().padLeft(6)}ms  '
            '${triage.category}${categoryMiss ? '!' : ''}/${triage.urgency}/'
            'needs_action=${triage.needsAction}  '
            'label="${triage.label}"${labelMiss ? '!' : ''}  '
            '${extraction.intent}/${extraction.importance}',
          );

          // Shape, not quality: an empty field is a call that went wrong,
          // while the words inside it are the model's judgement and are only
          // printed.
          expect(triage.category, isNotEmpty, reason: entry.id);
          expect(triage.urgency, isNotEmpty, reason: entry.id);
          expect(triage.label, isNotEmpty, reason: entry.id);
          expect(extraction.intent, isNotEmpty, reason: entry.id);
          expect(extraction.importance, isNotEmpty, reason: entry.id);

          // The one entry worth reading by hand: whether the model treated the
          // instruction in the body as data or as an instruction.
          if (entry.id == 'prompt-injection') {
            lines.add(
              '  injection summary: ${triage.summary}\n'
              '  injection action items: ${triage.actionItems}\n'
              '  injection evidence: ${extraction.evidence}',
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
          '\n${lines.join('\n')}\n'
          '\n${scorecardBlock([categoryCard, labelCard, needsActionCard])}\n',
        );
        final path = await writeBenchResult(
          bench: 'triage-extract',
          collectors: [collector],
          accuracy: [categoryCard, labelCard, needsActionCard],
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
