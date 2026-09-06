import '../../models/person.dart';

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
}
