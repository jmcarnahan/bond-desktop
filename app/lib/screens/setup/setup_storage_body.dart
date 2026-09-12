import 'package:flutter/material.dart';

import '../../services/models/disk_preflight.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import '../../widgets/inline_alert.dart';
import 'setup_controls.dart';

/// Step four: where the weights go, and whether they fit.
///
/// PROP-ONLY. [disk] null means the preflight has not answered yet, and
/// Continue is dead until it has: letting somebody start a twenty-three
/// gigabyte download before the volume has been asked about is how a Mac ends
/// up with no disk left.
///
/// Free space that CANNOT be asked is not a refusal. The download hits ENOSPC
/// and keeps its part, which is a recoverable failure with a sentence
/// attached, and refusing on ignorance would block a network mount that
/// simply cannot answer. A folder Bond cannot WRITE to is the other way
/// round: that one is known, it is fatal to every file, and the only way past
/// it is another folder.
class SetupStorageBody extends StatelessWidget {
  /// The EFFECTIVE folder — the host has already resolved "the app's own
  /// folder" into a path.
  final String folder;

  final DiskPreflight? disk;

  /// Opens the system's folder panel. Null hides the button.
  final VoidCallback? onChooseFolder;

  final VoidCallback onContinue;

  const SetupStorageBody({
    super.key,
    required this.folder,
    required this.disk,
    required this.onChooseFolder,
    required this.onContinue,
  });

  static const Key changeFolderKey = ValueKey('setup-change-folder');

  @override
  Widget build(BuildContext context) {
    final choose = onChooseFolder;
    final preflight = disk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Models folder',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(folder, style: BondType.mono),
        if (choose != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: changeFolderKey,
              onPressed: choose,
              child: const Text('Change folder…'),
            ),
          ),
        const SizedBox(height: BondSpacing.s16),
        ..._space(preflight),
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(
          label: 'Continue',
          // Dead until the volume has answered and the answer was yes. See
          // the class comment for why "could not be asked" counts as yes.
          onPressed:
              preflight == null || !preflight.ok ? null : onContinue,
        ),
      ],
    );
  }

  List<Widget> _space(DiskPreflight? preflight) {
    if (preflight == null) {
      return [Text('Checking free space…', style: BondType.body)];
    }
    if (!preflight.writable) {
      // Ahead of every arithmetic branch: a folder that refuses the first byte
      // makes the free figure beside it irrelevant, and the preflight's `ok`
      // has already made Continue dead.
      return [
        InlineAlert(
          severity: InlineAlertSeverity.error,
          text: "Bond can't write to this folder. Choose another one.",
        ),
      ];
    }
    if (!preflight.known) {
      return [
        Text(
          'Free space could not be checked. If the download runs out of room '
          'it stops and keeps what it has.',
          style: BondType.caption,
        ),
      ];
    }
    if (!preflight.ok) {
      // `formatBytes` answers the empty string for zero, and a volume with
      // nothing left on it is exactly the case this sentence is for — so the
      // free figure is guarded the way the download step's byte counts are.
      final free = formatBytes(preflight.freeBytes);
      return [
        InlineAlert(
          severity: InlineAlertSeverity.error,
          text: 'Not enough space: the download needs '
              '${formatBytes(preflight.requiredBytes)} and '
              '${free.isEmpty ? '0 B' : free} is free. Free up '
              '${formatBytes(preflight.shortfallBytes)} or choose another '
              'folder.',
        ),
        const SizedBox(height: BondSpacing.s8),
        // Said out loud because the required number is bigger than the
        // manifest total, and a reader doing the arithmetic would otherwise
        // conclude the app cannot add up.
        Text(
          'That includes 10 GB of headroom the models need to load.',
          style: BondType.caption,
        ),
      ];
    }
    if (preflight.neededBytes == 0) {
      return [
        Text('All models are already in this folder.', style: BondType.body),
      ];
    }
    return [
      Text(
        'Free after download: '
        '${formatBytes(preflight.freeBytes! - preflight.neededBytes)}',
        style: BondType.body,
      ),
    ];
  }
}
