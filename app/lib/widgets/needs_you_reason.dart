import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'time_format.dart';

/// The needs-you reason in a reader's words, and the two surfaces that draw it.
///
/// One file because two places ask the same question — the inbox row wants four
/// words in a chip and the thread panel wants a line under the header — and a
/// second copy of the token map is how the two start disagreeing about what
/// `teams_direct` means.
///
/// The reason arrives on [Conversation] off the kept inbound message, since the
/// owner's last reply, with the HIGHEST needs-you probability
/// (`message_store.dart`'s `loadConversations`), and that probability is
/// [Conversation.needsYouP]. So the percentage drawn beside the reason is the
/// number the owner's slider was compared against, from the message the reason
/// names.

/// The reason slug as words, or null when there is nothing honest to say.
///
/// Two kinds of value reach here and each is treated differently:
///
///  * `teams_direct` — the old deterministic floor's token, which rows written
///    before the decision model may still carry. Translated.
///  * anything else — a sentence: the decision model's templated reason, or
///    the evidence line an older build wrote. Passed through with its whitespace collapsed and
///    clamped to [maxChars]; paraphrasing it would be the app putting words in
///    its own mouth, and the same rule holds in `why_panel.dart`.
///
/// Null for null, empty and whitespace: a caller that gets null draws nothing
/// at all rather than an empty chip or a `Why:` with no why after it.
String? needsYouReasonWords(String? reason, {int maxChars = 120}) {
  final text = reason?.trim() ?? '';
  if (text.isEmpty) return null;
  if (text == 'teams_direct') return 'Direct message';
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= maxChars) return collapsed;
  return '${collapsed.substring(0, maxChars).trimRight()}…';
}

/// Whether [p] is an EARLIER model's verdict rather than a probability.
///
/// v21 carried the old yes/no verdicts across as `needs_you_p` 1.0 and 0.0, so
/// a message nothing has re-decided since holds a number no model said. It
/// still counts by the predicate — the verdict is the best answer the app has
/// — but it is never drawn as `100%` or `0%`.
///
/// [decidedNow] is whether the message has a `message_decisions` row under the
/// question set this build reads: true shows the number whatever it is, and a
/// reader that cannot know cheaply passes null, which leaves only the two
/// exact values in question.
bool needsYouFromEarlierModel(double? p, {bool? decidedNow}) =>
    decidedNow != true && (p == 0.0 || p == 1.0);

/// [p] as the whole percentage every needs-you surface shows, or null when the
/// message has not been decided or holds an earlier model's verdict
/// ([needsYouFromEarlierModel]). The Settings slider is set in the same unit,
/// so the two read as one number.
///
/// FLOORED, not rounded: 0.296 against a 30% line is below it, and `30%`
/// beside "below your 30% line" would be the app contradicting itself. For a
/// line on a slider notch the number shown is at or above the line's exactly
/// when `needsYouAt` says yes. The 1e-9 is for the binary fractions: 0.57 is
/// stored as 0.56999…, and it is 57%.
String? needsYouPercentWords(double? p, {bool? decidedNow}) {
  if (p == null || needsYouFromEarlierModel(p, decidedNow: decidedNow)) {
    return null;
  }
  return '${((p + 1e-9) * 100).floor()}%';
}

/// [words] with the thread's probability after it, `<words> · 72%`, or
/// [words] alone when there is no probability to show.
String _withPercent(String words, double? p, bool? decidedNow) {
  final percent = needsYouPercentWords(p, decidedNow: decidedNow);
  return percent == null ? words : '$words · $percent';
}

/// Whether [c] has a reason worth drawing: it is asking for a reply AND the
/// pipeline can name why.
bool hasNeedsYouReason(Conversation c) =>
    c.state == ConversationState.needsReply &&
    needsYouReasonWords(c.needsYouReason) != null;

/// The row's reason chip, so a test can read it without hunting a colour.
const Key needsYouReasonChipKey = ValueKey('needs-you-reason-chip');

/// The thread panel's `Why:` line.
const Key needsYouWhyLineKey = ValueKey('needs-you-why-line');

/// The row's reason, as a chip ready to splice into the metadata [Wrap] — a
/// list rather than a widget, exactly as `labelChips` is, so a thread with no
/// reason contributes nothing and the row draws what it drew before.
///
/// Clamped far shorter than the panel's line ([maxChars]): this sits on one
/// line of metadata beside the label chips and the message count, and the full
/// sentence is a click away in the thread. The clamp is on the reason alone;
/// the thread's percentage ([Conversation.needsYouP]) is appended after it
/// and never cut.
List<Widget> needsYouReasonChips(Conversation c, {int maxChars = 36}) {
  if (c.state != ConversationState.needsReply) return const [];
  final words = needsYouReasonWords(c.needsYouReason, maxChars: maxChars);
  if (words == null) return const [];
  return [
    BondChip.metric(_withPercent(words, c.needsYouP, c.needsYouDecidedNow),
        key: needsYouReasonChipKey),
  ];
}

/// `Why: <reason> · 72% · <when>` — the line under a thread's header that says
/// which message made it ask for you, how sure the decision model was of it,
/// and when that message arrived.
///
/// With [onTap] wired the line is also the way THERE: it scrolls the transcript
/// to that message and flashes it, which is the half of entry 8a naming the
/// message could only promise. Without it the line is the statement it shipped
/// as — a host whose thread never loaded the message the reason came from has
/// nowhere to send the tap, and the stamp is still the reader's own way of
/// finding it, in [formatTimestamp]'s format, the same one the message bubbles
/// below carry.
class NeedsYouWhyLine extends StatelessWidget {
  /// The stored slug or sentence; see [needsYouReasonWords].
  final String? reason;

  /// When the message carrying [reason] arrived. Absent — an older row, or a
  /// read that did not ask for it — drops the stamp and keeps the reason.
  final String? at;

  /// The thread's needs-you probability ([Conversation.needsYouP]), drawn as
  /// a percentage after the reason. Null draws no percentage.
  final double? p;

  /// Whether [p] was decided under the current question set
  /// ([Conversation.needsYouDecidedNow]); see [needsYouFromEarlierModel].
  final bool? decidedNow;

  /// Jump to the message the reason came from. Resolved by the host from
  /// `needs_you_reason_message_id`, so this widget never learns which message
  /// that is. Null leaves the line inert.
  final VoidCallback? onTap;

  const NeedsYouWhyLine({
    super.key,
    required this.reason,
    this.at,
    this.p,
    this.decidedNow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reasonWords = needsYouReasonWords(reason);
    if (reasonWords == null) return const SizedBox.shrink();
    final words = _withPercent(reasonWords, p, decidedNow);
    final stamp = formatTimestamp(at);
    final line = Text(
      stamp == null ? 'Why: $words' : 'Why: $words · $stamp',
      key: needsYouWhyLineKey,
      style: BondType.small.copyWith(color: BondColors.inkMuted),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final tap = onTap;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s12,
        BondSpacing.s16,
        0,
      ),
      // Its own transparent Material: ink paints on the nearest Material
      // ANCESTOR, which sits behind the pane's opaque surface — the same trap
      // `thread_detail_panel._ctaBanner` documents.
      child: tap == null
          ? line
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: tap,
                borderRadius: BondRadii.smAll,
                child: line,
              ),
            ),
    );
  }
}
