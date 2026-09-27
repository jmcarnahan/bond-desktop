import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../services/sender_display.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'label_chip.dart';
import 'needs_you_reason.dart';
import 'processing_hint.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// One row per thread: a state dot, the primary participant, the subject, a
/// CTA (needs-reply) or the last-message preview, the timestamp, and a chip
/// row.
class ConversationRow extends StatelessWidget {
  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  /// When this session started. Null — the default — never shows the
  /// processing hint; see [showsProcessing] for why the gate is a time and
  /// not a flag.
  final DateTime? processingSince;

  /// One line that REPLACES the row's usual second line — the CTA, or the
  /// last-message preview — when the list has something more specific to say
  /// about this row than the row can say about itself.
  ///
  /// The Deadlines tab is what it exists for: on a list the reader chose
  /// BECAUSE every row has a date on it, the date in the sender's own words is
  /// worth more than another copy of the ask, which the title already carries.
  /// Null everywhere else, which is the ordinary row.
  final String? caption;

  /// The owner's own mail domains, for the external mark. Empty — the default —
  /// draws no mark at all, which is what a host that has not resolved the
  /// signed-in account yet passes and what every test that does not care about
  /// externality gets: the row it drew before this existed.
  ///
  /// See [Conversation.isExternalTo] for what counts as external and why the
  /// answer is computed here rather than stored.
  final Set<String> ownerDomains;

  const ConversationRow({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onTap,
    this.processingSince,
    this.caption,
    this.ownerDomains = const {},
  });

  /// The stripe, for a test that wants to assert its colour rather than its
  /// absence — `find.byType` cannot tell one `Container` from another.
  static const Key externalStripeKey = ValueKey('conversation-row-external');

  /// How wide the stripe is. Narrow on purpose: this is a temperature, not a
  /// state, and the state dot two columns over is still the loudest mark.
  static const double externalStripeWidth = 4;

  /// Urgent needs-reply is error, needs-reply is attention, waiting is
  /// neutral, done is success.
  BondTone get _dotTone {
    switch (conversation.state) {
      case ConversationState.needsReply:
        return conversation.ctaUrgency == CtaUrgency.urgent
            ? BondTone.error
            : BondTone.attention;
      case ConversationState.done:
        return BondTone.success;
      case ConversationState.waiting:
        return BondTone.neutral;
    }
  }

