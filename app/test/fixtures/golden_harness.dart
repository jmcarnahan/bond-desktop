import 'dart:io';

import 'package:bond_inbox/services/clustering_card.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
// `show`: the two things this file wants from the storyline service are the
// charter clamp the app ships and the grouping mode a define can pick, so a
// harness default cannot drift from either.
import 'package:bond_inbox/services/storyline_service.dart'
    show GroupingMode, StorylineTuning;

import 'bench_stats.dart';
import 'golden_prices.dart';
import 'golden_run.dart';
import 'golden_set.dart';

/// Everything a golden replay does that is not a model call.
///
/// The live test is `@Skip`'d and needs both a server and a set this repo does
/// not carry, so nothing inside it can be covered by the gate. What CAN be
/// covered is every decision it makes around the calls: how a result becomes a
/// run-file section, how the needs-you verdict is derived, what a run cost and
/// how fast it went. Those live here, pure, and `golden_harness_test.dart`
/// pins them offline — which leaves the live file holding only the parts that
/// genuinely require a model.

/// The defines a golden replay reads.
///
/// Read in ONE place so the live test and the offline tests cannot disagree
/// about a default: a `GOLDEN_CTX` that defaulted to `tail3` here and to
/// something else in the test would let a green suite describe a run nobody
/// performed.
class GoldenDefines {
  /// The set to replay. Empty means nobody passed one — a bare `flutter test`
  /// rather than `make golden`, which the live test refuses rather than
  /// silently scoring nothing.
  static const String setPath = String.fromEnvironment('GOLDEN_SET');

  /// The inbox owner as the app knows them. The set carries no owner line —
  /// it is a fact about the machine, not about the messages — so needs-you
  /// reads it from here.
  static const String ownerNameRaw = String.fromEnvironment('GOLDEN_OWNER_NAME');
  static const String ownerAddressRaw =
      String.fromEnvironment('GOLDEN_OWNER_ADDRESS');

  /// How many items are in flight at once.
  static const int k = int.fromEnvironment('GOLDEN_K', defaultValue: 1);

  /// Which context rung the message text and needs-you are shown, by name.
  /// Parsed by `parseGoldenCtx`, which refuses anything that is not a rung.
  /// (Extraction's own axis, `GOLDEN_EXTRACT_CTX`, went with the extraction
  /// call: the text stage reads the tail the retired triage call read.)
  static const String ctxRaw =
      String.fromEnvironment('GOLDEN_CTX', defaultValue: 'tail3');

  /// The gold storyline registry — the thirty efforts a storyline replay files
  /// candidates into, and the anti-storylines it must not. Machine-local like
  /// the set, and empty for the same reason: a bare `flutter test` passed
  /// nobody a path.
  static const String registryPath = String.fromEnvironment('GOLDEN_REGISTRY');

  /// The bulk run file whose extraction topics and triage summary build each
  /// candidate card — the app's card carries the newest inbound message's
  /// extraction and summary, so a replay without them would judge a thinner
  /// card than the app sends.
  static const String runPath = String.fromEnvironment('GOLDEN_RUN');

  /// How much of a storyline's charter the confirm reads, in characters. The
  /// default IS the app's own `StorylineTuning.charterCap`, read off it rather
  /// than copied, so a replay nobody passed a define to measures the clamp the
  /// app ships. The define exists so one set of cards can be replayed at
  /// several caps.
  static const int charterCap = int.fromEnvironment(
    'GOLDEN_CHARTER_CAP',
    defaultValue: StorylineTuning.charterCap,
  );

  /// Which clustering card the sweep replay embeds, by name. Parsed by
  /// `parseClusteringCardVariant`, which refuses anything that is not one of
  /// the five variants.
  ///
  /// The default follows the app, like every other define here: a replay
  /// nobody passed a card to measures the card the app writes.
  static const String sweepCardRaw =
      String.fromEnvironment('SWEEP_CARD', defaultValue: 'topics');

