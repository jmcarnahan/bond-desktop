/// The arithmetic every live benchmark prints, and the accumulator it prints
/// from.
///
/// Extracted rather than duplicated: `llm_bench_live_test.dart`,
/// `llm_ab_live_test.dart` and `llm_membership_live_test.dart` are read side by
/// side — the bench says how fast the app's path is, the A/B says what that
/// path cost in agreement — and two copies of a percentile that drifted apart
/// would make those tables quietly incomparable.
///
/// What lives here now is more than percentiles because the question the bench
/// answers has grown. Latency alone cannot compare two runtimes: a server that
/// answers in four seconds is fast or slow depending entirely on how many
/// tokens it wrote in them, so the tables carry tokens per second, and — where
/// the runtime reports its own timings — the same rate measured by the server
/// rather than by the wall. [Scorecard] is the other half: a bakeoff that only
/// measured speed would recommend the runtime that is quickest at being wrong.
library;

import 'package:bond_inbox/services/llm/llm_client.dart';

/// p-th percentile, nearest rank. Small n, so nothing fancier would mean more.
int percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// One task's calls, as the observer saw them.
///
/// Built from [LlmCallRecord] rather than from stopwatches around the call
/// sites because the record is the only place latency and tokens are known to
/// belong to the same round trip. A stopwatch in the test can time a call it
/// cannot count the tokens of, and under any concurrency it times the wrong
/// thing entirely.
class TaskMetrics {
  final String task;

  /// Split at the door, because almost every number below is a lie if the two
  /// are mixed: a 3ms HTTP 400 is not a fast answer, it is no answer, and one
  /// of them in the sample drags the median toward a latency nothing achieved.
  final List<LlmCallRecord> ok = [];
  final List<LlmCallRecord> failed = [];

  TaskMetrics(this.task);

  void add(LlmCallRecord r) => (r.outcome == 'ok' ? ok : failed).add(r);

  int get n => ok.length;
  int get failures => failed.length;

  List<int> get _sortedMs => [...ok.map((r) => r.durationMs)]..sort();

  int get p50Ms => percentile(_sortedMs, 0.5);
  int get p95Ms => percentile(_sortedMs, 0.95);

  int get totalMs => ok.fold(0, (sum, r) => sum + r.durationMs);
  int get meanMs => ok.isEmpty ? 0 : totalMs ~/ ok.length;

  /// Null tokens contribute nothing rather than blocking the sum: a runtime
  /// that reports usage on some calls and not others should still show the
  /// total it did report.
  int get promptTokens => ok.fold(0, (sum, r) => sum + (r.promptTokens ?? 0));
  int get completionTokens =>
      ok.fold(0, (sum, r) => sum + (r.completionTokens ?? 0));

  /// Generation speed across the whole task, weighted by time rather than
  /// averaged per call: both sides are summed and divided ONCE, never a mean
  /// of per-call rates. A hundred one-token retries and one long answer are
  /// not a hundred and one data points of equal worth, and a per-call mean
  /// would let the retries outvote the only answer anyone waited for. This is
  /// the same invariant `ActivityLogPanel` holds
  /// (app/lib/widgets/activity_log_panel.dart:364-377), deliberately: the
  /// bench and the app's own speed tile must be quotable against each other.
  ///
  /// Only calls that reported tokens are in either sum — a call whose duration
  /// counted toward the denominator while its unreported tokens missed the
  /// numerator would report a rate lower than anything that happened.
  double? get genTps => _tps((r) => r.completionTokens);

  /// Prompt tokens over the WHOLE round trip, not over prefill time — the
  /// denominator includes generation and HTTP, so this reads far lower than a
  /// server's own prefill rate (the README's 90–126 t/s came from
  /// `prompt_ms`). It stays on the wall clock anyway because it is the only
  /// clock every runtime has: a column that switched denominators per server
  /// would compare nothing.
  double? get promptTps => _tps((r) => r.promptTokens);

  double? _tps(int? Function(LlmCallRecord) tokensOf) {
    var tokens = 0;
    var ms = 0;
    for (final r in ok) {
      final t = tokensOf(r);
      if (t == null) continue;
      tokens += t;
      ms += r.durationMs;
    }
    if (ms <= 0) return null;
    return tokens * 1000 / ms;
  }

  /// The same rate on the server's own clock — generation tokens over the
  /// milliseconds llama-server says it spent predicting them.
  ///
  /// Read next to [genTps], never instead of it: the gap between the two is
  /// the HTTP and queue-wait overhead the caller actually paid, and a runtime
  /// can hold this number flat while the wall-clock one collapses under
  /// concurrency.
  double? get serverGenTps {
    var tokens = 0;
    var ms = 0;
    for (final r in ok) {
      final predicted = r.serverPredictedMs;
      if (predicted == null) continue;
      tokens += r.completionTokens ?? 0;
      ms += predicted;
    }
    if (ms <= 0) return null;
    return tokens * 1000 / ms;
  }

