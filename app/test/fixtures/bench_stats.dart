/// The latency arithmetic both live benchmarks print.
///
/// Extracted rather than duplicated: `llm_bench_live_test.dart` and
/// `llm_ab_live_test.dart` are read side by side — the bench says how fast the
/// app's path is, the A/B says what that path cost in agreement — and two
/// copies of a percentile that drifted apart would make those two tables
/// quietly incomparable.
library;

/// p-th percentile, nearest rank. Small n, so nothing fancier would mean more.
int percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// One markdown row: `| task | n | p50 | p95 | mean | total s |`.
String row(String task, List<int> samples) {
  final sorted = [...samples]..sort();
  final total = samples.fold(0, (sum, ms) => sum + ms);
  final mean = samples.isEmpty ? 0 : total ~/ samples.length;
  return '| $task | ${samples.length} | ${percentile(sorted, 0.5)} '
      '| ${percentile(sorted, 0.95)} | $mean '
      '| ${(total / 1000).toStringAsFixed(1)} |';
}
