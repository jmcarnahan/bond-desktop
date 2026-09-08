import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/dismissed_storylines_fold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Storyline _storyline({
  required String id,
  String title = 'Website redesign',
  String status = 'active',
  int memberCount = 2,
  int openCount = 0,
}) {
  return Storyline(
    id: id,
    title: title,
    status: status,
    memberCount: memberCount,
    openCount: openCount,
  );
}

/// The fold on the dark ground it sits on in the rail, at the rail's width —
/// the rows truncate, and a wider host would hide a truncation bug.
Future<void> pumpFold(
  WidgetTester tester, {
  required List<Storyline> dismissed,
  void Function(String storylineId)? onRestore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Material(
          color: BondColors.ink,
          child: SizedBox(
            width: 260,
            child: DismissedStorylinesFold(
              dismissed: dismissed,
              onRestore: onRestore,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DismissedStorylinesFold', () {
    testWidgets('empty renders nothing', (tester) async {
      await pumpFold(tester, dismissed: const []);

      expect(find.textContaining('Dismissed'), findsNothing);
      expect(find.byIcon(Icons.restore), findsNothing);
    });

    testWidgets('the fold counts what is behind it and shows none of it',
        (tester) async {
      await pumpFold(
        tester,
        dismissed: [
          _storyline(id: 'sl-9', title: 'Office move', status: 'dismissed'),
        ],
      );

      expect(find.text('Dismissed · 1'), findsOneWidget);
      expect(find.text('Office move'), findsNothing);
    });

    testWidgets('opening the fold shows the rows', (tester) async {
      await pumpFold(
        tester,
        dismissed: [
          _storyline(id: 'sl-9', title: 'Office move', status: 'dismissed'),
        ],
      );

      await tester.tap(find.text('Dismissed · 1'));
      await tester.pumpAndSettle();

      expect(find.text('Office move'), findsOneWidget);
    });

    testWidgets('Restore fires for the row it sits on', (tester) async {
      final restored = <String>[];
      await pumpFold(
        tester,
        dismissed: [
          _storyline(id: 'sl-9', title: 'Office move', status: 'dismissed'),
        ],
        onRestore: restored.add,
      );

      await tester.tap(find.text('Dismissed · 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Restore'));

      expect(restored, ['sl-9']);
    });
  });
}
