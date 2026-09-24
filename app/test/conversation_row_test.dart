import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/label_chip.dart';
import 'package:bond_inbox/widgets/needs_you_reason.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a thread card says while the model is still reading it.
///
/// Words rather than a spinner, and never over the top of an answer the user
/// can already use: a row that has a CTA has something to act on whatever
/// else is still queued behind it.

final DateTime _since = DateTime.utc(2026, 8, 29, 12);
const String _afterSince = '2026-08-29T12:30:00Z';

Conversation _conv({
  String id = 'conv-1',
  String? who = 'Sarah',
  String? subject = 'Launch date',
  String? preview = 'Are we still on for Friday?',
  String? cta,
  int pending = 2,
  String? lastMessageAt = _afterSince,
  int attachmentCount = 0,
  List<Label> labels = const [],
  ConversationState? state,
  String? reason,
}) {
  return Conversation(
    id: id,
    subject: subject,
    participants: who == null ? const [] : [Participant(name: who)],
    ctaText: cta,
    state: state ??
        (cta == null
            ? ConversationState.waiting
            : ConversationState.needsReply),
    needsYouReason: reason,
    lastMessagePreview: preview,
    lastMessageAt: lastMessageAt,
    aiPendingCount: pending,
    attachmentCount: attachmentCount,
    labels: labels,
  );
}

Label _label(String name, {String? tone}) =>
    Label(id: name.toLowerCase().replaceAll(' ', '-'), name: name, tone: tone);

/// Loose width, like the list gives it — a Scaffold body's tight constraints
/// would hide a regression in the row's own layout.
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Row(children: [SizedBox(width: 420, child: child)]),
      ),
    );

Opacity? _opacityOver(WidgetTester tester, String text) {
  final matches = tester.widgetList<Opacity>(
    find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
  );
  return matches.isEmpty ? null : matches.first;
}

