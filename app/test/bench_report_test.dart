import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';

/// The bakeoff's file format, checked without a model server.
///
/// The document these tests describe is the only thing that outlives a run's
/// scrollback, and `tool/bench_compare.dart` reads it months later against a
/// candidate nobody has run yet. A field silently renamed or a null quietly
/// turned into a zero would not fail any live bench — it would just make two
/// runs stop being comparable, which is the one thing the file exists for.

CallCollector collectorWith(
  List<LlmCallRecord> records, {
  String label = 'omlx/Qwen3-4B 4bit',
}) {
  final c = CallCollector(
    label: label,
    url: 'http://localhost:9999/v1/chat/completions',
    model: 'qwen3-4b',
  );
  for (final r in records) {
    c.record(r);
  }
  return c;
}

LlmCallRecord ok({
  String label = 'triage',
  required int durationMs,
  int? promptTokens,
  int? completionTokens,
  int? serverPredictedMs,
}) =>
    LlmCallRecord(
      label: label,
      durationMs: durationMs,
      outcome: 'ok',
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      serverPredictedMs: serverPredictedMs,
    );

void main() {
  group('slug', () {
    test('turns a label into something a filename can hold', () {
      expect(slug('omlx/Qwen3-4B 4bit'), 'omlx-qwen3-4b-4bit');
    });

    test('collapses runs and trims the ends', () {
      // Otherwise a label that happens to end in a version suffix produces
      // `...-.json`, and two labels differing only in punctuation collide.
      expect(slug('  llama.cpp — Q4_K_M!! '), 'llama-cpp-q4-k-m');
      expect(slug('---27B (default)---'), '27b-default');
    });
  });

  group('writeBenchResult', () {
    test('writes nothing when no output directory was defined', () async {
      // BENCH_OUT is unset under `flutter test`, which is exactly the state
      // `make app-test` runs in: the suite must never leave a file behind.
      final path = await writeBenchResult(
        bench: 'triage-extract',
        collectors: [collectorWith([ok(durationMs: 100)])],
        accuracy: const [],
        startedAt: DateTime.utc(2026, 9, 3, 12),
      );

      expect(path, isNull);
    });
  });

  group('the result document', () {
    test('carries one entry per task, with the numbers the tables print', () {
      final collector = collectorWith([
        ok(durationMs: 1000, promptTokens: 800, completionTokens: 50),
        ok(durationMs: 3000, promptTokens: 900, completionTokens: 150),
        LlmCallRecord(
          label: 'triage',
          durationMs: 3,
          outcome: 'error',
          statusCode: 400,
        ),
      ]);

      final json = benchResultJson(
        bench: 'triage-extract',
        collectors: [collector],
        accuracy: const [],
        startedAt: DateTime.utc(2026, 9, 3, 12),
        finishedAt: DateTime.utc(2026, 9, 3, 12, 30),
      );

      expect(json['schema'], 1);
      expect(json['bench'], 'triage-extract');
      expect(json['started_at'], '2026-09-03T12:00:00.000Z');
      expect(json['finished_at'], '2026-09-03T12:30:00.000Z');

      final target = (json['targets'] as List).single as Map<String, Object?>;
      expect(target['label'], 'omlx/Qwen3-4B 4bit');
      expect(target['model'], 'qwen3-4b');
      expect(target['reasoning_leaks'], 0);

      final task = (target['tasks'] as List).single as Map<String, Object?>;
      expect(task['task'], 'triage');
      expect(task['n'], 2);
      expect(task['failures'], 1);
      expect(task['p50_ms'], 1000);
      expect(task['p95_ms'], 3000);
      expect(task['mean_ms'], 2000);
      expect(task['total_ms'], 4000);
      expect(task['prompt_tokens'], 1700);
      expect(task['completion_tokens'], 200);
      // 200 tokens over 4s, time-weighted — not the mean of 50/s and 50/s.
      expect(task['gen_tps'], 50.0);
      expect(task['timing_source'], 'wall');
    });

    test('a rate nobody measured stays null rather than becoming zero', () {
      // A runtime that sends no `timings` block reports nothing here. Written
      // as 0 it would read as a server that generated no tokens at all, and
      // the compare tool would print a regression that never happened.
      final json = benchResultJson(
        bench: 'triage-extract',
        collectors: [
          collectorWith([ok(durationMs: 1000, completionTokens: 20)])
        ],
        accuracy: const [],
        startedAt: DateTime.utc(2026, 9, 3, 12),
        finishedAt: DateTime.utc(2026, 9, 3, 12, 1),
      );

      final target = (json['targets'] as List).single as Map<String, Object?>;
      final task = (target['tasks'] as List).single as Map<String, Object?>;
      expect(task['gen_tps_server'], isNull);
      expect(task['prompt_tps'], isNull);
      expect(task['gen_tps'], 20.0);
    });

    test('carries the scorecards and every disagreement under them', () {
      final card = Scorecard('category (exact)')
        ..judge('lock-question', matched: true)
        ..judge('dinner-plans', matched: false, detail: 'category work != life');

      final json = benchResultJson(
        bench: 'triage-extract',
        collectors: [collectorWith([ok(durationMs: 10)])],
        accuracy: [card],
        startedAt: DateTime.utc(2026, 9, 3, 12),
        finishedAt: DateTime.utc(2026, 9, 3, 12, 1),
        extra: const {'agreement': 'unused here'},
      );

      final scored = (json['accuracy'] as List).single as Map<String, Object?>;
      expect(scored['dimension'], 'category (exact)');
      expect(scored['hits'], 1);
      expect(scored['judged'], 2);
      // The rate says how much, the list says what — a run that dropped the
      // misses could not answer whether the awkward third moved.
      expect(scored['misses'], ['dinner-plans: category work != life']);
      expect(json['extra'], {'agreement': 'unused here'});
    });
  });
}
