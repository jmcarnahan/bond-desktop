import 'package:bond_inbox/services/storyline_clustering.dart';
// `show`: the numbers the sweep runs this rule with. The module takes them as
// parameters and has no opinion about them, so the tests below hard-code the
// app's values and the first test is what keeps those two in step.
import 'package:bond_inbox/services/storyline_service.dart'
    show StorylineTuning;
import 'package:flutter_test/flutter_test.dart';

/// The clustering rule the sweep proposes storylines with, on explicit
/// similarity matrices rather than on vectors.
///
/// Written against numbers and not against geometry on purpose. Two-dimensional
/// test vectors cannot express what this rule is about — a group of four whose
/// members are pairwise close and whose mean is still low needs more room than
/// a circle has — and the point of pulling the rule into a file with no store
/// and no model in it was that it could be asked these questions directly.

/// A similarity function over an explicit table of unordered pairs, keyed
/// `'<lo>-<hi>'`. Anything unlisted reads [fallback], and a row against itself
/// reads 1.0.
double Function(int, int) simFrom(
  Map<String, double> pairs, {
  double fallback = 0.0,
}) =>
    (i, j) {
      if (i == j) return 1.0;
      final lo = i < j ? i : j;
      final hi = i < j ? j : i;
      return pairs['$lo-$hi'] ?? fallback;
    };

/// Every pair of [members] at [value], as table entries.
Map<String, double> clique(List<int> members, double value) => {
      for (var a = 0; a < members.length; a++)
        for (var b = a + 1; b < members.length; b++)
          '${members[a] < members[b] ? members[a] : members[b]}-'
                  '${members[a] < members[b] ? members[b] : members[a]}':
              value,
    };

