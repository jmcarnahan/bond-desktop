import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The overflow menu only — the transcript itself is covered elsewhere.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? bucket,
    VoidCallback? onAddToStoryline,
    VoidCallback? onSendToLater,
    VoidCallback? onKeepInInbox,
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
          ),
          messages: const [],
          onMarkDone: () {},
          onAddToStoryline: onAddToStoryline,
          onSendToLater: onSendToLater,
          onKeepInInbox: onKeepInInbox,
        ),
      ),
    ));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
  }

  testWidgets('a host that wires nothing renders no menu at all',
      (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  testWidgets('Send to Later alone is enough to open the menu', (tester) async {
    await pump(tester, onSendToLater: () {});
    await openMenu(tester);

    expect(find.text('Send to Later'), findsOneWidget);
  });

  testWidgets('Keep in inbox is hidden on a thread that is not bucketed',
      (tester) async {
    // An undo for something that never happened reads as a broken menu item.
    await pump(tester, onSendToLater: () {}, onKeepInInbox: () {});
    await openMenu(tester);

    expect(find.text('Keep in inbox'), findsNothing);
  });

  testWidgets('and shown once it is', (tester) async {
    await pump(
      tester,
      bucket: 'later',
      onSendToLater: () {},
      onKeepInInbox: () {},
    );
    await openMenu(tester);

    expect(find.text('Keep in inbox'), findsOneWidget);
  });

  testWidgets('the menu never lists the storylines themselves', (tester) async {
    // The choice is a pane with a way back, not a popup full of rows.
    await pump(tester, onAddToStoryline: () {});
    await openMenu(tester);

    expect(find.text('Add to storyline…'), findsOneWidget);
    expect(find.text('New storyline…'), findsNothing);
  });

  testWidgets('each item fires only its own callback', (tester) async {
    var later = 0;
    var keep = 0;
    var picking = 0;

    await pump(
      tester,
      bucket: 'later',
      onAddToStoryline: () => picking++,
      onSendToLater: () => later++,
      onKeepInInbox: () => keep++,
    );

    await openMenu(tester);
    await tester.tap(find.text('Send to Later'));
    await tester.pumpAndSettle();
    expect((later, keep, picking), (1, 0, 0));

    await openMenu(tester);
    await tester.tap(find.text('Keep in inbox'));
    await tester.pumpAndSettle();
    expect((later, keep), (1, 1));

    await openMenu(tester);
    await tester.tap(find.text('Add to storyline…'));
    await tester.pumpAndSettle();
    expect((later, keep, picking), (1, 1, 1));
  });
}
