import 'package:flutter/foundation.dart' show immutable;

import '../models/message_models.dart';
import '../models/needs_you_sort.dart';
import '../models/storyline_models.dart';
import '../services/attention.dart';
import 'app_rail.dart';
import 'find_field.dart' show completeLabelFacet, labelFacetPrefixOf;
import 'people_rooms.dart';

/// What the Find field does to the list column, as pure functions.
///
/// Find is not search. Search asks the index a question and costs an embedding
/// call; Find narrows the rows that are ALREADY on the rail, live, on every
/// keystroke. So it matches only what a row actually shows or is — the ask,
/// the subject, the people on it — and never a message body, which the rail
/// does not hold and could not honestly claim to have looked in.

/// A typed needle, ready to compare against. Trimmed and lowercased once, so
/// every `contains` below is measured against the same thing.
String normalizeFind(String raw) => raw.trim().toLowerCase();

/// A typed needle read into its facets and the words underneath them.
///
/// Find's facets are not search's: this is the ⌘K layer over rows already in
/// memory, so it can ask about a thread's labels and its state — which the
/// index does not hold — and cannot ask about a body, which these rows do not
/// hold. `services/search_grammar.dart` is the other parser and stays its own;
/// the two share a philosophy and no code.
///
/// The philosophy is that parser's, verbatim: **every unrecognised `word:`
/// token stays text.** An unknown facet, a known facet with a value it does not
/// take, a facet with nothing after it — all of them are words the reader
/// typed, and a box that swallowed `re:` or a URL because it looked like a
/// facet would be a box nobody could trust with an ordinary sentence. There is
/// no error channel here to explain what happened.
///
/// `is:external` is the one facet that needs something from OUTSIDE the row it
/// is asked about — whose domains are the owner's — and it takes it as data
/// rather than reaching for it: [conversationMatchesQuery] grows an
/// `ownerDomains` argument and this file still performs no I/O and holds no
/// address of its own. A caller that passes none narrows to nothing, which is
/// the same answer `Conversation.isExternalTo` gives for the same reason.
///
/// There is NO `-is:external`, and that is a decision rather than an omission:
/// `-label:` is the only negation this grammar has, `is:dismissed` has never
/// had one, and one `is:` value that could be negated while the other could not
/// would read as a bug in whichever one the reader tried second.
@immutable
class FindQuery {
  /// The words left once the facets have been lifted out, normalised. The whole
  /// needle when no facet was recognised — see [parse].
  final String text;

  /// `label:<name>` — every one of these must be on the thread. Normalised
  /// names, compared whole against [Label.name] rather than as substrings: the
  /// autocomplete completes to a name, and a substring `label:ops` that also
  /// caught `Ops handover` would narrow to more than the reader asked for.
  final List<String> labels;

  /// `-label:<name>` — none of these may be.
  final List<String> withoutLabels;

  /// `from:<text>` — a substring of the name the ROW is titled by, which is the
  /// "from" a reader can see. Every one must match.
  final List<String> senders;

  /// `is:done` (or its older spelling `is:dismissed`) — the thread is done.
  /// The one state facet, because it is the one state a reader looks for by
  /// name: needing a reply is what the whole column is already about. Both
  /// words, because the screen says Mark done and a needle typed before it
  /// did still says dismissed.
  final bool dismissedOnly;

  /// `has:attachment` — the thread carries a file. The same count the row's
  /// paperclip draws, so the facet agrees with what the reader can see.
  final bool attachmentsOnly;

  /// `is:external` — the thread's latest inbound sender is outside the owner's
  /// domains, the same question the row's External chip answers, so the facet
  /// and the mark can never disagree about a thread.
  final bool externalOnly;

  const FindQuery({
    this.text = '',
    this.labels = const [],
    this.withoutLabels = const [],
    this.senders = const [],
    this.dismissedOnly = false,
    this.attachmentsOnly = false,
    this.externalOnly = false,
  });

