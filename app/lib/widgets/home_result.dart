import 'package:flutter/foundation.dart' show immutable;

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'stage_bar.dart';

/// What a home feed row MEANS, in one sentence — the screen's narrator.
///
/// Pure and out of the widget for `ActivityLogPanel.describe`'s reason: every
/// judgement about what a row is saying is worth pinning, and a judgement that
/// needs a pump to test is one nobody writes the awkward cases for. The tile
/// decides what a sentence LOOKS like; what it says is decided here.
///
/// The whole point of the sentence is the REASON. "Dropped" tells a reader the
/// app did something; "Filtered — sender muted" tells them what to do about
/// it, and the columns behind that clause are already on the row.

/// The machine-readable drop reasons in the words a person would use.
///
/// Anything unmapped falls back to the raw reason with its underscores opened
/// up — a reason a newer build introduced reads awkwardly rather than
/// rendering an empty cell.
const Map<String, String> homeDropLabels = {
  'fyi': 'FYI',
  'newsletter': 'Newsletter',
  'auto_generated': 'Automated',
  'no_reply': 'No reply needed',
  'not_worthy': 'Nothing to do',
  'outbound': 'Outbound',
  'self': 'Your own',
  'empty': 'Empty',
  'backlog': 'Backlog',
  'gated': 'Filtered',
  'user': 'Ignored',
};

/// [homeDropLabels] with its fallbacks. A drop with no reason on it is still a
/// drop, so the absent case is a word rather than a blank.
String homeDropLabel(String? reason) {
  if (reason == null || reason.isEmpty) return 'Dropped';
  return homeDropLabels[reason] ?? reason.replaceAll('_', ' ');
}

/// Which of the row's stories the sentence tells. The widget reads it to
/// decide what else to draw (a storyline link, a Retry link); the sentence
/// itself is [HomeResult.text].
enum HomeResultKind {
  stalled,
  error,
  dropped,
  inFlight,
  needsYou,
  filed,
  later,
  draftReady,
  nothing,
}

/// One row's sentence, and everything the tile needs to dress it.
@immutable
class HomeResult {
  final HomeResultKind kind;

  /// One line, ellipsised by the widget.
  final String text;

  /// The full sentence for the tooltip. Never null: at minimum it is [text].
  final String tooltip;

  final BondTone tone;

  /// True when the row can be retried (stalled or errored, not dropped).
  final bool retryable;

  const HomeResult(
    this.kind,
    this.text, {
    required this.tooltip,
    required this.tone,
    this.retryable = false,
  });
}

/// The stage states a row is FINISHED with. Everything else is still owed,
/// which is what makes "waiting on extract" a fact rather than a guess.
const Set<String> _terminalStates = {'done', 'skipped', 'error'};

/// The earliest stage the row has not finished, in pipeline order.
///
/// Falls back to the last stage rather than to null: a row that is somehow
/// pending with every stage terminal is still waiting on the thing that ends
/// it, and a sentence with a hole in it helps nobody.
String _openStage(Map<String, String> states) {
  for (final stage in HomeStageBar.stages) {
    if (!_terminalStates.contains(states[stage] ?? 'pending')) return stage;
  }
  return 'settle';
}

/// The first stage that ended in an error, or null when none did. First and
/// not last, because the earliest failure is the one the rest went wrong
/// behind.
String? _erroredStage(Map<String, String> states) {
  for (final stage in HomeStageBar.stages) {
    if (states[stage] == 'error') return stage;
  }
  return null;
}

/// The stage the caption is about. `HomeStageBar.captionFor` names the first
/// RUNNING stage, which is not always the earliest one still owed — a triage
/// left pending while extraction runs would otherwise get a tooltip naming a
/// stage the caption never mentioned.
String _captionStage(Map<String, String> states) {
  for (final stage in HomeStageBar.stages) {
    if (states[stage] == 'running') return stage;
  }
  return _openStage(states);
}

/// The needs-you verdict's reason in a reader's words.
///
/// The model writes prose here and the connectors write a token or two, so
/// only the tokens are translated and everything else is passed through as
/// written — paraphrasing a judge's own sentence would be the app putting
/// words in its own mouth.
String _needsYouReasonText(String? reason) {
  final text = reason?.trim() ?? '';
  if (text.isEmpty) return 'the app thinks this wants you';
  if (text == 'teams_direct') return 'a direct Teams message';
  return text;
}

/// Why the attention sweep set a thread aside, in words.
const Map<String, String> _laterReasons = {
  'low_value': 'low value',
  'user': 'you deferred it',
  'sender_pref': 'sender rule',
};

/// Why a settled message was judged not worth the owner's attention.
///
/// `not_worthy` is the notify sweep's word for "the predicate said no", and
/// the predicate has more than one clause. When the verdict itself was a no,
/// the judge's reason is the answer. When the verdict was a YES the message
/// was set aside for a different reason — the thread sits in Later, or its
/// attention score fell under the threshold — and quoting a reason that says
/// "this wants you" under "Nothing to do" would be the app contradicting
/// itself in one line.
String _notWorthyReason(HomeFeedRow row) {
  final reason = row.needsYouReason?.trim() ?? '';
  return switch (row.needsYouVerdict) {
    false when reason.isNotEmpty => reason,
    true when row.bucket == 'later' => 'the thread is in Later',
    true => 'below the attention threshold',
    _ => 'no ask found',
  };
}

