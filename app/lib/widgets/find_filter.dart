import '../models/message_models.dart';
import '../models/needs_you_sort.dart';
import '../models/storyline_models.dart';
import '../services/attention.dart';
import 'app_rail.dart';
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

/// Whether a thread answers the needle.
///
/// The empty needle matches EVERYTHING — that is what makes an empty box the
/// unfiltered rail rather than an empty one.
///
/// Both titles are tried because the rail draws different ones in different
/// sections: [needsYouTitleFor] is the ask, [railTitleFor] is the person, and
/// a reader typing either has typed something they can see. The subject and
/// the participants follow, because they are what the reader would type to
/// find a thread whose ask they never read.
bool conversationMatches(Conversation c, String find) {
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
}) {
  final needle = normalizeFind(find);

  bool keepThread(Conversation c) =>
      conversationMatches(c, needle) && (!unreadOnly || c.hasUnread);
  bool keepRoom(PersonRoom r) =>
      roomMatches(r, needle) && (!unreadOnly || r.unread > 0);

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
