import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/conversation_vec_index.dart';
import '../data/message_store.dart';
import 'conversation_state.dart' show seriesKeyFor;
import 'decision/storyline_thread_input.dart' show StorylineThreadText;
import 'llm/embeddings_client.dart';
import 'storyline_cards.dart';
import 'storyline_clustering.dart';
import 'storyline_judge.dart';
// `show`: the two things that stay declared with the service. Narrowed so the
// card statics above can only come from `storyline_cards.dart` itself — the
// service re-exports that file, and an unrestricted import here would make the
// direct one above redundant.
import 'storyline_service.dart' show GroupingMode, StorylineTuning;

/// What one sweep's decision grouping did with its candidate pairs, counted
/// for the activity row and the golden sweep bench.
///
/// Mutable and handed DOWN rather than returned, so that the decision path
/// answers in exactly the shape the cosine path answers in — a list of index
/// lists — and the branch between them stays one expression with nothing
/// below it that knows which ran. Every counter stays zero under
/// [GroupingMode.cosine].
class GroupingTally {
  /// Candidate pairs the pass proposed: the cosine neighbours and the
  /// shared-subject pairs, de-duplicated.
  int pairs = 0;

  /// Pairs answered from `pair_decisions`, with no question asked.
  int cached = 0;

  /// Pairs sent to the decision model this pass: candidates, and the
  /// missing pairs inside a cluster being completed.
  int scored = 0;

  /// Pairs over [StorylinePolicy.pairBudgetPerPass], asked on a later pass:
  /// candidates read as p = 0 this pass, and the missing pairs of a cluster
  /// the budget could not complete.
  int deferred = 0;

  /// Clusters not proposed this pass because the budget could not complete
  /// their pairs. Rebuilt and completed on a later pass.
  int clustersDeferred = 0;

  /// For each cluster [StorylineGrouper.candidates] returned, in order, how
  /// many members its grouping set aside as outliers. The sweep counts them
  /// only for the clusters it goes on to name, so a cluster rebuilt pass
  /// after pass is not counted every time.
  final List<int> clusterOutliers = [];
}

/// How a sweep's pool becomes candidate clusters.
///
/// One entry point, [candidates], and behind it the two passes
/// [GroupingMode] names: the decision grouping that ships, where the cosine
/// only PROPOSES pairs and the decision model's `same_effort` judges them,
/// and the cosine clustering kept as the bench baseline. Both answer in
/// index lists into the rows they were handed, so nothing above this class
/// can tell which ran — which is what keeps the namer, the confirms, the
/// observer and the tombstones identical in either mode.
///
/// Nothing here touches a membership, a storyline row or the activity log.
/// The only rows it writes are the `pair_decisions` cache, and the only state
/// it keeps is the process-wide set of fallback reasons already printed.
class StorylineGrouper {
  StorylineGrouper(
    this._store, {
    this._judge,
    this._mode = StorylineTuning.groupingMode,
  });

  /// The fallback source label for a conversation row that carries none of its
  /// own. A copy of `StorylineService._workSource` rather than a reference to
  /// it: it is a constant, and such a row predates the second connector, so it
  /// is mail.
  static const String _workSource = 'email';

  final MessageStore _store;

  /// Who answers `same_effort` under [GroupingMode.decision]. Null only for a
  /// service that never sweeps; a decision grouping without one throws, which
  /// parks the lane rather than guessing.
  final StorylineJudge? _judge;

  /// Which pass this grouper groups with. [StorylineTuning.groupingMode] for
  /// every caller in `lib/`; a test or the bench may pass the cosine baseline
  /// without flipping a const the whole suite reads.
  final GroupingMode _mode;

  /// Whether this grouper asks the decision model anything: the sweep checks
  /// the judge is ready before it hands over a pool that will be judged.
  bool get judgesPairs => _mode == GroupingMode.decision;

