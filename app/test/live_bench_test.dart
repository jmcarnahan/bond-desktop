import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_json.dart';
import 'fixtures/golden_registry.dart';
import 'fixtures/golden_set.dart';
import 'fixtures/live_bench.dart';

/// The tail every live bench shares, pinned where it CAN be pinned.
///
/// The benches themselves dial a server and cannot run here at all, and with
/// `BENCH_OUT` undefined — which is what a bare `flutter test` is — nothing is
/// written to disk. So what is provable offline is the contract around the
/// write: that a bench with nowhere to write says so in both halves rather
/// than throwing, that the result map is built from the run path the run
/// actually got, and that a malformed golden file is named in the failure
/// instead of being reported as a byte offset in nothing in particular.
void main() {
  group('writeRun with BENCH_OUT unset', () {
    const bench = LiveBench('golden-test');

    test('writes neither half and says so by returning two nulls', () async {
      final paths = await bench.writeRun(
        entries: const [],
        label: 'a label',
        startedAt: DateTime.now(),
        extra: (runPath) => const {},
      );

      expect(paths.runPath, isNull);
      expect(paths.resultPath, isNull);
    });

    test('hands the extra builder the run path the run got', () async {
      // Null here, because nothing was written. The point of the builder is
      // that the map carries `run_file`, so it cannot be built before the run
      // is on disk — and a run that never landed must say null rather than a
      // path to a file nobody wrote.
      Object? seen = 'not called';
      await bench.writeRun(
        entries: const [],
        label: 'a label',
        startedAt: DateTime.now(),
        extra: (runPath) {
          seen = runPath;
          return const {};
        },
      );

      expect(seen, isNull);
    });

    test('a bench with nothing to time asks for no result at all', () async {
      // The gate replay's shape: no `extra`, so no result file is attempted
      // even where one could be written. A timing row of zeros beside the
      // real ones would be a row a reader compares.
      final paths = await bench.writeRun(
        entries: const [],
        label: 'app-gates',
        startedAt: DateTime.now(),
      );

      expect(paths.resultPath, isNull);
    });
  });

  group('a malformed file names itself', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('live-bench-test');
    });

    tearDown(() async => dir.delete(recursive: true));

    Future<File> write(String name, String body) async {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(body);
      return file;
    }

    test('decodeJsonOrFail turns a byte offset into a path', () async {
      Future<int> broken() async => throw const FormatException(
            'Unexpected character',
            'xx',
            41231,
          );

      await expectLater(
        decodeJsonOrFail('/some/where/golden-set.json', broken),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/some/where/golden-set.json'),
              contains('Unexpected character'),
            ),
          ),
        ),
      );
    });

    test('and lets everything else past untouched', () async {
      await expectLater(
        decodeJsonOrFail('/some/where.json', () async => 7),
        completion(7),
      );
      await expectLater(
        decodeJsonOrFail<int>(
          '/some/where.json',
          () async => throw StateError('the loader said no'),
        ),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'the loader said no')),
      );
    });

    test('the golden set loader names the file it choked on', () async {
      final file = await write('golden-set.json', '{"items": [,,]}');

      await expectLater(
        loadGoldenSet(file.path),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains(file.path))),
      );
    });

    test('and so does the registry loader', () async {
      final file = await write('storylines.json', 'not json at all');

      await expectLater(
        loadGoldenRegistry(file.path),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains(file.path))),
      );
    });

    test('a well-formed file that is the wrong shape still names itself',
        () async {
      // The guard that was already there, kept honest beside the new one: the
      // two failures read the same way, so a reader does not have to work out
      // which of them fired.
      final file = await write('empty.json', '{"generated": "2026-01-01"}');

      await expectLater(
        loadGoldenSet(file.path),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains(file.path), contains('items')),
        )),
      );
    });
  });
}