void main() {
  testWidgets('a thread the model is still reading says so', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    expect(find.text('thinking…'), findsOneWidget);
  });

  testWidgets('a thread nothing is queued against says nothing',
      (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(pending: 0),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    expect(find.text('thinking…'), findsNothing);
  });

  testWidgets('a host that never opted in shows nothing, busy or not',
      (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(pending: 5),
      selected: false,
      onTap: () {},
    )));

    expect(find.text('thinking…'), findsNothing);
  });

  testWidgets('the preview dims while there is no answer yet', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    expect(_opacityOver(tester, 'Are we still on for Friday?')?.opacity, 0.55);
  });

  testWidgets('a CTA is never dimmed — it is already useful', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(cta: 'Confirm Friday'),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    // Still working, still says so — but the line the user can act on reads
    // at full strength.
    expect(find.text('thinking…'), findsOneWidget);
    expect(_opacityOver(tester, 'Confirm Friday'), isNull);
  });

  testWidgets('a settled row keeps its preview at full strength',
      (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(pending: 0),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    expect(_opacityOver(tester, 'Are we still on for Friday?'), isNull);
  });

  testWidgets('nothing on the row animates', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(),
      selected: false,
      onTap: () {},
      processingSince: _since,
    )));

    // A permanently-animating indicator would mean no test in the suite that
    // renders a list could ever call pumpAndSettle again.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('a thread carrying files says how many', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(attachmentCount: 3),
      selected: false,
      onTap: () {},
    )));

    expect(find.text('📎 3'), findsOneWidget);
  });

  testWidgets('and one carrying none says nothing', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(),
      selected: false,
      onTap: () {},
    )));

    expect(find.textContaining('📎'), findsNothing);
  });

  testWidgets('a caption replaces the second line the row would draw itself',
      (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(cta: 'Confirm the launch date'),
      selected: false,
      onTap: () {},
      caption: 'Deadline · by Friday',
    )));

    // On a list the reader picked BECAUSE every row has a date on it, the date
    // in the sender's words is worth more than another copy of the ask — which
    // the title already carries.
    expect(find.text('Deadline · by Friday'), findsOneWidget);
    expect(find.text('Confirm the launch date'), findsNothing);
  });

  testWidgets('and it beats the preview on a row with no ask', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(),
      selected: false,
      onTap: () {},
      caption: 'Deadline · end of month',
    )));

    expect(find.text('Deadline · end of month'), findsOneWidget);
    expect(find.text('Are we still on for Friday?'), findsNothing);
  });

  testWidgets('no caption leaves the ordinary row alone', (tester) async {
    await tester.pumpWidget(_host(ConversationRow(
      conversation: _conv(cta: 'Confirm the launch date'),
      selected: false,
      onTap: () {},
    )));

    expect(find.text('Confirm the launch date'), findsOneWidget);
  });

  group('the owner\'s labels', () {
    /// The chip one label is drawn as, read by id rather than counted — the
    /// house rule, and the only way this file can tell a tint from a tint.
    BondChip chipFor(WidgetTester tester, String id) =>
        tester.widget<BondChip>(find.byKey(labelChipKey(id)));

    testWidgets('a thread nobody has filed draws the row it always drew',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(),
        selected: false,
        onTap: () {},
      )));

      // Not a chip, not a gap, not a `+0`: an empty vocabulary costs the row
      // nothing at all.
      expect(find.byKey(labelChipOverflowKey), findsNothing);
      expect(find.text('0 messages'), findsOneWidget);
    });

    testWidgets('one label is one chip, wearing its own tone', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(labels: [_label('Jira update', tone: 'success')]),
        selected: false,
        onTap: () {},
      )));

      expect(find.text('Jira update'), findsOneWidget);
      expect(chipFor(tester, 'jira-update').tone, BondTone.success);
    });

    testWidgets('a label with no colour of its own reads as neutral',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(labels: [_label('Meeting response')]),
        selected: false,
        onTap: () {},
      )));

      expect(chipFor(tester, 'meeting-response').tone, BondTone.neutral);
    });

    testWidgets('and a tone this build does not know reads as neutral too',
        (tester) async {
      // Written by a later version of the app. One chip loses its tint; nothing
      // throws mid-render.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(labels: [_label('Later', tone: 'chartreuse')]),
        selected: false,
        onTap: () {},
      )));

      expect(chipFor(tester, 'later').tone, BondTone.neutral);
    });

    testWidgets('two labels both fit', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(labels: [_label('Jira'), _label('Later')]),
        selected: false,
        onTap: () {},
      )));

      expect(find.text('Jira'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.byKey(labelChipOverflowKey), findsNothing);
    });

    testWidgets('five become the first two and a +3', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(labels: [
          for (final name in const ['Jira', 'Later', 'Legal', 'Ops', 'Travel'])
            _label(name),
        ]),
        selected: false,
        onTap: () {},
      )));

      // The store's order is most-used first, so the two that survive are the
      // two words the owner actually reaches for.
      expect(find.text('Jira'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.text('Legal'), findsNothing);
      expect(find.text('+3'), findsOneWidget);
    });

    testWidgets('and the counts the row already drew are still there',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(attachmentCount: 2, labels: [_label('Legal')]),
        selected: false,
        onTap: () {},
      )));

      expect(find.text('Legal'), findsOneWidget);
      expect(find.text('📎 2'), findsOneWidget);
      expect(find.text('0 messages'), findsOneWidget);
    });
  });

  group('why the row is asking', () {
    String chipText(WidgetTester tester) =>
        tester.widget<BondChip>(find.byKey(needsYouReasonChipKey)).label!;

    testWidgets('a reason on a needs-reply thread is a chip', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.needsReply,
          reason: 'Asks you to confirm Friday.',
        ),
        selected: false,
        onTap: () {},
      )));

      expect(chipText(tester), 'Asks you to confirm Friday.');
    });

    testWidgets('the connector token reads as words, not as a token',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.needsReply,
          reason: 'teams_direct',
        ),
        selected: false,
        onTap: () {},
      )));

      expect(chipText(tester), 'Direct message');
      expect(find.text('teams_direct'), findsNothing);
    });

    testWidgets('a rule reason says the thread was shown DESPITE the rule',
        (tester) async {
      // The only way this token reaches a drawn row is the floor raising a
      // thread past the owner's rule, so the bare label name would claim the
      // opposite of what happened.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.needsReply,
          reason: 'label_rule:Jira update',
        ),
        selected: false,
        onTap: () {},
      )));

      expect(chipText(tester), 'Shown despite Jira update');
    });

    testWidgets('a long sentence is clamped to the width of a row',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.needsReply,
          reason: 'The sender asks you to review the attached statement of '
              'work and reply with a date before the end of the quarter.',
        ),
        selected: false,
        onTap: () {},
      )));

      final text = chipText(tester);
      expect(text.length, lessThanOrEqualTo(37));
      expect(text, endsWith('…'));
      expect(text, startsWith('The sender asks you'));
    });

    testWidgets('a thread with no reason draws no chip', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(state: ConversationState.needsReply),
        selected: false,
        onTap: () {},
      )));

      expect(find.byKey(needsYouReasonChipKey), findsNothing);
    });

    testWidgets('and neither does a thread that is not asking for a reply',
        (tester) async {
      // The same stored reason, on a thread the owner has answered: the words
      // explain a question nobody is asking any more.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.waiting,
          reason: 'teams_direct',
        ),
        selected: false,
        onTap: () {},
      )));

      expect(find.byKey(needsYouReasonChipKey), findsNothing);
    });

    testWidgets('the chip sits after the labels and before the counts',
        (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(
          state: ConversationState.needsReply,
          labels: [_label('Legal')],
          attachmentCount: 1,
          reason: 'teams_direct',
        ),
        selected: false,
        onTap: () {},
      )));

      final wrap = tester.widget<Wrap>(find.byType(Wrap));
      final keys = wrap.children.map((w) => w.key).toList();
      expect(
        keys.indexOf(labelChipKey('legal')),
        lessThan(keys.indexOf(needsYouReasonChipKey)),
      );
      // The counts carry no keys of their own, so their position is read off
      // what the row still says.
      expect(find.text('📎 1'), findsOneWidget);
      expect(find.text('0 messages'), findsOneWidget);
    });
  });

  group('where the thread came from', () {
    testWidgets('a host that cannot say draws the row it always drew',
        (tester) async {
      // `ownerDomains` defaults to empty, so every call site that existed
      // before the external mark keeps the row it had — which is the whole
      // reason the prop is optional. `external_tint_test` holds the other side:
      // what a host that CAN say gets.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(),
        selected: false,
        onTap: () {},
      )));

      expect(find.byKey(ConversationRow.externalStripeKey), findsNothing);
      expect(find.text('External'), findsNothing);
      expect(find.text('0 messages'), findsOneWidget);
    });
  });
}
