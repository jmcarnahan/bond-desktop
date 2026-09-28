import '../models/message_models.dart';
import '../models/person.dart';

/// Reading a stored Teams roster, and matching people against a typed query.
///
/// Pure arithmetic over rows already in hand — no I/O, no store, no backend —
/// which is what lets `message_store.dart` use it without importing anything
/// above itself, the same licence `conversation_state.dart` has.

/// How many members a Teams conversation row stores.
///
/// `TeamsSync` caps its participant list here, minus the signed-in user, so a
/// stored roster of exactly this size may be TRUNCATED — it is the one size at
/// which "these are the members" and "these are eight of the members" look
/// identical in the database. Every comparison below turns on that. Declared
/// here rather than reused from `TeamsSync`, whose own copy is private to the
/// row builder; the two numbers must be changed together, and raising only
/// this one would start claiming a truncated roster is complete.
const int teamsRosterCap = 8;

/// How a stored chat's roster compares with a set of people the user picked.
enum RosterMatch {
  /// The chat holds exactly these people.
  exact,

  /// The chat holds somebody else, or is missing somebody.
  different,

  /// The chat's stored roster is at the cap and the picked set contains all of
  /// it, so the real chat may hold exactly these people or may hold more.
  /// Unknowable without asking Graph, which is a request this app will not
  /// spend on a typeahead.
  unknown,
}

/// The Graph user ids on a stored Teams conversation row.
///
/// A participant whose address is not `teams:`-prefixed is skipped rather than
/// guessed at: a mail address on a Teams row is data from another source, and
/// treating it as an id would put a stranger in a member comparison.
Set<String> teamsMemberIds(Conversation chat) {
  final ids = <String>{};
  for (final participant in chat.participants) {
    final email = participant.email;
    if (email == null || !email.startsWith('teams:')) continue;
    final id = email.substring('teams:'.length);
    if (id.isNotEmpty) ids.add(id);
  }
  return ids;
}

/// Whether [chat]'s stored roster is KNOWN not to hold [userId] — the one
/// answer that refuses a mention, since Teams notifies only a chat's members.
///
/// Known means under [teamsRosterCap], which covers every 1:1: a roster at the
/// cap may be truncated, and an empty one has not been read yet, so both
/// answer false and the pick is allowed rather than refused on a guess.
bool teamsRosterLacks(Conversation chat, String userId) {
  if (chat.source != 'teams') return false;
  final stored = teamsMemberIds(chat);
  if (stored.isEmpty || stored.length >= teamsRosterCap) return false;
  return !stored.contains(userId);
}

/// Whether [chat] is the chat holding exactly [userIds].
///
/// [RosterMatch.unknown] is the answer that matters. A roster at
/// [teamsRosterCap] that the picked set covers COULD be this chat with members
/// the row never stored — so the screen offers both "send in this chat" and
/// "start a new one" rather than choosing wrong. Claiming [RosterMatch.exact]
/// there would post into a thread with people in it the user never picked;
/// claiming [RosterMatch.different] would silently create a duplicate group
/// beside one they already have.
RosterMatch rosterMatch(Conversation chat, Set<String> userIds) {
  if (chat.source != 'teams') return RosterMatch.different;
  final stored = teamsMemberIds(chat);
  if (stored.length == userIds.length && stored.containsAll(userIds)) {
    return RosterMatch.exact;
  }
  if (stored.length >= teamsRosterCap && userIds.containsAll(stored)) {
    return RosterMatch.unknown;
  }
  return RosterMatch.different;
}

