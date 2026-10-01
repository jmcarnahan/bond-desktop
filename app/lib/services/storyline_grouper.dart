import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/conversation_vec_index.dart';
import '../data/message_store.dart';
import 'llm/embeddings_client.dart';
import 'storyline_cards.dart';
import 'storyline_clustering.dart';
// `show`: the one thing that stays declared with the service. Narrowed so the
// card statics above can only come from `storyline_cards.dart` itself — the
// service re-exports that file, and an unrestricted import here would make the
// direct one above redundant.
import 'storyline_service.dart' show StorylineTuning;

/// How a sweep's pool becomes candidate clusters: the cosine clustering.
///
/// One entry point, [candidates], answering in index lists into the rows it
/// was handed, so the namer, the confirms, the observer and the tombstones
/// above it read one shape.
///
/// Nothing here touches a membership, a storyline row or the activity log,
/// and the only state it keeps is the process-wide set of fallback reasons
/// already printed.
class StorylineGrouper {
  StorylineGrouper(this._store);

  /// The fallback source label for a conversation row that carries none of its
  /// own. A copy of `StorylineService._workSource` rather than a reference to
  /// it: it is a constant, and such a row predates the second connector, so it
  /// is mail.
  static const String _workSource = 'email';

  final MessageStore _store;

  /// The clusters [rows] should be considered in: index lists into [rows],
  /// members ascending, largest cluster first.
  ///
  /// The split is deliberate and narrow: measuring the pairs is the part an
  /// index can do faster, and forming the clusters out of them is the part
  /// whose determinism the tombstones depend on. So both paths build the same
  /// table of similarities and hand it to the same [_clusterBy], and the only
  /// thing that varies is who measured "how close are rows i and j".
  Future<List<List<int>>> candidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    final table = await _indexedSimilarities(rows, vectors) ??
        _arithmeticSimilarities(vectors);
    return _clusterBy(vectors.length, table.get);
  }

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
