/// The owner's own Needs You answers, applied to every decision: a label on
/// the message itself, or on a message whose decision vector is a near
/// duplicate of this one's.
///
/// The owner's "Remove from Needs You" / "Add to Needs You" presses are rows
/// of `decision_labels` (`MessageStore.writeNeedsYouLabel`), each with the
/// decision model's vector of the pressed message. `applyDecision` asks
/// [NeedsYouExemplars.answerFor] before it stores a decision, and when an
/// answer comes back the decision's `needs_you` becomes the owner's (1.0 or
/// 0.0). Every decision path passes through `applyDecision`, so the triage
/// claim, the needs-you pass, the install-time re-decide and Re-judge all
/// inherit the answer without code of their own, and no Needs You query
/// changes: the number they read already carries it.
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../data/message_store.dart';
import '../llm/embeddings_client.dart' show cosine;
import 'decision_heads.dart';

/// The one measured constant of the exemplar match.
abstract final class NeedsYouExemplarTuning {
  /// A label generalises to a message whose decision vector is at least this
  /// close (cosine, raw v3 pooled vectors) under the same model.
  ///
  /// Measured on the owner's Needs You audit (2026-10-01, 321 threads: 80
  /// right, 185 wrong, 56 on the bubble): at 0.97, 137 of the 185 wrong
  /// threads have a same-verdict neighbour and no correct or bubble thread
  /// sits inside the radius; 0.95 catches one bubble thread and 0.90 two.
  /// Unrelated pairs sit at a median of 0.27 and templated duplicates at
  /// 0.99 or above, so the cut has room on both sides. Centering the vectors
  /// changed nothing. Two presses cleared 125 wrong threads with zero correct
  /// ones caught.
  static const double matchCosine = 0.97;
}

/// The owner's answer for one message, and where it came from.
@immutable
class OwnerAnswer {
  /// `yes` or `no`.
  final String answer;

  /// The `decision_labels` row that answered.
  final int labelId;

  /// The cosine between the two vectors; 1.0 for a label on this very
  /// message.
  final double cosine;

  /// Whether the label is on this very message rather than a near duplicate.
  final bool exact;

  const OwnerAnswer({
    required this.answer,
    required this.labelId,
    required this.cosine,
    required this.exact,
  });
}

/// The owner's Needs You labels, held in memory and matched against each
/// decision.
///
/// Loaded lazily on first use and dropped by [invalidate] after any write, so
/// a press is seen by the very next decision. A few hundred labels at most
/// (one per press per message), so the nearest-neighbour scan is linear.
///
/// The cache also checks itself: every [load] reads the labels' signature
/// (`MessageStore.needsYouLabelSignature`, a count and the highest id) and
/// reads the list again when it moved. A wipe — sign-out, Forget everything,
/// the identity guard — deletes the rows without telling this object, and one
/// account's answers must never decide the next account's mail.
///
/// So the [invalidate] after an insert or a delete (a press, an undo) is
/// belt-and-braces, save for a delete followed by an insert that reuses the
/// same highest id. The LOAD-BEARING call is the one after the vector-heal
/// UPDATE in `applyDecision`: an UPDATE moves neither the count nor the
/// highest id, so without it the healed vector would go unseen.
class NeedsYouExemplars {
  final MessageStore _store;

  /// The loaded labels and the signature they were read under. Only a read
  /// that ANSWERED is kept: a throw leaves both null, so the next call asks
  /// again rather than rethrowing one hiccup on every decision.
  List<NeedsYouLabel>? _labels;
  ({int count, int maxId})? _signature;

  NeedsYouExemplars(this._store);

  /// The labels, oldest first, read again only after [invalidate] or when
  /// the table's signature moved.
  Future<List<NeedsYouLabel>> load() async {
    final signature = await _store.needsYouLabelSignature();
    final cached = _labels;
    if (cached != null && signature == _signature) return cached;
    final labels = await _store.needsYouLabels();
    _labels = labels;
    _signature = signature;
    return labels;
  }

  /// Forgets the loaded labels; the next [load] reads them again.
  void invalidate() {
    _labels = null;
    _signature = null;
  }

  /// Every label on the message itself, oldest first.
  Future<List<NeedsYouLabel>> labelsOn({
    required String source,
    required String sourceMessageId,
  }) async =>
      [
        for (final label in await load())
          if (label.source == source &&
              label.sourceMessageId == sourceMessageId)
            label,
      ];

  /// The owner's answer for message [sourceMessageId], or null when the
  /// model's own stands.
  ///
  /// The newest label on the message itself wins, whatever any vector says.
  /// Otherwise the nearest label by [cosine] over the labels taken under
  /// [model] with a vector, when it is at least
  /// [NeedsYouExemplarTuning.matchCosine] (the newest wins a tie). A label
  /// under another model is never compared — two models' vectors live in
  /// different spaces — and a decision with no [vector] (Kev) matches only by
  /// id.
  Future<OwnerAnswer?> answerFor({
    required String source,
    required String sourceMessageId,
    List<double>? vector,
    required String model,
  }) async {
    final labels = await load();
    NeedsYouLabel? exact;
    for (final label in labels) {
      if (label.source == source && label.sourceMessageId == sourceMessageId) {
        exact = label;
      }
    }
    if (exact != null) {
      return OwnerAnswer(
        answer: exact.answer,
        labelId: exact.id,
        cosine: 1.0,
        exact: true,
      );
    }
    if (vector == null) return null;
    NeedsYouLabel? best;
    var bestCosine = NeedsYouExemplarTuning.matchCosine;
    for (final label in labels) {
      final other = label.vector;
      if (other == null || label.vectorModel != model) continue;
      final c = cosine(vector, other);
      if (c >= bestCosine) {
        best = label;
        bestCosine = c;
      }
    }
    if (best == null) return null;
    return OwnerAnswer(
      answer: best.answer,
      labelId: best.id,
      cosine: bestCosine,
      exact: false,
    );
  }
}

/// The owner's answer in place of the model's.
extension NeedsYouOverride on DecisionAnswers {
  /// A copy whose `needs_you` is [answer] (`yes` or `no`) with certainty —
  /// p(yes) 1.0 or 0.0 — and which carries the owner's answer
  /// ([DecisionAnswers.ownerAnswer], [exact]) so its reason says so. Every
  /// other field is the model's.
  DecisionAnswers withNeedsYou(String answer, {bool exact = false}) {
    final yes = answer == 'yes';
    return DecisionAnswers(
      {
        ...fields,
        'needs_you': ChoiceAnswer(
          choice: yes ? 'yes' : 'no',
          confidence: 1.0,
          probabilities: {'yes': yes ? 1.0 : 0.0, 'no': yes ? 0.0 : 1.0},
        ),
      },
      ownerAnswer: yes ? 'yes' : 'no',
      ownerExact: exact,
    );
  }
}
