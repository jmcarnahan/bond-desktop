import 'package:flutter/material.dart';

import '../../services/system/system_info.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step two: what this Mac is, and whether the models will run on it.
///
/// PROP-ONLY. The two judgements — [blocked] and [lowMemory] — are made by
/// the controller against the manifest rather than here, so the numbers that
/// decide them live with the checkpoints they describe.
///
/// The two verdicts are deliberately different in kind. An Intel Mac, or an
/// x86_64 build under Rosetta, has no Metal backend under it and there is
/// nothing to offer: this step renders NO way forward. Too little memory for
/// the writing model is a warning and nothing more — triage, extraction and
/// search all run on the two small models, and those fit anywhere.
class SetupDeviceBody extends StatelessWidget {
  /// Null while the platform is still being asked.
  final HardwareInfo? hardware;

  final bool blocked;
  final bool lowMemory;

  /// The writing model's name and appetite, for the low-memory sentence.
  final String proseName;
  final int proseMinRamBytes;

  final VoidCallback onContinue;

  const SetupDeviceBody({
    super.key,
    required this.hardware,
    required this.blocked,
    required this.lowMemory,
    required this.proseName,
    required this.proseMinRamBytes,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final info = hardware;
    if (info == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: BondSpacing.s12),
          Text('Checking this Mac…', style: BondType.body),
        ],
      );
    }

    // 0 bytes is `HardwareInfo.unknown`'s memory, which is what a build with
    // no channel behind it answers. Saying "0 B" would be a claim; "unknown"
    // is the fact.
    final memory = info.memoryBytes > 0
        ? formatBytes(info.memoryBytes)
        : 'unknown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SetupFactRow(label: 'Chip', value: info.chip),
        SetupFactRow(label: 'Memory', value: memory),
        if (info.osVersion.isNotEmpty)
          SetupFactRow(label: 'macOS', value: info.osVersion),
        if (blocked) ...[
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Intel-based Macs are currently not supported.',
            style: BondType.heading,
          ),
          const SizedBox(height: BondSpacing.s8),
          Text("Bond's models need Apple silicon.", style: BondType.caption),
          if (info.rosetta) ...[
            const SizedBox(height: BondSpacing.s8),
            Text(
              'This copy of Bond is running under Rosetta. Download the Apple '
              'silicon build.',
              style: BondType.caption,
            ),
          ],
        ],
        if (!blocked && lowMemory) ...[
          const SizedBox(height: BondSpacing.s16),
          InlineAlert(
            text: 'This Mac has $memory of memory. The writing model '
                '($proseName) is built for ${formatBytes(proseMinRamBytes)} '
                'or more and may run slowly here. The models the inbox itself '
                'needs fit comfortably.',
          ),
        ],
        // No way forward on a machine that cannot run the models. A disabled
        // Continue would invite pressing it; an absent one says the sentence
        // above is the end of the road.
        if (!blocked) ...[
          const SizedBox(height: BondSpacing.s24),
          SetupPrimaryButton(label: 'Continue', onPressed: onContinue),
        ],
      ],
    );
  }
}
