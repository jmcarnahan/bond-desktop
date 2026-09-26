import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:bond_inbox/widgets/quick_replies.dart'
    show QuickReply, QuickReplyBox;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String source = 'email',
  String subject = 'Homepage copy',
  ConversationState state = ConversationState.done,
  List<Label> labels = const [],
}) {
  return Conversation(
    id: id,
    source: source,
    subject: subject,
    participants: const [
      Participant(name: 'Alex Rivera', email: 'alex.rivera@example.com'),
    ],
    state: state,
    lastMessageAt: '2026-01-14T10:00:00',
    labels: labels,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Conversation> conversations,
    InboxFilter filter = InboxFilter.done,
    List<(String, List<Conversation>)>? sectionsOverride,
    void Function(String, String)? onReopen,
    String? Function(Conversation)? captionFor,
    void Function(Conversation)? onDismiss,
    void Function(Conversation)? onLabel,
    void Function(Conversation)? onLater,
    void Function(Conversation)? onDismissSender,
    List<Label> labels = const [],
    LabelPickerMode? Function(Conversation)? labelPickerFor,
    void Function(Conversation, Label)? onApplyLabel,
    void Function(Conversation, String)? onCreateLabel,
    void Function(Conversation)? onDismissWithoutLabel,
    void Function(Conversation)? onCloseLabelPicker,
    ({int cleared, int total})? progress,
    QuickReply? Function(Conversation)? quickReplyFor,
    void Function(Conversation, String)? onQuickReplySend,
    void Function(Conversation)? onCloseQuickReply,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConversationListPane(
          sources: const ['email', 'teams'],
          filter: filter,
          conversations: conversations,
          selectedId: null,
          onSelect: (_, _) {},
          sectionsOverride: sectionsOverride,
          onReopen: onReopen,
          captionFor: captionFor,
          onDismiss: onDismiss,
          onLabel: onLabel,
          onLater: onLater,
          onDismissSender: onDismissSender,
          labels: labels,
          labelPickerFor: labelPickerFor,
          onApplyLabel: onApplyLabel,
          onCreateLabel: onCreateLabel,
          onDismissWithoutLabel: onDismissWithoutLabel,
          onCloseLabelPicker: onCloseLabelPicker,
          progress: progress,
          quickReplyFor: quickReplyFor,
          onQuickReplySend: onQuickReplySend,
          onCloseQuickReply: onCloseQuickReply,
        ),
      ),
    ));
  }

  group('reopen', () {
    testWidgets('a done row offers it when the host wired one', (tester) async {
      await pump(
        tester,
        conversations: [_conv(id: 'c1')],
        onReopen: (_, _) {},
      );

      expect(find.text('Reopen'), findsOneWidget);
    });

    testWidgets('the row carries its source and key', (tester) async {
      final reopened = <(String, String)>[];
      await pump(
        tester,
        conversations: [_conv(id: 'c1', source: 'teams')],
        onReopen: (source, key) => reopened.add((source, key)),
      );

      await tester.tap(find.text('Reopen'));
      await tester.pump();

      expect(reopened, [('teams', 'c1')]);
    });

    testWidgets('no callback renders the list exactly as it always did',
        (tester) async {
      await pump(tester, conversations: [_conv(id: 'c1')]);

      expect(find.text('Reopen'), findsNothing);
      expect(find.text('DONE'), findsOneWidget);
    });

    testWidgets('a live section never offers it', (tester) async {
      await pump(
        tester,
        filter: InboxFilter.waiting,
        conversations: [_conv(id: 'c1', state: ConversationState.waiting)],
        onReopen: (_, _) {},
      );

      expect(find.text('WAITING'), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });

    testWidgets("a host's own sections are its own business", (tester) async {
      final rows = [_conv(id: 'c1')];
      await pump(
        tester,
        conversations: rows,
        sectionsOverride: [('DONE', rows)],
        onReopen: (_, _) {},
      );

      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('Reopen'), findsNothing);
    });
  });

  group('captionFor', () {
    testWidgets('reaches the row, per row', (tester) async {
      final rows = [_conv(id: 'a'), _conv(id: 'b')];

      await pump(
        tester,
        conversations: rows,
        sectionsOverride: [('NEEDS YOU', rows)],
        // A builder that answers null for a row leaves that one saying what it
        // always says.
        captionFor: (c) => c.id == 'a' ? 'Deadline · by Friday' : null,
      );

      expect(find.text('Deadline · by Friday'), findsOneWidget);
    });

    testWidgets('and no builder leaves every row alone', (tester) async {
      final rows = [_conv(id: 'a')];

      await pump(
        tester,
        conversations: rows,
        sectionsOverride: [('NEEDS YOU', rows)],
      );

      expect(find.textContaining('Deadline'), findsNothing);
    });
  });

  /// The per-row cluster (entries 12b and 6b) and the inline picker under it.
  /// Every assertion is about WHICH row a button carries and that the card
  /// itself never changed: `ConversationRow` reads the same in every list.
  group('row quick actions', () {
    /// Puts a MOUSE over one row. Touch never enters a `MouseRegion`.
    Future<void> hover(WidgetTester tester, Finder target) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
    }

    Finder rowFor(Conversation c) => find.ancestor(
          of: find.text(c.subject!),
          matching: find.byType(ConversationRow),
        );

    final needsYou = _conv(
      id: 'c1',
      state: ConversationState.needsReply,
      subject: 'Access to the analytics tool',
    );
    final rows = [needsYou];
    const fyi = Label(id: 'fyi', name: 'FYI only');

    testWidgets('are absent until a host wires one', (tester) async {
      await pump(tester, conversations: rows, filter: InboxFilter.needsReply);

      await hover(tester, rowFor(needsYou));

      expect(find.byKey(ConversationListPane.dismissKeyFor(needsYou)),
          findsNothing);
      expect(find.byTooltip('Mark done'), findsNothing);
      // The row is the row it always was.
      expect(find.text('Access to the analytics tool'), findsOneWidget);
    });

    testWidgets('the pointer reveals them, and each fires with its own row',
        (tester) async {
      final acted = <String>[];
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        onDismiss: (c) => acted.add('dismiss:${c.id}'),
        onLabel: (c) => acted.add('label:${c.id}'),
        onLater: (c) => acted.add('later:${c.id}'),
        onDismissSender: (c) => acted.add('sender:${c.id}'),
      );

      // Nothing until a pointer arrives.
      expect(find.byTooltip('Mark done'), findsNothing);

      await hover(tester, rowFor(needsYou));

      expect(find.byTooltip('Mark done'), findsOneWidget);
      expect(find.byTooltip('Label…'), findsOneWidget);
      expect(find.byTooltip('Later'), findsOneWidget);
      // Short on the button, the whole sender in the tooltip.
      expect(find.byTooltip('Drop sender Alex Rivera'),
          findsOneWidget);

      for (final key in [
        ConversationListPane.dismissKeyFor(needsYou),
        ConversationListPane.labelKeyFor(needsYou),
        ConversationListPane.laterKeyFor(needsYou),
        ConversationListPane.dismissSenderKeyFor(needsYou),
      ]) {
        await tester.tap(find.byKey(key));
        await tester.pump();
      }

      expect(acted, [
        'dismiss:c1',
        'label:c1',
        'later:c1',
        'sender:c1',
      ]);
    });

    testWidgets('a callback the host left out is a button that is not there',
        (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        onDismiss: (_) {},
      );

      await hover(tester, rowFor(needsYou));

      expect(find.byTooltip('Mark done'), findsOneWidget);
      expect(find.byTooltip('Later'), findsNothing);
      expect(find.byTooltip('Label…'), findsNothing);
    });

    testWidgets('a sender with no name to show gets no sender action',
        (tester) async {
      final anonymous = Conversation(
        id: 'c2',
        subject: 'No sender on this one',
        state: ConversationState.needsReply,
        lastMessageAt: '2026-01-14T10:00:00',
      );
      await pump(
        tester,
        conversations: [anonymous],
        filter: InboxFilter.needsReply,
        onDismiss: (_) {},
        onDismissSender: (_) {},
      );

      await hover(tester, rowFor(anonymous));

      expect(find.byTooltip('Mark done'), findsOneWidget);
      expect(
        find.byKey(ConversationListPane.dismissSenderKeyFor(anonymous)),
        findsNothing,
      );
    });

    testWidgets('keyboard focus on the row reveals them too', (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        onDismiss: (_) {},
      );

      expect(find.byTooltip('Mark done'), findsNothing);

      // No pointer anywhere: the row takes focus by traversal, the way a
      // keyboard-first pass through the list reaches it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(find.byTooltip('Mark done'), findsOneWidget);
    });

    testWidgets('the label action expands the picker for THAT row',
        (tester) async {
      final other = _conv(
        id: 'c9',
        state: ConversationState.needsReply,
        subject: 'Renewal approval',
      );
      final applied = <String>[];
      await pump(
        tester,
        conversations: [needsYou, other],
        filter: InboxFilter.needsReply,
        labels: const [fyi],
        labelPickerFor: (c) =>
            c.id == 'c1' ? LabelPickerMode.dismiss : null,
        onApplyLabel: (c, label) => applied.add('${c.id}:${label.id}'),
        onCreateLabel: (_, _) {},
        onDismissWithoutLabel: (_) {},
        onCloseLabelPicker: (_) {},
      );

      expect(
        find.byKey(ConversationListPane.pickerKeyFor(needsYou)),
        findsOneWidget,
      );
      expect(
        find.byKey(ConversationListPane.pickerKeyFor(other)),
        findsNothing,
      );
      expect(find.text('FYI only'), findsOneWidget);

      await tester.tap(find.byKey(LabelPicker.keyFor(fyi)));
      await tester.pump();

      expect(applied, ['c1:fyi']);
    });

    testWidgets('and no picker at all while the host wired no callbacks',
        (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        labels: const [fyi],
        labelPickerFor: (_) => LabelPickerMode.dismiss,
      );

      expect(find.byType(LabelPicker), findsNothing);
    });

    testWidgets('the row card never grows an action of its own',
        (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        onDismiss: (_) {},
        onLabel: (_) {},
      );

      await hover(tester, rowFor(needsYou));

      // The buttons are outside the card: the strip is a sibling of the row,
      // never a descendant of it.
      expect(
        find.descendant(
          of: rowFor(needsYou),
          matching: find.byKey(ConversationListPane.dismissKeyFor(needsYou)),
        ),
        findsNothing,
      );
      expect(find.byKey(ConversationListPane.dismissKeyFor(needsYou)),
          findsOneWidget);
    });

    testWidgets("a word the row already wears carries the picker's ✓",
        (tester) async {
      // `l` on a row and `l` on the open thread are the same question, and
      // must offer the same answers.
      await pump(
        tester,
        conversations: [
          _conv(
            id: 'c1',
            state: ConversationState.needsReply,
            subject: 'Access to the analytics tool',
            labels: const [fyi],
          ),
        ],
        filter: InboxFilter.needsReply,
        labels: const [fyi, Label(id: 'jira', name: 'jira')],
        labelPickerFor: (_) => LabelPickerMode.label,
        onApplyLabel: (_, _) {},
        onCreateLabel: (_, _) {},
        onCloseLabelPicker: (_) {},
      );

      expect(find.text('✓ FYI only'), findsOneWidget);
      expect(find.text('jira'), findsOneWidget);
      expect(find.text('✓ jira'), findsNothing);
    });
  });

  /// The in-list quick reply's mount (entry 12f). The box itself is pinned in
  /// `quick_reply_test.dart`; these are about WHICH row has one, and that a
  /// list nobody wired one on is the list it always was.
  group('the quick reply under one row', () {
    final needsYou = _conv(
      id: 'c1',
      state: ConversationState.needsReply,
      subject: 'Access to the analytics tool',
    );
    final other = _conv(
      id: 'c9',
      state: ConversationState.needsReply,
      subject: 'Renewal approval',
    );

    testWidgets('opens for the row the host names, and no other',
        (tester) async {
      await pump(
        tester,
        conversations: [needsYou, other],
        filter: InboxFilter.needsReply,
        quickReplyFor: (c) => c.id == 'c1' ? const QuickReply() : null,
        onQuickReplySend: (_, _) {},
        onCloseQuickReply: (_) {},
      );

      expect(
        find.byKey(ConversationListPane.quickReplyKeyFor(needsYou)),
        findsOneWidget,
      );
      expect(
        find.byKey(ConversationListPane.quickReplyKeyFor(other)),
        findsNothing,
      );
      // The sender comes off the thread, not from the host.
      expect(find.text('Reply to Alex Rivera'), findsOneWidget);
    });

    testWidgets('a send carries the row it was typed under', (tester) async {
      final sent = <String>[];
      await pump(
        tester,
        conversations: [needsYou, other],
        filter: InboxFilter.needsReply,
        quickReplyFor: (c) => c.id == 'c9' ? const QuickReply() : null,
        onQuickReplySend: (c, body) => sent.add('${c.id}:$body'),
        onCloseQuickReply: (_) {},
      );

      await tester.enterText(find.byKey(QuickReplyBox.fieldKey), 'On it.');
      await tester.pump();
      await tester.tap(find.byKey(QuickReplyBox.sendKey));
      await tester.pump();

      expect(sent, ['c9:On it.']);
    });

    testWidgets('and so does the close', (tester) async {
      final closed = <String>[];
      await pump(
        tester,
        conversations: [needsYou],
        filter: InboxFilter.needsReply,
        quickReplyFor: (_) => const QuickReply(),
        onQuickReplySend: (_, _) {},
        onCloseQuickReply: (c) => closed.add(c.id),
      );

      await tester.tap(find.byKey(QuickReplyBox.cancelKey));
      await tester.pump();

      expect(closed, ['c1']);
    });

    testWidgets('a host that wired no send path draws no box', (tester) async {
      await pump(
        tester,
        conversations: [needsYou],
        filter: InboxFilter.needsReply,
        quickReplyFor: (_) => const QuickReply(),
      );

      expect(find.byType(QuickReplyBox), findsNothing);
      // And the row is the row it always was.
      expect(find.text('Access to the analytics tool'), findsOneWidget);
    });

    testWidgets('the box is outside the card, like every other row action',
        (tester) async {
      await pump(
        tester,
        conversations: [needsYou],
        filter: InboxFilter.needsReply,
        quickReplyFor: (_) => const QuickReply(),
        onQuickReplySend: (_, _) {},
        onCloseQuickReply: (_) {},
      );

      expect(
        find.descendant(
          of: find.byType(ConversationRow),
          matching: find.byType(QuickReplyBox),
        ),
        findsNothing,
      );
      expect(find.byType(QuickReplyBox), findsOneWidget);
    });

    testWidgets('a picker open on the same row sits under the box',
        (tester) async {
      await pump(
        tester,
        conversations: [needsYou],
        filter: InboxFilter.needsReply,
        labels: const [Label(id: 'fyi', name: 'FYI only')],
        labelPickerFor: (_) => LabelPickerMode.label,
        onApplyLabel: (_, _) {},
        onCreateLabel: (_, _) {},
        onCloseLabelPicker: (_) {},
        quickReplyFor: (_) => const QuickReply(),
        onQuickReplySend: (_, _) {},
        onCloseQuickReply: (_) {},
      );

      final box = tester.getTopLeft(find.byType(QuickReplyBox)).dy;
      final picker = tester.getTopLeft(find.byType(LabelPicker)).dy;
      expect(box, lessThan(picker));
    });
  });

  /// The session's own line (entry 12g). The host counts; the pane draws.
  group('the triage progress line', () {
    final rows = [_conv(id: 'c1', state: ConversationState.needsReply)];

    testWidgets('says how much of the pile was the reader\'s', (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        progress: (cleared: 12, total: 60),
      );

      expect(find.text('12 of 60 cleared'), findsOneWidget);
    });

    testWidgets('a session that has cleared nothing has nothing to report',
        (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        progress: (cleared: 0, total: 60),
      );

      expect(find.byKey(ConversationListPane.progressKey), findsNothing);
    });

    testWidgets('and no count at all leaves the list as it was', (tester) async {
      await pump(tester, conversations: rows, filter: InboxFilter.needsReply);

      expect(find.byKey(ConversationListPane.progressKey), findsNothing);
      expect(find.text('NEEDS REPLY'), findsOneWidget);
    });

    testWidgets('it sits above the first section header', (tester) async {
      await pump(
        tester,
        conversations: rows,
        filter: InboxFilter.needsReply,
        progress: (cleared: 1, total: 4),
      );

      final line = tester.getTopLeft(find.text('1 of 4 cleared')).dy;
      final header = tester.getTopLeft(find.text('NEEDS REPLY')).dy;
      expect(line, lessThan(header));
    });
  });

  // The selection gutter (12c): drawn by the pane, owned by the host.
  group('the selection gutter', () {
    final rows = [
      _conv(id: 'a', subject: 'Homepage copy'),
      _conv(id: 'b', subject: 'Invoice 4471'),
    ];
    final opened = <String>[];
    final toggles = <(String, bool)>[];

    setUp(() {
      opened.clear();
      toggles.clear();
    });

    Future<void> pumpGutter(
      WidgetTester tester, {
      Set<({String source, String key})> checked = const {},
      bool wired = true,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ConversationListPane(
              sources: const ['email'],
              filter: InboxFilter.open,
              conversations: rows,
              selectedId: null,
              onSelect: (_, id) => opened.add(id),
              sectionsOverride: [('NEEDS YOU', rows)],
              checked: checked,
              onToggleChecked: wired
                  ? (c, {required range}) => toggles.add((c.id, range))
                  : null,
            ),
          ),
        ));

    testWidgets('an unwired host gets the list it always got', (tester) async {
      await pumpGutter(tester, wired: false);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('once anything is ticked every row shows its box',
        (tester) async {
      await pumpGutter(tester, checked: {(source: 'email', key: 'a')});

      final a = tester.widget<Checkbox>(
        find.byKey(ConversationListPane.checkKeyFor(rows[0])),
      );
      final b = tester.widget<Checkbox>(
        find.byKey(ConversationListPane.checkKeyFor(rows[1])),
      );
      expect(a.value, isTrue);
      expect(b.value, isFalse);

      await tester.tap(find.byKey(ConversationListPane.checkKeyFor(rows[1])));
      expect(toggles, [('b', false)]);
    });

    testWidgets('a Shift-click on a card is a range and does not open it',
        (tester) async {
      await pumpGutter(tester, checked: {(source: 'email', key: 'a')});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Invoice 4471'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(toggles, [('b', true)]);
      expect(opened, isEmpty);

      await tester.tap(find.text('Invoice 4471'));
      expect(opened, ['b']);
    });
  });
}