  /// Whether this query asks anything a STORYLINE or a person room could not
  /// answer. A storyline has no labels, no sender and no attachments, so a
  /// query carrying one of those is about threads and must not fall through to
  /// one — see [firstFindTarget].
  bool get hasThreadFacets =>
      labels.isNotEmpty ||
      withoutLabels.isNotEmpty ||
      senders.isNotEmpty ||
      dismissedOnly ||
      attachmentsOnly ||
      externalOnly;

  /// Reads a needle. Never throws, and never refuses one.
  ///
  /// Two fast paths, and both exist to make a facet-free needle behave exactly
  /// as it did before facets existed: a needle with no colon in it is the
  /// [text] and nothing else, and so is one whose colons all turned out to be
  /// words. Only once a facet has actually been recognised is the remainder
  /// rebuilt from the tokens — which is also where quoting stops being
  /// invisible, since `"two words"` arrives as the two words with nothing
  /// around them. Quoting is a grouping gesture, not something to search for.
  static FindQuery parse(String raw) {
    final needle = normalizeFind(raw);
    if (!needle.contains(':')) return FindQuery(text: needle);

    final labels = <String>[];
    final withoutLabels = <String>[];
    final senders = <String>[];
    var dismissedOnly = false;
    var attachmentsOnly = false;
    var externalOnly = false;
    final words = <String>[];

    for (final token in _tokenise(needle)) {
      final colon = token.indexOf(':');
      // A colon at the very start is not a facet name, and one at the very end
      // is a facet with nothing in it — both are words.
      if (colon > 0 && colon < token.length - 1) {
        final name = token.substring(0, colon);
        final value = token.substring(colon + 1).trim();
        if (value.isNotEmpty) {
          switch (name) {
            case 'label':
              labels.add(value);
              continue;
            case '-label':
              withoutLabels.add(value);
              continue;
            case 'from':
              senders.add(value);
              continue;
            case 'is':
              if (value == 'done' || value == 'dismissed') {
                dismissedOnly = true;
                continue;
              }
              if (value == 'external') {
                externalOnly = true;
                continue;
              }
            case 'has':
              if (const {'attachment', 'attachments', 'file', 'files'}
                  .contains(value)) {
                attachmentsOnly = true;
                continue;
              }
          }
        }
      }
      words.add(token);
    }

    final query = FindQuery(
      text: words.join(' ').trim(),
      labels: labels,
      withoutLabels: withoutLabels,
      senders: senders,
      dismissedOnly: dismissedOnly,
      attachmentsOnly: attachmentsOnly,
      externalOnly: externalOnly,
    );
    // Nothing was a facet after all, so the needle is the needle — whitespace,
    // quotes and every colon exactly as they were typed.
    return query.hasThreadFacets ? query : FindQuery(text: needle);
  }
}

/// Splits on whitespace, keeping anything inside double quotes together.
///
/// Lifted in spirit from `search_grammar._tokenise`, and separate from it for
/// the reason the two parsers are separate: that file is the index's grammar
/// and this one is the rail's, and a shared tokeniser would be the seam through
/// which one grammar's change reached the other.
///
/// The quotes are dropped as they are read, so `label:"vendor outreach"`
/// arrives as one token spelled `label:vendor outreach`.
List<String> _tokenise(String raw) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quoted = false;

  void flush() {
    final token = buffer.toString();
    buffer.clear();
    if (token.isNotEmpty) tokens.add(token);
  }

  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')) {
      flush();
      continue;
    }
    buffer.write(ch);
  }
  flush();
  return tokens;
}

