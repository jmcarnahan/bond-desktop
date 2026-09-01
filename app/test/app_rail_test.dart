import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Storyline _storyline({
  required String id,
  String title = 'Website redesign',
  String status = 'active',
  int memberCount = 2,
  int openCount = 0,
}) {
  return Storyline(
    id: id,
    title: title,
    status: status,
    memberCount: memberCount,
    openCount: openCount,
  );
}

Conversation _conv({
  required String id,
  String? who,
  String? subject,
  ConversationState state = ConversationState.waiting,
  String? cta,
  String? bucket,
  double? score,
  String? lastMessageAt,
}) {
  return Conversation(
    id: id,
    subject: subject,
    participants: who == null ? const [] : [Participant(name: who)],
    state: state,
    ctaText: cta,
    bucket: bucket,
    attentionScore: score,
    lastMessageAt: lastMessageAt,
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

    test('preserves input order among equals', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply),
        _conv(id: 'b', state: ConversationState.waiting),
        _conv(id: 'c', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['a', 'c']);
    });

    test('excludes anything deferred to Later', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply, bucket: 'later'),
        _conv(id: 'b', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['b']);
    });

    test('sorts needs-reply first, then by score', () {
      final rows = needsYouRows([
        _conv(id: 'quiet', state: ConversationState.needsReply, score: 0.4),
        _conv(
          id: 'loud-waiting',
          state: ConversationState.waiting,
          cta: 'ask',
          score: 1.9,
        ),
        _conv(id: 'loud', state: ConversationState.needsReply, score: 1.5),
      ]);
      // A waiting thread never outranks a reply the LO owes, however loudly
      // it scores.
      expect(rows.map((c) => c.id), ['loud', 'quiet', 'loud-waiting']);
    });

    test('ties keep input order rather than shuffling between reads', () {
      final rows = needsYouRows([
        for (final id in ['a', 'b', 'c', 'd', 'e'])
          _conv(id: id, state: ConversationState.needsReply, score: 1),
      ]);
      expect(rows.map((c) => c.id), ['a', 'b', 'c', 'd', 'e']);
    });

    test('a missing score sorts as zero rather than throwing', () {
      final rows = needsYouRows([
        _conv(id: 'unscored', state: ConversationState.needsReply),
        _conv(id: 'scored', state: ConversationState.needsReply, score: 1),
      ]);
      expect(rows.map((c) => c.id), ['scored', 'unscored']);
    });

    test('the threshold cuts anything below it, needs-reply included', () {
      final rows = needsYouRows(
        [
          _conv(id: 'over', state: ConversationState.needsReply, score: 0.9),
          _conv(id: 'under', state: ConversationState.needsReply, score: 0.1),
        ],
        threshold: 0.5,
      );
      expect(rows.map((c) => c.id), ['over']);
    });

    test('a row exactly at the threshold is in', () {
      final rows = needsYouRows(
        [_conv(id: 'a', state: ConversationState.needsReply, score: 0.5)],
        threshold: 0.5,
      );
      expect(rows.map((c) => c.id), ['a']);
    });
  });

  group('isWaitingRow', () {
    test('is the second block of Needs You', () {
      expect(
        isWaitingRow(_conv(id: 'a', state: ConversationState.needsReply)),
        isFalse,
      );
      expect(
        isWaitingRow(_conv(id: 'a', state: ConversationState.waiting)),
        isTrue,
      );
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

    test('drops deferred threads too — exactly one section claims each', () {
      final rows = conversationRows([
        _conv(id: 'a', state: ConversationState.needsReply),
        _conv(id: 'b', state: ConversationState.waiting, bucket: 'later'),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });
  });

  group('laterRows', () {
    test('is everything deferred and still open', () {
      final rows = laterRows([
        _conv(id: 'a', bucket: 'later'),
        _conv(id: 'b'),
        _conv(id: 'c', bucket: 'later', state: ConversationState.done),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });
  });

  group('laterDayCounts', () {
    test('groups by local day, newest day first', () {
      final rows = laterDayCounts([
        _conv(id: 'a', bucket: 'later', lastMessageAt: '2026-08-28T10:00:00'),
        _conv(id: 'b', bucket: 'later', lastMessageAt: '2026-08-28T18:00:00'),
        _conv(id: 'c', bucket: 'later', lastMessageAt: '2026-08-27T10:00:00'),
        _conv(id: 'd', lastMessageAt: '2026-08-28T10:00:00'),
      ]);
      expect(rows, [('2026-08-28', 2), ('2026-08-27', 1)]);
    });

    test('mail with an unreadable date is still counted, never dropped', () {
      // Later must never lose anything. A bad timestamp gets its own group
      // rather than an early return.
      final rows = laterDayCounts([
        _conv(id: 'a', bucket: 'later', lastMessageAt: 'wharrgarbl'),
        _conv(id: 'b', bucket: 'later'),
      ]);
      expect(rows, [('', 2)]);
    });

    test('nothing deferred is no days', () {
      expect(laterDayCounts([_conv(id: 'a')]), isEmpty);
    });
  });

  group('laterDayLabel', () {
    test('names the day and carries the count', () {
      expect(laterDayLabel('2026-01-14', 3), 'Wed, Jan 14 — 3');
    });

    test('falls back rather than rendering an empty row', () {
      expect(laterDayLabel('', 2), 'Undated — 2');
      expect(laterDayLabel('nonsense', 1), 'nonsense — 1');
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
        cta: 'Send the homepage copy',
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

  group('AppRail Later', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Conversation> conversations,
      String? selectedLaterDay,
      void Function(String)? onSelectLaterDay,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        conversations: conversations,
        selectedId: null,
        selectedSection: RailSection.later,
        selectedLaterDay: selectedLaterDay,
        laterCount: laterRows(conversations).length,
        laterDays: laterDayCounts(conversations),
        onSelectConversation: (_) {},
        onSelectSection: (_) {},
        onSelectLaterDay: onSelectLaterDay,
      )));
    }

    testWidgets('an empty pile keeps the placeholder and no badge',
        (tester) async {
      await pumpRail(tester, conversations: [_conv(id: 'a')]);

      expect(find.text('Nothing deferred yet'), findsOneWidget);
    });

    testWidgets('a day row per day, with the count in the label',
        (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
        _conv(
          id: 'b',
          who: 'Bruno',
          bucket: 'later',
          lastMessageAt: '2026-01-14T18:00:00',
        ),
        _conv(
          id: 'c',
          who: 'Cleo',
          bucket: 'later',
          lastMessageAt: '2026-01-13T10:00:00',
        ),
      ]);

      expect(find.text('Wed, Jan 14 — 2'), findsOneWidget);
      expect(find.text('Tue, Jan 13 — 1'), findsOneWidget);
      expect(find.text('Nothing deferred yet'), findsNothing);
      // The badge counts the whole pile, not the days.
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('deferred threads appear in no other section', (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          state: ConversationState.needsReply,
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
      ]);

      // Its name is nowhere: not in Needs You, not in Conversations. Only the
      // day row it was folded into.
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Wed, Jan 14 — 1'), findsOneWidget);
    });

    testWidgets('tapping a day opens its digest', (tester) async {
      final days = <String>[];
      await pumpRail(
        tester,
        conversations: [
          _conv(id: 'a', bucket: 'later', lastMessageAt: '2026-01-14T10:00:00'),
        ],
        onSelectLaterDay: days.add,
      );

      await tester.tap(find.text('Wed, Jan 14 — 1'));
      expect(days, ['2026-01-14']);
    });
  });

  group('AppRail Needs You ranking', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Conversation> conversations,
      double threshold = 0,
      void Function(RailSection)? onSelectSection,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        conversations: conversations,
        selectedId: null,
        selectedSection: RailSection.needsYou,
        attentionThreshold: threshold,
        onSelectConversation: (_) {},
        onSelectSection: onSelectSection ?? (_) {},
      )));
    }

    List<Conversation> manyNeedsReply(int n) => [
          for (var i = 0; i < n; i++)
            _conv(
              id: 'c$i',
              who: 'Person $i',
              state: ConversationState.needsReply,
              // Descending, so the rendered order is the seeded order.
              score: 2 - i * 0.01,
            ),
        ];

    testWidgets('shows at most the top seven, and says how many are left',
        (tester) async {
      await pumpRail(tester, conversations: manyNeedsReply(10));

      expect(find.text('Person 0'), findsNWidgets(2)); // Needs You + open list
      expect(find.text('Person 6'), findsNWidgets(2));
      // Person 7..9 are past the cap: only the Conversations section has them.
      expect(find.text('Person 7'), findsOneWidget);
      expect(find.text('+3 more'), findsOneWidget);
      // The badge still counts all ten. It must never flatter the workload.
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('exactly seven needs no overflow row', (tester) async {
      await pumpRail(tester, conversations: manyNeedsReply(7));
      expect(find.textContaining('more'), findsNothing);
    });

    testWidgets('the overflow row opens the section, not a thread',
        (tester) async {
      final sections = <RailSection>[];
      await pumpRail(
        tester,
        conversations: manyNeedsReply(9),
        onSelectSection: sections.add,
      );

      await tester.tap(find.text('+2 more'));
      expect(sections, [RailSection.needsYou]);
    });

    testWidgets('the threshold hides rows from Needs You but not the app',
        (tester) async {
      await pumpRail(
        tester,
        threshold: 0.5,
        conversations: [
          _conv(
            id: 'a',
            who: 'Loud',
            state: ConversationState.needsReply,
            score: 1.5,
          ),
          _conv(
            id: 'b',
            who: 'Quiet',
            state: ConversationState.needsReply,
            score: 0.1,
          ),
        ],
      );

      expect(find.text('Loud'), findsNWidgets(2));
      // Cut from Needs You, still in Conversations. Nothing is ever hidden
      // entirely by the slider.
      expect(find.text('Quiet'), findsOneWidget);
    });

    testWidgets('a waiting row renders dimmed below the needs-reply block',
        (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Owed',
          state: ConversationState.needsReply,
          score: 1,
        ),
        _conv(
          id: 'b',
          who: 'Waiting',
          state: ConversationState.waiting,
          cta: 'Send the homepage copy',
          score: 1.9,
        ),
      ]);

      // Present, and quieter than the row above it.
      expect(find.text('Waiting'), findsNWidgets(2));
      final dimmed = tester.widget<Text>(find.text('Waiting').first);
      expect(dimmed.style?.color, BondColors.onDarkMuted);

      final loud = tester.widget<Text>(find.text('Owed').first);
      expect(loud.style?.color, BondColors.onDarkPrimary);
    });
  });

  group('storylineRows', () {
    test('puts suggestions first and keeps each half in input order', () {
      final rows = storylineRows([
        _storyline(id: 'a', status: 'active'),
        _storyline(id: 'b', status: 'suggested'),
        _storyline(id: 'c', status: 'active'),
        _storyline(id: 'd', status: 'suggested'),
      ]);

      expect(rows.map((s) => s.id), ['b', 'd', 'a', 'c']);
    });
  });

  group('AppRail storylines', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Storyline> storylines,
      String? selectedStorylineId,
      void Function(String)? onSelectStoryline,
      void Function(String)? onKeepSuggestion,
      void Function(String)? onDismissSuggestion,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        conversations: const [],
        storylines: storylines,
        selectedId: null,
        selectedStorylineId: selectedStorylineId,
        selectedSection: RailSection.storylines,
        onSelectConversation: (_) {},
        onSelectSection: (_) {},
        onSelectStoryline: onSelectStoryline ?? (_) {},
        onKeepSuggestion: onKeepSuggestion ?? (_) {},
        onDismissSuggestion: onDismissSuggestion ?? (_) {},
      )));
    }

    testWidgets('an empty list keeps the placeholder', (tester) async {
      await pumpRail(tester, storylines: const []);

      expect(find.text('Suggestions arrive after processing'), findsOneWidget);
    });

    testWidgets('rows replace the placeholder', (tester) async {
      await pumpRail(tester, storylines: [_storyline(id: 'sl-1')]);

      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('Suggestions arrive after processing'), findsNothing);
    });

    testWidgets('a suggestion carries Keep and Dismiss; an active row does not',
        (tester) async {
      await pumpRail(tester, storylines: [
        _storyline(id: 'sl-1', title: 'Proposed', status: 'suggested'),
        _storyline(id: 'sl-2', title: 'Live', status: 'active'),
      ]);

      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('Keep and Dismiss fire for the row they sit on',
        (tester) async {
      final kept = <String>[];
      final dismissed = <String>[];
      await pumpRail(
        tester,
        storylines: [
          _storyline(id: 'sl-1', title: 'Proposed', status: 'suggested'),
        ],
        onKeepSuggestion: kept.add,
        onDismissSuggestion: dismissed.add,
      );

      await tester.tap(find.byIcon(Icons.check));
      await tester.tap(find.byIcon(Icons.close));

      expect(kept, ['sl-1']);
      expect(dismissed, ['sl-1']);
    });

    testWidgets('an active row badges its open count, and nothing when zero',
        (tester) async {
      await pumpRail(tester, storylines: [
        _storyline(id: 'sl-1', title: 'Busy', openCount: 3),
        _storyline(id: 'sl-2', title: 'Quiet'),
      ]);

      expect(find.text('3'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('tapping a row selects that storyline', (tester) async {
      final selected = <String>[];
      await pumpRail(
        tester,
        storylines: [_storyline(id: 'sl-1')],
        onSelectStoryline: selected.add,
      );

      await tester.tap(find.text('Website redesign'));

      expect(selected, ['sl-1']);
    });

    testWidgets('an untitled storyline still renders a row', (tester) async {
      await pumpRail(tester, storylines: [_storyline(id: 'sl-1', title: '')]);

      expect(find.text('(untitled)'), findsOneWidget);
    });
  });
}
