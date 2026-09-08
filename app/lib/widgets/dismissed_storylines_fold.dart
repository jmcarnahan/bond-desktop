import 'package:flutter/material.dart';

import '../models/storyline_models.dart';
import '../theme/tokens.dart';

/// The storylines the user said no to, folded under the live ones.
///
/// Dismissing was the one storyline decision that had no way back: the row
/// left the rail and nothing on screen remembered it. The list is folded
/// because it is history rather than a queue — nothing here is asking for
/// anything — but it is reachable, and every row in it can be restored.
class DismissedStorylinesFold extends StatefulWidget {
  final List<Storyline> dismissed;

  /// Puts one back as a suggestion. Null leaves the Restore buttons inert.
  final void Function(String storylineId)? onRestore;

  /// The column's fill behind each row, so the fold matches whichever rail it
  /// sits in.
  final Color fill;

  static const Key headerKey = ValueKey('dismissed-storylines-header');

  static Key restoreKey(String storylineId) =>
      ValueKey('dismissed-restore-$storylineId');

  const DismissedStorylinesFold({
    super.key,
    required this.dismissed,
    this.onRestore,
    this.fill = BondColors.ink,
  });

  @override
  State<DismissedStorylinesFold> createState() =>
      _DismissedStorylinesFoldState();
}

class _DismissedStorylinesFoldState extends State<DismissedStorylinesFold> {
  /// Whether the dismissed storylines are unfolded. Shut every time, unlike
  /// the sections: this is the one list on the rail nobody opens the app to
  /// look at.
  bool _open = false;

  static const double _rowHeight = 32;

  @override
  Widget build(BuildContext context) {
    if (widget.dismissed.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (_open)
          for (final s in widget.dismissed) _item(s),
      ],
    );
  }

  /// The fold over the dismissed storylines. Its count is in the label, the
  /// way a Later day's is: it is what the row has to say for itself while it
  /// is shut.
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: widget.fill,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          key: DismissedStorylinesFold.headerKey,
          onTap: () => setState(() => _open = !_open),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Dismissed · ${widget.dismissed.length}',
                      style: BondType.caption.copyWith(
                        color: BondColors.onDarkSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0 : -0.25,
                    duration: const Duration(milliseconds: 120),
                    child: const Icon(
                      Icons.expand_more,
                      size: 16,
                      color: BondColors.onDarkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One dismissed storyline: the title, and the one action that can undo the
  /// dismissal. No dot — the dot says whether a row is asking for something,
  /// and this one is not — and no count, for the same reason.
  Widget _item(Storyline storyline) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: widget.fill,
        borderRadius: BondRadii.smAll,
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    storyline.title.isEmpty ? '(untitled)' : storyline.title,
                    style: BondType.small.copyWith(
                      color: BondColors.onDarkSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _restoreAction(storyline.id),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Restore. Small and quiet, the way the rail's Keep / Dismiss pair is: the
  /// row it sits in is a piece of history, and a loud button here would ask
  /// for more attention than anything in this list deserves.
  Widget _restoreAction(String storylineId) {
    return Tooltip(
      message: 'Restore',
      child: InkWell(
        key: DismissedStorylinesFold.restoreKey(storylineId),
        onTap: widget.onRestore == null
            ? null
            : () => widget.onRestore!(storylineId),
        borderRadius: BondRadii.fullAll,
        hoverColor: BondColors.onDarkTint,
        child: const Padding(
          padding: EdgeInsets.all(BondSpacing.s4),
          child: Icon(Icons.restore, size: 16, color: BondColors.onDarkMuted),
        ),
      ),
    );
  }
}
