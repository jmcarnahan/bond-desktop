import 'dart:typed_data';

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

/// One person on a sent message's To or Cc line, as the server reported them
/// back.
///
/// [name] is absent far more often than it looks — it is filled in from the
/// address book and left null for anyone not in one — so nothing may key on
/// it. [address] is the identity, and the only field a stored row keeps.
@immutable
class Recipient {
  final String? name;
  final String address;

  const Recipient({this.name, required this.address});
}

/// What a send actually put in front of somebody.
///
/// A draft dies the moment it is sent: its id names a message that has left
/// Drafts and is not yet the copy in Sent Items. So the only way to show a
/// reply before the next sync catches up is to learn these fields while the
/// draft still exists and write a local row from them — which is what
/// `mail_echo.dart` does.
///
/// [internetMessageId] is the field that makes the row RECONCILABLE. The Sent
/// Items copy carries the same one and a different [draftId], so the sync can
/// replace the local echo rather than duplicate it. Without it there would be
/// two rows for one message and nothing able to tell.
///
/// [sentAt] is ISO-8601 UTC at SECONDS precision with a `Z` suffix — the shape
/// Graph prints `receivedDateTime` in, e.g. `2026-09-06T20:37:16Z`. It goes
/// verbatim into a column the fold compares as a string, so a stamp printed at
/// any other precision would sort against its own thread wrongly.
@immutable
class SentDraft {
  /// The id that was sent. Dies with the draft; kept because the local echo is
  /// keyed on it and nothing else about the message is unique yet.
  final String draftId;

  final String? conversationId;

  /// The RFC 5322 Message-ID, and the only identifier the Sent Items copy
  /// shares with the draft that became it.
  final String? internetMessageId;

  final String? subject;
  final List<Recipient> to;
  final List<Recipient> cc;

  /// The server's clock, not this machine's — see the class doc for the
  /// precision this must be printed at.
  final String? sentAt;

  const SentDraft({
    required this.draftId,
    this.conversationId,
    this.internetMessageId,
    this.subject,
    this.to = const [],
    this.cc = const [],
    this.sentAt,
  });
}

/// The directory could not be searched. Held apart from every other failure
/// because the recipients field degrades rather than errors: with no directory
/// it still offers recents and typed addresses, so what it needs to know is
/// only whether the affordance is worth showing again.
///
/// [scopeMissing] is what separates the two answers. True means the tenant has
/// not granted `User.ReadBasic.All` and no retry can change that until somebody
/// consents and the app reconnects — the field stops asking for the rest of the
/// session. False means a throttle, a network, a server: the next keystroke is
/// worth trying.
class DirectoryUnavailable implements Exception {
  final bool scopeMissing;
  final String message;

  const DirectoryUnavailable({
    required this.scopeMissing,
    required this.message,
  });

  @override
  String toString() => message;
}

/// One profile photo as the directory served it: the bytes and the MIME type
/// the server put on them, and nothing decoded.
///
/// Deliberately not an `ImageProvider`. A backend lives below `widgets/` and
/// must not depend on a rendering library to answer a question about a person;
/// turning bytes into something paintable is the one job the widget layer keeps
/// for itself. [contentType] rides along because Graph serves whatever the
/// person uploaded — jpeg for most, png for some — and a caller writing the
/// bytes to disk or into an `<img>` needs to be told which.
@immutable
class ProfilePhoto {
  final Uint8List bytes;
  final String contentType;

  const ProfilePhoto({required this.bytes, required this.contentType});
}

/// A Teams chat that is now known to exist and can be posted to.
///
/// [isGroup] is carried because the two are not the same promise: a 1:1 chat
/// is idempotent — asking for it twice returns the same chat — while every
/// group request CREATES another chat. A caller retrying a failed send has to
/// reuse this id rather than ask again, and this flag is how it knows it must.
@immutable
class EnsuredChat {
  final String chatId;
  final bool isGroup;

  const EnsuredChat({required this.chatId, required this.isGroup});
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
///
/// [hasMore] is the Bond MCP server's explicit paging verdict, null for a
/// backend that does not report one (the direct-Graph SDK path). It tracks the
/// nextLink in the current server, and the drain treats it as the primary
/// keep-paging signal with the nextLink presence as the fallback.
class DeltaPage {
  final List<Map<String, dynamic>> messages;
  final String? nextLink;
  final String? deltaLink;
  final bool? hasMore;

  const DeltaPage({
    this.messages = const [],
    this.nextLink,
    this.deltaLink,
    this.hasMore,
  });
}
