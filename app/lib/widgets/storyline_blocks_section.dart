import 'package:flutter/material.dart';

import '../models/storyline_models.dart';
import '../theme/tokens.dart';

/// The threads somebody took out of a storyline — the owner's own and the
/// re-check pass's — with the ways back in, and the button that runs the
/// re-check.
///
/// It sits at the FOOT OF THE MESSAGES TAB, under the spine it is about. The
/// reader who has just looked at six cards and doubts three of them is looking
/// here; a reference tab beside the storyline is not where they would go.
///
/// Empty is the ordinary state and renders no headings at all. The re-check
/// button is offered either way: it judges the members, not the blocks.
class StorylineBlocksSection extends StatelessWidget {
  /// The threads somebody took out of this storyline, for the two lists.
  final List<StorylineBlock> blocks;

  /// Lifts the veto on one blocked thread without filing it back: the model
  /// may decide for itself, next time a pass looks at it. Null leaves the
  /// button inert.
  final void Function(String source, String conversationKey)? onUnblockThread;

  /// Files a blocked thread back in by hand, which clears its block whichever
  /// pass wrote it. Null leaves the button inert.
  final void Function(String source, String conversationKey)? onAddBackThread;

  /// Re-judges the threads the model filed here. Null leaves the button inert.
  final VoidCallback? onAudit;

  /// True while a re-check this owner asked for is still in the worker. The
  /// button goes inert and says so, because pressing *Add back* under a pass
  /// that is mid-flight is how a thread gets removed and re-filed in the same
  /// minute.
  final bool auditing;

  static const Key userBlocksHeadingKey =
      ValueKey('storyline-blocks-user-heading');
  static const Key auditBlocksHeadingKey =
      ValueKey('storyline-blocks-audit-heading');
  static const Key auditButtonKey = ValueKey('storyline-audit-button');

  /// The two ways back, keyed by source AND key: two connectors can carry one
  /// conversation key, and a test that tapped the twin would still pass.
  static Key addBackKeyFor(String source, String key) =>
      Key('storyline-add-back-$source-$key');
  static Key allowAgainKeyFor(String source, String key) =>
      Key('storyline-allow-again-$source-$key');

  /// A member entry carries a whole subject line, which can be arbitrarily
  /// long.
  static const double _entryMaxWidth = 320;

  const StorylineBlocksSection({
    super.key,
    this.blocks = const [],
    this.onUnblockThread,
    this.onAddBackThread,
    this.onAudit,
    this.auditing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Said once, above both lists: the two buttons on every entry read
        // alike and do very different things, and a reader who pressed the
        // wrong one is the reader who ends up with three threads missing.
        if (blocks.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s8),
          Text(
            'Add back puts a thread on the spine again. Allow again only '
            'lifts the block — the model may file the thread again on its '
            'own, or not.',
            style: BondType.caption,
          ),
        ],
        ..._blockList(
          'REMOVED BY YOU',
          [
            for (final block in blocks)
              if (block.blockedByUser) block,
          ],
          key: userBlocksHeadingKey,
        ),
        ..._blockList(
          'REMOVED BY RE-CHECK',
          [
            for (final block in blocks)
              if (!block.blockedByUser) block,
          ],
          key: auditBlocksHeadingKey,
        ),
        Row(
          children: [
            _quietButton(
              auditing ? 'Re-checking…' : 'Re-check members',
              auditing ? null : onAudit,
              key: auditButtonKey,
            ),
          ],
        ),
        Text(
          auditing
              ? 'The model is re-judging each thread against the charter. '
                  'This takes a moment per thread; the spine updates as it '
                  'goes.'
              : 'Re-judges the threads the model filed here against the '
                  'charter and what you kept and removed.',
          style: BondType.caption,
        ),
      ],
    );
  }

  /// One heading and its removed threads, or nothing when none were removed
  /// that way. Two lists rather than one, because the two answer different
  /// questions: what the owner has already said no to, and what the re-check
  /// pass decided on its own and may have got wrong.
  List<Widget> _blockList(
    String heading,
    List<StorylineBlock> blocks, {
    required Key key,
  }) {
    if (blocks.isEmpty) return const [];
    return [
      const SizedBox(height: BondSpacing.s8),
      Text(heading, key: key, style: BondType.label),
      const SizedBox(height: 2),
      for (final block in blocks)
        Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s4),
          child: _blockEntry(block),
        ),
    ];
  }

  /// One removed thread, shaped like a member entry so the two lists read as
  /// the same kind of thing seen from opposite sides.
  ///
  /// A block outlives the thread it was written about — the store keeps it
  /// when the conversation row goes — so the subject can be missing and the
  /// entry says so rather than rendering a blank line.
  Widget _blockEntry(StorylineBlock block) {
    return Container(
      constraints: const BoxConstraints(maxWidth: _entryMaxWidth),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s8,
        vertical: BondSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            block.subject ?? '(thread no longer stored)',
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            block.evidence?.isNotEmpty == true
                ? block.evidence!
                : 'No reason recorded.',
            style: BondType.caption,
          ),
          Row(
            children: [
              // FIRST, because it is the one a reader looking at a thread the
              // re-check took out actually wants: it files the thread by hand,
              // which clears the block on the way in — a block of either kind,
              // since both entries offer both buttons.
              _quietButton(
                'Add back',
                onAddBackThread == null
                    ? null
                    : () => onAddBackThread!(
                          block.source,
                          block.conversationKey,
                        ),
                key: addBackKeyFor(block.source, block.conversationKey),
              ),
              const SizedBox(width: BondSpacing.s4),
              // Lifts the veto and nothing else: the thread is not filed back,
              // the model is simply allowed to decide about it again.
              _quietButton(
                'Allow again',
                onUnblockThread == null
                    ? null
                    : () => onUnblockThread!(
                          block.source,
                          block.conversationKey,
                        ),
                key: allowAgainKeyFor(block.source, block.conversationKey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The panel's own quiet button, copied rather than shared: a null
  /// [onPressed] is the inert state, and the button stays where it is.
  Widget _quietButton(String label, VoidCallback? onPressed, {Key? key}) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: BondType.caption.copyWith(
        color: BondColors.primary,
        fontWeight: FontWeight.w600,
      )),
    );
  }
}
