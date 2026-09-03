import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
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
}) {
  return Conversation(
    id: id,
    subject: subject,
    participants: who == null ? const [] : [Participant(name: who)],
    ctaText: cta,
    state: cta == null ? ConversationState.waiting : ConversationState.needsReply,
    lastMessagePreview: preview,
    lastMessageAt: lastMessageAt,
    aiPendingCount: pending,
  );
}

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
}