  /// How much of the sweep replay runs: `vector` stops after the seeding and
  /// reads the clustering vector alone, `full` is the whole filing path, and
  /// `declared` skips the clustering entirely and recruits into storylines
  /// declared from the registry. Parsed by [parseSweepStage], which refuses
  /// anything else.
  ///
  /// One test body and one seeding serve all three, which is what keeps the
  /// readings of one mailbox from drifting apart. `full` is the default
  /// because it is what `make golden-sweep` has always run.
  static const String sweepStageRaw =
      String.fromEnvironment('SWEEP_STAGE', defaultValue: 'full');

  /// Which pass decides what goes together on a sweep replay: `cosine`,
  /// `model` or `pool`. Parsed by [parseSweepGrouping], which refuses
  /// anything else.
  ///
  /// A define rather than a `sed` of `StorylineTuning.groupingMode`, for the
  /// reason every other knob here is one: a row has to name the mode it was
  /// taken under, and a constant edited for one run and forgotten is how two
  /// rows from different trees end up in one table. The default follows the
  /// app, so a run nobody passed a mode to measures the mode that ships.
  static const String sweepGroupingRaw =
      String.fromEnvironment('SWEEP_GROUPING', defaultValue: 'cosine');

  /// The instruction the embedding model is given about what a card is FOR,
  /// verbatim — a trailing space included, which is why nothing here trims it.
  ///
  /// Three readings, resolved by [sweepEmbedPrefix]: empty means nobody passed
  /// one and the app's own `EmbeddingsClient.clusteringPrefix` is used; the
  /// literal `none` means the card goes to the server bare; anything else is
  /// sent as typed. Candidate embedding models document their own wording, and
  /// a model asked in the wrong one measures the wrong thing.
  static const String sweepEmbedPrefixRaw =
      String.fromEnvironment('SWEEP_EMBED_PREFIX', defaultValue: '');

  /// [sweepEmbedPrefixRaw] as the seeding sends it. Never printed: a run
  /// prints its LENGTH, which is what shows a trailing space the shell ate.
  static String get sweepEmbedPrefix =>
      resolveEmbedPrefix(sweepEmbedPrefixRaw);

  /// The owner's name, or null when the define is empty or only whitespace.
  /// Null and not the empty string: `NeedsYouInput` takes a `String?` and
  /// omits the owner line entirely for null, which is the honest rendering of
  /// "this machine did not say who the owner is".
  static String? get ownerName =>
      ownerNameRaw.trim().isEmpty ? null : ownerNameRaw.trim();

  static String? get ownerAddress =>
      ownerAddressRaw.trim().isEmpty ? null : ownerAddressRaw.trim();

  /// The decision model's owner line value, `name <address>` — the form the
  /// heads were trained on — or null unless BOTH defines are set. Not
  /// `decisionOwnerString`'s fallback to whichever half is known: the golden
  /// row of record was taken with the full form, and a half-owner run would
  /// be a different measurement quietly scored against it.
  static String? get decisionOwner => ownerName == null || ownerAddress == null
      ? null
      : '$ownerName <$ownerAddress>';
}

// ── the decision model on the golden set ─────────────────────────────

/// The state the decision model reads for one golden item, from the item's
/// raw `stage_input` — jev-prototype's `distill/state.py` `golden_states`,
/// the WITH-tail half: `now`, `directness_line`, `message_block` and
/// `ctx_tail3.thread_tail` exactly as the packer wrote them, through the same
/// composer the app's raw-field renderer calls. No cap and no strip here,
/// because `render_state` applied none — the packer already had.
///
/// From the raw map rather than a [GoldenItem]: the item keeps `now` as a
/// parsed date and the tail as rebuilt messages, and a round trip through
/// either is a second renderer that could drift from the bytes the heads were
/// scored on.
String goldenDecisionState(
  Map<String, dynamic> stageInput, {
  String? owner,
}) {
  String text(Object? v) => v is String ? v : '';
  final ctx = stageInput['ctx_tail3'];
  final tail = ctx is Map ? ctx['thread_tail'] : null;
  return renderDecisionStateFromParts(
    owner: owner,
    now: text(stageInput['now']),
    directnessLine: text(stageInput['directness_line']),
    messageBlock: text(stageInput['message_block']),
    tail: [
      if (tail is List)
        for (final t in tail)
          if (t is Map)
            // `t.get('who') or ''`, `t.get('text') or ''`.
            DecisionTailItem(who: text(t['who']), text: text(t['text'])),
    ],
  );
}

