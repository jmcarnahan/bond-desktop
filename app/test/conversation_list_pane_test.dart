import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String source = 'email',
  String subject = 'Homepage copy',
  ConversationState state = ConversationState.done,
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
      expect(find.byTooltip('Dismiss'), findsNothing);
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
      expect(find.byTooltip('Dismiss'), findsNothing);

      await hover(tester, rowFor(needsYou));

      expect(find.byTooltip('Dismiss'), findsOneWidget);
      expect(find.byTooltip('Label…'), findsOneWidget);
      expect(find.byTooltip('Later'), findsOneWidget);
      // Short on the button, the whole sender in the tooltip.
      expect(find.byTooltip('Dismiss everything from Alex Rivera'),
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

      expect(find.byTooltip('Dismiss'), findsOneWidget);
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

      expect(find.byTooltip('Dismiss'), findsOneWidget);
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

      expect(find.byTooltip('Dismiss'), findsNothing);

      // No pointer anywhere: the row takes focus by traversal, the way a
      // keyboard-first pass through the list reaches it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(find.byTooltip('Dismiss'), findsOneWidget);
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
  });
}
