import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/needs_you_tabs.dart';
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
}) =>
    Conversation(
      id: id,
      state: state,
      ctaText: cta,
      attentionScore: score,
      latestDeadline: deadline,
      pendingDraftCount: pendingDrafts,
      lastMessageAt: lastMessageAt,
    );

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
      expect(isWaitingRow(c) ? waiting.contains(c) : asked.contains(c), isTrue);
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
        ['By priority', 'Newest first'],
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
