import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/link_unfurl.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/room_header.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// A thread's second half: everything it carried, on one tab.
///
/// The rule this file pins is that the list is DERIVED from the transcript
/// rather than queried — `loadThread` already loaded the whole thread — so the
/// count on the tab and the cards under it are the same answer and can never
/// drift apart.

Message _msg({
  required String id,
  required String receivedAt,
  List<AttachmentRef> attachments = const [],
}) =>
    Message(
      id: id,
      outbound: false,
      fromName: 'Dana Ruiz',
      fromAddress: 'dana@example.com',
      receivedAt: receivedAt,
      bodyText: 'Body of $id.',
      triageStatus: 'done',
      attachments: attachments,
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Message> messages,
    void Function(AttachmentRef)? onOpenAttachment,
    void Function(AttachmentRef)? onUseInReply,
    void Function(String url)? onOpenLink,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadDetailPanel(
          conversation: const Conversation(
            id: 'c1',
            subject: 'Launch date',
            state: ConversationState.waiting,
          ),
          messages: messages,
          onMarkDone: () {},
          onOpenAttachment: onOpenAttachment,
          onUseInReply: onUseInReply,
          onOpenLink: onOpenLink,
        ),
      ),
    ));
    await tester.pump();
  }

  group('threadFiles', () {
    test('newest message first, and the connector order inside one', () {
      final older = _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        attachments: [ref(messageId: 'a', attachmentId: 'old')],
      );
      final newer = _msg(
        id: 'b',
        receivedAt: '2026-08-26T09:00:00',
        attachments: [
          ref(messageId: 'b', attachmentId: 'second', ordinal: 1),
          ref(messageId: 'b', attachmentId: 'first'),
        ],
      );

      // Messages arrive oldest-first from the store, so the walk is reversed.
      expect(
        threadFiles([older, newer]).map((a) => a.attachmentId).toList(),
        ['first', 'second', 'old'],
      );
    });

    test('an inline logo is not a file anybody sent', () {
      final message = _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        attachments: [
          imageRef(messageId: 'a', attachmentId: 'logo'),
          ref(messageId: 'a', attachmentId: 'terms'),
        ],
      );

      expect(
        threadFiles([message]).map((a) => a.attachmentId).toList(),
        ['terms'],
      );
    });

    test('a thread with nothing on it has nothing to list', () {
      expect(threadFiles([_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')]),
          isEmpty);
    });
  });

  group('the Files tab', () {
    List<Message> withTwoFiles() => [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            attachments: [ref(messageId: 'a', name: 'Terms.pdf')],
          ),
          _msg(
            id: 'b',
            receivedAt: '2026-08-26T09:00:00',
            attachments: [
              ref(
                messageId: 'b',
                attachmentId: 'a2',
                name: 'Schedule.xlsx',
                contentType: null,
              ),
            ],
          ),
        ];

    testWidgets('a thread with files wears a tab that counts them',
        (tester) async {
      await pump(tester, messages: withTwoFiles());

      expect(
        find.byKey(RoomHeader.tabKey(ThreadTab.files)),
        findsOneWidget,
      );
      expect(find.text('Files (2)'), findsOneWidget);
    });

    testWidgets('a thread with no files draws no tab row at all',
        (tester) async {
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
      ]);

      // One tab is a label pretending to be a choice, so the header draws
      // none — a fileless thread looks exactly as it always did.
      expect(find.byKey(RoomHeader.tabKey(ThreadTab.files)), findsNothing);
      expect(find.byKey(RoomHeader.tabKey(ThreadTab.messages)), findsNothing);
    });

    testWidgets('the tab lists the files and puts the transcript away',
        (tester) async {
      await pump(tester, messages: withTwoFiles());

      expect(find.text('Body of a.'), findsOneWidget);

      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();

      expect(find.byType(AttachmentCard), findsNWidgets(2));
      expect(find.text('Terms.pdf'), findsOneWidget);
      expect(find.text('Schedule.xlsx'), findsOneWidget);
      expect(find.byType(MessageRow), findsNothing);
    });

    testWidgets('a link on the thread is an unfurl here too', (tester) async {
      final link = ref(
        messageId: 'a',
        kind: 'reference',
        name: 'Budget.xlsx',
        contentType: null,
        sourceUrl: 'https://contoso.sharepoint.com/Budget.xlsx',
      );
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: '2026-08-25T09:00:00', attachments: [link]),
      ]);

      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();

      expect(find.byKey(LinkUnfurl.keyFor(link)), findsOneWidget);
      expect(find.byType(AttachmentCard), findsNothing);
    });

    testWidgets('a card on the tab opens the file it stands for',
        (tester) async {
      final opened = <String>[];
      await pump(
        tester,
        messages: withTwoFiles(),
        onOpenAttachment: (a) => opened.add(a.attachmentId),
      );

      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();
      await tester.tap(find.text('Terms.pdf'));
      await tester.pump();

      expect(opened, ['a1']);
    });

    testWidgets('Use in reply reaches the host with the file it was on',
        (tester) async {
      final used = <String>[];
      await pump(
        tester,
        messages: withTwoFiles(),
        onUseInReply: (a) => used.add(a.attachmentId),
      );

      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();

      final card = tester.widget<AttachmentCard>(
        find.byKey(AttachmentCard.keyFor(
          ref(messageId: 'a', name: 'Terms.pdf'),
        )),
      );
      card.onUseInReply!();

      expect(used, ['a1']);
    });

    testWidgets('files that go away take the tab with them, and the reader '
        'lands back on the transcript', (tester) async {
      await pump(tester, messages: withTwoFiles());
      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();
      expect(find.text('Body of a.'), findsNothing);

      // The same panel, re-read without its files: no tab row is drawn, so
      // a pane still showing "No files" would have no pill to leave by.
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
        _msg(id: 'b', receivedAt: '2026-08-26T09:00:00'),
      ]);

      expect(find.byKey(RoomHeader.tabKey(ThreadTab.files)), findsNothing);
      expect(find.text('No files on this thread.'), findsNothing);
      expect(find.text('Body of a.'), findsOneWidget);
    });

    testWidgets('going back to Messages brings the transcript back',
        (tester) async {
      await pump(tester, messages: withTwoFiles());

      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.files)));
      await tester.pump();
      await tester.tap(find.byKey(RoomHeader.tabKey(ThreadTab.messages)));
      await tester.pump();

      expect(find.text('Body of a.'), findsOneWidget);
    });
  });
}