/// Whether [person] is one of the people [query] is reaching for.
///
/// A prefix on any WORD of the display name, not a substring anywhere in it:
/// typing `wh` should find Sarah Whitfield and not everyone with an `h` in
/// their surname. The address matches on its prefix for the same reason —
/// somebody typing an address types it from the front.
///
/// A query of several words is matched word by word, each against the name's
/// words: `sarah wh` reaches Sarah Whitfield, and so does `wh sarah`. Taking
/// the query as one string would mean the second word typed makes the person
/// disappear, which is the opposite of narrowing.
///
/// A blank query matches everybody, which is what makes the recents list show
/// before anything is typed.
bool matchesPersonQuery(Person person, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;

  final nameWords = person.displayName.toLowerCase().split(RegExp(r'\s+'));
  final needleWords = needle.split(RegExp(r'\s+'));
  if (needleWords.every(
    (part) => nameWords.any((word) => word.startsWith(part)),
  )) {
    return true;
  }
  if (person.addressKey.startsWith(needle)) return true;
  final upn = person.userPrincipalName?.toLowerCase();
  return upn != null && upn.startsWith(needle);
}

/// Names in an unnamed Teams chat's title before it becomes "and so on".
const int teamsSubjectNameCap = 3;

/// The title an unnamed Teams chat is given on first sight: the people in it,
/// by name, at most [teamsSubjectNameCap] of them and an ellipsis after that.
/// Null when nobody on the roster has a name to show.
///
/// [participants] are the roster maps `TeamsSync` stores in
/// `participants_json` (`name`, `email`). A null name falls back to the
/// address and an EMPTY name is skipped, exactly as the sync always did it.
/// Public, and here rather than in `teams_sync.dart`, because the clustering
/// card has to recognise this title as a derived one ([isTeamsNamesSubject]),
/// and a second copy of the rule would be the one that drifted.
String? teamsNamesSubject(List<Map<String, Object?>> participants) {
  final names = [
    for (final participant in participants)
      (participant['name'] as String?) ?? (participant['email'] as String? ?? ''),
  ]..removeWhere((name) => name.isEmpty);
  if (names.isEmpty) return null;
  if (names.length <= teamsSubjectNameCap) return names.join(', ');
  return '${names.take(teamsSubjectNameCap).join(', ')}…';
}

/// Whether [subject] is a title [teamsNamesSubject] wrote rather than a topic
/// somebody gave the chat.
///
/// The stored row keeps no separate "topic" column: the sync writes the topic
/// when the chat has one and the names when it does not, into the same
/// `subject`. So the question is answered from the subject and the roster.
/// Exact equality with [teamsNamesSubject] over the stored roster is the
/// first reading. The second covers a roster that changed after first sight
/// (the title is written ONCE and never follows the members): the subject,
/// with a trailing ellipsis dropped, reads as nothing but roster names joined
/// by `, ` — matched name by name rather than split on commas, so a
/// directory name like `Whitfield, Dana` still counts as one name.
/// Case-insensitive. The cost is a chat somebody deliberately titled with
/// exactly its members' names, which reads as untitled — the same title the
/// sync would have written.
bool isTeamsNamesSubject(
  String? subject,
  List<Map<String, Object?>> participants,
) {
  final trimmed = subject?.trim() ?? '';
  if (trimmed.isEmpty) return false;
  if (trimmed == teamsNamesSubject(participants)) return true;

  final tokens = <String>{
    for (final participant in participants) ...[
      if ((participant['name'] as String?)?.trim() case final String name
          when name.isNotEmpty)
        name.toLowerCase(),
      if ((participant['email'] as String?)?.trim() case final String email
          when email.isNotEmpty)
        email.toLowerCase(),
    ],
  };
  if (tokens.isEmpty) return false;

  var text = trimmed.toLowerCase();
  if (text.endsWith('…')) text = text.substring(0, text.length - 1).trimRight();
  if (text.isEmpty) return false;

  // reachable[i]: the first i characters are a whole run of names.
  final reachable = List<bool>.filled(text.length + 1, false)..[0] = true;
  for (var i = 0; i < text.length; i++) {
    if (!reachable[i]) continue;
    final start = i == 0 ? 0 : (text.startsWith(', ', i) ? i + 2 : -1);
    if (start < 0) continue;
    for (final token in tokens) {
      if (text.startsWith(token, start)) {
        reachable[start + token.length] = true;
      }
    }
  }
  return reachable[text.length];
}
