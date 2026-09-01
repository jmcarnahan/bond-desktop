@Skip('live — needs llama-server on :8080. Run: make bench (or '
    'flutter test test/llm_bench_live_test.dart --run-skipped)')
library;

import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/corpus.dart';

/// The number every perf phase is judged against.
///
/// Skipped by default for the same reason `llm_live_test.dart` is — it needs a
/// server the CI box does not have — but it exists for a different job. That
/// file asks whether the model answers at all; this one asks how long it takes
/// to answer the same seventeen emails, every time, so two phases' numbers can
/// be put next to each other and mean something.
///
/// It prints rather than asserts, almost entirely on purpose. A small model's
/// category is a judgement, and a test that pinned it would fail on the next
/// model swap for no defect. What is asserted is shape — a result that came
/// back empty is a broken call, not a debatable label — and the one thing that
/// is never a judgement call: that `enable_thinking: false` was honoured.

/// p-th percentile, nearest rank. Small n, so nothing fancier would mean more.
int percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

String row(String task, List<int> samples) {
  final sorted = [...samples]..sort();
  final total = samples.fold(0, (sum, ms) => sum + ms);
  final mean = samples.isEmpty ? 0 : total ~/ samples.length;
  return '| $task | ${samples.length} | ${percentile(sorted, 0.5)} '
      '| ${percentile(sorted, 0.95)} | $mean '
      '| ${(total / 1000).toStringAsFixed(1)} |';
}

void main() {
  test(
    'the corpus through triage and extraction, timed',
    () async {
      final client = LlmClient();
      var leaks = 0;
      client.onReasoningLeak = () => leaks++;

      final emails = emailCorpus
          .where((entry) => entry.expectedGate == null)
          .toList();
      final triageMs = <int>[];
      final extractMs = <int>[];
      final lines = <String>[];

      // The table prints even when a call fails mid-run. A later phase points
      // this bench at an experimental server config, and a failure on the
      // fifteenth email is exactly when the fourteen numbers already paid for
      // are worth reading — along with which email broke.
      var current = '';
      try {
        for (final entry in emails) {
          current = entry.id;
          final now = DateTime.now();

          final triageWatch = Stopwatch()..start();
          final triage = await runTask(
            client,
            const TriageTask(),
            TriageInput(entry.message, now),
          );
          triageWatch.stop();

          final extractWatch = Stopwatch()..start();
          final extraction = await runTask(
            client,
            const ExtractTask(),
            ExtractionInput(entry.message, now),
            // As the handler runs it: the same email twice must be the same
            // facts, or a phase's "improvement" is just sampling noise.
            temperature: 0,
          );
          extractWatch.stop();

          triageMs.add(triageWatch.elapsed.inMilliseconds);
          extractMs.add(extractWatch.elapsed.inMilliseconds);

          lines.add(
            '${entry.id.padRight(26)} '
            'triage ${triageWatch.elapsed.inMilliseconds.toString().padLeft(6)}ms  '
            'extract ${extractWatch.elapsed.inMilliseconds.toString().padLeft(6)}ms  '
            '${triage.category}/${triage.urgency}/'
            'needs_action=${triage.needsAction}  '
            '${extraction.intent}/${extraction.importance}',
          );

          // Shape, not quality: an empty label is a call that went wrong.
          expect(triage.category, isNotEmpty, reason: entry.id);
          expect(triage.urgency, isNotEmpty, reason: entry.id);
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
          '\n| task | n | p50 ms | p95 ms | mean ms | total s |\n'
          '| --- | --- | --- | --- | --- | --- |\n'
          '${row('triage', triageMs)}\n'
          '${row('extract', extractMs)}\n'
          '\n${lines.join('\n')}\n',
        );
      }

      // Not a judgement call: a build that ignores enable_thinking runs at
      // half speed, and every number above would be measuring that instead of
      // the change under test.
      expect(leaks, 0, reason: 'the model reasoned despite enable_thinking');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
