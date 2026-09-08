import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/storyline_blocks_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The section on its own, at about the width the About block gives it.
Future<void> pumpSection(
  WidgetTester tester, {
  List<StorylineBlock> blocks = const [],
  void Function(String source, String conversationKey)? onUnblockThread,
  void Function(String source, String conversationKey)? onAddBackThread,
  VoidCallback? onAudit,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: StorylineBlocksSection(
            blocks: blocks,
            onUnblockThread: onUnblockThread,
            onAddBackThread: onAddBackThread,
            onAudit: onAudit,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('StorylineBlocksSection', () {
    final userBlock = StorylineBlock(
      storylineId: 'sl-1',
      conversationKey: 'c9',
      blockedBy: 'user',
      evidence: 'Both concern the website redesign.',
      subject: 'Office move',
      blockedAt: '2026-09-02T10:00:00Z',
    );
    final auditBlock = StorylineBlock(
      storylineId: 'sl-1',
      source: 'teams',
      conversationKey: 'c8',
      blockedBy: 'audit',
      evidence: 'The charter is about the homepage, this is hiring.',
      subject: 'Interview loop',
      blockedAt: '2026-09-01T10:00:00Z',
    );

    testWidgets('a heading with nothing under it is absent, the button is not',
        (tester) async {
      await pumpSection(tester);

      expect(find.text('REMOVED BY YOU'), findsNothing);
      expect(find.text('REMOVED BY RE-CHECK'), findsNothing);
      // The re-check is offered whether or not anything has been removed —
      // it judges the members, not the blocks.
      expect(find.text('Re-check members'), findsOneWidget);
    });

    testWidgets('a block whose thread is gone still says what it was',
        (tester) async {
      await pumpSection(
        tester,
        blocks: [
          StorylineBlock(
            storylineId: 'sl-1',
            conversationKey: 'c7',
            blockedBy: 'user',
            blockedAt: '2026-09-02T10:00:00Z',
          ),
        ],
      );

      expect(find.text('(thread no longer stored)'), findsOneWidget);
      expect(find.text('No reason recorded.'), findsOneWidget);
    });

    testWidgets('Allow again and Add back carry the block\'s source and key',
        (tester) async {
      final allowed = <(String, String)>[];
      final added = <(String, String)>[];
      await pumpSection(
        tester,
        // The audit block is the chat one, so a source dropped on the way
        // through would send the call to the wrong connector's thread.
        blocks: [auditBlock],
        onUnblockThread: (source, key) => allowed.add((source, key)),
        onAddBackThread: (source, key) => added.add((source, key)),
      );

      await tester.tap(find.text('Allow again'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add back'));
      await tester.pumpAndSettle();

      expect(allowed, [('teams', 'c8')]);
      expect(added, [('teams', 'c8')]);
    });

    testWidgets('the owner\'s own removals get both buttons too',
        (tester) async {
      final allowed = <(String, String)>[];
      await pumpSection(
        tester,
        blocks: [userBlock],
        onUnblockThread: (source, key) => allowed.add((source, key)),
      );

      expect(find.text('Add back'), findsOneWidget);
      await tester.tap(find.text('Allow again'));
      await tester.pumpAndSettle();

      expect(allowed, [('email', 'c9')]);
    });

    testWidgets('Re-check members asks for the audit', (tester) async {
      var audits = 0;
      await pumpSection(tester, onAudit: () => audits++);

      await tester.tap(find.text('Re-check members'));
      await tester.pumpAndSettle();

      expect(audits, 1);
    });
  });
}
