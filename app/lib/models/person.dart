import 'package:flutter/foundation.dart' show immutable;

/// A person a message can be addressed to, from whichever of the three places
/// the app can learn about one.
///
/// The three are not interchangeable, which is why [PersonSource] is on the
/// model rather than kept beside it: a directory hit carries a Graph user id
/// and can therefore open a Teams chat; a recent carries whatever the stored
/// rows remember, which for mail is an address and no id at all; and a typed
/// address is a claim the user made that nothing has verified. A field that
/// only recorded "a person" would leave the compose screen unable to tell
/// which of them it may start a chat with.

/// Where a [Person] was learned.
enum PersonSource {
  /// A `search_people_json` / Graph `/users` hit — the only source that always
  /// carries a real Graph user id.
  directory,

  /// Reconstructed from rows already in this database.
  recent,

  /// An address the user typed. Mail only; there is no id behind it.
  typed,
}

/// Which channel a recipient is being picked for. Lives here, in `models/`, so
/// a widget can take it as a parameter without importing a provider.
enum RecipientChannel { mail, teams }

/// The prefix that marks an id this app invented because Microsoft gave it
/// none. Everything else is a Graph user id.
const String _mailIdPrefix = 'mail:';

@immutable
class Person {
  /// The Graph user id, or `mail:<lowercased address>` when no id is known.
  ///
  /// Never empty in practice, and the identity for `==`: two rows naming the
  /// same person through different spellings of their display name are one
  /// person, and the same address typed in two cases is one id by
  /// construction.
  final String id;

  final String displayName;
  final String? mail;
  final String? userPrincipalName;
  final String? jobTitle;
  final PersonSource source;

  const Person({
    required this.id,
    required this.displayName,
    this.mail,
    this.userPrincipalName,
    this.jobTitle,
    this.source = PersonSource.directory,
  });

  /// An address somebody typed into the recipients field.
  ///
  /// The id is derived from the address rather than left absent, so the same
  /// address typed twice — or typed once and picked once — collapses to one
  /// chip, which is the whole reason `==` is on the id.
  factory Person.typed(String address) {
    final trimmed = address.trim();
    return Person(
      id: '$_mailIdPrefix${trimmed.toLowerCase()}',
      displayName: trimmed,
      mail: trimmed,
      source: PersonSource.typed,
    );
  }

  /// One entry of `search_people_json`'s `people` list.
  ///
  /// The wire is snake_case; Graph's own `/users` is camelCase and is mapped
  /// by `graph_people.dart` instead. An empty string is read as absent — the
  /// server omits a missing `mail`, but nothing downstream may tell the
  /// difference between a person with no mailbox and one with an empty one.
  factory Person.fromDirectoryJson(Map<String, dynamic> json) {
    return Person(
      id: json['id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      mail: _present(json['mail']),
      userPrincipalName: _present(json['user_principal_name']),
      jobTitle: _present(json['job_title']),
      source: PersonSource.directory,
    );
  }

  /// The address to send mail to: the mailbox when there is one, else the
  /// sign-in name, which in most tenants is deliverable. Empty when neither is
  /// known, which is what makes a person mail-unaddressable.
  String get address => mail ?? userPrincipalName ?? '';

  /// Whether [id] is Microsoft's rather than this app's invention — the one
  /// test that decides whether a Teams chat can be opened with this person.
  bool get hasGraphId => !id.startsWith(_mailIdPrefix) && id.isNotEmpty;

  /// This person as the `messages` and `conversations` tables spell a Teams
  /// participant, or null when there is no Graph id to spell.
  String? get teamsAddress => hasGraphId ? 'teams:$id' : null;

  /// The key two people are the same address under. EMPTY for anyone with no
  /// address at all — a Teams-only recent, say — so no caller may treat it as
  /// an identity on its own without testing for that.
  String get addressKey => address.trim().toLowerCase();

  static String? _present(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;

  @override
  bool operator ==(Object other) => other is Person && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Person($id, $displayName)';
}

/// Whether [text] is worth sending mail to.
///
/// Deliberately pragmatic rather than RFC 5322: the only job here is to keep a
/// half-typed word from becoming a chip, and every address a real mail server
/// would accept has to pass. One `@`, something before it, and a dot inside
/// the domain with characters either side — that is the whole test.
bool isValidEmailAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains(RegExp(r'\s'))) return false;
  final at = trimmed.indexOf('@');
  if (at <= 0) return false;
  if (trimmed.indexOf('@', at + 1) != -1) return false;
  final domain = trimmed.substring(at + 1);
  final dot = domain.indexOf('.');
  return dot > 0 && dot < domain.length - 1;
}
