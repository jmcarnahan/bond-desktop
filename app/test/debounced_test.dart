import 'package:bond_inbox/utils/debounced.dart';
import 'package:flutter_test/flutter_test.dart';

/// The typeahead's only rate limiter.
///
/// Real timers rather than a fake clock: `fake_async` is not a declared dev
/// dependency and importing a transitive one trips
/// `depend_on_referenced_packages`. A 20 ms delay keeps the whole file under a
/// tenth of a second.
void main() {
  group('Debounced', () {
    test('a lone call survives, and not before the delay', () async {
      final debounced = Debounced(delay: const Duration(milliseconds: 20));
      var settled = false;
      final call = debounced.settle().then((survived) {
        settled = true;
        return survived;
      });

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(settled, isFalse, reason: 'the delay had not elapsed yet');

      expect(await call, isTrue);
    });

    test('a burst leaves exactly one survivor', () async {
      final debounced = Debounced(delay: const Duration(milliseconds: 20));

      final first = debounced.settle();
      final second = debounced.settle();
      final third = debounced.settle();

      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(await third, isTrue);
    });

    test('a superseded call resolves without waiting for the delay', () async {
      final debounced = Debounced(delay: const Duration(seconds: 30));

      final first = debounced.settle();
      debounced.settle();

      // Would time out on a delay-long wait if the loser were held back.
      expect(await first, isFalse);
      debounced.cancel();
    });

    test('cancel resolves the pending call and disarms the timer', () async {
      final debounced = Debounced(delay: const Duration(milliseconds: 20));
      final call = debounced.settle();

      debounced.cancel();
      expect(await call, isFalse);

      // Nothing fires afterwards — a second cancel over a spent timer is a
      // no-op rather than a double-complete.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      debounced.cancel();
    });

    test('it is reusable after a completed call', () async {
      final debounced = Debounced(delay: const Duration(milliseconds: 20));

      expect(await debounced.settle(), isTrue);
      expect(await debounced.settle(), isTrue);

      final loser = debounced.settle();
      final winner = debounced.settle();
      expect(await loser, isFalse);
      expect(await winner, isTrue);
    });

    test('the default delay is a quarter second', () {
      expect(Debounced().delay, const Duration(milliseconds: 250));
    });
  });
}
