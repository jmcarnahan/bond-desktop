/// The one rule for "does this need the owner": the decision model's
/// probability against the owner's slider.
///
/// Every message the triage pass keeps carries `messages.needs_you_p`, the
/// decision model's calibrated p(needs_you = yes). The owner's slider
/// (`needs_you_threshold`) is a cut on that same number, and a message needs
/// the owner exactly when its probability is at or above the cut. Nothing else
/// gates: no band sent to a language model, no cold-outreach bar, no Teams
/// floor. Moving the slider re-reads stored probabilities and asks no model
/// anything.
///
/// Two spellings of one rule, [needsYouAt] for Dart and [needsYouAtSql] for a
/// query, pinned to agree by `needs_you_predicate_test`. A NULL probability is
/// a message not decided yet, and it needs nobody in either spelling: an
/// undecided message is not a low one, but it is not an ask either until the
/// model has read it.
library;

/// The slider's range and default.
abstract final class NeedsYouTuning {
  /// Fitted on the golden set 2026-09-29: keep-only needs_you scored 69/76 at
  /// 0.30 against 67/76 at 0.50, on a plateau from 0.30 to 0.55. The lower
  /// end of the plateau was chosen because a missed ask costs the owner more
  /// than one extra row to glance past.
  static const double defaultThreshold = 0.30;

  /// The slider's ends. Neither reaches 0 or 1: a cut of 0 would put every
  /// decided message in Needs You, and a cut of 1 would empty it.
  static const double minThreshold = 0.05;
  static const double maxThreshold = 0.95;

  /// One slider notch. A stored threshold is rounded to it, so the number the
  /// slider shows is the number the queries read.
  static const double step = 0.05;
}

/// Whether a message with probability [p] needs the owner at [threshold].
bool needsYouAt(double? p, double threshold) => p != null && p >= threshold;

/// [needsYouAt] as a SQL condition over [column].
///
/// [threshold] is SQL text, a bound `?` or a literal, so a query binds the
/// owner's slider like any other argument. The explicit NULL test is for the
/// reader rather than for sqlite, whose `NULL >= x` is already not true: it
/// says in the query what the Dart spelling says with `p != null`.
String needsYouAtSql(String column, String threshold) =>
    '($column IS NOT NULL AND $column >= $threshold)';

/// [value] on the slider: clamped to its range and rounded to its nearest
/// notch. The rounding goes through two decimals so a notch is stored as
/// `0.35`, never as `0.35000000000000003`, and the number the slider shows is
/// the number a query binds. A value that is not a number is the default.
double normalizeNeedsYouThreshold(double value) {
  if (value.isNaN) return NeedsYouTuning.defaultThreshold;
  final clamped = value.clamp(
    NeedsYouTuning.minThreshold,
    NeedsYouTuning.maxThreshold,
  );
  final notch = (clamped / NeedsYouTuning.step).round() * NeedsYouTuning.step;
  return double.parse(notch.toStringAsFixed(2));
}

/// The stored `needs_you_threshold` pref as a threshold. Absent or unreadable
/// is the default; anything else is normalized, so a hand-edited value cannot
/// empty Needs You or fill it with every decided message.
double parseNeedsYouThreshold(String? raw) {
  final parsed = raw == null ? null : double.tryParse(raw);
  return parsed == null
      ? NeedsYouTuning.defaultThreshold
      : normalizeNeedsYouThreshold(parsed);
}
