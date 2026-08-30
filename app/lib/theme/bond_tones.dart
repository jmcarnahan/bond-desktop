import 'package:flutter/material.dart';

import 'bond_colors.dart';

/// Bond tones — the ONE central value→color mapping. Screens pass values;
/// only this file resolves them to colors. Feeds `BondChip` and any tinted
/// indicator.
///
/// Ported from a sibling CRM app's tone tokens with the CRM-specific
/// resolvers (stage, contact type, loan status, chart series) dropped — this
/// app has no pipeline to tint.
enum BondTone {
  /// Warm limestone — untyped/neutral values.
  neutral,

  /// Sea-glass / primary tint — calm in-progress values.
  primary,

  /// Moss — success / funded / sent / connected.
  success,

  /// Warm copper — needs attention / pending.
  attention,

  /// Clay — error / declined / failed.
  error,

  /// Governed off-palette purple — the Video channel only.
  video,
}

/// Background / foreground / border triple for a [BondTone].
class BondToneColors {
  final Color background;
  final Color foreground;
  final Color border;

  const BondToneColors({
    required this.background,
    required this.foreground,
    required this.border,
  });
}

const Map<BondTone, BondToneColors> bondToneColors = {
  BondTone.neutral: BondToneColors(
    background: BondColors.neutralTint,
    foreground: BondColors.inkSecondary,
    border: BondColors.border,
  ),
  BondTone.primary: BondToneColors(
    background: BondColors.primaryTint,
    foreground: BondColors.primaryDeep,
    border: BondColors.primaryTintBorder,
  ),
  BondTone.success: BondToneColors(
    background: BondColors.successTint,
    foreground: BondColors.onSuccessTint,
    border: BondColors.successTint,
  ),
  BondTone.attention: BondToneColors(
    background: BondColors.attentionTint,
    foreground: BondColors.onAttentionTint,
    border: BondColors.attentionTint,
  ),
  BondTone.error: BondToneColors(
    background: BondColors.errorTint,
    foreground: BondColors.onErrorTint,
    border: BondColors.errorTint,
  ),
  BondTone.video: BondToneColors(
    background: BondColors.channelVideoTint,
    foreground: BondColors.channelVideo,
    border: BondColors.channelVideoTint,
  ),
};
