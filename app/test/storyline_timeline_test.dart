import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String receivedAt,
  String from = 'Sarah Chen',
  String address = 'sarah@example.com',
  String? body,
}) =>
    Message(
      id: id,
      outbound: false,
      fromName: from,
      fromAddress: address,
      receivedAt: receivedAt,
      bodyText: body ?? 'body of $id',
    );

const _storyline = Storyline(
  id: 'sl-1',
  title: 'Willow St purchase',
  summary: 'Underwriting is reviewing the appraisal.',
  status: 'active',
  memberCount: 2,
);

void main() {
  // Two threads interleaved in time: c1 opens, c2 answers, c1 closes. Every
  // message is from the same sender within the run window, so any seam the
  // view draws is the thread changing and nothing else.
  final messages = [
    _message(id: 'm1', receivedAt: '2026-08-01T09:00:00Z'),
    _message(id: 'm2', receivedAt: '2026-08-01T09:01:00Z'),
    _message(id: 'm3', receivedAt: '2026-08-01T09:02:00Z'),
  ];
  const keyByMessageId = {'m1': 'c1', 'm2': 'c2', 'm3': 'c1'};
  const subjectByKey = {'c1': 'Appraisal review', 'c2': 'Rate lock'};
  const members = [
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c1',
      addedBy: 'auto',
      evidence: 'Both concern the Willow Street appraisal.',
    ),
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c2',
      addedBy: 'user',
    ),
  ];

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<Message>? only,
    void Function(String title)? onRename,
    void Function(String source, String key)? onRemoveThread,
    void Function(String source, String key)? onOpenThread,
    VoidCallback? onBack,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StorylineTimelinePanel(
          storyline: _storyline,
          messages: only ?? messages,
          keyByMessageId: keyByMessageId,
          subjectByKey: subjectByKey,
          members: members,
          onBack: onBack,
          onRename: onRename ?? (_) {},
          onRemoveThread: onRemoveThread ?? (_, _) {},
          onOpenThread: onOpenThread ?? (_, _) {},
        ),
      ),
    ));
  }

  group('header', () {
    testWidgets('shows the title, the summary and the thread count',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('Willow St purchase'), findsOneWidget);
      expect(find.text('Underwriting is reviewing the appraisal.'),
          findsOneWidget);
      expect(find.text('2 threads'), findsOneWidget);
    });

    testWidgets('the back arrow is absent when there is nowhere to go back to',
        (tester) async {
      await pumpPanel(tester);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      await pumpPanel(tester, onBack: () {});
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });
  });

  group('transcript', () {
    testWidgets('renders every message in merged order', (tester) async {
      await pumpPanel(tester);

      expect(find.byType(MessageRow), findsNWidgets(3));
      expect(find.text('body of m1'), findsOneWidget);
      expect(find.text('body of m2'), findsOneWidget);
      expect(find.text('body of m3'), findsOneWidget);
    });

    testWidgets('a seam chip appears each time the thread changes',
        (tester) async {
      await pumpPanel(tester);

      // c1 opens, c2 interrupts, c1 resumes: three seams, and the middle
      // thread is named once.
      expect(find.text('✉ Appraisal review'), findsNWidgets(2));
      expect(find.text('✉ Rate lock'), findsOneWidget);
    });

    testWidgets('a seam always breaks the run, however close in time',
        (tester) async {
      await pumpPanel(tester);

      // Same sender, a minute apart — the thread panel would collapse all
      // three under one header. Here each one opens its own.
      final rows = tester
          .widgetList<MessageRow>(find.byType(MessageRow))
          .map((r) => r.showHeader)
          .toList();
      expect(rows, [true, true, true]);
    });

    testWidgets('tapping a seam chip opens that thread', (tester) async {
      final opened = <String>[];
      await pumpPanel(tester, onOpenThread: (_, key) => opened.add(key));

      await tester.tap(find.text('✉ Rate lock'));

      expect(opened, ['c2']);
    });

    testWidgets('an empty storyline says so rather than going blank',
        (tester) async {
      await pumpPanel(tester, only: const []);

      expect(find.text('No messages in this storyline.'), findsOneWidget);
    });
  });

  group('member strip', () {
    testWidgets('is collapsed until the thread count is tapped',
        (tester) async {
      await pumpPanel(tester);
      expect(find.byType(Checkbox), findsNothing);

      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNWidgets(2));
    });

    testWidgets('un-ticking a thread filters it out of the transcript',
        (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      // The second entry is c2 — the one message from the Rate lock thread.
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();

      expect(find.byType(MessageRow), findsNWidgets(2));
      expect(find.text('body of m2'), findsNothing);
      // With c2 hidden, c1's two messages are no longer interrupted, so the
      // seam count drops with them.
      expect(find.text('✉ Rate lock'), findsNothing);
      expect(find.text('✉ Appraisal review'), findsOneWidget);
    });

    testWidgets('the close icon removes the thread from the storyline',
        (tester) async {
      final removed = <String>[];
      await pumpPanel(tester, onRemoveThread: (_, key) => removed.add(key));
      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close).first);

      // Hiding is a view filter; removing is a correction. They are different
      // controls on purpose.
      expect(removed, ['c1']);
    });
  });

  group('rename', () {
    testWidgets('tapping the title opens a field that commits on submit',
        (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Willow St purchase'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Chen refinance');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, ['Chen refinance']);
    });

    testWidgets('an empty rename is a cancel', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Willow St purchase'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
      expect(find.text('Willow St purchase'), findsOneWidget);
    });

    testWidgets('submitting the same title writes nothing', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Willow St purchase'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
    });
  });

  group('why these threads', () {
    testWidgets('lists the model evidence and the threads the user added',
        (tester) async {
      await pumpPanel(tester);

      await tester.tap(find.text('Why these threads?'));
      await tester.pumpAndSettle();

      expect(find.text('Both concern the Willow Street appraisal.'),
          findsOneWidget);
      // A thread a person filed has no model reasoning to show, and inventing
      // one would be worse than saying who did it.
      expect(find.text('You added this.'), findsOneWidget);
      expect(find.text('Appraisal review'), findsOneWidget);
      expect(find.text('Rate lock'), findsOneWidget);
    });
  });
}
