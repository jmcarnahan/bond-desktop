import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'triage_intents.dart';

/// `@ You · 3` with an arrow either side of it: the way through a long thread's
/// mentions.
///
/// A busy group chat is fifty messages of other people talking with two turns in
/// it that are the reader's. Those two are why the thread is in Needs You, and
/// before this control the only way to them was scrolling and reading. The count
/// is the promise ("there are three"), the arrows are the walk, and the position
/// says where in the walk the reader stands once they have taken a step.
///
/// It holds no callbacks. Both arrows INVOKE the intents in
/// `triage_intents.dart` and let whatever `Actions` sits above answer — the same
/// arrangement every triage button lives under, and the reason a key and a
/// button cannot come to disagree about where "next" is. Nothing above handling
/// them means a press does nothing, which is the honest outcome for a host that
/// wired no transcript to scroll.
class MentionNavigator extends StatelessWidget {
  /// How many messages in this thread name the owner
  /// (`services/mention_index.dart`). Zero draws nothing at all.
  final int count;

  /// Which stop the reader is on, 1-based, or null before they have stepped.
  ///
  /// Null is not "the first one": it is "you have not started", which is why the
  /// first press of either arrow lands on an END of the walk rather than on the
  /// second stop.
  final int? position;

  const MentionNavigator({super.key, required this.count, this.position});

  /// The whole control, for a test that wants to say it is or is not there.
  static const Key navigatorKey = ValueKey('mention-navigator');

  /// The count-and-position words, read as text rather than by colour.
  static const Key labelKey = ValueKey('mention-navigator-label');

  /// Toward the newest mention — down the transcript, the direction the reader
  /// reads in.
  static const Key nextKey = ValueKey('mention-navigator-next');

  static const Key previousKey = ValueKey('mention-navigator-previous');

  /// `@ You · 3` before the first step, `@ You · 2 of 3` after one.
  ///
  /// Pure and static so the words are pinned without pumping a widget: the count
  /// is a promise about the thread and the position is a claim about where the
  /// reader is, and both have to survive a refactor of the row that draws them.
  static String labelFor(int count, int? position) =>
      position == null ? '@ You · $count' : '@ You · $position of $count';

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    // At an edge the walk STOPS (`stepMention`), so the arrow that would run off
    // the end is drawn disabled rather than left looking live: this control is
    // also how the reader finds out there is nothing further up.
    final at = position;
    final canGoNext = at == null || at < count;
    final canGoBack = at == null ? count > 0 : at > 1;

    return Row(
      key: navigatorKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          labelFor(count, at),
          key: labelKey,
          style: BondType.small.copyWith(
            color: BondColors.onAttentionTint,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: BondSpacing.s4),
        _Step(
          icon: Icons.keyboard_arrow_up,
          tooltip: 'Previous mention',
          buttonKey: previousKey,
          intent: canGoBack ? const PreviousMentionIntent() : null,
        ),
        _Step(
          icon: Icons.keyboard_arrow_down,
          tooltip: 'Next mention',
          buttonKey: nextKey,
          intent: canGoNext ? const NextMentionIntent() : null,
        ),
      ],
    );
  }
}

/// One arrow. A null [intent] is an edge of the walk and draws the button
/// disabled.
class _Step extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Key buttonKey;
  final Intent? intent;

  const _Step({
    required this.icon,
    required this.tooltip,
    required this.buttonKey,
    required this.intent,
  });

  @override
  Widget build(BuildContext context) {
    final step = intent;
    return IconButton(
      key: buttonKey,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      color: BondColors.onAttentionTint,
      onPressed:
          step == null ? null : () => Actions.maybeInvoke(context, step),
    );
  }
}
