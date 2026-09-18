import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A row of segments with a sentence under it — the one shape every
/// either/or/or setting on this screen takes.
///
/// One widget rather than a third hand-rolled copy. Notifications, Suggested
/// replies and Drafts in flight are the same control asking three different
/// questions, and they were drifting apart in the small ways copies do: the
/// gap under the buttons, whether the tick shows, whether the caption uses the
/// caption style. A reader who has understood one of them has now understood
/// all three.
///
/// It owns no state. The selected value comes from the host on every build and
/// the change goes straight back out through [onChanged], because each of
/// these settings is reported to its host the instant it moves — the next
/// draft, the next notification, the next launch is what the choice governs,
/// and one can arrive while the section is still open.
class SettingsSegments<T> extends StatelessWidget {
  /// The choices, in the order they are drawn.
  final List<({T value, String label})> segments;

  /// Which one is filled in.
  final T selected;

  /// Fired with the new value the moment a segment is pressed.
  final ValueChanged<T> onChanged;

  /// The sentence under the buttons: what the choice actually does, in the
  /// words a person would use rather than the segment's own label.
  final String caption;

  const SettingsSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<T>(
            // No tick on the selected segment: the segment is already filled,
            // and every segmented control on this screen agrees about that.
            showSelectedIcon: false,
            segments: [
              for (final segment in segments)
                ButtonSegment(value: segment.value, label: Text(segment.label)),
            ],
            selected: {selected},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(caption, style: BondType.caption),
      ],
    );
  }
}
