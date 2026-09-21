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
      void Function(String title, String charter)? onCreateWithCharter,
    }) =>
        pump(
          tester,
          AddToStorylinePane(
            choices: only,
            onBack: onBack ?? () {},
            onPick: onPick ?? (_) {},
            onCreate: onCreate ?? (_) {},
            onCreateWithCharter: onCreateWithCharter,
          ),
        );

    /// Whether the Create button is live. By key rather than by label now that
    /// the pane holds two fields and the button sits beside the first.
    bool createEnabled(WidgetTester tester) =>
        tester
            .widget<TextButton>(find.byKey(AddToStorylinePane.createKey))
            .onPressed !=
        null;

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
      expect(createEnabled(tester), isFalse);

      // Whitespace is not a name.
      await tester.enterText(find.byKey(AddToStorylinePane.titleKey), '   ');
      await tester.pumpAndSettle();
      expect(createEnabled(tester), isFalse);

      await tester.enterText(
          find.byKey(AddToStorylinePane.titleKey), 'Q4 offsite');
      await tester.pumpAndSettle();
      expect(createEnabled(tester), isTrue);
    });

    testWidgets('and hands back the trimmed title', (tester) async {
      final created = <String>[];
      await pumpPane(tester, onCreate: created.add);

      await tester.enterText(
          find.byKey(AddToStorylinePane.titleKey), '  Q4 offsite  ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AddToStorylinePane.createKey));
      await tester.pumpAndSettle();

      expect(created, ['Q4 offsite']);
    });

    testWidgets('the three keys are on the two fields and the button',
        (tester) async {
      await pumpPane(tester);

      expect(find.byKey(AddToStorylinePane.titleKey), findsOneWidget);
      expect(find.byKey(AddToStorylinePane.charterKey), findsOneWidget);
      expect(find.byKey(AddToStorylinePane.createKey), findsOneWidget);
      expect(find.text('What belongs here'), findsOneWidget);
    });

    testWidgets('a charter alone is not enough to create', (tester) async {
      // The storyline would have no name to show in the rail. The charter is
      // the optional half here, not the required one.
      await pumpPane(tester, onCreateWithCharter: (_, _) {});

      await tester.enterText(find.byKey(AddToStorylinePane.charterKey),
          'Everything about the offsite.');
      await tester.pumpAndSettle();

      expect(createEnabled(tester), isFalse);
    });

    testWidgets('a name with a charter takes the charter door',
        (tester) async {
      final created = <String>[];
      final withCharter = <({String title, String charter})>[];
      await pumpPane(
        tester,
        onCreate: created.add,
        onCreateWithCharter: (title, charter) =>
            withCharter.add((title: title, charter: charter)),
      );

      await tester.enterText(
          find.byKey(AddToStorylinePane.titleKey), 'Q4 offsite');
      await tester.enterText(find.byKey(AddToStorylinePane.charterKey),
          '  The venue, the agenda and the travel.  ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AddToStorylinePane.createKey));
      await tester.pumpAndSettle();

      expect(created, isEmpty);
      expect(withCharter.single.title, 'Q4 offsite');
      expect(withCharter.single.charter,
          'The venue, the agenda and the travel.');
    });

    testWidgets('a host with no charter door gets a dead charter field',
        (tester) async {
      // Rather than a live field whose text Create would silently drop. The
      // pane still creates; it just cannot pretend to take a charter nothing
      // downstream would save.
      final created = <String>[];
      await pumpPane(tester, onCreate: created.add);

      final field = tester
          .widget<TextField>(find.byKey(AddToStorylinePane.charterKey));
      expect(field.enabled, isFalse);

      await tester.enterText(
          find.byKey(AddToStorylinePane.titleKey), 'Q4 offsite');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AddToStorylinePane.createKey));
      await tester.pumpAndSettle();

      expect(created, ['Q4 offsite']);
    });

    testWidgets('and with one the charter field is live', (tester) async {
      await pumpPane(tester, onCreateWithCharter: (_, _) {});

      expect(
        tester
            .widget<TextField>(find.byKey(AddToStorylinePane.charterKey))
            .enabled,
        isTrue,
      );
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

  group('NewStorylinePane', () {
    /// The pane that declares a storyline out of nothing. It differs from
    /// [AddToStorylinePane] on exactly one rule, and the rule is the point: a
    /// declared storyline with no charter has nothing for the recruit to hunt
    /// with, so it would be an empty list that stays empty.
    Future<void> pumpPane(
      WidgetTester tester, {
      VoidCallback? onBack,
      void Function(String title, String charter)? onCreate,
    }) =>
        pump(
          tester,
          NewStorylinePane(
            onBack: onBack ?? () {},
            onCreate: onCreate ?? (_, _) {},
          ),
        );

    bool createEnabled(WidgetTester tester) =>
        tester
            .widget<TextButton>(find.byKey(NewStorylinePane.createKey))
            .onPressed !=
        null;

    testWidgets('carries its four keys and names both fields', (tester) async {
      await pumpPane(tester);

      expect(find.byKey(NewStorylinePane.titleKey), findsOneWidget);
      expect(find.byKey(NewStorylinePane.charterKey), findsOneWidget);
      expect(find.byKey(NewStorylinePane.createKey), findsOneWidget);
      expect(find.byKey(NewStorylinePane.paneKey), findsOneWidget);
      expect(find.text('New storyline'), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('What belongs here'), findsOneWidget);
    });

    testWidgets('Create wants both fields, not just the title',
        (tester) async {
      await pumpPane(tester);
      expect(createEnabled(tester), isFalse);

      await tester.enterText(
          find.byKey(NewStorylinePane.titleKey), 'Q4 offsite');
      await tester.pumpAndSettle();
      expect(createEnabled(tester), isFalse);

      await tester.enterText(find.byKey(NewStorylinePane.charterKey),
          'The venue, the agenda and the travel.');
      await tester.pumpAndSettle();
      expect(createEnabled(tester), isTrue);
    });

    testWidgets('and whitespace in either one is not a field', (tester) async {
      await pumpPane(tester);

      await tester.enterText(
          find.byKey(NewStorylinePane.titleKey), 'Q4 offsite');
      await tester.enterText(find.byKey(NewStorylinePane.charterKey), '   ');
      await tester.pumpAndSettle();

      expect(createEnabled(tester), isFalse);
    });

    testWidgets('it hands back the trimmed pair', (tester) async {
      final created = <({String title, String charter})>[];
      await pumpPane(
        tester,
        onCreate: (title, charter) =>
            created.add((title: title, charter: charter)),
      );

      await tester.enterText(
          find.byKey(NewStorylinePane.titleKey), '  Q4 offsite ');
      await tester.enterText(find.byKey(NewStorylinePane.charterKey),
          ' The venue, the agenda and the travel. ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NewStorylinePane.createKey));
      await tester.pumpAndSettle();

      expect(created.single.title, 'Q4 offsite');
      expect(created.single.charter, 'The venue, the agenda and the travel.');
    });

    testWidgets('nothing here is a dialog either', (tester) async {
      await pumpPane(tester);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the back arrow is the way out', (tester) async {
      var back = 0;
      await pumpPane(tester, onBack: () => back++);

      await tester.tap(find.descendant(
        of: find.byKey(NewStorylinePane.paneKey),
        matching: find.byTooltip('Back'),
      ));
      await tester.pumpAndSettle();

      expect(back, 1);
    });
  });
}
