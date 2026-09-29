import 'package:flutter/foundation.dart' show immutable;

import 'decision_heads.dart';

/// The key in `answers_json` that records whether the state carried an owner
/// line. Not one of the nine field names, and a bool rather than a Map, so it
/// can never be read as an answer.
const String decisionOwnerKnownKey = 'owner_known';

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
  });
}
