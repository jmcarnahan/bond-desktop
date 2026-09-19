import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/clustering_card.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/storyline_service.dart' show StorylineTuning;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_harness.dart';
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

  group('clusters before naming', () {
    /// The three efforts these tests file under, and the thread that files
    /// nowhere. Invented slugs: the registry's own never reach a test.
    const gold = {
      'email\nk1': 'alpha-effort',
      'email\nk2': 'alpha-effort',
      'email\nk3': 'beta-effort',
      'email\nk4': noneId,
    };

    test('reports of one set are one cluster, and answered yields to the '
        'verdict', () {
      final verdictFirst = distinctClusters([
        (threads: [t('k1'), t('k2'), t('k3')], outcome: 'incoherent'),
        (threads: [t('k3'), t('k1'), t('k2')], outcome: 'answered'),
      ]);
      // The same three threads, reported in a different order by the second
      // pass, are the same cluster judged once.
      expect(verdictFirst, hasLength(1));
      expect(verdictFirst.single.outcome, 'incoherent');

      final answeredFirst = distinctClusters([
        (threads: [t('k3'), t('k1'), t('k2')], outcome: 'answered'),
        (threads: [t('k1'), t('k2'), t('k3')], outcome: 'incoherent'),
      ]);
      expect(answeredFirst, hasLength(1));
      expect(answeredFirst.single.outcome, 'incoherent');

      // Only ever answered: the tombstone predates the run and there is no
      // verdict to recover.
      final onlyAnswered = distinctClusters([
        (threads: [t('k1'), t('k2')], outcome: 'answered'),
        (threads: [t('k2'), t('k1')], outcome: 'answered'),
      ]);
      expect(onlyAnswered, hasLength(1));
      expect(onlyAnswered.single.outcome, 'answered');
    });

    test('two different sets are two clusters', () {
      final distinct = distinctClusters([
        (threads: [t('k1'), t('k2')], outcome: 'formed'),
        (threads: [t('k3'), t('k4')], outcome: 'incoherent'),
      ]);

      expect(distinct, hasLength(2));
      expect(distinct.map((c) => c.outcome), ['formed', 'incoherent']);
    });

    test('purity by outcome averages the clusters that carry gold', () {
      // `k5` is in no gold map at all, which reads the same as `none`: a
      // thread there is nothing to be pure about.
      final byOutcome = clusterPurityByOutcome(
        [
          (threads: [t('k1'), t('k2')], outcome: 'formed'),
          (threads: [t('k1'), t('k2'), t('k3')], outcome: 'incoherent'),
          (threads: [t('k4'), t('k5')], outcome: 'lint'),
        ],
        gold,
      );

      expect(byOutcome['formed']!.mean, closeTo(1.0, 1e-9));
      expect(byOutcome['formed']!.pureAt70, 1);
      expect(byOutcome['formed']!.pureAt100, 1);

      expect(byOutcome['incoherent']!.mean, closeTo(2 / 3, 1e-9));
      expect(byOutcome['incoherent']!.pureAt70, 0);
      expect(byOutcome['incoherent']!.pureAt100, 0);

      // Nothing to be pure about: counted as a cluster, averaged nowhere.
      expect(byOutcome['lint']!.clusters, 1);
      expect(byOutcome['lint']!.withCarrier, 0);
      expect(byOutcome['lint']!.mean, 0);
      expect(byOutcome['lint']!.shares, [null]);

      // The union bucket, in input order, and `thin` absent rather than zero.
      expect(byOutcome['declined']!.clusters, 2);
      expect(byOutcome['declined']!.withCarrier, 1);
      expect(byOutcome['declined']!.sizes, [3, 2]);
      expect(byOutcome.containsKey('thin'), isFalse);
      expect(byOutcome.containsKey('answered'), isFalse);
    });

    test('pureAt70 is inclusive', () {
      // Seven threads of one effort and three of another: exactly the line.
      final purity = ClusterPurity.of(
        [
          (
            threads: [for (var i = 0; i < 10; i++) t('n$i')],
            outcome: 'formed',
          ),
        ],
        {
          for (var i = 0; i < 7; i++) t('n$i'): 'alpha-effort',
          for (var i = 7; i < 10; i++) t('n$i'): 'beta-effort',
        },
      );

      expect(purity.shares.single, closeTo(0.7, 1e-9));
      expect(purity.pureAt70, 1);
      expect(purity.pureAt100, 0);
    });

    test('pair cosines split by whether the threads share an effort', () {
      const vectors = {
        'email\nk1': [1.0, 0.0],
        'email\nk2': [0.0, 1.0],
        'email\nk3': [1.0, 1.0],
        'email\nk4': [1.0, -1.0],
      };

      final pairs = pairCosinesOf(vectors: vectors, goldByThread: gold);

      // Six unordered pairs: one inside alpha, two across the two efforts,
      // three touching the thread that files nowhere.
      expect(pairs.sameEffort, hasLength(1));
      expect(pairs.crossEffort, hasLength(2));
      expect(pairs.withNone, hasLength(3));

      // Sorted keys, so the answer does not depend on insertion order.
      final reversed = <String, List<double>>{
        for (final key in vectors.keys.toList().reversed) key: vectors[key]!,
      };
      final again = pairCosinesOf(vectors: reversed, goldByThread: gold);
      expect(again.sameEffort, pairs.sameEffort);
      expect(again.crossEffort, pairs.crossEffort);
      expect(again.withNone, pairs.withNone);
    });
  });

  group('the subject overlap', () {
    test('Jaccard over the words, the stopwords and the Re: taken off', () {
      // Two words shared out of three used: the third bin's floor is 0.25 and
      // the fourth's is 0.5, so this lands in the fourth.
      final pairs = pairSubjectOverlapOf(
        subjectByThread: {
          t('a'): 'Budget review',
          t('b'): 'Re: The budget review notes',
        },
        goldByThread: {t('a'): 'alpha-effort', t('b'): 'alpha-effort'},
      );

      expect(pairs.sameEffort.single, closeTo(2 / 3, 1e-9));
      expect(overlapBins(pairs.sameEffort), [0, 0, 0, 1]);
    });

    test('identical subjects score one and disjoint ones score zero', () {
      final pairs = pairSubjectOverlapOf(
        subjectByThread: {
          t('a'): 'Budget review',
          t('b'): 'budget review',
          t('c'): 'Office lease addendum',
        },
        goldByThread: {
          t('a'): 'alpha-effort',
          t('b'): 'alpha-effort',
          t('c'): 'beta-effort',
        },
      );

      expect(pairs.sameEffort.single, closeTo(1.0, 1e-9));
      expect(pairs.crossEffort, [0.0, 0.0]);
      expect(overlapBins(pairs.crossEffort), [2, 0, 0, 0]);
    });

    test('a subject of nothing but function words has no tokens', () {
      // Which is a real subject line — "For you" and "FYI" both reduce to
      // nothing — and two of them are not the same thing as two that agree.
      expect(subjectTokens('Re: For you'), isEmpty);
      final pairs = pairSubjectOverlapOf(
        subjectByThread: {t('a'): 'Re: For you', t('b'): 'To the team'},
        goldByThread: {t('a'): 'alpha-effort', t('b'): 'alpha-effort'},
      );
      expect(pairs.sameEffort.single, 0);
    });

    test('the four bins take their edges at 0, 0.25 and 0.5', () {
      expect(overlapBins([0, 0.2, 0.24999, 0.25, 0.4, 0.5, 1.0]),
          [1, 2, 2, 2]);
    });
  });

  group('the shared people', () {
    test('counts non-owner displays, case-insensitively', () {
      final pairs = pairSharedPeopleOf(
        participantsByThread: {
          t('a'): ['Alex Rivera', 'Dana Whitfield', 'Priya Raman'],
          t('b'): ['alex rivera', 'DANA WHITFIELD', 'Priya Raman'],
          t('c'): ['Alex Rivera', 'Sam Okafor'],
        },
        goldByThread: {
          t('a'): 'alpha-effort',
          t('b'): 'alpha-effort',
          t('c'): 'beta-effort',
        },
        ownerDisplays: {'Alex Rivera'},
      );

      // Two shared, the owner not among them.
      expect(pairs.sameEffort.single, 2);
      expect(sharedPeopleBins(pairs.sameEffort), [0, 0, 1]);
      // The owner is on every thread, so the cross pairs share nobody else.
      expect(pairs.crossEffort, [0.0, 0.0]);
      expect(sharedPeopleBins(pairs.crossEffort), [2, 0, 0]);
    });

    test('without an owner every pair counts them', () {
      final pairs = pairSharedPeopleOf(
        participantsByThread: {
          t('a'): ['Alex Rivera', 'Dana Whitfield'],
          t('b'): ['Alex Rivera'],
        },
        goldByThread: {t('a'): 'alpha-effort', t('b'): 'alpha-effort'},
        ownerDisplays: const {},
      );

      expect(pairs.sameEffort.single, 1);
      expect(sharedPeopleBins(pairs.sameEffort), [0, 1, 0]);
    });

    test('a pair touching a thread gold files nowhere is its own population',
        () {
      final pairs = pairSharedPeopleOf(
        participantsByThread: {
          t('a'): ['Dana Whitfield'],
          t('b'): ['Dana Whitfield'],
        },
        goldByThread: {t('a'): 'alpha-effort', t('b'): 'none'},
        ownerDisplays: const {},
      );

      expect(pairs.sameEffort, isEmpty);
      expect(pairs.crossEffort, isEmpty);
      expect(pairs.withNone.single, 1);
    });
  });

  group('the separation', () {
    test('the points are the two shares at the bar, in whole percents', () {
      // Eight same-effort pairs, six of them at or above 0.65 (75%); four
      // cross pairs, one of them (25%).
      final separation = separationOf(
        sameEffort: const [0.9, 0.8, 0.75, 0.7, 0.68, 0.66, 0.5, 0.4],
        crossEffort: const [0.7, 0.6, 0.5, 0.4],
      );

      expect(separation.points, 50);
    });

    test('recall-70 is the highest cosine seven in ten still clear', () {
      // Ten same-effort pairs. At 0.60 exactly seven of them link, and no
      // higher value in the list keeps seven, so 0.60 is the answer. Two of
      // the five cross pairs clear the same bar: 40%.
      final separation = separationOf(
        sameEffort: const [
          0.30, 0.40, 0.50, 0.60, 0.62, 0.64, 0.66, 0.70, 0.80, 0.90,
        ],
        crossEffort: const [0.10, 0.20, 0.55, 0.61, 0.75],
      );

      expect(separation.recall70Cosine, closeTo(0.60, 1e-9));
      expect(separation.recall70CrossPct, 40);
    });

    test('ties do not let a value claim a share it has not got', () {
      // Four pairs, three of them at 0.50: at 0.50 all four link, at 0.90 one
      // does. Seventy percent needs three, so the answer is 0.50 and not 0.90.
      final separation = separationOf(
        sameEffort: const [0.50, 0.50, 0.50, 0.90],
        crossEffort: const [0.50, 0.10],
      );

      expect(separation.recall70Cosine, closeTo(0.50, 1e-9));
      expect(separation.recall70CrossPct, 50);
    });

    test('cross-5 is the lowest cosine one cross pair in twenty still clears',
        () {
      // Twenty cross pairs. At 0.80 one of them links, which is 5%; at 0.70
      // two do, which is 10%. So 0.80 is the lowest bar that holds the line,
      // and three of the ten same-effort pairs survive it.
      final separation = separationOf(
        sameEffort: const [
          0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.85, 0.90,
        ],
        crossEffort: const [
          0.05, 0.05, 0.10, 0.10, 0.15, 0.15, 0.20, 0.20, 0.25, 0.25,
          0.30, 0.30, 0.35, 0.35, 0.40, 0.40, 0.45, 0.45, 0.70, 0.80,
        ],
      );

      expect(separation.cross5Cosine, closeTo(0.80, 1e-9));
      expect(separation.cross5CrossPct, 5);
      expect(separation.cross5SameRecallPct, 30);
    });

    test('nothing to keep out puts the bar at the top same-effort pair', () {
      // An empty cross list is not a reason to report a cosine of zero, which
      // would read as "every pair links and none of them is wrong".
      final separation = separationOf(
        sameEffort: const [0.30, 0.60, 0.90],
        crossEffort: const [],
      );

      expect(separation.cross5Cosine, closeTo(0.90, 1e-9));
      expect(separation.cross5CrossPct, 0);
      expect(separation.cross5SameRecallPct, 33);
    });

    test('a cross list too short to reach 5% reports its top and says so', () {
      // Five cross pairs: even the largest is 20% of them, so no cosine in the
      // list clears the bar. The top is returned and the share beside it is
      // what tells a reader the rung is not the precision point.
      final separation = separationOf(
        sameEffort: const [0.50, 0.90],
        crossEffort: const [0.10, 0.20, 0.30, 0.40, 0.70],
      );

      expect(separation.cross5Cosine, closeTo(0.70, 1e-9));
      // The fallback made visible: one of five cross pairs is 20%, not 5%, and
      // the share beside the cosine is the only thing that says so.
      expect(separation.cross5CrossPct, 20);
      expect(separation.cross5SameRecallPct, 50);
    });

    test('nothing to recall reports nothing rather than a ratio', () {
      final separation = separationOf(
        sameEffort: const [],
        crossEffort: const [0.9, 0.1],
      );

      expect(separation.recall70Cosine, 0);
      expect(separation.recall70CrossPct, 0);
      expect(separation.points, -50);
    });
  });

  group('the clusters a pool would form', () {
    /// One pool row, fictional and on example.com.
    Map<String, Object?> row(
      String key, {
      required String subject,
      List<String> people = const ['Dana Whitfield', 'Priya Raman'],
      String at = '2026-09-10T09:00:00Z',
    }) =>
        {
          'source': 'email',
          'conversation_key': key,
          'subject': subject,
          'participants_json': jsonEncode([
            for (final person in people)
              {'name': person, 'email': '${person.split(' ').first.toLowerCase()}@example.com'},
          ]),
          'state': 'needs_reply',
          'cta_urgency': 'normal',
          'last_message_at': at,
        };

    // Four threads that all point the same way, so the cosine is never what
    // decides anything in these cases.
    List<double> near(double tilt) => [1.0, tilt];

    test('a duplicate-subject sibling never joins the clustering', () {
      // `k4` is `k1`'s fragment: the same subject after Re:, the same people,
      // four days apart. `sweep()` folds it onto k1 and clusters the three
      // representatives, so the group it would form is three threads and not
      // four — and Round D found that one folded row changing the whole
      // outcome, which is why this reading has to fold too.
      final rows = [
        row('k1', subject: 'Addendum for the River Street suite'),
        row('k2', subject: 'Fit-out allowance'),
        row('k3', subject: 'Lease schedule'),
        row('k4',
            subject: 'Re: Addendum for the River Street suite',
            at: '2026-09-14T09:00:00Z'),
      ];
      final formed = wouldFormClustersOf(
        rows: rows,
        vectors: [near(0.01), near(0.02), near(0.03), near(0.04)],
        keys: [t('k1'), t('k2'), t('k3'), t('k4')],
        threshold: StorylineTuning.clusterLinkThreshold,
      );

      expect(formed.folded, 1);
      expect(formed.representatives, 3);
      expect(formed.clusters, hasLength(1));
      expect(
        formed.clusters.single.threads,
        containsAll([t('k1'), t('k2'), t('k3')]),
      );
      expect(formed.clusters.single.threads, isNot(contains(t('k4'))));
    });

    test('a pool with nothing to fold clusters every row', () {
      final rows = [
        row('k1', subject: 'Addendum for the River Street suite'),
        row('k2', subject: 'Fit-out allowance'),
        row('k3', subject: 'Lease schedule'),
      ];
      final formed = wouldFormClustersOf(
        rows: rows,
        vectors: [near(0.01), near(0.02), near(0.03)],
        keys: [t('k1'), t('k2'), t('k3')],
        threshold: StorylineTuning.clusterLinkThreshold,
      );

      expect(formed.folded, 0);
      expect(formed.representatives, 3);
      expect(formed.clusters.single.threads, hasLength(3));
    });

    test('the threshold decides which pairs link, and the rungs move with it',
        () {
      // Three threads whose cosines sit LOW, which is the case the ladder
      // exists for: at the shipped 0.65 nothing links, and at a bar this
      // model's own numbers reach, all three do.
      final rows = [
        row('k1', subject: 'Addendum for the River Street suite'),
        row('k2', subject: 'Fit-out allowance'),
        row('k3', subject: 'Lease schedule'),
      ];
      // Three unit vectors 0.85 apart from each other, pairwise: a shared
      // axis at sqrt(0.85) and one private axis each at sqrt(0.15).
      const shared = 0.9219544457292887;
      const own = 0.3872983346207417;
      const vectors = [
        [shared, own, 0.0, 0.0],
        [shared, 0.0, own, 0.0],
        [shared, 0.0, 0.0, own],
      ];
      final keys = [t('k1'), t('k2'), t('k3')];

      final shipped = wouldFormClustersOf(
        rows: rows,
        vectors: vectors,
        keys: keys,
        threshold: 0.99,
      );
      final rescaled = wouldFormClustersOf(
        rows: rows,
        vectors: vectors,
        keys: keys,
        threshold: 0.80,
      );

      expect(shipped.clusters, isEmpty);
      expect(rescaled.clusters.single.threads, hasLength(3));
      // The fold does not depend on the bar, so both rungs report one pool.
      expect(shipped.representatives, rescaled.representatives);
      expect(shipped.folded, rescaled.folded);
    });

    test('pairs inside the clusters split by shared effort', () {
      final clusters = <JudgedCluster>[
        (threads: [t('k1'), t('k2'), t('k3')], outcome: 'would_form'),
        (threads: [t('k4'), t('k5')], outcome: 'would_form'),
      ];
      final inside = pairsInsideClusters(clusters, {
        t('k1'): 'alpha-effort',
        t('k2'): 'alpha-effort',
        t('k3'): 'beta-effort',
        t('k4'): 'beta-effort',
        t('k5'): 'none',
      });

      // Three pairs in the first cluster: one same, two cross. One pair in the
      // second, touching a thread gold files nowhere.
      expect(inside.same, 1);
      expect(inside.cross, 2);
      expect(inside.none, 1);
    });

    test('a pool with no cluster has no pair inside one', () {
      final inside = pairsInsideClusters(const <JudgedCluster>[], const {});

      expect(inside, (same: 0, cross: 0, none: 0));
    });

    test('a rung prints its cosine, its purity and its two pair counts', () {
      final line = wouldFormLine(
        label: 'recall-70',
        threshold: 0.58,
        purity: ClusterPurity.of(
          const <JudgedCluster>[
            (threads: ['email\nk1', 'email\nk2'], outcome: 'would_form'),
          ],
          {t('k1'): 'alpha-effort', t('k2'): 'alpha-effort'},
        ),
        inside: (same: 12, cross: 3, none: 5),
        sameTotal: 85,
      );

      expect(
        line,
        '  would-form at recall-70 0.58: 1 cluster, mean 100% over 1, '
        '>=70% 1, 100% 1 · same-effort pairs inside 12 of 85 · '
        'cross-effort pairs inside 3',
      );
      // No key and no slug, like every other printed line here.
      expect(line, isNot(contains('alpha-effort')));
      expect(line, isNot(contains('k1')));
    });

    test('the outcome word is the one the purity read groups on', () {
      final formed = wouldFormClustersOf(
        rows: [
          row('k1', subject: 'Addendum for the River Street suite'),
          row('k2', subject: 'Fit-out allowance'),
          row('k3', subject: 'Lease schedule'),
        ],
        vectors: [near(0.01), near(0.02), near(0.03)],
        keys: [t('k1'), t('k2'), t('k3')],
        threshold: StorylineTuning.clusterLinkThreshold,
      );

      expect(formed.clusters.single.outcome, 'would_form');
      final purity = ClusterPurity.of(formed.clusters, {
        t('k1'): 'alpha-effort',
        t('k2'): 'alpha-effort',
        t('k3'): 'beta-effort',
      });
      expect(purity.clusters, 1);
      expect(purity.mean, closeTo(2 / 3, 1e-9));
    });

    test('threads too far apart to link form nothing', () {
      final formed = wouldFormClustersOf(
        rows: [
          row('k1', subject: 'Addendum for the River Street suite'),
          row('k2', subject: 'Fit-out allowance'),
          row('k3', subject: 'Lease schedule'),
        ],
        vectors: const [
          [1.0, 0.0],
          [0.0, 1.0],
          [-1.0, 0.0],
        ],
        keys: [t('k1'), t('k2'), t('k3')],
        threshold: StorylineTuning.clusterLinkThreshold,
      );

      expect(formed.clusters, isEmpty);
      expect(formed.representatives, 3);
    });
  });

  group('the sweep defines', () {
    test('SWEEP_STAGE names a stage or fails loudly', () {
      expect(parseSweepStage('vector'), SweepStage.vector);
      expect(parseSweepStage(' FULL '), SweepStage.full);
      for (final raw in ['', 'vectors', 'seed', 'all']) {
        expect(() => parseSweepStage(raw), throwsArgumentError, reason: raw);
      }
    });

    test('SWEEP_CARD is the app\'s own variant list, and round-trips', () {
      expect(parseSweepCard('subject_topics'),
          ClusteringCardVariant.subjectTopics);
      expect(() => parseSweepCard('people'), throwsArgumentError);
      // The word a result file records has to be the word the define takes, or
      // a row cannot be matched to the command that produced it.
      for (final variant in ClusteringCardVariant.values) {
        expect(parseSweepCard(variant.wireName), variant);
      }
      expect(ClusteringCardVariant.subjectTopics.wireName, 'subject_topics');
    });

    test('SWEEP_EMBED_PREFIX has three readings and keeps every space', () {
      expect(resolveEmbedPrefix(''), EmbeddingsClient.clusteringPrefix);
      expect(resolveEmbedPrefix('none'), '');
      // Verbatim, trailing space included: a model's documented wording often
      // ends in one and losing it is a different request.
      expect(resolveEmbedPrefix('clustering: '), 'clustering: ');
      expect(resolveEmbedPrefix('  '), '  ');
    });
  });

  group('the tally', () {
    SweepTally tally({
      Map<String, double?> purity = const {'sl-1': 1.0, 'sl-2': 0.5},
      Map<String, double> coverage = const {'river-office-lease': 0.5},
      Map<String, int> forbidden = const {'studio-website-redesign': 2},
      Map<String, ClusterPurity> clusters = const {},
    }) =>
        SweepTally(
          formed: 2,
          tombstoned: 3,
          lintRejected: 5,
          incoherent: 6,
          seriesSeeded: 1,
          seriesExcluded: 8,
          outliersDropped: 3,
          fragmentsJoined: 4,
          fragmentsFolded: 6,
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
          clusterPurity: clusters,
          sameEffortBins: const [0, 0, 0, 0, 0],
          crossEffortBins: const [0, 0, 0, 0, 0],
          withNoneBins: const [0, 0, 0, 0, 0],
          sameSubjectBins: const [1, 0, 0, 2],
          crossSubjectBins: const [5, 1, 0, 0],
          withNoneSubjectBins: const [3, 0, 0, 0],
          samePeopleBins: const [0, 1, 2],
          crossPeopleBins: const [4, 2, 0],
          withNonePeopleBins: const [3, 0, 0],
          separation: (
            points: 25,
            recall70Cosine: 0.58,
            recall70CrossPct: 31,
            cross5Cosine: 0.79,
            cross5CrossPct: 5,
            cross5SameRecallPct: 14,
          ),
        );

    /// Two judged clusters: a formed one wholly inside one effort and a
    /// declined one that was half another. Built through the real arithmetic
    /// so the printed line is the line the bench prints.
    final judgedClusters = clusterPurityByOutcome(
      [
        (threads: [t('k1'), t('k2')], outcome: 'formed'),
        (threads: [t('k3'), t('k4')], outcome: 'incoherent'),
      ],
      {
        t('k1'): 'alpha-effort',
        t('k2'): 'alpha-effort',
        t('k3'): 'beta-effort',
        t('k4'): 'alpha-effort',
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

    test('the sweep-side counts ride the JSON under the note keys', () {
      // The same seven keys the sweep writes to its activity row, so the run
      // file and the log read as one story.
      final json = tally().toJson();

      expect(json['lint_rejected'], 5);
      expect(json['incoherent'], 6);
      expect(json['series'], 1);
      expect(json['series_excluded'], 8);
      expect(json['outliers'], 3);
      expect(json['fragments'], 4);
      expect(json['folded'], 6);
    });

    test('the JSON carries clusters by outcome and the pair bins by name', () {
      final json = SweepTally(
        formed: 1,
        tombstoned: 1,
        lintRejected: 0,
        incoherent: 1,
        seriesSeeded: 0,
        seriesExcluded: 0,
        outliersDropped: 0,
        fragmentsJoined: 0,
        fragmentsFolded: 0,
        purityByStoryline: const {},
        coverageBySlug: const {},
        largestShare: 0,
        correctPositives: 0,
        forbiddenByAnti: const {},
        unmapped: 0,
        filedNowhere: 0,
        callsByKind: const {},
        callsPerPass: const [],
        wallPerPassMs: const [],
        cosineBins: const [0, 0, 0, 0, 0],
        lintCounts: const {},
        clusterPurity: judgedClusters,
        sameEffortBins: const [0, 0, 1, 0, 0],
        crossEffortBins: const [2, 0, 0, 0, 0],
        withNoneBins: const [0, 0, 0, 3, 0],
        sameSubjectBins: const [0, 0, 1, 0],
        crossSubjectBins: const [2, 0, 0, 0],
        withNoneSubjectBins: const [3, 0, 0, 0],
        samePeopleBins: const [0, 0, 1],
        crossPeopleBins: const [2, 0, 0],
        withNonePeopleBins: const [1, 2, 0],
        separation: (
          points: 40,
          recall70Cosine: 0.6,
          recall70CrossPct: 12,
          cross5Cosine: 0.82,
          cross5CrossPct: 4,
          cross5SameRecallPct: 9,
        ),
      ).toJson();

      final clusters = json['clusters']! as Map;
      expect(clusters.keys, ['formed', 'incoherent', 'declined']);
      expect((clusters['formed']! as Map)['mean'], closeTo(1.0, 1e-9));
      expect((clusters['formed']! as Map)['pure_at_100'], 1);
      expect((clusters['incoherent']! as Map)['mean'], closeTo(0.5, 1e-9));
      expect((clusters['declined']! as Map)['sizes'], [2]);

      expect(json['pair_bins'], {
        'same_effort': {
          '<0.50': 0,
          '0.50-0.55': 0,
          '0.55-0.60': 1,
          '0.60-0.65': 0,
          '>=0.65': 0,
        },
        'cross_effort': {
          '<0.50': 2,
          '0.50-0.55': 0,
          '0.55-0.60': 0,
          '0.60-0.65': 0,
          '>=0.65': 0,
        },
        'with_none': {
          '<0.50': 0,
          '0.50-0.55': 0,
          '0.55-0.60': 0,
          '0.60-0.65': 3,
          '>=0.65': 0,
        },
      });
    });

    test('the lexical lines and the separation ride the JSON by name', () {
      final json = tally().toJson();

      expect(json['subject_overlap_bins'], {
        'same_effort': {'0': 1, '0-0.25': 0, '0.25-0.5': 0, '>=0.5': 2},
        'cross_effort': {'0': 5, '0-0.25': 1, '0.25-0.5': 0, '>=0.5': 0},
        'with_none': {'0': 3, '0-0.25': 0, '0.25-0.5': 0, '>=0.5': 0},
      });
      expect(json['shared_people_bins'], {
        'same_effort': {'0': 0, '1': 1, '2+': 2},
        'cross_effort': {'0': 4, '1': 2, '2+': 0},
        'with_none': {'0': 3, '1': 0, '2+': 0},
      });
      expect(json['separation'], {
        'points': 25,
        'recall_70_cosine': 0.58,
        'recall_70_cross_pct': 31,
        'cross_5_cosine': 0.79,
        'cross_5_cross_pct': 5,
        'cross_5_same_recall_pct': 14,
      });
    });

    test('the lexical lines and the separation print as counts', () {
      final printed = tally().table();

      expect(
        printed,
        contains('pool pairs by subject overlap  same  0 1  0-0.25 0  '
            '0.25-0.5 0  >=0.5 2'),
      );
      expect(printed, contains('cross  0 5  0-0.25 1  0.25-0.5 0  >=0.5 0'));
      expect(
        printed,
        contains('pool pairs by shared people  same  0 0  1 1  2+ 2'),
      );
      expect(
        printed,
        contains('separation: 25 points at 0.65 · recall-70 cosine 0.58 · '
            'cross 31% · cross-5 cosine 0.79 · cross 5% · same 14%'),
      );
    });

    test('the declined bucket is not counted twice in clusters judged', () {
      // Two clusters judged, three entries in the map: `declined` unions one
      // of them and summing every entry would report three.
      expect(tally(clusters: judgedClusters).clustersJudged, 2);
      expect(tally().clustersJudged, 0);
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
      // Counts, which is all the sweep-side line ever carries.
      expect(printed, contains('lint-rejected 5  incoherent 6'));
      expect(printed, contains('series  seeded 1  excluded 8'));
      expect(printed, contains('outliers dropped 3'));
      expect(printed, contains('fragments 4'));
      expect(printed, contains('folded 6'));
      // A run that judged nothing still prints all five columns and says so.
      expect(
        printed,
        contains(
            'clusters judged 0  formed 0  incoherent 0  lint 0  thin 0  '
            'answered 0'),
      );
      expect(printed, contains('purity before naming  formed: none'));
      expect(printed, contains('declined: none'));
      expect(
        printed,
        contains('pool pairs by cosine  same effort  <0.50 0'),
      );

      // The same three lines with clusters in them, which is where a thread
      // key would leak if one ever reached the printed side.
      final withClusters = tally(clusters: judgedClusters).table();
      expect(
        withClusters,
        contains(
            'clusters judged 2  formed 1  incoherent 1  lint 0  thin 0  '
            'answered 0'),
      );
      expect(
        withClusters,
        contains('purity before naming  formed: 1 cluster, mean 100% over 1, '
            '>=70% 1, 100% 1'),
      );
      expect(
        withClusters,
        contains('declined: 1 cluster, mean 50% over 1, >=70% 0, 100% 0'),
      );
      for (final key in ['k1', 'k2', 'k3', 'k4']) {
        expect(withClusters, isNot(contains(t(key))));
      }
      expect(withClusters, isNot(contains('alpha-effort')));
      expect(withClusters, isNot(contains('beta-effort')));
    });
  });
}
