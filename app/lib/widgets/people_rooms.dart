import 'package:flutter/foundation.dart' show immutable;

import '../models/message_models.dart';
import 'app_rail.dart' show conversationRows, isNeedsYou, needsYouRows;

/// The signed-in account, as much of it as the grouping needs.
///
/// Two fields rather than one because the two connectors name the same person
/// differently: mail carries the owner's address on every thread, while a
/// Teams roster carries `teams:<id>` and a display name. Excluding by address
/// alone would leave the owner standing in their own chat rooms.
typedef Owner = ({String? name, String? address});

/// The room a thread with nobody but the owner on it falls into. It is a real
/// room rather than a dropped thread: mail from a no-reply address and a chat
/// whose roster failed to load are still mail, and a pile that quietly loses
/// them is worse than one with an oddly named row in it.
const String noSenderRoom = '(no sender)';

/// How many names a group room's title spells out before it trails off. The
/// same three `TeamsSync._subjectFor` uses, so a chat titled by its roster and
/// a room titled by its people read the same way.
const int _maxTitleNames = 3;

/// One person — or one group of them — and every live thread with them in it.
///
/// The unit the People section is a list of. A room is not stored anywhere: it
/// is derived from the conversation list on every build, which is what lets a
/// mail thread and a Teams chat with the same colleague sit in one row without
/// a cross-source identity table behind them.
@immutable
class PersonRoom {
  /// What [roomKeyFor] returned for every thread in it — the grouping key, and
  /// what the screen stores as the selection.
  final String key;

  /// The row's one line: the other party, or the group spelled out.
  final String title;

  /// The room's threads, newest first.
  final List<Conversation> threads;

  /// Unread messages across the room, summed from the rows.
  final int unread;

  /// How many of [threads] the user is on the hook for, at the threshold the
  /// caller passed.
  final int needsYou;

  /// Which connectors the room's threads came from. One source earns the row a
  /// glyph; two means the same person on both, and a glyph would be a lie.
  final Set<String> sources;

  /// The newest `last_message_at` in the room, which is what orders the list.
  /// Null when nothing in it is stamped.
  final String? latestAt;

  /// The other parties, for avatars.
  final List<Participant> people;

  const PersonRoom({
    required this.key,
    required this.title,
    required this.threads,
    required this.unread,
    required this.needsYou,
    required this.sources,
    required this.latestAt,
    required this.people,
  });
}

/// What a participant is called: their name when they have one, their address
/// when they do not.
String _displayOf(Participant p) {
  final name = p.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  return p.email?.trim() ?? '';
}

/// Whether this participant is the account itself.
///
/// Address first, because it is the exact answer where it exists. Name second,
/// because it is the ONLY answer for a Teams roster entry, whose address is a
/// `teams:<id>` that no mailbox address will ever equal — without that arm the
/// owner appears as a member of every chat room and a 1:1 chat reads as a
/// group of two.
bool _isOwner(Participant p, Owner owner) {
  final ownerAddress = owner.address?.trim().toLowerCase() ?? '';
  final email = p.email?.trim().toLowerCase() ?? '';
  if (ownerAddress.isNotEmpty && email == ownerAddress) return true;

  final ownerName = owner.name?.trim().toLowerCase() ?? '';
  final name = p.name?.trim().toLowerCase() ?? '';
  if (ownerName.isNotEmpty && name == ownerName) return true;

  return false;
}

/// Everyone on the thread but the account, in the order the thread lists them,
/// each person once.
List<Participant> _others(Conversation c, Owner owner) {
  final out = <Participant>[];
  final seen = <String>{};
  for (final p in c.participants) {
    if (_isOwner(p, owner)) continue;
    final display = _displayOf(p);
    if (display.isEmpty) continue;
    // The same colleague can be on a thread twice — once per message the
    // folder read them off — and a key that counted them twice would put an
    // otherwise identical thread in its own room.
    if (!seen.add(display.toLowerCase())) continue;
    out.add(p);
  }
  return out;
}

