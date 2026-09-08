import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/conversations_provider.dart'
    show ThreadTarget;
import 'package:bond_inbox/services/profile_photos.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:bond_inbox/widgets/person_room_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One person's history, merged across mail and Teams.
///
/// The load-bearing claim is the ORDER: a mail thread that landed between two
/// chat messages is drawn between them, because that is the order the reader
/// lived through. Everything else here is about the room never having a hole —
/// a chat whose transcript has not arrived is a card until it does.
Conversation _thread(
  String id, {
  String source = 'email',
  String? subject,
  String? preview,
  String? cta,
  int messageCount = 1,
  int unreadCount = 0,
  String? at = '2026-09-04T10:00:00Z',
  String who = 'Dana Whitfield',
  String? address = 'dana@example.test',
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: [Participant(name: who, email: address)],
      lastMessageAt: at,
      lastMessagePreview: preview,
      ctaText: cta,
      messageCount: messageCount,
      unreadCount: unreadCount,
    );

Message _msg(String id, {required String at, String body = 'A chat line.'}) =>
    Message(
      id: id,
      outbound: false,
      source: 'teams',
      fromName: 'Dana Whitfield',
      fromAddress: 'teams:19:abc',
      receivedAt: at,
      bodyText: body,
      triageStatus: 'triaged',
    );

PersonRoom _room(List<Conversation> threads, {int people = 1, int needsYou = 0}) =>
    PersonRoom(
      key: 'dana whitfield',
      title: 'Dana Whitfield',
      threads: threads,
      unread: 0,
      needsYou: needsYou,
      sources: {for (final t in threads) t.source},
      latestAt: threads.isEmpty ? null : threads.first.lastMessageAt,
      people: [
        for (var i = 0; i < people; i++)
          Participant(
            name: i == 0 ? 'Dana Whitfield' : 'Colleague $i',
            email: i == 0 ? 'dana@example.test' : 'c$i@example.test',
          ),
      ],
    );

ThreadTarget _target(Conversation c) =>
    (source: c.source, conversationKey: c.id);

void main() {
  final now = DateTime(2026, 9, 8, 12);

  group('which chats are drawn inline', () {
    test('the newest five, and no mail', () {
      final threads = [
        for (var i = 0; i < 7; i++)
          _thread('chat-$i', source: 'teams', at: '2026-09-0${7 - i}T10:00:00Z'),
        _thread('c1'),
      ];

      final chats = roomChats(_room(threads));

      expect(chats.length, roomChatCap);
      expect(chats.map((c) => c.id), [
        'chat-0',
        'chat-1',
        'chat-2',
        'chat-3',
        'chat-4',
      ]);
    });

    test('a room with no chats has none', () {
      expect(roomChats(_room([_thread('c1')])), isEmpty);
    });
  });

  group('where the composer writes', () {
    test('one person with a chat gets their newest chat', () {
      final newest = _thread('chat-new', source: 'teams', at: '2026-09-05T10:00:00Z');
      final older = _thread('chat-old', source: 'teams', at: '2026-09-01T10:00:00Z');

      expect(
        roomComposerTarget(_room([newest, older])),
        (source: 'teams', conversationKey: 'chat-new'),
      );
    });

    test('one person the reader has only mailed gets no box', () {
      expect(roomComposerTarget(_room([_thread('c1')])), isNull);
    });

    test('a group gets no box, chat or not', () {
      // A group chat is not a place a sentence typed under a room heading
      // obviously belongs.
      final chat = _thread('chat-1', source: 'teams');
      expect(roomComposerTarget(_room([chat], people: 3)), isNull);
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
    test('names both connectors when both are live', () {
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
  });

  group('the merged timeline', () {
    test('a mail card dated between two chat messages lands between them', () {
      final chat = _thread('chat-1', source: 'teams', at: '2026-09-04T12:00:00Z');
      final mail = _thread('c1', at: '2026-09-04T11:00:00Z');
      final items = roomTimeline(_room([chat, mail]), {
        _target(chat): [
          _msg('m1', at: '2026-09-04T10:00:00Z'),
          _msg('m2', at: '2026-09-04T12:00:00Z'),
        ],
      });

      expect(items.map((i) => i.runtimeType.toString()), [
        'RoomChatHeaderItem',
        'RoomMessageItem',
        'RoomCardItem',
        'RoomChatHeaderItem',
        'RoomMessageItem',
      ]);
      // The run that resumes after the card wears its own heading, so nobody
      // reads it as part of the mail thread above it.
      expect((items[3] as RoomChatHeaderItem).chat.id, 'chat-1');
    });

    test('a run of one chat carries one heading', () {
      final chat = _thread('chat-1', source: 'teams');
      final items = roomTimeline(_room([chat]), {
        _target(chat): [
          _msg('m1', at: '2026-09-04T10:00:00Z'),
          _msg('m2', at: '2026-09-04T11:00:00Z'),
        ],
      });

      expect(items.whereType<RoomChatHeaderItem>().length, 1);
      expect(items.whereType<RoomMessageItem>().length, 2);
    });

    test('a chat whose transcript has not landed is a card, not a hole', () {
      final chat = _thread('chat-1', source: 'teams');
      final items = roomTimeline(_room([chat]), const {});

      expect(items.single, isA<RoomCardItem>());
    });

    test('a sixth chat is a card', () {
      final chats = [
        for (var i = 0; i < 6; i++)
          _thread('chat-$i', source: 'teams', at: '2026-09-0${6 - i}T10:00:00Z'),
      ];
      final loaded = {
        for (final chat in chats)
          _target(chat): [_msg('${chat.id}-m', at: chat.lastMessageAt!)],
      };

      final items = roomTimeline(_room(chats), loaded);

      // The oldest one falls past the cap and is summarised instead.
      final cards = items.whereType<RoomCardItem>().toList();
      expect(cards.map((c) => c.conversation.id), ['chat-5']);
    });

    test('an undated thread sorts to the top rather than the bottom', () {
      final undated = _thread('c-undated', at: null);
      final dated = _thread('c1', at: '2026-09-04T10:00:00Z');

      final items = roomTimeline(_room([dated, undated]), const {});

      expect((items.first as RoomCardItem).conversation.id, 'c-undated');
    });

    test('an empty room is an empty timeline', () {
      expect(roomTimeline(_room(const []), const {}), isEmpty);
    });
  });

  group('the pane', () {
    Future<void> pump(
      WidgetTester tester, {
      required PersonRoom room,
      Map<ThreadTarget, List<Message>> chats = const {},
      void Function(String, String)? onOpenThread,
      VoidCallback? onMessage,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PersonRoomPane(
            room: room,
            chats: chats,
            now: now,
            photos: const NoProfilePhotos(),
            thumbnailFor: null,
            onOpenThread: onOpenThread ?? (_, _) {},
            onOpenAttachment: (_, _) {},
            onMessage: onMessage,
          ),
        ),
      ));
      await tester.pump();
    }

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
      expect(
        find.text('Dana Whitfield · The hero paragraph.'),
        findsOneWidget,
      );
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

    testWidgets('tapping a card opens that thread', (tester) async {
      final opened = <(String, String)>[];
      await pump(
        tester,
        room: _room([_thread('c1', subject: 'Homepage copy')]),
        onOpenThread: (source, key) => opened.add((source, key)),
      );

      await tester.tap(find.byKey(RootMessageCard.keyFor('email', 'c1')));
      await tester.pump();

      expect(opened, [('email', 'c1')]);
    });

    testWidgets('chat messages are drawn as messages, under their heading',
        (tester) async {
      final chat = _thread('chat-1', source: 'teams', subject: 'Launch date');
      await pump(
        tester,
        room: _room([chat]),
        chats: {
          _target(chat): [
            _msg('m1', at: '2026-09-08T10:00:00Z', body: 'The fourteenth.'),
          ],
        },
      );

      expect(find.byType(MessageRow), findsOneWidget);
      expect(find.text('The fourteenth.'), findsOneWidget);
      expect(find.text('💬 Launch date'), findsOneWidget);
    });

    testWidgets('Open chat leads into the chat itself', (tester) async {
      final opened = <(String, String)>[];
      final chat = _thread('chat-1', source: 'teams', subject: 'Launch date');
      await pump(
        tester,
        room: _room([chat]),
        chats: {
          _target(chat): [_msg('m1', at: '2026-09-08T10:00:00Z')],
        },
        onOpenThread: (source, key) => opened.add((source, key)),
      );

      await tester.tap(find.byKey(PersonRoomPane.openChatKeyFor('chat-1')));
      await tester.pump();

      expect(opened, [('teams', 'chat-1')]);
    });

    testWidgets('the day turns over with a divider', (tester) async {
      await pump(
        tester,
        room: _room([
          _thread('c1', subject: 'Monday', at: '2026-09-07T10:00:00Z'),
          _thread('c2', subject: 'Sunday', at: '2026-09-06T10:00:00Z'),
        ]),
      );

      expect(find.byType(DayDivider), findsNWidgets(2));
    });

    testWidgets('the Message button appears only when the host offers one',
        (tester) async {
      await pump(tester, room: _room([_thread('c1', subject: 'One')]));
      expect(find.byKey(PersonRoomPane.messageButtonKey), findsNothing);

      var asked = 0;
      await pump(
        tester,
        room: _room([_thread('c1', subject: 'One')]),
        onMessage: () => asked++,
      );
      expect(find.text('Message Dana Whitfield'), findsOneWidget);

      await tester.tap(find.byKey(PersonRoomPane.messageButtonKey));
      await tester.pump();
      expect(asked, 1);
    });

    testWidgets('a room with nothing in it says so', (tester) async {
      await pump(tester, room: _room(const []));

      expect(find.byKey(PersonRoomPane.emptyKey), findsOneWidget);
      expect(find.text('No live threads with them.'), findsOneWidget);
    });
  });
}