/// Whether a thread answers the needle, facets and words together.
///
/// Kept on its original signature — a [Conversation] and a normalised string —
/// because the rail calls it once per row and knows nothing about facets. It
/// parses per call, which a needle with no colon in it makes almost free; a
/// caller with a query already in hand should reach for
/// [conversationMatchesQuery] instead.
///
/// [ownerDomains] is only ever read by `is:external`. A caller that passes none
/// still gets every other facet exactly as it was.
bool conversationMatches(
  Conversation c,
  String find, {
  Set<String> ownerDomains = const {},
}) =>
    conversationMatchesQuery(
      c,
      FindQuery.parse(find),
      ownerDomains: ownerDomains,
    );

/// The same question with the needle already read.
///
/// Every facet narrows — they combine AND-wise with each other and with the
/// words, because that is what a reader adding a second term to a filter box
/// means by it. The words are tried LAST: they are the only clause that walks
/// several fields, and a cheap `state` or `label` refusal above them saves it.
bool conversationMatchesQuery(
  Conversation c,
  FindQuery query, {
  Set<String> ownerDomains = const {},
}) {
  if (query.dismissedOnly && c.state != ConversationState.done) return false;
  if (query.attachmentsOnly && c.attachmentCount <= 0) return false;
  if (query.externalOnly && !c.isExternalTo(ownerDomains)) return false;
  for (final name in query.labels) {
    if (!_carriesLabel(c, name)) return false;
  }
  for (final name in query.withoutLabels) {
    if (_carriesLabel(c, name)) return false;
  }
  for (final who in query.senders) {
    if (!_isFrom(c, who)) return false;
  }
  return conversationMatchesText(c, query.text);
}

/// Whether one of the owner's words is on this thread, by name.
bool _carriesLabel(Conversation c, String name) {
  for (final label in c.labels) {
    if (label.name.trim().toLowerCase() == name) return true;
  }
  return false;
}

/// Whether the name the ROW is titled by answers `from:`.
///
/// The primary participant and not every participant on the thread: the row
/// draws one name, `from:` is a question about that name, and a facet that also
/// matched the six people copied in would quietly mean `with:`.
bool _isFrom(Conversation c, String who) {
  final p = c.primaryParticipant;
  if (p == null) return false;
  return (p.name ?? '').toLowerCase().contains(who) ||
      (p.email ?? '').toLowerCase().contains(who);
}

/// Whether a thread answers the WORDS of a needle — Find as it was before it
/// had facets.
///
/// The empty needle matches EVERYTHING — that is what makes an empty box the
/// unfiltered rail rather than an empty one.
///
/// Both titles are tried because the rail draws different ones in different
/// sections: [needsYouTitleFor] is the ask, [railTitleFor] is the person, and
/// a reader typing either has typed something they can see. The subject and
/// the participants follow, because they are what the reader would type to
/// find a thread whose ask they never read.
bool conversationMatchesText(Conversation c, String find) {
  if (find.isEmpty) return true;
  if (needsYouTitleFor(c).toLowerCase().contains(find)) return true;
  if (railTitleFor(c).toLowerCase().contains(find)) return true;
  if ((c.subject ?? '').toLowerCase().contains(find)) return true;
  for (final p in c.participants) {
    if ((p.name ?? '').toLowerCase().contains(find)) return true;
    if ((p.email ?? '').toLowerCase().contains(find)) return true;
  }
  return false;
}

/// Whether a storyline answers the needle. Its title and nothing else: the
/// title is the whole row, and the charter behind it is a paragraph nobody is
/// typing three letters of.
bool storylineMatches(Storyline s, String find) =>
    find.isEmpty || s.title.toLowerCase().contains(find);

/// Whether a person room answers the needle. Its title is the people in it,
/// already spelled out by [peopleRooms], so matching it matches them.
bool roomMatches(PersonRoom r, String find) =>
    find.isEmpty || r.title.toLowerCase().contains(find);

/// What Enter in the Find field opens.
sealed class FindTarget {
  const FindTarget();
}

final class FindThread extends FindTarget {
  final String source;
  final String conversationKey;

  const FindThread(this.source, this.conversationKey);
}

final class FindStoryline extends FindTarget {
  final String id;

  const FindStoryline(this.id);
}

