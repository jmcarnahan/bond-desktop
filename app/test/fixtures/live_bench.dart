import 'bench_report.dart';
import 'bench_stats.dart';
import 'bench_target.dart';
import 'golden_json.dart';
import 'golden_run.dart';

/// The shape every live bench has around its model calls: check the defines,
/// read the JSON somebody pointed at, write the run and the result file, say
/// where they went.
///
/// **All five tests in `llm_golden_live_test.dart` are on it**, as of Round F
/// Phase 2. Round E Phase 1 factored it out for the two STAGES of the sweep
/// test, which share one body and one seeding and would otherwise carry two
/// copies of the same header and the same write; the other four kept their own
/// copies of the `BENCH_OUT` guard, the bench's name twice and the empty
/// accuracy list until [writeRun] gave them one call to make. That swap was
/// mechanical by construction, because nothing offline can execute any of
/// these tests: every `extra:` map is per-bench and stayed exactly where it
/// was, and the five load-bearing words in the test names — `triage`, `reply`,
/// `storyline`, `sweep`, `gates`, which the Makefile filters on — were not
/// touched.
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
  /// The rule itself is [decodeJsonOrFail], which the two golden loaders apply
  /// to their own `jsonDecode` so that a caller reaching them any other way
  /// still gets the path.
  Future<T> decodeOrFail<T>(String path, Future<T> Function() load) =>
      decodeJsonOrFail(path, load);

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

  /// The golden run file and the timing result file, written together.
  ///
  /// The four benches that are not the sweep each wrote these two by hand, and
  /// the repetition was the three-line `BENCH_OUT` guard, this bench's own
  /// name twice over and an accuracy list that has been empty in every live
  /// bench this repository has ever had: a Dart opinion about what "right"
  /// means is the one thing a bakeoff must not grow.
  ///
  /// [extra] is a FUNCTION of the run path rather than a map, because every
  /// one of those maps carries `run_file`: the result cannot be built until
  /// the run is on disk. A bench with nothing to time passes none and gets no
  /// result file — the gate replay is pure, and a timing row of zeros beside
  /// the real ones would be a row a reader compares.
  Future<({String? runPath, String? resultPath})> writeRun({
    required List<GoldenRunEntry> entries,
    required String label,
    required DateTime startedAt,
    Map<String, Object?> Function(String? runPath)? extra,
    List<CallCollector> collectors = const [],
  }) async {
    final runPath = BenchTarget.outDir.isEmpty
        ? null
        : await writeGoldenRun(
            entries,
            bench: bench,
            label: label,
            outDir: BenchTarget.outDir,
          );
    return (
      runPath: runPath,
      resultPath: extra == null
          ? null
          : await writeResult(
              startedAt: startedAt,
              extra: extra(runPath),
              collectors: collectors,
            ),
    );
  }

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
