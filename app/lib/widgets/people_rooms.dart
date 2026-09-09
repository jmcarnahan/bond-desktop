import 'package:flutter/foundation.dart' show immutable;

import '../models/message_models.dart';
import '../providers/conversations_provider.dart' show ThreadTarget;
import 'app_rail.dart' show isNeedsYou;

/// The signed-in account, as much of it as the grouping needs.
///
/// Two fields rather than one because the two connectors name the same person
/// differently: mail carries the owner's address on every thread, while a
/// Teams roster carries `teams:<id>` and a display name. Excluding by address
/// alone would leave the owner standing in their own chat rooms.
typedef Owner = ({String? name, String? address});

/// The KEY of the room a thread with nobody but the owner on it falls into.
/// It is a real room rather than a dropped thread: mail the user sent to
/// themselves, a no-reply address, a chat whose roster failed to load are all
/// still mail, and a pile that quietly loses them is worse than one odd row.
///
/// The key is not what the row says — see [selfRoomTitle]. It stays as it is
/// because it is what a screen stores as the selection.
const String noSenderRoom = '(no sender)';

/// What the [noSenderRoom] row is CALLED. In practice it is mail the user
/// sent to themselves — a note, a forward, a probe — so the honest name is
/// the reader, not a bracket saying nobody wrote it.
const String selfRoomTitle = 'Just you';

/// A thread the reader is still in: not closed, not deferred. The two counts
/// on a room that drive bold and the badge are taken over these.
///
/// A done or deferred thread is still the person's — it is in their room and
/// marked on its card — but it owes nothing, and a badge that counted it would
/// ask the reader for work they have already put down.
bool isLiveThread(Conversation c) =>
    c.state != ConversationState.done && c.bucket != 'later';

/// One person, and every thread with them in it.
///
/// The unit the People section is a list of. A room is not stored anywhere: it
/// is derived from the conversation list on every build, which is what lets a
/// mail thread and a Teams chat with the same colleague sit in one row without
/// a cross-source identity table behind them.
///
/// A thread with three other parties on it is in THREE rooms — the room is the
/// person, not the group, so a colleague reached only inside a project thread
/// is still findable under their own name.
@immutable
class PersonRoom {
  /// One of the keys [personKeysFor] minted for every thread in it — the
  /// grouping key, and what the screen stores as the selection.
  final String key;

  /// The row's one line: the person this room is.
  final String title;

  /// The room's threads, newest first. Done and deferred ones included.
  final List<Conversation> threads;

  /// Unread messages across the room's LIVE threads.
  final int unread;

  /// How many of the LIVE [threads] the user is on the hook for, at the
  /// threshold the caller passed.
  final int needsYou;

  /// Which connectors the room's threads came from. One source earns the row a
  /// glyph; two means the same person on both, and a glyph would be a lie.
  final Set<String> sources;

  /// The newest `last_message_at` in the room, which is what orders the list.
  /// Null when nothing in it is stamped.
  final String? latestAt;

  /// The one person this room is, for the avatar and the panel. Empty for
  /// [noSenderRoom], which is nobody.
  final List<Participant> people;

  /// The threads on which this person is the ONLY other party — their 1:1s,
  /// mail and chat alike. What the `Direct` pill keeps and what the Message
  /// action writes into. Derived from [companions]: a thread with nobody else
  /// on it is a direct one, and two answers to that question would eventually
  /// disagree.
  final Set<ThreadTarget> direct;

  /// Who ELSE was on each of the room's threads — the resolved display names
  /// of the other parties, minus this person and minus the owner, in the
  /// order the thread lists them. An empty list is a direct thread.
  ///
  /// It is what the card's `with …` line is drawn from, and the reason it
  /// exists: one thread with three other parties now sits in three rooms
  /// under the same subject, and without this the three cards are identical
  /// and none of them says who the conversation was actually with.
  final Map<ThreadTarget, List<String>> companions;

  const PersonRoom({
    required this.key,
    required this.title,
    required this.threads,
    required this.unread,
    required this.needsYou,
    required this.sources,
    required this.latestAt,
    required this.people,
    this.direct = const {},
    this.companions = const {},
  });

