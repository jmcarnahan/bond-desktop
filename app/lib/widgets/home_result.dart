import 'package:flutter/foundation.dart' show immutable;

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'stage_bar.dart';

/// What an Inbox feed row MEANS — the screen's narrator.
///
/// Pure and out of the widget for `ActivityLogPanel.describe`'s reason: every
/// judgement about what a row is saying is worth pinning, and a judgement that
/// needs a pump to test is one nobody writes the awkward cases for. The tile
/// decides what a sentence LOOKS like; what it says is decided here.
///
/// The sentence is now TWO CELLS. [HomeResult.text] is the label — `Needs
/// you`, `Newsletter`, `Filed in <title>` — and [HomeResult.detail] is the
/// reason clause that used to hang off it after a dash. They split because the
/// table gained an Ask · Summary column: the reason is worth as much as it ever
/// was, but a reader scanning a column of verdicts should be able to scan the
/// VERDICTS, and the words belong beside the thread's own ask rather than
/// crammed into a two-flex cell that ellipsised them. The whole sentence still
/// exists — it is [HomeResult.tooltip], and it is what a hover gets.

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

/// One row's verdict, its reason, and everything the tile needs to dress it.
@immutable
class HomeResult {
  final HomeResultKind kind;

  /// The LABEL — short enough to read at a glance down a column of them, and
  /// short enough that the Result cell never has to ellipsise it.
  final String text;

  /// The reason clause, or null when the label is the whole of it.
  ///
  /// This is what the Ask · Summary column falls back to on a row with no ask
  /// and no summary of its own: a message the gate filtered has no triage
  /// summary to show, and "sender muted" is exactly what the reader wants in
  /// that space.
  final String? detail;

  /// The whole sentence, both cells joined, for the tooltip. Never null: with
  /// no [detail] it is [text].
  ///
  /// A getter over a stored override rather than a field composed in the
  /// initializer list, because a const constructor cannot interpolate its own
  /// parameters — and this class is built once per row per rebuild.
  String get tooltip =>
      _override ?? (detail == null ? text : '$text — $detail');

  /// Set only where the composed sentence is not the whole story — see the
  /// drop in [resultLine], which prefixes its own.
  final String? _override;

  final BondTone tone;

  /// True when the row can be retried (stalled or errored, not dropped).
  final bool retryable;

