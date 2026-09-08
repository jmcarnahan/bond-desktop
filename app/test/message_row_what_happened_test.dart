import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The door from one message in a thread to its whole story.
///
/// Split out of `message_row_test.dart` because it is a different question
/// from how a row renders: what it pins is where the link may appear and where
/// it may not — the header of a run and nowhere else — and that a row asking
/// "why" does not fold the message the question is about.

Message _msg() => const Message(
      id: 'm1',
      outbound: false,
      fromName: 'Eric Nolan',
      fromAddress: 'eric@example.com',
      receivedAt: '2026-08-25T09:00:00',
      bodyText: 'Hello there.',
      triageStatus: 'done',
      pendingSend: false,
      actionItems: [],
      attachments: [],
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

void main() {
  group('what happened', () {
    testWidgets('the link rides on the header and never folds the row',
        (tester) async {
      var asked = 0;
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(),
        collapsible: true,
        onWhatHappened: () => asked++,
      )));

      expect(find.text('What happened'), findsOneWidget);
      expect(find.text('Hello there.'), findsOneWidget);

      await tester.tap(find.byKey(MessageRow.whatHappenedKey));
      await tester.pump();

      expect(asked, 1);
      expect(
        find.text('Hello there.'),
        findsOneWidget,
        reason: 'asking why must not collapse the message being asked about',
      );
    });

    testWidgets('no link without a handler', (tester) async {
      await tester.pumpWidget(_host(MessageRow(message: _msg())));

      expect(find.text('What happened'), findsNothing);
    });

    testWidgets('a continuation row carries no link of its own',
        (tester) async {
      // The run's header already has one, and the message it names is the
      // same message.
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(),
        showHeader: false,
        onWhatHappened: () {},
      )));

      expect(find.text('What happened'), findsNothing);
    });
  });
}
