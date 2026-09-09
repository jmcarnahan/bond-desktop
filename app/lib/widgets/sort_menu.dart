import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The one order control every list in the app wears: an icon, the current
/// order in words, a caret, and a checked menu of the alternatives.
///
/// It started as the Needs You pile's own control and is now shared, because
/// three lists growing three order controls is how they come to disagree about
/// what a sort menu looks like — and a reader who learned one would have
/// learned nothing about the next.
///
/// A `PopupMenuButton` and not a pane: the no-popups rule bans dialogs, and a
/// menu hanging off the button that opened it takes nothing over.
///
/// The current order is spelled out beside the icon rather than left to a
/// tooltip. A bare icon would leave the reader to guess which of the orders
/// they are looking at, which is the one question the control exists to
/// answer.
class SortMenu<T extends Enum> extends StatelessWidget {
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  /// Keys for the menu items, so a screen test can pick one by name.
  final Key Function(T)? itemKeyFor;

  final String tooltip;

  const SortMenu({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.itemKeyFor,
    this.tooltip = 'Order',
  });

  @override
  Widget build(BuildContext context) {
    final keyFor = itemKeyFor;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final option in options)
          CheckedPopupMenuItem<T>(
            key: keyFor == null ? null : keyFor(option),
            value: option,
            checked: option == value,
            child: Text(labelOf(option)),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s8,
          vertical: BondSpacing.s4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sort,
              size: 14,
              color: BondColors.inkSecondary,
            ),
            const SizedBox(width: BondSpacing.s4),
            Text(labelOf(value), style: BondType.small),
            const Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: BondColors.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
