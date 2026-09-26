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
/// The reason arrives on [Conversation] off the newest kept inbound whose
/// verdict was YES (`message_store.dart`'s `loadConversations`), so anything
/// drawn here is an answer to "why does this want you", never to the opposite
/// question.

/// The reason slug as words, or null when there is nothing honest to say.
///
/// Two kinds of value reach here and each is treated differently:
///
///  * `teams_direct` — the deterministic floor's token, and the one token the
///    needs-you pass writes instead of a sentence. Translated.
///  * anything else — the model's `evidence` line, already a sentence in the
///    judge's own words. Passed through with its whitespace collapsed and
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
/// sentence is a click away in the thread.
List<Widget> needsYouReasonChips(Conversation c, {int maxChars = 36}) {
  if (c.state != ConversationState.needsReply) return const [];
  final words = needsYouReasonWords(c.needsYouReason, maxChars: maxChars);
  if (words == null) return const [];
  return [BondChip.metric(words, key: needsYouReasonChipKey)];
}

/// `Why: <reason> · <when>` — the line under a thread's header that says which
/// message made it ask for you, and when that message arrived.
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

  /// Jump to the message the reason came from. Resolved by the host from
  /// `needs_you_reason_message_id`, so this widget never learns which message
  /// that is. Null leaves the line inert.
  final VoidCallback? onTap;

  const NeedsYouWhyLine({
    super.key,
    required this.reason,
    this.at,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final words = needsYouReasonWords(reason);
    if (words == null) return const SizedBox.shrink();
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
