import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// The grouping behind the People section: one row per PERSON, however many
/// threads, whichever connectors, and whoever else was on them.
///
/// Two claims carry the file. The first is about the OWNER — a thread carries
/// everybody on it including the account, mail names them by address and Teams
/// names them by display name, and a room that failed to drop them would be a
/// room the user is standing in. The second is about NAMES: the mail sync
/// stores the recipients of the user's own mail with no name at all, so
/// without the resolution here one colleague has a named room and a second
/// room titled by their address.

Conversation _conv({
  required String id,
  String source = 'email',
  List<Participant> people = const [],
  ConversationState state = ConversationState.waiting,
  String? cta,
  String? bucket,
  double? score,
  String? lastMessageAt = '2026-09-01T09:00:00Z',
  int unread = 0,
}) =>
    Conversation(
      id: id,
      source: source,
      participants: people,
      state: state,
      ctaText: cta,
      bucket: bucket,
      attentionScore: score,
      lastMessageAt: lastMessageAt,
      unreadCount: unread,
    );

const Owner _owner = (name: 'Dana Whitfield', address: 'dana@example.com');

void main() {
  group('personKeysFor', () {
    test('the owner is dropped by address', () {
      final keys = personKeysFor(
        _conv(id: 'a', people: const [
          Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          Participant(name: 'Eric Nolan', email: 'eric@example.com'),
        ]),
        owner: _owner,
      );

      expect(keys, ['eric nolan']);
    });

    test('and by name when the address is one no mailbox would match', () {
      // The Teams case: the roster names the account with a `teams:` id, so
      // the address arm cannot help and the name arm is all there is.
      final keys = personKeysFor(
        _conv(id: 'chat-1', source: 'teams', people: const [
          Participant(name: 'Dana Whitfield', email: 'teams:19:aaa'),
          Participant(name: 'Eric Nolan', email: 'teams:19:bbb'),
        ]),
        owner: _owner,
      );

      expect(keys, ['eric nolan']);
    });

    test('is case-insensitive, and unbothered by stray whitespace', () {
      final loud = personKeysFor(
        _conv(id: 'a', people: const [Participant(name: 'ERIC NOLAN')]),
        owner: _owner,
      );
      final quiet = personKeysFor(
        _conv(id: 'b', people: const [Participant(name: '  eric nolan  ')]),
        owner: _owner,
      );

      expect(loud, ['eric nolan']);
      expect(quiet, loud);
    });

    test('falls back to the address when nobody anywhere named them', () {
      final keys = personKeysFor(
        _conv(id: 'a', people: const [
          Participant(email: 'Noreply@Bank.example'),
        ]),
        owner: _owner,
      );

      expect(keys, ['noreply@bank.example']);
    });

    test('the names map fills in a recipient the thread left nameless', () {
      // Thread B is one the USER sent: the sync stores its recipients with a
      // null name, so on its own it would key by the bare address.
      final inbound = _conv(id: 'a', people: const [
        Participant(name: 'Todd Alder', email: 'todd@example.test'),
      ]);
      final outbound = _conv(id: 'b', people: const [
        Participant(email: 'todd@example.test'),
      ]);
      final names = participantNames([inbound, outbound]);

      expect(
        personKeysFor(outbound, owner: _owner, names: names),
        ['todd alder'],
      );
      expect(personKeysFor(outbound, owner: _owner), ['todd@example.test']);
    });

    test('a three-party thread yields a key each', () {
      final keys = personKeysFor(
        _conv(id: 'a', people: const [
          Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          Participant(name: 'Eric Nolan'),
          Participant(name: 'Priya Raman'),
          Participant(name: 'Tom Alder'),
        ]),
        owner: _owner,
      );

      expect(keys, ['eric nolan', 'priya raman', 'tom alder']);
    });

    test('nobody but the owner files under (no sender)', () {
      expect(
        personKeysFor(
          _conv(id: 'a', people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          ]),
          owner: _owner,
        ),
        [noSenderRoom],
      );
      expect(personKeysFor(_conv(id: 'b'), owner: _owner), [noSenderRoom]);
    });

    test('roomKeyFor is the first of them', () {
      final c = _conv(id: 'a', people: const [
        Participant(name: 'Eric Nolan'),
        Participant(name: 'Priya Raman'),
      ]);

      expect(roomKeyFor(c, owner: _owner), 'eric nolan');
      expect(
        roomKeyFor(c, owner: _owner),
        personKeysFor(c, owner: _owner).first,
      );
    });
  });

  group('participantNames', () {
    test('the first name seen for an address wins', () {
      final names = participantNames([
        _conv(id: 'a', people: const [
          Participant(name: 'Todd Alder', email: 'todd@example.test'),
        ]),
        _conv(id: 'b', people: const [
          Participant(name: 'T. Alder', email: 'todd@example.test'),
        ]),
      ]);

      expect(names['todd@example.test'], 'Todd Alder');
    });

    test('a nameless participant contributes nothing', () {
      final names = participantNames([
        _conv(id: 'a', people: const [
          Participant(email: 'todd@example.test'),
        ]),
      ]);

      expect(names, isEmpty);
    });

    test('the keys are lowercased addresses', () {
      final names = participantNames([
        _conv(id: 'a', people: const [
          Participant(name: 'Todd Alder', email: 'Todd@Example.Test'),
        ]),
      ]);

      expect(names.keys, ['todd@example.test']);
    });
  });

  group('peopleRooms', () {
    test('a mail thread and a chat with the same person are ONE room', () {
      final rooms = peopleRooms(
        [
          _conv(id: 'c1', people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
            Participant(name: 'Eric Nolan', email: 'eric@example.com'),
          ]),
          _conv(
            id: 'chat-1',
            source: 'teams',
            people: const [
              Participant(name: 'Dana Whitfield', email: 'teams:19:aaa'),
              Participant(name: 'Eric Nolan', email: 'teams:19:bbb'),
            ],
            lastMessageAt: '2026-09-02T09:00:00Z',
          ),
        ],
        owner: _owner,
      );

      expect(rooms.length, 1);
      expect(rooms.single.title, 'Eric Nolan');
      expect(rooms.single.threads.map((c) => c.id), ['chat-1', 'c1']);
      // Two connectors, so the row earns no glyph — see the rail.
      expect(rooms.single.sources, {'email', 'teams'});
    });

    test('a group thread is in every member\'s room, and is direct in none',
        () {
      final group = _conv(id: 'g', people: const [
        Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
        Participant(name: 'Eric Nolan'),
        Participant(name: 'Priya Raman'),
      ]);
      final oneToOne = _conv(
        id: 'c1',
        people: const [Participant(name: 'Eric Nolan')],
        lastMessageAt: '2026-08-01T09:00:00Z',
      );

      final rooms = peopleRooms([group, oneToOne], owner: _owner);

      expect(rooms.map((r) => r.title), ['Eric Nolan', 'Priya Raman']);
      final eric = rooms.first;
      expect(eric.threads.map((c) => c.id), ['g', 'c1']);
      expect(eric.direct, {(source: 'email', conversationKey: 'c1')});
      expect(rooms.last.direct, isEmpty);
    });

    test('a closed thread and a deferred one are still the person\'s', () {
      // They used to be in no room at all, which is how a colleague whose one
      // Teams chat had been marked done disappeared from People entirely.
      final rooms = peopleRooms(
        [
          _conv(
            id: 'later',
            people: const [Participant(name: 'Eric Nolan')],
            bucket: 'later',
            state: ConversationState.needsReply,
            unread: 4,
          ),
          _conv(
            id: 'done',
            people: const [Participant(name: 'Eric Nolan')],
            state: ConversationState.done,
            unread: 2,
          ),
        ],
        owner: _owner,
      );

      expect(rooms.single.threads.map((c) => c.id), ['later', 'done']);
      // In the room, but owing nothing: neither number asks for work the
      // reader has already put down.
      expect(rooms.single.unread, 0);
      expect(rooms.single.needsYou, 0);
      expect(rooms.single.liveCount, 0);
    });

    test('unread sums and needs-you counts across the LIVE threads', () {
      final rooms = peopleRooms(
        [
          _conv(
            id: 'a',
            people: const [Participant(name: 'Eric Nolan')],
            state: ConversationState.needsReply,
            unread: 2,
          ),
          _conv(
            id: 'b',
            people: const [Participant(name: 'Eric Nolan')],
            cta: 'Send the rate sheet',
            unread: 3,
          ),
          _conv(id: 'c', people: const [Participant(name: 'Eric Nolan')]),
          _conv(
            id: 'shut',
            people: const [Participant(name: 'Eric Nolan')],
            state: ConversationState.done,
            unread: 9,
          ),
        ],
        owner: _owner,
      );

      expect(rooms.single.threads.length, 4);
      expect(rooms.single.liveCount, 3);
      expect(rooms.single.unread, 5);
      expect(rooms.single.needsYou, 2);
    });

    test('a nameless recipient files under the colleague, not the address',
        () {
      final rooms = peopleRooms(
        [
          _conv(id: 'in', people: const [
            Participant(name: 'Todd Alder', email: 'todd@example.test'),
          ]),
          _conv(
            id: 'out',
            people: const [Participant(email: 'todd@example.test')],
            lastMessageAt: '2026-08-01T09:00:00Z',
          ),
        ],
        owner: _owner,
      );

      expect(rooms.length, 1);
      expect(rooms.single.key, 'todd alder');
      expect(rooms.single.threads.map((c) => c.id), ['in', 'out']);
    });

    test('the threshold moves a thread between the counts, never out', () {
      final rows = [
        _conv(
          id: 'quiet',
          people: const [Participant(name: 'Eric Nolan')],
          state: ConversationState.needsReply,
          score: 0.1,
        ),
      ];

      expect(peopleRooms(rows, owner: _owner).single.needsYou, 1);
      final raised = peopleRooms(rows, owner: _owner, threshold: 0.5).single;
      expect(raised.needsYou, 0);
      expect(raised.threads.length, 1);
    });

    test('rooms are newest first, and threads inside them too', () {
      final rooms = peopleRooms(
        [
          _conv(
            id: 'old',
            people: const [Participant(name: 'Eric Nolan')],
            lastMessageAt: '2026-09-01T09:00:00Z',
          ),
          _conv(
            id: 'oldest',
            people: const [Participant(name: 'Eric Nolan')],
            lastMessageAt: '2026-08-01T09:00:00Z',
          ),
          _conv(
            id: 'new',
            people: const [Participant(name: 'Priya Raman')],
            lastMessageAt: '2026-09-05T09:00:00Z',
          ),
        ],
        owner: _owner,
      );

      expect(rooms.map((r) => r.title), ['Priya Raman', 'Eric Nolan']);
      expect(rooms.last.threads.map((c) => c.id), ['old', 'oldest']);
      expect(rooms.last.latestAt, '2026-09-01T09:00:00Z');
    });

    test('a thread with only the owner on it still has a room', () {
      final rooms = peopleRooms(
        [
          _conv(id: 'a', people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          ]),
        ],
        owner: _owner,
      );

      expect(rooms.single.key, noSenderRoom);
      expect(rooms.single.title, noSenderRoom);
      expect(rooms.single.people, isEmpty);
    });

    test('the same person listed twice on one thread is one room member', () {
      final rooms = peopleRooms(
        [
          _conv(id: 'a', people: const [
            Participant(name: 'Eric Nolan', email: 'eric@example.com'),
            Participant(name: 'Eric Nolan', email: 'eric.nolan@example.com'),
          ]),
        ],
        owner: _owner,
      );

      expect(rooms.single.key, 'eric nolan');
      expect(rooms.single.people.length, 1);
    });

    test('the face prefers the mail-addressed instance over a teams: one', () {
      // The panel writes to the address on `people`, and a `teams:` id is a
      // Graph id nothing can be written to.
      final rooms = peopleRooms(
        [
          _conv(
            id: 'chat-1',
            source: 'teams',
            people: const [
              Participant(name: 'Eric Nolan', email: 'teams:19:bbb'),
            ],
            lastMessageAt: '2026-09-05T09:00:00Z',
          ),
          _conv(id: 'c1', people: const [
            Participant(name: 'Eric Nolan', email: 'eric@example.com'),
          ]),
        ],
        owner: _owner,
      );

      expect(rooms.single.people.single.email, 'eric@example.com');
    });

    test('with no owner resolved yet, nobody is dropped', () {
      // The first frames, before the keychain read lands. Grouping everyone
      // in is wrong-but-harmless; dropping the wrong person is not.
      final rooms = peopleRooms(
        [
          _conv(id: 'a', people: const [
            Participant(name: 'Dana Whitfield'),
            Participant(name: 'Eric Nolan'),
          ]),
        ],
        owner: (name: null, address: null),
      );

      expect(rooms.map((r) => r.title), ['Dana Whitfield', 'Eric Nolan']);
    });
  });
}
