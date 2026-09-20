import 'bench_report.dart';
import 'bench_stats.dart';

/// The shape every live bench has around its model calls: check the defines,
/// read the JSON somebody pointed at, write the result file, say where it
/// went.
///
/// **Started, not finished.** Round E Phase 1 factors this out for the two
/// STAGES of the sweep test, which share one body and one seeding and would
/// otherwise carry two copies of the same header and the same write. The other
/// four live tests in `llm_golden_live_test.dart` still have their own copies
/// and are deliberately left alone: migrating them is a diff across five
/// ninety-minute benches with nothing to run them against offline, and the
/// roadmap's simplification item stays open until a round touches them for
/// another reason.
///
/// Nothing here prints anything but paths and counts. The benches it serves
/// replay real correspondence in a public repository.
class LiveBench {
  /// The bench's own name, which is the `bench` field of every result file it
  /// writes and half of that file's name.
  final String bench;

  const LiveBench(this.bench);

  /// [load], with a malformed file named rather than thrown at.
  ///
  /// A `FormatException` out of `jsonDecode` says where in the bytes it gave
  /// up and nothing about which file it was reading, and a bench reads four.
  Future<T> decodeOrFail<T>(String path, Future<T> Function() load) async {
    try {
      return await load();
    } on FormatException catch (e) {
      throw StateError('could not read $path as JSON: ${e.message}');
    }
  }

  /// The result JSON, or null when `BENCH_OUT` was not defined.
  ///
  /// [label] names the run in the filename and in `extra`. The result schema
  /// names its targets by their collectors, and a stage that dials no model
  /// has none to name, so without it two rows of one bench a second apart
  /// would be told apart by nothing but a timestamp. A stage that HAS
  /// collectors passes none: the filename already carries the target's label,
  /// and adding a second name would move a field in every result file the
  /// comparison tool reads.
  Future<String?> writeResult({
    String? label,
    required DateTime startedAt,
    Map<String, Object?> extra = const {},
    List<CallCollector> collectors = const [],
  }) =>
      writeBenchResult(
        bench: bench,
        collectors: collectors,
        accuracy: const [],
        startedAt: startedAt,
        label: label,
        extra: extra,
      );

  /// Where the run went, and what to run next. The one place a bench prints a
  /// path, which is the only string it prints that is not a count.
  void printPaths({String? runPath, String? resultPath}) {
    final lines = [
      // A stage that writes no RUN file by design (the vector stage has
      // nothing to score) still wrote its result; the warning is for the case
      // where nothing at all landed.
      if (runPath == null && resultPath == null)
        'BENCH_OUT not set — no run file written'
      else if (runPath != null)
        'wrote $runPath',
      if (resultPath != null) 'wrote $resultPath',
      if (runPath != null) 'next: make golden-score R=$runPath',
    ];
    // ignore: avoid_print
    print(lines.join('\n'));
  }
}
