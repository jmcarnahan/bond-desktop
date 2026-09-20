import 'package:bond_inbox/services/token_store.dart';

/// The keychain, in a map.
///
/// `flutter_secure_storage` is a plugin and throws `MissingPluginException`
/// under `flutter test`, which [SecureTokenStore] deliberately does not catch
/// — so anything that reads or writes a token takes one of these instead. A
/// SHARED fixture rather than a fourth private copy, because this one is
/// handed to `AppPrefsNotifier` by more than one test file and the assertions
/// they make are about [values].
class MemoryTokenStore implements TokenStore {
  /// What is stored, by key. Public so a test can assert on it directly,
  /// which is the whole point of the fake.
  final Map<String, String?> values = {};

  /// Every key that has been read, in order — how a test tells a prefetch
  /// from a per-request keychain call.
  final List<String> reads = [];

  MemoryTokenStore([Map<String, String>? initial]) {
    if (initial != null) values.addAll(initial);
  }

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

/// A store whose every call throws, the way a keychain that refuses does.
/// What proves a refusal costs the header and never the launch or the write.
class RefusingTokenStore implements TokenStore {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String? value) async =>
      throw StateError('no keychain');

  @override
  Future<void> deleteAll() async => throw StateError('no keychain');
}