/// The heads file a decision leg applies: `DECIDE_HEADS` (the Makefile
/// passes `$(DECIDE_DIR)/$(DECIDE_HEADS)`), else where `make decide-install`
/// puts it.
String decideHeadsPath() {
  const defined = String.fromEnvironment('DECIDE_HEADS');
  if (defined.isNotEmpty) return defined;
  final home = Platform.environment['HOME'] ?? '';
  return '$home/Library/Application Support/com.bondinbox.app/models/'
      'local_bond-decide/decide-heads.json';
}

/// Which gate rule a decision run file records.
enum DecisionGateRule {
  /// The app's `learnedGateReason`: drop when `p(drop) >= 0.70` and the drop
  /// reason is not `cold_outreach` (a human writing to the owner stays kept),
  /// with the reason mapped to the app's gate word (R5-1).
  policy,

  /// The row of record's: the gate head's argmax and the drop-reason head's
  /// raw argmax — jev-prototype's `golden_run.run_entry`, which is what the
  /// plan's §1 numbers were scored from.
  argmax,
}

/// The needs-you confidence word from the head's top probability — the row
/// of record's `confidence_word(max(p, 1 - p))`.
String decisionConfidenceWord(double pYes) {
  final top = pYes >= 1 - pYes ? pYes : 1 - pYes;
  return top >= 0.85
      ? 'high'
      : top >= 0.65
          ? 'medium'
          : 'low';
}

/// One item's decision answers, as the run file records them.
///
/// needs_you is `p(yes) >= 0.5` in BOTH rules: that is the row of record's
/// verdict. The app's own reading is banded (yes at 0.65, no below 0.35,
/// the generative model in between — D6), which a run file of one model's
/// answers cannot express; the band's size is what the agreement leg counts.
GoldenClassifierOut classifierOut(
  DecisionAnswers a, {
  required DecisionGateRule rule,
  bool truncated = false,
}) {
  final pDrop = a.p('gate', 'drop');
  final dropReason = a['drop_reason'].choice;
  final String verdict;
  final String? reason;
  switch (rule) {
    case DecisionGateRule.policy:
      // The app's own rule, called rather than restated.
      reason = learnedGateReason(a);
      verdict = reason == null ? 'keep' : 'drop';
    case DecisionGateRule.argmax:
      verdict = a['gate'].choice;
      reason = verdict == 'drop' ? dropReason : null;
  }
  final pNeedsYou = a.p('needs_you', 'yes');
  return GoldenClassifierOut(
    gateVerdict: verdict,
    gateReason: reason,
    category: a['category'].choice,
    urgency: a['urgency'].choice,
    needsAction: a.p('needs_action', 'yes') >= DecisionPolicy.booleanYes,
    replyExpected: a.p('reply_expected', 'yes') >= DecisionPolicy.replyYes,
    needsYouVerdict: pNeedsYou >= 0.5,
    needsYouConfidence: decisionConfidenceWord(pNeedsYou),
    intent: a['intent'].choice,
    importance: a['importance'].choice,
    probabilities: {
      'gate_drop': pDrop,
      'drop_reason': dropReason,
      'needs_you_yes': pNeedsYou,
      'needs_action_yes': a.p('needs_action', 'yes'),
      'reply_expected_yes': a.p('reply_expected', 'yes'),
      'truncated': truncated,
    },
  );
}

