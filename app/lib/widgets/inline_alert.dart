import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// InlineAlert severities. Only the two this app renders exist here —
/// attention (the needs-reply CTA banner) and error.
enum InlineAlertSeverity { attention, error }

/// A static inline tinted message row: leading icon, text, optional trailing
/// action. Distinct from a SnackBar (transient) and from a full error panel.
class InlineAlert extends StatelessWidget {
  final InlineAlertSeverity severity;
  final String text;
  final Widget? action;

  /// Drawn in place of [text]'s own `Text`, for a caller whose words carry
  /// links (`LinkedText`). Handed the style the alert would have used, so the
  /// severity's ink stays this widget's call — and expected to paint [text]'s
  /// words, since that is the alert's sentence and what finders will look for.
  /// A caller that paints something else entirely is on its own.
  final Widget Function(TextStyle style)? content;

  /// Caps [text] at N lines with an ellipsis. Null lets it run. The inbox CTA
  /// banner caps at 2 — it sits directly above the transcript and a
  /// three-line ask was eating the read.
  final int? maxLines;

  const InlineAlert({
    super.key,
    this.severity = InlineAlertSeverity.attention,
    required this.text,
    this.action,
    this.content,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, Color border, IconData icon) = switch (severity) {
      InlineAlertSeverity.attention => (
          BondColors.attentionTint,
          BondColors.onAttentionTint,
          BondColors.attentionTint,
          Icons.warning_amber_outlined,
        ),
      InlineAlertSeverity.error => (
          BondColors.errorTint,
          BondColors.onErrorTint,
          BondColors.errorTint,
          Icons.error_outline,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s12,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            child: content?.call(BondType.small.copyWith(color: fg)) ??
                Text(
                  text,
                  style: BondType.small.copyWith(color: fg),
                  maxLines: maxLines,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                ),
          ),
          if (action != null) ...[
            const SizedBox(width: BondSpacing.s12),
            action!,
          ],
        ],
      ),
    );
  }
}
