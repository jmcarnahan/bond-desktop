import 'dart:convert';
import 'dart:io';

import 'bench_stats.dart';
import 'bench_target.dart';

/// A bench run, written down.
///
/// The tables a live bench prints are for the person watching it run. This is
/// for the person comparing it against a run from last Tuesday, which is the
/// whole job of a bakeoff and the one thing scrollback cannot do: two candidates
/// are only comparable if both runs survive in a form something can diff — see
/// `tool/bench_compare.dart`, which reads exactly this.
///
/// Writing is OPT-IN, off unless `BENCH_OUT` is defined. `make app-test` runs
/// the whole suite on every change and must never leave a file behind.

/// `omlx/Qwen3-4B 4bit` → `omlx-qwen3-4b-4bit`. A label is written for a human
/// and lands in a filename, so every run of anything that is not a letter or a
/// digit collapses to one hyphen.
String slug(String label) {
  final collapsed =
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return collapsed.replaceAll(RegExp(r'^-+|-+$'), '');
}

/// The result document, built without touching the disk.
///
/// Split out from [writeBenchResult] so the shape can be asserted offline: the
/// only other way to check it would be to run a live bench with a define set,
/// which is exactly the thing that is not available on a machine without a
/// model server.
Map<String, Object?> benchResultJson({
  required String bench,
  required List<CallCollector> collectors,
  required List<Scorecard> accuracy,
  required DateTime startedAt,
  required DateTime finishedAt,
  Map<String, Object?> extra = const {},
}) =>
    {
      // Bumped when a reader would break on the change. `bench_compare` reads
      // this before it reads anything else.
      'schema': 1,
      'bench': bench,
      'started_at': startedAt.toUtc().toIso8601String(),
      'finished_at': finishedAt.toUtc().toIso8601String(),
      'targets': [
        for (final c in collectors)
          {
            'label': c.label,
            'url': c.url,
            'model': c.model,
            'reasoning_leaks': c.reasoningLeaks,
            'tasks': [
              for (final m in c.tasks)
                {
                  'task': m.task,
                  'n': m.n,
                  'failures': m.failures,
                  'p50_ms': m.p50Ms,
                  // Null on every task that does not stream, which is all of
                  // them but the draft. Additive, so `schema` stays 1.
                  'first_token_p50_ms': m.firstTokenP50Ms,
                  'p95_ms': m.p95Ms,
                  'mean_ms': m.meanMs,
                  'total_ms': m.totalMs,
                  'prompt_tokens': m.promptTokens,
                  'completion_tokens': m.completionTokens,
                  // Null stays null through the file. A runtime that reports no
                  // timings must not read downstream as one that generates
                  // nothing, which is what a 0 here would say.
                  'gen_tps': m.genTps,
                  'gen_tps_server': m.serverGenTps,
                  'prompt_tps': m.promptTps,
                  'timing_source': m.timingSource,
                },
            ],
          },
      ],
      'accuracy': [
        for (final card in accuracy)
          {
            'dimension': card.dimension,
            'hits': card.hits,
            'judged': card.judged,
            'misses': card.misses,
          },
      ],
      'extra': extra,
    };

/// Writes the run to `BENCH_OUT` and returns the path, or null when no
/// directory was defined and nothing was written.
/// [label] names the run when there is no collector to name it — a stage that
/// dials no model has no target, and two rows of one bench would otherwise
/// land on one filename a second apart. It rides in `extra` as well as in the
/// name, because the result schema has no column for it. Omitted, every
/// filename is byte-identical to what it has always been.
Future<String?> writeBenchResult({
  required String bench,
  required List<CallCollector> collectors,
  required List<Scorecard> accuracy,
  required DateTime startedAt,
  String? label,
  Map<String, Object?> extra = const {},
}) async {
  final dir = BenchTarget.outDir;
  if (dir.isEmpty) return null;

  final finishedAt = DateTime.now();
  final json = benchResultJson(
    bench: bench,
    collectors: collectors,
    accuracy: accuracy,
    startedAt: startedAt,
    finishedAt: finishedAt,
    extra: label == null ? extra : {'label': label, ...extra},
  );

  await Directory(dir).create(recursive: true);
  // Named by what ran, against what, and when — because a bakeoff's second
  // question is always "was that before or after the flag change?", and a
  // filename that answered only the first would need a notebook beside it.
  // The collector's label first, because that is what every existing filename
  // was built from; then an explicit [label]; then the bench's own name, which
  // is what a bench with neither has always fallen back to.
  final named = collectors.isNotEmpty
      ? collectors.first.label
      : (label ?? bench);
  final name = '$bench-${slug(named)}-${stamp(finishedAt.toUtc())}.json';
  final path = '$dir${Platform.pathSeparator}$name';
  await File(path)
      .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  return path;
}

/// `20260903-141205`, UTC — sortable, and the same instant whichever machine
/// ran it.
///
/// Public because it is not this file's alone: `golden_run.dart` writes the
/// other half of a golden run and must name it the same way, and two copies of
/// a filename convention drift the day one of them is edited.
String stamp(DateTime utc) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}'
      '-${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
}
