import 'package:bond_inbox/services/llm/llm_client.dart';

import 'bench_stats.dart';

/// Where a live bench points, and what the report should call it.
///
/// A target is an ordinary VALUE, not configuration the app reads: the live
/// tests construct their own clients, and the dart-defines below are only the
/// defaults the Makefile fills in. Nothing in `lib/` looks at any of this —
/// the app's own servers stay on `LLAMA_URL`/`FAST_LLAMA_URL`, so pointing a
/// bakeoff at an experimental runtime cannot move the app onto it by accident.
///
/// [label] is the whole reason a run is readable a week later. It names the
/// runtime AND the weights (`omlx/qwen3-4b-4bit`), because two candidates that
/// differ only in quantization produce two tables that are otherwise identical.
class BenchTarget {
  /// `bulk` or `prose` — which of the app's two jobs this target stands in
  /// for. Kept so a bench can say what it was benching; the report identifies
  /// targets by [label].
  final String slot;

  final String label;
  final String url;
  final String model;

  const BenchTarget({
    required this.slot,
    required this.label,
    required this.url,
    required this.model,
  });

  /// The bulk-work slot: triage, extraction, membership. Defaults to the fast
  /// server the app already uses, so a bench with no defines benches today.
  static const BenchTarget bulk = BenchTarget(
    slot: 'bulk',
    label: String.fromEnvironment('BENCH_LABEL', defaultValue: 'fast (default)'),
    url: String.fromEnvironment('BENCH_URL', defaultValue: LlmClient.fastBaseUrl),
    model: String.fromEnvironment('BENCH_MODEL',
        defaultValue: LlmClient.defaultModel),
  );

  /// The prose slot: drafts and storyline names — the work that goes to the
  /// big server today, and the side of the A/B a candidate is compared against.
  static const BenchTarget prose = BenchTarget(
    slot: 'prose',
    label: String.fromEnvironment('PROSE_LABEL', defaultValue: '27B (default)'),
    url: String.fromEnvironment('PROSE_URL',
        defaultValue: LlmClient.defaultBaseUrl),
    model: String.fromEnvironment('PROSE_MODEL',
        defaultValue: LlmClient.defaultModel),
  );

  /// Where a run drops its JSON, or empty for none. Absolute: `flutter test`
  /// runs with `app/` as its working directory, so a relative path would
  /// scatter results wherever the runner happened to be invoked from.
  static const String outDir = String.fromEnvironment('BENCH_OUT');

  /// Discarded calls before the clock starts. llama.cpp measured 6.8 tok/s on
  /// its first call against 130 warm on this machine — a cold call in the
  /// sample does not slow the median down, it replaces it with a number about
  /// weight loading. See MODEL_FLAGS in the Makefile.
  static const int warmup = int.fromEnvironment('BENCH_WARMUP', defaultValue: 1);

  /// The escape hatch for candidates that always reason: R1-Distill has no
  /// `enable_thinking` toggle to honour, so the leak tripwire would fail every
  /// run against it for no defect. With this set the benches PRINT the leak
  /// count instead of asserting it is zero — the number still has to be read,
  /// it just stops being a gate.
  static const bool allowReasoning = bool.fromEnvironment('BENCH_THINK');

  LlmClient client({LlmCallObserver? onCall}) =>
      LlmClient(baseUrl: url, model: model, onCall: onCall);

  CallCollector collector() =>
      CallCollector(label: label, url: url, model: model);
}
