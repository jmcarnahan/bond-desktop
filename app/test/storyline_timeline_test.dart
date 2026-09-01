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
  title: 'Website redesign',
  summary: 'The studio is reviewing the homepage copy.',
  status: 'active',
  memberCount: 2,
);

/// The same storyline once someone has written down what belongs in it.
const _chartered = Storyline(
  id: 'sl-1',
  title: 'Website redesign',
  summary: 'The studio is reviewing the homepage copy.',
  status: 'active',
  charter: 'Threads about the new homepage and its launch.',
  charterLocked: true,
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
  const subjectByKey = {'c1': 'Homepage copy', 'c2': 'Launch date'};
  const members = [
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c1',
      addedBy: 'auto',
      evidence: 'Both concern the website redesign.',
    ),
    StorylineMember(
      storylineId: 'sl-1',
      conversationKey: 'c2',
      addedBy: 'user',
    ),
  ];

  Future<void> pumpPanel(
    WidgetTester tester, {
    Storyline storyline = _storyline,
    List<Message>? only,
    void Function(String title)? onRename,
    void Function(String charter)? onSetCharter,
    void Function(String source, String key)? onRemoveThread,
    void Function(String source, String key)? onOpenThread,
    VoidCallback? onBack,
    VoidCallback? onAddThread,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StorylineTimelinePanel(
          storyline: storyline,
          messages: only ?? messages,
          keyByMessageId: keyByMessageId,
          subjectByKey: subjectByKey,
          members: members,
          onBack: onBack,
          onRename: onRename ?? (_) {},
          onSetCharter: onSetCharter ?? (_) {},
          onRemoveThread: onRemoveThread ?? (_, _) {},
          onOpenThread: onOpenThread ?? (_, _) {},
          onAddThread: onAddThread ?? () {},
        ),
      ),
    ));
  }

  group('header', () {
    testWidgets('shows the title, the summary and the thread count',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('The studio is reviewing the homepage copy.'),
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
      expect(find.text('✉ Homepage copy'), findsNWidgets(2));
      expect(find.text('✉ Launch date'), findsOneWidget);
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

      await tester.tap(find.text('✉ Launch date'));

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

      // The second entry is c2 — the one message from the Launch date thread.
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();

      expect(find.byType(MessageRow), findsNWidgets(2));
      expect(find.text('body of m2'), findsNothing);
      // With c2 hidden, c1's two messages are no longer interrupted, so the
      // seam count drops with them.
      expect(find.text('✉ Launch date'), findsNothing);
      expect(find.text('✉ Homepage copy'), findsOneWidget);
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

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Brightsea launch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, ['Brightsea launch']);
    });

    testWidgets('an empty rename is a cancel', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
      expect(find.text('Website redesign'), findsOneWidget);
    });

    testWidgets('submitting the same title writes nothing', (tester) async {
      final renamed = <String>[];
      await pumpPanel(tester, onRename: renamed.add);

      await tester.tap(find.text('Website redesign'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
    });
  });

  group('member strip evidence', () {
    testWidgets('the model reasoning reads inline, not in a dialog',
        (tester) async {
      await pumpPanel(tester);

      await tester.tap(find.text('2 threads'));
      await tester.pumpAndSettle();

      expect(find.text('Both concern the website redesign.'), findsOneWidget);
      // A thread a person filed has no model reasoning to show, and inventing
      // one would be worse than saying who did it.
      expect(find.text('You added this.'), findsOneWidget);
      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('Launch date'), findsOneWidget);
      // The explanation is the strip itself now. Nothing here opens a popup.
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('the charter', () {
    const placeholder = 'No charter yet — the model drafts one from the '
        'threads.';
    const charter = 'Threads about the new homepage and its launch.';

    testWidgets('About says so when nothing has been written yet',
        (tester) async {
      await pumpPanel(tester);
      expect(find.text(placeholder), findsNothing);

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text(placeholder), findsOneWidget);
    });

    testWidgets('and shows the charter once there is one', (tester) async {
      await pumpPanel(tester, storyline: _chartered);

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text(charter), findsOneWidget);
    });

    testWidgets('tapping it opens a prefilled field that saves what it holds',
        (tester) async {
      final saved = <String>[];
      await pumpPanel(
        tester,
        storyline: _chartered,
        onSetCharter: saved.add,
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(charter));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        charter,
      );

      await tester.enterText(
        find.byType(TextField),
        'Only the launch announcement threads.',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, ['Only the launch announcement threads.']);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      final saved = <String>[];
      await pumpPanel(
        tester,
        storyline: _chartered,
        onSetCharter: saved.add,
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(charter));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Something else.');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(saved, isEmpty);
      expect(find.text(charter), findsOneWidget);
    });

    testWidgets('Add thread asks the host for a picker', (tester) async {
      var asked = 0;
      await pumpPanel(tester, onAddThread: () => asked++);

      await tester.tap(find.text('Add thread'));
      await tester.pumpAndSettle();

      expect(asked, 1);
    });
  });
}
