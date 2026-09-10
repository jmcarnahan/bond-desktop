import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step seven: the one permission this app asks for.
///
/// PROP-ONLY. There is EXACTLY ONE button and it says `Continue` — the word
/// `Allow` appears nowhere on this screen. macOS is about to put its own
/// dialog up with its own Allow and Don't Allow in it, and a Bond button
/// spelled the same way would look like the system prompt arriving twice, or
/// worse, like this app collecting the answer itself.
///
/// [granted] is null until the ask has happened, false when it was refused,
/// true when it was not. A refusal keeps the user on this step exactly once,
/// so they see where to change their mind; the next Continue moves on.
class SetupNotificationsBody extends StatelessWidget {
  final bool? granted;

  final VoidCallback onContinue;

  /// Opens the Notifications pane of System Settings. Null hides the link.
  final VoidCallback? onOpenSettings;

  const SetupNotificationsBody({
    super.key,
    required this.granted,
    required this.onContinue,
    required this.onOpenSettings,
  });

  static const Key openSettingsKey = ValueKey('setup-open-notification-settings');

  @override
  Widget build(BuildContext context) {
    final open = onOpenSettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Bond can let you know when a message needs you, even while it is '
          'in the background. macOS will ask whether to allow it.',
          style: BondType.body.copyWith(color: BondColors.inkSecondary),
        ),
        if (granted == false) ...[
          const SizedBox(height: BondSpacing.s16),
          const InlineAlert(
            text: 'Notifications are off for Bond. You can turn them on any '
                'time in System Settings.',
          ),
          if (open != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: openSettingsKey,
                onPressed: open,
                child: const Text('Open System Settings'),
              ),
            ),
        ],
        if (granted == true) ...[
          const SizedBox(height: BondSpacing.s16),
          Text('Notifications are on.', style: BondType.caption),
        ],
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(label: 'Continue', onPressed: onContinue),
      ],
    );
  }
}