/// `SWEEP_EMBED_PREFIX`'s three readings, apart from the define so they can be
/// pinned without one.
///
/// Empty is "nobody passed one" and means the app's own prefix; the literal
/// `none` is somebody asking for no prefix at all, which is a real candidate
/// and not the same thing; anything else is sent verbatim, whitespace
/// included, because a model's documented wording often ends in a space or a
/// newline and losing it is a different request.
String resolveEmbedPrefix(String raw) => switch (raw) {
      '' => EmbeddingsClient.clusteringPrefix,
      'none' => '',
      final prefix => prefix,
    };

/// Which clustering card `SWEEP_CARD` names.
///
/// A delegation and not a second table: the app owns the variant list, and a
/// bench that kept its own copy could offer a card the app cannot build.
ClusteringCardVariant parseSweepCard(String raw) =>
    parseClusteringCardVariant(raw);

/// How much of the sweep replay one run performs.
enum SweepStage {
  /// Seed the mailbox, read the vector, stop. No chat model is dialled at all,
  /// so the whole run is the embeddings plus arithmetic.
  vector,

  /// The whole filing path: clustering, naming, confirms and the assign
  /// shortlist.
  full,

  /// Every registry storyline declared by hand, then recruit. No clustering
  /// and no naming call: what the recruit can do from a charter a person
  /// wrote, which is the ceiling the sweep is measured against.
  declared,
}

/// The stage `SWEEP_STAGE` names, or a thrown [ArgumentError].
///
/// Loud rather than defaulted, for [parseSweepCard]'s reason and one of its
/// own: the two stages write DIFFERENT result files, and a typo that quietly
/// ran the full sweep would spend ninety minutes and three servers on a
/// question somebody asked of one.
SweepStage parseSweepStage(String raw) => switch (raw.trim().toLowerCase()) {
      'vector' => SweepStage.vector,
      'full' => SweepStage.full,
      'declared' => SweepStage.declared,
      _ => throw ArgumentError.value(
          raw,
          'SWEEP_STAGE',
          'must be one of vector, full, declared',
        ),
    };

/// The grouping mode `SWEEP_GROUPING` names, or a thrown [ArgumentError].
///
/// Loud rather than defaulted, for [parseSweepStage]'s reason: the three modes
/// are three different experiments, they cost three different numbers of prose
/// calls, and a typo that quietly ran the shipped one would record a row
/// against a question nobody asked.
GroupingMode parseSweepGrouping(String raw) =>
    switch (raw.trim().toLowerCase()) {
      'cosine' => GroupingMode.cosine,
      'model' => GroupingMode.model,
      'pool' => GroupingMode.pool,
      _ => throw ArgumentError.value(
          raw,
          'SWEEP_GROUPING',
          'must be one of cosine, model, pool',
        ),
    };

/// [k] if it names a concurrency, or a thrown [ArgumentError].
///
/// Separate from [GoldenDefines] so the validation is testable without
/// defines, and loud rather than clamped for `parseDrainK`'s reason: a `K` is
/// typed by hand on a command line, and a `GOLDEN_K=0` that quietly became 1
/// would produce a run that measured a concurrency nobody asked for.
int checkK(int k) {
  if (k < 1) {
    throw ArgumentError.value(k, 'GOLDEN_K', 'must be a positive integer');
  }
  return k;
}

/// [cap] if it names a charter clamp, or a thrown [ArgumentError]. Loud rather
/// than clamped for [checkK]'s reason: a cap of zero would send the confirm a
/// storyline with no description at all and record the result as a measurement
/// of the cap somebody typed.
int checkCharterCap(int cap) {
  if (cap < 1) {
    throw ArgumentError.value(
      cap,
      'GOLDEN_CHARTER_CAP',
      'must be a positive integer',
    );
  }
  return cap;
}

/// The message-text stage's answer, as the run file records it. A straight
/// copy: the scorer reads these fields by name, so anything clever here would
/// be scoring a transformation rather than the model. `deadline` needs no null
/// guard because `MessageTextTask.validate` already clamps it to a string —
/// the empty one meaning "this message named no deadline", which is an answer.
GoldenTextOut textOut(MessageTextResult r) => GoldenTextOut(
      summary: r.summary,
      actionItems: r.actionItems,
      deadline: r.deadline,
      topics: r.topics,
      project: r.project,
    );

