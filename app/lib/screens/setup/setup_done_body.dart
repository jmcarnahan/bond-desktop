import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step eight: what was just set up, said back.
///
/// PROP-ONLY. It repeats four facts the user chose or was told, because the
/// wizard is about to disappear and this is the last chance to say where the
/// models went and what the app will do with them — and because the last
/// line, the one naming Settings, is only useful next to the things it can
/// change.
class SetupDoneBody extends StatelessWidget {
  final String folder;
  final int routerPort;

  /// The signed-in name, when the platform knew one. Null falls back to a
  /// plain `yes` rather than an empty row.
  final String? accountName;

  final bool? notificationsGranted;

  /// Finish is in flight — the preference is being written and the server
  /// started.
  final bool finishing;

  /// The last Finish did not save. The step stays up and says so, because the
  /// only thing to do about it is press the button again.
  final bool finishFailed;

  final VoidCallback onFinish;

  const SetupDoneBody({
    super.key,
    required this.folder,
    required this.routerPort,
    required this.accountName,
    required this.notificationsGranted,
    required this.finishing,
    required this.finishFailed,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Bond is ready.', style: BondType.heading),
        const SizedBox(height: BondSpacing.s16),
        SetupFactRow(label: 'Models', value: folder, mono: true),
        SetupFactRow(
          label: 'Model server',
          value: 'Bond runs it on port $routerPort',
        ),
        SetupFactRow(label: 'Signed in', value: accountName ?? 'yes'),
        SetupFactRow(
          label: 'Notifications',
          value: notificationsGranted == true ? 'on' : 'off',
        ),
        const SizedBox(height: BondSpacing.s8),
        Text(
          'You can change any of this later under Settings → Models → Local '
          'server.',
          style: BondType.caption,
        ),
        const SizedBox(height: BondSpacing.s24),
        if (finishFailed) ...[
          const InlineAlert(
            severity: InlineAlertSeverity.error,
            text: 'Setup could not be saved. Try Finish again.',
          ),
          const SizedBox(height: BondSpacing.s16),
        ],
        SetupPrimaryButton(
          label: 'Finish',
          onPressed: onFinish,
          busy: finishing,
        ),
      ],
    );
  }
}
