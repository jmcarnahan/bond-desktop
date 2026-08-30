import 'package:flutter/foundation.dart' show immutable;

/// The types every Microsoft backend implementation speaks, held apart from
/// any one of them so a second implementation can be plugged in without the
/// callers learning which one they got.
///
/// The exception taxonomy here is the contract callers route on: [NotSignedIn]
/// and [ReconsentRequired] mean the session is over and the UI must go to
/// sign-in, while a plain [AuthException] is transient and worth retrying.
/// Collapsing them into one type would erase the only distinction the routing
/// has to make.

/// Anything the caller can show the user verbatim. [message] is written for a
/// person, not a log line.
class AuthException implements Exception {
  final String message;

  const AuthException(this.message);

  @override
  String toString() => message;
}

/// There is no usable refresh token — the user must sign in interactively.
class NotSignedIn extends AuthException {
  const NotSignedIn([super.message = 'You are not signed in.']);
}

/// The stored grant is missing a scope this build now asks for. Refreshing
/// cannot fix it; only an interactive sign-in with the new consent can.
class ReconsentRequired extends AuthException {
  const ReconsentRequired([
    super.message =
        'This version needs additional Microsoft permissions. Sign in again '
            'to grant them.',
  ]);
}

/// The browser came back carrying an OAuth `error` instead of a code.
///
/// Held apart from a plain [AuthException] because the sign-in has to read the
/// raw parameters to tell two very different things apart: a user who clicked
/// Cancel, and a tenant that refuses one of the scopes this build asks for.
/// Only the second is worth retrying with less.
class AuthorizeDenied extends AuthException {
  /// Entra's `error` parameter, e.g. `access_denied`, `consent_required`.
  final String error;

  /// Entra's `error_description`, which is where the AADSTS code lives.
  final String errorDescription;

  const AuthorizeDenied(this.error, this.errorDescription, String message)
      : super(message);

  /// True when this reads as "the tenant will not grant that consent" rather
  /// than "the person said no".
  ///
  /// AADSTS90094 is admin consent required; AADSTS65001 is consent not
  /// granted. Both arrive as `access_denied` in the `error` parameter, which is
  /// the same code a Cancel click produces — the description is the only thing
  /// that separates them.
  bool get isConsentProblem =>
      error == 'consent_required' ||
      errorDescription.contains('AADSTS90094') ||
      errorDescription.contains('AADSTS65001');
}

/// The signed-in user, as Graph's `/me` describes them. Only [displayName] is
/// guaranteed — a mailbox-less account has no `mail`, and both fields are
/// tolerated as absent so a thin `/me` payload cannot break the header.
@immutable
class AccountInfo {
  final String displayName;
  final String? mail;
  final String? userPrincipalName;

  const AccountInfo({
    required this.displayName,
    this.mail,
    this.userPrincipalName,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    return AccountInfo(
      displayName: json['displayName'] as String? ?? '',
      mail: json['mail'] as String?,
      userPrincipalName: json['userPrincipalName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        'mail': mail,
        'userPrincipalName': userPrincipalName,
      };
}

/// Graph refused the delta cursor (HTTP 410): the token is older than the
/// server's change history and only a fresh drain can recover.
class DeltaResyncRequired implements Exception {
  const DeltaResyncRequired();

  @override
  String toString() => 'The mail sync cursor expired and must be rebuilt.';
}

/// One page of a delta drain. Exactly one of [nextLink] / [deltaLink] is set
/// in practice: more pages to walk, or the cursor to store for next time.
class DeltaPage {
  final List<Map<String, dynamic>> messages;
  final String? nextLink;
  final String? deltaLink;

  const DeltaPage({
    this.messages = const [],
    this.nextLink,
    this.deltaLink,
  });
}
