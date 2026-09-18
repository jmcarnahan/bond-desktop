/// The three ways a storyline's own description admits everything.
///
/// A charter is what every membership confirmation is judged against, so a
/// charter that names a team, a person or a shape of message is not a weak
/// charter — it is a charter that says yes to the whole mailbox, and the
/// confirms then rubber-stamp whatever the shortlist put in front of them.
/// The golden set's anti-storylines are the same three mistakes written down
/// by a person; this is the cheap lexical half of that judgement, applied to
/// what the naming pass just wrote, before a single confirmation is spent.
///
/// Pure, and dependency-free on purpose: it is read by the service and
/// counted by the sweep bench, and a lint that needed a store could be
/// neither. It never REWRITES anything. A hit is grounds for throwing the
/// proposal away, which is the only remedy that costs nothing — the alternative
/// is asking the model again for a sentence it has already shown it cannot
/// write about these threads.
library;

/// Words that name no effort. A title or charter carrying one is a placeholder
/// the model reached for when it had nothing specific to say.
/// `general` and `other` are deliberately NOT here. Both are ordinary English
/// about real work — a general contractor, the other suite — and a lint that
/// refused them would throw away the storylines this exists to protect.
final RegExp _placeholderWords = RegExp(
  r'\b(placeholder|unrelated|misc(ellaneous)?|various|assorted|untitled)\b',
  caseSensitive: false,
);

/// A charter whose SUBJECT is a class of message rather than a piece of work:
/// "emails from the team", "all updates", "notifications about deliveries".
/// Anchored at the start, because what a charter opens with is what it is
/// about; the same nouns appearing mid-sentence are ordinary description.
final RegExp _categoryOpening = RegExp(
  r'^(all |any |the )?(emails?|messages?|threads?|correspondence|updates?|'
  r'notifications?|newsletters?|invoices?|receipts?|reports?|alerts?)\b',
  caseSensitive: false,
);

/// The clause that rescues a category opening by naming what the messages are
/// ABOUT. "Emails about the River Street fit-out" is a storyline; "emails from
/// the team" is a mailbox.
/// The preposition has to be followed by something: "Updates on" names no
/// subject, and a clause that rescues a charter has to say what the subject is.
final RegExp _aboutClause = RegExp(
  r'\b(about|for|on|regarding)\s+\S',
  caseSensitive: false,
);

/// Anything that is not a word character — what the residue test counts by.
final RegExp _nonWord = RegExp(r'[^A-Za-z0-9]');

/// Words that carry no subject of their own, so a charter left holding only
/// these has named nothing. Deliberately small: this list is a floor under the
/// person rule, not a stopword list for retrieval.
const Set<String> _stopwords = {
  'a', 'about', 'all', 'an', 'and', 'any', 'anything', 'are', 'around', 'as',
  'at', 'be', 'belongs', 'between', 'both', 'by', 'conversation',
  'conversations', 'email', 'emails', 'everything', 'for', 'from', 'here',
  'his', 'her', 'in', 'into', 'involving', 'is', 'it', 'its', 'mail',
  'message', 'messages', 'of', 'on', 'or', 'our', 'regarding', 'related',
  'she', 'talks', 'that', 'the', 'their', 'them', 'these', 'they', 'this',
  'thread', 'threads', 'to', 'topic', 'topics', 'up', 'us', 'we', 'what',
  'when', 'where', 'which', 'who', 'with', 'work',
};

/// Why this storyline's description admits everything, or null when it names
/// something specific.
///
/// Three verdicts, checked in this order, because a charter can be more than
/// one of them and the first is the most certain:
///
/// - `placeholder` — the title or the charter carries a word that names no
///   effort at all: placeholder, unrelated, misc, miscellaneous, various,
///   assorted, untitled.
/// - `person` — the charter names the people and nothing else: it mentions at
///   least one of [participants], and once those names and the stopwords are
///   removed fewer than three word characters are left. A person is not an
///   effort: filing by who wrote it buries the work under a contact card.
/// - `category` — the charter's subject is a class of message ("all
///   notifications", "invoices") with no clause saying what they are about.
///
/// [participants] are the display names of everyone on the cluster's threads.
/// An empty list cannot produce a `person` hit, which is the honest answer:
/// with nobody to compare against there is no evidence the charter is a roster.
String? charterLint({
  required String title,
  required String charter,
  required List<String> participants,
}) {
  final trimmedTitle = title.trim();
  final trimmedCharter = charter.trim();

  if (_placeholderWords.hasMatch(trimmedTitle) ||
      _placeholderWords.hasMatch(trimmedCharter)) {
    return 'placeholder';
  }

  if (_isRoster(trimmedCharter, participants)) return 'person';

  if (_categoryOpening.hasMatch(trimmedCharter)) {
    // The opening is only a verdict when nothing after it says what the
    // messages are about. The clause is looked for in what FOLLOWS the
    // opening: a charter that begins "About the…" has already named its
    // subject, and one that begins "Emails" has not.
    final rest = trimmedCharter.substring(
      _categoryOpening.firstMatch(trimmedCharter)!.end,
    );
    if (!_aboutClause.hasMatch(rest)) return 'category';
  }

  return null;
}

/// Whether [charter] is a roster: the people on the threads, and no subject.
///
/// Two conditions, and both are needed. The charter has to MENTION somebody on
/// these threads — otherwise a sentence about a budget and a sentence about a
/// person would be judged the same way — and what is left once those names and
/// the stopwords come out has to be under three word characters. The second is
/// what makes this a judgement about the whole charter rather than about its
/// nouns: "Dana and Priya on the River Street fit-out" keeps `river`, `street`
/// and `fit`, while "Threads between Dana and Priya" keeps nothing.
///
/// Capitalisation is deliberately not consulted. A charter's first word is
/// capitalised because it opens a sentence, and reading that as a proper noun
/// would make the rule fire on where a full stop happened to fall.
bool _isRoster(String charter, List<String> participants) {
  if (participants.isEmpty || charter.isEmpty) return false;

  final names = <String>{};
  for (final person in participants) {
    for (final token in person.split(_nonWord)) {
      if (token.isNotEmpty) names.add(token.toLowerCase());
    }
  }
  if (names.isEmpty) return false;

  var mentionsSomebody = false;
  var residue = 0;
  for (final token in charter.split(_nonWord)) {
    if (token.isEmpty) continue;
    final word = token.toLowerCase();
    if (names.contains(word)) {
      mentionsSomebody = true;
      continue;
    }
    if (_stopwords.contains(word)) continue;
    residue += word.length;
    if (residue >= 3) return false;
  }
  return mentionsSomebody;
}
