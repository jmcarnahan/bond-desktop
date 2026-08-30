import 'package:flutter/material.dart';

/// Bond design tokens — colors. 1:1 with the Paper `--color-*` tokens
/// (design-plans/00-overview.md) plus the Phase 0 expansion mandated by
/// design-plans/23-evaluation.md §14 (blocking prerequisite for the
/// no-raw-hex grep gate).
///
/// This file is the ONLY place raw color values may appear outside tests.
abstract final class BondColors {
  // ── Base palette (Paper --color-*) ────────────────────────────────────
  /// Limestone bone — scaffold/page background (`--color-ground`).
  static const Color ground = Color(0xFFFAF9F7);

  /// Cards and panels (`--color-surface`).
  static const Color surface = Color(0xFFFFFFFF);

  /// Deep slate — primary text (`--color-ink`), also the sidebar fill.
  static const Color ink = Color(0xFF1E2B28);

  /// Secondary text (`--color-ink-secondary`).
  static const Color inkSecondary = Color(0xFF5B6B67);

  /// Oxidized copper — primary actions (`--color-primary`).
  static const Color primary = Color(0xFF2E6E62);

  /// Primary hover/pressed (`--color-primary-deep`).
  static const Color primaryDeep = Color(0xFF235349);

  /// Selected/hover surfaces (`--color-primary-tint`).
  static const Color primaryTint = Color(0xFFEAF1EF);

  /// Hairline borders (`--color-border`).
  static const Color border = Color(0xFFE8E4DD);

  /// Moss — success / funded.
  static const Color success = Color(0xFF3D7A54);

  /// Warm copper — needs attention.
  static const Color attention = Color(0xFFB07C4F);

  /// Clay — error / declined.
  static const Color error = Color(0xFFA8433B);

  // ── §14 expansion: semantic tint pairs (bg + on-bg text) ──────────────
  static const Color successTint = Color(0xFFE9F0EA);
  static const Color onSuccessTint = Color(0xFF2E5C3F);
  static const Color attentionTint = Color(0xFFF3EBE2);
  static const Color onAttentionTint = Color(0xFF8A5F3A);
  static const Color errorTint = Color(0xFFF4E7E5);
  static const Color onErrorTint = Color(0xFF8A3730);

  /// Border for primary-tinted surfaces.
  static const Color primaryTintBorder = Color(0xFFD8E5E1);

  // ── §14 expansion: warm neutrals ──────────────────────────────────────
  /// Neutral chip/tile fill.
  static const Color neutralTint = Color(0xFFF0EDE8);

  /// Faint table-header ground.
  static const Color faintGround = Color(0xFFF5F3EF);

  /// Kanban lane ground / hairline dividers.
  static const Color laneGround = Color(0xFFF1EEE9);

  /// Preview-frame ground.
  static const Color previewGround = Color(0xFFEDEAE4);

  // ── §14 expansion: muted text + dashed border ─────────────────────────
  /// Placeholders, disabled chevrons.
  static const Color inkMuted = Color(0xFF9AA5A1);

  /// Disabled "soon" labels / faint captions.
  static const Color inkDisabled = Color(0xFFB4AFA6);

  /// Dashed borders (dropzones, add-slots).
  static const Color borderDashed = Color(0xFFC9C4BB);

  // ── §14 expansion: dark surfaces ──────────────────────────────────────
  /// Dark icon/agent tiles.
  /// Ink scrim behind media play discs (video player overlay).
  static const Color inkScrim = Color(0x661E2B28); // ink 40%

  static const Color darkTile = Color(0xFF3A4744);
  static const Color darkTileAlt = Color(0xFF55635F);

  /// On-dark white-alpha set (sidebar, dark tiles).
  static const Color onDarkFaint = Color(0x0FFFFFFF); //  6% — hover tint
  static const Color onDarkTint = Color(0x1FFFFFFF); // 12% — pills, user block
  static const Color onDarkBorder = Color(0x33FFFFFF); // 20%
  static const Color onDarkMuted = Color(0x8CFFFFFF); // 55% — secondary text
  static const Color onDarkSecondary = Color(0xA6FFFFFF); // 65% — inactive labels
  static const Color onDarkPrimary = Color(0xE6FFFFFF); // 90%

  /// Sea-glass accent on dark surfaces.
  static const Color seaGlassOnDark = Color(0xFF7FBAAE);

  // ── §14 expansion: governed off-palette channel color (decision 9) ────
  static const Color channelVideo = Color(0xFF6D5BA6);
  static const Color channelVideoTint = Color(0xFFEFE9F6);
}
