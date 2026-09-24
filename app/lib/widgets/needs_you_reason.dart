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
/// Three kinds of value reach here and each is treated differently:
///
///  * `teams_direct` — the deterministic floor's token, and the one token the
///    needs-you pass writes instead of a sentence. Translated.
///  * `label_rule:<name>` — written by a label rule, and the words after the
///    colon are the owner's own label name, so the name IS the explanation.
///    Today this arm is DEFENSIVE: a rule writes its reason with verdict 0
///    and the subselect above reads only verdict 1, so no current caller can
///    hand one in. It stays because 12i's "shown despite rule X" note is
///    exactly this token surfacing on a raised thread, and the map is the one
///    place those words are minted.
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
  if (text.startsWith(_labelRulePrefix)) {
    final name = text.substring(_labelRulePrefix.length).trim();
    // A rule with no name behind it explains nothing a reader can act on, so
    // it reads as nothing rather than as a bare "Label rule".
    return name.isEmpty ? null : name;
  }
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= maxChars) return collapsed;
  return '${collapsed.substring(0, maxChars).trimRight()}…';
}

const String _labelRulePrefix = 'label_rule:';

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
/// Inert text: naming the message is this phase's promise, and scrolling the
/// transcript to it is the next one. The stamp is [formatTimestamp]'s, the same
/// format the message bubbles below carry, so the reader can find the message
/// by eye until the tap works.
class NeedsYouWhyLine extends StatelessWidget {
  /// The stored slug or sentence; see [needsYouReasonWords].
  final String? reason;

  /// When the message carrying [reason] arrived. Absent — an older row, or a
  /// read that did not ask for it — drops the stamp and keeps the reason.
  final String? at;

  const NeedsYouWhyLine({super.key, required this.reason, this.at});

  @override
  Widget build(BuildContext context) {
    final words = needsYouReasonWords(reason);
    if (words == null) return const SizedBox.shrink();
    final stamp = formatTimestamp(at);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s12,
        BondSpacing.s16,
        0,
      ),
      child: Text(
        stamp == null ? 'Why: $words' : 'Why: $words · $stamp',
        key: needsYouWhyLineKey,
        style: BondType.small.copyWith(color: BondColors.inkMuted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
