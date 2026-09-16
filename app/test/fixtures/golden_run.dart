import 'dart:convert';
import 'dart:io';

import 'bench_report.dart';

/// The run file a golden replay writes, in the shape the scorer reads.
///
/// `golden/tools/score_run.py --run FILE` and `golden/tools/judge_rubrics.py`
/// are the scorers of record; this file's only job is to hand them a JSON
/// ARRAY of per-item objects in exactly the shape their docstrings describe.
/// Nothing here decides whether an answer is right — that would be a second
/// opinion about what "correct" means, which is the one thing a bakeoff must
/// not grow.
///
/// The rule that makes a partial run honest: **an omitted section means "not
/// attempted", not "wrong"**. So every section below is nullable and absent
/// sections are left out of the JSON entirely rather than written as null. The
/// one place that bites is `triage.deadline`, which must be the empty string
/// to claim "this message named no deadline" — a null there reads as a stage
/// that never ran.

/// Triage's answer for one item.
class GoldenTriageOut {
  final String category;
  final String urgency;
  final bool needsAction;
  final bool replyExpected;

  /// The date or timeframe in the sender's own words. Empty string when the
  /// message named none — never null; see the note at the top of this file.
  final String deadline;

  /// The free-text "what is this about" label, judged by rubric, not lexically.
  final String label;
  final String summary;
  final List<String> actionItems;

  const GoldenTriageOut({
    required this.category,
    required this.urgency,
    required this.needsAction,
    required this.replyExpected,
    required this.deadline,
    required this.label,
    required this.summary,
    this.actionItems = const [],
  });
}

/// Extraction's answer for one item.
class GoldenExtractOut {
  final String intent;
  final String importance;
  final String project;
  final List<String> topics;
  final List<String> people;
  final List<String> organizations;
  final String evidence;

  const GoldenExtractOut({
    required this.intent,
    required this.importance,
    required this.project,
    this.topics = const [],
    this.people = const [],
    this.organizations = const [],
    this.evidence = '',
  });
}

/// The needs-you pass's answer for one item.
class GoldenNeedsYouOut {
  final bool verdict;

  /// `low`, `medium`, `high` — or null when the answer came from the
  /// deterministic floor, which states no confidence of its own.
  final String? confidence;
  final String evidence;

  /// Whether the deterministic floor settled it rather than the model. Not
  /// scored; it is how a reader tells a model's recall from the floor's.
  final bool floor;

  const GoldenNeedsYouOut({
    required this.verdict,
    this.confidence,
    this.evidence = '',
    this.floor = false,
  });
}

/// The reply-decision stage's answer for one item.
class GoldenDecisionOut {
  final bool needsReply;
  final String reason;

  const GoldenDecisionOut({required this.needsReply, this.reason = ''});
}

/// A drafted reply, for the rubric judge.
class GoldenDraftOut {
  final String body;
  final List<String> options;
  final String evidence;

  const GoldenDraftOut({
    required this.body,
    this.options = const [],
    this.evidence = '',
  });
}

/// What one model call cost, per stage.
class GoldenCall {
  final int ms;
  final int? promptTokens;
  final int? completionTokens;

  /// `ok`, `unavailable`, `error` or `format` — `LlmCallRecord`'s own words.
  final String outcome;

  const GoldenCall({
    required this.ms,
    this.promptTokens,
    this.completionTokens,
    required this.outcome,
  });

  Map<String, Object?> toJson() => {
        'ms': ms,
        // Null stays null: a runtime that reports no usage must not read
        // downstream as one that spent nothing.
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'outcome': outcome,
      };
}

/// One item's row in a run file.
///
/// Sections are filled in as the stages run, which is why they are mutable:
/// a bulk replay writes triage, needs-you and extraction on the same entry,
/// each in its own `try`, so a stage that throws leaves its section absent
/// and the rest of the row still scores.
///
/// [calls] is keyed by stage — `triage`, `needs_you`, `extraction`,
/// `reply_decision`, `draft_reply`, `storyline_membership` — the same words
/// the tasks use for their labels.
class GoldenRunEntry {
  final String id;

  /// Carried through for whoever READS the run file: the scorer buckets from
  /// the golden set rather than from the entry, so these two are here to make
  /// a row legible on its own, not to be scored.
  final String stratum;
  final String difficulty;

  GoldenTriageOut? triage;
  GoldenExtractOut? extract;
  GoldenNeedsYouOut? needsYou;

