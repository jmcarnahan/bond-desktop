import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/bot_run_row.dart';
import 'package:bond_inbox/widgets/hover_actions.dart';
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:bond_inbox/widgets/mention_navigator.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/needs_you_reason.dart';
import 'package:bond_inbox/widgets/quote_block.dart';
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

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
  bool addressedMe = false,
  List<AttachmentRef> attachments = const [],
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
    addressedMe: addressedMe,
    attachments: attachments,
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

/// One status line from a meeting application, gated at ingest the way
/// `TeamsSync` gates every application's message. [source] and [fromAddress]
/// turn it into a mail auto-reply, which the header gate words the same way.
Message _bot({
  required String id,
  required String receivedAt,
  String source = 'teams',
  String fromAddress = 'teams:app-0001',
  bool addressedMe = false,
}) =>
    Message(
      id: id,
      source: source,
      outbound: false,
      fromName: 'Meeting assistant',
      fromAddress: fromAddress,
      receivedAt: receivedAt,
      bodyText: 'Status from $id.',
      triageStatus: 'done',
      gateReason: 'auto_generated',
      addressedMe: addressedMe,
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Message> messages,
    String? ctaText = 'Reply to Dana',
    ConversationState state = ConversationState.needsReply,
    String? reason,
    String? reasonAt,
    String? reasonMessageId,
    double? needsYouP,
    TranscriptJumps? jumps,
    VoidCallback? onOpenReply,
    VoidCallback? onReopen,
    VoidCallback? onCompose,
    Widget? Function(Message message)? suggestionFor,
    void Function(AttachmentRef attachment)? onOpenAttachment,
    AttachmentRef? selectedAttachment,
    ImageProvider? Function(AttachmentRef attachment)? thumbnailFor,
    void Function(Message message)? onReplyTo,
    void Function(Message message)? onSuggestFor,
    void Function(Message message)? onWhy,
    void Function(Message message)? onWhatHappened,
    void Function(String url)? onOpenLink,
    List<Label> labels = const [],
    LabelPickerMode? labelPicker,
    void Function(LabelPickerMode mode)? onOpenLabelPicker,
    void Function(Label label)? onApplyLabel,
    void Function(String name)? onCreateLabel,
    VoidCallback? onDismissWithoutLabel,
    VoidCallback? onCloseLabelPicker,
    String source = 'email',
    List<Label> threadLabels = const [],
    VoidCallback? onRemoveFromNeedsYou,
    VoidCallback? onAddToNeedsYou,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadDetailPanel(
          conversation: Conversation(
            id: 'c1',
            source: source,
            subject: 'Launch date',
            state: state,
            ctaText: ctaText,
            needsYouReason: reason,
            needsYouReasonAt: reasonAt,
            needsYouReasonMessageId: reasonMessageId,
            needsYouP: needsYouP,
            labels: threadLabels,
          ),
          messages: messages,
          jumps: jumps,
          onMarkDone: () {},
          onReopen: onReopen,
          onOpenReply: onOpenReply,
          onCompose: onCompose,
          suggestionFor: suggestionFor,
          onOpenAttachment: onOpenAttachment,
          selectedAttachment: selectedAttachment,
          thumbnailFor: thumbnailFor,
          onReplyTo: onReplyTo,
          onSuggestFor: onSuggestFor,
          onWhy: onWhy,
          onWhatHappened: onWhatHappened,
          onOpenLink: onOpenLink,
          labels: labels,
          labelPicker: labelPicker,
          onOpenLabelPicker: onOpenLabelPicker,
          onApplyLabel: onApplyLabel,
          onCreateLabel: onCreateLabel,
          onDismissWithoutLabel: onDismissWithoutLabel,
          onCloseLabelPicker: onCloseLabelPicker,
          onRemoveFromNeedsYou: onRemoveFromNeedsYou,
          onAddToNeedsYou: onAddToNeedsYou,
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

  testWidgets('a Message button appears only when the host can compose',
      (tester) async {
    final messages = [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')];

    await pump(tester, messages: messages);
    expect(find.byKey(const Key('thread-compose')), findsNothing);

    var asked = 0;
    await pump(tester, messages: messages, onCompose: () => asked++);
    expect(find.byKey(const Key('thread-compose')), findsOneWidget);

    await tester.tap(find.byKey(const Key('thread-compose')));
    await tester.pump();

    expect(asked, 1);
  });

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

  group('why this thread is asking', () {
    final messages = [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')];
    const at = '2026-08-25T09:00:00';

    String lineText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(needsYouWhyLineKey)).data!;

    testWidgets('names the reason and when the message arrived',
        (tester) async {
      await pump(
        tester,
        messages: messages,
        ctaText: null,
        reason: 'Asks you to confirm the launch date.',
        reasonAt: at,
      );

      expect(
        lineText(tester),
        'Why: Asks you to confirm the launch date. · '
        '${formatTimestamp(at)}',
      );
    });

    testWidgets('a reason with no stamp still says why', (tester) async {
      await pump(
        tester,
        messages: messages,
        ctaText: null,
        reason: 'teams_direct',
      );

      expect(lineText(tester), 'Why: Direct message');
    });

    testWidgets("the thread's probability sits between the reason and the "
        'stamp', (tester) async {
      await pump(
        tester,
        messages: messages,
        ctaText: null,
        reason: 'Asks you to confirm the launch date.',
        reasonAt: at,
        needsYouP: 0.72,
      );

      expect(
        lineText(tester),
        'Why: Asks you to confirm the launch date. · 72% · '
        '${formatTimestamp(at)}',
      );
    });

    testWidgets("the owner's answer is its own sentence, with no percentage",
        (tester) async {
      await pump(
        tester,
        messages: messages,
        ctaText: null,
        reason: 'You removed a message like this from Needs You.',
        reasonAt: at,
        needsYouP: 0.0,
      );

      expect(
        lineText(tester),
        'Why: You removed a message like this from Needs You. · '
        '${formatTimestamp(at)}',
      );
    });

    testWidgets('the bar offers Remove or Add by the rail\'s own rule',
        (tester) async {
      await pump(
        tester,
        messages: messages,
        needsYouP: 0.72,
        onRemoveFromNeedsYou: () {},
        onAddToNeedsYou: () {},
      );
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsOneWidget);
      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsNothing);

      await pump(
        tester,
        messages: messages,
        needsYouP: 0.1,
        onRemoveFromNeedsYou: () {},
        onAddToNeedsYou: () {},
      );
      expect(find.byKey(ThreadActionBar.needsYouRemoveKey), findsNothing);
      expect(find.byKey(ThreadActionBar.needsYouAddKey), findsOneWidget);
    });

    testWidgets('the banner answers first when there is one', (tester) async {
      // Two explanations stacked would read as two different ones, and the ask
      // is the better answer of the two.
      await pump(
        tester,
        messages: messages,
        reason: 'teams_direct',
        reasonAt: at,
      );

      expect(find.text('Reply to Dana'), findsOneWidget);
      expect(find.byKey(needsYouWhyLineKey), findsNothing);
    });

    testWidgets('no reason, no line', (tester) async {
      await pump(tester, messages: messages, ctaText: null);

      expect(find.byKey(needsYouWhyLineKey), findsNothing);
    });

    testWidgets('and none on a thread that is not asking', (tester) async {
      await pump(
        tester,
        messages: messages,
        ctaText: null,
        state: ConversationState.done,
        reason: 'teams_direct',
        reasonAt: at,
      );

      expect(find.byKey(needsYouWhyLineKey), findsNothing);
    });
  });

  group('where the thread came from', () {
    testWidgets('a host that cannot say draws no External chip',
        (tester) async {
      // `ownerDomains` defaults to empty, so the header every existing call
      // site draws is the header it drew before the chip existed.
      // `external_tint_test` holds what a host that CAN say gets.
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
      ]);

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsNothing);
      expect(find.text('External'), findsNothing);
    });
  });

  group('links in the banner and the transcript', () {
    const url = 'https://metrics.example.com/rooms/01f0b5d9c4e2';
    const run = 'Dashboard <$url>';

    testWidgets('the banner paints the label and opens the whole address',
        (tester) async {
      final opened = <String>[];
      var replies = 0;
      await pump(
        tester,
        messages: [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')],
        ctaText: 'Confirm access. $run',
        onOpenReply: () => replies++,
        onOpenLink: opened.add,
      );

      expect(find.text('Confirm access. Dashboard'), findsOneWidget);
      expect(find.textContaining('http'), findsNothing);

      await tester.tapOnText(find.textRange.ofSubstring('Dashboard'));
      await tester.pump();

      expect(opened, [url]);
      // The banner is still the way into the reply everywhere else on it.
      expect(replies, 0);
    });

    testWidgets('a body link in the transcript reaches the host too',
        (tester) async {
      final opened = <String>[];
      await pump(
        tester,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            bodyText: 'Numbers are here: $run',
          ),
        ],
        ctaText: null,
        onOpenLink: opened.add,
      );

      await tester.tapOnText(find.textRange.ofSubstring('Dashboard'));
      await tester.pump();

      expect(opened, [url]);
    });
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
    testWidgets('the banner explains the newest inbound ask', (tester) async {
      // Rewritten in Phase 6: the composer is docked and always visible, so
      // "put the cursor in the box" is a click nobody needed help with, while
      // "where did this ask come from" had no answer anywhere.
      final asked = <String>[];
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        onWhy: (m) => asked.add(m.id),
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            needsAction: true,
            actionItems: const ['Send the deck'],
          ),
          _msg(id: 'b', receivedAt: '2026-08-25T11:00:00'),
        ],
      );

      await tester.tap(find.text('Reply to Dana'));
      await tester.pump();

      expect(asked, ['b']);
      expect(opened, 0);
    });

    testWidgets('with no Why to open, the banner still opens the reply',
        (tester) async {
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

    testWidgets('a thread with nothing inbound falls back to the reply',
        (tester) async {
      // Nothing to explain: the banner's ask is about a message somebody sent
      // the reader, and there is none.
      var opened = 0;
      await pump(
        tester,
        onOpenReply: () => opened++,
        onWhy: (_) => fail('there is no inbound message to explain'),
        messages: [
          _msg(id: 'mine', outbound: true, receivedAt: '2026-08-25T09:00:00'),
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

  group('reopen', () {
    testWidgets('a done thread offers it where Done used to sit',
        (tester) async {
      await pump(
        tester,
        state: ConversationState.done,
        messages: [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')],
        onReopen: () {},
      );

      expect(find.text('Reopen'), findsOneWidget);
      // By key: the header's state chip says "Done" on a closed thread.
      expect(find.byKey(ThreadActionBar.doneKey), findsNothing);
    });

    testWidgets('tapping it asks the host', (tester) async {
      var reopened = 0;
      await pump(
        tester,
        state: ConversationState.done,
        messages: [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')],
        onReopen: () => reopened++,
      );

      await tester.tap(find.text('Reopen'));
      await tester.pump();

      expect(reopened, 1);
    });

    testWidgets('a live thread is still the one that closes', (tester) async {
      await pump(
        tester,
        messages: [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')],
        onReopen: () {},
      );

      expect(find.byKey(ThreadActionBar.doneKey), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });

    testWidgets('a host with nowhere to put it gets no button', (tester) async {
      await pump(
        tester,
        state: ConversationState.done,
        messages: [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')],
      );

      expect(find.text('Reopen'), findsNothing);
    });
  });

  group('attachments', () {
    testWidgets('a row that carried a file offers it to the host',
        (tester) async {
      AttachmentRef? opened;
      await pump(
        tester,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            attachments: [ref(messageId: 'a', name: 'Terms.pdf')],
          ),
        ],
        onOpenAttachment: (attachment) => opened = attachment,
      );

      await tester.tap(find.text('Terms.pdf'));
      expect(opened?.attachmentId, 'a1');
    });

    testWidgets('and the one on screen is the one that says so',
        (tester) async {
      final file = ref(messageId: 'a', name: 'Terms.pdf');
      await pump(
        tester,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            attachments: [file, ref(messageId: 'a', attachmentId: 'a2')],
          ),
        ],
        onOpenAttachment: (_) {},
        selectedAttachment: file,
      );

      final chips =
          tester.widgetList<AttachmentCard>(find.byType(AttachmentCard));
      expect(chips.where((c) => c.selected).length, 1);
      expect(chips.firstWhere((c) => c.selected).attachment.attachmentId, 'a1');
    });

    testWidgets('a panel told nothing about files leaves them as statements',
        (tester) async {
      await pump(
        tester,
        messages: [
          _msg(
            id: 'a',
            receivedAt: '2026-08-25T09:00:00',
            attachments: [ref(messageId: 'a', name: 'Terms.pdf')],
          ),
        ],
      );

      expect(find.text('Terms.pdf'), findsOneWidget);
      expect(
        tester.widget<AttachmentCard>(find.byType(AttachmentCard)).onTap,
        isNull,
      );
    });
  });

  /// The strip that appears at a row's top-right under the mouse.
  ///
  /// It is an accelerator and never the only way to do a thing, which is why
  /// every assertion here is about WHICH message a button carries: a Reply
  /// that fired for its neighbour would answer Thursday's mail with Monday's
  /// words.
  group('the hover strip', () {
    /// Puts a MOUSE over one row. Touch never enters a `MouseRegion`.
    Future<void> hover(WidgetTester tester, String id) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(rowFor(id)));
      await tester.pump();
    }

    final two = [
      _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
      _msg(id: 'b', receivedAt: '2026-08-25T15:00:00'),
    ];

    testWidgets('offers Reply and Suggest on the message under the pointer',
        (tester) async {
      final replied = <String>[];
      final suggested = <String>[];
      await pump(
        tester,
        messages: two,
        onReplyTo: (m) => replied.add(m.id),
        onSuggestFor: (m) => suggested.add(m.id),
      );

      // Nothing until a pointer arrives.
      expect(find.byKey(HoverActions.replyKeyFor('a')), findsNothing);

      await hover(tester, 'a');

      expect(find.byKey(HoverActions.replyKeyFor('a')), findsOneWidget);
      // One row at a time: the strip belongs to the message under the mouse.
      expect(find.byKey(HoverActions.replyKeyFor('b')), findsNothing);

      await tester.tap(find.byKey(HoverActions.replyKeyFor('a')));
      await tester.pump();
      await tester.tap(find.byKey(HoverActions.suggestKeyFor('a')));
      await tester.pump();

      expect(replied, ['a']);
      expect(suggested, ['a']);
    });

    testWidgets('and reports the OLDER message when that is the one hovered',
        (tester) async {
      final replied = <String>[];
      await pump(tester, messages: two, onReplyTo: (m) => replied.add(m.id));

      await hover(tester, 'b');
      await tester.tap(find.byKey(HoverActions.replyKeyFor('b')));
      await tester.pump();

      expect(replied, ['b']);
    });

    testWidgets('an outbound row wears nothing', (tester) async {
      // There is nothing to reply to on the user's own message, and nothing to
      // draft an answer to either.
      await pump(
        tester,
        messages: [
          _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'mine', outbound: true, receivedAt: '2026-08-25T16:00:00'),
        ],
        onReplyTo: (_) {},
        onSuggestFor: (_) {},
      );

      await hover(tester, 'mine');

      expect(find.byKey(HoverActions.replyKeyFor('mine')), findsNothing);
      expect(find.byKey(HoverActions.suggestKeyFor('mine')), findsNothing);
    });

    testWidgets('one callback draws one button', (tester) async {
      await pump(tester, messages: two, onReplyTo: (_) {});

      await hover(tester, 'a');

      expect(find.byKey(HoverActions.replyKeyFor('a')), findsOneWidget);
      expect(find.byKey(HoverActions.suggestKeyFor('a')), findsNothing);
    });

    testWidgets('a panel wired with neither wraps nothing at all',
        (tester) async {
      await pump(tester, messages: two);

      await hover(tester, 'a');

      // The wrapper hands the row straight through — `hover_actions_test`
      // pins that there is not even a MouseRegion left behind.
      expect(find.byKey(HoverActions.replyKeyFor('a')), findsNothing);
      expect(find.byKey(HoverActions.suggestKeyFor('a')), findsNothing);
      expect(find.byKey(HoverActions.whyKeyFor('a')), findsNothing);
      expect(find.byIcon(Icons.reply_outlined), findsNothing);
      expect(find.text('Body of a.'), findsOneWidget);
    });

    testWidgets('Why joins the strip, on the row under the pointer',
        (tester) async {
      final asked = <String>[];
      await pump(tester, messages: two, onWhy: (m) => asked.add(m.id));

      expect(find.byKey(HoverActions.whyKeyFor('a')), findsNothing);

      await hover(tester, 'a');

      expect(find.byKey(HoverActions.whyKeyFor('a')), findsOneWidget);
      expect(find.byKey(HoverActions.whyKeyFor('b')), findsNothing);

      await tester.tap(find.byKey(HoverActions.whyKeyFor('a')));
      await tester.pump();

      expect(asked, ['a']);
    });

    testWidgets('an outbound row is not explained either', (tester) async {
      await pump(
        tester,
        messages: [
          _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'mine', outbound: true, receivedAt: '2026-08-25T16:00:00'),
        ],
        onWhy: (_) {},
      );

      await hover(tester, 'mine');

      expect(find.byKey(HoverActions.whyKeyFor('mine')), findsNothing);
    });

    testWidgets('What happened is the fourth button, and names its message',
        (tester) async {
      // The door into a message's history rides the hover strip with the
      // other per-message actions, not the row's header: the row renders one
      // message and does not know what a history is.
      final asked = <String>[];
      await pump(
        tester,
        messages: two,
        onReplyTo: (_) {},
        onSuggestFor: (_) {},
        onWhy: (_) {},
        onWhatHappened: (m) => asked.add(m.id),
      );

      expect(find.byKey(HoverActions.historyKeyFor('a')), findsNothing);
      expect(find.text('What happened'), findsNothing);

      await hover(tester, 'a');

      expect(find.byKey(HoverActions.historyKeyFor('a')), findsOneWidget);
      expect(find.byKey(HoverActions.historyKeyFor('b')), findsNothing);
      expect(find.byTooltip('What happened'), findsOneWidget);

      await tester.tap(find.byKey(HoverActions.historyKeyFor('a')));
      await tester.pump();

      expect(asked, ['a']);
      expect(
        find.text('Body of a.'),
        findsOneWidget,
        reason: 'asking what happened must not fold the message asked about',
      );
    });

    testWidgets('no What happened without a handler', (tester) async {
      await pump(tester, messages: two, onWhy: (_) {});

      await hover(tester, 'a');

      expect(find.byKey(HoverActions.whyKeyFor('a')), findsOneWidget);
      expect(find.byKey(HoverActions.historyKeyFor('a')), findsNothing);
    });

    testWidgets('an outbound row has no history to ask about either',
        (tester) async {
      await pump(
        tester,
        messages: [
          _msg(id: 'a', receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'mine', outbound: true, receivedAt: '2026-08-25T16:00:00'),
        ],
        onWhatHappened: (_) {},
      );

      await hover(tester, 'mine');

      expect(find.byKey(HoverActions.historyKeyFor('mine')), findsNothing);
    });
  });

  group('the label picker strip', () {
    final one = [_msg(id: 'a', receivedAt: '2026-08-25T09:00:00')];
    const fyi = Label(id: 'fyi', name: 'FYI only');

    testWidgets('is absent until a host wires it', (tester) async {
      await pump(tester, messages: one);

      // Mark done is always there, and with no second way to finish it acts
      // rather than opening choices.
      expect(find.byKey(ThreadActionBar.doneKey), findsOneWidget);
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect(find.byKey(ThreadActionBar.addLabelKey), findsNothing);
      expect(find.byType(LabelPicker), findsNothing);
      // And the panel is the one it always was.
      expect(find.text('Reply to Dana'), findsOneWidget);
      expect(find.text('Body of a.'), findsOneWidget);
    });

    testWidgets('offers both affordances, each opening its own mode',
        (tester) async {
      final opened = <LabelPickerMode>[];
      await pump(
        tester,
        messages: one,
        onOpenLabelPicker: opened.add,
      );

      // On the action bar now: Mark done opens its choices in place (no
      // menu), and the label row leads with Add label.
      expect(find.byKey(ThreadActionBar.doneKey), findsOneWidget);
      expect(find.text('Add label'), findsOneWidget);
      expect(find.byType(LabelPicker), findsNothing);
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);

      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      await tester.pump();
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsOneWidget);
      await tester.tap(find.byKey(ThreadActionBar.doneWithReasonKey));
      await tester.pump();
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      await tester.tap(find.byKey(ThreadActionBar.addLabelKey));
      await tester.pump();

      expect(opened, [LabelPickerMode.dismiss, LabelPickerMode.label]);
    });

    testWidgets('expands in place, with the mode\'s own prompt and its chips',
        (tester) async {
      await pump(
        tester,
        messages: one,
        labels: const [fyi],
        labelPicker: LabelPickerMode.dismiss,
        onOpenLabelPicker: (_) {},
        onApplyLabel: (_) {},
        onCreateLabel: (_) {},
        onDismissWithoutLabel: () {},
        onCloseLabelPicker: () {},
      );

      expect(find.text('Mark done with a label…'), findsOneWidget);
      expect(find.text('FYI only'), findsOneWidget);
      expect(find.byKey(LabelPicker.noLabelKey), findsOneWidget);
      // The choices it grew out of have shut: the picker stands alone.
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      // Nothing opened over the thread: the transcript is still there.
      expect(find.text('Body of a.'), findsOneWidget);
    });

    testWidgets('opens right under the bar, and ticks the thread\'s own words',
        (tester) async {
      const jira = Label(id: 'jira', name: 'jira');
      await pump(
        tester,
        messages: one,
        labels: const [fyi, jira],
        threadLabels: const [jira],
        labelPicker: LabelPickerMode.label,
        onOpenLabelPicker: (_) {},
        onApplyLabel: (_) {},
        onCreateLabel: (_) {},
        onCloseLabelPicker: () {},
      );

      // What the thread already wears carries a ✓; the rest of the
      // vocabulary does not.
      expect(find.text('✓ jira'), findsOneWidget);
      expect(find.text('FYI only'), findsOneWidget);
      // Pressed on the bar, it opens against the bar — above the ask, not a
      // banner lower.
      final picker = tester.getRect(find.byType(LabelPicker));
      final bar = tester.getRect(find.byType(ThreadActionBar));
      final ask = tester.getRect(find.text('Reply to Dana'));
      expect(picker.top, greaterThanOrEqualTo(bar.bottom - 1));
      expect(picker.bottom, lessThanOrEqualTo(ask.top));
    });

    testWidgets('the label-only mode offers no way out with no label',
        (tester) async {
      await pump(
        tester,
        messages: one,
        labels: const [fyi],
        labelPicker: LabelPickerMode.label,
        onApplyLabel: (_) {},
        onCreateLabel: (_) {},
        onDismissWithoutLabel: () {},
        onCloseLabelPicker: () {},
      );

      expect(find.text('Label…'), findsOneWidget);
      expect(find.byKey(LabelPicker.noLabelKey), findsNothing);
    });

    testWidgets('a chip fires the host\'s apply', (tester) async {
      final applied = <String>[];
      await pump(
        tester,
        messages: one,
        labels: const [fyi],
        labelPicker: LabelPickerMode.dismiss,
        onApplyLabel: (label) => applied.add(label.id),
        onCreateLabel: (_) {},
        onCloseLabelPicker: () {},
      );

      await tester.tap(find.byKey(LabelPicker.keyFor(fyi)));
      await tester.pump();

      expect(applied, ['fyi']);
    });

    testWidgets('and the strip stays collapsed while a callback is missing',
        (tester) async {
      // A picker that could not apply what it was asked for is worse than none.
      await pump(
        tester,
        messages: one,
        labels: const [fyi],
        labelPicker: LabelPickerMode.dismiss,
        onOpenLabelPicker: (_) {},
        onCreateLabel: (_) {},
        onCloseLabelPicker: () {},
      );

      expect(find.byType(LabelPicker), findsNothing);
      // Collapsed, not broken: the bar still offers the way to ask again.
      expect(find.byKey(ThreadActionBar.addLabelKey), findsOneWidget);
    });
  });

  /// Entry 7b: in a fifty-message chat, which two turns are yours and how to
  /// get to them. The walk, the four other doors onto the same jump, and what
  /// arriving looks like.
  group('mentions and transcript jumps', () {
    /// A local, timezone-free stamp, derived from now so nothing here rots at a
    /// midnight boundary.
    String iso(DateTime when) => when.toIso8601String().split('.').first;

    final base = DateTime.now().subtract(const Duration(hours: 6));

    /// Every frame a jump's scroll-then-retry can ask for, and no more TIME than
    /// that: bare pumps, so the flash timer is still burning when the
    /// assertions read it (the pump at the end of each test lets it fire).
    Future<void> settleJump(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
    }

    /// The tint a row is wearing, or null for one that is not lit. Read off the
    /// always-present wrapper rather than by looking for a widget that comes and
    /// goes, which is how the wrapper is built.
    Color? litOn(WidgetTester tester, String id) {
      final box = tester.widget<DecoratedBox>(
        find.byKey(ThreadDetailPanel.flashKeyFor(id)),
      );
      return (box.decoration as BoxDecoration).color;
    }

    /// Let the flash burn out, so no timer outlives the test.
    Future<void> burnOut(WidgetTester tester) =>
        tester.pump(ThreadDetailPanel.flashDuration);

    testWidgets('the navigator counts the turns that name the owner',
        (tester) async {
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base)),
        _msg(
          id: 'b',
          receivedAt: iso(base.add(const Duration(minutes: 30))),
          addressedMe: true,
        ),
        _msg(
          id: 'c',
          receivedAt: iso(base.add(const Duration(minutes: 60))),
          actionItems: const ['Send the deck'],
        ),
        _msg(
          id: 'd',
          receivedAt: iso(base.add(const Duration(minutes: 90))),
        ),
      ]);

      expect(find.byKey(MentionNavigator.navigatorKey), findsOneWidget);
      expect(find.text('@ You · 2'), findsOneWidget);
    });

    testWidgets('a thread that names the owner nowhere draws no navigator',
        (tester) async {
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base)),
        _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
      ]);

      expect(find.byKey(MentionNavigator.navigatorKey), findsNothing);
    });

    testWidgets('the arrow walks the mentions and says where the reader stands',
        (tester) async {
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base), addressedMe: true),
        _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
        _msg(
          id: 'c',
          receivedAt: iso(base.add(const Duration(minutes: 60))),
          addressedMe: true,
        ),
      ]);

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await settleJump(tester);
      expect(find.text('@ You · 1 of 2'), findsOneWidget);
      expect(litOn(tester, 'a'), isNotNull);
      expect(litOn(tester, 'c'), isNull);

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await settleJump(tester);
      expect(find.text('@ You · 2 of 2'), findsOneWidget);
      expect(litOn(tester, 'c'), isNotNull);
      // One row lit at a time: two highlights would say the reader is in two
      // places.
      expect(litOn(tester, 'a'), isNull);

      await tester.tap(find.byKey(MentionNavigator.previousKey));
      await settleJump(tester);
      expect(find.text('@ You · 1 of 2'), findsOneWidget);

      await burnOut(tester);
      expect(litOn(tester, 'a'), isNull);
    });

    testWidgets('a key bound above the panel takes the very same walk',
        (tester) async {
      // The host's key map reaches the transcript through this seam, and lands
      // in the same method the arrows invoke — one walk, two doors.
      final jumps = TranscriptJumps();
      await pump(
        tester,
        jumps: jumps,
        messages: [
          _msg(id: 'a', receivedAt: iso(base), addressedMe: true),
          _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
          _msg(
            id: 'c',
            receivedAt: iso(base.add(const Duration(minutes: 60))),
            addressedMe: true,
          ),
        ],
      );
      expect(jumps.attached, isTrue);

      jumps.nextMention();
      await settleJump(tester);
      expect(find.text('@ You · 1 of 2'), findsOneWidget);
      expect(litOn(tester, 'a'), isNotNull);

      jumps.previousMention();
      await settleJump(tester);
      // Already at the first: the walk stops rather than wrapping to the end.
      expect(find.text('@ You · 1 of 2'), findsOneWidget);

      await burnOut(tester);
    });

    testWidgets('the seam also goes to one named message, and to no other',
        (tester) async {
      final jumps = TranscriptJumps();
      await pump(
        tester,
        jumps: jumps,
        messages: [
          _msg(id: 'a', receivedAt: iso(base)),
          _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
          _msg(
            id: 'c',
            receivedAt: iso(base.add(const Duration(minutes: 60))),
            needsAction: true,
          ),
        ],
      );

      jumps.toMessage('a');
      await settleJump(tester);
      expect(litOn(tester, 'a'), isNotNull);
      expect(chevronOn('a', collapsed: false), findsOneWidget);
      await burnOut(tester);

      // An id from outside the window this panel read is a no-op, not a throw:
      // a host may well ask about a message that scrolled out of it.
      jumps.toMessage('older-than-the-window');
      await settleJump(tester);
      expect(litOn(tester, 'a'), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('and goes quiet once no transcript is mounted', (tester) async {
      final jumps = TranscriptJumps();
      await pump(
        tester,
        jumps: jumps,
        messages: [
          _msg(id: 'a', receivedAt: iso(base), addressedMe: true),
          _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
        ],
      );
      expect(jumps.attached, isTrue);

      // What a key pressed on the list with no thread open means.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      expect(jumps.attached, isFalse);

      jumps.nextMention();
      jumps.toMessage('a');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mentioned row wears its marker and starts unfolded',
        (tester) async {
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base)),
        _msg(
          id: 'b',
          receivedAt: iso(base.add(const Duration(minutes: 30))),
          addressedMe: true,
        ),
        _msg(id: 'c', receivedAt: iso(base.add(const Duration(minutes: 60)))),
      ]);

      // 'a' is history the thread moved past and folds; 'b' is the reason the
      // thread is here at all and does not.
      expect(chevronOn('a', collapsed: true), findsOneWidget);
      expect(chevronOn('b', collapsed: false), findsOneWidget);
      expect(
        find.descendant(
          of: rowFor('b'),
          matching: find.byKey(MessageRow.ownerMarkerKey),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowFor('a'),
          matching: find.byKey(MessageRow.ownerMarkerKey),
        ),
        findsNothing,
      );
    });

    testWidgets('the Why line goes to the message the verdict named',
        (tester) async {
      await pump(
        tester,
        ctaText: null,
        reason: 'Dana asked you to confirm the launch date.',
        reasonMessageId: 'a',
        messages: [
          _msg(id: 'a', receivedAt: iso(base)),
          _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
          _msg(
            id: 'c',
            receivedAt: iso(base.add(const Duration(minutes: 60))),
            needsAction: true,
          ),
        ],
      );

      expect(chevronOn('a', collapsed: true), findsOneWidget);

      await tester.tap(find.byKey(needsYouWhyLineKey));
      await settleJump(tester);

      // Entry 8a's other half: the reason says which message, and now it goes
      // there — arriving unfolds the row and lights it.
      expect(chevronOn('a', collapsed: false), findsOneWidget);
      expect(litOn(tester, 'a'), isNotNull);

      await burnOut(tester);
    });

    testWidgets('and stays a statement when it names nothing this read loaded',
        (tester) async {
      await pump(
        tester,
        ctaText: null,
        reason: 'Dana asked you to confirm the launch date.',
        reasonMessageId: 'older-than-the-window',
        messages: [
          _msg(id: 'a', receivedAt: iso(base)),
          _msg(
            id: 'b',
            receivedAt: iso(base.add(const Duration(minutes: 30))),
            needsAction: true,
          ),
        ],
      );

      expect(find.byKey(needsYouWhyLineKey), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(needsYouWhyLineKey),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    });

    testWidgets('the banner goes to the message its ask was read off',
        (tester) async {
      final asked = <String>[];
      await pump(
        tester,
        onWhy: (m) => asked.add(m.id),
        messages: [
          _msg(id: 'a', receivedAt: iso(base)),
          _msg(
            id: 'b',
            receivedAt: iso(base.add(const Duration(minutes: 30))),
            needsAction: true,
          ),
        ],
      );

      await tester.tap(find.text('Reply to Dana'));
      await settleJump(tester);

      // One press: the explanation opens AND the reader is left standing on the
      // message the words came from.
      expect(asked, ['b']);
      expect(litOn(tester, 'b'), isNotNull);

      await burnOut(tester);
    });

    testWidgets('a quote is the way back to the message it quotes',
        (tester) async {
      final quote = AttachmentRef(
        source: 'teams',
        messageId: 'c',
        attachmentId: 'q1',
        kind: quoteAttachmentKind,
        contentType: 'messageReference',
        itemFrom: 'Dana Ruiz',
        cardText: 'is it slide 29 in the deck?',
        // The quoted message's id, on the column the Teams sync reuses for it.
        contentId: 'a',
      );
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base)),
        _msg(id: 'b', receivedAt: iso(base.add(const Duration(minutes: 30)))),
        _msg(
          id: 'c',
          receivedAt: iso(base.add(const Duration(minutes: 60))),
          attachments: [quote],
        ),
      ]);

      expect(chevronOn('a', collapsed: true), findsOneWidget);

      await tester.tap(find.text('is it slide 29 in the deck?'));
      await settleJump(tester);

      expect(chevronOn('a', collapsed: false), findsOneWidget);
      expect(litOn(tester, 'a'), isNotNull);

      await burnOut(tester);
    });

    testWidgets('a quote of a message outside the window offers no tap',
        (tester) async {
      final quote = AttachmentRef(
        source: 'teams',
        messageId: 'b',
        attachmentId: 'q1',
        kind: quoteAttachmentKind,
        contentType: 'messageReference',
        itemFrom: 'Dana Ruiz',
        cardText: 'is it slide 29 in the deck?',
        contentId: 'older-than-the-window',
      );
      await pump(tester, messages: [
        _msg(id: 'a', receivedAt: iso(base)),
        _msg(
          id: 'b',
          receivedAt: iso(base.add(const Duration(minutes: 30))),
          attachments: [quote],
        ),
      ]);

      expect(find.text('is it slide 29 in the deck?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(QuoteBlock.keyFor(quote)),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    });

    testWidgets('a jump reaches a mention the list had not built yet',
        (tester) async {
      // The whole reason the jump is a LOOP. `ListView(children:)` creates
      // elements for the viewport and its cache extent and nothing else, so a
      // row forty messages down has no context for `ensureVisible` to work
      // from. Each lap scrolls to where the list's own extent estimate puts the
      // row, lets a frame build, and looks again — and the estimate sharpens as
      // more of the list exists.
      const target = 40;
      await pump(tester, messages: [
        for (var i = 0; i < 80; i++)
          _msg(
            id: 'm$i',
            receivedAt: iso(base.add(Duration(minutes: i * 5))),
            addressedMe: i == target,
          ),
      ]);

      expect(find.text('@ You · 1'), findsOneWidget);
      // Not built, and so not reachable by the naive one-shot jump this loop
      // replaced.
      expect(rowFor('m$target'), findsNothing);

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await settleJump(tester);

      expect(rowFor('m$target'), findsOneWidget);
      final row = tester.getRect(rowFor('m$target'));
      final pane = tester.getRect(find.byType(ThreadDetailPanel));
      // Near the TOP of the pane, not merely somewhere on screen: the first lap
      // can only scroll to an estimate, and only a later lap — once the row
      // exists and has a context — can align it. Measured at 219 with the loop
      // and 438 with one lap, so this fails if the retry is removed.
      expect(row.top, greaterThanOrEqualTo(pane.top));
      expect(row.top, lessThan(pane.top + pane.height / 3));
      expect(litOn(tester, 'm$target'), isNotNull);

      await burnOut(tester);
    });

    testWidgets('a far collapsible row arrives OPEN, not folded',
        (tester) async {
      // The mention above is immune to this by accident — a mentioned row
      // starts unfolded. A row that folds by default and is FIRST BUILT
      // mid-jump only ever sees `unfoldRequest` in its initial widget, so
      // `initiallyCollapsed` has to read the pending request too, or the walk
      // ends on one muted line. Ten-minute gaps, so every row is its own run
      // and folds; the Why line is the door, since its target is exactly the
      // kind of old row a long thread has scrolled past.
      const target = 40;
      final start = DateTime.now().subtract(const Duration(hours: 20));
      await pump(
        tester,
        ctaText: null,
        reason: 'Dana asked you to confirm the launch date.',
        reasonMessageId: 'm$target',
        messages: [
          for (var i = 0; i < 80; i++)
            _msg(
              id: 'm$i',
              receivedAt: iso(start.add(Duration(minutes: i * 10))),
            ),
        ],
      );

      expect(rowFor('m$target'), findsNothing);

      await tester.tap(find.byKey(needsYouWhyLineKey));
      await settleJump(tester);

      expect(rowFor('m$target'), findsOneWidget);
      expect(chevronOn('m$target', collapsed: false), findsOneWidget);
      expect(litOn(tester, 'm$target'), isNotNull);

      await burnOut(tester);
    });
  });
  group('a run of bot updates', () {
    String iso(DateTime when) => when.toIso8601String().split('.').first;

    /// Past-anchored and in hours, so the whole thread sits on one day well
    /// behind now.
    final base = DateTime.now().subtract(const Duration(hours: 6));
    DateTime at(int minutes) => base.add(Duration(minutes: minutes));

    /// A person, [bots] status lines a minute apart, and the person again.
    List<Message> thread(int bots) => [
          _msg(id: 'h1', receivedAt: iso(at(0))),
          for (var i = 0; i < bots; i++)
            _bot(id: 'b$i', receivedAt: iso(at(10 + i))),
          _msg(id: 'h2', receivedAt: iso(at(30))),
        ];

    final runLine = BotRunRow.labelFor('Meeting assistant', 5);

    testWidgets('five in a row become one muted line', (tester) async {
      await pump(tester, source: 'teams', messages: thread(5));

      expect(find.text(runLine), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        expect(rowFor('b$i'), findsNothing);
        expect(find.text('Status from b$i.'), findsNothing);
      }
      // The people either side are still rows of their own.
      expect(rowFor('h1'), findsOneWidget);
      expect(find.text('Body of h2.'), findsOneWidget);
    });

    testWidgets('and a tap gives all five back', (tester) async {
      await pump(tester, source: 'teams', messages: thread(5));

      await tester.tap(find.text(runLine));
      await tester.pump();

      for (var i = 0; i < 5; i++) {
        expect(find.text('Status from b$i.'), findsOneWidget);
      }
      // The line stays as the way to put them away again.
      expect(find.text(runLine), findsOneWidget);
      await tester.tap(find.text(runLine));
      await tester.pump();
      expect(find.text('Status from b0.'), findsNothing);
    });

    testWidgets('a run that ends the thread leaves its last line showing',
        (tester) async {
      final messages = [
        _msg(id: 'h1', receivedAt: iso(at(0))),
        for (var i = 0; i < 4; i++)
          _bot(id: 'b$i', receivedAt: iso(at(10 + i))),
      ];
      await pump(tester, source: 'teams', messages: messages);

      expect(
        find.text(BotRunRow.labelFor('Meeting assistant', 3)),
        findsOneWidget,
      );
      expect(find.text('Status from b0.'), findsNothing);
      expect(find.text('Status from b3.'), findsOneWidget);
    });

    testWidgets('and one that would be left under three folds nothing',
        (tester) async {
      final messages = [
        _msg(id: 'h1', receivedAt: iso(at(0))),
        for (var i = 0; i < 3; i++)
          _bot(id: 'b$i', receivedAt: iso(at(10 + i))),
      ];
      await pump(tester, source: 'teams', messages: messages);

      expect(find.byType(BotRunRow), findsNothing);
      expect(find.text('Status from b0.'), findsOneWidget);
    });

    testWidgets('two in a row are just two rows', (tester) async {
      await pump(tester, source: 'teams', messages: thread(2));

      expect(find.byType(BotRunRow), findsNothing);
      expect(find.text('Status from b0.'), findsOneWidget);
      expect(find.text('Status from b1.'), findsOneWidget);
    });

    testWidgets('a bot line that names the owner stays out of the count',
        (tester) async {
      final messages = thread(5);
      messages[3] = _bot(id: 'b2', receivedAt: iso(at(12)), addressedMe: true);
      await pump(tester, source: 'teams', messages: messages);

      // b0, b1 are only two; b3, b4 are only two. Nothing folds.
      expect(find.byType(BotRunRow), findsNothing);
      expect(find.text('Status from b2.'), findsOneWidget);
    });

    testWidgets('an auto-reply in a mail thread never folds', (tester) async {
      // The mail header gate writes the very same word on an out-of-office.
      final messages = [
        for (final m in thread(5))
          m.gateReason == null
              ? m
              : _bot(
                  id: m.id,
                  receivedAt: m.receivedAt!,
                  source: 'email',
                  fromAddress: 'noreply@example.com',
                ),
      ];
      await pump(tester, messages: messages);

      expect(find.byType(BotRunRow), findsNothing);
      for (var i = 0; i < 5; i++) {
        expect(find.text('Status from b$i.'), findsOneWidget);
      }
    });

    testWidgets('a jump into a far folded run lands on it open and lit',
        (tester) async {
      // Far enough down that the run's rows would not be built even if it were
      // open: the run has to open BEFORE the walk looks for the row, or the
      // walk scrolls to a line that has no row for the target at all.
      // A fixed time of day yesterday, so the run sits at noon and cannot
      // straddle a midnight that would split it across two days.
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day - 1, 2);
      final messages = [
        for (var i = 0; i < 60; i++)
          _msg(id: 'm$i', receivedAt: iso(start.add(Duration(minutes: i * 10)))),
        for (var i = 0; i < 5; i++)
          _bot(
            id: 'b$i',
            receivedAt: iso(start.add(Duration(minutes: 600, seconds: i * 20))),
          ),
        for (var i = 60; i < 80; i++)
          _msg(
            id: 'm$i',
            receivedAt: iso(start.add(Duration(minutes: 610 + (i - 60) * 10))),
          ),
      ];
      final jumps = TranscriptJumps();
      await pump(tester, source: 'teams', jumps: jumps, messages: messages);

      expect(rowFor('b3'), findsNothing);

      jumps.toMessage('b3');
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }

      expect(rowFor('b3'), findsOneWidget);
      expect(find.text('Status from b3.'), findsOneWidget);
      final box = tester.widget<DecoratedBox>(
        find.byKey(ThreadDetailPanel.flashKeyFor('b3')),
      );
      expect((box.decoration as BoxDecoration).color, isNotNull);

      await tester.pump(ThreadDetailPanel.flashDuration);
    });
  });
}
