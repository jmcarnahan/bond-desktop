@Skip('live — needs llama-server on :8080 AND :8082. Run: make ab-membership')
library;

import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_stats.dart';
import 'fixtures/membership_cases.dart';

/// What the charter bought, in verdicts rather than seconds.
///
/// `llm_ab_live_test.dart` runs the corpus through triage and extraction on
/// both servers; this runs the membership eval set through the confirm task on
/// both, and prints where each one lands against the answer a person would
/// give. The set is in `fixtures/membership_cases.dart`, and every case there
/// exists because it is a way this judgement goes wrong — two invoices, a
/// borrowed vocabulary, a stranger joining a project.
///
/// Nothing here asserts a verdict, and that is the design. Membership is a
/// judgement, and an agreement threshold pinned in a test would fail on the
/// next model swap for no defect. What IS asserted is shape — an empty
/// evidence sentence is a broken call, not a debatable one — and, per server,
/// that `enable_thinking: false` was honoured: a reasoning leak makes every
/// latency below a measurement of the leak.
///
/// The big server goes first on every case. Neither ordering is fair — the
/// second call of a pair runs against a warmer machine — but a FIXED order
/// makes the bias the same for all twelve.

/// The SERVICE's reading of an answer, which is the one that decides whether a
/// thread is filed: `low` is a no however confidently the model said yes.
bool _verdict(ConfirmResult result) =>
    result.belongs && result.confidence != 'low';

/// `yes/high`, `no/low` — the answer and how sure it was, in one column.
String _cell(ConfirmResult result) =>
    '${_verdict(result) ? 'yes' : 'no'}/${result.confidence}';

void main() {
  test(
    'the membership eval set through both servers, compared',
    () async {
      final big = LlmClient();
      final fast = LlmClient(baseUrl: LlmClient.fastBaseUrl);
      var bigLeaks = 0;
      var fastLeaks = 0;
      // Counted per client, so a leak names the server that leaked rather than
      // leaving both under suspicion.
      big.onReasoningLeak = () => bigLeaks++;
      fast.onReasoningLeak = () => fastLeaks++;

      final bigMs = <int>[];
      final fastMs = <int>[];
      final lines = <String>[];
      var bigAgree = 0;
      var fastAgree = 0;
      var bigMustPass = 0;
      var fastMustPass = 0;
      var mustPassTotal = 0;
      var judged = 0;

      // The table prints even when a call fails mid-run: a failure on the
      // ninth case is exactly when the eight comparisons already paid for are
      // worth reading, along with which case broke.
      var current = '';
      try {
        for (final entry in membershipCases) {
          current = entry.id;
          final input = ConfirmInput(
            storyline: entry.storyline,
            storylineParticipants: entry.participants,
            candidateCard: entry.candidateCard,
          );

          final bigWatch = Stopwatch()..start();
          final bigResult = await runTask(
            big,
            const ConfirmMembershipTask(),
            input,
            // As the service runs it, on both sides: a disagreement has to be
            // the models differing, not one of them sampling.
            temperature: 0,
          );
          bigWatch.stop();

          final fastWatch = Stopwatch()..start();
          final fastResult = await runTask(
            fast,
            const ConfirmMembershipTask(),
            input,
            temperature: 0,
          );
          fastWatch.stop();

          bigMs.add(bigWatch.elapsed.inMilliseconds);
          fastMs.add(fastWatch.elapsed.inMilliseconds);

          final bigOk = _verdict(bigResult) == entry.expectBelongs;
          final fastOk = _verdict(fastResult) == entry.expectBelongs;
          judged++;
          if (bigOk) bigAgree++;
          if (fastOk) fastAgree++;
          if (entry.mustPass) {
            mustPassTotal++;
            if (bigOk) bigMustPass++;
            if (fastOk) fastMustPass++;
          }

          lines.add(
            '${entry.id.padRight(28)}'
            '${entry.mustPass ? '*' : ' '} '
            '${(entry.expectBelongs ? 'yes' : 'no').padRight(4)} '
            '27B ${_cell(bigResult).padRight(11)}'
            '${bigOk ? ' ' : '!'} '
            '4B ${_cell(fastResult).padRight(11)}'
            '${fastOk ? ' ' : '!'} '
            '${bigWatch.elapsed.inMilliseconds.toString().padLeft(6)}ms '
            '${fastWatch.elapsed.inMilliseconds.toString().padLeft(6)}ms',
          );

          // Shape, not quality: an answer with no evidence sentence is a call
          // that went wrong, on whichever server produced it.
          expect(bigResult.evidence, isNotEmpty, reason: '${entry.id} 27B');
          expect(fastResult.evidence, isNotEmpty, reason: '${entry.id} fast');
        }
      } catch (error) {
        lines.add('FAILED on $current: $error');
        rethrow;
      } finally {
        final bigSorted = [...bigMs]..sort();
        final fastSorted = [...fastMs]..sort();
        // ignore: avoid_print
        print(
          '\n=== membership eval — * must-pass, ! disagrees with expected ===\n'
          '${lines.join('\n')}\n'
          '\n27B: $bigAgree/$judged agree, '
          'must-pass $bigMustPass/$mustPassTotal, '
          'p50 ${percentile(bigSorted, 0.5)}ms\n'
          '4B:  $fastAgree/$judged agree, '
          'must-pass $fastMustPass/$mustPassTotal, '
          'p50 ${percentile(fastSorted, 0.5)}ms\n'
          '\n| task | n | p50 ms | p95 ms | mean ms | total s |\n'
          '| --- | --- | --- | --- | --- | --- |\n'
          '${row('confirm 27B', bigMs)}\n'
          '${row('confirm fast', fastMs)}\n',
        );
      }

      // Per server, and not a judgement call either way: a build that ignores
      // enable_thinking runs at half speed, and every latency above would be
      // measuring that instead of the model.
      expect(bigLeaks, 0, reason: 'the 27B reasoned despite enable_thinking');
      expect(fastLeaks, 0,
          reason: 'the fast model reasoned despite enable_thinking');
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
