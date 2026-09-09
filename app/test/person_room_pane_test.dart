import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/people_sort.dart';
import 'package:bond_inbox/services/profile_photos.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:bond_inbox/widgets/person_room_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One person, every thread with them, as cards.
///
/// The load-bearing claims are that the list is TOP-anchored — it used to be a
/// `reverse: true` timeline, which left a person with three threads reading as
/// a gap with three cards under it — and that nothing is missing from it: a
/// done thread and a deferred one are here, marked, because the question the
/// stop answers is what there IS with somebody.

Conversation _thread(
  String id, {
  String source = 'email',
  String? subject,
  String? preview,
  String? cta,
  int messageCount = 1,
  int unreadCount = 0,
  String? at = '2026-09-04T10:00:00Z',
  ConversationState state = ConversationState.waiting,
  String? bucket,
  List<Participant>? people,
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: people ??
          const [Participant(name: 'Dana Whitfield', email: 'dana@example.test')],
      lastMessageAt: at,
      lastMessagePreview: preview,
      ctaText: cta,
      messageCount: messageCount,
      unreadCount: unreadCount,
      state: state,
      bucket: bucket,
    );

/// A room over [threads]; everything in [direct] is a 1:1 with her.
PersonRoom _room(
  List<Conversation> threads, {
  Set<String>? direct,
  Map<String, List<String>>? companions,
  int needsYou = 0,
}) =>
    PersonRoom(
      key: 'dana whitfield',
      title: 'Dana Whitfield',
      threads: threads,
      unread: 0,
      needsYou: needsYou,
      sources: {for (final t in threads) t.source},
      latestAt: threads.isEmpty ? null : threads.first.lastMessageAt,
      people: const [
        Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
      ],
      direct: {
        for (final t in threads)
          if (direct == null || direct.contains(t.id))
            (source: t.source, conversationKey: t.id),
      },
      companions: {
        for (final t in threads)
          (source: t.source, conversationKey: t.id):
              companions?[t.id] ?? const [],
      },
    );

void main() {
  final now = DateTime(2026, 9, 8, 12);

  group('the with-line', () {
    test('nobody else on it draws no line at all', () {
      expect(withLine(const []), isNull);
      expect(withLine(const ['   ']), isNull);
    });

    test('one, two and three names are spelled out', () {
      expect(withLine(const ['Ada Sun']), 'with Ada Sun');
      expect(withLine(const ['Ada Sun', 'Bo Vance']), 'with Ada Sun, Bo Vance');
      expect(
        withLine(const ['Ada Sun', 'Bo Vance', 'Cleo Marsh']),
        'with Ada Sun, Bo Vance, Cleo Marsh',
      );
    });

    test('a fourth turns the tail into a count', () {
      expect(
        withLine(const ['Ada Sun', 'Bo Vance', 'Cleo Marsh', 'Dev Rao']),
        'with Ada Sun, Bo Vance, Cleo Marsh +1',
      );
      expect(
        withLine(const [
          'Ada Sun',
          'Bo Vance',
          'Cleo Marsh',
          'Dev Rao',
          'Eve Ng',
        ]),
        'with Ada Sun, Bo Vance, Cleo Marsh +2',
      );
    });
  });

  group('the chat a Message goes into', () {
    test('is the newest DIRECT chat', () {
      final newest =
          _thread('chat-new', source: 'teams', at: '2026-09-05T10:00:00Z');
      final older =
          _thread('chat-old', source: 'teams', at: '2026-09-01T10:00:00Z');

      expect(directChat(_room([newest, older]))?.id, 'chat-new');
    });

    test('and a group chat does not count', () {
      // A sentence typed at one person's name must not land in a nine-way
      // chat because it was the newest thing they spoke in.
      final group =
          _thread('chat-group', source: 'teams', at: '2026-09-05T10:00:00Z');
      final direct =
          _thread('chat-1', source: 'teams', at: '2026-09-01T10:00:00Z');

      expect(
        directChat(_room([group, direct], direct: {'chat-1'}))?.id,
        'chat-1',
      );
      expect(directChat(_room([group], direct: const {})), isNull);
    });

    test('a person the reader has only mailed has none', () {
      expect(directChat(_room([_thread('c1')])), isNull);
    });
  });

  test('the newest mail thread is the one a new message answers', () {
    final newest = _thread('c-new', at: '2026-09-05T10:00:00Z');
    final older = _thread('c-old', at: '2026-09-01T10:00:00Z');
    final chat = _thread('chat-1', source: 'teams', at: '2026-09-06T10:00:00Z');

    expect(newestMailThread(_room([chat, newest, older]))?.id, 'c-new');
    expect(newestMailThread(_room([chat])), isNull);
  });

  group('the subtitle', () {
    test('names both connectors when both are there', () {
      final room = _room([
        _thread('c1'),
        _thread('chat-1', source: 'teams'),
      ]);
      expect(roomSubtitle(room), '2 threads · mail and Teams');
    });

    test('names one when there is one, and counts in the singular', () {
      expect(roomSubtitle(_room([_thread('c1')])), '1 thread · mail');
      expect(
        roomSubtitle(_room([_thread('chat-1', source: 'teams')])),
        '1 thread · Teams',
      );
    });

    test('and says how much of it is finished', () {
      final room = _room([
        _thread('c1'),
        _thread('c2'),
        _thread('c3', state: ConversationState.done),
      ]);
      expect(roomSubtitle(room), '3 threads · mail · 1 done');
    });

    test('and how much of it was put off', () {
      final room = _room([
        _thread('c1'),
        _thread('c2', bucket: 'later'),
        _thread('c3', state: ConversationState.done),
      ]);
      expect(roomSubtitle(room), '3 threads · mail · 1 done · 1 later');
    });
  });

  group('the pane', () {
    late TextEditingController controller;

    setUp(() => controller = TextEditingController());
    tearDown(() => controller.dispose());

    Future<List<(String, String)>> pump(
      WidgetTester tester, {
      required PersonRoom room,
      RoomFilter filter = RoomFilter.all,
      RoomSort sort = RoomSort.newest,
      String needle = '',
      Widget? emptyNotice,
      void Function(RoomFilter)? onFilter,
      void Function(RoomSort)? onSort,
      void Function(String)? onSearch,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final opened = <(String, String)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PersonRoomPane(
            room: room,
            filter: filter,
            onFilter: onFilter ?? (_) {},
            sort: sort,
            onSort: onSort ?? (_) {},
            searchController: controller,
            onSearch: onSearch ?? (_) {},
            needle: needle,
            now: now,
            photos: const NoProfilePhotos(),
            onOpenThread: (source, key) => opened.add((source, key)),
            emptyNotice: emptyNotice,
          ),
        ),
      ));
      await tester.pump();
      return opened;
    }

    double topOf(WidgetTester tester, String source, String id) =>
        tester.getTopLeft(find.byKey(RootMessageCard.keyFor(source, id))).dy;

    testWidgets('a mail thread reads as a card with its own numbers',
        (tester) async {
      await pump(
        tester,
        room: _room([
          _thread(
            'c1',
            subject: 'Re: Homepage copy',
            preview: 'The hero paragraph.',
            cta: 'Send the survey back',
            messageCount: 3,
            at: '2026-09-08T10:00:00Z',
          ),
        ]),
      );

      // The reply prefix comes off — the thread is one conversation.
      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('Dana Whitfield · The hero paragraph.'), findsOneWidget);
      expect(find.text('Send the survey back'), findsOneWidget);
      // The elapsed unit itself is the clock's business — what this pins is
      // that the count and the age are on one line.
      expect(find.textContaining('3 messages · last '), findsOneWidget);
      expect(find.text('open ›'), findsOneWidget);
    });

    testWidgets('a one-message thread counts in the singular', (tester) async {
      await pump(tester, room: _room([_thread('c1', subject: 'One')]));
      expect(find.textContaining('1 message · last'), findsOneWidget);
    });

    testWidgets('a chat is titled by its subject and previews alone',
        (tester) async {
      await pump(
        tester,
        room: _room([
          _thread(
            'chat-1',
            source: 'teams',
            subject: 'Launch date',
            preview: 'The fourteenth works.',
            people: const [
              Participant(name: 'Dana Whitfield', email: 'teams:19:abc'),
              Participant(name: 'Priya Raman', email: 'teams:19:def'),
            ],
          ),
        ]),
      );

      expect(find.text('💬 Launch date'), findsOneWidget);
      // No `who ·` prefix: a chat's messages come from everyone in it, so
      // naming one of them as the speaker would name the wrong person.
      expect(find.text('The fourteenth works.'), findsOneWidget);
      expect(find.textContaining('with '), findsNothing);
    });

    testWidgets('a group card says who else was on it; a direct one does not',
        (tester) async {
      await pump(
        tester,
        room: _room(
          [
            _thread('g1', subject: 'The five of us'),
            _thread('c1', subject: 'Just us', at: '2026-09-01T10:00:00Z'),
          ],
          direct: {'c1'},
          companions: {
            'g1': const ['Ada Sun', 'Bo Vance'],
          },
        ),
      );

      expect(find.text('with Ada Sun, Bo Vance'), findsOneWidget);
      expect(find.textContaining('with '), findsOneWidget);
    });

    testWidgets('a subjectless chat is titled Chat, with the line under it',
        (tester) async {
      await pump(
        tester,
        room: _room(
          [_thread('chat-1', source: 'teams', preview: 'The fourteenth works.')],
          direct: const {},
          companions: {
            'chat-1': const ['Ada Sun', 'Bo Vance'],
          },
        ),
      );

      // The roster used to be spelled into the title; it is the line's job now.
      expect(find.text('💬 Chat'), findsOneWidget);
      expect(find.text('with Ada Sun, Bo Vance'), findsOneWidget);
      expect(find.text('The fourteenth works.'), findsOneWidget);
    });

    testWidgets('a done card and a deferred one say which they are',
        (tester) async {
      await pump(
        tester,
        room: _room([
          _thread('c1', subject: 'Shut', state: ConversationState.done),
          _thread(
            'c2',
            subject: 'Parked',
            bucket: 'later',
            at: '2026-09-01T10:00:00Z',
          ),
        ]),
      );

      expect(find.textContaining('Done · 1 message'), findsOneWidget);
      expect(find.textContaining('Later · 1 message'), findsOneWidget);
    });

    testWidgets('the cards are newest first, and the list is NOT reversed',
        (tester) async {
      await pump(
        tester,
        room: _room([
          _thread('new', subject: 'New', at: '2026-09-08T10:00:00Z'),
          _thread('old', subject: 'Old', at: '2026-09-01T10:00:00Z'),
        ]),
      );

      // Top-anchored: the room used to pin short content to the bottom of the
      // pane, which read as a gap where the history should start.
      expect(
        tester
            .widget<ListView>(find.byKey(PersonRoomPane.listKey))
            .reverse,
        isFalse,
      );
      expect(topOf(tester, 'email', 'new'),
          lessThan(topOf(tester, 'email', 'old')));
    });

    testWidgets('and Oldest first turns them over', (tester) async {
      await pump(
        tester,
        room: _room([
          _thread('new', subject: 'New', at: '2026-09-08T10:00:00Z'),
          _thread('old', subject: 'Old', at: '2026-09-01T10:00:00Z'),
        ]),
        sort: RoomSort.oldest,
      );

      expect(topOf(tester, 'email', 'old'),
          lessThan(topOf(tester, 'email', 'new')));
    });

    testWidgets('the sort menu reports the order the reader picked',
        (tester) async {
      final picked = <RoomSort>[];
      await pump(
        tester,
        room: _room([_thread('c1', subject: 'One')]),
        onSort: picked.add,
      );

      await tester.tap(find.byKey(PersonRoomPane.sortKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byKey(PersonRoomPane.sortItemKeyFor(RoomSort.oldest)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(picked, [RoomSort.oldest]);
    });

    testWidgets('Direct and Groups split her threads', (tester) async {
      final room = _room(
        [
          _thread('c1', subject: 'Just us'),
          _thread(
            'g1',
            subject: 'The five of us',
            at: '2026-09-01T10:00:00Z',
            people: const [
              Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
              Participant(name: 'Priya Raman', email: 'priya@example.test'),
            ],
          ),
        ],
        direct: {'c1'},
      );

      await pump(tester, room: room, filter: RoomFilter.direct);
      expect(find.text('Just us'), findsOneWidget);
      expect(find.text('The five of us'), findsNothing);

      await pump(tester, room: room, filter: RoomFilter.groups);
      expect(find.text('The five of us'), findsOneWidget);
      expect(find.text('Just us'), findsNothing);
    });

    testWidgets('a pill reports the filter the reader picked', (tester) async {
      final picked = <RoomFilter>[];
      await pump(
        tester,
        room: _room([_thread('c1', subject: 'One')]),
        onFilter: picked.add,
      );

      await tester.tap(find.descendant(
        of: find.byKey(PersonRoomPane.filterPillsKey),
        matching: find.text(RoomFilter.groups.label),
      ));
      await tester.pump();

      expect(picked, [RoomFilter.groups]);
    });

    testWidgets('the filter field narrows by subject and by who was on it',
        (tester) async {
      final typed = <String>[];
      final room = _room([
        _thread('c1', subject: 'Homepage copy'),
        _thread(
          'g1',
          subject: 'Launch plan',
          at: '2026-09-01T10:00:00Z',
          people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
            Participant(name: 'Priya Raman', email: 'priya@example.test'),
          ],
        ),
      ]);

      await pump(tester, room: room, onSearch: typed.add);
      await tester.enterText(find.byType(TextField), 'homepage');
      await tester.pump();
      expect(typed, ['homepage']);

      await pump(tester, room: room, needle: 'homepage');
      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('Launch plan'), findsNothing);

      await pump(tester, room: room, needle: 'priya');
      expect(find.text('Launch plan'), findsOneWidget);
      expect(find.text('Homepage copy'), findsNothing);
    });

    testWidgets('tapping a card opens that thread', (tester) async {
      final opened = await pump(
        tester,
        room: _room([_thread('c1', subject: 'Homepage copy')]),
      );

      await tester.tap(find.byKey(RootMessageCard.keyFor('email', 'c1')));
      await tester.pump();

      expect(opened, [('email', 'c1')]);
    });

    testWidgets('an empty room and a narrowed one say different things',
        (tester) async {
      await pump(tester, room: _room(const []));
      expect(find.byKey(PersonRoomPane.emptyKey), findsOneWidget);
      expect(find.text('No threads with them.'), findsOneWidget);

      await pump(
        tester,
        room: _room([_thread('c1', subject: 'One')]),
        needle: 'zzz',
      );
      expect(find.text('Nothing matches.'), findsOneWidget);
      expect(find.text('No threads with them.'), findsNothing);
    });

    testWidgets('the host\'s scope notice sits under the empty line',
        (tester) async {
      await pump(
        tester,
        room: _room(const []),
        emptyNotice: const Text('Showing Teams only.'),
      );

      expect(find.text('No threads with them.'), findsOneWidget);
      expect(find.text('Showing Teams only.'), findsOneWidget);
    });
  });
}
