import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/find_filter.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a needle matches, and what Enter opens.
///
/// The contract worth pinning is the LAST group: `firstFindTarget` walks the
/// column in the order the rail draws it, so "Enter opens the top match" is a
/// promise about the row under the reader's eyes. `app_rail_test` holds the
/// other half of that agreement.

const Owner _owner = (name: 'Dana Whitfield', address: 'dana@example.com');

Conversation _conv({
  required String id,
  String? who,
  String? email,
  String? subject,
  String? cta,
  ConversationState state = ConversationState.needsReply,
  int unread = 0,
  String? lastMessageAt = '2026-09-03T10:00:00Z',
}) =>
    Conversation(
      id: id,
      subject: subject,
      participants: (who == null && email == null)
          ? const []
          : [Participant(name: who, email: email)],
      state: state,
      ctaText: cta,
      unreadCount: unread,
      lastMessageAt: lastMessageAt,
    );

Storyline _storyline(String id, String title) =>
    Storyline(id: id, title: title, status: 'active', memberCount: 2);

void main() {
  group('normalizeFind', () {
    test('trims and lowercases, so every compare is against one thing', () {
      expect(normalizeFind('  LAUNCH  '), 'launch');
      expect(normalizeFind(''), '');
    });
  });

  group('conversationMatches', () {
    test('an empty needle matches everything — that is the unfiltered rail',
        () {
      expect(conversationMatches(_conv(id: 'a'), ''), isTrue);
    });

    test('matches the ask, which is what a Needs You row is titled by', () {
      final c = _conv(id: 'a', cta: 'Confirm the launch date');

      expect(conversationMatches(c, 'launch'), isTrue);
    });

    test('matches the person, which is what a People row is titled by', () {
      final c = _conv(id: 'a', who: 'Eric Vance');

      expect(conversationMatches(c, 'eric'), isTrue);
    });

    test('matches the subject', () {
      final c = _conv(id: 'a', who: 'Eric Vance', subject: 'Homepage copy');

      expect(conversationMatches(c, 'homepage'), isTrue);
    });

    test('matches a participant address nobody put in the title', () {
      final c = _conv(id: 'a', who: 'Eric Vance', email: 'eric@example.com');

      expect(conversationMatches(c, '@example.com'), isTrue);
    });

    test('and says no to a needle nothing on the row answers', () {
      final c = _conv(id: 'a', who: 'Eric Vance', subject: 'Homepage copy');

      expect(conversationMatches(c, 'invoice'), isFalse);
    });
  });

  group('storylineMatches and roomMatches', () {
    test('a storyline matches on its title, which is the whole row', () {
      expect(storylineMatches(_storyline('s1', 'Website redesign'), 'redesign'),
          isTrue);
      expect(storylineMatches(_storyline('s1', 'Website redesign'), 'invoice'),
          isFalse);
      expect(storylineMatches(_storyline('s1', 'Website redesign'), ''), isTrue);
    });

    test('a room matches on the people it is named for', () {
      final rooms = peopleRooms(
        [_conv(id: 'a', who: 'Eric Vance', email: 'eric@example.com')],
        owner: _owner,
      );

      expect(roomMatches(rooms.single, 'eric'), isTrue);
      expect(roomMatches(rooms.single, 'dana'), isFalse);
    });
  });

  group('firstFindTarget', () {
    List<Conversation> conversations() => [
          _conv(id: 'a', who: 'Eric Vance', cta: 'Confirm the launch date'),
          _conv(id: 'b', who: 'Priya Raman', cta: 'Sign the invoice', unread: 1),
        ];

    test('on Home it walks threads, then storylines, then rooms', () {
      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: conversations(),
        storylines: [_storyline('s1', 'Website redesign')],
        rooms: peopleRooms(conversations(), owner: _owner),
        find: 'invoice',
        unreadOnly: false,
        threshold: 0,
      );

      expect(target, isA<FindThread>());
      expect((target as FindThread).conversationKey, 'b');
    });

    test('a needle only a storyline answers falls through to it', () {
      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: conversations(),
        storylines: [_storyline('s1', 'Website redesign')],
        rooms: const [],
        find: 'redesign',
        unreadOnly: false,
        threshold: 0,
      );

      expect((target as FindStoryline).id, 's1');
    });

    test('and one only a room answers falls through to that', () {
      final rows = [
        // Not on the hook, so it is a room and never a Needs You row.
        _conv(id: 'q', who: 'Priya Raman', cta: null,
            state: ConversationState.waiting),
      ];
      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: rows,
        storylines: const [],
        rooms: peopleRooms(rows, owner: _owner),
        find: 'priya',
        unreadOnly: false,
        threshold: 0,
      );

      expect(target, isA<FindRoom>());
    });

    test('Drafts scopes to the same stack its row lives in', () {
      final rows = conversations();
      Object? targetFor(RailSection scope) => firstFindTarget(
            scope: scope,
            conversations: rows,
            storylines: const [],
            rooms: const [],
            find: 'launch',
            unreadOnly: false,
            threshold: 0,
          );

      expect(
        (targetFor(RailSection.drafts) as FindThread).conversationKey,
        (targetFor(RailSection.home) as FindThread).conversationKey,
      );
    });

    test('a one-section scope never falls through to another section', () {
      final target = firstFindTarget(
        scope: RailSection.needsYou,
        conversations: conversations(),
        storylines: [_storyline('s1', 'Website redesign')],
        rooms: const [],
        find: 'redesign',
        unreadOnly: false,
        threshold: 0,
      );

      // Needs You is what the reader is looking at. Opening a storyline from
      // it would be opening something the column is not drawing.
      expect(target, isNull);
    });

    test('unreadOnly narrows threads, and leaves storylines alone', () {
      final unreadThread = firstFindTarget(
        scope: RailSection.home,
        conversations: conversations(),
        storylines: const [],
        rooms: const [],
        // 'a' matches and is read; 'b' matches nothing here.
        find: 'launch',
        unreadOnly: true,
        threshold: 0,
      );
      expect(unreadThread, isNull);

      final storyline = firstFindTarget(
        scope: RailSection.storylines,
        conversations: const [],
        storylines: [_storyline('s1', 'Website redesign')],
        rooms: const [],
        find: 'redesign',
        unreadOnly: true,
        threshold: 0,
      );
      // A storyline is not read or unread, so the toggle must not hide one.
      expect((storyline as FindStoryline).id, 's1');
    });

    test('Later, Files and AI have no first row for Enter to mean', () {
      // A Files column is a list of SHELVES rather than of rows — there is
      // nothing in it for Enter to open.
      for (final scope in const [
        RailSection.archive,
        RailSection.files,
        RailSection.ai,
      ]) {
        expect(
          firstFindTarget(
            scope: scope,
            conversations: conversations(),
            storylines: [_storyline('s1', 'Website redesign')],
            rooms: peopleRooms(conversations(), owner: _owner),
            find: 'launch',
            unreadOnly: false,
            threshold: 0,
          ),
          isNull,
          reason: '$scope',
        );
      }
    });

    test('a needle nothing answers is null, which is the cue to search', () {
      expect(
        firstFindTarget(
          scope: RailSection.home,
          conversations: conversations(),
          storylines: [_storyline('s1', 'Website redesign')],
          rooms: peopleRooms(conversations(), owner: _owner),
          find: 'zzzz',
          unreadOnly: false,
          threshold: 0,
        ),
        isNull,
      );
    });
  });
}
