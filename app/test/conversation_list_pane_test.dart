import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String source = 'email',
  String subject = 'Homepage copy',
  ConversationState state = ConversationState.done,
}) {
  return Conversation(
    id: id,
    source: source,
    subject: subject,
    participants: const [
      Participant(name: 'Alex Rivera', email: 'alex.rivera@example.com'),
    ],
    state: state,
    lastMessageAt: '2026-01-14T10:00:00',
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Conversation> conversations,
    InboxFilter filter = InboxFilter.done,
    List<(String, List<Conversation>)>? sectionsOverride,
    void Function(String, String)? onReopen,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConversationListPane(
          sources: const ['email', 'teams'],
          filter: filter,
          conversations: conversations,
          selectedId: null,
          onSelect: (_, _) {},
          sectionsOverride: sectionsOverride,
          onReopen: onReopen,
        ),
      ),
    ));
  }

  group('reopen', () {
    testWidgets('a done row offers it when the host wired one', (tester) async {
      await pump(
        tester,
        conversations: [_conv(id: 'c1')],
        onReopen: (_, _) {},
      );

      expect(find.text('Reopen'), findsOneWidget);
    });

    testWidgets('the row carries its source and key', (tester) async {
      final reopened = <(String, String)>[];
      await pump(
        tester,
        conversations: [_conv(id: 'c1', source: 'teams')],
        onReopen: (source, key) => reopened.add((source, key)),
      );

      await tester.tap(find.text('Reopen'));
      await tester.pump();

      expect(reopened, [('teams', 'c1')]);
    });

    testWidgets('no callback renders the list exactly as it always did',
        (tester) async {
      await pump(tester, conversations: [_conv(id: 'c1')]);

      expect(find.text('Reopen'), findsNothing);
      expect(find.text('DONE'), findsOneWidget);
    });

    testWidgets('a live section never offers it', (tester) async {
      await pump(
        tester,
        filter: InboxFilter.waiting,
        conversations: [_conv(id: 'c1', state: ConversationState.waiting)],
        onReopen: (_, _) {},
      );

      expect(find.text('WAITING'), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });

    testWidgets("a host's own sections are its own business", (tester) async {
      final rows = [_conv(id: 'c1')];
      await pump(
        tester,
        conversations: rows,
        sectionsOverride: [('DONE', rows)],
        onReopen: (_, _) {},
      );

      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });
  });
}