/// The needs-you answer the app's ladder settles from the decision model
/// alone, or null when p(yes) sits in the band and the generative model is
/// asked (`NeedsYouHandler`, D6): yes at [DecisionPolicy.needsYouYes] and
/// above, no below [DecisionPolicy.needsYouNo]. The confidence word is the
/// head's, as the decision leg records it, and the evidence is the app's own
/// TEMPLATED `needs_you_reason` ([needsYouYesReason] / [needsYouNoReason]),
/// so a decided item carries evidence the way the app's row does.
///
/// The ONE bar the replay cannot reproduce is the cold-outreach one
/// ([DecisionPolicy.needsYouYesCold]): the app decides "cold" from the
/// owner's own sender history, which a golden item does not carry, so the
/// replay uses the ordinary bar throughout.
GoldenNeedsYouOut? decidedNeedsYouOut(DecisionAnswers a) {
  final pYes = a.p('needs_you', 'yes');
  if (pYes >= DecisionPolicy.needsYouYes) {
    return GoldenNeedsYouOut(
      verdict: true,
      confidence: decisionConfidenceWord(pYes),
      evidence: needsYouYesReason(a),
    );
  }
  if (pYes < DecisionPolicy.needsYouNo) {
    return GoldenNeedsYouOut(
      verdict: false,
      confidence: decisionConfidenceWord(pYes),
      evidence: needsYouNoReason,
    );
  }
  return null;
}

/// The needs-you answer, as the HANDLER would have written it down.
///
/// Not a straight copy, and deliberately so: the shipping verdict is
/// `needsYou && confidence != 'low'` (`lib/services/needs_you_handler.dart`,
/// the `verdict` local), because a low-confidence yes is a no in this app. A
/// replay that recorded the model's raw boolean would score a pipeline that
/// does not exist. The raw confidence rides along beside the derived verdict
/// so a reader can still see which of the two the model actually said.
GoldenNeedsYouOut needsYouOut(NeedsYouResult r) => GoldenNeedsYouOut(
      verdict: r.needsYou && r.confidence != 'low',
      confidence: r.confidence,
      evidence: r.evidence,
    );

/// The needs-you answer for an item the deterministic floor already settles.
///
/// No confidence, because the floor states none — it is a rule about how a
/// message was addressed, not a judgement — and `floor: true` so a reader can
/// tell the model's recall from the floor's rather than reading one number
/// that mixes them.
GoldenNeedsYouOut floorOut() =>
    const GoldenNeedsYouOut(verdict: true, floor: true);

/// The reply decision, as the run file records it: the decision model's
/// p(reply_expected = yes) against [DecisionPolicy.replyYes] — the bar the
/// draft lane applies before it gathers anything.
GoldenDecisionOut decisionOut(DecisionAnswers answers) {
  final p = answers.p('reply_expected', 'yes');
  return GoldenDecisionOut(needsReply: p >= DecisionPolicy.replyYes, p: p);
}

/// A drafted reply, as the rubric judge reads it.
///
/// The options are flattened to `stance: body` strings because the run file
/// carries them as text for a judge to read, and a stance without its body —
/// or a body without the commitment its stance names — is half an option.
GoldenDraftOut draftOut(DraftResult r) => GoldenDraftOut(
      body: r.replyBody,
      options: [for (final o in r.options) '${o.stance}: ${o.body}'],
      evidence: r.evidence,
    );

/// One call's cost in time and tokens, straight off the client's own record —
/// the same record every table in the bakeoff is built from, so a per-item row
/// and the summary table can never disagree about what a call took.
GoldenCall callOf(LlmCallRecord r) => GoldenCall(
      ms: r.durationMs,
      promptTokens: r.promptTokens,
      completionTokens: r.completionTokens,
      outcome: r.outcome,
    );

