import 'package:flutter/material.dart';

import '../../data/app_paths.dart' show MigrationReport;
import '../../theme/tokens.dart';
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step one: what this app is, and what setting it up costs.
///
/// PROP-ONLY, the `SettingsLocalServerBody` discipline: no provider is read
/// here, the host resolves everything and takes the one action back as a
/// closure. That is what lets every sentence on this screen be pinned by a
/// test that builds nothing but this widget.
///
/// The four things named in the body are the four the user is about to do.
/// The eight steps under them are the wizard's, not theirs — a welcome screen
/// that counted its own bookkeeping screens would read as twice the work.
class SetupWelcomeBody extends StatelessWidget {
  /// What `main()` recorded about the copy out of the old sandbox container,
  /// when there was one to record. Null is the normal case — a fresh install
  /// — and renders nothing at all.
  final MigrationReport? migration;

  final VoidCallback onContinue;

  const SetupWelcomeBody({
    super.key,
    required this.migration,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final report = migration;
    final error = report?.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Bond reads your mail and Teams messages and works out what needs '
          'you.',
          style: BondType.heading,
        ),
        const SizedBox(height: BondSpacing.s12),
        Text(
          'The models that do the reading run on this Mac. Setup takes four '
          'steps: check this Mac, download the models (about 22 GB), sign in, '
          'and choose notifications.',
          style: BondType.body.copyWith(color: BondColors.inkSecondary),
        ),
        if (error != null) ...[
          const SizedBox(height: BondSpacing.s16),
          InlineAlert(
            severity: InlineAlertSeverity.error,
            text: 'Your mailbox from the previous version could not be '
                'copied: $error. Bond starts empty and syncs again after you '
                'sign in.',
          ),
        ] else if (report?.migrated == true) ...[
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Your mailbox from the previous version was brought across.',
            style: BondType.caption,
          ),
        ],
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(label: 'Get started', onPressed: onContinue),
      ],
    );
  }
}
