import 'package:bond_inbox/services/owner_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('memoizedOwner', () {
    test('asks once, however many times it is read', () async {
      // The answer is a keychain read that only changes on sign-out, and
      // sign-out disposes the provider that built the caller. One read per
      // closure is a read per session.
      var lookups = 0;
      final owner = memoizedOwner(() async {
        lookups++;
        return (name: 'Alex Rivera', address: 'alex@example.com');
      });

      final first = await owner();
      final second = await owner();

      expect(lookups, 1);
      expect(first?.name, 'Alex Rivera');
      expect(second?.address, 'alex@example.com');
    });

    test('a lookup that threw reads as null and is asked again', () async {
      // Caching a failed future would leave every later caller inheriting one
      // keychain hiccup until the app restarts. The caller reads null in the
      // meantime, which every caller of this lookup already allows for.
      var lookups = 0;
      final owner = memoizedOwner(() async {
        lookups++;
        if (lookups == 1) throw StateError('keychain unavailable');
        return (name: 'Alex Rivera', address: null);
      });

      expect(await owner(), isNull);
      expect(lookups, 1);
      expect((await owner())?.name, 'Alex Rivera');
      expect(lookups, 2);
      expect((await owner())?.name, 'Alex Rivera');
      expect(lookups, 2);
    });

    test('a lookup that answers null is still memoized', () async {
      // Null is an answer: nobody is signed in. Asking the keychain again on
      // every item would be a read per item for the same nothing.
      var lookups = 0;
      final owner = memoizedOwner(() async {
        lookups++;
        return null;
      });

      expect(await owner(), isNull);
      expect(await owner(), isNull);
      expect(lookups, 1);
    });
  });
}
