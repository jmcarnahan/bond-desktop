import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/needs_you_sort.dart';
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
  List<String> labels = const [],
  int attachments = 0,
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
      attachmentCount: attachments,
      labels: [
        for (final name in labels)
          Label(id: name.toLowerCase().replaceAll(' ', '-'), name: name),
      ],
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

  group('FindQuery.parse', () {
    test('a needle with no colon is the words and nothing else', () {
      final query = FindQuery.parse('  Launch Date ');

      expect(query.text, 'launch date');
      expect(query.hasThreadFacets, isFalse);
    });

    test('a facet is lifted out, and what is left is the words', () {
      final query = FindQuery.parse('label:legal invoice');

      expect(query.labels, ['legal']);
      expect(query.text, 'invoice');
      expect(query.hasThreadFacets, isTrue);
    });

    test('quotes group a name with a space in it, and are not searched for',
        () {
      final query = FindQuery.parse('label:"vendor outreach"');

      expect(query.labels, ['vendor outreach']);
      expect(query.text, '');
    });

    test('each facet reads into its own field', () {
      final query = FindQuery.parse(
        'label:legal -label:jira from:eric is:dismissed has:attachment ping',
      );

      expect(query.labels, ['legal']);
      expect(query.withoutLabels, ['jira']);
      expect(query.senders, ['eric']);
      expect(query.dismissedOnly, isTrue);
      expect(query.attachmentsOnly, isTrue);
      expect(query.text, 'ping');
    });

    test('and one facet can be typed twice, because both must hold', () {
      final query = FindQuery.parse('label:legal label:jira');

      expect(query.labels, ['legal', 'jira']);
    });

    test('has: takes the words a reader would actually type', () {
      for (final word in const [
        'attachment',
        'attachments',
        'file',
        'files',
      ]) {
        expect(
          FindQuery.parse('has:$word').attachmentsOnly,
          isTrue,
          reason: word,
        );
      }
    });

    test('a name this parser does not know stays text, verbatim', () {
      // The rule the whole grammar rests on: there is no error channel here, so
      // an unknown facet has to be readable as the words somebody typed.
      // `-is:external` is in the list because `is:external` DOES parse now and
      // its negation deliberately does not — `-label:` is this grammar's only
      // one, so the minus falls through to text like any other unknown name.
      for (final needle in const [
        '-is:external',
        'is:unread',
        'has:deadline',
        'foo:bar',
        'label:',
        ':legal',
        'http://example.com/plan',
      ]) {
        final query = FindQuery.parse(needle);

        expect(query.hasThreadFacets, isFalse, reason: needle);
        expect(query.text, normalizeFind(needle), reason: needle);
      }
    });

    test('a facet-free needle keeps its own spacing and its own quotes', () {
      // The pin that matters most: a needle nothing recognised is handed back
      // exactly as typed, colons, doubled spaces and quote marks included, so
      // every needle that worked before facets existed still works. The
      // remainder is only rebuilt from tokens once a facet HAS been recognised
      // — which is also the only place a quote stops being a character to look
      // for and becomes a grouping gesture.
      expect(FindQuery.parse('re:  launch').text, 're:  launch');
      expect(FindQuery.parse('"launch date"').text, '"launch date"');
    });
  });

  group('facets', () {
    test('label: keeps the threads filed under that word', () {
      final filed = _conv(id: 'a', labels: ['Waiting on legal']);
      final bare = _conv(id: 'b');

      expect(conversationMatches(filed, 'label:"waiting on legal"'), isTrue);
      expect(conversationMatches(bare, 'label:"waiting on legal"'), isFalse);
    });

    test('and matches the whole name, never a piece of it', () {
      // The autocomplete completes to a whole name, so `label:ops` is a reader
      // asking for Ops — narrowing to `Ops handover` as well would hand back
      // more than they asked for, silently.
      final c = _conv(id: 'a', labels: ['Ops handover']);

      expect(conversationMatches(c, 'label:ops'), isFalse);
      expect(conversationMatches(c, 'label:"ops handover"'), isTrue);
    });

    test('a label is matched however either side was capitalised', () {
      final c = _conv(id: 'a', labels: ['Jira Update']);

      expect(conversationMatches(c, 'LABEL:"Jira Update"'), isTrue);
    });

    test('-label: refuses the threads filed under it', () {
      final filed = _conv(id: 'a', labels: ['Jira update']);
      final bare = _conv(id: 'b');

      expect(conversationMatches(filed, '-label:"jira update"'), isFalse);
      expect(conversationMatches(bare, '-label:"jira update"'), isTrue);
    });

    test('from: matches the name the row is titled by', () {
      final c = _conv(id: 'a', who: 'Eric Vance', email: 'eric@example.com');

      expect(conversationMatches(c, 'from:vance'), isTrue);
      expect(conversationMatches(c, 'from:@example.com'), isTrue);
      expect(conversationMatches(c, 'from:priya'), isFalse);
    });

    test('and a thread with nobody on it answers no rather than throwing', () {
      expect(conversationMatches(_conv(id: 'a'), 'from:eric'), isFalse);
    });

    test('is:dismissed keeps the threads that are done', () {
      final done = _conv(id: 'a', state: ConversationState.done);
      final open = _conv(id: 'b');

      expect(conversationMatches(done, 'is:dismissed'), isTrue);
      expect(conversationMatches(open, 'is:dismissed'), isFalse);
    });

    test('has:attachment keeps the threads whose paperclip is drawn', () {
      final carrying = _conv(id: 'a', attachments: 2);
      final empty = _conv(id: 'b');

      expect(conversationMatches(carrying, 'has:attachment'), isTrue);
      expect(conversationMatches(empty, 'has:attachment'), isFalse);
    });

    test('facets narrow each other — two terms mean both', () {
      final both = _conv(
        id: 'both',
        who: 'Eric Vance',
        labels: ['Legal'],
        attachments: 1,
      );
      final onlyLabel = _conv(id: 'label', who: 'Eric Vance', labels: ['Legal']);

      expect(conversationMatches(both, 'label:legal has:attachment'), isTrue);
      expect(
        conversationMatches(onlyLabel, 'label:legal has:attachment'),
        isFalse,
      );
    });

    test('and they narrow the free text beside them', () {
      final rows = [
        _conv(id: 'a', cta: 'Sign the invoice', labels: ['Legal']),
        _conv(id: 'b', cta: 'Confirm the launch date', labels: ['Legal']),
        _conv(id: 'c', cta: 'Sign the invoice'),
      ];

      expect(
        [
          for (final c in rows)
            if (conversationMatches(c, 'label:legal invoice')) c.id,
        ],
        ['a'],
      );
    });

    test('an unrecognised term narrows exactly as the same words would', () {
      // Pinned against `conversationMatchesText` rather than against a literal:
      // whatever the words clause does, an unknown facet must do the same
      // thing, today and after the next term lands.
      final rows = [
        _conv(id: 'a', subject: 'Re: is:unread tagging'),
        _conv(id: 'b', subject: 'Launch date'),
      ];

      for (final c in rows) {
        expect(
          conversationMatches(c, 'is:unread'),
          conversationMatchesText(c, 'is:unread'),
          reason: c.id,
        );
      }
      expect(conversationMatches(rows.first, 'is:unread'), isTrue);
      expect(conversationMatches(rows.last, 'is:unread'), isFalse);
    });

    test('a needle that is only facets matches on the facets alone', () {
      // No words left once `label:` is lifted out, and an empty words clause
      // matches everything — the same rule that makes an empty box the
      // unfiltered rail.
      final c = _conv(id: 'a', subject: 'Nothing in common', labels: ['Legal']);

      expect(conversationMatches(c, 'label:legal'), isTrue);
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

    test('Enter opens the top row in the order the rail is drawing', () {
      // The two halves of one promise: the rail applies the reader's order to
      // the whole pile, and so does this. Walking the ranking while the column
      // shows the clock is the one way Enter can open a row nobody is looking
      // at.
      final rows = [
        _conv(
          id: 'older',
          who: 'Eric Vance',
          cta: 'Confirm the launch date',
          lastMessageAt: '2026-09-01T09:00:00Z',
        ),
        _conv(
          id: 'newer',
          who: 'Priya Raman',
          cta: 'Confirm the launch date',
          lastMessageAt: '2026-09-05T09:00:00Z',
        ),
      ];
      FindTarget? targetFor(NeedsYouSort sort) => firstFindTarget(
            scope: RailSection.needsYou,
            conversations: rows,
            storylines: const [],
            rooms: const [],
            find: 'launch',
            unreadOnly: false,
            threshold: 0,
            needsYouSort: sort,
          );

      expect(
        (targetFor(NeedsYouSort.priority) as FindThread).conversationKey,
        'older',
      );
      expect(
        (targetFor(NeedsYouSort.newest) as FindThread).conversationKey,
        'newer',
      );
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

    test('a facet narrows the walk to threads and never falls through', () {
      // A storyline has no labels, no sender and no files. Falling through to
      // one would open a row that is only "matching" because the clause that
      // would have refused it does not apply to it.
      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: conversations(),
        storylines: [_storyline('s1', 'Website redesign')],
        rooms: peopleRooms(conversations(), owner: _owner),
        find: 'label:legal redesign',
        unreadOnly: false,
        threshold: 0,
      );

      expect(target, isNull);
    });

    test('and Enter opens the top thread the facet leaves standing', () {
      final rows = [
        _conv(id: 'a', who: 'Eric Vance', cta: 'Confirm the launch date'),
        _conv(
          id: 'b',
          who: 'Priya Raman',
          cta: 'Confirm the launch date',
          labels: ['Waiting on legal'],
        ),
      ];
      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: rows,
        storylines: const [],
        rooms: const [],
        find: 'label:"waiting on legal" launch',
        unreadOnly: false,
        threshold: 0,
      );

      expect((target as FindThread).conversationKey, 'b');
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
