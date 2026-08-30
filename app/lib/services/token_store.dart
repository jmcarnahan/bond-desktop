import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The three-method slice of key/value storage [GraphAuth] needs.
///
/// It exists so the auth logic can be tested without a platform channel —
/// `flutter_secure_storage` is a plugin, and its calls throw
/// MissingPluginException under `flutter test`.
abstract class TokenStore {
  Future<String?> read(String key);

  /// A null [value] deletes the key.
  Future<void> write(String key, String? value);

  Future<void> deleteAll();
}

/// Production store: the OS keychain via `flutter_secure_storage`.
///
/// Two accommodations for this project's ad-hoc signing, both learned the
/// hard way:
///
/// - `usesDataProtectionKeychain: false`. The default (data-protection, the
///   iOS-style keychain) requires the `keychain-access-groups` entitlement,
///   which Xcode refuses to grant an ad-hoc-signed build — every write dies
///   with errSecMissingEntitlement (-34018). The legacy file-based keychain
///   needs no entitlement and persists fine.
/// - every call swallows [PlatformException]. A keychain refusal must cost
///   persistence (a re-auth at next launch), never crash a sign-in that
///   already holds a working token.
class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _storage;

  const SecureTokenStore([
    this._storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  ]);

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      debugPrint('keychain read failed for "$key": ${e.message} — '
          'treating as not stored');
      return null;
    }
  }

  @override
  Future<void> write(String key, String? value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      debugPrint('keychain write failed for "$key": ${e.message} — '
          'this session works, but sign-in will not survive a relaunch');
    }
  }

  @override
  Future<void> deleteAll() async {
    try {
      await _storage.deleteAll();
    } on PlatformException catch (e) {
      debugPrint('keychain clear failed: ${e.message}');
    }
  }
}
