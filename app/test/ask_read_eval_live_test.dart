@Skip('live — needs the generative server (PROSE_URL). Run: make ask-read-eval')
library;

import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/llm/ask_read_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/ask_reads.dart';
import 'fixtures/bench_target.dart';

/// The model's reading of a scheduling ask, measured (the round's D10;
/// docs/model-bakeoff.md "Ask reading"): every fixture ask through the real
/// `ask_read` task on the generative server ([BenchTarget.prose]), resolved
/// by the same Dart as the app ([readAskHintsFromRead]), scored beside the
/// rules ([readAskHints]) against the fixture's expectation.
///
/// It PRINTS the line the ledger records — `model: m/40 · rules: k/40 ·
/// both: b/40 · disagree: d · failed: f` — and every row where the model
/// missed or the two readers parted, with the phrases the model copied. It
/// asserts shape only: every row came back as a reading (`failed` is 0). A
/// score threshold would fail a model swap for no defect (the repo's
/// live-bench rule).
void main() {
  setUpAll(initCalendarZones);

  test(
    'ask_read over the fixture, scored beside the rules',
    () async {
      final client = BenchTarget.prose.client();
      final cases = loadAskCases();
      var model = 0, rules = 0, both = 0, disagree = 0, failed = 0;
      final lines = <String>[];
      for (final (i, c) in cases.indexed) {
        // ignore: avoid_print
        print('[${i + 1}/${cases.length}] ${c.id}');
        final AskRead read;
        try {
          read = await runTask(
            client,
            const AskReadTask(),
            AskReadInput.at(
              subject: c.subject,
              body: c.body,
              now: c.now,
              sentAt: c.sentAt,
              zone: c.zone,
            ),
            temperature: AskReadTask.temperature,
            maxTokens: AskReadTask.maxTokens,
          );
        } on Object catch (e) {
          // One bad answer is a row, not the run: counted, named, and the
          // rest still read.
          failed += 1;
          lines.add('${c.id}: FAILED ${e.runtimeType}');
          continue;
        }
        final byModel = askOutcome(readAskHintsFromRead(
          read: read,
          subject: c.subject,
          body: c.body,
          now: c.now,
          zone: c.zone,
          sentAt: c.sentAt,
        ));
        final byRules = askOutcome(c.rules());
        final want = c.want;
        final modelRight = byModel == want;
        final rulesRight = byRules == want;
        if (modelRight) model += 1;
        if (rulesRight) rules += 1;
        if (modelRight && rulesRight) both += 1;
        if (byModel != byRules) disagree += 1;
        if (!modelRight || byModel != byRules) {
          lines.add('${c.id}${c.hard ? ' (hard)' : ''}: model $byModel '
              'rules $byRules want $want\n'
              '    copied: asks=${read.asksForTime} when=${read.when} '
              'time="${read.time}" duration="${read.duration}" '
              'meal=${read.meal.wire}');
        }
      }
      final n = cases.length;
      // ignore: avoid_print
      print([
        '',
        '${BenchTarget.prose.label} · ${BenchTarget.prose.model}',
        'model: $model/$n · rules: $rules/$n · both: $both/$n · '
            'disagree: $disagree · failed: $failed',
        ...lines,
      ].join('\n'));
      // Shape only: every row came back as a reading. A score is never
      // asserted.
      expect(failed, 0,
          reason: 'every row must come back as a reading; failures are '
              'printed above');
      expect(n, 40);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
