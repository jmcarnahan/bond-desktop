import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/people_sort.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// The People stop's four pure functions: how the directory is ordered and
/// narrowed, and how one person's threads are.
///
/// Stability is the load-bearing property in all four. Dart's own sort is not
/// stable, and a directory that reshuffled its ties between two frames would
/// move a row out from under the finger going for it.

Conversation _thread(
  String id, {
  String source = 'email',
  String? subject,
  String? preview,
  String? cta,
  String? at = '2026-09-04T10:00:00Z',
  List<Participant> people = const [
    Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
  ],
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: people,
      lastMessageAt: at,
      lastMessagePreview: preview,
      ctaText: cta,
    );

PersonRoom _room(
  String key, {
  String? title,
  int unread = 0,
  int needsYou = 0,
  List<Conversation> threads = const [],
  Set<ThreadTargetLike> direct = const {},
  Map<String, List<String>> companions = const {},
}) =>
    PersonRoom(
      key: key,
      title: title ?? key,
      threads: threads,
      unread: unread,
      needsYou: needsYou,
      sources: {for (final t in threads) t.source},
      latestAt: threads.isEmpty ? null : threads.first.lastMessageAt,
      people: const [],
      direct: {
        for (final d in direct)
          (source: d.source, conversationKey: d.conversationKey),
      },
      companions: {
        for (final entry in companions.entries)
          (source: 'email', conversationKey: entry.key): entry.value,
      },
    );

/// The record `direct` holds, spelled out so the fixture reads.
typedef ThreadTargetLike = ({String source, String conversationKey});

void main() {
  group('sortRooms', () {
    test('Most recent is the input untouched', () {
      final rooms = [_room('b'), _room('a'), _room('c')];
      expect(
        sortRooms(PeopleSort.recent, rooms).map((r) => r.key),
        ['b', 'a', 'c'],
      );
    });

    test('By name is alphabetical, case-insensitively', () {
      final rooms = [_room('cleo', title: 'Cleo Marsh'),
        _room('ada', title: 'ada sun'), _room('bo', title: 'Bo Vance')];
      expect(
        sortRooms(PeopleSort.name, rooms).map((r) => r.key),
        ['ada', 'bo', 'cleo'],
      );
    });

    test('and puts the no-sender room last, because it is not a person', () {
      final rooms = [
        _room(noSenderRoom, title: noSenderRoom),
        _room('zoe', title: 'Zoe Kerr'),
      ];
      expect(
        sortRooms(PeopleSort.name, rooms).map((r) => r.key),
        ['zoe', noSenderRoom],
      );
    });

    test('Needs you first ranks by the count, then keeps input order', () {
      final rooms = [
        _room('quiet'),
        _room('one', needsYou: 1),
        _room('also-quiet'),
        _room('three', needsYou: 3),
      ];
      expect(
        sortRooms(PeopleSort.needsYou, rooms).map((r) => r.key),
        ['three', 'one', 'quiet', 'also-quiet'],
      );
    });

    test('and it is stable where the counts tie', () {
      final rooms = [
        _room('first', needsYou: 2),
        _room('second', needsYou: 2),
        _room('third', needsYou: 2),
      ];
      expect(
        sortRooms(PeopleSort.needsYou, rooms).map((r) => r.key),
        ['first', 'second', 'third'],
      );
    });
  });

  group('filterRooms', () {
    final rooms = [
      _room('dana', title: 'Dana Whitfield', unread: 2, needsYou: 1),
      _room('eric', title: 'Eric Nolan', unread: 3),
      _room('priya', title: 'Priya Raman'),
    ];

    test('the empty needle and All keep everything, in order', () {
      expect(
        filterRooms(rooms, PeopleFilter.all, '').map((r) => r.key),
        ['dana', 'eric', 'priya'],
      );
    });

    test('the needle matches the title', () {
      expect(
        filterRooms(rooms, PeopleFilter.all, 'nolan').map((r) => r.key),
        ['eric'],
      );
    });

    test('Needs you keeps only rooms that are owed something', () {
      expect(
        filterRooms(rooms, PeopleFilter.needsYou, '').map((r) => r.key),
        ['dana'],
      );
    });

    test('Unread keeps only rooms with unread mail', () {
      expect(
        filterRooms(rooms, PeopleFilter.unread, '').map((r) => r.key),
        ['dana', 'eric'],
      );
    });

    test('a pill and a needle both apply', () {
      expect(
        filterRooms(rooms, PeopleFilter.unread, 'dana').map((r) => r.key),
        ['dana'],
      );
    });
  });

  group('sortRoomThreads', () {
    test('Newest first, Oldest first', () {
      final threads = [
        _thread('mid', at: '2026-09-04T10:00:00Z'),
        _thread('new', at: '2026-09-08T10:00:00Z'),
        _thread('old', at: '2026-09-01T10:00:00Z'),
      ];

      expect(
        sortRoomThreads(RoomSort.newest, threads).map((c) => c.id),
        ['new', 'mid', 'old'],
      );
      expect(
        sortRoomThreads(RoomSort.oldest, threads).map((c) => c.id),
        ['old', 'mid', 'new'],
      );
    });

    test('an undated thread is last under BOTH orders', () {
      // It is not the newest and it is not the oldest either — a card nobody
      // can date must not lead the list at whichever end is being read.
      final threads = [
        _thread('undated', at: null),
        _thread('dated', at: '2026-09-04T10:00:00Z'),
      ];

      expect(
        sortRoomThreads(RoomSort.newest, threads).map((c) => c.id),
        ['dated', 'undated'],
      );
      expect(
        sortRoomThreads(RoomSort.oldest, threads).map((c) => c.id),
        ['dated', 'undated'],
      );
    });

    test('equal stamps keep the order they arrived in', () {
      final threads = [
        _thread('a'),
        _thread('b'),
        _thread('c'),
      ];
      expect(
        sortRoomThreads(RoomSort.newest, threads).map((c) => c.id),
        ['a', 'b', 'c'],
      );
      expect(
        sortRoomThreads(RoomSort.oldest, threads).map((c) => c.id),
        ['a', 'b', 'c'],
      );
    });
  });

  group('filterRoomThreads', () {
    final oneToOne = _thread('c1', subject: 'Re: Homepage copy',
        preview: 'The hero paragraph.');
    final group = _thread(
      'g1',
      subject: 'Launch plan',
      cta: 'Send the survey back',
      people: const [
        Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
        Participant(name: 'Priya Raman', email: 'priya@example.test'),
      ],
    );
    final room = _room(
      'dana',
      title: 'Dana Whitfield',
      threads: [oneToOne, group],
      direct: const {(source: 'email', conversationKey: 'c1')},
    );

    test('All and an empty needle keep everything', () {
      expect(
        filterRoomThreads(room, RoomFilter.all, '').map((c) => c.id),
        ['c1', 'g1'],
      );
    });

    test('Direct keeps the 1:1s and Groups keeps the rest', () {
      expect(
        filterRoomThreads(room, RoomFilter.direct, '').map((c) => c.id),
        ['c1'],
      );
      expect(
        filterRoomThreads(room, RoomFilter.groups, '').map((c) => c.id),
        ['g1'],
      );
    });

    test('the needle matches the subject, with its reply prefix off', () {
      expect(
        filterRoomThreads(room, RoomFilter.all, 'homepage').map((c) => c.id),
        ['c1'],
      );
    });

    test('and the preview', () {
      expect(
        filterRoomThreads(room, RoomFilter.all, 'hero').map((c) => c.id),
        ['c1'],
      );
    });

    test('and the ask', () {
      expect(
        filterRoomThreads(room, RoomFilter.all, 'survey').map((c) => c.id),
        ['g1'],
      );
    });

    test('and whoever else was on it', () {
      expect(
        filterRoomThreads(room, RoomFilter.all, 'priya').map((c) => c.id),
        ['g1'],
      );
    });

    test('and the name the card shows for a recipient stored nameless', () {
      // The room was grouped from resolved names; a thread whose recipient
      // the sync stored as an address alone still has to answer to the name
      // its card is drawing.
      final nameless = _thread(
        'out-1',
        subject: 'Rate sheet',
        people: const [Participant(email: 'priya@example.test')],
      );
      final resolved = _room(
        'dana',
        threads: [nameless],
        companions: const {
          'out-1': ['Priya Raman'],
        },
      );
      expect(
        filterRoomThreads(resolved, RoomFilter.all, 'priya raman')
            .map((c) => c.id),
        ['out-1'],
      );
    });

    test('a needle nothing answers empties the room', () {
      expect(filterRoomThreads(room, RoomFilter.all, 'zzz'), isEmpty);
    });
  });
}
