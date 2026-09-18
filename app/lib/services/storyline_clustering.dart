import 'dart:typed_data';

/// The clustering the sweep proposes storylines out of, as pure arithmetic.
///
/// It lives apart from `storyline_service.dart` because it is the one part of
/// the sweep with no store, no model and no clock in it: everything it needs
/// is a count, a similarity function and the five numbers the caller passes.
/// That is not tidiness. The rule below has to be a PURE function of the
/// store's row order and the similarities, because a dismissed suggestion is
/// tombstoned under the hash of the member set the cluster produced — a
/// clustering that answered differently on a second run would re-propose a
/// group the user has already thrown away. Nothing here reads anything it was
/// not handed, and nothing imports the service (which imports this file), so
/// the numbers cannot quietly become defaults.
///
/// ## The rule
///
/// A link is a pair at or above the caller's threshold. Candidates arrive in
/// the store's own order — newest first, key ascending, a total order with no
/// ties — and each one either joins a cluster or opens its own:
///
/// * it may join cluster `C` when it links to at least `min(2, |C|)` of C's
///   members AND to at least half of them. Two links and half the members: a
///   pair still forms from one link, and a third thread has to look like both
///   of the first two rather than like either;
/// * among the clusters it qualifies for, the one it has the MOST links into
///   wins, ties to the earlier cluster.
///
/// Single-link — join the first cluster holding any member you link to — is
/// what this replaces, and what it cost is on the record: on 2026-09-18 the
/// golden mailbox chained into one storyline holding 56% of every filed
/// thread, with no correct positive anywhere in the run. One thread that
/// looks a little like two different groups is all single-link needs to weld
/// them together, and in a one-team mailbox there is always one.
///
/// Two guards run after the pass, and both are splits rather than verdicts:
///
/// * a cluster at `maxSize` accepts no more members while the pass runs, and
///   is re-clustered afterwards at a higher threshold;
/// * a cluster whose mean pairwise similarity is under `floor` is
///   re-clustered the same way.
///
/// Re-clustering is this same rule over the cluster's own members at
/// `threshold + step`, repeating up to `ceiling`. What is still incoherent at
/// the ceiling is DROPPED for this pass: no naming call is spent on a blob,
/// and nothing is tombstoned, because nothing was ever asked. A capped but
/// coherent group survives at the ceiling rather than being thrown away for
/// being large.
///
/// Every cluster comes back with its members in ascending index order, and
/// the clusters themselves largest-first, ties broken by their smallest
/// member index.

/// A symmetric table of pairwise similarities over [count] rows, stored once
/// per unordered pair.
///
/// The triangle rather than the square: the sweep asks for every pair of a
/// few hundred candidates, and a square would hold each of them twice for no
/// reason. A pair nothing ever wrote reads 0, which is below every threshold
/// this file is used with — that is what lets the index path record only the
/// hits its probes returned and leave the rest alone.
///
/// Single precision, and that is a size decision rather than an accuracy one.
/// The clustering pool has no upper bound: it is every unassigned thread in
/// the mailbox with a vector, so a 2,000-thread mailbox is two million pairs,
/// which is 8 MB here and 16 MB at double width. What is stored is a cosine
/// between unit vectors, and on the index path it arrives already computed by
/// vec0 over packed float32, so the second half of a double was never carrying
/// information. The thresholds this table is compared against are spaced 0.05
/// apart, five orders of magnitude above the rounding.
class PairSimilarities {
  PairSimilarities(this.count)
      : assert(count >= 0),
        _values = Float32List(count * (count - 1) ~/ 2);

  /// How many rows the table spans. Indexes run `0 ..< count`.
  final int count;

  final Float32List _values;

  /// The similarity of [i] and [j] in either order: 1.0 for a row against
  /// itself, 0.0 for a pair nothing has set.
  double get(int i, int j) {
    assert(_inRange(i) && _inRange(j), 'row out of range: $i, $j of $count');
    if (i == j) return 1.0;
    return _values[_offset(i, j)];
  }

  /// Records [value] for the unordered pair [i], [j]. A self-pair is ignored
  /// rather than stored: the diagonal is a constant, not data.
  void set(int i, int j, double value) {
    assert(_inRange(i) && _inRange(j), 'row out of range: $i, $j of $count');
    if (i == j) return;
    _values[_offset(i, j)] = value;
  }

  /// Checked in debug only, and checked at all because the triangle is indexed
  /// by arithmetic: an index past the end folds into another pair's slot
  /// rather than throwing, so a caller walking the wrong list would read
  /// plausible numbers about the wrong threads.
  bool _inRange(int i) => i >= 0 && i < count;

  int _offset(int i, int j) {
    final lo = i < j ? i : j;
    final hi = i < j ? j : i;
    // Row `lo` of the strict upper triangle starts after the `lo` rows above
    // it, each shorter than the last.
    return lo * count - (lo * (lo + 1)) ~/ 2 + (hi - lo - 1);
  }
}

