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
}) =>
    Conversation(
      id: id,
      state: state,
      ctaText: cta,
      attentionScore: score,
      latestDeadline: deadline,
      pendingDraftCount: pendingDrafts,
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
}
