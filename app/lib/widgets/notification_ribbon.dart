import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'inline_alert.dart';

/// The banner that slides in when a processed message needs the user.
///
/// An [InlineAlert] lifted off the page: the same tinted row the inbox already
/// uses to say a thread is waiting on an answer, given a shadow, a tap target
/// and a way out. Presentation only — what it says, how loud it is and when it
/// goes are all decided above it, so this widget can be pumped on its own.
class NotificationRibbon extends StatelessWidget {
  final InlineAlertSeverity severity;
  final String text;

  /// Opens whatever the ribbon is announcing.
  final VoidCallback onTap;

  /// Takes it off screen without going anywhere.
  final VoidCallback onDismiss;

  const NotificationRibbon({
    super.key,
    required this.severity,
    required this.text,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // Wide enough for a subject and a storyline, narrow enough to read as a
      // notice over the inbox rather than a bar across it.
      constraints: const BoxConstraints(maxWidth: 420),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: BondShadows.overlay,
          borderRadius: BondRadii.smAll,
        ),
        child: Material(
          // The shadow and the tint are the alert's own; this Material exists
          // for the ink the tap draws and nothing else.
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BondRadii.smAll,
            child: InlineAlert(
              severity: severity,
              text: text,
              maxLines: 2,
              action: IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
                iconSize: 16,
                tooltip: 'Dismiss',
                padding: const EdgeInsets.all(BondSpacing.s4),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
