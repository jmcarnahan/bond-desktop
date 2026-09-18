import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_set.dart';
import 'fixtures/golden_sweep.dart';

/// The sweep replay's pure half, on invented storylines and fictional slugs.
///
/// The live run needs three servers, a hundred real messages and a registry
/// this repository does not carry, so it is `@Skip`'d and nothing inside it is
/// covered by the gate. What CAN be covered is every decision it makes around
/// the model: which gold effort an app storyline turned out to be, which
/// `storyline.id` that derives for each item, and what the whole pass tallied.
/// A change to any of those moves every number in a ledger row silently.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';

  String t(String key) => threadKeyOf('email', key);

  group('mapping a storyline to a gold effort', () {
    test('a clear plurality maps, and the minority members are the impurity',
        () {
      final gold = {
        t('a'): 'river-office-lease',
        t('b'): 'river-office-lease',
        t('c'): 'studio-website-redesign',
      };
      final mapping = mapStorylinesToSlugs(
        members: {
          'sl-1': [t('a'), t('b'), t('c')],
        },
        goldByThread: gold,
      );

      expect(mapping['sl-1'], 'river-office-lease');
      expect(purityOf([t('a'), t('b'), t('c')], gold), closeTo(2 / 3, 1e-9));
    });

    test('one member carrying a slug is not evidence — two are', () {
      final gold = {t('a'): 'river-office-lease'};

      expect(
        mapStorylinesToSlugs(
          members: {
            'sl-1': [t('a'), t('b')],
          },
          goldByThread: gold,
        )['sl-1'],
        unmappedId,
      );
      expect(
        mapStorylinesToSlugs(
          members: {
            'sl-1': [t('a'), t('b')],
          },
          goldByThread: {...gold, t('b'): 'river-office-lease'},
        )['sl-1'],
        'river-office-lease',
      );
    });

    test('below half is unmapped however many members carry the slug', () {
      // Four efforts, two threads each, one group: the top slug holds two of
      // eight, which is a group about nothing in particular.
      final gold = {
        t('a'): 'river-office-lease',
        t('b'): 'river-office-lease',
        t('c'): 'studio-website-redesign',
        t('d'): 'studio-website-redesign',
        t('e'): 'sprinkler-remediation',
        t('f'): 'sprinkler-remediation',
        t('g'): 'q3-budget',
        t('h'): 'q3-budget',
      };

      expect(
        mapStorylinesToSlugs(
          members: {'sl-1': gold.keys.toList()},
          goldByThread: gold,
        )['sl-1'],
        unmappedId,
      );
    });

    test('a group built only from threads gold files nowhere maps nowhere', () {
      const gold = {'email\na': 'none', 'email\nb': 'none', 'email\nc': 'none'};
      final threads = [t('a'), t('b'), t('c')];

      expect(
        mapStorylinesToSlugs(members: {'sl-1': threads}, goldByThread: gold)[
            'sl-1'],
        unmappedId,
      );
      // Null, not zero: there is nothing to be pure ABOUT here, and a zero
      // averaged in would report the sweep as dirtier than it was.
      expect(purityOf(threads, gold), isNull);
    });

    test('two gold efforts chained into one storyline: the minority misses',
        () {
      // The chaining failure this whole round is about. Five threads of one
      // effort and three of another land in a single group; the group IS the
      // first effort, and every thread of the second is filed wrongly.
      final gold = {
        for (final key in ['a', 'b', 'c', 'd', 'e']) t(key): 'river-office-lease',
        for (final key in ['f', 'g', 'h']) t(key): 'studio-website-redesign',
      };
      final members = {'sl-1': gold.keys.toList()};
      final mapping =
          mapStorylinesToSlugs(members: members, goldByThread: gold);

      expect(mapping['sl-1'], 'river-office-lease');
      expect(purityOf(members['sl-1']!, gold), closeTo(5 / 8, 1e-9));
    });

    test('a tie at exactly half goes to the alphabetically smaller slug', () {
      final mapping = mapStorylinesToSlugs(
        members: {
          'sl-1': [t('a'), t('b'), t('c'), t('d')],
        },
        goldByThread: {
          t('a'): 'studio-website-redesign',
          t('b'): 'studio-website-redesign',
          t('c'): 'river-office-lease',
          t('d'): 'river-office-lease',
        },
      );

      // Blind to gold and deterministic: two readings of one run must agree.
      expect(mapping['sl-1'], 'river-office-lease');
    });
  });

  group('deriving an item id', () {
    late GoldenSet set;

    setUp(() {
      set = GoldenSet.fromJson(
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>,
      );
    });

    test('a thread in no storyline derives none', () {
      final derived = deriveSweepIds(
        items: set.items,
        storylineByThread: const {},
        slugByStoryline: const {},
      );

      expect(derived.values.toSet(), {noneId});
      expect(derived, hasLength(set.items.length));
    });

    test('two items of one conversation derive the same id', () {
      // The fixture files two items under one lease thread and one under
      // another; the app files THREADS, so both items of a thread move
      // together.
      final lease = set.items
          .where((item) => item.gold.storylineId == 'river-office-lease')
          .toList();
      expect(lease, hasLength(2));

      final derived = deriveSweepIds(
        items: set.items,
        storylineByThread: {
          for (final item in lease)
            threadKeyOf(item.source, item.conversationKey): 'sl-1',
        },
        slugByStoryline: const {'sl-1': 'river-office-lease'},
      );

      for (final item in lease) {
        expect(derived[item.id], 'river-office-lease');
      }
    });

    test('a storyline that maps nowhere derives unmapped, not none', () {
      final item = set.items.first;
      final derived = deriveSweepIds(
        items: [item],
        storylineByThread: {
          threadKeyOf(item.source, item.conversationKey): 'sl-9',
        },
        slugByStoryline: const {'sl-9': unmappedId},
      );

      // Filed into junk is not filed nowhere, and the scorer has to be able to
      // tell them apart.
      expect(derived[item.id], unmappedId);
    });

    test('gold by thread prefers the item that names an effort', () {
      final byThread = goldSlugByThread(set);
      final lease = set.items
          .firstWhere((item) => item.gold.storylineId == 'river-office-lease');

      expect(byThread[threadKeyOf(lease.source, lease.conversationKey)],
          'river-office-lease');
      // Only the efforts, never `none`, reach the coverage denominators.
      expect(goldThreadsBySlug(set).containsKey(noneId), isFalse);
      expect(goldThreadsBySlug(set)['river-office-lease'], 2);
    });
  });

  group('coverage', () {
    test('an effort split across two storylines counts the bigger half', () {
      final set = GoldenSet.fromJson(
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>,
      );
      final lease = set.items
          .where((item) => item.gold.storylineId == 'river-office-lease')
          .toList();
      final keys = [
        for (final item in lease) threadKeyOf(item.source, item.conversationKey),
      ];

      final gathered = coverageBySlugOf(
        set: set,
        membership: SweepMembership(
          threadsByStoryline: {'sl-1': keys},
          storylineByThread: {for (final key in keys) key: 'sl-1'},
        ),
        slugByStoryline: const {'sl-1': 'river-office-lease'},
        goldByThread: goldSlugByThread(set),
      );
      expect(gathered['river-office-lease'], 1.0);

      final split = coverageBySlugOf(
        set: set,
        membership: SweepMembership(
          threadsByStoryline: {
            'sl-1': [keys.first],
            'sl-2': [keys.last],
          },
          storylineByThread: {keys.first: 'sl-1', keys.last: 'sl-2'},
        ),
        slugByStoryline: const {
          'sl-1': 'river-office-lease',
          'sl-2': 'river-office-lease',
        },
        goldByThread: goldSlugByThread(set),
      );
      expect(split['river-office-lease'], 0.5);
    });
  });

  group('membership arithmetic', () {
    test('the largest share is the chaining number', () {
      const membership = SweepMembership(
        threadsByStoryline: {
          'sl-1': ['email\na', 'email\nb', 'email\nc'],
          'sl-2': ['email\nd'],
        },
        storylineByThread: {
          'email\na': 'sl-1',
          'email\nb': 'sl-1',
          'email\nc': 'sl-1',
          'email\nd': 'sl-2',
        },
      );

      expect(membership.storylines, 2);
      expect(membership.filedThreads, 4);
      expect(membership.largestShare, 0.75);
    });

    test('nothing filed is a share of zero, never a division by zero', () {
      const membership = SweepMembership(
        threadsByStoryline: {},
        storylineByThread: {},
      );

      expect(membership.largestShare, 0);
    });
  });

  group('cosine bins', () {
    test('every edge lands in the bin above it', () {
      final bins = cosineBins([0.10, 0.4999, 0.50, 0.54, 0.55, 0.62, 0.65, 0.9]);

      expect(bins, [2, 2, 1, 1, 2]);
      expect(bins.length, cosineBinLabels.length);
    });

    test('no pairs is five zeroes', () {
      expect(cosineBins(const []), [0, 0, 0, 0, 0]);
    });
  });

  group('the charter lint, counted', () {
    test('every storyline lands in exactly one bucket', () {
      final counts = charterLintCounts(const [
        LintCandidate(
          title: 'River office lease',
          charter: 'Signing and fitting out the second-floor suite.',
          participants: ['Dana Whitfield'],
        ),
        LintCandidate(
          title: 'Miscellaneous',
          charter: 'Things that did not fit.',
          participants: ['Dana Whitfield'],
        ),
        LintCandidate(
          title: 'Dana Whitfield',
          charter: 'Threads with Dana.',
          participants: ['Dana Whitfield'],
        ),
        LintCandidate(
          title: 'Invoices',
          charter: 'Invoices and receipts.',
          participants: ['Dana Whitfield'],
        ),
      ]);

      expect(counts, {
        'clean': 1,
        'placeholder': 1,
        'person': 1,
        'category': 1,
      });
      expect(counts.values.fold(0, (a, b) => a + b), 4);
    });
  });

  group('the tally', () {
    SweepTally tally({
      Map<String, double?> purity = const {'sl-1': 1.0, 'sl-2': 0.5},
      Map<String, double> coverage = const {'river-office-lease': 0.5},
      Map<String, int> forbidden = const {'studio-website-redesign': 2},
    }) =>
        SweepTally(
          formed: 2,
          tombstoned: 3,
          lintRejected: 0,
          incoherent: 0,
          purityByStoryline: purity,
          coverageBySlug: coverage,
          largestShare: 0.4,
          correctPositives: 7,
          forbiddenByAnti: forbidden,
          unmapped: 4,
          filedNowhere: 11,
          callsByKind: const {'storyline_name': 2, 'storyline_membership': 9},
          callsPerPass: const [7, 4],
          wallPerPassMs: const [1200, 900],
          cosineBins: const [0, 1, 2, 3, 4],
          lintCounts: const {
            'clean': 2,
            'placeholder': 0,
            'person': 0,
            'category': 0,
          },
        );

    test('the means are over the entries that have one', () {
      expect(tally().purityMean, closeTo(0.75, 1e-9));
      expect(tally().coverageMean, closeTo(0.5, 1e-9));
      expect(tally(purity: const {}, coverage: const {}).purityMean, 0);
      expect(tally(purity: const {}, coverage: const {}).coverageMean, 0);
    });

    test('a storyline with no gold carrier is listed but not averaged', () {
      final mixed = tally(
        purity: const {'sl-1': 1.0, 'sl-2': 0.5, 'sl-3': null},
      );

      // Three groups formed, two of them have anything to say about purity.
      expect(mixed.purityMean, closeTo(0.75, 1e-9));
      expect(mixed.purityWithCarrier, 2);
      expect(mixed.purityByStoryline, hasLength(3));
      expect(
        (mixed.toJson()['purity']! as Map)['by_storyline'],
        {'sl-1': 1.0, 'sl-2': 0.5, 'sl-3': null},
      );
      expect((mixed.toJson()['purity']! as Map)['with_carrier'], 2);
      expect(mixed.table(), contains('purity mean 75% over 2 of 3 storylines'));
    });

    test('forbidden hits sum across their buckets', () {
      expect(
        tally(forbidden: const {'a-slug': 2, 'b-slug': 1}).forbiddenHits,
        3,
      );
      expect(tally(forbidden: const {}).forbiddenHits, 0);
    });

    test('the JSON carries the per-slug maps and the bins by name', () {
      final json = tally().toJson();

      expect((json['coverage']! as Map)['by_slug'],
          {'river-office-lease': 0.5});
      expect((json['forbidden']! as Map)['hits'], 2);
      expect((json['purity']! as Map)['with_carrier'], 2);
      expect(json['cosine_bins'], {
        '<0.50': 0,
        '0.50-0.55': 1,
        '0.55-0.60': 2,
        '0.60-0.65': 3,
        '>=0.65': 4,
      });
      expect(json['calls_per_pass'], [7, 4]);
    });

    test('the printed table names no slug and no storyline', () {
      final printed = tally().table();

      // The whole reason the per-slug maps live in the JSON alone: the
      // storylines this bench forms are named out of real mail, and scrollback
      // is how that leaks.
      expect(printed, isNot(contains('river-office-lease')));
      expect(printed, isNot(contains('studio-website-redesign')));
      expect(printed, isNot(contains('sl-1')));
      // What it does carry: counts, ratios and the bins' names.
      expect(printed, contains('formed 2'));
      expect(printed, contains('correct positives 7'));
      expect(printed, contains('forbidden hits 2 over 1 buckets'));
      expect(printed, contains('0.55-0.60 2'));
    });
  });
}
