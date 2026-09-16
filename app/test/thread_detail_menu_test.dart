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
    VoidCallback? onDropSender,
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
          onDropSender: onDropSender,
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

  testWidgets('Drop this sender is absent until a host wires it',
      (tester) async {
    // The item writes a standing gate on an address. A host with no address
    // to key one on gets no item rather than a rule on the empty string.
    await pump(tester, onSendToLater: () {});
    await openMenu(tester);

    expect(find.text('Drop this sender'), findsNothing);
  });

  testWidgets('and sits directly under Send to Later once it is',
      (tester) async {
    // The order is the escalation: quiet this sender, then stop them.
    await pump(tester, onSendToLater: () {}, onDropSender: () {});
    await openMenu(tester);

    final later = tester.getTopLeft(find.text('Send to Later')).dy;
    final drop = tester.getTopLeft(find.text('Drop this sender')).dy;
    expect(drop, greaterThan(later));
  });

  testWidgets('Drop this sender fires its own callback', (tester) async {
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