  /// The registry slug this run filed the item under, or `'none'` for the
  /// assertion "no storyline". Null means the stage never ran.
  String? storylineId;

  GoldenDecisionOut? decision;
  GoldenDraftOut? draft;

  final Map<String, GoldenCall> calls = {};

  /// Whether any stage was so much as tried on this item.
  ///
  /// The rule for which rows a run file carries: a row that attempted nothing
  /// is not a row (the item was outside the run's population), while a row
  /// whose only stage failed still is — its `calls` say what went wrong, and
  /// the scorer reads its missing sections as "not attempted" either way.
  bool get attempted =>
      calls.isNotEmpty ||
      triage != null ||
      extract != null ||
      needsYou != null ||
      storylineId != null ||
      decision != null ||
      draft != null;

  GoldenRunEntry({
    required this.id,
    required this.stratum,
    required this.difficulty,
  });

  /// This row, in `score_run.py`'s shape.
  ///
  /// One mapping is worth stating plainly, because it looks like a bug and is
  /// not: when a prose run carries a reply DECISION and no triage, this emits
  /// `triage: {reply_expected: …}` carrying the decision's verdict and no
  /// other triage key. The scorer's `triage.reply_expected` field is the
  /// question "is the sender waiting on an answer", which is exactly what the
  /// reply-decision stage answers, and gold has one label for it. So in a
  /// prose run file `triage.reply_expected` IS the reply decision; the
  /// `decision` object beside it carries the same verdict plus the model's
  /// reason, which the scorer ignores and a reader does not.
  Map<String, Object?> toScoreRunJson() => {
        'id': id,
        'stratum': stratum,
        'difficulty': difficulty,
        if (triage != null)
          'triage': {
            'category': triage!.category,
            'urgency': triage!.urgency,
            'needs_action': triage!.needsAction,
            'reply_expected': triage!.replyExpected,
            'deadline': triage!.deadline,
            'label': triage!.label,
            'summary': triage!.summary,
            'action_items': triage!.actionItems,
          }
        else if (decision != null)
          'triage': {'reply_expected': decision!.needsReply},
        if (extract != null)
          'extract': {
            'intent': extract!.intent,
            'importance': extract!.importance,
            'project': extract!.project,
            'topics': extract!.topics,
            'people': extract!.people,
            'organizations': extract!.organizations,
            'evidence': extract!.evidence,
          },
        if (needsYou != null)
          'needs_you': {
            'verdict': needsYou!.verdict,
            // Omitted rather than null when the floor answered: the scorer
            // reads a present confidence as a claim and scores it.
            if (needsYou!.confidence != null) 'confidence': needsYou!.confidence,
            'evidence': needsYou!.evidence,
            'floor': needsYou!.floor,
          },
        if (storylineId != null) 'storyline': {'id': storylineId},
        if (decision != null)
          'decision': {
            'needs_reply': decision!.needsReply,
            'reason': decision!.reason,
          },
        if (draft != null)
          'draft': {
            'body': draft!.body,
            'options': draft!.options,
            'evidence': draft!.evidence,
          },
        if (calls.isNotEmpty)
          'calls': {
            for (final entry in calls.entries) entry.key: entry.value.toJson(),
          },
      };
}

/// Writes a run file and returns its path.
///
/// Named for the label so two candidates never overwrite each other, and
/// stamped so a rerun of the same candidate does not either — the same
/// reasoning, and literally the same [stamp], as `writeBenchResult`. The companion
/// timing and cost JSON is written by the caller through that function, with
/// this path in its `extra`, so a row in the ledger has both halves.
///
/// Never prints what it wrote: a run file holds real message content by
/// design, and this repo is public.
Future<String> writeGoldenRun(
  List<GoldenRunEntry> entries, {
  required String bench,
  required String label,
  required String outDir,
  DateTime? finishedAt,
}) async {
  if (outDir.isEmpty) {
    throw StateError(
      '$bench has nowhere to write its run file — BENCH_OUT is not defined '
      '(the Makefile sets it; a bare `flutter test` does not)',
    );
  }
  await Directory(outDir).create(recursive: true);
  final name = 'golden-run-${slug(label)}'
      '-${stamp((finishedAt ?? DateTime.now()).toUtc())}.json';
  final path = '$outDir${Platform.pathSeparator}$name';
  await File(path).writeAsString(
    const JsonEncoder.withIndent('  ')
        .convert([for (final entry in entries) entry.toScoreRunJson()]),
  );
  return path;
}
