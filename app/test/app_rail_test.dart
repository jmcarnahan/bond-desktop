import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String? who,
  String? subject,
  ConversationState state = ConversationState.waiting,
  String? cta,
}) {
  return Conversation(
    id: id,
    subject: subject,
    participants: who == null ? const [] : [Participant(name: who)],
    state: state,
    ctaText: cta,
  );
}

/// The rail is 260 wide by design, so the host must hand it loose width —
/// a Scaffold body's tight constraints would stretch it and hide a
/// regression in the row layout.
Widget _host(Widget rail) => MaterialApp(
      home: Scaffold(
        body: Row(children: [rail, const Expanded(child: SizedBox())]),
      ),
    );

void main() {
  group('needsYouRows', () {
    test('includes anything awaiting a reply', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });

    test('includes a waiting thread the model left an ask on', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.waiting, cta: 'Send the doc'),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });

    test('excludes a done thread even with an ask on it', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.done, cta: 'Send the doc'),
      ]);
      expect(rows, isEmpty);
    });

    test('excludes a waiting thread with no ask', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.waiting),
      ]);
      expect(rows, isEmpty);
    });

    test('preserves input order', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply),
        _conv(id: 'b', state: ConversationState.waiting),
        _conv(id: 'c', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['a', 'c']);
    });
  });

  group('conversationRows', () {
    test('drops done threads and keeps the rest in order', () {
      final rows = conversationRows([
        _conv(id: 'a', state: ConversationState.needsReply),
        _conv(id: 'b', state: ConversationState.done),
        _conv(id: 'c', state: ConversationState.waiting),
      ]);
      expect(rows.map((c) => c.id), ['a', 'c']);
    });
  });

  group('railTitleFor', () {
    test('prefers the first participant', () {
      expect(
        railTitleFor(_conv(id: 'a', who: 'Eric Nolan', subject: 'Rate sheet')),
        'Eric Nolan',
      );
    });

    test('falls back to the subject, reply prefixes stripped', () {
      expect(railTitleFor(_conv(id: 'a', subject: 're: re: foo')), 'foo');
      expect(railTitleFor(_conv(id: 'a', subject: 'FWD: Re: Closing')),
          'Closing');
    });

    test('is a placeholder when there is neither', () {
      expect(railTitleFor(_conv(id: 'a')), '(no subject)');
      expect(railTitleFor(_conv(id: 'a', subject: 'Re: ')), '(no subject)');
    });
  });

  group('AppRail', () {
    final conversations = [
      _conv(id: 'a', who: 'Alice', state: ConversationState.needsReply),
      _conv(id: 'b', who: 'Bruno', state: ConversationState.waiting),
      _conv(
        id: 'c',
        who: 'Cleo',
        state: ConversationState.waiting,
        cta: 'Send the appraisal',
      ),
      _conv(id: 'd', who: 'Dev', state: ConversationState.done),
    ];

    Future<void> pumpRail(
      WidgetTester tester, {
      String? selectedId,
      RailSection? selectedSection = RailSection.needsYou,
      void Function(String)? onSelectConversation,
      void Function(RailSection)? onSelectSection,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        conversations: conversations,
        selectedId: selectedId,
        selectedSection: selectedSection,
        onSelectConversation: onSelectConversation ?? (_) {},
        onSelectSection: onSelectSection ?? (_) {},
      )));
    }

    testWidgets('renders every section header', (tester) async {
      await pumpRail(tester);

      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('STORYLINES'), findsOneWidget);
      expect(find.text('CONVERSATIONS'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);
    });

    testWidgets('the empty sections say so rather than going blank',
        (tester) async {
      await pumpRail(tester);

      expect(find.text('Suggestions arrive after processing'), findsOneWidget);
      expect(find.text('Nothing deferred yet'), findsOneWidget);
    });

    testWidgets('the Needs You badge counts what is actually waiting',
        (tester) async {
      await pumpRail(tester);

      // Alice (needs reply) and Cleo (waiting, with an ask). Bruno has no ask
      // and Dev is done.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a done thread appears in no section', (tester) async {
      await pumpRail(tester);
      expect(find.text('Dev'), findsNothing);
    });

    testWidgets('tapping a row selects that conversation', (tester) async {
      final selected = <String>[];
      await pumpRail(tester, onSelectConversation: selected.add);

      // Cleo is in Needs You and in Conversations; either one means the row.
      await tester.tap(find.text('Cleo').first);
      expect(selected, ['c']);
    });

    testWidgets('tapping a section label opens its overview', (tester) async {
      final sections = <RailSection>[];
      await pumpRail(tester, onSelectSection: sections.add);

      await tester.tap(find.text('CONVERSATIONS'));
      expect(sections, [RailSection.conversations]);
    });

    testWidgets('the chevron collapses a section without selecting it',
        (tester) async {
      final sections = <RailSection>[];
      await pumpRail(tester, onSelectSection: sections.add);

      expect(find.text('Alice'), findsNWidgets(2));

      // The first chevron belongs to Needs You.
      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(sections, isEmpty);
    });
  });
}
