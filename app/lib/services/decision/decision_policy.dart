/// What the pipeline does with the decision model's probabilities: the
/// thresholds, the learned gate's reason words, and the sentences a
/// model-decided needs-you verdict carries.
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

  /// A needs-you yes at p(needs_you = yes) ≥ this.
  static const double needsYouYes = 0.65;

  /// The same, for a stranger's first approach (the handler's own cold
  /// outreach rule): outreach is written to read as an ask, so the bar moves.
  static const double needsYouYesCold = 0.85;

  /// A needs-you no below this. Between [needsYouNo] and the yes bar is the
  /// BAND, which goes to the generative model exactly as before.
  static const double needsYouNo = 0.35;

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

/// The sentence a model-decided needs-you YES carries as `needs_you_reason`.
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

/// The sentence a model-decided needs-you NO carries.
const String needsYouNoReason = 'Nothing here asks for you.';
