import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a thread's verbs live: the action bar under the header for what is
/// done to THIS thread, and the header's ⋯ for what is said about its SENDER.
/// The transcript itself is covered elsewhere.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? bucket,
    List<Label> labels = const [],
    VoidCallback? onAddToStoryline,
    VoidCallback? onSendToLater,
    VoidCallback? onDropSender,
    VoidCallback? onKeepInInbox,
    VoidCallback? onLaterThread,
    VoidCallback? onContext,
    void Function(Label)? onRemoveLabel,
    void Function(Label)? onFindLabel,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadDetailPanel(
          conversation: Conversation(
            id: 'c1',
            subject: 'Launch date',
            bucket: bucket,
            labels: labels,
          ),
          messages: const [],
          onMarkDone: () {},
          onAddToStoryline: onAddToStoryline,
          onSendToLater: onSendToLater,
          onDropSender: onDropSender,
          onKeepInInbox: onKeepInInbox,
          onLaterThread: onLaterThread,
          onContext: onContext,
          onRemoveLabel: onRemoveLabel,
          onFindLabel: onFindLabel,
        ),
      ),
    ));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
  }

  group('the ⋯ menu holds the sender', () {
    testWidgets('a host that wires nothing renders no menu at all',
        (tester) async {
      await pump(tester, onAddToStoryline: () {}, onLaterThread: () {});
      expect(find.byIcon(Icons.more_horiz), findsNothing);
    });

    testWidgets('the sender-wide Later says whose it is', (tester) async {
      await pump(tester, onSendToLater: () {});
      await openMenu(tester);

      expect(find.text('Send this sender to Later'), findsOneWidget);
    });

    testWidgets('Drop this sender sits under it, the escalation',
        (tester) async {
      await pump(tester, onSendToLater: () {}, onDropSender: () {});
      await openMenu(tester);

      final later =
          tester.getTopLeft(find.text('Send this sender to Later')).dy;
      final drop = tester.getTopLeft(find.text('Drop this sender')).dy;
      expect(drop, greaterThan(later));
    });

    testWidgets('each item fires only its own callback', (tester) async {
      var dropped = 0;
      var later = 0;
      await pump(
        tester,
        onSendToLater: () => later++,
        onDropSender: () => dropped++,
      );

      await openMenu(tester);
      await tester.tap(find.text('Drop this sender'));
      await tester.pumpAndSettle();
      expect((dropped, later), (1, 0));

      await openMenu(tester);
      await tester.tap(find.text('Send this sender to Later'));
      await tester.pumpAndSettle();
      expect((dropped, later), (1, 1));
    });

    testWidgets('no thread verb is left in it', (tester) async {
      await pump(
        tester,
        bucket: 'later',
        onSendToLater: () {},
        onDropSender: () {},
        onAddToStoryline: () {},
        onKeepInInbox: () {},
        onLaterThread: () {},
      );
      await openMenu(tester);

      // Exactly the sender's two, whatever a thread verb is called now.
      expect(
        find.byWidgetPredicate((w) => w is PopupMenuEntry),
        findsNWidgets(2),
      );
      expect(find.text('Send this sender to Later'), findsOneWidget);
      expect(find.text('Drop this sender'), findsOneWidget);
    });
  });

  group('the action bar holds the thread', () {
    testWidgets('Later defers the thread, and reads Keep once it is in Later',
        (tester) async {
      var later = 0;
      var keep = 0;
      await pump(
        tester,
        onLaterThread: () => later++,
        onKeepInInbox: () => keep++,
      );
      expect(find.byKey(ThreadActionBar.keepKey), findsNothing);
      await tester.tap(find.byKey(ThreadActionBar.laterKey));
      expect((later, keep), (1, 0));

      await pump(
        tester,
        bucket: 'later',
        onLaterThread: () => later++,
        onKeepInInbox: () => keep++,
      );
      expect(find.byKey(ThreadActionBar.laterKey), findsNothing);
      await tester.tap(find.byKey(ThreadActionBar.keepKey));
      expect((later, keep), (1, 1));
    });

    testWidgets('storyline and context are one press each', (tester) async {
      var picking = 0;
      var context = 0;
      await pump(
        tester,
        onAddToStoryline: () => picking++,
        onContext: () => context++,
      );

      await tester.tap(find.byKey(ThreadActionBar.storylineKey));
      await tester.tap(find.byKey(ThreadActionBar.contextKey));
      expect((picking, context), (1, 1));
    });

    testWidgets('every icon names itself on hover', (tester) async {
      await pump(tester, onAddToStoryline: () {}, onContext: () {});

      expect(find.byTooltip('Add to storyline'), findsOneWidget);
      expect(find.byTooltip('Add context'), findsOneWidget);
    });
  });

  group('the thread\'s labels', () {
    const jira = Label(id: 'l-jira', name: 'Jira');
    const metrics = Label(id: 'l-metrics', name: 'Metrics');

    testWidgets('are always on screen, without opening anything',
        (tester) async {
      await pump(tester, labels: const [jira, metrics]);

      expect(find.byKey(ThreadActionBar.labelKeyFor('l-jira')), findsOneWidget);
      expect(
        find.byKey(ThreadActionBar.labelKeyFor('l-metrics')),
        findsOneWidget,
      );
    });

    testWidgets('the name finds the label and the ✕ takes it off',
        (tester) async {
      final found = <String>[];
      final removed = <String>[];
      await pump(
        tester,
        labels: const [jira, metrics],
        onFindLabel: (l) => found.add(l.id),
        onRemoveLabel: (l) => removed.add(l.id),
      );

      await tester.tap(find.text('Jira'));
      await tester.tap(find.byKey(ThreadActionBar.removeLabelKey('l-metrics')));

      expect(found, ['l-jira']);
      expect(removed, ['l-metrics']);
    });

    testWidgets('a row that cannot be edited draws no ✕', (tester) async {
      await pump(tester, labels: const [jira]);

      expect(
        find.byKey(ThreadActionBar.removeLabelKey('l-jira')),
        findsNothing,
      );
    });
  });
}
