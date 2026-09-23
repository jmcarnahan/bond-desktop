import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart'
    show NameStorylineTask;
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/possible_storylines_fold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Storyline _storyline({
  required String id,
  String title = 'Roof work',
  String status = 'possible',
  int memberCount = 3,
}) {
  return Storyline(
    id: id,
    title: title,
    status: status,
    memberCount: memberCount,
  );
}

/// The fold on the dark ground it sits on in the rail, at the rail's width —
/// the rows truncate, and a wider host would hide a truncation bug.
Future<void> pumpFold(
  WidgetTester tester, {
  required List<Storyline> possible,
  void Function(String storylineId)? onKeep,
  void Function(String storylineId)? onDismiss,
  void Function(String storylineId)? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Material(
          color: BondColors.ink,
          child: SizedBox(
            width: 260,
            child: PossibleStorylinesFold(
              possible: possible,
              onKeep: onKeep,
              onDismiss: onDismiss,
              onOpen: onOpen,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PossibleStorylinesFold', () {
    testWidgets('empty renders nothing', (tester) async {
      await pumpFold(tester, possible: const []);

      expect(find.textContaining('Possible'), findsNothing);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('the fold counts what is behind it and shows none of it',
        (tester) async {
      await pumpFold(tester, possible: [_storyline(id: 'sl-7')]);

      expect(find.text('Possible · 1'), findsOneWidget);
      expect(find.text('Roof work'), findsNothing);
    });

    testWidgets('opening the fold shows the rows and their two answers',
        (tester) async {
      await pumpFold(tester, possible: [
        _storyline(id: 'sl-7'),
        _storyline(id: 'sl-8', title: 'Friday dinners'),
      ]);

      await tester.tap(find.byKey(PossibleStorylinesFold.headerKey));
      await tester.pumpAndSettle();

      expect(find.text('Roof work'), findsOneWidget);
      expect(find.text('Friday dinners'), findsOneWidget);
      expect(find.byKey(PossibleStorylinesFold.keepKey('sl-7')), findsOneWidget);
      expect(
        find.byKey(PossibleStorylinesFold.dismissKey('sl-8')),
        findsOneWidget,
      );
    });

    testWidgets('Keep and Dismiss fire for the row they sit on',
        (tester) async {
      final kept = <String>[];
      final let = <String>[];
      await pumpFold(
        tester,
        possible: [
          _storyline(id: 'sl-7'),
          _storyline(id: 'sl-8', title: 'Friday dinners'),
        ],
        onKeep: kept.add,
        onDismiss: let.add,
      );

      await tester.tap(find.byKey(PossibleStorylinesFold.headerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PossibleStorylinesFold.keepKey('sl-7')));
      await tester.tap(find.byKey(PossibleStorylinesFold.dismissKey('sl-8')));

      expect(kept, ['sl-7']);
      expect(let, ['sl-8']);
    });

    testWidgets('the title opens the storyline, so the threads can be read '
        'before either answer', (tester) async {
      final opened = <String>[];
      await pumpFold(
        tester,
        possible: [_storyline(id: 'sl-7')],
        onOpen: opened.add,
      );

      await tester.tap(find.byKey(PossibleStorylinesFold.headerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Roof work'));

      expect(opened, ['sl-7']);
    });

    testWidgets('a row with no title still renders', (tester) async {
      await pumpFold(tester, possible: [_storyline(id: 'sl-7', title: '')]);

      await tester.tap(find.byKey(PossibleStorylinesFold.headerKey));
      await tester.pumpAndSettle();

      // The namer's own fallback, which is the one word the whole tree uses
      // for a storyline with no name.
      expect(find.text(NameStorylineTask.fallbackTitle), findsOneWidget);
    });
  });
}
