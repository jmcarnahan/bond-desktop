import 'backend_types.dart';

/// The session the app signs in with, and asks about what it may do.
///
/// `getValidAccessToken` is deliberately absent: a Graph token is an
/// implementation detail of the SDK-mode backends, and a session that talks to
/// a server-side backend never holds one client-side at all.
abstract class AuthSession {
  Future<bool> get isSignedIn;

  /// True when a scope this build REQUIRES is absent from what was actually
  /// granted.
  Future<bool> get needsReconsent;

  /// Whether the stored GRANT carries [bareScope] — a bare lowercase name such
  /// as `chat.read` or `mail.send`, never the requested list: a degraded
  /// sign-in asked for more than it got, and the honest answer is what the
  /// server granted.
  Future<bool> hasScope(String bareScope);

  Future<AccountInfo?> get storedAccount;

  Future<AccountInfo> signIn();

  /// Ends the session. What else sign-out entails — wiping the local mail
  /// data — belongs to the caller's flow, not to this call.
  Future<void> signOut();
}
