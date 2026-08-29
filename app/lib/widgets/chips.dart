import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The one tinted-chip primitive. Tints come only from the central tone map
/// (`theme/bond_tones.dart`); call sites pass a value's tone, never a color.
///
/// A label-less chip renders as a bare 8px tone dot — that is the state
/// indicator on an inbox row.
class BondChip extends StatelessWidget {
  final BondTone tone;

  /// Null renders dot-only mode.
  final String? label;

  /// Leading 6px status dot inside the pill.
  final bool showDot;

  const BondChip({
    super.key,
    required this.tone,
    this.label,
    this.showDot = false,
  });

  /// Label-less tone dot.
  factory BondChip.dot(BondTone tone, {Key? key}) =>
      BondChip(key: key, tone: tone);

  /// Quiet stat chip ("3 messages").
  factory BondChip.metric(String label, {Key? key}) =>
      BondChip(key: key, tone: BondTone.neutral, label: label);

  /// Dot + status label ("Needs reply").
  factory BondChip.semantic(String label, BondTone tone, {Key? key}) =>
      BondChip(key: key, tone: tone, label: label, showDot: true);

  @override
  Widget build(BuildContext context) {
    final colors = bondToneColors[tone]!;

    if (label == null) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: colors.foreground,
          shape: BoxShape.circle,
        ),
      );
    }

    final labelStyle = BondType.label.copyWith(
      letterSpacing: 0,
      color: colors.foreground,
      fontSize: 12,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BondRadii.fullAll,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label!,
              style: labelStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// One filter pill: selected is ink-filled, the rest are bordered surface.
class BondFilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const BondFilterPill({
    super.key,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? BondColors.surface : BondColors.inkSecondary;

    return Material(
      color: selected ? BondColors.ink : BondColors.surface,
      borderRadius: BondRadii.fullAll,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.fullAll,
        hoverColor: selected ? BondColors.darkTileAlt : BondColors.faintGround,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
          decoration: selected
              ? null
              : BoxDecoration(
                  borderRadius: BondRadii.fullAll,
                  border: Border.all(color: BondColors.border),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: BondType.workFamily,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-select pill row. Generic over the value so callers can drive it
/// with an enum rather than stringly-typed options.
class BondFilterPillRow<T> extends StatelessWidget {
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  const BondFilterPillRow({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        for (final option in options)
          BondFilterPill(
            label: labelOf(option),
            selected: option == selected,
            onTap: () => onSelected(option),
          ),
      ],
    );
  }
}
