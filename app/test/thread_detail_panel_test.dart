import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The open-ask banner, the per-message ask lines under it, the suggestion
/// cards beside them, and which messages the transcript folds away. The
/// overflow menu is covered in `thread_detail_menu_test.dart`.
Message _msg({
  required String id,
  bool outbound = false,
  required String receivedAt,
  bool? needsAction,
  bool? replyExpected,
  List<String> actionItems = const [],
  String? bodyText,
}) {
  return Message(
    id: id,
    outbound: outbound,
    fromName: outbound ? null : 'Dana Ruiz',
    fromAddress: outbound ? 'me@example.com' : 'dana@example.com',
    receivedAt: receivedAt,
    bodyText: bodyText ?? 'Body of $id.',
    triageStatus: 'done',
    needsAction: needsAction,
    replyExpected: replyExpected,
    actionItems: actionItems,
  );
}

/// A message whose body has a second line, so the folded one-line preview and
/// the open body are told apart by what is on screen rather than by widget
/// type.
Message _twoLine({
  required String id,
  required String receivedAt,
  bool? needsAction,
  List<String> actionItems = const [],
}) =>
    _msg(
      id: id,
      receivedAt: receivedAt,
      needsAction: needsAction,
      actionItems: actionItems,
      bodyText: 'First line of $id.\nSecond line of $id.',
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Message> messages,
    String? ctaText = 'Reply to Dana',
    ConversationState state = ConversationState.needsReply,
    VoidCallback? onOpenReply,
    Widget? Function(Message message)? suggestionFor,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadDetailPanel(
          conversation: Conversation(
            id: 'c1',
            subject: 'Launch date',
            state: state,
            ctaText: ctaText,
          ),
          messages: messages,
          onMarkDone: () {},
          onOpenReply: onOpenReply,
          suggestionFor: suggestionFor,
        ),
      ),
    ));
  }

  /// One message's row, by the key the transcript gives it.
  Finder rowFor(String id) => find.byKey(ValueKey(id));

  /// The fold affordance on one row, whichever way it is pointing.
  Finder chevronOn(String id, {required bool collapsed}) => find.descendant(
        of: rowFor(id),
        matching:
            find.byIcon(collapsed ? Icons.expand_more : Icons.expand_less),
      );

  testWidgets('more than one open ask is counted in the banner', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(
        id: 'b',
        receivedAt: '2026-08-25T11:00:00',
        replyExpected: true,
        actionItems: const ['Confirm the date'],
      ),
    ]);

    expect(find.text('Reply to Dana · 2 open asks'), findsOneWidget);
  });

  testWidgets('a single open ask leaves the banner as the bare CTA',
      (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
    ]);

    expect(find.text('Reply to Dana'), findsOneWidget);
    expect(find.textContaining('open asks'), findsNothing);
  });

  testWidgets('one reply answers every ask before it', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(
        id: 'b',
        receivedAt: '2026-08-25T11:00:00',
        replyExpected: true,
        actionItems: const ['Confirm the date'],
      ),
      _msg(id: 'c', outbound: true, receivedAt: '2026-08-25T12:00:00'),
    ]);

    expect(find.text('Reply to Dana'), findsOneWidget);
    expect(find.textContaining('open asks'), findsNothing);
    expect(find.text('Send the deck'), findsNothing);
    expect(find.text('Confirm the date'), findsNothing);
  });

  group('an ask is a call to action', () {
    testWidgets('the banner opens the reply', (tester) async {
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            needsAction: true,
            actionItems: const ['Send the deck'],
          ),
        ],
      );

      await tester.tap(find.text('Reply to Dana'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets("and so does a message's own ask line", (tester) async {
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            needsAction: true,
            actionItems: const ['Send the deck'],
          ),
        ],
      );

      await tester.tap(find.text('Send the deck'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('a pane with no reply to open leaves both as statements',
        (tester) async {
      await pump(tester, messages: [
        _msg(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
      ]);

      // Still said, still not clickable.
      expect(find.text('Reply to Dana'), findsOneWidget);
      expect(find.text('Send the deck'), findsOneWidget);
      for (final ask in ['Reply to Dana', 'Send the deck']) {
        expect(
          find.ancestor(of: find.text(ask), matching: find.byType(InkWell)),
          findsNothing,
        );
      }
    });
  });

  testWidgets('a waiting thread carries no banner and no ask line',
      (tester) async {
    // The send that flips the thread to waiting clears the CTA in the same
    // fold. The ask lines have to go with it, or they sit lit under a banner
    // that is already gone until the sent message syncs back.
    await pump(
      tester,
      state: ConversationState.waiting,
      messages: [
        _msg(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
      ],
    );

    expect(find.text('Reply to Dana'), findsNothing);
    expect(find.text('Send the deck'), findsNothing);
  });

  /// The panel places what the host builds and never learns what it is.
  group('the suggestion under a message', () {
    testWidgets('is drawn under the message it was built for', (tester) async {
      await pump(
        tester,
        messages: [
          _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
        suggestionFor: (m) => Text('card for ${m.id}'),
      );

      expect(
        find.descendant(of: rowFor('a'), matching: find.text('card for a')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowFor('b'), matching: find.text('card for b')),
        findsOneWidget,
      );
      // Each card belongs to one message; neither strayed into the other's row.
      expect(
        find.descendant(of: rowFor('a'), matching: find.text('card for b')),
        findsNothing,
      );
    });

    testWidgets('and a message the host offers nothing for gets nothing',
        (tester) async {
      await pump(
        tester,
        messages: [
          _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
        suggestionFor: (m) => m.id == 'b' ? const Text('card for b') : null,
      );

      expect(find.text('card for b'), findsOneWidget);
      expect(find.textContaining('card for a'), findsNothing);
    });
  });

  /// Folding a message is not the `Show more` clamp on a long body: it gives up
  /// the whole message and keeps only what still wants something.
  group('folding a message away', () {
    testWidgets('a message the thread has moved past opens folded',
        (tester) async {
      await pump(tester, messages: [
        _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
        _twoLine(
          id: 'b',
          receivedAt: '2026-08-25T11:00:00',
          needsAction: true,
          actionItems: const ['Confirm the date'],
        ),
      ]);

      // Nothing open on it and nothing offered for it: one muted line of what
      // was said, and no more.
      expect(find.text('First line of a.'), findsOneWidget);
      expect(find.textContaining('Second line of a.'), findsNothing);
      expect(chevronOn('a', collapsed: true), findsOneWidget);
    });

    testWidgets('the newest message never does — it is what the thread is '
        'about', (tester) async {
      await pump(tester, messages: [
        _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
        _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
      ]);

      expect(find.textContaining('Second line of b.'), findsOneWidget);
      expect(chevronOn('b', collapsed: true), findsNothing);
      expect(chevronOn('b', collapsed: false), findsNothing);
    });

    testWidgets('and neither does one still waiting on an answer',
        (tester) async {
      await pump(tester, messages: [
        _twoLine(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
        _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
      ]);

      expect(find.textContaining('Second line of a.'), findsOneWidget);
      // Offered, but not taken: the ask is the reason to scroll back here.
      expect(chevronOn('a', collapsed: false), findsOneWidget);
    });

    testWidgets('nor one with a suggestion waiting on it', (tester) async {
      await pump(
        tester,
        messages: [
          _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
        suggestionFor: (m) => m.id == 'a' ? const Text('card for a') : null,
      );

      expect(find.textContaining('Second line of a.'), findsOneWidget);
      expect(find.text('card for a'), findsOneWidget);
    });

    testWidgets('a folded message still says it needs an answer',
        (tester) async {
      // The whole point of the rule: the fold hides reading, never answering.
      await pump(tester, messages: [
        _twoLine(
          id: 'a',
          receivedAt: '2026-08-25T09:00:00',
          needsAction: true,
          actionItems: const ['Send the deck'],
        ),
        _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
      ]);

      await tester.tap(chevronOn('a', collapsed: false));
      await tester.pump();

      expect(find.textContaining('Second line of a.'), findsNothing);
      expect(find.text('Send the deck'), findsOneWidget);
    });

    testWidgets('and a folded suggestion says there is one under the fold',
        (tester) async {
      await pump(
        tester,
        messages: [
          _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
        suggestionFor: (m) => m.id == 'a' ? const Text('card for a') : null,
      );

      await tester.tap(chevronOn('a', collapsed: false));
      await tester.pump();

      expect(find.text('✨ Suggested reply'), findsOneWidget);
      expect(find.text('card for a'), findsNothing);
    });

    testWidgets('and the header gives it all back', (tester) async {
      await pump(
        tester,
        messages: [
          _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
        suggestionFor: (m) => m.id == 'a' ? const Text('card for a') : null,
      );
      await tester.tap(chevronOn('a', collapsed: false));
      await tester.pump();

      await tester.tap(chevronOn('a', collapsed: true));
      await tester.pump();

      expect(find.textContaining('Second line of a.'), findsOneWidget);
      expect(find.text('card for a'), findsOneWidget);
      expect(find.text('✨ Suggested reply'), findsNothing);
    });

    testWidgets('a message the user opened stays open through a rebuild',
        (tester) async {
      // The transcript rebuilds on every sync and every draft reload. The fold
      // is seeded once and never recomputed — there is deliberately no
      // `didUpdateWidget` arm — so none of those rebuilds may fold a message
      // back under the user's cursor.
      final messages = [
        _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
        _twoLine(id: 'b', receivedAt: '2026-08-25T11:00:00'),
      ];
      await pump(tester, messages: messages);
      await tester.tap(chevronOn('a', collapsed: true));
      await tester.pump();
      expect(find.textContaining('Second line of a.'), findsOneWidget);

      // The same thread again — same keys, so the rows keep their elements,
      // exactly as a sync-driven rebuild would.
      await pump(tester, messages: messages);

      expect(find.textContaining('Second line of a.'), findsOneWidget);
      expect(chevronOn('a', collapsed: false), findsOneWidget);
    });

    testWidgets('a run is never half folded', (tester) async {
      // Folding a run's header while its continuations stayed up would leave
      // the rest of the run hanging under no name.
      await pump(tester, messages: [
        _twoLine(id: 'a', receivedAt: '2026-08-25T09:00:00'),
        _twoLine(id: 'b', receivedAt: '2026-08-25T09:01:00'),
        _twoLine(id: 'c', receivedAt: '2026-08-25T11:00:00'),
      ]);

      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      expect(find.textContaining('Second line of a.'), findsOneWidget);
      expect(find.textContaining('Second line of b.'), findsOneWidget);
    });
  });

  testWidgets('only the unanswered message carries an ask line', (tester) async {
    await pump(tester, messages: [
      _msg(
        id: 'a',
        receivedAt: '2026-08-25T09:00:00',
        needsAction: true,
        actionItems: const ['Send the deck'],
      ),
      _msg(id: 'b', outbound: true, receivedAt: '2026-08-25T10:00:00'),
      _msg(
        id: 'c',
        receivedAt: '2026-08-25T11:00:00',
        needsAction: true,
        actionItems: const ['Confirm the date'],
      ),
    ]);

    expect(find.text('Confirm the date'), findsOneWidget);
    expect(find.text('Send the deck'), findsNothing);
  });
}
