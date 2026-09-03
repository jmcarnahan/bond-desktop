import 'package:bond_inbox/providers/draft_provider.dart' show PendingSend;
import 'package:bond_inbox/services/llm/draft_task.dart' show DraftOption;
import 'package:bond_inbox/theme/tokens.dart' show BondColors;
import 'package:bond_inbox/widgets/quick_replies.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The short answers under the transcript.
///
/// The bar decides nothing: a tap reports which option it was and the host
/// decides whether that is a send or a prefill. These tests pin what it draws
/// and that every affordance reports exactly once.

const DraftOption _confirm = DraftOption(
  stance: 'Confirm Friday',
  body: 'Friday works — see you then.',
);

const DraftOption _propose = DraftOption(
  stance: 'Propose Tuesday',
  body: 'Friday is tight for me. Could we say Tuesday instead?',
);

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    List<DraftOption> options = const [_confirm, _propose],
    bool armed = true,
    void Function(DraftOption)? onPick,
    VoidCallback? onReply,
    VoidCallback? onDismiss,
    PendingSend? pending,
    VoidCallback? onUndo,
    VoidCallback? onSuggest,
    bool suggesting = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QuickReplyBar(
          options: options,
          armed: armed,
          onPick: onPick ?? (_) {},
          onReply: onReply ?? () {},
          onDismiss: onDismiss,
          pending: pending,
          onUndo: onUndo,
          onSuggest: onSuggest,
          suggesting: suggesting,
        ),
      ),
    ));
    await tester.pump();
  }

  group('the cards', () {
    testWidgets('two options render both stances and both bodies',
        (tester) async {
      await pumpBar(tester);

      expect(find.text('Confirm Friday'), findsOneWidget);
      expect(find.text('Propose Tuesday'), findsOneWidget);
      expect(find.text('Friday works — see you then.'), findsOneWidget);
    });

    testWidgets('one option renders one card', (tester) async {
      await pumpBar(tester, options: const [_confirm]);

      expect(find.text('Confirm Friday'), findsOneWidget);
      expect(find.text('Propose Tuesday'), findsNothing);
    });

    testWidgets('a tap reports which option it was', (tester) async {
      final picked = <String>[];
      await pumpBar(tester, onPick: (o) => picked.add(o.stance));

      await tester.tap(find.text('Propose Tuesday'));
      await tester.pump();

      expect(picked, ['Propose Tuesday']);
    });

    testWidgets('an unarmed bar still reports the tap', (tester) async {
      // Whether a tap sends or prefills is the host's decision, not this
      // widget's — it reports the same either way.
      final picked = <String>[];
      await pumpBar(tester, armed: false, onPick: (o) => picked.add(o.stance));

      await tester.tap(find.text('Confirm Friday'));
      await tester.pump();

      expect(picked, ['Confirm Friday']);
    });

    testWidgets('and says so, so a card cannot look like a send button',
        (tester) async {
      await pumpBar(tester, armed: false);

      expect(find.text('Tap a reply to open it in the composer.'),
          findsOneWidget);
      // The icon agrees with the words: composing, not sending.
      expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.send_outlined), findsNothing);
    });

    testWidgets('an armed bar says a tap sends, and wears the send icon',
        (tester) async {
      await pumpBar(tester);

      expect(
        find.text(
            'Tap a suggestion to send it — you can undo for a few seconds.'),
        findsOneWidget,
      );
      expect(find.text('Tap a reply to open it in the composer.'),
          findsNothing);
      expect(find.byIcon(Icons.send_outlined), findsNWidgets(2));
    });

    testWidgets('the whole reply is visible — no tooltip, no truncation',
        (tester) async {
      // A tap may SEND these words, so all of them are on screen. The long
      // body must lay out unclipped rather than hide its tail behind a hover.
      const long = DraftOption(
        stance: 'Decline politely',
        body: 'Thanks so much for thinking of me — unfortunately I have a '
            'prior commitment on Friday evening that I cannot move, so I '
            'will have to miss this one. I would love to join the next '
            'dinner, and I hope you all have a wonderful time together.',
      );
      await pumpBar(tester, options: const [long]);

      expect(find.byType(Tooltip), findsNothing);
      final text = tester.widget<Text>(find.text(long.body));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets('a card lights up under the mouse', (tester) async {
      // Ink paints on the nearest Material ancestor. The bar's tile is an
      // opaque Container, so without a transparent Material of its own the
      // hover would render underneath it — set, but never seen.
      await pumpBar(tester);

      final inkWells = tester.widgetList<InkWell>(find.byType(InkWell));
      final cards = inkWells.where((w) => w.hoverColor != null).toList();
      expect(cards, hasLength(2));
      for (final card in cards) {
        expect(card.hoverColor, BondColors.primaryTint);
      }
      expect(
        find.ancestor(
          of: find.text('Confirm Friday'),
          matching: find.byWidgetPredicate(
            (w) => w is Material && w.type == MaterialType.transparency,
          ),
        ),
        findsOneWidget,
      );

      // And the mouse actually reaching a card must not throw.
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Confirm Friday')));
      await tester.pumpAndSettle();
    });
  });

  group('the way into the composer', () {
    testWidgets('Reply… is there beside the cards', (tester) async {
      var replies = 0;
      await pumpBar(tester, onReply: () => replies++);

      await tester.tap(find.text('Reply…'));
      await tester.pump();

      expect(replies, 1);
    });

    testWidgets('with no options, the bar is the Reply… affordance alone',
        (tester) async {
      // The bar is also how a thread the model wrote nothing for reaches the
      // composer.
      var replies = 0;
      await pumpBar(
        tester,
        options: const [],
        onDismiss: () {},
        onReply: () => replies++,
      );

      expect(find.text('Reply…'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tap(find.text('Reply…'));
      await tester.pump();
      expect(replies, 1);
    });

    testWidgets('the × asks before it closes the suggestions', (tester) async {
      var dismissed = 0;
      await pumpBar(tester, onDismiss: () => dismissed++);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // The first tap only asks. Suggestions are cheap to keep and gone for
      // good once thrown away, so the × owes the user a question.
      expect(dismissed, 0);
      expect(find.text('Dismiss these suggestions?'), findsOneWidget);
      // The cards the question is about stay on screen while it stands.
      expect(find.text(_confirm.body), findsOneWidget);
      expect(find.text(_propose.body), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pump();

      expect(dismissed, 1);
    });

    testWidgets('and Keep puts the caption back without closing anything',
        (tester) async {
      var dismissed = 0;
      await pumpBar(tester, onDismiss: () => dismissed++);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.tap(find.text('Keep'));
      await tester.pump();

      expect(dismissed, 0);
      expect(find.text('Dismiss these suggestions?'), findsNothing);
      expect(
        find.text('Tap a suggestion to send it — you can undo for a few '
            'seconds.'),
        findsOneWidget,
      );
    });

    testWidgets('a fresh pair is never asked about on the old one\'s behalf',
        (tester) async {
      var dismissed = 0;
      await pumpBar(tester, onDismiss: () => dismissed++);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // The model wrote two new suggestions while the question stood. They
      // are not what the user was answering.
      await pumpBar(
        tester,
        options: const [
          DraftOption(stance: 'Ask for Wednesday', body: 'Wednesday?'),
        ],
        onDismiss: () => dismissed++,
      );

      expect(find.text('Dismiss these suggestions?'), findsNothing);
      expect(dismissed, 0);
    });

    testWidgets('but the same pair in a new list is the same question',
        (tester) async {
      // `DraftState.options` mints a fresh list on every read, so an identity
      // check disarmed the question on any parent rebuild — every inbox
      // setState, every sync reload — and the × would need tapping twice for
      // no reason the user could see.
      var dismissed = 0;
      await pumpBar(tester, onDismiss: () => dismissed++);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // Fresh objects as well as a fresh list: `DraftState.options` decodes new
      // [DraftOption]s out of JSON on every read, so neither the list nor what
      // is in it survives a rebuild by identity.
      DraftOption copyOf(DraftOption option) =>
          DraftOption(stance: option.stance, body: option.body);

      await pumpBar(
        tester,
        options: [copyOf(_confirm), copyOf(_propose)],
        onDismiss: () => dismissed++,
      );

      expect(find.text('Dismiss these suggestions?'), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(dismissed, 1);
    });

    testWidgets('and is absent when the host offers no way to dismiss',
        (tester) async {
      await pumpBar(tester);

      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group('asking for a suggestion', () {
    testWidgets('is offered when there is nothing to suggest yet',
        (tester) async {
      // The un-dismiss: the × takes the cards away, and this is how they come
      // back.
      await pumpBar(tester, options: const [], onSuggest: () {});

      expect(find.text('Suggest a reply'), findsOneWidget);
    });

    testWidgets('and never beside cards that are already there',
        (tester) async {
      await pumpBar(tester, onSuggest: () {});

      expect(find.text('Suggest a reply'), findsNothing);
    });

    testWidgets('is absent when the host cannot ask for one', (tester) async {
      await pumpBar(tester, options: const []);

      expect(find.text('Reply…'), findsOneWidget);
      expect(find.text('Suggest a reply'), findsNothing);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
    });

    testWidgets('says so while one is being written, and cannot be asked twice',
        (tester) async {
      var asked = 0;
      await pumpBar(
        tester,
        options: const [],
        onSuggest: () => asked++,
        suggesting: true,
      );

      expect(find.text('Drafting…'), findsOneWidget);
      expect(find.text('Suggest a reply'), findsNothing);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Drafting…'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(asked, 0);
    });

    testWidgets('a tap asks once', (tester) async {
      var asked = 0;
      await pumpBar(tester, options: const [], onSuggest: () => asked++);

      await tester.tap(find.text('Suggest a reply'));
      await tester.pump();

      expect(asked, 1);
    });
  });

  group('a queued send', () {
    PendingSend pendingWith(String body) =>
        (body: body, sendsAt: DateTime(2026, 9, 1, 12));

    testWidgets('replaces the cards in place with the undo row',
        (tester) async {
      await pumpBar(
        tester,
        pending: pendingWith('Friday works — see you then.'),
        onUndo: () {},
      );

      // The thing being taken back sits where the thing that started it was.
      expect(find.text('Confirm Friday'), findsNothing);
      expect(find.text('Propose Tuesday'), findsNothing);
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Friday works — see you then.'), findsOneWidget);
    });

    testWidgets('Undo reports once', (tester) async {
      var undos = 0;
      await pumpBar(
        tester,
        pending: pendingWith('Friday works.'),
        onUndo: () => undos++,
      );

      await tester.tap(find.text('Undo'));
      await tester.pump();

      expect(undos, 1);
    });

    testWidgets('shows the first line only, elided', (tester) async {
      await pumpBar(
        tester,
        pending: pendingWith('Friday works.\nSee you at the office.'),
        onUndo: () {},
      );

      expect(find.text('Friday works.'), findsOneWidget);
      expect(find.textContaining('See you at the office'), findsNothing);
    });

    testWidgets('and takes over even a bar with no options', (tester) async {
      await pumpBar(
        tester,
        options: const [],
        pending: pendingWith('Friday works.'),
        onUndo: () {},
      );

      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Reply…'), findsNothing);
    });
  });
}
