import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A run of one application's messages, drawn as the one muted line the
/// transcript puts in their place: `Meeting assistant · 5 updates`.
///
/// Entry 8b's nice-to-have. A facilitator bot posting every few minutes turns a
/// meeting chat into a wall of its own status lines, and the human turns the
/// thread is actually about sink under it. Which messages make a run is the
/// panel's call (`ThreadDetailPanel._botRuns`); this row only says how many
/// there were and hands the tap back.
///
/// Muted on purpose — caption type in [BondColors.inkMuted], no avatar disc —
/// so the eye slides past it to the next person. The chevron is the only
/// affordance, and it points the way the fold would go, as `MessageRow`'s does.
class BotRunRow extends StatelessWidget {
  /// Who posted the run, as the transcript would name them.
  final String senderName;

  /// How many messages the line stands for.
  final int count;

  /// Whether the run's messages are drawn under this line. The same row is the
  /// way back in both directions, so an opened run can be put away again.
  final bool expanded;

  /// Told when the line is tapped. Null draws a statement with no chevron.
  final VoidCallback? onTap;

  const BotRunRow({
    super.key,
    required this.senderName,
    required this.count,
    this.expanded = false,
    this.onTap,
  });

  /// The words on the line, kept here so a test and the row cannot disagree.
  static String labelFor(String senderName, int count) =>
      '$senderName · $count ${count == 1 ? 'update' : 'updates'}';

  /// The avatar column plus its gutter, matching `MessageRow` — the line sits
  /// where the message bodies do, with the glyph in the avatar's slot.
  static const double _avatarColumn = 36;

  @override
  Widget build(BuildContext context) {
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Row(
        children: [
          const SizedBox(
            width: _avatarColumn,
            child: Icon(
              Icons.smart_toy_outlined,
              size: 16,
              color: BondColors.inkMuted,
            ),
          ),
          const SizedBox(width: BondSpacing.s12),
          Flexible(
            child: Text(
              labelFor(senderName, count),
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: BondSpacing.s4),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: BondColors.inkMuted,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return line;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: line,
      ),
    );
  }
}
