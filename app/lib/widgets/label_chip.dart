import 'package:flutter/material.dart';

import '../models/label_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';

/// How the owner's own words are drawn, wherever they are drawn.
///
/// One file rather than a copy per surface: a label appears on a conversation
/// row, beside the Needs You tabs and in the Settings list, and a colour that
/// resolved differently in one of the three would read as a different label.
/// The stored value is a WORD (`Label.tone`) and this is the only place that
/// turns one into a [BondTone] — the model layer and the store under it know
/// nothing about colour.

/// The tones a label may wear, in the order a picker offers them.
///
/// [BondTone.video] is deliberately absent: it is the governed off-palette
/// purple the Video channel owns, and a label wearing it would claim to be a
/// channel.
const List<BondTone> labelTones = [
  BondTone.neutral,
  BondTone.primary,
  BondTone.success,
  BondTone.attention,
  BondTone.error,
];

/// What a label's stored word means, or [BondTone.neutral] for a label with no
/// colour and for a word this build does not know.
///
/// Unknown falls back rather than throwing, on the models' own defensive rule:
/// a tone written by a later version of the app must cost one chip its tint,
/// never a render.
BondTone labelToneOf(String? tone) {
  if (tone == null || tone.isEmpty) return BondTone.neutral;
  for (final candidate in labelTones) {
    if (candidate.name == tone) return candidate;
  }
  return BondTone.neutral;
}

/// What a tone is called where a person has to pick one.
///
/// The palette's own words, from `theme/bond_tones.dart` — a label is not a
/// status, so `attention` and `error` would be describing the paint by what the
/// rest of the app uses it for. [BondTone.neutral] is `Stone` and reads as the
/// plain one, which is what clearing a label's colour leaves.
String toneLabel(BondTone tone) => switch (tone) {
      BondTone.neutral => 'Stone',
      BondTone.primary => 'Sea glass',
      BondTone.success => 'Moss',
      BondTone.attention => 'Copper',
      BondTone.error => 'Clay',
      BondTone.video => 'Violet',
    };

/// The chip one label is drawn as, by label id. What every test reads a label
/// off, and what carries the tone — assert the chip's [BondChip.tone] through
/// this key rather than hunting a colour.
ValueKey<String> labelChipKey(String id) => ValueKey('label-chip-$id');

/// The `+N` that stands for the labels a row had no room for.
const Key labelChipOverflowKey = ValueKey('label-chip-overflow');

/// One thread's labels as chips, ready to splice into a row's existing chip
/// [Wrap] — a list rather than a widget, so nothing about the row's layout has
/// to change to carry them.
///
/// At most [max] chips and then a `+N`, because a row is one line of metadata
/// and a thread the owner has filed under six words would otherwise push the
/// message count off the card. The labels arrive most-used first (the store's
/// order), so the two that survive are the two the owner reaches for.
///
/// An empty list contributes nothing at all: a thread nobody has filed draws
/// exactly the row it drew before labels existed.
List<Widget> labelChips(List<Label> labels, {int max = 2}) {
  if (labels.isEmpty) return const [];
  final shown = labels.length <= max ? labels : labels.take(max).toList();
  return [
    for (final label in shown)
      BondChip.semantic(
        label.name,
        labelToneOf(label.tone),
        key: labelChipKey(label.id),
      ),
    if (labels.length > shown.length)
      BondChip.metric(
        '+${labels.length - shown.length}',
        key: labelChipOverflowKey,
      ),
  ];
}

/// A label's colour as a small round swatch, for the Settings list — where the
/// name is already a heading and a second copy of it inside a chip would say
/// nothing the row does not.
class LabelToneSwatch extends StatelessWidget {
  final BondTone tone;

  const LabelToneSwatch({super.key, required this.tone});

  @override
  Widget build(BuildContext context) {
    final colors = bondToneColors[tone]!;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: colors.background,
        shape: BoxShape.circle,
        border: Border.all(color: colors.foreground),
      ),
    );
  }
}