/// The mean of [sim] over every unordered pair of [members], and 1.0 when
/// there are fewer than two of them.
///
/// One member is trivially coherent with itself, and answering 1.0 rather
/// than 0 or a NaN is what keeps a singleton from being read as the least
/// coherent thing in the pass by a caller comparing against a floor.
double meanPairwiseSimilarity(
  List<int> members,
  double Function(int, int) sim,
) {
  if (members.length < 2) return 1.0;
  var total = 0.0;
  var pairs = 0;
  for (var a = 0; a < members.length; a++) {
    for (var b = a + 1; b < members.length; b++) {
      total += sim(members[a], members[b]);
      pairs++;
    }
  }
  return total / pairs;
}

/// Groups `0 ..< count` by the rule this file's doc describes.
///
/// [sim] must be pure and symmetric — both of the sweep's paths satisfy that,
/// one by arithmetic and one by construction — because a similarity that
/// depended on the order it was asked in would put the tombstones' identity
/// back at risk.
///
/// [threshold] is what counts as a link, [minSize] the smallest group worth
/// returning, [maxSize] the point at which a cluster stops accepting members,
/// [floor] the mean pairwise similarity a cluster has to reach to be named,
/// and [step] / [ceiling] the ladder a capped or incoherent cluster is
/// re-clustered up.
List<List<int>> clusterBySimilarity(
  int count,
  double Function(int i, int j) sim, {
  required double threshold,
  required int minSize,
  required int maxSize,
  required double floor,
  required double step,
  required double ceiling,
}) {
  // A step of zero would re-cluster the same members at the same threshold
  // forever: the ladder terminates because each rung asks for more.
  assert(step > 0, 'the split ladder needs a positive step');
  final formed = _pass(
    [for (var i = 0; i < count; i++) i],
    sim,
    threshold,
    maxSize,
  );

  final settled = <List<int>>[];
  for (final cluster in formed) {
    settled.addAll(
      _settle(
        cluster,
        sim,
        threshold,
        maxSize: maxSize,
        floor: floor,
        step: step,
        ceiling: ceiling,
      ),
    );
  }

  final kept = [
    for (final cluster in settled)
      if (cluster.length >= minSize) cluster,
  ];
  // Largest first, so a caller spending a budget on the head of the list
  // spends it on the strongest proposals. The tiebreak is spelled out rather
  // than left to the sort: `List.sort` makes no stability promise, and this
  // function has to answer identically on a second run for a tombstone to
  // keep holding.
  kept.sort((a, b) {
    final bySize = b.length.compareTo(a.length);
    return bySize != 0 ? bySize : a.first.compareTo(b.first);
  });
  return kept;
}

/// One greedy pass over [members] (ascending) at [threshold].
List<List<int>> _pass(
  List<int> members,
  double Function(int, int) sim,
  double threshold,
  int maxSize,
) {
  final clusters = <List<int>>[];
  for (final candidate in members) {
    List<int>? best;
    var bestLinks = 0;
    for (final cluster in clusters) {
      if (cluster.length >= maxSize) continue;
      var links = 0;
      for (final member in cluster) {
        if (sim(candidate, member) >= threshold) links++;
      }
      // Two links and half the members, and a pair still forms from one.
      if (links < (cluster.length < 2 ? cluster.length : 2)) continue;
      if (2 * links < cluster.length) continue;
      // Strictly greater, so a tie keeps the earlier cluster.
      if (links > bestLinks) {
        best = cluster;
        bestLinks = links;
      }
    }
    if (best != null) {
      best.add(candidate);
    } else {
      clusters.add([candidate]);
    }
  }
  return clusters;
}

/// [cluster] as it stands, or the smaller clusters it breaks into one rung up
/// the threshold ladder.
List<List<int>> _settle(
  List<int> cluster,
  double Function(int, int) sim,
  double threshold, {
  required int maxSize,
  required double floor,
  required double step,
  required double ceiling,
}) {
  if (cluster.length < 2) return [cluster];
  final mean = meanPairwiseSimilarity(cluster, sim);
  final atCap = cluster.length >= maxSize;
  if (!atCap && mean >= floor) return [cluster];

  final next = threshold + step;
  if (next > ceiling + 1e-9) {
    // The top of the ladder. A group that is merely large is kept — being at
    // the cap is not a defect when everything in it is coherent — and one
    // that is still a blob is dropped, with no model call spent on it and no
    // tombstone written, because nothing was ever asked about it.
    return mean >= floor ? [cluster] : const [];
  }

  final out = <List<int>>[];
  for (final split in _pass(cluster, sim, next, maxSize)) {
    out.addAll(
      _settle(
        split,
        sim,
        next,
        maxSize: maxSize,
        floor: floor,
        step: step,
        ceiling: ceiling,
      ),
    );
  }
  return out;
}
