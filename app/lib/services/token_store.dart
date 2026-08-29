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
/// Reads return null rather than throwing when nothing is stored, which the
/// callers already treat as "signed out". Note that macOS keychain
/// persistence is unverified under this project's ad-hoc signing (see the
/// comment in macos/Runner/DebugProfile.entitlements) — a null read after a
/// relaunch means re-authenticating, not a crash.
class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _storage;

  const SecureTokenStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}
