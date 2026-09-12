import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';

/// A session that signs in without a browser.
///
/// Lifted out of `sign_in_connect_test.dart`'s private `_FakeSession` when the
/// setup wizard grew a sign-in step of its own — the two want the same fake,
/// and that test's copy stays where it is so its cases keep reading as one
/// file. Everything here is told rather than probed.
class FakeAuthSession implements AuthSession {
  FakeAuthSession({
    this.reconsent = false,
    this.signedIn = false,
    this.account = const AccountInfo(displayName: 'Jared'),
    this.throwOnProbe = false,
  });

  /// Whether a session is live. Public and mutable so a test can flip it
  /// between two probes, which is what a sign-in in another window looks like
  /// from here.
  bool signedIn;

  final bool reconsent;

  /// What [storedAccount] answers. Null is a platform that knows a session is
  /// live and nothing about whose it is.
  final AccountInfo? account;

  /// Makes [isSignedIn] throw — the unreadable-keychain case every gate has
  /// to survive.
  final bool throwOnProbe;

  int signIns = 0;
  int signInProbes = 0;
  int accountReads = 0;

  @override
  Future<bool> get isSignedIn async {
    signInProbes++;
    if (throwOnProbe) throw StateError('keychain unavailable');
    return signedIn;
  }

  @override
  Future<bool> get needsReconsent async => reconsent;

  @override
  Future<bool> hasScope(String bareScope) async => true;

  @override
  Future<AccountInfo?> get storedAccount async {
    accountReads++;
    return signedIn ? account : null;
  }

  @override
  Future<AccountInfo> signIn() async {
    signIns++;
    signedIn = true;
    return account ?? const AccountInfo(displayName: '');
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
  }
}
