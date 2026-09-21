import 'package:flutter/material.dart';

import '../../services/models/model_manifest.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import 'setup_controls.dart';

/// Step three: which models arrive, what each one is for, and under what
/// licence.
///
/// PROP-ONLY, and it renders the manifest rather than a list of its own —
/// `assets/models/manifest.json` is the only place the checkpoints are named,
/// and a screen with its own copy would be the second.
///
/// [manifest] is the RESOLVED one: what THIS Mac downloads, which on the
/// inbox tier is two models rather than three. The count is in the first
/// sentence, so a person on a small Mac is told what is coming before the
/// rows say it and before the total is a number they have to compare.
///
/// The rows are in MANIFEST order (embed, bulk, prose) rather than by size,
/// because this screen is about what each model does and that order is the
/// pipeline's. The download step is the one that sorts by size.
class SetupModelsBody extends StatelessWidget {
  /// The manifest this Mac's tier resolved to, not the master list.
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

  /// Small counts read as words in a sentence. Two and three are the only
  /// ones any tier produces; anything else falls back to the digits rather
  /// than inventing a vocabulary this screen does not need.
  static String countWord(int count) => switch (count) {
        1 => 'one',
        2 => 'two',
        3 => 'three',
        _ => '$count',
      };

  /// The opening sentence, which has to agree with itself about number: no
  /// tier ships one model today, and a sentence reading "one models" would be
  /// the first thing a person saw.
  static String downloadsSentence(int count) => count == 1
      ? 'Bond downloads one model from Hugging Face. It runs on this Mac and '
          'never sends your mail anywhere.'
      : 'Bond downloads ${countWord(count)} models from Hugging Face. They '
          'run on this Mac and never send your mail anywhere.';

  /// What each role is FOR, in the user's terms. Held here rather than in the
  /// manifest because it is copy about this app's pipeline, not a fact about
  /// a checkpoint: swapping which GGUF fills the prose role must not need a
  /// new sentence.
  static String roleSentence(ModelRole role) => switch (role) {
        ModelRole.embed => 'Finds related messages',
        ModelRole.bulk => 'Reads and sorts your mail',
        ModelRole.prose => 'Writes drafts and replies',
      };

  /// What a checkpoint's second file adds, under its size. Named here so a
  /// test can pin the sentence rather than rebuild it.
  static String sidecarLine(ModelSidecar sidecar) =>
      '+ MTP head, ${formatBytes(sidecar.sizeBytes)}';

  @override
  Widget build(BuildContext context) {
    final open = onOpenLicense;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          downloadsSentence(manifest.models.length),
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatBytes(model.sizeBytes), style: BondType.small),
                  // A second file, not a second model: the writing model
                  // drafts with its own MTP head and cannot be served without
                  // it. Said under the size rather than as a row of its own,
                  // because the row is what the person is choosing and the
                  // head is not a choice — and the footer totals both.
                  if (model.sidecar case final head?) ...[
                    const SizedBox(height: BondSpacing.s4),
                    Text(sidecarLine(head), style: BondType.caption),
                  ],
                ],
              ),
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
