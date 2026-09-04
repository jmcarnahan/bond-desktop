import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';

/// What the day has been about: the storylines the window landed the most
/// messages in, each one a way into its timeline.
///
/// Nothing at all when there is none — a "HOT RIGHT NOW" heading over an empty
/// row would be the screen promising something it does not have. That is the
/// normal state of a quiet morning and of an install whose clustering pass has
/// not run yet.
class HotStorylinesStrip extends StatelessWidget {
  final List<HotStoryline> items;
  final void Function(String storylineId) onOpen;

  const HotStorylinesStrip({
    super.key,
    required this.items,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('HOT RIGHT NOW', style: BondType.label),
        const SizedBox(height: BondSpacing.s8),
        Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s8,
          children: [
            for (final item in items)
              BondFilterPill(
                // The count is part of what the pill says rather than a badge
                // hanging off it: "how much landed here today" is the whole
                // reason this storyline is on the strip.
                label: '${item.title} · ${item.messageCount}',
                selected: false,
                onTap: () => onOpen(item.id),
              ),
          ],
        ),
      ],
    );
  }
}
