import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_target.dart';

/// The one piece of a bench target that can be typed wrong.
///
/// Everything else on [BenchTarget] is a string handed straight to an HTTP
/// client, which fails loudly and immediately when it is wrong. `BENCH_K` is
/// parsed, and a parse that was lenient about a stray comma would drop a round
/// from a drain race — leaving a table that looks complete, reads plausibly,
/// and is missing the concurrency the whole run was for. The live drain is the
/// only caller and it runs on a machine with a model server, so this is the
/// only place the failure can be caught before someone quotes the table.

void main() {
  group('BENCH_K', () {
    test('reads the rounds in the order they are written', () {
      // Order is preserved rather than sorted: the drain divides every later
      // round's speedup by the K=1 wall, and a run written `3,1` deliberately
      // races the warm machine first.
      expect(parseDrainK('1,3'), [1, 3]);
      expect(parseDrainK(' 1 , 3 , 6 '), [1, 3, 6]);
      expect(parseDrainK('4'), [4]);
    });

    test('defaults to the shipping pair', () {
      expect(parseDrainK(), [1, 3]);
    });

    test('refuses anything it would have to guess about', () {
      // Each of these has a plausible lenient reading, and every one of those
      // readings silently runs fewer rounds than were asked for.
      for (final garbage in ['1,3,', '1;3', '1,three', '0,3', '-1', '', '1,0']) {
        expect(() => parseDrainK(garbage), throwsArgumentError,
            reason: 'BENCH_K=$garbage');
      }
    });
  });
}
