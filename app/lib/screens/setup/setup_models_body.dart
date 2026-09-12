import 'package:flutter/material.dart';

import '../../services/models/model_manifest.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import 'setup_controls.dart';

/// Step three: which models arrive, what each one is for, and under what
/// licence.
///
/// PROP-ONLY, and it renders the manifest rather than a list of its own —
/// `assets/models/manifest.json` is the only place the three checkpoints are
/// named, and a screen with its own copy would be the second.
///
/// The rows are in MANIFEST order (embed, bulk, prose) rather than by size,
/// because this screen is about what each model does and that order is the
/// pipeline's. The download step is the one that sorts by size.
class SetupModelsBody extends StatelessWidget {
  final ModelManifest manifest;

  /// Opens a licence in the browser. Null hides every licence button — the
  /// discipline the rest of the app keeps, so a host that cannot open a URL
  /// never offers one.
  final void Function(ModelFile file)? onOpenLicense;

  final VoidCallback onContinue;

  const SetupModelsBody({
    super.key,
    required this.manifest,
    required this.onOpenLicense,
    required this.onContinue,
  });

  static Key licenseKey(String id) => ValueKey('setup-license-$id');

  /// What each role is FOR, in the user's terms. Held here rather than in the
  /// manifest because it is copy about this app's pipeline, not a fact about
  /// a checkpoint: swapping which GGUF fills the prose role must not need a
  /// new sentence.
  static String roleSentence(ModelRole role) => switch (role) {
        ModelRole.embed => 'Finds related messages',
        ModelRole.bulk => 'Reads and sorts your mail',
        ModelRole.prose => 'Writes drafts and replies',
      };

  @override
  Widget build(BuildContext context) {
    final open = onOpenLicense;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Bond downloads three models from Hugging Face. They run on this '
          'Mac and never send your mail anywhere.',
          style: BondType.body.copyWith(color: BondColors.inkSecondary),
        ),
        const SizedBox(height: BondSpacing.s16),
        for (final model in manifest.models) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.displayName,
                      style: BondType.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(roleSentence(model.role), style: BondType.caption),
                  ],
                ),
              ),
              const SizedBox(width: BondSpacing.s12),
              Text(formatBytes(model.sizeBytes), style: BondType.small),
              if (open != null) ...[
                const SizedBox(width: BondSpacing.s8),
                TextButton(
                  key: licenseKey(model.id),
                  onPressed: () => open(model),
                  child: Text(model.license),
                ),
              ],
            ],
          ),
          // The notice is rendered VERBATIM and never abbreviated: it is what
          // the licence requires to be shown, and paraphrasing it would be
          // this app deciding what a licence meant.
          if (model.notice != null) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(model.notice!, style: BondType.caption),
          ],
          const SizedBox(height: BondSpacing.s16),
        ],
        Text(
          'Total download: ${formatBytes(manifest.totalBytes)}',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(label: 'Continue', onPressed: onContinue),
      ],
    );
  }
}