final class FindRoom extends FindTarget {
  final String key;

  const FindRoom(this.key);
}

/// The FIRST row the column is drawing, for the scope it is drawing, once the
/// filters are applied — which is what Enter opens.
///
/// This function and [AppRail] MUST agree, and the agreement is not decorative:
/// "Enter opens the top match" is only a promise anyone can act on if the top
/// match is the row under their eyes. So the walk here is the stack's own
/// order — Needs You, then storylines, then rooms.
///
/// [needsYouSort] is the order the rail is drawing the pile in, and it is
/// passed rather than read here for the same reason the threshold is: this
/// file knows no preferences, and the screen that owns the setting hands the
/// same value to both.
///
/// The rail's `+N more` truncation cannot come between them, and that is a
/// consequence of WHERE it filters rather than luck: the rail narrows the
/// Needs You list and only then cuts it to [AttentionTuning.topCount], so the
/// first surviving row is always the first row drawn. Cutting first and
/// filtering second would let Enter open a thread the column had already
/// dropped, which is why the rail must never be "optimised" into that order.
/// A test pins the two against each other.
///
/// [ownerDomains] is passed for the same reason and from the same place: the
/// screen that knows who is signed in hands the identical set to the rail and to
/// this walk, so `is:external` cannot mean one thing in the column and another
/// under Enter.
///
/// Later days, the Files stop and the AI stop answer null. A day is a bucket
/// rather than a thing, the Files column is a list of SHELVES rather than of
/// rows, and the AI pane is one screen with no list beside it — none of the
/// three has a first row for Enter to mean.
FindTarget? firstFindTarget({
  required RailSection scope,
  required List<Conversation> conversations,
  required List<Storyline> storylines,
  required List<PersonRoom> rooms,
  required String find,
  required bool unreadOnly,
  required double threshold,
  NeedsYouSort needsYouSort = NeedsYouSort.priority,
  Set<String> ownerDomains = const {},
}) {
  // Read once and reused, unlike the rail's per-row call: this walk has the
  // whole needle in hand before it starts.
  final query = FindQuery.parse(find);
  final needle = query.text;
  // A storyline has no labels, no sender and no files, so it cannot answer a
  // query that asks about one — and Enter must not fall through to a row that
  // is only "matching" because the clause that would have refused it does not
  // apply. A facet narrows the walk to threads.
  final threadsOnly = query.hasThreadFacets;

  bool keepThread(Conversation c) =>
      conversationMatchesQuery(c, query, ownerDomains: ownerDomains) &&
      (!unreadOnly || c.hasUnread);
  bool keepRoom(PersonRoom r) =>
      !threadsOnly && roomMatches(r, needle) && (!unreadOnly || r.unread > 0);

  FindTarget? firstThread() {
    // The reader's chosen order, applied exactly where the rail applies it —
    // to the whole pile, before the match. Reading the rail's order and then
    // walking a different one is the one way this function can lie.
    final pile = sortNeedsYou(
      needsYouSort,
      needsYouRows(conversations, threshold: threshold),
    );
    for (final c in pile) {
      if (keepThread(c)) return FindThread(c.source, c.id);
    }
    return null;
  }

  FindTarget? firstStoryline() {
    if (threadsOnly) return null;
    for (final s in storylineRows(storylines)) {
      // The unread filter never touches storylines: a storyline is not read or
      // unread, and hiding one under a filter about mail would make the toggle
      // mean two things.
      if (storylineMatches(s, needle)) return FindStoryline(s.id);
    }
    return null;
  }

  FindTarget? firstRoom() {
    for (final room in rooms) {
      if (keepRoom(room)) return FindRoom(room.key);
    }
    return null;
  }

  switch (scope) {
    // Drafts scopes to the SAME stack — its row lives in it — so Enter walks
    // the same three sections the reader is looking at.
    case RailSection.home:
    case RailSection.drafts:
      return firstThread() ?? firstStoryline() ?? firstRoom();
    case RailSection.needsYou:
      return firstThread();
    case RailSection.storylines:
      return firstStoryline();
    case RailSection.people:
      return firstRoom();
    case RailSection.files:
    case RailSection.archive:
    case RailSection.ai:
      return null;
  }
}

