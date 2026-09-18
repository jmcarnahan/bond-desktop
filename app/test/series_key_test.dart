import 'package:bond_inbox/services/conversation_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of the normaliser table: two subjects and whether they are issues
/// of one recurring series.
typedef SeriesCase = ({String name, String a, String b, bool same});

/// The pre-pass groups threads by this key alone, so the table is the rule:
/// what varies between two issues of a series is folded, everything else
/// keeps them apart.
const List<SeriesCase> cases = [
  (
    name: 'an ISO date varies, the markers do not',
    a: 'Re: Weekly digest 2026-09-14',
    b: 'Fwd: weekly digest 2026-09-21',
    same: true,
  ),
  (
    name: 'an issue number after a hash',
    a: 'Invoice #4412',
    b: 'Invoice #4413',
    same: true,
  ),
  (
    name: 'a ticket id',
    a: 'OPS-118: build failed',
    b: 'OPS-204: build failed',
    same: true,
  ),
  (
    name: 'a wordy date, abbreviated against full with a year',
    a: 'Sept 3 standup notes',
    b: 'September 10, 2026 standup notes',
    same: true,
  ),
  (
    name: 'a bare digit run',
    a: 'Budget review 2',
    b: 'Budget review 3',
    same: true,
  ),
  (
    // The fold replaces a digit run, it does not delete it, so an issue that
    // never carried a number is its own key. Three numbered issues are still
    // a series; a lone unnumbered one joining them would widen every key by
    // a token and merge one-off subjects into whatever series shares a word.
    name: 'an unnumbered issue is not an issue of the numbered series',
    a: 'Budget review',
    b: 'Budget review 2',
    same: false,
  ),
  (
    name: 'two different subjects stay apart',
    a: 'Weekly ops digest',
    b: 'Quarterly finance digest',
    same: false,
  ),
  (
    name: 'the folded numbers do not make unlike subjects alike',
    a: 'Invoice #4412',
    b: 'Ticket OPS-118',
    same: false,
  ),
  (
    // The month names are spelled out in the regex rather than matched as a
    // three-letter prefix: `dec` followed by any letters swallowed `decide`,
    // and `mar` swallowed `marketing`, so two subjects that share only a
    // number folded to one key.
    name: 'a word that merely starts like a month is not a month',
    a: 'decide 5 options',
    b: 'marketing 5 ideas',
    same: false,
  ),
];

void main() {
  group('seriesKeyFor', () {
    for (final c in cases) {
      test(c.name, () {
        final ka = seriesKeyFor(c.a);
        final kb = seriesKeyFor(c.b);
        expect(ka, isNotEmpty);
        expect(kb, isNotEmpty);
        if (c.same) {
          expect(ka, kb);
        } else {
          expect(ka, isNot(kb));
        }
      });
    }

    test('an unnamed thread has no key', () {
      expect(seriesKeyFor(null), '');
      expect(seriesKeyFor(''), '');
      expect(seriesKeyFor('   '), '');
      // A subject that is nothing but markers keeps nothing, exactly as
      // stripReFw leaves it, so it can never group with another empty one.
      expect(seriesKeyFor('Re:'), '');
      expect(seriesKeyFor('Re: Fwd: '), '');
    });

    test('whitespace runs collapse to one space', () {
      expect(seriesKeyFor('  Weekly   ops    digest  '), 'weekly ops digest');
    });

    test('case does not separate two issues', () {
      expect(seriesKeyFor('WEEKLY OPS DIGEST'), seriesKeyFor('weekly ops digest'));
    });

    test('a whole date folds to one placeholder, not a word and a number', () {
      expect(seriesKeyFor('Standup notes 2026-09-14'), 'standup notes #');
      expect(seriesKeyFor('OPS-118: build failed'), '#: build failed');
    });

    test('a subject with nothing to fold comes back lower-cased only', () {
      expect(seriesKeyFor('Re: Roof replacement quote'), 'roof replacement quote');
    });

    test('a word starting like a month keeps itself and folds its number', () {
      expect(seriesKeyFor('decide 5 options'), 'decide # options');
      expect(seriesKeyFor('marketing 5 ideas'), 'marketing # ideas');
      expect(seriesKeyFor('January 5 options'), '# options');
    });

    test('an abbreviated month still folds with its full form', () {
      expect(seriesKeyFor('Sept 3rd notes'), seriesKeyFor('September 10, 2026 notes'));
      expect(seriesKeyFor('Sept 3rd notes'), '# notes');
    });
  });
}
