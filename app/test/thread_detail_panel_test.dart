import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The open-ask banner and the per-message ask lines under it. The overflow
/// menu is covered in `thread_detail_menu_test.dart`.
Message _msg({
  required String id,
  bool outbound = false,
  required String receivedAt,
  bool? needsAction,
  bool? replyExpected,
  List<String> actionItems = const [],
}) {
  return Message(
    id: id,
    outbound: outbound,
    fromName: outbound ? null : 'Dana Ruiz',
    fromAddress: outbound ? 'me@example.com' : 'dana@example.com',
    receivedAt: receivedAt,
    bodyText: 'Body of $id.',
    triageStatus: 'done',
    needsAction: needsAction,
    replyExpected: replyExpected,
    actionItems: actionItems,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Message> messages,
    String? ctaText = 'Reply to Dana',
    ConversationState state = ConversationState.needsReply,
    VoidCallback? onOpenReply,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadDetailPanel(
          conversation: Conversation(
            id: 'c1',
            subject: 'Launch date',
            state: state,
            ctaText: ctaText,
          ),
          messages: messages,
          onMarkDone: () {},
          onOpenReply: onOpenReply,
        ),
      ),
    ));
  }

  testWidgets('more than one open ask is counted in the banner', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(
        id: 'b',
        receivedAt: '2026-08-25T11:00:00',
        replyExpected: true,
        actionItems: const ['Confirm the date'],
      ),
    ]);

    expect(find.text('Reply to Dana · 2 open asks'), findsOneWidget);
  });

  testWidgets('a single open ask leaves the banner as the bare CTA',
      (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
    ]);

    expect(find.text('Reply to Dana'), findsOneWidget);
    expect(find.textContaining('open asks'), findsNothing);
  });

  testWidgets('one reply answers every ask before it', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(
        id: 'b',
        receivedAt: '2026-08-25T11:00:00',
        replyExpected: true,
        actionItems: const ['Confirm the date'],
      ),
      _msg(id: 'c', outbound: true, receivedAt: '2026-08-25T12:00:00'),
    ]);

    expect(find.text('Reply to Dana'), findsOneWidget);
    expect(find.textContaining('open asks'), findsNothing);
    expect(find.text('Send the deck'), findsNothing);
    expect(find.text('Confirm the date'), findsNothing);
  });

  group('an ask is a call to action', () {
    testWidgets('the banner opens the reply', (tester) async {
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            needsAction: true,
            actionItems: const ['Send the deck'],
          ),
        ],
      );

      await tester.tap(find.text('Reply to Dana'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets("and so does a message's own ask line", (tester) async {
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            needsAction: true,
            actionItems: const ['Send the deck'],
          ),
        ],
      );

      await tester.tap(find.text('Send the deck'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('a pane with no reply to open leaves both as statements',
        (tester) async {
      await pump(tester, messages: [
        _msg(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
      ]);

      // Still said, still not clickable.
      expect(find.text('Reply to Dana'), findsOneWidget);
      expect(find.text('Send the deck'), findsOneWidget);
      for (final ask in ['Reply to Dana', 'Send the deck']) {
        expect(
          find.ancestor(of: find.text(ask), matching: find.byType(InkWell)),
          findsNothing,
        );
      }
    });
  });

  testWidgets('a waiting thread carries no banner and no ask line',
      (tester) async {
    // The send that flips the thread to waiting clears the CTA in the same
    // fold. The ask lines have to go with it, or they sit lit under a banner
    // that is already gone until the sent message syncs back.
    await pump(
      tester,
      state: ConversationState.waiting,
      messages: [
        _msg(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
      ],
    );

    expect(find.text('Reply to Dana'), findsNothing);
    expect(find.text('Send the deck'), findsNothing);
  });

  testWidgets('only the unanswered message carries an ask line', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(id: 'b', outbound: true, receivedAt: '2026-08-25T10:00:00'),
      _msg(
        id: 'c',
        receivedAt: '2026-08-25T11:00:00',
        needsAction: true,
        actionItems: const ['Confirm the date'],
      ),
    ]);

    expect(find.text('Confirm the date'), findsOneWidget);
    expect(find.text('Send the deck'), findsNothing);
  });
}
