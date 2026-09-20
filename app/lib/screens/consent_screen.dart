import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// What leaves this machine when a draft is written somewhere else, asked once
/// and answered by the person.
///
/// The BODY of a pane, not the pane: `SettingsScreen` wraps it in the
/// `PaneSurface` titled **Cloud drafts** whose back arrow is Not now, because
/// the screen is what owns which sub-pane is open. Prop-only, so the copy is
/// pinned by a widget test with no prefs and no network behind it.
///
/// It appears for one reason only: a THIRD-PARTY target picked for a draft
/// stage. A target on somebody else's machine answering triage or a storyline
/// name never asks, because what those prompts carry is a subject line and a
/// summary; a draft prompt carries the message, the tail of its thread and
/// excerpts from the user's own directories, and that is a different question.
class CloudDraftsConsentPane extends StatelessWidget {
  /// The target's own name, as the person typed it. The question is about a
  /// machine they named, not about a category.
  final String targetName;

  /// Which stage this would answer, from `pipelineStages`.
  final String stageLabel;

  /// How many drafts a day may go to a third-party target at all.
  final int dailyCap;

  final VoidCallback onContinue;
  final VoidCallback onNotNow;

  const CloudDraftsConsentPane({
    super.key,
    required this.targetName,
    required this.stageLabel,
    this.dailyCap = 50,
    required this.onContinue,
    required this.onNotNow,
  });

  static const Key continueKey = ValueKey('consent-continue');
  static const Key notNowKey = ValueKey('consent-not-now');
  static const Key measuredKey = ValueKey('consent-measured');

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Send drafts to $targetName?', style: BondType.titleSm),
          const SizedBox(height: BondSpacing.s8),
          Text(
            'This target would answer the $stageLabel stage.',
            style: BondType.small,
          ),
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Every draft sent to this target leaves this machine. What goes: '
            'the message being answered, the last few messages of its thread, '
            'the storyline summary if there is one, and short excerpts from '
            'your registered directories. What never goes: the rest of the '
            'mailbox, your sign in, and your settings.',
            style: BondType.body,
          ),
          const SizedBox(height: BondSpacing.s24),
          // The numbers sit in a table rather than in the paragraph above,
          // because the whole point of them is that a reader compares the two.
          Table(
            key: measuredKey,
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              _measuredRow('Local 27B', '6 of 25 drafts passed'),
              _measuredRow('Opus 5', '17 of 25 drafts passed'),
            ],
          ),
          const SizedBox(height: BondSpacing.s4),
          Text(
            'Measured on 25 replies from the golden set, 2026-09-17.',
            style: BondType.caption,
          ),
          const SizedBox(height: BondSpacing.s16),
          Text(
            'At most $dailyCap drafts a day go to a third-party target. You '
            'can change the cap under Settings, Processing.',
            style: BondType.small,
          ),
          const SizedBox(height: BondSpacing.s24),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: BondSpacing.s8,
            children: [
              TextButton(
                key: notNowKey,
                onPressed: onNotNow,
                child: const Text('Not now'),
              ),
              FilledButton(
                key: continueKey,
                onPressed: onContinue,
                child: const Text('I understand, continue'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  TableRow _measuredRow(String model, String score) => TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              right: BondSpacing.s16,
              bottom: BondSpacing.s4,
            ),
            child: Text(
              model,
              style: BondType.small.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: BondSpacing.s4),
            child: Text(score, style: BondType.small),
          ),
        ],
      );
}