  /// [tooltip] is composed rather than passed at every call site, because the
  /// one way two cells and their hover come to disagree is by being written
  /// out twice. The drop is the only caller that overrides it, and only to
  /// keep its `Dropped: ` prefix.
  const HomeResult(
    this.kind,
    this.text, {
    this.detail,
    String? tooltip,
    required this.tone,
    this.retryable = false,
  }) : _override = tooltip;
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
    final text = homeDropLabel(reason);
    final detail = switch (reason) {
      'not_worthy' => _notWorthyReason(row),
      'gated' when gate.isNotEmpty => gate.replaceAll('_', ' '),
      _ => null,
    };
    return HomeResult(
      HomeResultKind.dropped,
      text,
      detail: detail,
      // The one composed tooltip: the prefix is what tells a hover that the
      // label is a drop rather than a stage, and the label alone does not say
      // so — "Newsletter" is a description, "Dropped: Newsletter" is a verdict.
      tooltip: 'Dropped: ${detail == null ? text : '$text — $detail'}',
      tone: BondTone.neutral,
    );
  }

  final errored = _erroredStage(states);
  if (errored != null) {
    return HomeResult(
      HomeResultKind.error,
      'Failed at $errored',
      detail: 'The $errored stage ended in an error.',
      tone: BondTone.error,
      retryable: true,
    );
  }

  if (row.isStalled(now)) {
    final stage = _openStage(states);
    return HomeResult(
      HomeResultKind.stalled,
      'Stalled',
      // The stage moves out of the label and into the clause: every stalled row
      // says the same word in the Result column, and WHICH stage it is stuck
      // behind is the reason rather than the verdict.
      detail: 'No progress for ${homeStalledAfter.inMinutes} minutes and '
          'nothing is queued — waiting on $stage.',
      tone: BondTone.error,
      retryable: true,
    );
  }

  if (row.outcome == 'pending') {
    final caption = HomeStageBar.captionFor(states);
    if (caption != null) {
      // No reason clause on a stage that is RUNNING: the label already says
      // what is happening, and "not queued yet" beside "Extracting…" would be
      // the row contradicting itself in one line. It cannot arise off real
      // columns either — a running stage IS an open work row, or a
      // `triage_status` of `processing`, and `work_open` counts both.
      return HomeResult(
        HomeResultKind.inFlight,
        caption[0].toUpperCase() + caption.substring(1),
        tone: BondTone.primary,
      );
    }
    return HomeResult(
      HomeResultKind.inFlight,
      'Waiting on ${_openStage(states)}',
      // Nothing on a queue means the row is waiting on the next sync pass
      // rather than on the pipeline, which is a different kind of wait.
      detail: row.workOpen ? null : 'Not queued yet',
      tone: BondTone.primary,
    );
  }

  if (row.needsYou) {
    return HomeResult(
      HomeResultKind.needsYou,
      'Needs you',
      detail: _needsYouReasonText(row.needsYouReason),
      tone: row.urgency == 'urgent' ? BondTone.error : BondTone.attention,
    );
  }

  final title = row.storylineTitle;
  if (row.storylineId != null && (title?.isNotEmpty ?? false)) {
    return HomeResult(
      HomeResultKind.filed,
      'Filed in $title',
      detail: homeFiledEvidence(row),
      tone: BondTone.success,
    );
  }

  if (row.bucket == 'later') {
    final reason = row.bucketReason;
    return HomeResult(
      HomeResultKind.later,
      'Later',
      detail: _laterReasons[reason] ?? reason ?? 'deferred',
      tone: BondTone.neutral,
    );
  }

  if (row.draftState == 'done') {
    return HomeResult(
      HomeResultKind.draftReady,
      'Draft ready',
      tone: BondTone.success,
    );
  }

  // The judge's own words when it has any: "nothing to do" is a verdict, and a
  // verdict a reader cannot see the reason for is one they cannot disagree
  // with. Only under a recorded NO — the reason column can hold a stale
  // sentence from a verdict that was never re-run.
  final verdictReason = row.needsYouReason?.trim() ?? '';
  return HomeResult(
    HomeResultKind.nothing,
    'Nothing to do',
    detail: row.needsYouVerdict == false && verdictReason.isNotEmpty
        ? verdictReason
        : null,
    tone: BondTone.neutral,
  );
}

/// What a row SAYS, as opposed to what the app decided about it: the thread's
/// ask, or the message's summary.
///
/// A record rather than two returns because the flag changes how the cell is
/// drawn — an ask is the reader's work and is set in [FontWeight.w600], a
/// summary is context and is quiet — and a caller that had to re-derive which
/// it was holding would eventually derive it differently.
typedef HomeAsk = ({String text, bool ask});

/// The Ask · Summary cell's words.
///
/// An ask is per THREAD and a summary is per MESSAGE, which is the whole reason
/// they are two columns in the store and one column on screen: a needs-you row
/// is asking for something from the reader, and what the message happened to be
/// about is the smaller fact. Everything else shows the summary, because a row
/// nobody is being asked anything by is a row the reader is only scanning.
///
/// The reason clause is what a row says when it has neither. A message the gate
/// threw out never reached triage, so it has no summary at all — and "sender
/// muted" in that space is worth more than a blank.
HomeAsk askLine(HomeFeedRow row, HomeResult result) {
  if (row.needsYou && !row.dropped) {
    final cta = row.ctaText?.trim() ?? '';
    if (cta.isNotEmpty) return (text: cta, ask: true);
    final reason = row.needsYouReason?.trim() ?? '';
    if (reason.isNotEmpty) return (text: reason, ask: true);
    return (text: result.detail ?? '', ask: true);
  }
  final summary = row.summary?.trim() ?? '';
  if (summary.isNotEmpty) return (text: summary, ask: false);
  return (text: result.detail ?? '', ask: false);
}
