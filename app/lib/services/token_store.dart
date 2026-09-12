import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The three-method slice of key/value storage the sign-in sessions need.
///
/// It exists so the auth logic can be tested without a platform channel —
/// `flutter_secure_storage` is a plugin, and its calls throw
/// MissingPluginException under `flutter test`.
abstract class TokenStore {
  Future<String?> read(String key);

  /// A null [value] deletes the key.
  Future<void> write(String key, String? value);

  /// Empties the store. Nothing in the app calls this, and ending a session
  /// must not: one keychain now holds the direct-Graph session AND one slot
  /// per MCP server, so a session that wiped the store would sign the user
  /// out of every backend they have. Each clears its own keys by name.
  Future<void> deleteAll();
}

/// Production store: the OS keychain via `flutter_secure_storage`.
///
/// Two accommodations, both learned the hard way:
///
/// - `usesDataProtectionKeychain: false`, and it stays false now that the app
///   is unsandboxed and Developer ID signed. The default (data-protection,
///   the iOS-style keychain) requires the `keychain-access-groups`
///   entitlement, which an ad-hoc-signed build cannot be granted at all —
///   every write dies with errSecMissingEntitlement (-34018) — and which a
///   distributed build would only carry to gain an isolation the file-based
///   login keychain already provides for a single unsandboxed app. So the
///   file-based keychain is the deliberate choice, not a workaround left
///   over from ad-hoc days.
///
///   One consequence for anyone upgrading from a pre-Bond-Desktop build:
///   keychain items do NOT migrate. The old build's items were written by a
///   sandboxed app under a different code identity, and the OS treats a
///   different identity as a different owner. The database and attachments
///   are copied forward on first launch; the sign-in is not, so the user
///   signs in again once.
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
