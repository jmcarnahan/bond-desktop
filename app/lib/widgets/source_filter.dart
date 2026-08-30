import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'chips.dart';
import 'source_glyph.dart';

/// Which connector the inbox is showing: All, Mail, or Teams.
///
/// Null is All and is the value the app starts on. A sealed enum would be
/// tidier to read here and worse everywhere else — the value is compared
/// against `Conversation.source`, which is a string from a database column,
/// and a second spelling of the same fact is a second thing to keep in step.
class SourceFilterBar extends StatelessWidget {
  /// `null` for All, or a source name.
  final String? selected;

  /// False when the tenant never granted `Chat.Read`. The Teams pill then
  /// renders unselectable with a tooltip saying why.
  ///
  /// Unavailable is NOT the same as absent. A pill that vanished would leave a
  /// user who expected Teams with nothing to ask about; one that is there and
  /// says what is missing points at the fix.
  final bool teamsAvailable;

  final ValueChanged<String?> onSelected;

  const SourceFilterBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.teamsAvailable = true,
  });

  /// Named so a test can find the pill without matching on its label.
  static const Key allKey = Key('source-filter-all');
  static const Key mailKey = Key('source-filter-email');
  static const Key teamsKey = Key('source-filter-teams');

  static const String unavailableTooltip =
      'Teams needs permissions — see Settings';

  @override
  Widget build(BuildContext context) {
    final teams = BondFilterPill(
      key: teamsKey,
      label: '$teamsGlyph Teams',
      selected: selected == 'teams',
      onDark: true,
      // Null is what makes an InkWell unresponsive AND visibly so; a callback
      // that quietly did nothing would look like a broken pill.
      onTap: teamsAvailable ? () => onSelected('teams') : null,
    );

    // Wrap, not Row: the rail is a fixed 260 wide and three pills of this
    // length land within a few pixels of that. A second line is a far better
    // answer than a yellow overflow stripe.
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        BondFilterPill(
          key: allKey,
          label: 'All',
          selected: selected == null,
          onTap: () => onSelected(null),
          onDark: true,
        ),
        BondFilterPill(
          key: mailKey,
          label: '$mailGlyph Mail',
          selected: selected == 'email',
          onTap: () => onSelected('email'),
          onDark: true,
        ),
        if (teamsAvailable)
          teams
        else
          Tooltip(message: unavailableTooltip, child: teams),
      ],
    );
  }
}
