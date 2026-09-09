import '../services/conversation_state.dart' show stripReFw;
import '../widgets/people_rooms.dart';
import 'message_models.dart';

/// How the People directory and one person's room are ordered and narrowed.
///
/// Four small vocabularies rather than one, because they answer four different
/// questions — how the people are ordered, how one person's threads are, which
/// people are shown, which threads are — and a single enum spanning them would
/// let a screen ask for "Groups" of people.
///
/// They live in `models/` for [NeedsYouSort]'s reason: a preference reads two
/// of them, and a provider importing a widget file for an enum is the wrong
/// direction for that dependency to run.

/// How the People directory is ordered.
enum PeopleSort { recent, name, needsYou }

extension PeopleSortLabel on PeopleSort {
  String get label => switch (this) {
        PeopleSort.recent => 'Most recent',
        PeopleSort.name => 'By name',
        PeopleSort.needsYou => 'Needs you first',
      };
}

/// How one person's threads are ordered inside their room.
enum RoomSort { newest, oldest }

extension RoomSortLabel on RoomSort {
  String get label => switch (this) {
        RoomSort.newest => 'Newest first',
        RoomSort.oldest => 'Oldest first',
      };
}

/// Which people the directory keeps.
enum PeopleFilter { all, needsYou, unread }

extension PeopleFilterLabel on PeopleFilter {
  String get label => switch (this) {
        PeopleFilter.all => 'All',
        PeopleFilter.needsYou => 'Needs you',
        PeopleFilter.unread => 'Unread',
      };
}

/// Which of a person's threads the room keeps.
enum RoomFilter { all, direct, groups }

extension RoomFilterLabel on RoomFilter {
  String get label => switch (this) {
        RoomFilter.all => 'All',
        RoomFilter.direct => 'Direct',
        RoomFilter.groups => 'Groups',
      };
}

/// The directory in [sort] order, stably.
///
/// [PeopleSort.recent] is the input UNTOUCHED — [peopleRooms] already orders
/// by `latestAt`, and re-deriving it here would be a second opinion about an
/// order that already has one.
///
/// [PeopleSort.name] is by lowercased title with [noSenderRoom] last: it is
/// not a person, and a bracket sorting to the top of an alphabetical list of
/// colleagues is a row nobody was looking for in the place everybody looks
/// first.
///
/// [PeopleSort.needsYou] puts everyone who is owed something first, loudest
/// first, and leaves the rest in the order they came in — the recency order,
/// which is the sensible thing to fall back to once the question "who is
/// waiting" has been answered.
///
/// Dart's sort is not stable, so the input position is carried through and
/// used as the final tie-break rather than trusted.
List<PersonRoom> sortRooms(PeopleSort sort, List<PersonRoom> rooms) {
  if (sort == PeopleSort.recent) return rooms;

  final indexed = <(int, PersonRoom)>[];
  var index = 0;
  for (final room in rooms) {
    indexed.add((index++, room));
  }

  indexed.sort((a, b) {
    switch (sort) {
      case PeopleSort.recent:
        break;
      case PeopleSort.name:
        final left = a.$2.key == noSenderRoom;
        final right = b.$2.key == noSenderRoom;
        if (left != right) return left ? 1 : -1;
        final byName =
            a.$2.title.toLowerCase().compareTo(b.$2.title.toLowerCase());
        if (byName != 0) return byName;
      case PeopleSort.needsYou:
        final left = a.$2.needsYou;
        final right = b.$2.needsYou;
        if ((left > 0) != (right > 0)) return left > 0 ? -1 : 1;
        final byCount = right.compareTo(left);
        if (byCount != 0) return byCount;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, room) in indexed) room];
}

/// The directory narrowed. Order preserved — this never reorders, because the
/// sort menu beside it is what answers that question.
///
/// [needle] is normalised by the caller (trimmed and lowercased once), so
/// every `contains` below is measured against the same thing. The empty needle
/// matches everything, which is what makes an empty box the whole directory
/// rather than an empty one.
List<PersonRoom> filterRooms(
  List<PersonRoom> rooms,
  PeopleFilter filter,
  String needle,
) {
  bool keep(PersonRoom r) {
    switch (filter) {
      case PeopleFilter.all:
        break;
      case PeopleFilter.needsYou:
        if (r.needsYou <= 0) return false;
      case PeopleFilter.unread:
        if (r.unread <= 0) return false;
    }
    if (needle.isEmpty) return true;
    return r.title.toLowerCase().contains(needle);
  }

  return [
    for (final r in rooms)
      if (keep(r)) r,
  ];
}

/// One room's threads in [sort] order, stably.
///
/// Undated threads sort LAST under BOTH orders, which is deliberate and not a
/// sign flip missed: a card nobody can date is not "the newest" and it is not
/// "the oldest" either, and putting it at whichever end the reader is looking
/// at would make an unstamped row the first thing they see twice over.
List<Conversation> sortRoomThreads(RoomSort sort, List<Conversation> threads) {
  final indexed = <(int, Conversation)>[];
  var index = 0;
  for (final c in threads) {
    indexed.add((index++, c));
  }

  indexed.sort((a, b) {
    final left = a.$2.lastMessageAt ?? '';
    final right = b.$2.lastMessageAt ?? '';
    if (left.isEmpty != right.isEmpty) return left.isEmpty ? 1 : -1;
    if (left.isEmpty) return a.$1.compareTo(b.$1);
    // ISO-8601 UTC strings compare lexicographically, so nothing has to be
    // parsed to put the rest in order.
    final byDate = sort == RoomSort.newest
        ? right.compareTo(left)
        : left.compareTo(right);
    if (byDate != 0) return byDate;
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, c) in indexed) c];
}

/// One room's threads narrowed. Order preserved, for [filterRooms]' reason.
///
/// The needle reaches further here than it does over the directory, because a
/// room is a list of threads rather than of names: the subject the reader half
/// remembers, the last line they saw, the ask the app wrote, and whoever else
/// was on it are all things somebody would type to find one conversation among
/// a colleague's forty.
List<Conversation> filterRoomThreads(
  PersonRoom room,
  RoomFilter filter,
  String needle,
) {
  bool matches(Conversation c) {
    if (needle.isEmpty) return true;
    if (stripReFw(c.subject).toLowerCase().contains(needle)) return true;
    if ((c.lastMessagePreview ?? '').toLowerCase().contains(needle)) {
      return true;
    }
    if ((c.ctaText ?? '').toLowerCase().contains(needle)) return true;
    for (final p in c.participants) {
      if (p.display.toLowerCase().contains(needle)) return true;
    }
    return false;
  }

  bool keep(Conversation c) {
    final direct = room.direct.contains(
      (source: c.source, conversationKey: c.id),
    );
    switch (filter) {
      case RoomFilter.all:
        break;
      case RoomFilter.direct:
        if (!direct) return false;
      case RoomFilter.groups:
        if (direct) return false;
    }
    return matches(c);
  }

  return [
    for (final c in room.threads)
      if (keep(c)) c,
  ];
}