/// The `extra` keys a golden result carries that `tool/bench_compare.dart`
/// reads back. Named once here; the tool cannot import a test fixture, so the
/// offline test holds its source to these same literals — a rename on either
/// side would otherwise drop two rows from every future comparison and say
/// nothing.
const String msgsPerMinKey = 'msgs_per_min';
const String costKey = 'cost';
const String per1kKey = 'per_1k_messages_usd';

/// What a run cost, per stage and per thousand messages.
///
/// Built from the collector's own token sums rather than from a per-call
/// walk: the sums are already time-weighted and already exclude failed calls,
/// and a second accumulator over the same records is a second thing to drift.
///
/// [items] is the message count the per-1k figure is scaled from, which is the
/// only unit a person compares two candidates in — dollars per run depends on
/// how much of the set was replayed, dollars per thousand messages does not.
Map<String, Object?> costSummary({
  required List<TaskMetrics> tasks,
  required String url,
  required String model,
  required int items,
}) {
  final perStage = <String, Object?>{};
  var total = 0.0;
  // One unpriced stage poisons the total on purpose. A sum that quietly
  // skipped it would read as the whole run's cost while being a subset's, and
  // an unpriced model would come out looking cheapest in the ledger.
  var priced = true;
  for (final m in tasks) {
    final usd = costFor(
      url: url,
      model: model,
      promptTokens: m.promptTokens,
      completionTokens: m.completionTokens,
    );
    if (usd == null) {
      priced = false;
    } else {
      total += usd;
    }
    perStage[m.task] = {
      'usd': usd,
      'prompt_tokens': m.promptTokens,
      'completion_tokens': m.completionTokens,
    };
  }
  final totalUsd = priced ? total : null;
  return {
    'prices_dated': pricesDated,
    'per_stage': perStage,
    'total_usd': totalUsd,
    per1kKey: totalUsd == null || items == 0 ? null : totalUsd / items * 1000,
  };
}

/// Messages a minute over the WHOLE run, wall clock.
///
/// The throughput a person feels, and the one number that answers "how long
/// would my backlog take" — which tokens per second does not, since it says
/// nothing about how many calls a message costs or how well they overlap. Zero
/// for a zero-length wall rather than an infinity: a run that took no
/// measurable time measured nothing.
double msgsPerMinute(int items, Duration wall) =>
    wall.inMilliseconds <= 0 ? 0 : items * 60000 / wall.inMilliseconds;

/// Runs [call], retrying only the failure that says nothing about the request.
///
/// A cloud server throttles with HTTP 429, which the client maps to
/// [LlmUnavailableException] for the same reason a 503 maps there: the same
/// request succeeds a few seconds later. Without a retry a throttled stage
/// would leave its section out of the run file, and an omitted section reads
/// to the scorer as "not attempted" — a silently smaller denominator rather
/// than a visible failure. Everything else propagates on the first try: a 400
/// is this side's bug, a format failure is the model's answer, and neither is
/// improved by asking again.
///
/// The cost when the server really is down is the backoff and nothing else —
/// the warmup has already failed the run by then.
///
/// [wait] is injectable so the offline test can assert the schedule without
/// sleeping through it; [onRetry] is how a run counts what it had to repeat.
Future<T> retryingUnavailable<T>(
  Future<T> Function() call, {
  int attempts = 4,
  Duration firstDelay = const Duration(seconds: 2),
  Future<void> Function(Duration delay) wait = _sleep,
  void Function()? onRetry,
}) async {
  if (attempts < 1) {
    throw ArgumentError.value(attempts, 'attempts', 'must be at least one');
  }
  var delay = firstDelay;
  for (var attempt = 1;; attempt++) {
    try {
      return await call();
    } on LlmUnavailableException {
      if (attempt >= attempts) rethrow;
      onRetry?.call();
      await wait(delay);
      delay *= 2;
    }
  }
}

Future<void> _sleep(Duration d) => Future<void>.delayed(d);
