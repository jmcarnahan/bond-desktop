import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/archive_pane.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/later_digest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String source = 'email',
  String? who = 'Alex Rivera',
  String? email = 'alex.rivera@example.com',
  String? subject,
  String? bucket,
  ConversationState state = ConversationState.waiting,
  String lastMessageAt = '2026-01-14T10:00:00',
}) {
  return Conversation(
    id: id,
    source: source,
    subject: subject ?? 'Homepage copy',
    participants:
        who == null ? const [] : [Participant(name: who, email: email)],
    state: state,
    bucket: bucket,
    lastMessageAt: lastMessageAt,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Conversation> conversations,
    ArchiveTab tab = ArchiveTab.later,
    String? dayFilter,
    void Function(ArchiveTab)? onTab,
    void Function(String, String)? onOpen,
    void Function(String, String)? onReopen,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArchivePane(
          conversations: conversations,
          sources: const ['email', 'teams'],
          tab: tab,
          onTab: onTab ?? (_) {},
          dayFilter: dayFilter,
          onOpen: onOpen ?? (_, _) {},
          onKeepSender: (_, _) {},
          onKeepThread: (_, _) {},
          onReopen: onReopen ?? (_, _) {},
        ),
      ),
    ));
  }

  testWidgets('the three piles are offered as pills', (tester) async {
    await pump(tester, conversations: [_conv(id: 'a', bucket: 'later')]);

    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Dropped'), findsOneWidget);
  });

  testWidgets('picking a pill asks the host to change tab', (tester) async {
    final picked = <ArchiveTab>[];
    await pump(
      tester,
      conversations: [_conv(id: 'a', bucket: 'later')],
      onTab: picked.add,
    );

    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(picked, [ArchiveTab.done]);
  });

  testWidgets('the later tab shows what was deferred', (tester) async {
    await pump(
      tester,
      conversations: [_conv(id: 'a', bucket: 'later', subject: 'Launch date')],
    );

    expect(find.byType(LaterDigestPanel), findsOneWidget);
    expect(find.text('Launch date'), findsOneWidget);
  });

  testWidgets('the done tab shows what was closed', (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.done,
      conversations: [
        _conv(id: 'a', subject: 'Launch date', state: ConversationState.done),
      ],
    );

    expect(find.byType(ConversationListPane), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.textContaining('Launch date'), findsOneWidget);
  });

  testWidgets(
      'a thread that was deferred and then closed is under Done only — '
      'the piles never answer the same question twice', (tester) async {
    final both = [
      _conv(
        id: 'a',
        subject: 'Launch date',
        bucket: 'later',
        state: ConversationState.done,
      ),
    ];

    await pump(tester, tab: ArchiveTab.done, conversations: both);
    expect(find.textContaining('Launch date'), findsOneWidget);

    await pump(tester, conversations: both);
    expect(find.text('Launch date'), findsNothing);
    expect(find.text('Nothing deferred.'), findsOneWidget);
  });

  testWidgets('reopening a done thread carries its source and key',
      (tester) async {
    final reopened = <(String, String)>[];
    await pump(
      tester,
      tab: ArchiveTab.done,
      conversations: [
        _conv(id: 'c1', source: 'teams', state: ConversationState.done),
      ],
      onReopen: (source, key) => reopened.add((source, key)),
    );

    await tester.tap(find.text('Reopen'));
    await tester.pump();

    expect(reopened, [('teams', 'c1')]);
  });

  testWidgets('the dropped tab says the pile is not here yet', (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: [_conv(id: 'a', bucket: 'later')],
    );

    expect(
      find.text('Dropped messages arrive here later this round.'),
      findsOneWidget,
    );
    expect(find.byType(LaterDigestPanel), findsNothing);
    expect(find.byType(ConversationListPane), findsNothing);
  });

  testWidgets('a day filter narrows the later tab and nothing else',
      (tester) async {
    await pump(
      tester,
      dayFilter: '2026-01-14',
      conversations: [
        _conv(
          id: 'a',
          subject: 'Launch date',
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
        _conv(
          id: 'b',
          subject: 'Homepage copy',
          bucket: 'later',
          lastMessageAt: '2026-01-11T10:00:00',
        ),
      ],
    );

    expect(find.text('Launch date'), findsOneWidget);
    expect(find.text('Homepage copy'), findsNothing);
  });
}