/// What the row says about HOW it came to be filed, or null when it has
/// nothing to add.
///
/// A person's filing is named as one: "the model saw a shared thread" and "you
/// said so" are different kinds of fact, and only the second is beyond
/// argument.
String? homeFiledEvidence(HomeFeedRow row) {
  if (row.storylineAddedBy == 'user') return 'filed by you';
  final evidence = row.storylineEvidence?.trim();
  return (evidence == null || evidence.isEmpty) ? null : evidence;
}

/// What happened to this message, in one sentence, with the reason.
///
/// Pure and static: every judgement about what a row MEANS lives here. [now]
/// is a parameter and never the clock, so the stalled threshold is pinnable.
///
/// The order is a priority and the FIRST match wins.
///
/// A dropped row shows the drop and nothing else — not the ask, for the
/// reason `home_feed_row.dart` has always given (a "Needs You" beside
/// "Newsletter" is the app arguing with itself), and not a failure either:
/// `PipelineRepairService` refuses a dropped row, so a "Failed at" with a
/// Retry on it would be a button that does nothing. Restore is that row's
/// lever, and the drop is the sentence that points at it.
///
/// A failure outranks a stall. A row that errored and then sat is stuck
/// BECAUSE it errored, and "waiting on storyline" would hide the one fact the
/// reader needs; both sentences carry the same Retry.
HomeResult resultLine(HomeFeedRow row, {required DateTime now}) {
  final states = HomeStageBar.statesOf(row);

  if (row.dropped) {
    final reason = row.dropReason;
    final gate = row.gateReason?.trim() ?? '';
    final text = switch (reason) {
      'not_worthy' => 'Nothing to do — ${_notWorthyReason(row)}',
      'gated' when gate.isNotEmpty =>
        'Filtered — ${gate.replaceAll('_', ' ')}',
      _ => homeDropLabel(reason),
    };
    return HomeResult(
      HomeResultKind.dropped,
      text,
      tooltip: 'Dropped: $text',
      tone: BondTone.neutral,
    );
  }

  final errored = _erroredStage(states);
  if (errored != null) {
    return HomeResult(
      HomeResultKind.error,
      'Failed at $errored',
      tooltip: 'The $errored stage ended in an error. Retry runs it again.',
      tone: BondTone.error,
      retryable: true,
    );
  }

  if (row.isStalled(now)) {
    final stage = _openStage(states);
    return HomeResult(
      HomeResultKind.stalled,
      'Stalled — waiting on $stage',
      tooltip: 'No progress for ${homeStalledAfter.inMinutes} minutes and '
          'nothing is queued. Retry puts the owed stages back on their '
          'queues.',
      tone: BondTone.error,
      retryable: true,
    );
  }

  if (row.outcome == 'pending') {
    final caption = HomeStageBar.captionFor(states);
    if (caption != null) {
      final stage = _captionStage(states);
      return HomeResult(
        HomeResultKind.inFlight,
        caption[0].toUpperCase() + caption.substring(1),
        tooltip: 'The $stage stage is running.',
        tone: BondTone.primary,
      );
    }
    final stage = _openStage(states);
    return HomeResult(
      HomeResultKind.inFlight,
      row.workOpen
          ? 'Waiting on $stage'
          : 'Waiting on $stage — not queued yet',
      tooltip: row.workOpen
          ? 'Queued behind other work.'
          : 'Nothing is queued for this yet; the next sync pass queues it.',
      tone: BondTone.primary,
    );
  }

  if (row.needsYou) {
    final text = 'Needs you — ${_needsYouReasonText(row.needsYouReason)}';
    return HomeResult(
      HomeResultKind.needsYou,
      text,
      tooltip: text,
      tone: row.urgency == 'urgent' ? BondTone.error : BondTone.attention,
    );
  }

  final title = row.storylineTitle;
  if (row.storylineId != null && (title?.isNotEmpty ?? false)) {
    final evidence = homeFiledEvidence(row);
    final text =
        'Filed in $title${evidence == null ? '' : ' — $evidence'}';
    return HomeResult(
      HomeResultKind.filed,
      text,
      tooltip: text,
      tone: BondTone.success,
    );
  }

  if (row.bucket == 'later') {
    final reason = row.bucketReason;
    final why = _laterReasons[reason] ?? reason ?? 'deferred';
    final text = 'Later — $why';
    return HomeResult(
      HomeResultKind.later,
      text,
      tooltip: text,
      tone: BondTone.neutral,
    );
  }

  if (row.draftState == 'done') {
    return const HomeResult(
      HomeResultKind.draftReady,
      'Draft ready',
      tooltip: 'Draft ready',
      tone: BondTone.success,
    );
  }

  // The judge's own words when it has any: "nothing to do" is a verdict, and a
  // verdict a reader cannot see the reason for is one they cannot disagree
  // with.
  final verdictReason = row.needsYouReason?.trim() ?? '';
  return HomeResult(
    HomeResultKind.nothing,
    'Nothing to do',
    tooltip: row.needsYouVerdict == false && verdictReason.isNotEmpty
        ? 'Nothing to do — $verdictReason'
        : 'Nothing to do',
    tone: BondTone.neutral,
  );
}
