import 'package:flutter/foundation.dart' show immutable;

import 'decision_heads.dart';

/// The key in `answers_json` that records whether the state carried an owner
/// line. Not one of the nine field names, and a bool rather than a Map, so it
/// can never be read as an answer.
const String decisionOwnerKnownKey = 'owner_known';

/// The keys in `answers_json` that record the owner's Needs You answer when
/// it replaced the model's (`applyDecision`, `NeedsYouExemplars`): the answer
/// (`yes`/`no`), the `decision_labels` row it came from, the cosine between
/// the two vectors (1.0 for a label on this very message), and whether the
/// label was on this very message. Scalars, never a Map, so
/// `DecisionAnswers.fromJson` never reads one as a field.
const String decisionOwnerAnswerKey = 'owner_answer';
const String decisionOwnerLabelIdKey = 'owner_label_id';
const String decisionOwnerCosineKey = 'owner_cosine';
const String decisionOwnerExactKey = 'owner_exact';

/// The key in `answers_json` that keeps the MODEL's own p(needs_you = yes)
/// beside an owner's override (`applyDecision`), so a stored decision can be
/// applied again once the labels behind the override are gone — an undo, a
/// Forget — and the model's number comes back without a model call
/// ([StoredDecision.modelAnswers]). A scalar, like its siblings above.
const String decisionModelNeedsYouKey = 'model_needs_you_p';

/// The key in `answers_json` that marks a message the install-time re-decide
/// could not decide (a 4xx that one request earned). The row carries the
/// current question hash, so the re-decide's stale list stops returning it,
/// while `MessageStore.decisionFor` reads it as no decision at all: its
/// answers, if any, are an older model's. `MessageStore.writeDecision`
/// replaces the whole blob, so a later decision clears the mark.
const String decisionRedecideFailedKey = 'redecide_failed';

/// One message's stored decision, as `MessageStore.decisionFor` reads it
/// back from `message_decisions`.
@immutable
class StoredDecision {
  /// Every head's answer, decoded from `answers_json`. Empty when the blob
  /// was unreadable, so `answers.fields.isEmpty` is the reader's guard.
  final DecisionAnswers answers;
  final String model;

  /// p(gate = drop).
  final double? gateP;

  /// p(needs_you = yes).
  final double? needsYouP;

  /// p(needs_action = yes).
  final double? needsActionP;

  /// p(reply_expected = yes).
  final double? replyExpectedP;
  final double? latencyMs;
  final bool truncated;

  /// Whether the state the model read carried an owner line. False for an
  /// ownerless decision AND for a row written without the key. Its needs-you
  /// probability is shown but untrusted: the needs-you pass decides the
  /// message again once the owner is known.
  final bool ownerKnown;

  /// The owner's Needs You answer (`yes`/`no`) when it replaced the model's
  /// ([decisionOwnerAnswerKey]); null for a decision the model alone made.
  /// The stored [needsYouP] is then 1.0 or 0.0.
  String? get ownerAnswer => answers.ownerAnswer;

  /// The model's own p(needs_you = yes) when the owner's answer replaced it
  /// ([decisionModelNeedsYouKey]); null for a decision the model alone made
  /// (its [needsYouP] is the model's) and for an override written before the
  /// key existed (the model's number is then lost).
  final double? modelNeedsYouP;

  /// The decision model's raw pooled vector of the message, decoded from the
  /// row's `vector` BLOB (float32), or null on a backend with no vector (Kev)
  /// and on a row decided before v24.
  final List<double>? vector;

  /// The tag [vector] lives under: the row's [model].
  String get vectorModel => model;

  const StoredDecision({
    required this.answers,
    required this.model,
    this.gateP,
    this.needsYouP,
    this.needsActionP,
    this.replyExpectedP,
    this.latencyMs,
    this.truncated = false,
    this.ownerKnown = false,
    this.modelNeedsYouP,
    this.vector,
  });

  /// The answers the MODEL gave, with no owner's answer in them: [answers]
  /// as stored when the model alone decided, else with `needs_you` put back
  /// from [modelNeedsYouP]. Null when they cannot be had without asking the
  /// model again — an unreadable row, or an override that did not keep the
  /// model's number.
  DecisionAnswers? get modelAnswers {
    if (answers.fields.isEmpty || !answers.fields.containsKey('needs_you')) {
      return null;
    }
    if (answers.ownerAnswer == null) return DecisionAnswers(answers.fields);
    final p = modelNeedsYouP;
    if (p == null) return null;
    return DecisionAnswers({
      ...answers.fields,
      'needs_you': ChoiceAnswer.fromProbabilities(
        decisionOptions['needs_you']!,
        {'yes': p, 'no': 1 - p},
      ),
    });
  }
}