/// Lowercased other-party display names joined by `'\n'` (address when a name
/// is missing); the owner excluded by address or by name; [noSenderRoom] when
/// nobody is left.
///
/// A name and not an address, deliberately (D7): the same colleague reaches
/// this mailbox as `dana@…` and reaches Teams as `teams:19:…`, and the display
/// name is the only thing the two have in common. It is a heuristic and it is
/// meant to be — a real cross-source identity map is a later round — but it is
/// the heuristic that makes one row out of one person.
///
/// The newline is the separator because it is the one character a display name
/// cannot contain, so no two different groups can collide on one key.
String roomKeyFor(Conversation c, {required Owner owner}) {
  final others = _others(c, owner);
  if (others.isEmpty) return noSenderRoom;
  return [for (final p in others) _displayOf(p).toLowerCase()].join('\n');
}

/// The room's one line: one other party is their name, a handful are spelled
/// out, and a crowd trails off after three — the `TeamsSync._subjectFor` rule,
/// so a group chat's own subject and its room title agree.
String _titleFor(List<Participant> people) {
  if (people.isEmpty) return noSenderRoom;
  final names = [for (final p in people) _displayOf(p)];
  if (names.length <= _maxTitleNames) return names.join(', ');
  return '${names.take(_maxTitleNames).join(', ')}…';
}

/// Newest first, with unstamped threads last. Lexicographic over the stored
/// ISO strings, which is chronological for the UTC stamps the store writes.
int _byLatestDesc(String? a, String? b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// Every live thread, grouped by who is on it, busiest room first.
///
/// Over [needsYouRows] and [conversationRows] together — the two halves of the
/// live inbox, which between them claim each thread exactly once. Later and
/// done threads are in neither, and so are in no room: a person's room is what
/// is going on with them now, and a pile the user deferred is not that.
List<PersonRoom> peopleRooms(
  List<Conversation> all, {
  required Owner owner,
  double threshold = 0,
}) {
  final live = [
    ...needsYouRows(all, threshold: threshold),
    ...conversationRows(all, threshold: threshold),
  ];

  final grouped = <String, List<Conversation>>{};
  final order = <String>[];
  for (final c in live) {
    final key = roomKeyFor(c, owner: owner);
    final bucket = grouped[key];
    if (bucket == null) {
      grouped[key] = [c];
      order.add(key);
    } else {
      bucket.add(c);
    }
  }

  final rooms = <(int, PersonRoom)>[];
  for (var i = 0; i < order.length; i++) {
    final key = order[i];
    final threads = grouped[key]!
      ..sort((a, b) => _byLatestDesc(a.lastMessageAt, b.lastMessageAt));

    // Taken across the room's threads rather than off one of them: every
    // thread here produced the same key, so the names match, but only one of
    // them may carry a real address for the face.
    final people = <Participant>[];
    final seen = <String>{};
    for (final c in threads) {
      for (final p in _others(c, owner)) {
        if (seen.add(_displayOf(p).toLowerCase())) people.add(p);
      }
    }

    var unread = 0;
    var needsYou = 0;
    final sources = <String>{};
    for (final c in threads) {
      unread += c.unreadCount;
      if (isNeedsYou(c, threshold: threshold)) needsYou++;
      sources.add(c.source);
    }

    rooms.add((
      i,
      PersonRoom(
        key: key,
        title: _titleFor(people),
        threads: threads,
        unread: unread,
        needsYou: needsYou,
        sources: sources,
        latestAt: threads.isEmpty ? null : threads.first.lastMessageAt,
        people: people,
      ),
    ));
  }

  // Dart's sort is not stable, so the discovery order is carried through and
  // used as the tie-break rather than trusted implicitly.
  rooms.sort((a, b) {
    final byTime = _byLatestDesc(a.$2.latestAt, b.$2.latestAt);
    if (byTime != 0) return byTime;
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, room) in rooms) room];
}
