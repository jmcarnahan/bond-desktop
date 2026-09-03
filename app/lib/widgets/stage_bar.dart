import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';

/// One message's trip through the pipeline, as four segments.
///
/// Four and not five: ingest is the row existing at all, so a segment for it
/// would be full on every row ever rendered and would say nothing.
///
/// **A running segment is a static half-fill, never a creep.** A bar that
/// crawled would be a perpetual animation on a screen designed to be left open
/// all day — the widget tests would never settle, and the motion would be a
/// lie besides: nothing here knows how far through a stage the model is. Half
/// means "started, not finished", and the caption underneath says which stage
/// in words. Same rule as `conversation_row.dart`'s "thinking…": words, not
/// spinners.
///
/// Every judgement about what a state LOOKS like is in [fillFor], and what a
/// bar SAYS is in [captionFor], both pure and static — the two facts worth
/// pinning are testable without a pump.
class HomeStageBar extends StatelessWidget {
  /// The stages in pipeline order. Also the key order the widget builds in, so
  /// a test can walk them.
  static const List<String> stages = ['triage', 'extract', 'storyline', 'settle'];

  /// The track, shared with the feed row's column grid.
  static const double trackWidth = 200;
  static const double trackHeight = 6;

  /// Gap between segments. Small enough to read as one bar, wide enough that
  /// four full segments are still four.
  static const double segmentGap = 2;

  static const Duration fillDuration = Duration(milliseconds: 240);

  /// How much of a running segment is filled. A CONSTANT, and the tests hold
  /// it there — see the class doc.
  static const double runningFactor = 0.5;

  /// Historical rows keep their segments — a skipped extract is a diagnostic —
  /// but drop back so the live rows above them read first.
  static const double mutedOpacity = 0.55;

  final String triageState;
  final String extractState;
  final String storylineState;
  final String settleState;

  /// A row the pipeline has finished with. Dims the bar and drops the caption:
  /// there is nothing in progress to narrate.
  final bool muted;

  const HomeStageBar({
    super.key,
    required this.triageState,
    required this.extractState,
    required this.storylineState,
    required this.settleState,
    this.muted = false,
  });

  HomeStageBar.forRow(
    HomeFeedRow row, {
    super.key,
    this.muted = false,
  })  : triageState = row.triageState,
        extractState = row.extractState,
        storylineState = row.storylineState,
        settleState = row.settleState;

  /// The four states by stage name — what [captionFor] reads.
  static Map<String, String> statesOf(HomeFeedRow row) => {
        'triage': row.triageState,
        'extract': row.extractState,
        'storyline': row.storylineState,
        'settle': row.settleState,
      };

  /// What each stage is called while it is happening. Present tense and
  /// lowercase: this is the app narrating itself, not labelling a column.
  static const Map<String, String> _runningCaptions = {
    'triage': 'triaging…',
    'extract': 'extracting…',
    'storyline': 'grouping…',
    'settle': 'settling…',
  };

  /// The word under the bar, or null when nothing is running.
  ///
  /// The FIRST running stage, in pipeline order. Two stages are only ever
  /// running at once across different queues, and the earlier one is the one
  /// the rest are waiting behind.
  static String? captionFor(Map<String, String> states) {
    for (final stage in stages) {
      if (states[stage] == 'running') return _runningCaptions[stage];
    }
    return null;
  }

  /// The track colour, the fill colour, and how much of the track the fill
  /// covers.
  ///
  /// Anything this does not recognise reads as `pending`. A newer build's
  /// vocabulary must render as an empty segment rather than throw on a table
  /// someone left open.
  static ({Color track, Color fill, double factor}) fillFor(String state) {
    final neutral = bondToneColors[BondTone.neutral]!;
    return switch (state) {
      'running' => (
          track: bondToneColors[BondTone.primary]!.background,
          fill: bondToneColors[BondTone.primary]!.foreground,
          factor: runningFactor,
        ),
      'done' => (
          track: bondToneColors[BondTone.success]!.background,
          fill: bondToneColors[BondTone.success]!.foreground,
          factor: 1.0,
        ),
      'error' => (
          track: bondToneColors[BondTone.error]!.background,
          fill: bondToneColors[BondTone.error]!.foreground,
          factor: 1.0,
        ),
      // Skipped is an END state, not a failure — a gated message's bar must
      // not wait forever. It reads as an empty segment with an outline: this
      // stage was decided against, rather than still owed.
      'skipped' => (track: neutral.background, fill: neutral.background, factor: 0.0),
      _ => (track: neutral.background, fill: neutral.background, factor: 0.0),
    };
  }

  /// Whether a state draws the outline that separates "decided against" from
  /// "not yet".
  static bool isSkipped(String state) => state == 'skipped';

  static ValueKey<String> segmentKey(String stage) => ValueKey('stage-$stage');

  @override
  Widget build(BuildContext context) {
    final states = {
      'triage': triageState,
      'extract': extractState,
      'storyline': storylineState,
      'settle': settleState,
    };
    final caption = muted ? null : captionFor(states);

    final bar = SizedBox(
      width: trackWidth,
      height: trackHeight,
      child: Row(
        children: [
          for (final stage in stages) ...[
            if (stage != stages.first) const SizedBox(width: segmentGap),
            Expanded(child: _segment(stage, states[stage] ?? 'pending')),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        muted ? Opacity(opacity: mutedOpacity, child: bar) : bar,
        if (caption != null) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(
            caption,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// One segment. Implicit animations only, both finite: the colour crosses
  /// when a stage changes state, and the fill grows to whatever [fillFor] says
  /// it should be — and then stops.
  Widget _segment(String stage, String state) {
    final look = fillFor(state);
    return AnimatedContainer(
      key: segmentKey(stage),
      duration: fillDuration,
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: look.track,
        borderRadius: BondRadii.fullAll,
        border: isSkipped(state)
            ? Border.all(color: BondColors.border)
            : null,
      ),
      child: AnimatedFractionallySizedBox(
        duration: fillDuration,
        curve: Curves.easeOut,
        alignment: Alignment.centerLeft,
        widthFactor: look.factor,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: look.fill,
            borderRadius: BondRadii.fullAll,
          ),
        ),
      ),
    );
  }
}
