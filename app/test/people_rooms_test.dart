import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// The grouping behind the People section: one row per person, however many
/// threads and whichever connectors they reach through.
///
/// The interesting cases are all about the OWNER. A thread carries everybody
/// on it including the account, mail names them by address and Teams names
/// them by display name, and a room that failed to drop them would be a room
/// the user is standing in.

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
  group('roomKeyFor', () {
    test('the owner is dropped by address', () {
      final key = roomKeyFor(
        _conv(id: 'a', people: const [
          Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          Participant(name: 'Eric Nolan', email: 'eric@example.com'),
        ]),
        owner: _owner,
      );

      expect(key, 'eric nolan');
    });

    test('and by name when the address is one no mailbox would match', () {
      // The Teams case: the roster names the account with a `teams:` id, so
      // the address arm cannot help and the name arm is all there is.
      final key = roomKeyFor(
        _conv(id: 'chat-1', source: 'teams', people: const [
          Participant(name: 'Dana Whitfield', email: 'teams:19:aaa'),
          Participant(name: 'Eric Nolan', email: 'teams:19:bbb'),
        ]),
        owner: _owner,
      );

      expect(key, 'eric nolan');
    });

    test('is case-insensitive, and unbothered by stray whitespace', () {
      final loud = roomKeyFor(
        _conv(id: 'a', people: const [Participant(name: 'ERIC NOLAN')]),
        owner: _owner,
      );
      final quiet = roomKeyFor(
        _conv(id: 'b', people: const [Participant(name: '  eric nolan  ')]),
        owner: _owner,
      );

      expect(loud, 'eric nolan');
      expect(quiet, loud);
    });

    test('falls back to the address when a party has no name', () {
      final key = roomKeyFor(
        _conv(id: 'a', people: const [Participant(email: 'Noreply@Bank.com')]),
        owner: _owner,
      );

      expect(key, 'noreply@bank.com');
    });

    test('nobody but the owner files under (no sender)', () {
      expect(
        roomKeyFor(
          _conv(id: 'a', people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.com'),
          ]),
          owner: _owner,
        ),
        noSenderRoom,
      );
      expect(roomKeyFor(_conv(id: 'b'), owner: _owner), noSenderRoom);
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

    test('a group of three spells them out; a crowd trails off', () {
      Conversation group(String id, List<String> names) => _conv(
            id: id,
            people: [
              const Participant(name: 'Dana Whitfield'),
              for (final n in names) Participant(name: n),
            ],
          );

      final rooms = peopleRooms(
        [
          group('a', ['Eric Nolan', 'Priya Raman', 'Tom Alder']),
          group('b', ['Ada Sun', 'Bo Vance', 'Cleo Marsh', 'Dev Rao', 'Eve Ng']),
        ],
        owner: _owner,
      );

      final titles = rooms.map((r) => r.title).toSet();
      expect(titles, {
        'Eric Nolan, Priya Raman, Tom Alder',
        'Ada Sun, Bo Vance, Cleo Marsh…',
      });
    });

    test('unread sums and needs-you counts across the room', () {
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
          _conv(
            id: 'c',
            people: const [Participant(name: 'Eric Nolan')],
          ),
        ],
        owner: _owner,
      );

      expect(rooms.single.threads.length, 3);
      expect(rooms.single.unread, 5);
      expect(rooms.single.needsYou, 2);
    });

    test('a deferred thread and a done one are in no room at all', () {
      final rooms = peopleRooms(
        [
          _conv(
            id: 'later',
            people: const [Participant(name: 'Eric Nolan')],
            bucket: 'later',
          ),
          _conv(
            id: 'done',
            people: const [Participant(name: 'Priya Raman')],
            state: ConversationState.done,
          ),
        ],
        owner: _owner,
      );

      expect(rooms, isEmpty);
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

    test('with no owner resolved yet, nobody is dropped', () {
      // The first frames, before the keychain read lands. Grouping everyone
      // together is wrong-but-harmless; dropping the wrong person is not.
      final rooms = peopleRooms(
        [
          _conv(id: 'a', people: const [
            Participant(name: 'Dana Whitfield'),
            Participant(name: 'Eric Nolan'),
          ]),
        ],
        owner: (name: null, address: null),
      );

      expect(rooms.single.title, 'Dana Whitfield, Eric Nolan');
    });
  });
}
