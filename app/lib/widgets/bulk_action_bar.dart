import 'package:flutter/material.dart';

import '../services/select_similar.dart' show SimilarScope;
import '../theme/tokens.dart';
import 'chips.dart';

/// One "Select similar" offer on the bulk bar: a scope, the words on the chip,
/// and how many drawn rows it would select.
@immutable
class BulkSimilarChip {
  final SimilarScope scope;

  /// `Same sender`, the domain itself, or the subject's front (`accepted:`) —
  /// the value the reader is being offered to select by, in its own words.
  final String label;

  /// Every drawn row the scope matches, the ones already ticked included, so
  /// the number agrees with what a rule on the same scope would catch here.
  final int count;

  final VoidCallback onTap;

  const BulkSimilarChip({
    required this.scope,
    required this.label,
    required this.count,
    required this.onTap,
  });
}

/// The bar over the Needs You list while rows are ticked — requirement 12c's
/// Dismiss · Label · Later · Drop senders, acting on every ticked row at once.
///
/// Stateless: the selection, the acts and the one toast each act raises all
/// live on the inbox, which owns the pile. PINNED over the list rather than in
/// its scroll, because a bar that scrolled away with the rows would leave a
/// selection nobody could act on.
///
/// Every button is optional and a null one is left off, the house discipline
/// for a control whose host cannot act on it. The second line — the similar
/// chips — draws only when there is something to offer.
class BulkActionBar extends StatelessWidget {
  /// How many ticked rows are drawn right now — the number every act will
  /// touch, never the size of a set that still holds rows a sync removed.
  final int count;

  final VoidCallback? onDismiss;
  final VoidCallback? onLabel;
  final VoidCallback? onLater;
  final VoidCallback? onDropSenders;
  final VoidCallback? onClear;

  /// The "Select similar" offers, already filtered by the host to the scopes
  /// that apply and still have an unticked match. Empty draws no second line.
  final List<BulkSimilarChip> similar;

  const BulkActionBar({
    super.key,
    required this.count,
    this.onDismiss,
    this.onLabel,
    this.onLater,
    this.onDropSenders,
    this.onClear,
    this.similar = const [],
  });

  static const Key barKey = ValueKey('bulk-bar');
  static const Key dismissKey = ValueKey('bulk-dismiss');
  static const Key labelKey = ValueKey('bulk-label');
  static const Key laterKey = ValueKey('bulk-later');
  static const Key dropKey = ValueKey('bulk-drop');
  static const Key clearKey = ValueKey('bulk-clear');

  static Key similarKeyFor(SimilarScope scope) =>
      ValueKey('bulk-similar-${scope.name}');

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: barKey,
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s12,
          vertical: BondSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: BondColors.faintGround,
          borderRadius: BondRadii.smAll,
          border: Border.all(color: BondColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: BondSpacing.s8,
              runSpacing: BondSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('$count selected', style: BondType.small),
                if (onDismiss != null)
                  _button(dismissKey, 'Mark done', onDismiss!),
                if (onLabel != null) _button(labelKey, 'Label…', onLabel!),
                if (onLater != null) _button(laterKey, 'Later', onLater!),
                if (onDropSenders != null) _button(dropKey, 'Drop senders', onDropSenders!),
                if (onClear != null) _button(clearKey, 'Clear', onClear!),
              ],
            ),
            if (similar.isNotEmpty) ...[
              const SizedBox(height: BondSpacing.s8),
              Wrap(
                spacing: BondSpacing.s8,
                runSpacing: BondSpacing.s4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Select similar:', style: BondType.caption),
                  for (final chip in similar)
                    BondFilterPill(
                      key: similarKeyFor(chip.scope),
                      label: '${chip.label} · ${chip.count}',
                      onTap: chip.onTap,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(Key key, String words, VoidCallback onPressed) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: _style,
      child: Text(words),
    );
  }

  static final ButtonStyle _style = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
    minimumSize: const Size(0, 28),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: BondType.caption,
  );
}