  /// How many of the room's threads are still going. The count the room's own
  /// numbers are taken over, offered so a caller can say so.
  int get liveCount => threads.where(isLiveThread).length;
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

/// Lowercased address → display name, from every participant in [all] that
/// carries both. First name seen wins.
///
/// This is what lets an outbound-only thread — whose recipients the mail sync
/// stores with no name at all — file under the colleague it was sent to rather
/// than under their address. Without it the same person has a named room from
/// the mail they sent and a second, address-titled room from the mail the user
/// sent them, and the People list reads as a list of strangers.
///
/// Read-time and pure: nothing is written back to the store, because the name
/// is a fact about the OTHER threads in this list rather than about this one.
Map<String, String> participantNames(Iterable<Conversation> all) {
  final names = <String, String>{};
  for (final c in all) {
    for (final p in c.participants) {
      final address = p.email?.trim().toLowerCase() ?? '';
      if (address.isEmpty) continue;
      final name = p.name?.trim() ?? '';
      if (name.isEmpty) continue;
      names.putIfAbsent(address, () => name);
    }
  }
  return names;
}

/// Everyone on the thread but the account, in the order the thread lists them,
/// each person once, with [names] filling in the ones the thread left nameless.
List<Participant> _others(
  Conversation c,
  Owner owner,
  Map<String, String> names,
) {
  final out = <Participant>[];
  final seen = <String>{};
  for (final raw in c.participants) {
    // Resolved BEFORE the owner test, so a nameless recipient that turns out
    // to be the account is dropped by the name arm too.
    final p = _resolve(raw, names);
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

/// A participant with the list's name for their address, where they had none.
Participant _resolve(Participant p, Map<String, String> names) {
  final name = p.name?.trim() ?? '';
  if (name.isNotEmpty) return p;
  final address = p.email?.trim().toLowerCase() ?? '';
  if (address.isEmpty) return p;
  final known = names[address];
  if (known == null) return p;
  return Participant(name: known, email: p.email);
}

/// One key per other party on the thread: their resolved display name,
/// lowercased (their address when no name is known anywhere).
/// `[noSenderRoom]` when nobody but the owner is on it.
///
/// A name and not an address, deliberately (D7): the same colleague reaches
/// this mailbox as `dana@…` and reaches Teams as `teams:19:…`, and the display
/// name is the only thing the two have in common. It is a heuristic and it is
/// meant to be — a real cross-source identity map is a later round — but it is
/// the heuristic that makes one row out of one person.
///
/// A thread yields as many keys as it has other parties, because a room is a
/// PERSON: a colleague on a five-way project thread is in that thread's list
/// under their own name, not buried in a room titled after all five.
List<String> personKeysFor(
  Conversation c, {
  required Owner owner,
  Map<String, String> names = const {},
}) {
  final others = _others(c, owner, names);
  if (others.isEmpty) return const [noSenderRoom];
  return [for (final p in others) _displayOf(p).toLowerCase()];
}

/// The FIRST of [personKeysFor] — the person a thread is "with" when one has
/// to be picked. The thread header's faces open this person.
String roomKeyFor(
  Conversation c, {
  required Owner owner,
  Map<String, String> names = const {},
}) =>
    personKeysFor(c, owner: owner, names: names).first;

/// Newest first, with unstamped threads last. Lexicographic over the stored
/// ISO strings, which is chronological for the UTC stamps the store writes.
int _byLatestDesc(String? a, String? b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// Every thread, grouped by each person on it, most recent room first.
///
/// Over ALL of [all] rather than over the live inbox: a room is everything
/// with a person, and a reader who filtered People by Teams and found the one
/// chat they have missing — because they had marked it done — has been told
/// their colleague is not there. Done and deferred threads are IN the room and
/// marked on their cards; what excludes them is only [unread] and [needsYou],
/// the two numbers that ask for work.
List<PersonRoom> peopleRooms(
  List<Conversation> all, {
  required Owner owner,
  double threshold = 0,
}) {
  // Built once, over the whole list, and handed to every key and every member
  // walk below: a name resolved differently in two of them would file one
  // person's threads in two rooms.
  final names = participantNames(all);

  final grouped = <String, List<Conversation>>{};
  final order = <String>[];
  for (final c in all) {
    for (final key in personKeysFor(c, owner: owner, names: names)) {
      final bucket = grouped[key];
      if (bucket == null) {
        grouped[key] = [c];
        order.add(key);
      } else {
        bucket.add(c);
      }
    }
  }

  final rooms = <(int, PersonRoom)>[];
  for (var i = 0; i < order.length; i++) {
    final key = order[i];
    final threads = grouped[key]!
      ..sort((a, b) => _byLatestDesc(a.lastMessageAt, b.lastMessageAt));

    // Taken across the room's threads rather than off one of them: every
    // thread here produced the same key, so the names match, but only one of
    // them may carry a real address for the face. A mail address is preferred
    // over a `teams:` id, which is a Graph id nothing can be written to.
    Participant? best;
    for (final c in threads) {
      for (final p in _others(c, owner, names)) {
        if (_displayOf(p).toLowerCase() != key) continue;
        if (_rank(p) > _rank(best)) best = p;
      }
    }

    var unread = 0;
    var needsYou = 0;
    final sources = <String>{};
    final direct = <ThreadTarget>{};
    final companions = <ThreadTarget, List<String>>{};
    for (final c in threads) {
      sources.add(c.source);
      final target = (source: c.source, conversationKey: c.id);
      // Everyone on it but this room's person — and the owner is already out,
      // because `_others` dropped them.
      final others = [
        for (final p in _others(c, owner, names))
          if (_displayOf(p).toLowerCase() != key) _displayOf(p),
      ];
      companions[target] = others;
      // A thread with nobody else on it is a 1:1 WITH THIS PERSON — which the
      // no-sender room has none of, because it stands for nobody: an empty
      // list there means the thread had no other party at all, not that it
      // had exactly one.
      if (others.isEmpty && key != noSenderRoom) direct.add(target);
      if (!isLiveThread(c)) continue;
      unread += c.unreadCount;
      if (isNeedsYou(c, threshold: threshold)) needsYou++;
    }

    rooms.add((
      i,
      PersonRoom(
        key: key,
        title: best == null ? selfRoomTitle : _displayOf(best),
        threads: threads,
        unread: unread,
        needsYou: needsYou,
        sources: sources,
        latestAt: threads.isEmpty ? null : threads.first.lastMessageAt,
        people: best == null ? const [] : [best],
        direct: direct,
        companions: companions,
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

/// How good an instance of one person is as THE instance: a named, mailable
/// one beats a named `teams:` one, which beats one with only an address.
int _rank(Participant? p) {
  if (p == null) return -1;
  final named = (p.name?.trim() ?? '').isNotEmpty;
  final address = p.email?.trim() ?? '';
  final mailable = address.isNotEmpty && !address.startsWith('teams:');
  if (named && mailable) return 3;
  if (named && address.isNotEmpty) return 2;
  if (named) return 1;
  return 0;
}
