import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/conversation_vec_index.dart';
import '../data/message_store.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/storyline_tasks.dart';
import 'storyline_cards.dart';
import 'storyline_clustering.dart';
// `show`: the two things that stay declared with the service. Narrowed so the
// card statics above can only come from `storyline_cards.dart` itself — the
// service re-exports that file, and an unrestricted import here would make the
// direct one above redundant.
import 'storyline_service.dart' show GroupingMode, StorylineTuning;

/// What one sweep's model-read grouping did, counted for the activity row.
///
/// Mutable and handed DOWN rather than returned, so that
/// `StorylineGrouper._groupCandidates` can answer in exactly the shape
/// `_clusterCandidates` answers in — a list of index lists — and the branch
/// between them stays one expression with nothing below it that knows which
/// ran.
class GroupingTally {
  /// Grouping calls made. One per piece shown to the model, which is one per
  /// neighbourhood except where the card budget split a neighbourhood up.
  int calls = 0;

  /// Threads placed in a returned group big enough to propose.
  int grouped = 0;

  /// Calls that left their piece ungrouped: the answer threw, or it named no
  /// group at all. The two are one number deliberately — an empty answer is
  /// an honest reading of a neighbourhood that holds nothing, and what the
  /// row is measuring is how much of the pool the pass could not use.
  int failed = 0;

  /// Pieces dropped before any call: too few threads left after a split, or
  /// still too wide to show in one call at the top of the ladder.
  int unfit = 0;
}

/// How a sweep's pool becomes candidate clusters.
///
/// One entry point, [candidates], and behind it the two passes
/// [GroupingMode] names: the cosine clustering that ships, and the model-read
/// grouping that reads a neighbourhood or a whole chunk of the pool at once.
/// Both answer in index lists into the rows they were handed, so nothing above
/// this class can tell which ran — which is what keeps the namer, the confirms,
/// the observer and the tombstones identical in either mode.
///
/// It came out of `storyline_service.dart` with its block intact. Nothing here
/// touches a membership, a storyline row or the activity log: the grouping is
/// pure pair-discovery plus at most one prose call per piece, and the only
/// state it keeps is the process-wide set of fallback reasons already printed.
class StorylineGrouper {
  StorylineGrouper(
    this._store,
    this._groupClient, {
    this._mode = StorylineTuning.groupingMode,
  });

  /// The fallback source label for a conversation row that carries none of its
  /// own. A copy of `StorylineService._workSource` rather than a reference to
  /// it: it is a constant, and such a row predates the second connector, so it
  /// is mail.
  static const String _workSource = 'email';

  final MessageStore _store;

  /// Where the neighbourhood and pool grouping questions go. Never dialled
  /// while [_mode] reads [GroupingMode.cosine], which is what ships.
  final LlmClient _groupClient;

  /// Which pass this grouper groups with. [StorylineTuning.groupingMode] for
  /// every caller in `lib/`; a test may pass another to exercise a dark path
  /// without flipping a const the whole suite reads.
  final GroupingMode _mode;

