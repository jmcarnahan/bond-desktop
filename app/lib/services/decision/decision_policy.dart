/// What the pipeline does with the decision model's probabilities: the
/// thresholds, the learned gate's reason words, and the needs-you probability
/// with the sentence it carries. The needs-you CUT is not here: it is the
/// owner's slider (`needs_you_predicate.dart`).
library;

import 'decision_heads.dart';

/// The thresholds every decided field is read against.
///
/// Fitted on the golden set in jev-prototype (the decision-model bake-off);
/// move one only with a `make golden-decision` row on each side. One file, so
/// a threshold is never spelled twice.
abstract final class DecisionPolicy {
  /// The learned gate drops a rules-kept message at p(gate = drop) ≥ this.
  static const double gateDrop = 0.70;

  /// `needs_action` is yes at p ≥ this.
  static const double booleanYes = 0.50;

  /// `reply_expected` is yes at p ≥ this.
  static const double replyYes = 0.50;
}

/// The `gate_reason` a drop_reason becomes. Every reason the model can give
/// except `cold_outreach` (never gates) and `other` (→ `model_other`).
const Map<String, String> _gateReasonFor = {
  'newsletter': 'newsletter',
  'no_reply': 'no_reply',
  'auto_generated': 'auto_generated',
  'monitoring': 'monitoring',
  'machine_sender': 'machine_sender',
  'outbound': 'outbound',
  'empty': 'empty',
  'ticket_system': 'ticket_system',
  'identity_service': 'identity_service',
  'share_notification': 'share_notification',
  'digest': 'digest',
  'other': 'model_other',
};

/// Every `gate_reason` word [learnedGateReason] can write. The rules gates
/// share some of these words, so a word alone never says the MODEL dropped a
/// message: a reader pairs it with the stored p(drop) ≥
/// [DecisionPolicy.gateDrop] (the Why panel's `dropped`).
///
/// `other` already maps to `model_other` in the table above, so the table's
/// values are the whole set.
final Set<String> learnedGateReasons = {..._gateReasonFor.values};

/// The learned gate: the `gate_reason` to drop this message with, or null to
/// keep it.
///
/// Drops at p(gate = drop) ≥ [DecisionPolicy.gateDrop] unless the model's
/// drop reason is `cold_outreach` — a human writing to the owner stays kept,
/// however unsolicited. The reason words reuse the rules gates' where the two
/// mean the same thing; provenance (rules or model) lives in
/// `message_decisions` and the activity row, not in a new word.
String? learnedGateReason(DecisionAnswers a) {
  if (a.p('gate', 'drop') < DecisionPolicy.gateDrop) return null;
  final reason = a['drop_reason'].choice;
  if (reason == 'cold_outreach') return null;
  return _gateReasonFor[reason] ?? 'model_other';
}

/// The decision's p(needs_you = yes), or null when the answers carry no
/// needs-you head at all (an unreadable stored row). The same number
/// `message_decisions.needs_you_p` stores, and the one `messages.needs_you_p`
/// carries for Needs You to read against the owner's slider.
double? needsYouP(DecisionAnswers a) =>
    a.fields.containsKey('needs_you') ? a.p('needs_you', 'yes') : null;

/// The sentence a model-decided needs-you probability carries as
/// `needs_you_reason`, written beside it whatever its value: whether it reads
/// as a yes is the slider's call, at read time.
///
/// The Why panel and the rail's "can it explain itself" check read that
/// column, and the decision model writes no evidence of its own, so the
/// reason is templated from its intent and reply answers.
String needsYouYesReason(DecisionAnswers a) {
  switch (a['intent'].choice) {
    case 'approval':
      return 'Asks you to approve something.';
    case 'question':
      return 'Asks you a question.';
    case 'request':
      return 'Asks you to do something.';
    case 'scheduling':
      return 'Asks you about a time.';
  }
  if (a.p('reply_expected', 'yes') >= DecisionPolicy.replyYes) {
    return 'Expects a reply from you.';
  }
  return 'Names you and needs your attention.';
}
