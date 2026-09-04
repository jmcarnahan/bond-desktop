@Skip('live — needs the 27B llama-server on :8080. Run: make bench-prose')
library;

import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/prose_cases.dart';

/// The other half of the bakeoff: what the PROSE slot costs and what it writes.
///
/// `llm_bench_live_test.dart` times triage and extraction on the bulk slot,
/// which is most of the app's model calls and none of its visible output. This
/// times the two tasks a person actually reads — the storyline title on a card
/// and the reply waiting in a composer — because a candidate runtime that
/// halves latency and writes worse drafts has not won anything, and a table of
/// milliseconds cannot say so.
///
/// It runs against [BenchTarget.prose], by default the 27B on :8080. Point it
/// elsewhere with `make bench-prose PROSE_URL=… PROSE_LABEL=…`.
///
/// There is no scorecard here, and that is the design rather than an omission.
/// A title is right when its owner recognizes the thing it names, and a draft
/// is right when the person about to press Send does not have to rewrite it —
/// neither is a string comparison, and inventing one would score the model
/// against whatever phrasing happened to be typed into a fixture. So every
/// answer is PRINTED VERBATIM and a human reads them. What is asserted is
/// shape: an empty title is a broken call, the fallback title is the task's own
/// admission that it could not name the group, and an empty reply body is the
/// exact failure `DraftHandler` retries on.

void main() {
  test(
    'the prose slot names storylines and drafts replies, timed',
    () async {
      // Every number below comes from the client's own call records rather
      // than a stopwatch at the call site: the same clock the token counts are
      // divided by, and the same one the app's activity log shows, so the two
      // are quotable against each other.
      final collector = BenchTarget.prose.collector();
      final client = BenchTarget.prose.client(onCall: collector.record);
      client.onReasoningLeak = collector.noteLeak;

      final lines = <String>[];

      // Thrown away, and on a client with no observer, so the first call's
      // weight-loading cost lands nowhere near the table. Cold against warm is
      // a 20x difference on this machine; one cold call in the sample does not
      // move the median, it replaces it.
      final warmupClient = BenchTarget.prose.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        await runTask(
          warmupClient,
          const NameStorylineTask(),
          NameInput(nameCases.first.cards),
          temperature: 0,
          think: BenchTarget.allowReasoning,
        );
      }

      final startedAt = DateTime.now();

      // The table prints even when a call fails mid-run: a failure on the
      // eighth case is exactly when the seven answers already paid for are
      // worth reading, along with which case broke.
      var current = '';
      try {
        for (final nameCase in nameCases) {
          current = nameCase.id;

          final result = await runTask(
            client,
            const NameStorylineTask(),
            NameInput(nameCase.cards),
            // As the service runs it: naming the same storyline twice must
            // give the same title, or a rename is just the sampler.
            temperature: 0,
            think: BenchTarget.allowReasoning,
          );

          final ms = collector.lastFor('storyline_name')!.durationMs;

          // Verbatim, all three fields. The title is what a card shows, the
          // summary is what sits under it, and the charter is what every later
          // membership call is judged against — a good title on top of a vague
          // charter is a storyline that will quietly swallow the next
          // unrelated thread.
          lines.add(
            '\n${nameCase.id.padRight(24)} ${ms.toString().padLeft(6)}ms\n'
            '  title:    ${result.title}\n'
            '  summary:  ${result.summary}\n'
            '  charter:  ${result.charter}\n'
            '  evidence: ${result.evidence}',
          );

          // Shape, not quality: the words are a judgement and are only
          // printed. The fallback title is the exception — it is not a bad
          // name, it is the task saying it produced none.
          expect(result.title, isNotEmpty, reason: nameCase.id);
          expect(result.title, isNot(NameStorylineTask.fallbackTitle),
              reason: nameCase.id);
          expect(result.evidence, isNotEmpty, reason: nameCase.id);
        }

        for (final draftCase in draftCases) {
          current = draftCase.id;
          final thread = [
            for (final entry in draftThread(draftCase)) entry.message,
          ];

          final result = await runTask(
            client,
            const DraftTask(),
            DraftInput(
              thread: thread,
              // The last message, which `prose_cases_test.dart` pins as
              // inbound: the one the reply answers.
              replyTo: thread.last,
              styleExamples: const [],
              storylineSummary: null,
              aboutMe: null,
              now: DateTime.now(),
            ),
            // Exactly `DraftHandler`'s parameters — temperature 0 and the
            // 1536-token ceiling a reply needs. A bench of parameters the app
            // does not use benches nothing: at the default 512 a 150-word
            // draft comes back grammar-valid and cut off mid-sentence, which
            // would read here as the model writing badly.
            temperature: 0,
            maxTokens: 1536,
            think: BenchTarget.allowReasoning,
          );

          final ms = collector.lastFor('draft_reply')!.durationMs;

          lines.add(
            '\n${draftCase.id.padRight(24)} ${ms.toString().padLeft(6)}ms  '
            '(${thread.length} message${thread.length == 1 ? '' : 's'})\n'
            '  evidence: ${result.evidence}\n'
            '${result.options.isEmpty ? '  options:  (none)\n' : result.options.map((o) => '  option:   ${o.stance}: ${o.body}\n').join()}'
            '  reply:\n'
            '${result.replyBody.split('\n').map((line) => '    $line').join('\n')}',
          );

          // Shape again. An empty reply body is not a debatable draft — it is
          // the exact condition `DraftHandler` throws on and the worker
          // retries, so it is a failed call however well-formed the JSON was.
          expect(result.evidence, isNotEmpty, reason: draftCase.id);
          expect(result.replyBody, isNotEmpty, reason: draftCase.id);
        }
      } catch (error) {
        lines.add('FAILED on $current: $error');
        rethrow;
      } finally {
        // ignore: avoid_print
        print(
          '\n${collector.banner}\n'
          '\n${collector.table()}\n'
          '\n=== prose, verbatim — read these rather than scoring them ===\n'
          '${lines.join('\n')}\n',
        );
        // `accuracy` is empty on purpose: there is nothing here a scorecard
        // could count without inventing an expectation for prose.
        final path = await writeBenchResult(
          bench: 'prose',
          collectors: [collector],
          accuracy: const [],
          startedAt: startedAt,
        );
        // ignore: avoid_print
        if (path != null) print('wrote $path');
      }

      // Not a judgement call: a build that ignores enable_thinking runs at
      // half speed, and every number above would be measuring that instead of
      // the model. A candidate that cannot be told to stop reasoning is the
      // one exception, and it has to say so deliberately.
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
