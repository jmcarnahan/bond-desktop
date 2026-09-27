import 'package:bond_inbox/widgets/mention_navigator.dart';
import 'package:bond_inbox/widgets/triage_intents.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The navigator under an `Actions` that records which intents reached it, the
/// arrangement every triage button ships under.
Widget _host(Widget child, List<String> invoked) {
  return MaterialApp(
    home: Scaffold(
      body: Actions(
        actions: {
          NextMentionIntent: CallbackAction<NextMentionIntent>(
            onInvoke: (_) {
              invoked.add('next');
              return null;
            },
          ),
          PreviousMentionIntent: CallbackAction<PreviousMentionIntent>(
            onInvoke: (_) {
              invoked.add('previous');
              return null;
            },
          ),
        },
        child: child,
      ),
    ),
  );
}

void main() {
  group('labelFor', () {
    test('the count alone before the reader has stepped', () {
      expect(MentionNavigator.labelFor(3, null), '@ You · 3');
    });

    test('the position joins it once they have', () {
      expect(MentionNavigator.labelFor(3, 2), '@ You · 2 of 3');
    });

    test('one mention still says one', () {
      expect(MentionNavigator.labelFor(1, 1), '@ You · 1 of 1');
    });
  });

  group('MentionNavigator', () {
    testWidgets('draws the count and both arrows', (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 3), invoked),
      );

      expect(find.byKey(MentionNavigator.navigatorKey), findsOneWidget);
      expect(find.text('@ You · 3'), findsOneWidget);
      expect(find.byKey(MentionNavigator.nextKey), findsOneWidget);
      expect(find.byKey(MentionNavigator.previousKey), findsOneWidget);
    });

    testWidgets('a thread with no mentions draws no control at all',
        (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 0), invoked),
      );

      // Not `@ You · 0`: a counter that counts to nothing still has to be read
      // before it says there is nothing to press.
      expect(find.byKey(MentionNavigator.navigatorKey), findsNothing);
      expect(find.textContaining('@ You'), findsNothing);
    });

    testWidgets('the arrows invoke the triage intents and nothing else',
        (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 3, position: 2), invoked),
      );

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await tester.pump();
      expect(invoked, ['next']);

      await tester.tap(find.byKey(MentionNavigator.previousKey));
      await tester.pump();
      expect(invoked, ['next', 'previous']);
    });

    testWidgets('the position shows where in the walk the reader stands',
        (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 3, position: 2), invoked),
      );
      expect(find.text('@ You · 2 of 3'), findsOneWidget);
    });

    testWidgets('at the last mention the forward arrow is disabled',
        (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 3, position: 3), invoked),
      );

      final next = tester.widget<IconButton>(
        find.byKey(MentionNavigator.nextKey),
      );
      expect(next.onPressed, isNull);
      // And back is still live, which is how the reader gets out again.
      final back = tester.widget<IconButton>(
        find.byKey(MentionNavigator.previousKey),
      );
      expect(back.onPressed, isNotNull);

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await tester.pump();
      expect(invoked, isEmpty);
    });

    testWidgets('at the first mention the back arrow is disabled',
        (tester) async {
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 3, position: 1), invoked),
      );

      expect(
        tester
            .widget<IconButton>(find.byKey(MentionNavigator.previousKey))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(MentionNavigator.nextKey))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('before the first step both arrows are live', (tester) async {
      // Null position means the walk has not started, and either end of it is a
      // legal first stop.
      final invoked = <String>[];
      await tester.pumpWidget(
        _host(const MentionNavigator(count: 2), invoked),
      );

      await tester.tap(find.byKey(MentionNavigator.previousKey));
      await tester.pump();
      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await tester.pump();
      expect(invoked, ['previous', 'next']);
    });

    testWidgets('with nothing handling the intents a press does nothing',
        (tester) async {
      // A host that wired no transcript gets a control that is honest about it
      // rather than one that throws under a finger.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MentionNavigator(count: 2)),
        ),
      );

      await tester.tap(find.byKey(MentionNavigator.nextKey));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