/// The needle a label chip's press leaves in Find: [needle] with
/// `label:<name>` added — once, and read as a query rather than as text, so a
/// box holding `label:opsx` or `-label:ops` still gains the chip's `ops`,
/// and one already asking for it (in any case, quoted or bare) gains nothing.
///
/// A `-label:` of the same word is taken OUT: the chip asks for the label,
/// and leaving its exclusion beside it would narrow to nothing. Everything
/// else the reader typed — a `from:`, plain words — survives in place. The
/// facet is spelled by [completeLabelFacet], so a name with a space in it is
/// quoted exactly as the box's own completion quotes it, and the result
/// always ends in a space, ready for the next word.
String withLabelFacet(String needle, String name) {
  final facet = completeLabelFacet('label:', name);
  final wanted = normalizeFind(name);
  // A half-typed label term under the caret — `label:` or `label:op` with no
  // space yet — is this same ask, mid-word: finish that term, the box's own
  // suggestion-press rule, rather than leaving its stub beside a second copy
  // for the parser to read as a word no row contains. Only while what is
  // typed still spells this chip's name; a WHOLE other label there is an ask
  // of its own and keeps. A half-typed `-label:` that spells it completes
  // too, into the exclusion the removal below cancels — either way the stub
  // does not survive the press.
  final typed = labelFacetPrefixOf(needle);
  final base = typed != null && wanted.startsWith(typed)
      ? completeLabelFacet(needle, name)
      : needle;
  var kept = base
      .replaceAllMapped(_labelExclusion, (m) {
        // Inside a quoted phrase this is the reader's words, not a facet: an
        // odd number of quotes before the match means one is open over it.
        if ('"'.allMatches(base.substring(0, m.start)).length.isOdd) {
          return m[0]!;
        }
        final value = m[1] ?? m[2] ?? '';
        return normalizeFind(value) == wanted ? '' : m[0]!;
      })
      .trim();
  // A quote left open swallows everything after it into one quoted word —
  // the facet about to be added included. Closing it keeps the reader's
  // half-quoted words as the words they typed and the facet as a facet.
  if ('"'.allMatches(kept).length.isOdd) kept = '$kept"';
  if (kept.isEmpty) return facet;
  if (FindQuery.parse(kept).labels.contains(wanted)) return '$kept ';
  return '$kept $facet';
}

/// One `-label:` term as [FindQuery.parse] reads it, quoted or bare, with the
/// whitespace after it — taken out along with the term, so a removal leaves
/// no double space and the spaces INSIDE a quoted phrase are never touched.
final RegExp _labelExclusion =
    RegExp(r'(?<!\S)-label:(?:"([^"]*)"|(\S+))\s*', caseSensitive: false);

/// Where the column goes when a label chip writes its facet into Find, from
/// the section it is on. Find narrows whatever the column is scoped to, so
/// from Storylines or People the facet would filter storylines or rooms and
/// the chip's "Filter Needs You" would be a lie: those move to Needs You.
/// The Inbox and Needs You already show the Needs You stack, and so does
/// Drafts & sent, a row of the Inbox stack whose MAIN pane is its own list —
/// moving the section there swapped that list for the Needs You overview
/// under a reader who was still using it — so those stay. Elsewhere the
/// overview a thread sits beside follows the section to Needs You, which is
/// the list the chip asked for.
///
/// Null (the Inbox, never yet moved off) stays null.
RailSection? sectionForLabelFind(RailSection? here) => switch (here) {
      null => null,
      RailSection.home || RailSection.needsYou || RailSection.drafts => here,
      _ => RailSection.needsYou,
    };
