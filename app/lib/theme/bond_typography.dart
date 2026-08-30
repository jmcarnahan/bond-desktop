import 'package:flutter/material.dart';

import 'bond_colors.dart';

/// Bond design tokens — type scale. Mirrors the Paper `--text-*` tokens.
///
/// Rule of voice (design-plans/01-component-library.md): Fraunces for page
/// titles, greetings, and headline numbers only — the moments the product
/// speaks to a person. Inter everywhere work happens. IBM Plex Mono for
/// rates/IDs where tabular alignment matters.
///
/// Fraunces scale is governed by 23-evaluation.md decision 11:
/// `title` 32 (list/landing) and `titleSm` 24 (detail/form headers, auth) —
/// no other Fraunces sizes exist.
abstract final class BondType {
  static const String voiceFamily = 'Fraunces';
  static const String workFamily = 'Inter';
  static const String monoFamily = 'IBMPlexMono';

  // ── Fraunces · voice ──────────────────────────────────────────────────
  /// Hero numbers/greetings (56/60).
  static const TextStyle hero = TextStyle(
    fontFamily: voiceFamily,
    fontSize: 56,
    height: 60 / 56,
    fontWeight: FontWeight.w600,
    color: BondColors.ink,
  );

  /// Page titles — list/landing screens (32).
  static const TextStyle title = TextStyle(
    fontFamily: voiceFamily,
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w600,
    color: BondColors.ink,
  );

  /// Detail/form/auth headers (24).
  static const TextStyle titleSm = TextStyle(
    fontFamily: voiceFamily,
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w600,
    color: BondColors.ink,
  );

  // ── Inter · work ──────────────────────────────────────────────────────
  /// Section headings (22/semibold).
  static const TextStyle heading = TextStyle(
    fontFamily: workFamily,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    color: BondColors.ink,
  );

  /// Body copy (16/24).
  static const TextStyle body = TextStyle(
    fontFamily: workFamily,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
    color: BondColors.ink,
  );

  /// Meta/secondary (14/20, medium).
  static const TextStyle small = TextStyle(
    fontFamily: workFamily,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    color: BondColors.inkSecondary,
  );

  /// Caption (12/16, normal case) — fine print, timestamps, tertiary meta.
  /// [label] is the caps variant of this size.
  static const TextStyle caption = TextStyle(
    fontFamily: workFamily,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    color: BondColors.inkSecondary,
  );

  /// Caps labels (12, +0.08em tracking). Call sites uppercase the text —
  /// TextStyle cannot apply a text transform.
  static const TextStyle label = TextStyle(
    fontFamily: workFamily,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 12 * 0.08,
    color: BondColors.inkSecondary,
  );

  // ── IBM Plex Mono · accents ───────────────────────────────────────────
  /// Rates, IDs, amounts where tabular alignment matters (14/20).
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
    color: BondColors.ink,
  );
}