  /// The CTA line's ink. Only the top two urgencies get a tint — tinting
  /// every ask would make none of them read as louder than the others.
  Color get _ctaColor => switch (conversation.ctaUrgency) {
        CtaUrgency.urgent => BondColors.onErrorTint,
        CtaUrgency.high => BondColors.onAttentionTint,
        CtaUrgency.normal || CtaUrgency.low => BondColors.inkSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final cta = c.ctaText;
    final hasCta = cta != null && cta.isNotEmpty;
    final secondary = caption ?? (hasCta ? cta : c.lastMessagePreview);
    // Not `Participant.display`: that answers the address when there is no
    // name, and a chat participant's address is a `teams:<id>` identity key.
    final who = displaySenderName(
      name: c.primaryParticipant?.name,
      address: c.primaryParticipant?.email,
      fallback: '(no sender)',
    );
    final time = formatTimestamp(c.lastMessageAt);
    final processing = showsProcessing(c, since: processingSince);
    final external = c.isExternalTo(ownerDomains);

    // The preview is the line the model is in the middle of turning into a
    // CTA, so it dims while that happens. A row that already HAS one is never
    // dimmed — the ask is useful now, whatever else is still running.
    Widget? secondaryLine;
    if (secondary != null && secondary.isNotEmpty) {
      secondaryLine = Text(
        secondary,
        style: hasCta
            ? BondType.small.copyWith(
                color: _ctaColor,
                fontWeight: FontWeight.w600,
              )
            : BondType.small,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
      if (processing && !hasCta) {
        secondaryLine = Opacity(opacity: 0.55, child: secondaryLine);
      }
    }

    // The 2px selection ring paints over the constant 1px border rather than
    // replacing it, so selecting a row never shifts the list's layout.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      foregroundDecoration: selected
          ? BoxDecoration(
              borderRadius: BondRadii.mdAll,
              border: Border.all(color: BondColors.primary, width: 2),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: BondColors.surface,
        child: InkWell(
          onTap: onTap,
          // A stripe down the left edge, in a Stack rather than as a
          // non-uniform Border: `Border.paint` refuses a border radius unless
          // every side matches, and the rounded card is not negotiable. The
          // card's own fill stays [BondColors.surface] — tinting the whole
          // surface would put the CTA's copper ink on a cool ground and make
          // the loudest line on the row the hardest to read.
          child: Stack(
            children: [
              _body(who, time, secondaryLine, processing, external),
              if (external)
                const Positioned(
                  top: 0,
                  bottom: 0,
                  left: 0,
                  width: externalStripeWidth,
                  child: ColoredBox(
                    key: externalStripeKey,
                    color: BondColors.external,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Everything inside the card. Its own method only so the stripe has a
  /// sibling to be positioned against; the lines it draws are unchanged.
  Widget _body(
    String who,
    String? time,
    Widget? secondaryLine,
    bool processing,
    bool external,
  ) {
    final c = conversation;
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: BondChip.dot(_dotTone),
          ),
          const SizedBox(width: BondSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        who,
                        style: BondType.body
                            .copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (time != null) ...[
                      const SizedBox(width: BondSpacing.s8),
                      Text(time, style: BondType.caption),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // The subject line carries the source mark, not the
                // name above it: the name is the loudest thing on the
                // card and a glyph in front of it would compete with
                // the state dot for the same job.
                Text(
                  withSourceGlyph(
                    c.source,
                    c.subject?.isNotEmpty == true
                        ? c.subject!
                        : '(no subject)',
                  ),
                  style: BondType.small.copyWith(color: BondColors.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (secondaryLine != null) ...[
                  const SizedBox(height: BondSpacing.s4),
                  secondaryLine,
                ],
                const SizedBox(height: BondSpacing.s8),
                Wrap(
                  spacing: BondSpacing.s8,
                  runSpacing: BondSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // Words, not a spinner: something that animates for
                    // as long as the model runs would never let a test
                    // settle, and it would make an ordinary wait look
                    // like a stall.
                    if (processing)
                      Text('thinking…', style: BondType.caption),
                    if (c.ctaUrgency == CtaUrgency.urgent)
                      const BondChip(
                          label: 'Urgent', tone: BondTone.attention),
                    // The tenant's own "⚠ External Email — Use caution
                    // with links and attachments" banner is stripped out
                    // of the body at ingest (Phase 1), and this is what
                    // replaces it: the same fact, said once per thread in
                    // a place the reader can see before they open it,
                    // instead of a line of shouting inside every message
                    // that also went to the model as prose.
                    if (external)
                      const BondChip(
                          label: 'External', tone: BondTone.external),
                    // The owner's own words, ahead of the counts: a word
                    // somebody chose for this thread says more about it
                    // than how many messages are on it. Display-only
                    // here — the picker is where a label is put on or
                    // taken off, and a chip that swallowed the tap would
                    // cost the row its own.
                    ...labelChips(c.labels),
                    // Why the row is in Needs you at all, in four words,
                    // after the owner's labels and before the counts —
                    // the pipeline's reason ranks under a person's own
                    // word for the thread and over its arithmetic. Only
                    // on a thread asking for a reply, and only when the
                    // pipeline can name why.
                    ...needsYouReasonChips(c),
                    // What came with the thread, counted at read time
                    // over its non-inline attachments — a signature logo
                    // is not a file somebody sent.
                    if (c.attachmentCount > 0)
                      BondChip.metric('📎 ${c.attachmentCount}'),
                    BondChip.metric(
                      c.messageCount == 1
                          ? '1 message'
                          : '${c.messageCount} messages',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
