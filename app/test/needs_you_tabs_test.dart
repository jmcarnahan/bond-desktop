import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/needs_you_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The five lenses on the Needs You pile.
///
/// Two properties matter more than any single tab: the four narrow lenses are
/// filters over the SAME ranked list, so the order never changes; and the two
/// halves of "who is waiting" are complements, so every row is on exactly one
/// of them and the counts add back up to All.

Conversation _conv({
  required String id,
  ConversationState state = ConversationState.needsReply,
  String? cta = 'Answer Dana',
  String? deadline,
  int pendingDrafts = 0,
  double? score,
  String? lastMessageAt,
  List<Label> labels = const [],
  int messages = 0,
  bool? replyExpected,
}) =>
    Conversation(
      id: id,
      state: state,
      ctaText: cta,
      attentionScore: score,
      latestDeadline: deadline,
      pendingDraftCount: pendingDrafts,
      lastMessageAt: lastMessageAt,
      labels: labels,
      messageCount: messages,
      replyExpected: replyExpected,
    );

Label _label(String id, String name) => Label(id: id, name: name);

List<String> _idsOf(List<Conversation> rows) => [for (final c in rows) c.id];

void main() {
  test('every tab has a label a pill can wear', () {
    expect(
      [for (final tab in NeedsYouTab.values) tab.label],
      [
        'All',
        'Asked of me',
        'Waiting on others',
        'Deadlines',
        'Suggested drafts',
      ],
    );
  });

  test('All leads, so arriving at the stop changes nothing', () {
    expect(NeedsYouTab.values.first, NeedsYouTab.all);
  });

  test('All is the list itself, untouched', () {
    final rows = [_conv(id: 'a'), _conv(id: 'b')];

    expect(needsYouTabRows(NeedsYouTab.all, rows), same(rows));
  });

  test('Asked of me and Waiting on others are complements of one predicate',
      () {
    final rows = [
      _conv(id: 'mine'),
      _conv(id: 'theirs', state: ConversationState.waiting),
      _conv(id: 'also-mine'),
    ];

    final asked = needsYouTabRows(NeedsYouTab.askedOfMe, rows);
    final waiting = needsYouTabRows(NeedsYouTab.waitingOnOthers, rows);

    expect(_idsOf(asked), ['mine', 'also-mine']);
    expect(_idsOf(waiting), ['theirs']);
    // Nothing on both, nothing on neither — the same rule Needs You itself
    // partitions the inbox by.
    expect(asked.length + waiting.length, rows.length);
    for (final c in rows) {
      final isWaiting = c.state != ConversationState.needsReply;
      expect(isWaiting ? waiting.contains(c) : asked.contains(c), isTrue);
    }
  });

  test('Deadlines keeps the rows whose newest inbound named a date', () {
    final rows = [
      _conv(id: 'dated', deadline: 'by Friday'),
      _conv(id: 'undated'),
      // Whitespace is not a date. Triage writes NULL for "named none", but a
      // row that came back with a blank string must not read as a deadline.
      _conv(id: 'blank', deadline: '  '),
    ];

    expect(_idsOf(needsYouTabRows(NeedsYouTab.deadlines, rows)), ['dated']);
  });

  test('Deadlines refuses plan-relative wording that names no date', () {
    // "Day 1" is day one of somebody's plan, not a date the app can stand
    // behind — a row seated on the Deadlines tab over it would print a
    // caption that reads like a promise. A phrase that ALSO carries a real
    // date keeps its seat: the ticket said when day one is.
    final rows = [
      _conv(id: 'plan', deadline: 'Day 1'),
      _conv(id: 'sprint', deadline: 'sprint 2'),
      _conv(id: 'anchored', deadline: 'Day 1 (2026-10-05)'),
      _conv(id: 'dated', deadline: 'by Friday'),
    ];

    expect(
      _idsOf(needsYouTabRows(NeedsYouTab.deadlines, rows,
          now: DateTime(2026, 9, 24))),
      ['anchored', 'dated'],
    );
  });

  test('Suggested drafts keeps the rows the model has written for', () {
    final rows = [
      _conv(id: 'drafted', pendingDrafts: 1),
      _conv(id: 'bare'),
    ];

    expect(
      _idsOf(needsYouTabRows(NeedsYouTab.suggestedDrafts, rows)),
      ['drafted'],
    );
  });

  test('every tab keeps the order it was handed', () {
    // Deliberately NOT in id order: the input is `needsYouRows`' ranking, and a
    // tab that re-sorted would reshuffle the list under a reader who only
    // pressed a pill.
    final rows = [
      _conv(id: 'c', deadline: 'Friday', pendingDrafts: 1),
      _conv(
        id: 'a',
        state: ConversationState.waiting,
        deadline: 'Monday',
        pendingDrafts: 1,
      ),
      _conv(id: 'b', deadline: 'Tuesday', pendingDrafts: 1),
    ];

    const expected = {
      NeedsYouTab.all: ['c', 'a', 'b'],
      NeedsYouTab.askedOfMe: ['c', 'b'],
      NeedsYouTab.waitingOnOthers: ['a'],
      NeedsYouTab.deadlines: ['c', 'a', 'b'],
      NeedsYouTab.suggestedDrafts: ['c', 'a', 'b'],
    };
    for (final tab in NeedsYouTab.values) {
      expect(_idsOf(needsYouTabRows(tab, rows)), expected[tab], reason: '$tab');
    }
  });

  test('an empty pile is an empty tab, never a throw', () {
    for (final tab in NeedsYouTab.values) {
      expect(needsYouTabRows(tab, const []), isEmpty, reason: '$tab');
    }
  });

  group('sortNeedsYou', () {
    test('every order has a label a menu item can wear', () {
      expect(
        [for (final sort in NeedsYouSort.values) sort.label],
        ['By priority', 'Newest first', 'Quick wins', 'Oldest first'],
      );
    });

    test('priority leads, so an install that never chose gets the ranking', () {
      expect(NeedsYouSort.values.first, NeedsYouSort.priority);
    });

    test('priority is the input itself, untouched', () {
      final rows = [
        _conv(id: 'a', lastMessageAt: '2026-09-01T09:00:00Z'),
        _conv(id: 'b', lastMessageAt: '2026-09-03T09:00:00Z'),
      ];

      expect(sortNeedsYou(NeedsYouSort.priority, rows), same(rows));
    });

    test('newest puts the latest stamp on top', () {
      final rows = [
        _conv(id: 'older', lastMessageAt: '2026-09-01T09:00:00Z'),
        _conv(id: 'newest', lastMessageAt: '2026-09-05T09:00:00Z'),
        _conv(id: 'middle', lastMessageAt: '2026-09-03T09:00:00Z'),
      ];

      expect(
        _idsOf(sortNeedsYou(NeedsYouSort.newest, rows)),
        ['newest', 'middle', 'older'],
      );
    });

    test('and is stable, so the ranking still shows through a tie', () {
      // Dart's own sort is not stable. Two threads whose newest message landed
      // in the same second must stay in the order the ranking put them, or the
      // list would reshuffle between reads for no reason a reader could see.
      final rows = [
        for (var i = 0; i < 8; i++)
          _conv(id: 'c$i', lastMessageAt: '2026-09-03T09:00:00Z'),
      ];

      expect(
        _idsOf(sortNeedsYou(NeedsYouSort.newest, rows)),
        _idsOf(rows),
      );
    });

    test('a row with no stamp sorts last, not first', () {
      final rows = [
        _conv(id: 'undated', lastMessageAt: null),
        _conv(id: 'blank', lastMessageAt: ''),
        _conv(id: 'dated', lastMessageAt: '2026-09-01T09:00:00Z'),
      ];

      expect(
        _idsOf(sortNeedsYou(NeedsYouSort.newest, rows)),
        ['dated', 'undated', 'blank'],
      );
    });

    test('and never drops one — the badge over the section counts these', () {
      final rows = [
        _conv(id: 'a', lastMessageAt: '2026-09-01T09:00:00Z'),
        _conv(id: 'b'),
        _conv(id: 'c', lastMessageAt: '2026-09-05T09:00:00Z'),
      ];

      for (final sort in NeedsYouSort.values) {
        final out = sortNeedsYou(sort, rows);
        expect(out, hasLength(rows.length), reason: '$sort');
        expect(_idsOf(out)..sort(), ['a', 'b', 'c'], reason: '$sort');
      }
    });

    test('an empty pile is an empty pile in either order', () {
      for (final sort in NeedsYouSort.values) {
        expect(sortNeedsYou(sort, const []), isEmpty, reason: '$sort');
      }
    });

    group('the two session orders', () {
      test('oldest is the clock run backwards, undated still last', () {
        final rows = [
          _conv(id: 'newest', lastMessageAt: '2026-09-05T09:00:00Z'),
          _conv(id: 'undated'),
          _conv(id: 'older', lastMessageAt: '2026-09-01T09:00:00Z'),
          _conv(id: 'middle', lastMessageAt: '2026-09-03T09:00:00Z'),
        ];

        expect(
          _idsOf(sortNeedsYou(NeedsYouSort.oldest, rows)),
          ['older', 'middle', 'newest', 'undated'],
        );
      });

      test('and is stable through a tie, like newest', () {
        final rows = [
          for (var i = 0; i < 8; i++)
            _conv(id: 'c$i', lastMessageAt: '2026-09-03T09:00:00Z'),
        ];

        expect(_idsOf(sortNeedsYou(NeedsYouSort.oldest, rows)), _idsOf(rows));
      });

      test('quick wins rise, and each half keeps the ranking it came in with',
          () {
        final rows = [
          _conv(id: 'long-ask', messages: 20),
          // No ask on it and short: the shape of a thread that clears in a
          // line.
          _conv(id: 'short', cta: null, messages: 2),
          _conv(id: 'other-ask', messages: 9),
          // The model said outright that no reply is expected, so its length
          // does not matter.
          _conv(id: 'no-reply', messages: 30, replyExpected: false),
        ];

        expect(
          _idsOf(sortNeedsYou(NeedsYouSort.quickWins, rows)),
          ['short', 'no-reply', 'long-ask', 'other-ask'],
        );
      });

      test('a thread past the message ceiling is not a quick win', () {
        expect(
          isQuickWin(_conv(id: 'a', cta: null, messages: quickWinMessages)),
          isTrue,
        );
        expect(
          isQuickWin(_conv(id: 'b', cta: null, messages: quickWinMessages + 1)),
          isFalse,
        );
      });

      test('an ask on a short thread is still an ask', () {
        expect(isQuickWin(_conv(id: 'a', cta: 'Answer Dana', messages: 1)),
            isFalse);
        // Whitespace is not an ask.
        expect(isQuickWin(_conv(id: 'b', cta: '   ', messages: 1)), isTrue);
      });
    });
  });

  group('needsYouLabelRows', () {
    test('nothing picked is the pile itself, untouched', () {
      final rows = [_conv(id: 'a'), _conv(id: 'b')];

      expect(needsYouLabelRows(null, rows), same(rows));
      expect(needsYouLabelRows('', rows), same(rows));
    });

    test('a label keeps the rows filed under it, in the order they came', () {
      final legal = _label('legal', 'Waiting on legal');
      final rows = [
        _conv(id: 'c', labels: [legal]),
        _conv(id: 'a'),
        _conv(id: 'b', labels: [_label('jira', 'Jira update'), legal]),
      ];

      expect(_idsOf(needsYouLabelRows('legal', rows)), ['c', 'b']);
    });

    test('and a label nothing carries narrows to nothing, never a throw', () {
      // The label was deleted while its pill was pressed. An empty tab is the
      // honest answer; the tab's own empty sentence is what the reader reads.
      final rows = [_conv(id: 'a', labels: [_label('jira', 'Jira update')])];

      expect(needsYouLabelRows('gone', rows), isEmpty);
    });
  });

  group('NeedsYouLabelFilter', () {
    Future<void> pump(
      WidgetTester tester, {
      List<Label> labels = const [],
      String? selected,
      ValueChanged<String?>? onSelected,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: NeedsYouLabelFilter(
              labels: labels,
              selectedLabelId: selected,
              onLabelSelected: onSelected,
            ),
          ),
        ));

    testWidgets('an owner with no labels gets no row at all', (tester) async {
      await pump(tester);

      // Additive in the strict sense: the Needs You header is exactly what it
      // was before labels existed.
      expect(find.byKey(NeedsYouLabelFilter.rowKey), findsNothing);
    });

    testWidgets('one pill per word, read by the word', (tester) async {
      await pump(tester, labels: [
        _label('jira', 'Jira update'),
        _label('legal', 'Waiting on legal'),
      ]);

      expect(find.byKey(NeedsYouLabelFilter.rowKey), findsOneWidget);
      expect(find.text('Jira update'), findsOneWidget);
      expect(find.text('Waiting on legal'), findsOneWidget);
    });

    testWidgets('a press selects, and a second press on it clears',
        (tester) async {
      final picked = <String?>[];
      await pump(
        tester,
        labels: [_label('jira', 'Jira update')],
        onSelected: picked.add,
      );

      await tester.tap(find.byKey(NeedsYouLabelFilter.pillKeyFor('jira')));
      await tester.pump();

      expect(picked, ['jira']);

      // The pill is pressed now, which the host reports back as the selection.
      await pump(
        tester,
        labels: [_label('jira', 'Jira update')],
        selected: 'jira',
        onSelected: picked.add,
      );
      await tester.tap(find.byKey(NeedsYouLabelFilter.pillKeyFor('jira')));
      await tester.pump();

      // Null, not the id again: a label filter's resting state is off, unlike
      // the five tabs beside it.
      expect(picked, ['jira', null]);
    });

    testWidgets('a host that cannot act leaves the pills inert',
        (tester) async {
      await pump(tester, labels: [_label('jira', 'Jira update')]);

      await tester.tap(find.byKey(NeedsYouLabelFilter.pillKeyFor('jira')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  test('every tab has an empty sentence of its own', () {
    final sentences = {for (final tab in NeedsYouTab.values) tab.emptyText};
    expect(sentences, hasLength(NeedsYouTab.values.length));
    for (final s in sentences) {
      expect(s, endsWith('.'));
      expect(s, isNot(contains('_')));
    }
    expect(NeedsYouTab.all.emptyText, 'Nothing needs you right now.');
  });
}
