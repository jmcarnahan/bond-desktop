import 'package:bond_inbox/services/pkce.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pkceChallengeFor', () {
    test('matches the RFC 7636 appendix B vector', () {
      expect(
        pkceChallengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('never emits base64 padding', () {
      // sha256 is 32 bytes, which base64-encodes to 44 chars with one '='.
      for (var i = 0; i < 20; i++) {
        expect(pkceChallengeFor(randomUrlSafe(64)), isNot(contains('=')));
      }
    });
  });

  group('randomUrlSafe', () {
    test('produces a verifier inside the RFC 7636 length bounds', () {
      final verifier = randomUrlSafe(64);
      expect(verifier.length, greaterThanOrEqualTo(43));
      expect(verifier.length, lessThanOrEqualTo(128));
    });

    test('uses only unreserved characters and no padding', () {
      final unreserved = RegExp(r'^[A-Za-z0-9\-._~]+$');
      for (var i = 0; i < 50; i++) {
        final value = randomUrlSafe(64);
        expect(value, matches(unreserved), reason: value);
        expect(value, isNot(contains('=')));
      }
    });

    test('does not repeat', () {
      final values = {for (var i = 0; i < 100; i++) randomUrlSafe(32)};
      expect(values, hasLength(100));
    });
  });
}
