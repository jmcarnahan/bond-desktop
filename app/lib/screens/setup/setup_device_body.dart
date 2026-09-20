import 'package:flutter/material.dart';

import '../../services/system/system_info.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step two: what this Mac is, and which models it will run.
///
/// PROP-ONLY. The three judgements — [blocked], [lowMemory] and
/// [underMeasuredFloor] — are made by the controller against the machine's
/// memory and the manifest rather than here, so the numbers that decide them
/// live with the checkpoints they describe.
///
/// The two verdicts are deliberately different in kind. An Intel Mac, or an
/// x86_64 build under Rosetta, has no Metal backend under it and there is
/// nothing to offer: this step renders NO way forward. The blocked branch is
/// insurance for a HAND-BUILT x86_64 binary rather than the shipped path —
/// the released app is arm64-only (`ARCHS = arm64`), so macOS refuses to open
/// it on an Intel Mac and nobody ever reaches this screen there.
///
/// Too little memory for the writing model is a warning and nothing more.
/// It is also a PROMISE about what happens next: the inbox tier does not
/// download the writing model at all, so the sentence says which models this
/// Mac takes and where the writing stages run instead. Triage, extraction and
/// search all run on the two small models, and those fit anywhere.
class SetupDeviceBody extends StatelessWidget {
  /// Null while the platform is still being asked.
  final HardwareInfo? hardware;

  final bool blocked;

  /// This Mac is on the inbox tier: the embedding model and the inbox model,
  /// no writing model.
  final bool lowMemory;

  /// Below the smallest machine the golden set was measured on. One more
  /// sentence, never a refusal.
  final bool underMeasuredFloor;

  /// The writing model's name, for the inbox sentence.
  final String proseName;

  /// The memory the writing model's tier starts at — `fullTierMinBytes`.
  final int fullTierMinRamBytes;

  final VoidCallback onContinue;

  const SetupDeviceBody({
    super.key,
    required this.hardware,
    required this.blocked,
    required this.lowMemory,
    required this.underMeasuredFloor,
    required this.proseName,
    required this.fullTierMinRamBytes,
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

    // What this Mac takes, in one paragraph. The floor is one more SENTENCE
    // about the same machine rather than a second verdict about it, so it
    // joins the alert instead of opening a second one.
    final inboxText = StringBuffer(
      'This Mac has $memory of memory. It runs the inbox models, the '
      'embedding model and the 4B. The writing model ($proseName) is built '
      'for ${formatBytes(fullTierMinRamBytes)} or more and is not downloaded '
      'here; writing stages run on the inbox model until you add a target '
      'under Settings, Models.',
    );
    if (underMeasuredFloor) {
      inboxText.write(
        ' The inbox models were measured on 16 GB and up; below that, expect '
        'slower triage.',
      );
    }

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
        if (!blocked && !lowMemory) ...[
          const SizedBox(height: BondSpacing.s16),
          Text(
            'This Mac runs all three models: the embedding model, the inbox '
            'model and the writing model.',
            style: BondType.caption,
          ),
        ],
        if (!blocked && lowMemory) ...[
          const SizedBox(height: BondSpacing.s16),
          InlineAlert(text: inboxText.toString()),
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