  /// The clusters [rows] should be considered in, by whichever pass [_mode]
  /// names.
  ///
  /// The branch lives here rather than at the call site so the sweep asks one
  /// question and reads one answer: index lists into [rows], members ascending,
  /// largest cluster first. [tally] is filled in only by the model-read passes,
  /// which is why the cosine path leaves every one of its counters at zero, and
  /// [room] is the number of proposals the sweep still has slots for.
  Future<List<List<int>>> candidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
    GroupingTally tally, {
    required int room,
  }) async =>
      _mode == GroupingMode.cosine
          ? await _clusterCandidates(rows, vectors)
          : await _groupCandidates(rows, vectors, tally, room: room);

  /// The clusters this sweep will consider, from whichever pair-discovery is
  /// available.
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

  /// The one pairwise table a sweep builds, whichever pass reads it.
  ///
  /// Factored out when the model-read grouping arrived rather than copied
  /// into it: the index probe is a query per candidate row, and two passes
  /// each building their own table would double that for an answer that is
  /// the same both times.
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

  /// The clusters this sweep will consider when a MODEL does the grouping:
  /// the cosine pass draws neighbourhoods and [GroupThreadsTask] says what is
  /// inside each one.
  ///
  /// Answers in the same shape [_clusterCandidates] answers in — index lists
  /// into [rows], members ascending, nothing below the branch point able to
  /// tell which pass ran — which is what keeps the namer, the confirms, the
  /// observer and the tombstones identical in both modes. The tombstone is
  /// keyed on the member SET, so an identical group is recognised whichever
  /// pass proposed it.
  ///
  /// Three steps, and each one is a place a thread can drop out:
  ///
  /// * the neighbourhoods, at [StorylineTuning.groupingNeighbourhoodThreshold]
  ///   with no coherence split — a region, not a proposal, so the only thing
  ///   allowed to break one up is size;
  /// * the card budget, which fits twelve whole cards in one call: a
  ///   neighbourhood above that is re-clustered up the [clusterBySimilarity]
  ///   ladder until every piece fits, and a piece that is still too wide at
  ///   [StorylineTuning.clusterSplitCeiling] is dropped unasked;
  /// * the call itself, whose groups under
  ///   [StorylineTuning.proposeMinClusterSize] are dropped for the same
  ///   reason a cosine cluster of two is.
  ///
  /// [room] is the number of proposals the sweep still has slots for, and it
  /// is a budget on the CALLS as well as on the proposals: a naming call is
  /// spent per cluster and the sweep breaks at `room`, so a pool of forty
  /// neighbourhoods would otherwise spend forty prose calls to build a list
  /// the caller reads three entries of. Pieces past the budget are left
  /// unasked and are NOT counted `unfit`: nothing was judged about them, and
  /// a count that mixed "the model could not use this" with "the pass ran out
  /// of room" would be unreadable on a ledger row. Under [GroupingMode.pool]
  /// it is not a budget on the calls at all: there are two of them on a pool
  /// this size and the mode exists to read the whole thing.
  ///
  /// Deterministic at temperature 0 on a fixed order: the neighbourhoods are
  /// walked in the pool's own order, the cards inside one are ordered by
  /// centrality, and the members of every group come back ascending.
  Future<List<List<int>>> _groupCandidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
    GroupingTally tally, {
    required int room,
  }) async {
    // Under [GroupingMode.pool] there is no neighbourhood and no similarity
    // table: the pool's own order is the chunking, consecutive slices of
    // [StorylineTuning.poolCardsPerCall] cards, one call each. Deterministic
    // because the store's order is, and nothing below this branch runs — no
    // `clusterBySimilarity`, no ladder, no [_fittingPieces].
    //
    // And NO `room` break, which is the one place this branch departs from the
    // cosine path deliberately. `room` is at most
    // [StorylineTuning.maxPendingSuggestions], three, so a first chunk that
    // returned three groups would end the loop with the second half of the
    // mailbox unread — and reading the whole pool is the entire point of the
    // mode. The cost it would be saving is small here in a way it is not
    // there: a pool of about seventy threads is two prose calls a pass, where
    // the cosine path can draw forty neighbourhoods. `_propose` still spends
    // `room` on the sorted list below, so what ships is unchanged; only what
    // was LOOKED at is.
    if (_mode == GroupingMode.pool) {
      final poolClusters = <List<int>>[];
      for (var start = 0;
          start < rows.length;
          start += StorylineTuning.poolCardsPerCall) {
        final chunk = [
          for (var i = start;
              i < start + StorylineTuning.poolCardsPerCall && i < rows.length;
              i++)
            i,
        ];
        // The tail of the pool can be shorter than a group. Counted `unfit`
        // and never asked, for [_fittingPieces]'s reason.
        if (chunk.length < StorylineTuning.groupingNeighbourhoodMinSize) {
          tally.unfit++;
          continue;
        }
        poolClusters.addAll(await _groupOne(
          rows,
          vectors,
          chunk,
          tally,
          cardsPerCall: StorylineTuning.poolCardsPerCall,
        ));
      }
      // The same order the cosine path answers in, spelled out for the same
      // reason: `List.sort` makes no stability promise and a tombstone has to
      // keep answering for the same set on a second pass.
      poolClusters.sort((a, b) {
        final bySize = b.length.compareTo(a.length);
        return bySize != 0 ? bySize : a.first.compareTo(b.first);
      });
      return poolClusters;
    }

    final table = await _similaritiesOf(rows, vectors);
    final neighbourhoods = clusterBySimilarity(
      vectors.length,
      table.get,
      threshold: StorylineTuning.groupingNeighbourhoodThreshold,
      minSize: StorylineTuning.groupingNeighbourhoodMinSize,
      maxSize: StorylineTuning.groupingNeighbourhoodCap,
      // No coherence floor, which is the whole difference from [_clusterBy]:
      // a neighbourhood is allowed to be a blob. Splitting it on its mean
      // would re-form exactly the tight little clusters the cosine pass
      // already makes and leave the model nothing to decide.
      floor: 0,
      step: StorylineTuning.clusterSplitStep,
      ceiling: StorylineTuning.clusterSplitCeiling,
    )
      // Walked in the pool's own order, which is the one thing that is the
      // same on a second run. What comes BACK is sorted largest-first below,
      // because the sweep spends its room on the head of the list.
      ..sort((a, b) => a.first.compareTo(b.first));

    final clusters = <List<int>>[];
    outer:
    for (final neighbourhood in neighbourhoods) {
      for (final piece in _fittingPieces(neighbourhood, table.get, tally)) {
        if (clusters.length >= room) break outer;
        clusters.addAll(await _groupOne(rows, vectors, piece, tally,
            cardsPerCall: _groupingCardsPerCall));
      }
    }
    // The same order [clusterBySimilarity] hands its clusters back in:
    // largest first, ties by smallest member index. The sweep breaks at
    // `room`, so the order IS what ships, and a proposal of six threads is a
    // better use of a slot than one of three. Spelled out rather than left to
    // the sort, for that function's reason: `List.sort` makes no stability
    // promise, and this pass has to answer identically on a second run for a
    // tombstone to keep holding.
    clusters.sort((a, b) {
      final bySize = b.length.compareTo(a.length);
      return bySize != 0 ? bySize : a.first.compareTo(b.first);
    });
    return clusters;
  }

  /// How many whole cards fit one grouping call on the COSINE path: twelve.
  /// The task reads the same number into its schema's two `maxItems`, so the
  /// split ladder and the grammar cannot disagree about how many cards a call
  /// holds. The card budget is what this ladder wants, which is why it reads
  /// `defaultCardsPerCall` and not either of the two ceilings derived from
  /// it. [GroupingMode.pool] asks for its own number instead —
  /// [StorylineTuning.poolCardsPerCall] — and never comes down this ladder.
  static const int _groupingCardsPerCall =
      GroupThreadsTask.defaultCardsPerCall;

  /// [members] as pieces the card budget can show in one call each, splitting
  /// up the same threshold ladder [clusterBySimilarity] settles a capped
  /// cluster with.
  ///
  /// Whole cards or nothing: truncating the joined set instead would hand the
  /// model a last thread cut mid-sentence and then read its number back as a
  /// group member. A piece that falls under
  /// [StorylineTuning.groupingNeighbourhoodMinSize] on the way down, and a
  /// piece still too wide at the top of the ladder, are both counted `unfit`
  /// and dropped — nothing is asked about them, so nothing is tombstoned
  /// either.
  static List<List<int>> _fittingPieces(
    List<int> members,
    double Function(int, int) sim,
    GroupingTally tally,
  ) {
    final fitting = <List<int>>[];
    var pending = <List<int>>[members];
    var threshold = StorylineTuning.groupingNeighbourhoodThreshold;
    while (pending.isNotEmpty) {
      final tooWide = <List<int>>[];
      for (final piece in pending) {
        if (piece.length > _groupingCardsPerCall) {
          tooWide.add(piece);
        } else if (piece.length >=
            StorylineTuning.groupingNeighbourhoodMinSize) {
          fitting.add(piece);
        } else {
          tally.unfit++;
        }
      }
      if (tooWide.isEmpty) break;
      threshold += StorylineTuning.clusterSplitStep;
      if (threshold > StorylineTuning.clusterSplitCeiling + 1e-9) {
        tally.unfit += tooWide.length;
        break;
      }
      pending = [
        for (final piece in tooWide) ..._splitAt(piece, sim, threshold),
      ];
    }
    fitting.sort((a, b) => a.first.compareTo(b.first));
    return fitting;
  }

  /// [piece] re-clustered among itself at [threshold], in the piece's own
  /// index space, back as indexes into the pool.
  ///
  /// `minSize: 1` because every member has to come back: what is too small to
  /// group is the caller's count, and a member quietly dropped here would be
  /// a thread the row never accounted for.
  static List<List<int>> _splitAt(
    List<int> piece,
    double Function(int, int) sim,
    double threshold,
  ) {
    final split = clusterBySimilarity(
      piece.length,
      (i, j) => sim(piece[i], piece[j]),
      threshold: threshold,
      minSize: 1,
      maxSize: StorylineTuning.groupingNeighbourhoodCap,
      floor: 0,
      step: StorylineTuning.clusterSplitStep,
      ceiling: StorylineTuning.clusterSplitCeiling,
    );
    return [
      for (final cluster in split)
        [for (final index in cluster) piece[index]]..sort(),
    ];
  }

  /// One grouping call over [piece], and the groups it named that are worth
  /// proposing.
  ///
  /// The cards are the naming call's cards, built by the same recipe and
  /// ordered by centrality, so a thread reads the same to the model that
  /// groups it as to the model that names the group. The numbers the answer
  /// comes back with are mapped through that centrality order, and the range
  /// check is here rather than in the task for [NameStorylineTask]'s reason:
  /// only the caller knows how many cards it showed.
  ///
  /// [LlmUnavailableException] propagates, exactly as the naming call's does,
  /// so the worker parks the sweep and re-runs it with its attempt unspent. A
  /// malformed answer or a refusal is counted and the pass carries on: one
  /// neighbourhood the model could not read is not a reason to abandon the
  /// rest of the mailbox.
  /// [cardsPerCall] is how many cards this call may show, and it is the
  /// caller's because the two grouping modes ask different questions: the
  /// cosine path splits a neighbourhood down to [_groupingCardsPerCall],
  /// while [GroupingMode.pool] hands over a slice of
  /// [StorylineTuning.poolCardsPerCall]. The task derives its whole-set clamp
  /// and both of its array bounds from it, so the grammar always agrees with
  /// what was sent.
  Future<List<List<int>>> _groupOne(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
    List<int> piece,
    GroupingTally tally, {
    required int cardsPerCall,
  }) async {
    final task = GroupThreadsTask(cardsPerCall: cardsPerCall);
    var central = centralIndexes(
      [for (final index in piece) vectors[index]],
      take: piece.length,
    );
    final cards = <String>[];
    for (final at in central) {
      final row = rows[piece[at]];
      cards.add(namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          row['source'] as String? ?? _workSource,
          row['conversation_key'] as String? ?? '',
        ),
      ));
    }
    // The task's OWN belt, not the namer's. At the default twelve cards the
    // two differ by 45 characters — 7,255 against 7,300 — and building to the
    // larger would leave an overhang `buildUserMessage` then cuts mid-sentence,
    // which is the one thing the whole-cards rule exists to prevent. Twelve
    // whole cards fit under either number, so the shipped path is unchanged;
    // at [StorylineTuning.poolCardsPerCall] this is the only cap a chunk of
    // that size fits under at all.
    final numbered = numberedCards(cards, cap: task.cardsCap);
    // Dropping from the far end can leave fewer cards than there are central
    // indexes, and card `[k]` must keep meaning the k-th of what was SENT.
    final shown = numbered.length;
    central = central.take(shown).toList();
    if (shown < StorylineTuning.groupingNeighbourhoodMinSize) {
      tally.unfit++;
      return const [];
    }

    tally.calls++;
    GroupResult result;
    try {
      result = await runTask(
        _groupClient,
        task,
        GroupInput(numbered),
        maxTokens: GroupThreadsTask.maxTokens,
        temperature: 0,
      );
    } on LlmUnavailableException {
      rethrow;
    } catch (_) {
      tally.failed++;
      return const [];
    }
    if (result.groups.isEmpty) {
      tally.failed++;
      return const [];
    }

    final clusters = <List<int>>[];
    for (final group in result.groups) {
      // A set, though the task already de-duplicates across the whole answer:
      // the range check below can map two different out-of-range numbers to
      // nothing and two in-range ones to the same card only if that guarantee
      // ever weakens, and a repeated member would be written twice.
      final members = <int>{
        for (final number in group.threads)
          if (number >= 1 && number <= shown) piece[central[number - 1]],
      }.toList()
        ..sort();
      if (members.length < StorylineTuning.proposeMinClusterSize) continue;
      tally.grouped += members.length;
      clusters.add(members);
    }
    return clusters;
  }

  /// Every candidate pair's similarity, computed in Dart — the fallback, and
  /// the definition the index path is measured against.
  ///
  /// Full agglomerative clustering — repeatedly merging the closest pair —
  /// would find slightly better groups and is O(n³) on a list that is
  /// re-clustered after every sync. This is O(n²) against a mailbox of a few
  /// hundred live threads, and the model call behind each proposal is the part
  /// that decides quality anyway.
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
