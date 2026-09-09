import '../../models/person.dart';
import 'backend_types.dart';

/// The organization's directory, as the recipients field asks about it.
///
/// One method, and it is a search rather than a listing on purpose: a tenant's
/// directory is thousands of people, none of which this app has any business
/// holding. Nothing here touches sqlite — recents come from [MessageStore],
/// and merging the two is `RecipientSearch`'s job, not a backend's.
///
/// Auth failures pass through UNWRAPPED, exactly as they do from the mail and
/// Teams backends: [NotSignedIn] and [ReconsentRequired] mean the session is
/// over and the UI must route to sign-in.
abstract class PeopleBackend {
  /// People in the organization matching [query], at most [top] of them.
  ///
  /// A blank query answers with an empty list and makes NO network call — the
  /// field asks on every keystroke, including the one that empties it.
  ///
  /// Throws [DirectoryUnavailable], whose `scopeMissing` says whether asking
  /// again could ever work. Callers show recents either way; nothing here is
  /// worth an error banner.
  Future<List<Person>> searchPeople(String query, {int top = 10});

  /// The signed-in user, as [profilePhoto] names them. Empty rather than a
  /// sentinel string because that is what both wires already mean by it: the
  /// MCP tool omits the argument, and Graph swaps `/users/{id}` for `/me`.
  static const String self = '';

  /// [user]'s profile photo — a Graph user id or a UPN, or [self] — at one of
  /// Graph's fixed sizes, or null when they have none.
  ///
  /// Null is the EVERYDAY answer, not a failure: every sender outside the
  /// tenant, everyone who never uploaded a picture, and every address this app
  /// only knows as text answers null, so "there is no face here" is a value
  /// and the caller draws initials. A person who is not in the directory at
  /// all answers the same way, since the two are indistinguishable from a
  /// mailbox and the avatar does not care which it is.
  ///
  /// Throws [DirectoryUnavailable] on the failures that are not about this
  /// person: `scopeMissing: true` means asking again can never work this
  /// session, false means it might — a throttle, a 500, a dropped socket.
  /// Auth failures pass through UNWRAPPED, exactly as for [searchPeople].
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'});
}