  /// `server` only when EVERY ok call carried server timings, `wall` when any
  /// did not, `none` when nothing succeeded.
  ///
  /// All-or-nothing on purpose: a run where half the calls reported timings
  /// has a [serverGenTps] computed over half the work, and a column labelled
  /// as the server's when it is really a subset's is worse than no column.
  String get timingSource {
    if (ok.isEmpty) return 'none';
    return ok.every((r) => r.serverPredictedMs != null) ? 'server' : 'wall';
  }
}

/// Every call one client made, bucketed by task in the order the tasks first
/// ran.
///
/// One collector per CLIENT, never one per run: two servers sharing a bucket
/// would average two machines together and report a speed neither of them
/// reaches. That is the whole point of the A/B, so the type makes the mistake
/// hard — the label and url it prints name which machine the numbers are from.
class CallCollector {
  final String label;
  final String url;
  final String model;

  /// Counted rather than asserted mid-run: the tripwire's meaning is that
  /// every latency in the table below measures the leak instead of the model,
  /// which is a fact about the whole table.
  int reasoningLeaks = 0;

  /// Insertion-ordered, so the table rows come out in the order the bench ran
  /// the tasks rather than alphabetically — the reading order matches the run.
  final Map<String, TaskMetrics> _byTask = {};

  /// The most recent call per task, success or failure, for the per-message
  /// lines a bench prints as it goes.
  final Map<String, LlmCallRecord> _last = {};

  CallCollector({required this.label, required this.url, required this.model});

  void record(LlmCallRecord r) {
    _byTask.putIfAbsent(r.label, () => TaskMetrics(r.label)).add(r);
    _last[r.label] = r;
  }

  void noteLeak() => reasoningLeaks++;

  LlmCallRecord? lastFor(String task) => _last[task];

  TaskMetrics metricsFor(String task) =>
      _byTask.putIfAbsent(task, () => TaskMetrics(task));

  List<TaskMetrics> get tasks => _byTask.values.toList();

  String get banner => '=== target: $label — $url (model $model) ===';

  String table() {
    final rows = tasks.map((m) => '| ${m.task} | ${m.n} | ${m.failures} '
        '| ${m.p50Ms} | ${m.p95Ms} | ${m.meanMs} '
        '| ${(m.totalMs / 1000).toStringAsFixed(1)} '
        '| ${m.promptTokens} | ${m.completionTokens} '
        '| ${_rate(m.genTps)} | ${_rate(m.serverGenTps)} '
        '| ${_rate(m.promptTps)} |');
    return '| task | n | fail | p50 ms | p95 ms | mean ms | total s '
        '| prompt tok | gen tok | gen t/s | gen t/s (srv) | prompt t/s |\n'
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
        '${rows.join('\n')}';
  }

  /// An em dash rather than 0.0 for a rate nobody measured: a runtime that
  /// reports no timings must not read as one that generates nothing.
  static String _rate(double? tps) =>
      tps == null ? '—' : tps.toStringAsFixed(1);
}

/// One dimension of the corpus's opinion, scored against the model's.
///
/// Entries whose expectation is null are simply not judged — [judged] only
/// counts what was asked. A corpus that declines to guess a category is not a
/// miss, and counting it as one would make every rate a function of how much
/// of the corpus had been annotated rather than of how right the model was.
/// Callers skip [judge] entirely for a null expectation.
class Scorecard {
  final String dimension;

  int hits = 0;
  int judged = 0;

  /// Kept as text, printed under the table: a rate says how often the model
  /// disagreed, and only the list says whether the disagreements were the
  /// awkward third of the mailbox or the easy two thirds.
  final List<String> misses = [];

  Scorecard(this.dimension);

  void judge(String id, {required bool matched, String? detail}) {
    judged++;
    if (matched) {
      hits++;
      return;
    }
    misses.add(detail == null ? id : '$id: $detail');
  }
}

/// `76% (13/17)`, or an em dash when nothing was judged.
String pct(int matches, int total) => total == 0
    ? '—'
    : '${(100 * matches / total).toStringAsFixed(0)}% ($matches/$total)';

/// The scorecards as one markdown block, with every disagreement listed under
/// it — the rates say how much, the list says what.
String scorecardBlock(List<Scorecard> cards) {
  final rows = cards.map((c) => '| ${c.dimension} | ${c.hits}/${c.judged} '
      '| ${pct(c.hits, c.judged)} |');
  final misses = cards.expand((c) => c.misses).toList();
  return '| dimension | hits/judged | rate |\n'
      '| --- | --- | --- |\n'
      '${rows.join('\n')}\n'
      '\n'
      '${misses.isEmpty ? 'no disagreements with the corpus' : misses.join('\n')}';
}