  /// The clusters [rows] should be considered in, by whichever pass [_mode]
  /// names.
  ///
  /// The branch lives here rather than at the call site so the sweep asks one
  /// question and reads one answer: index lists into [rows], members ascending,
  /// largest cluster first. [tally] is filled in only by the decision pass,
  /// which is why the cosine path leaves every one of its counters at zero.
  Future<List<List<int>>> candidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
    GroupingTally tally,
  ) async =>
      _mode == GroupingMode.cosine
          ? await _clusterCandidates(rows, vectors)
          : await _decisionCandidates(rows, vectors, tally);

  /// The clusters the COSINE baseline considers, from whichever
  /// pair-discovery is available.
  ///
  /// The split is deliberate and narrow: measuring the pairs is the part an
  /// index can do faster, and forming the clusters out of them is the part
  /// whose determinism the tombstones depend on. So both paths build the same
  /// table of similarities and hand it to the same [_clusterBy], and the only
  /// thing that varies is who measured "how close are rows i and j".
  Future<List<List<int>>> _clusterCandidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async =>
      _clusterBy(vectors.length, (await _similaritiesOf(rows, vectors)).get);

  /// The one pairwise cosine table a sweep builds, whichever pass reads it:
  /// the cosine baseline clusters on it whole, and the decision grouping reads
  /// each row's nearest neighbours off it as candidate pairs.
  Future<PairSimilarities> _similaritiesOf(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async =>
      await _indexedSimilarities(rows, vectors) ??
      _arithmeticSimilarities(vectors);

  /// The clustering rule, with this app's numbers in it. The rule itself lives
  /// in [clusterBySimilarity], which knows nothing about storylines — see its
  /// doc for the join rule, the cap, the coherence floor and the split ladder,
  /// and for why the whole thing has to be a pure function of the row order
  /// the store handed over.
  static List<List<int>> _clusterBy(
    int count,
    double Function(int i, int j) sim,
  ) =>
      clusterBySimilarity(
        count,
        sim,
        threshold: StorylineTuning.clusterLinkThreshold,
        // The PROPOSE floor, not the survivor floor: what comes back here is
        // a question to spend a naming call on, and a pair is not one.
        minSize: StorylineTuning.proposeMinClusterSize,
        maxSize: StorylineTuning.maxClusterSize,
        floor: StorylineTuning.clusterCoherenceFloor,
        step: StorylineTuning.clusterSplitStep,
        ceiling: StorylineTuning.clusterSplitCeiling,
      );

  /// The clusters the DECISION grouping proposes: cosine proposes the pairs,
  /// the decision model's `same_effort` judges them, and average linkage over
  /// the judged pairs forms the groups.
  ///
  /// The candidate pairs, unordered and de-duplicated:
  ///
  /// * each row's nearest [StorylinePolicy.pairNeighbours] by cosine, at
  ///   [StorylinePolicy.pairRetrievalFloor] or above — retrieval, so a loose
  ///   floor;
  /// * every pair of rows sharing a series key ([seriesKeyFor], the subject
  ///   pre-pass's own key), the first [StorylineTuning.maxClusterSize] of each
  ///   key in pool order. Two issues of one series share a shape and not a
  ///   subject matter, so the vector can miss them; a fragment key folds less
  ///   than a series key, so every fragment pair is among these too.
  ///
  /// Two rounds of linkage, because the candidates are not every pair. The
  /// first reads only the pairs that have an answer ([averageLinkage] with
  /// `unscoredAsZero: false`), so an effort whose threads are not all each
  /// other's nearest neighbours still comes together. Each cluster it forms
  /// of [StorylineTuning.proposeMinClusterSize] or more is then COMPLETED:
  /// every pair inside it without an answer is asked, and linkage and the
  /// outlier cut run again over that cluster alone on the full matrix, an
  /// unscored pair now reading p = 0 ([clusterByAverageLinkage]). Only what
  /// survives the second round is proposed, so a group is never named on
  /// part of its evidence.
  ///
  /// Every answer is cached in `pair_decisions` under the two thread texts'
  /// hashes and [StorylineJudge.decidedBy] (the qhash and the model), so only
  /// a pair never seen in its current texts is asked, at most
  /// [StorylinePolicy.pairBudgetPerPass] of them a pass: the candidates
  /// first, newest threads' pairs first (the pool arrives newest first), and
  /// the completions out of what is left, largest cluster first. A candidate
  /// over the budget reads as p = 0 this pass; a cluster the budget cannot
  /// complete is not proposed this pass and is counted
  /// [GroupingTally.clustersDeferred]. The cache is what makes the sweep
  /// converge over the passes that follow.
  ///
  /// Each row's text is built ONCE here, with its preview rows' bodies
  /// fetched first ([StorylineJudge.threadText]), because the hash that keys
  /// the cache is the hash of the text the model reads. That is a store read
  /// per pool thread in a candidate pair on every pass, whatever the cache
  /// holds.
  ///
  /// The model is asked in batches of [_pairBatch], and each batch's answers
  /// are written only once it returns. A batch that throws parks the lane
  /// with nothing of its own written, and the batches before it stay cached:
  /// the cache is the progress, so the re-run asks only what is left.
  Future<List<List<int>>> _decisionCandidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
    GroupingTally tally,
  ) async {
    final judge = _judge ??
        (throw StateError('StorylineGrouper: no decision judge to ask'));
    // Who answers this pass, and the cache pruned to it: rows another model
    // or question set wrote are never read again, and rows older than
    // [_pairCacheAge] mostly key texts that have since moved on.
    final decidedBy = await judge.decidedBy();
    await _store.prunePairDecisions(
      keep: decidedBy,
      olderThanIso: MessageStore.isoStamp(
        DateTime.now().subtract(_pairCacheAge),
      ),
    );
    final pairs = await _candidatePairs(rows, vectors);
    tally.pairs += pairs.length;
    if (pairs.isEmpty) return const [];

    // One text per row per pass, however many pairs the row is in.
    final texts = <int, StorylineThreadText>{};
    for (final (i, j) in pairs) {
      for (final index in [i, j]) {
        if (texts.containsKey(index)) continue;
        texts[index] = await judge.threadText(
          rows[index]['source'] as String? ?? _workSource,
          rows[index]['conversation_key'] as String? ?? '',
        );
      }
    }
    (String, String) hashesOf((int, int) pair) {
      final a = texts[pair.$1]!.cardHash;
      final b = texts[pair.$2]!.cardHash;
      return a.compareTo(b) <= 0 ? (a, b) : (b, a);
    }

    // Every cached answer among these texts, candidate or not: a completion
    // pair may have been asked on an earlier pass.
    final cached = await _store.pairDecisionsFor(
      [for (final text in texts.values) text.cardHash],
      decidedBy,
    );
    final p = <(int, int), double>{};
    var budget = StorylinePolicy.pairBudgetPerPass;

    /// Asks [asked] in batches, writing each batch once it returns.
    Future<void> ask(List<(int, int)> asked) async {
      for (var start = 0; start < asked.length; start += _pairBatch) {
        final batch = asked.sublist(
          start,
          start + _pairBatch < asked.length
              ? start + _pairBatch
              : asked.length,
        );
        final answers = await judge.sameEffortOfTexts([
          for (final (i, j) in batch) (texts[i]!.text, texts[j]!.text),
        ]);
        tally.scored += batch.length;
        budget -= batch.length;
        // Two texts that render identically share one hash, and a pair of
        // one hash has no row to live in: it is used this pass and asked
        // again on the next, which is rare enough to cost nothing.
        await _store.writePairDecisions(
          [
            for (final (index, pair) in batch.indexed)
              (
                a: hashesOf(pair).$1,
                b: hashesOf(pair).$2,
                p: answers[index],
              ),
          ],
          decidedBy: decidedBy,
        );
        for (final (index, pair) in batch.indexed) {
          p[pair] = answers[index];
        }
      }
    }

    /// The pairs of [asked] with no answer yet, the cached ones filled in.
    List<(int, int)> missingOf(Iterable<(int, int)> asked) {
      final missing = <(int, int)>[];
      for (final pair in asked) {
        if (p.containsKey(pair)) continue;
        final known = cached[hashesOf(pair)];
        if (known != null) {
          p[pair] = known;
          tally.cached++;
        } else {
          missing.add(pair);
        }
      }
      return missing;
    }

    // The candidates. Newest threads' pairs first: the pool is newest first,
    // so the pair with the smaller first index involves the newer thread.
    final missing = missingOf(pairs)
      ..sort((x, y) {
        final byFirst = x.$1.compareTo(y.$1);
        return byFirst != 0 ? byFirst : x.$2.compareTo(y.$2);
      });
    final first = missing.length > budget
        ? missing.sublist(0, budget)
        : missing;
    tally.deferred += missing.length - first.length;
    await ask(first);

    // The optimistic round, then each cluster completed and judged again on
    // the full matrix.
    final formed = averageLinkage(
      rows.length,
      p,
      tau: StorylinePolicy.linkTau,
      maxSize: StorylineTuning.maxClusterSize,
      unscoredAsZero: false,
    ).where((c) => c.length >= StorylineTuning.proposeMinClusterSize).toList();
    sortClusters(formed);

    final out = <({List<int> members, int outliers})>[];
    for (final cluster in formed) {
      final inside = missingOf([
        for (var a = 0; a < cluster.length; a++)
          for (var b = a + 1; b < cluster.length; b++) (cluster[a], cluster[b]),
      ]);
      if (inside.length > budget) {
        tally.clustersDeferred++;
        tally.deferred += inside.length;
        continue;
      }
      await ask(inside);

      final local = <(int, int), double>{
        for (var a = 0; a < cluster.length; a++)
          for (var b = a + 1; b < cluster.length; b++)
            (a, b): ?p[(cluster[a], cluster[b])],
      };
      final judged = clusterByAverageLinkage(
        cluster.length,
        local,
        tau: StorylinePolicy.linkTau,
        // The PROPOSE floor, as on the cosine path: a pair is not a question
        // worth a naming call.
        minSize: StorylineTuning.proposeMinClusterSize,
        maxSize: StorylineTuning.maxClusterSize,
      );
      final dropped =
          cluster.length - judged.clusters.fold<int>(0, (n, c) => n + c.length);
      for (final (index, kept) in judged.clusters.indexed) {
        out.add((
          members: [for (final at in kept) cluster[at]],
          // The members this cluster's judging set aside, once: on the
          // largest group it left, and nowhere if it left none.
          outliers: index == 0 ? dropped : 0,
        ));
      }
    }
    out.sort((a, b) {
      final bySize = b.members.length.compareTo(a.members.length);
      return bySize != 0 ? bySize : a.members.first.compareTo(b.members.first);
    });
    tally.clusterOutliers.addAll([for (final c in out) c.outliers]);
    return [for (final c in out) c.members];
  }

  /// How long a cached pair is kept. A thread's text moves with every new
  /// message, so an old row mostly keys a text nothing renders any more;
  /// one still in use is simply asked again.
  static const Duration _pairCacheAge = Duration(days: 30);

  /// How many pairs one `same_effort` request carries: both orders of each,
  /// so twice this many states. A batch is also the unit a failure loses.
  static const int _pairBatch = 50;

  /// The candidate pairs over [rows], each `(i, j)` with `i < j`, in the
  /// order they were first proposed. See [_decisionCandidates].
  Future<List<(int, int)>> _candidatePairs(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    final seen = <(int, int)>{};
    void add(int a, int b) {
      if (a == b) return;
      seen.add(a < b ? (a, b) : (b, a));
    }

    if (rows.length >= 2) {
      final table = await _similaritiesOf(rows, vectors);
      for (var i = 0; i < rows.length; i++) {
        final near = <({int j, double sim})>[
          for (var j = 0; j < rows.length; j++)
            if (j != i && table.get(i, j) >= StorylinePolicy.pairRetrievalFloor)
              (j: j, sim: table.get(i, j)),
        ]..sort((x, y) {
            final bySim = y.sim.compareTo(x.sim);
            return bySim != 0 ? bySim : x.j.compareTo(y.j);
          });
        for (final hit in near.take(StorylinePolicy.pairNeighbours)) {
          add(i, hit.j);
        }
      }
    }

    final bySeries = <String, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      final key = seriesKeyFor(rows[i]['subject'] as String?);
      if (key.isEmpty) continue;
      bySeries.putIfAbsent(key, () => <int>[]).add(i);
    }
    for (final group in bySeries.values) {
      final members = group.take(StorylineTuning.maxClusterSize).toList();
      for (var a = 0; a < members.length; a++) {
        for (var b = a + 1; b < members.length; b++) {
          add(members[a], members[b]);
        }
      }
    }
    return seen.toList();
  }

  /// Every candidate pair's similarity, computed in Dart — the fallback, and
  /// the definition the index path is measured against. O(n²) against a
  /// mailbox of a few hundred live threads.
  static PairSimilarities _arithmeticSimilarities(
    List<List<double>> vectors,
  ) {
    final table = PairSimilarities(vectors.length);
    for (var i = 0; i < vectors.length; i++) {
      for (var j = i + 1; j < vectors.length; j++) {
        table.set(i, j, cosine(vectors[i], vectors[j]));
      }
    }
    return table;
  }

  /// The candidate pair similarities read off the vec0 index, or null when the
  /// index cannot answer for this candidate set and the caller must do the
  /// arithmetic.
  ///
  /// **This is an equivalence, not an approximation.** Every probe asks for as
  /// many neighbours as the index HOLDS, so each one comes back with the whole
  /// corpus and every candidate pair is seen — twice, once from each end, at
  /// the same number. A pair no probe reported reads 0 out of the table, which
  /// is below every threshold the clustering compares against. The win being
  /// bought is that the distances are computed natively over packed float32
  /// instead of a Dart triple-accumulation per pair; it is emphatically not an
  /// asymptotic one, and asking for fewer neighbours to get one would mean the
  /// sweep proposing different storylines depending on whether an optional
  /// native extension had loaded. Note that the index holds the whole
  /// clustering corpus and the candidates are a subset of it — filed and
  /// finished threads are indexed too — which is exactly why `k` is the index's
  /// row count and not the candidate count: a `k` of the latter would let
  /// already-filed threads crowd a genuine candidate out of a probe's answer.
  ///
  /// What this does NOT do any more is decide anything. It used to return a
  /// boolean adjacency, applying the link threshold as it read each hit; the
  /// compare now lives in [clusterBySimilarity], because the coherence floor
  /// is a mean over every pair inside a cluster and the new join rule puts
  /// sub-threshold pairs inside one by construction.
  ///
  /// Four ways to decline, and each of them says why — once per distinct
  /// reason, per process:
  ///
  /// * a candidate whose vector is not the index's width — a corpus caught
  ///   mid-model-change has rows the index skipped, and a hole in the index is
  ///   a link the probes cannot find;
  /// * no usable index at all, which is the ordinary state of a build without
  ///   the native extension;
  /// * a candidate whose stored embedding is not bytes, which is a corrupt row
  ///   rather than a missing feature;
  /// * a probe that does not find its own row, which is the one cheap check
  ///   that says the index really does hold every candidate.
  ///
  /// The answer is the same in all four — fall back to the arithmetic, cluster
  /// identically, propose the same storylines — so none of them is an error.
  /// But a build that quietly clusters the slow way forever and a corpus with
  /// one bad row are very different things to be told about, and the report is
  /// the only place that distinction survives.
  Future<PairSimilarities?> _indexedSimilarities(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    for (final vector in vectors) {
      if (vector.length != ConversationVectorIndex.dims) {
        _reportBruteForce("a candidate vector is not the index's width");
        return null;
      }
    }

    final indexed = await _store.prepareConversationIndex(
      embedModel: EmbeddingsClient.modelTag,
    );
    if (indexed == null) {
      _reportBruteForce('no usable index');
      return null;
    }

    final position = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final source = rows[i]['source'] as String? ?? _workSource;
      final key = rows[i]['conversation_key'] as String? ?? '';
      position[threadKey(source, key)] = i;
    }

    final table = PairSimilarities(rows.length);
    for (var i = 0; i < rows.length; i++) {
      final blob = rows[i]['embedding'];
      if (blob is! Uint8List) {
        _reportBruteForce('a candidate blob is not bytes');
        return null;
      }
      final hits = await _store.conversationNeighbors(blob, k: indexed);
      var foundSelf = false;
      for (final hit in hits) {
        final j = position[threadKey(hit.source, hit.key)];
        if (j == null) continue;
        if (j == i) {
          foundSelf = true;
          continue;
        }
        // Stored once for the unordered pair, whichever end reported it.
        // Cosine is symmetric and each probe sees the whole corpus, so the
        // second sighting writes the number the first one did — which is what
        // makes the table a genuine symmetric measure rather than something
        // whose clusters could turn on which row was probed first.
        table.set(i, j, hit.similarity);
      }
      if (!foundSelf) {
        _reportBruteForce('the index does not hold every candidate');
        return null;
      }
    }
    return table;
  }

  /// Reasons already reported. Static because the interesting thing is the
  /// BUILD — an app without the native extension falls back on every sweep
  /// forever, and a line per sweep would be noise about a fact that cannot
  /// change.
  static final Set<String> _fallbackReported = {};

  /// Says once, per process, per distinct [reason], that the sweep is
  /// clustering the slow way.
  ///
  /// Keyed on the reason rather than on the fact, exactly like
  /// `EmbeddingsClient._fail`: the four declines are told apart by nothing
  /// else, and a single flag would let whichever one happened first hide the
  /// rest for the life of the process.
  static void _reportBruteForce(String reason) {
    if (!_fallbackReported.add(reason)) return;
    debugPrint('storylines: sweeping by arithmetic — $reason');
  }
}
