import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_stats.dart';

/// The bench's arithmetic, checked without a model server.
///
/// The live benchmarks that use this file are skipped everywhere except a
/// machine with llama-server running, which means a mistake in the averaging
/// would be discovered by someone reading a wrong number in a bakeoff table
/// and believing it. These tests are the only thing standing between a
/// division and that meeting, so they pin the arithmetic that a table cannot
/// show its own error in — above all the difference between a time-weighted
/// rate and a mean of rates, which look alike and differ by a third.
LlmCallRecord call({
  String label = 'triage',
  required int durationMs,
  String outcome = 'ok',
  int? promptTokens,
  int? completionTokens,
  int? serverPromptMs,
  int? serverPredictedMs,
}) =>
    LlmCallRecord(
      label: label,
      durationMs: durationMs,
      outcome: outcome,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      serverPromptMs: serverPromptMs,
      serverPredictedMs: serverPredictedMs,
    );

TaskMetrics metricsOf(List<LlmCallRecord> records, {String task = 'triage'}) {
  final m = TaskMetrics(task);
  for (final r in records) {
    m.add(r);
  }
  return m;
}

void main() {
  group('percentile', () {
    // Pinned rather than re-derived: two live tests and every table below sit
    // on these exact semantics, and "nearest rank" has enough plausible
    // definitions that a rewrite could change every historical number without
    // looking wrong.
    test('an empty sample is zero, not an error', () {
      expect(percentile(const [], 0.5), 0);
    });

    test('one sample is its own median and its own p95', () {
      expect(percentile(const [42], 0.5), 42);
      expect(percentile(const [42], 0.95), 42);
    });

    test('p50 and p95 of a known list', () {
      const sorted = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
      expect(percentile(sorted, 0.5), 50);
      expect(percentile(sorted, 0.95), 100);
    });
  });

  group('TaskMetrics generation speed', () {
    test('is weighted by time, not averaged across calls', () {
      // 10 tokens/second and 50 tokens/second. A mean of the two rates says
      // 30; what the machine actually sustained is 110 tokens in 3 seconds,
      // and the long answer is the one anybody waited for.
      final m = metricsOf([
        call(durationMs: 1000, completionTokens: 10),
        call(durationMs: 2000, completionTokens: 100),
      ]);

      expect(m.genTps, closeTo(110 * 1000 / 3000, 0.001));
      expect(m.genTps, isNot(closeTo(30, 1)));
    });

    test('prompt speed is the same shape over prompt tokens', () {
      final m = metricsOf([
        call(durationMs: 1000, promptTokens: 800),
        call(durationMs: 1000, promptTokens: 400),
      ]);

      expect(m.promptTps, closeTo(1200 * 1000 / 2000, 0.001));
    });

    test('a call that reported no tokens still counts as a call', () {
      final m = metricsOf([
        call(durationMs: 1000, completionTokens: 10),
        call(durationMs: 3000),
      ]);

      expect(m.n, 2);
      expect(m.p95Ms, 3000);
      expect(m.completionTokens, 10);
      // The untokened call's 3 seconds are NOT in the denominator: counting
      // them would report a rate no call achieved.
      expect(m.genTps, closeTo(10, 0.001));
    });

    test('no tokens anywhere reads as unknown, never as zero', () {
      final m = metricsOf([call(durationMs: 1000), call(durationMs: 2000)]);

      expect(m.genTps, isNull);
      expect(m.promptTps, isNull);
      expect(m.completionTokens, 0);
    });
  });

  group('TaskMetrics failures', () {
    test('are counted apart and kept out of the latency numbers', () {
      // The 3ms 400 is the point: a rejected request is not a fast answer, and
      // leaving it in the sample would report a median twice as good as
      // anything that happened.
      final m = metricsOf([
        call(durationMs: 1000, outcome: 'ok'),
        call(durationMs: 1000, outcome: 'ok'),
        call(durationMs: 3, outcome: 'error'),
        call(durationMs: 5, outcome: 'unavailable'),
      ]);

      expect(m.n, 2);
      expect(m.failures, 2);
      expect(m.p50Ms, 1000);
      expect(m.meanMs, 1000);
      expect(m.totalMs, 2000);
    });

    test('a task with nothing but failures reports zeros, not a crash', () {
      final m = metricsOf([call(durationMs: 3, outcome: 'error')]);

      expect(m.n, 0);
      expect(m.meanMs, 0);
      expect(m.p50Ms, 0);
      expect(m.genTps, isNull);
      expect(m.timingSource, 'none');
    });
  });

  group('TaskMetrics server timings', () {
    test('server speed divides by the server clock, not the wall', () {
      final m = metricsOf([
        call(durationMs: 1200, completionTokens: 40, serverPredictedMs: 1000),
        call(durationMs: 2400, completionTokens: 60, serverPredictedMs: 2000),
      ]);

      expect(m.serverGenTps, closeTo(100 * 1000 / 3000, 0.001));
      // The wall-clock rate is lower by exactly the overhead the caller paid.
      expect(m.genTps, closeTo(100 * 1000 / 3600, 0.001));
    });

    test('a runtime that sends no timings reports no server speed', () {
      final m = metricsOf([call(durationMs: 1000, completionTokens: 40)]);

      expect(m.serverGenTps, isNull);
    });

    test('the source is the server only when every call reported one', () {
      expect(
        metricsOf([
          call(durationMs: 1000, serverPredictedMs: 900),
          call(durationMs: 2000, serverPredictedMs: 1800),
        ]).timingSource,
        'server',
      );
      expect(
        metricsOf([call(durationMs: 1000), call(durationMs: 2000)]).timingSource,
        'wall',
      );
      // Mixed falls back to the wall: a server column computed over half the
      // calls is worse than no server column.
      expect(
        metricsOf([
          call(durationMs: 1000, serverPredictedMs: 900),
          call(durationMs: 2000),
        ]).timingSource,
        'wall',
      );
    });
  });

  group('CallCollector', () {
    test('buckets by task and remembers the last call of each', () {
      final c = CallCollector(
        label: 'fast (default)',
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3.8',
      );

      c.record(call(label: 'triage', durationMs: 100, completionTokens: 10));
      c.record(call(label: 'extraction', durationMs: 200));
      c.record(call(label: 'triage', durationMs: 300));

      expect(c.tasks.map((t) => t.task), ['triage', 'extraction']);
      expect(c.metricsFor('triage').n, 2);
      expect(c.lastFor('triage')!.durationMs, 300);
      expect(c.lastFor('draft_reply'), isNull);
    });

    test('a failed call is still the last call of its task', () {
      // The per-message line prints from `lastFor`, and the message that broke
      // the run is the one worth printing.
      final c = CallCollector(label: 'x', url: 'y', model: 'z');
      c.record(call(durationMs: 100));
      c.record(call(durationMs: 4, outcome: 'error'));

      expect(c.lastFor('triage')!.outcome, 'error');
    });

    test('counts reasoning leaks', () {
      final c = CallCollector(label: 'x', url: 'y', model: 'z');
      expect(c.reasoningLeaks, 0);
      c.noteLeak();
      c.noteLeak();
      expect(c.reasoningLeaks, 2);
    });

    test('the banner names the machine the numbers came from', () {
      final c = CallCollector(
        label: 'fast (default)',
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3.8',
      );

      expect(
        c.banner,
        '=== target: fast (default) — '
        'http://localhost:8082/v1/chat/completions (model qwen3.8) ===',
      );
    });

    test('the table carries every column, with dashes for what was not measured',
        () {
      final c = CallCollector(label: 'x', url: 'y', model: 'z');
      c.record(call(label: 'triage', durationMs: 1000, completionTokens: 10));
      c.record(call(label: 'extraction', durationMs: 500));

      final table = c.table();
      final rows = table.split('\n');

      expect(
        rows.first,
        '| task | n | fail | p50 ms | p95 ms | mean ms | total s '
        '| prompt tok | gen tok | gen t/s | gen t/s (srv) | prompt t/s |',
      );
      expect(rows[2], startsWith('| triage | 1 | 0 | 1000 |'));
      // No server timings anywhere and no prompt tokens, so those cells are
      // dashes rather than a confident 0.0.
      expect(rows[2], contains('| 10.0 | — | — |'));
      expect(rows[3], startsWith('| extraction | 1 | 0 | 500 |'));
      expect(rows[3], endsWith('| — | — | — |'));
    });
  });

  group('Scorecard', () {
    test('a match is a hit and leaves no miss behind', () {
      final card = Scorecard('category (exact)')
        ..judge('flight-confirm', matched: true);

      expect(card.hits, 1);
      expect(card.judged, 1);
      expect(card.misses, isEmpty);
    });

    test('a miss records the detail, or the id alone when there is none', () {
      final card = Scorecard('category (exact)')
        ..judge('dinner', matched: false, detail: 'category personal != work')
        ..judge('receipt', matched: false);

      expect(card.hits, 0);
      expect(card.judged, 2);
      expect(card.misses, [
        'dinner: category personal != work',
        'receipt',
      ]);
    });

    test('an expectation the corpus never made is simply not judged', () {
      // The caller skips `judge` for a null expectation, so an unannotated
      // entry moves neither number — a rate stays a statement about the model
      // rather than about how much of the corpus has been filled in.
      final card = Scorecard('needs_action (exact)')..judge('a', matched: true);

      expect(card.judged, 1);
      expect(pct(card.hits, card.judged), '100% (1/1)');
    });
  });

  group('pct', () {
    test('nothing judged is a dash, not a division', () {
      expect(pct(0, 0), '—');
    });

    test('a rate carries the raw counts beside it', () {
      expect(pct(13, 17), '76% (13/17)');
      expect(pct(0, 4), '0% (0/4)');
    });
  });

  group('scorecardBlock', () {
    test('lists the rates, then the disagreements', () {
      final category = Scorecard('category (exact)')
        ..judge('a', matched: true)
        ..judge('b', matched: false, detail: 'category work != personal');
      final label = Scorecard('label (contains)')..judge('a', matched: true);

      final block = scorecardBlock([category, label]);

      expect(block, contains('| dimension | hits/judged | rate |'));
      expect(block, contains('| category (exact) | 1/2 | 50% (1/2) |'));
      expect(block, contains('| label (contains) | 1/1 | 100% (1/1) |'));
      expect(block, contains('b: category work != personal'));
      expect(block, isNot(contains('no disagreements')));
    });

    test('says so plainly when the model agreed with everything', () {
      final block =
          scorecardBlock([Scorecard('category (exact)')..judge('a', matched: true)]);

      expect(block, contains('no disagreements with the corpus'));
    });
  });
}
