import '../models/message_models.dart';
import 'classification.dart';
import 'decision/decision_policy.dart';

// Whether a reply may be offered at all — the rule the draft queue, the draft
// handler and the composer all ask. Model-free: it reads the stored gate word
// and the message's own headers, nothing else.

/// The `gate_reason` slugs that say a machine wrote the message.
///
/// Every one of them is a reason `gates.dart` already refused to spend a model
/// call on, read here for the messages that carry one anyway: the `teams_source`
/// tolerance lets a gated row through the draft queue, a gate can fire on the
/// second call after a draft was already enqueued, and a row an older build
/// stored keeps whatever word that build wrote.
///
/// Not every gate reason belongs here. `self`, `sender_rule`, `monitoring` and
/// `machine_sender` all gate mail for reasons that say nothing about whether a
/// reply is owed, and `teams_source` is not a judgement at all. The decision
/// model's learned gate adds four machine senders nobody replies to; its
/// catch-all `model_other` stays out for the reason `monitoring` does.
const Set<String> automatedGateReasons = {
  'no_reply',
  'newsletter',
  'auto_generated',
  'meeting_response',
  'ticket_system',
  'identity_service',
  'share_notification',
  'digest',
};

/// Whether no reply may be offered for [message] — ever, by anybody.
///
/// The one authority on the question, asked at three points that would otherwise
/// each grow their own answer: the draft queue ahead of the prefetch
/// (`extract_handler.dart`), the handler that would write a draft for it
/// (`draft_handler.dart`), and the composer that would offer
/// **Suggest a reply** over it (`DraftState.suggestable`). A procurement
/// platform's comment notification reached all three and came back with a
/// drafted reply to a no-reply mailer; the real action was in the platform.
///
/// It is a judgement at READ TIME and it stores nothing. No column is written,
/// no verdict is overwritten, and a message whose headers arrive later — the
/// detail fetch is what gives [classificationOf] anything to read — simply gets
/// a different answer the next time somebody asks. A stored suppression would
/// be a third opinion about mail the gates and the model already
/// have one each.
///
/// TWO signals, and the second is the one that does the work. The `gate_reason`
/// arm is the belt: a gated message rarely reaches the draft paths at all.
/// [classificationOf] answering `automated_notification` is the braces, and it
/// is what catches the mail in the report — `Auto-Submitted`, `List-Id`,
/// `List-Unsubscribe` on a notification nothing gated, which triage then read as
/// an ask because the body politely asks the reader to approve something.
///
/// Deliberately NOT suppressed: `meeting_invite` and `tracker_notification`. An
/// invite asks for the reader's time and can be the most important mail of the
/// day, and a tracker's mention is addressed to the person reading it — the
/// same line `gates.dart` draws, and for the same reason.
///
/// A message the owner RESTORED (`gate_override = 'user'`) skips the
/// classification arm. Restore is the escape hatch from every gate, and tier
/// two already gates any `List-*` or `Auto-Submitted` mail, so the
/// classification fires mostly on exactly those restored rows: a colleague
/// writing through a team list, gated as a newsletter and restored. Keeping
/// the suppression would refuse the draft on the very judgement the owner
/// just overruled. The gate-reason arm needs no exemption, because Restore
/// clears `gate_reason`.
bool replySuppressed(Message message) =>
    automatedGateReasons.contains(message.gateReason) ||
    (message.gateOverride != 'user' &&
        classificationOf(message) == 'automated_notification');

/// Whether a PREFETCHED draft is wanted, from what triage stored — the one
/// rule, asked at two points that must agree: the draft queue
/// (`ExtractHandler._queueDraft`, so a "no" never takes a prefetch slot) and
/// the draft handler (`DraftHandler.run`, for queue rows written before the
/// answer was known or by an older build). An ASKED-FOR draft never asks it.
///
/// [replyExpectedP] is the decision model's p(reply_expected = yes) from
/// `message_decisions`, or null when it never read the message. Below
/// [DecisionPolicy.replyYes] is a no. It is used as is even for an ownerless
/// decision: unlike needs-you, the reply head reads the message, not whether
/// it names the owner.
///
/// With no probability, [storedReplyExpected] — the `messages.reply_expected`
/// column — decides: `0` is a no; `1` or NULL (never judged: a row triaged
/// before the decision model, or a legacy `teams_source` chat nothing judged)
/// proceeds, which is what the pre-gate that queued it already assumed.
///
/// [detail] is what the activity row says about the decision either way;
/// [skipWhy] is non-null exactly when the answer is no.
({Map<String, Object?> detail, String? skipWhy}) replyVerdict({
  required double? replyExpectedP,
  required Object? storedReplyExpected,
}) {
  final p = replyExpectedP;
  if (p != null) {
    final rounded = (p * 100).round() / 100;
    return (
      detail: {'decision': 'decision_model', 'reply_p': rounded},
      skipWhy: p < DecisionPolicy.replyYes
          ? 'The decision model put the chance a reply is expected at '
              '${rounded.toStringAsFixed(2)}.'
          : null,
    );
  }
  return (
    detail: {'decision': 'stored'},
    skipWhy: (storedReplyExpected as num?)?.toInt() == 0
        ? 'Triage judged no reply is expected.'
        : null,
  );
}
