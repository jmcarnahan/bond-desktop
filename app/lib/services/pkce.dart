import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE (RFC 7636) primitives, kept free of plugin imports so they are
/// directly testable against the spec's own vectors.

/// base64url without the '=' padding — RFC 7636 §4.1 forbids it, and Entra
/// rejects a padded verifier or challenge outright.
String _unpadded(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// [bytes] bytes of CSPRNG output as an unpadded base64url string. Used for
/// both the code verifier and the `state` nonce; [Random.secure] is the only
/// acceptable source for either.
String randomUrlSafe(int bytes) {
  final rng = Random.secure();
  return _unpadded(List<int>.generate(bytes, (_) => rng.nextInt(256)));
}

/// The S256 challenge for [verifier]: base64url(sha256(ASCII(verifier))).
///
/// ASCII, not UTF-8 — the spec fixes the encoding, and a verifier built by
/// [randomUrlSafe] is ASCII by construction.
String pkceChallengeFor(String verifier) =>
    _unpadded(sha256.convert(ascii.encode(verifier)).bytes);
