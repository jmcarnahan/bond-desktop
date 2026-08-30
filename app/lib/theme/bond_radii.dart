import 'package:flutter/material.dart';

/// Bond design tokens — corner radii. Mirrors Paper `--radius-*`.
abstract final class BondRadii {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 16;
  static const double full = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius fullAll = BorderRadius.all(Radius.circular(full));
}

/// Bond design tokens — shadows. Exactly two exist:
///
/// - Cards rest at elevation 0 (border only).
/// - [overlay] is for overlay-class surfaces (panels lifted above the page).
/// - [subtle] is the single documented exception for resting cards.
abstract final class BondShadows {
  /// `shadowSubtle` — ink @ 8%, tight.
  static const List<BoxShadow> subtle = [
    BoxShadow(
      color: Color(0x141E2B28),
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  /// `shadowOverlay` — ink @ 12%, soft and lifted.
  static const List<BoxShadow> overlay = [
    BoxShadow(
      color: Color(0x1F1E2B28),
      offset: Offset(0, 8),
      blurRadius: 24,
    ),
  ];
}