void main() {
  /// The app's own numbers, so what these tests pin is the rule the sweep
  /// runs and not a configuration of it nothing uses.
  List<List<int>> cluster(
    int count,
    double Function(int, int) sim, {
    double threshold = 0.65,
    // Two, where the sweep passes three. The minimum size is the CALLER's
    // policy about what is worth a naming call, not part of the join rule
    // these tests are about, and holding it at two is what lets a test say
    // "a pair still forms from a single link" at all. The sweep's own number
    // is pinned below.
    int minSize = 2,
    int maxSize = 12,
    double floor = 0.60,
    double step = 0.05,
    double ceiling = 0.85,
  }) =>
      clusterBySimilarity(
        count,
        sim,
        threshold: threshold,
        minSize: minSize,
        maxSize: maxSize,
        floor: floor,
        step: step,
        ceiling: ceiling,
      );

  test('the numbers these tests use are the numbers the sweep passes', () {
    // Every test below calls [cluster] with the app's constants written out,
    // because a rule is easier to read against literals than against names.
    // The cost of that is a suite that would go on passing if
    // `StorylineService._clusterBy` started passing something else, so the
    // literals and the constants are pinned to each other here, once.
    expect(StorylineTuning.clusterLinkThreshold, 0.65);
    // What `_clusterBy` passes as `minSize`: the PROPOSE floor. A pair is a
    // shape this rule can form and not a question worth a naming call, so
    // `minClusterSize` (2) is the survivor floor after the confirms and never
    // reaches this module.
    expect(StorylineTuning.proposeMinClusterSize, 3);
    expect(StorylineTuning.minClusterSize, 2);
    expect(StorylineTuning.maxClusterSize, 12);
    expect(StorylineTuning.clusterCoherenceFloor, 0.60);
    expect(StorylineTuning.clusterSplitStep, 0.05);
    expect(StorylineTuning.clusterSplitCeiling, 0.85);
  });

  group('PairSimilarities', () {
    test('reads the same number from either end', () {
      final table = PairSimilarities(4);
      table.set(2, 0, 0.7);

      // `closeTo` because the table is single precision: what it stores is a
      // cosine between unit vectors, and the thresholds it is compared against
      // are five orders of magnitude coarser than the rounding.
      expect(table.get(0, 2), closeTo(0.7, 1e-6));
      expect(table.get(2, 0), table.get(0, 2));
    });

    test('a row against itself is 1.0 and an unset pair is 0.0', () {
      final table = PairSimilarities(3);
      table.set(0, 1, 0.9);

      expect(table.get(1, 1), 1.0);
      expect(table.get(0, 2), 0.0);
      expect(table.get(2, 1), 0.0);
    });

    test('every pair has a slot of its own', () {
      // The triangle is indexed by hand, so a wrong offset would show up as
      // two pairs sharing a number rather than as a crash.
      final table = PairSimilarities(5);
      var next = 0.1;
      for (var i = 0; i < 5; i++) {
        for (var j = i + 1; j < 5; j++) {
          table.set(i, j, next);
          next += 0.01;
        }
      }
      var expected = 0.1;
      for (var i = 0; i < 5; i++) {
        for (var j = i + 1; j < 5; j++) {
          expect(table.get(j, i), closeTo(expected, 1e-6));
          expected += 0.01;
        }
      }
    });

    test('a self-pair cannot be written', () {
      final table = PairSimilarities(2);
      table.set(1, 1, 0.2);

      expect(table.get(1, 1), 1.0);
    });
  });

  group('meanPairwiseSimilarity', () {
    test('averages over every unordered pair', () {
      final sim = simFrom({'0-1': 0.9, '0-2': 0.6, '1-2': 0.3});

      expect(meanPairwiseSimilarity([0, 1, 2], sim), closeTo(0.6, 1e-12));
    });

    test('fewer than two members is trivially coherent', () {
      final sim = simFrom(const {});

      expect(meanPairwiseSimilarity(const [], sim), 1.0);
      expect(meanPairwiseSimilarity(const [7], sim), 1.0);
    });
  });

  group('the join rule', () {
    test('a chain does not become one blob', () {
      // The failure this rule exists for. Only neighbours link, so single-link
      // would weld all four into one group — and in a real mailbox the middle
      // thread is a status update that mentions two projects.
      final sim = simFrom(
        {'0-1': 0.7, '1-2': 0.7, '2-3': 0.7},
        fallback: 0.3,
      );

      expect(cluster(4, sim), [
        [0, 1],
        [2, 3],
      ]);
    });

    test('a clique is one cluster', () {
      expect(cluster(4, simFrom(clique([0, 1, 2, 3], 0.9))), [
        [0, 1, 2, 3],
      ]);
    });

    test('a pair still forms from a single link', () {
      expect(cluster(2, simFrom({'0-1': 0.66})), [
        [0, 1],
      ]);
    });

    test('one link into a group of three is not enough', () {
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        '0-3': 0.7,
      }, fallback: 0.3);

      // The candidate opens its own cluster and is dropped for being one
      // thread — a storyline of one is just a thread.
      expect(cluster(4, sim), [
        [0, 1, 2],
      ]);
    });

    test('two links and half the members is', () {
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        '0-3': 0.7,
        '1-3': 0.7,
      }, fallback: 0.3);

      expect(cluster(4, sim), [
        [0, 1, 2, 3],
      ]);
    });

    test('the cluster with the most links wins', () {
      // Two groups qualify. The candidate belongs to neither by the numbers
      // alone, and the tiebreak has to be a reason rather than an accident of
      // which group was built first.
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        ...clique([3, 4, 5], 0.9),
        '0-6': 0.7,
        '1-6': 0.7,
        '3-6': 0.7,
        '4-6': 0.7,
        '5-6': 0.7,
      }, fallback: 0.3);

      expect(cluster(7, sim), [
        [3, 4, 5, 6],
        [0, 1, 2],
      ]);
    });

    test('and a tie goes to the earlier cluster', () {
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        ...clique([3, 4, 5], 0.9),
        '0-6': 0.7,
        '1-6': 0.7,
        '3-6': 0.7,
        '4-6': 0.7,
      }, fallback: 0.3);

      expect(cluster(7, sim), [
        [0, 1, 2, 6],
        [3, 4, 5],
      ]);
    });
  });

  group('the cap and the floor', () {
    test('a thirteenth thread does not fit, and the twelve are kept', () {
      // Everything links to everything, so the only thing deciding the shape
      // is the cap. The twelve are coherent at every rung of the ladder, so
      // they survive being re-clustered for being large; the thirteenth is a
      // cluster of one and is dropped.
      final sim = simFrom(clique([for (var i = 0; i < 13; i++) i], 0.9));

      expect(cluster(13, sim), [
        [for (var i = 0; i < 12; i++) i],
      ]);
    });

    test('a group that is really two comes apart at the seam', () {
      // Two triangles at 0.9. The second one reaches the first through three
      // pairs just over the link threshold, which is enough to join under the
      // rule and not enough to be one story: the mean over all fifteen pairs
      // is 0.536, well under the floor.
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        ...clique([3, 4, 5], 0.9),
        '0-3': 0.66,
        '1-3': 0.66,
        '0-4': 0.66,
        '0-5': 0.66,
      });
      expect(
        meanPairwiseSimilarity([0, 1, 2, 3, 4, 5], sim),
        lessThan(0.60),
      );
      // Without the floor it would be one cluster of six.
      expect(
        cluster(6, sim, floor: 0.0),
        [
          [0, 1, 2, 3, 4, 5],
        ],
      );

      expect(cluster(6, sim), [
        [0, 1, 2],
        [3, 4, 5],
      ]);
    });

    test('a blob that never comes apart is dropped, not named', () {
      // Every link in this group is 0.87, so it survives every rung of the
      // ladder including the ceiling — and its mean is 0.58, because the rule
      // only ever asked half its members to recognise each new thread. What
      // happens at the top is a drop: no naming call is spent on it, and no
      // tombstone is written either, because nothing was asked.
      final sim = simFrom({
        ...clique([0, 1, 2], 0.87),
        '0-3': 0.87,
        '1-3': 0.87,
        '0-4': 0.87,
        '1-4': 0.87,
        '0-5': 0.87,
        '1-5': 0.87,
        '3-5': 0.87,
      });
      expect(
        meanPairwiseSimilarity([0, 1, 2, 3, 4, 5], sim),
        lessThan(0.60),
      );

      expect(cluster(6, sim), isEmpty);
    });

    test('a cluster whose mean clears the floor is left alone', () {
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        '0-3': 0.66,
        '1-3': 0.66,
      });
      expect(
        meanPairwiseSimilarity([0, 1, 2, 3], sim),
        greaterThanOrEqualTo(0.60),
      );

      expect(cluster(4, sim), [
        [0, 1, 2, 3],
      ]);
    });
  });

  group('the result is a pure function of its input', () {
    test('the same question twice gives the same answer', () {
      // What the tombstones stand on: a dismissed suggestion is recognised by
      // the hash of the member set its cluster produced, so a second run over
      // an unchanged mailbox has to group identically or the user is asked
      // again about a group they threw away.
      final sim = simFrom({
        ...clique([0, 1, 2], 0.9),
        ...clique([3, 4], 0.8),
        '2-5': 0.7,
        '1-5': 0.7,
      }, fallback: 0.2);

      expect(cluster(6, sim), cluster(6, sim));
      expect(cluster(6, sim), [
        [0, 1, 2, 5],
        [3, 4],
      ]);
    });

    test('largest first, ties by the earliest member', () {
      final sim = simFrom({
        ...clique([0, 3], 0.9),
        ...clique([1, 2, 4], 0.9),
        ...clique([5, 6], 0.9),
      });

      expect(cluster(7, sim), [
        [1, 2, 4],
        [0, 3],
        [5, 6],
      ]);
    });

    test('members come back in ascending order', () {
      final sim = simFrom(clique([0, 1, 2], 0.9));

      expect(cluster(3, sim).single, [0, 1, 2]);
    });

    test('nothing to cluster is nothing, not a throw', () {
      expect(cluster(0, simFrom(const {})), isEmpty);
      expect(cluster(1, simFrom(const {})), isEmpty);
    });
  });
}
