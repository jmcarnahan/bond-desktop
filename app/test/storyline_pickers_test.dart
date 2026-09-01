import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/storyline_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two panes that stand where a picker dialog would. Pure widgets, so
/// everything here is constructor in, callback out.

Conversation _conversation({
  required String id,
  required String subject,
  String source = 'email',
  List<Participant> participants = const [],
  String? lastMessageAt,
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: participants,
      lastMessageAt: lastMessageAt,
    );

void main() {
  Future<void> pump(WidgetTester tester, Widget pane) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: pane)));
  }

  group('AddThreadToStorylinePane', () {
    final candidates = [
      _conversation(
        id: 'c1',
        subject: 'Homepage copy',
        participants: const [Participant(name: 'Sarah Chen')],
        lastMessageAt: '2026-08-28T09:00:00Z',
      ),
      _conversation(
        id: 'c2',
        subject: 'Launch date',
        participants: const [Participant(name: 'Priya Natarajan')],
        lastMessageAt: '2026-08-27T09:00:00Z',
      ),
    ];

    Future<void> pumpPane(
      WidgetTester tester, {
      List<Conversation>? only,
      VoidCallback? onBack,
      void Function(Conversation)? onPick,
    }) =>
        pump(
          tester,
          AddThreadToStorylinePane(
            storylineTitle: 'Website redesign',
            candidates: only ?? candidates,
            onBack: onBack ?? () {},
            onPick: onPick ?? (_) {},
          ),
        );

    testWidgets('names the storyline and lists every candidate',
        (tester) async {
      await pumpPane(tester);

      expect(find.text('Add a thread to Website redesign'), findsOneWidget);
      expect(find.text('✉ Homepage copy'), findsOneWidget);
      expect(find.text('✉ Launch date'), findsOneWidget);
    });

    testWidgets('the filter narrows by subject', (tester) async {
      await pumpPane(tester);

      await tester.enterText(find.byType(TextField), 'launch');
      await tester.pumpAndSettle();

      expect(find.text('✉ Launch date'), findsOneWidget);
      expect(find.text('✉ Homepage copy'), findsNothing);
    });

    testWidgets('and by the people on the thread', (tester) async {
      // The user looking for a thread remembers the subject or the person,
      // and rarely which.
      await pumpPane(tester);

      await tester.enterText(find.byType(TextField), 'priya');
      await tester.pumpAndSettle();

      expect(find.text('✉ Launch date'), findsOneWidget);
      expect(find.text('✉ Homepage copy'), findsNothing);
    });

    testWidgets('tapping a row hands back that conversation', (tester) async {
      final picked = <String>[];
      await pumpPane(tester, onPick: (c) => picked.add(c.id));

      await tester.tap(find.text('✉ Launch date'));
      await tester.pumpAndSettle();

      expect(picked, ['c2']);
    });

    testWidgets('an empty candidate list says so rather than going blank',
        (tester) async {
      await pumpPane(tester, only: const []);

      expect(find.text('No threads to add.'), findsOneWidget);
    });

    testWidgets('the back arrow is the way out', (tester) async {
      var back = 0;
      await pumpPane(tester, onBack: () => back++);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(back, 1);
    });
  });

  group('AddToStorylinePane', () {
    const choices = [
      Storyline(
        id: 'sl-1',
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        status: 'active',
      ),
      Storyline(id: 'sl-2', title: 'Hiring loop', status: 'active'),
    ];

    Future<void> pumpPane(
      WidgetTester tester, {
      List<Storyline> only = choices,
      VoidCallback? onBack,
      void Function(String)? onPick,
      void Function(String)? onCreate,
    }) =>
        pump(
          tester,
          AddToStorylinePane(
            choices: only,
            onBack: onBack ?? () {},
            onPick: onPick ?? (_) {},
            onCreate: onCreate ?? (_) {},
          ),
        );

    testWidgets('lists the storylines with their summaries', (tester) async {
      await pumpPane(tester);

      expect(find.text('Add to storyline'), findsOneWidget);
      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('The studio is reviewing the homepage copy.'),
          findsOneWidget);
      expect(find.text('Hiring loop'), findsOneWidget);
    });

    testWidgets('tapping one hands back its id', (tester) async {
      final picked = <String>[];
      await pumpPane(tester, onPick: picked.add);

      await tester.tap(find.text('Hiring loop'));
      await tester.pumpAndSettle();

      expect(picked, ['sl-2']);
    });

    testWidgets('Create is dead until the field holds a name', (tester) async {
      await pumpPane(tester);

      TextButton create() =>
          tester.widget<TextButton>(find.widgetWithText(TextButton, 'Create'));
      expect(create().onPressed, isNull);

      // Whitespace is not a name.
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      expect(create().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Q4 offsite');
      await tester.pumpAndSettle();
      expect(create().onPressed, isNotNull);
    });

    testWidgets('and hands back the trimmed title', (tester) async {
      final created = <String>[];
      await pumpPane(tester, onCreate: created.add);

      await tester.enterText(find.byType(TextField), '  Q4 offsite  ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(created, ['Q4 offsite']);
    });

    testWidgets('the create row is the floor when there is nothing to pick',
        (tester) async {
      await pumpPane(tester, only: const []);

      expect(find.widgetWithText(TextButton, 'Create'), findsOneWidget);
      expect(find.text('Website redesign'), findsNothing);
    });

    testWidgets('nothing here is a dialog', (tester) async {
      await pumpPane(tester);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the back arrow is the way out', (tester) async {
      var back = 0;
      await pumpPane(tester, onBack: () => back++);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(back, 1);
    });
  });
}
