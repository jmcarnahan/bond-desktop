import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/conversation_state.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';

import 'golden_json.dart';
import 'golden_run.dart';
import 'golden_set.dart';

/// Everything the storyline replay does that is not a model call.
///
/// Same split as `golden_harness.dart`, for the same reason: the live test is
/// `@Skip`'d and needs a server, a set and a registry this repo does not carry,
/// so nothing inside it can be covered by the gate. What CAN be covered is
/// every decision it makes around the calls — how a candidate card is built,
/// which answers count as an accept, which storyline a set of answers derives,
/// and what the whole thing tallied. Those live here, pure, and
/// `golden_storyline_test.dart` pins them offline.
///
/// Nothing here scores anything. The derived `storyline.id` goes into a run
/// file and `golden/tools/score_run.py` applies the must/should/may/forbidden
/// rules to it; the tallies below are the replay's own arithmetic about its own
/// answers, which is a different question from "was it right".

// ── the cards a candidate is judged as ─────────────────────────────────

/// The two enriched fields of one item's card, out of a bulk run file.
class GoldenCard {
  final List<String> topics;
  final String? summary;

  const GoldenCard({required this.topics, required this.summary});
}

/// A bulk run file, read for nothing but its cards.
class GoldenCards {
  final Map<String, GoldenCard> byId;

  const GoldenCards(this.byId);

  int get size => byId.length;

  /// The topics and summary of every entry that carries either.
  ///
  /// An entry with neither is skipped rather than stored empty: the run prints
  /// how many items got a card from the file, and an entry that contributed
  /// nothing must not inflate that count. A non-string topic is dropped the
  /// way `topicsOfExtraction` in `lib/services/clustering_card.dart` drops one
  /// — a
  /// card is text, and a number in the list would be text the app never sent.
  static GoldenCards fromRunJson(List<dynamic> entries) {
    final byId = <String, GoldenCard>{};
    for (final raw in entries) {
      final entry = asMap(raw);
      final id = asString(entry['id']);
      if (id.isEmpty) continue;

      final topics = <String>[];
      for (final topic in asList(asMap(entry['extract'])['topics'])) {
        if (topic is String && topic.isNotEmpty) topics.add(topic);
      }

      // An empty or whitespace-only summary is NO summary, not a short one:
      // it puts nothing in the card's fourth segment, so an entry whose only
      // content is `""` must not be counted among the items the run file
      // carded.
      final rawSummary = asMap(entry['triage'])['summary'];
      final summary = rawSummary is! String || rawSummary.trim().isEmpty
          ? null
          : rawSummary;

      if (topics.isEmpty && summary == null) continue;
      byId[id] = GoldenCard(topics: topics, summary: summary);
    }
    return GoldenCards(byId);
  }
}

/// Reads a bulk run file off disk for its cards.
///
/// Throws for `loadGoldenSet`'s reason, and names what to pass: a run file is
/// written by `make golden` into the git-ignored `tmp/bench/`, so "no file" is
/// the normal failure of somebody who has not run the bulk half yet.
Future<GoldenCards> loadGoldenCards(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw StateError(
      'no run file at $path — GOLDEN_RUN wants the bulk run file whose topics '
      'and summary build the cards; write one with `make golden`',
    );
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List) {
    throw StateError(
      'the file at $path is not a run file — a run file is a JSON array of '
      'per-item objects',
    );
  }
  return GoldenCards.fromRunJson(decoded);
}

/// The candidate card for [item], the way the app builds one.
///
/// Mirrors `enrichedCardForConversationRow` in
/// `lib/services/storyline_service.dart:2789`: the subject stripped of its
/// Re:/Fw: markers, the conversation's display names, and the newest inbound
/// message's extraction topics and triage summary. The set carries the first
/// two; the last two come from a bulk run file, so the card is the one the app
/// would have if the model that wrote that file were the one shipping.
///
/// A missing card degrades to empty topics and no summary rather than failing,
/// exactly as the app's own card does when a conversation has never been
/// enriched — the four ` | ` segments are always there, two of them blank.
String candidateCardFor(GoldenItem item, GoldenCard? card) =>
    buildConversationCard(
      subject: stripReFw(item.conversationSubject),
      // Empty display names dropped before the join, exactly as the app drops
      // them: a blank entry survives `join(', ')` as a stray comma, which is a
      // character the app's own card never carries.
      participants: [
        for (final person in item.conversationParticipants)
          if (person.isNotEmpty) person,
      ],
      topics: card?.topics ?? const [],
      summary: card?.summary,
    );

// ── what one confirmation was, and what a set of them derives ──────────

/// Why a candidate is on an item's list.
enum CandidateKind {
  /// Gold says this item belongs here — the recall question.
  gold,

  /// Gold says filing this item here is an error — the trap.
  forbidden,

  /// Neither: a seeded draw from the rest of the registry — the
  /// false-positive probe.
  extra,
}

CandidateKind kindOf(GoldenItem item, String slug) {
  if (slug == item.gold.storylineId) return CandidateKind.gold;
  if (item.gold.storylineForbidden.contains(slug)) {
    return CandidateKind.forbidden;
  }
  return CandidateKind.extra;
}

/// One confirmation: what was asked, and what came back.
class ConfirmOutcome {
  final String slug;
  final CandidateKind kind;

  /// Null when the call failed after its retries. Neither a yes nor a no —
  /// see [deriveStorylineId], which refuses to file an item that has one.
  final ConfirmResult? result;

  const ConfirmOutcome({
    required this.slug,
    required this.kind,
    required this.result,
  });

  /// The SERVICE's rule, not the model's — and delegated to
  /// [ConfirmResult.accepted] rather than restated, so the replay cannot score
  /// a pipeline the app does not ship. A failed call is not an acceptance: a
  /// null result answered nothing.
  bool get accepted => result?.accepted ?? false;

  /// A yes the service throws away. Counted separately because it is the one
  /// number that says whether a model is being declined by its own hedging
  /// rather than by its judgement.
  bool get lowYes =>
      result != null && result!.belongs && result!.confidence == 'low';
}

/// The `storyline.id` a set of confirmations derives, plus whether anything
/// had to break a tie to get there.
class DerivedStoryline {
  /// A registry slug, `'none'` for the assertion "no storyline", or null for
  /// "not attempted".
  final String? id;

  final bool tie;

  const DerivedStoryline({required this.id, required this.tie});
}

/// Which storyline this item was filed under, out of its confirmations.
///
/// A failed candidate leaves the item UNFILED (`id: null`), even when another
/// candidate said yes. A call that never answered is neither a yes nor a no,
/// and the storyline it would have answered for might have been the right one
/// — so the honest record is "not attempted", which the run file expresses by
/// omitting the section and the scorer reads as no claim rather than as a miss.
///
/// Among the accepted, high beats medium; among the top rank, the
/// alphabetically smallest slug wins. Alphabetical rather than candidate
/// order, deliberately: candidate order puts the gold storyline first, so a
/// tie-break that took the first would hand the model gold every time two
/// answers were equally confident and flatter every recall number in the
/// ledger. Alphabetical is blind to gold, and the ties are counted so a reader
/// knows how often the rule decided anything at all.
DerivedStoryline deriveStorylineId(List<ConfirmOutcome> outcomes) {
  for (final outcome in outcomes) {
    if (outcome.result == null) {
      return const DerivedStoryline(id: null, tie: false);
    }
  }

  var bestRank = 0;
  final best = <String>[];
  for (final outcome in outcomes) {
    if (!outcome.accepted) continue;
    final rank = outcome.result!.confidence == 'high' ? 2 : 1;
    if (rank > bestRank) {
      bestRank = rank;
      best
        ..clear()
        ..add(outcome.slug);
    } else if (rank == bestRank) {
      best.add(outcome.slug);
    }
  }
  if (best.isEmpty) return const DerivedStoryline(id: 'none', tie: false);
  best.sort((a, b) => a.compareTo(b));
  return DerivedStoryline(id: best.first, tie: best.length > 1);
}

/// One item's whole storyline stage, as the run file records its cost.
///
/// Several calls under one label, so this is a SUM rather than a copy of the
/// last one: the item paid for every confirmation on its list, and a row that
/// quoted one of them would understate the stage by four fifths. Tokens go
/// null the moment any record's are null — the same rule `GoldenCall.toJson`
/// holds, because a runtime that reported no usage must not read downstream as
/// one that spent nothing.
GoldenCall summariseCalls(List<LlmCallRecord> records) {
  if (records.isEmpty) {
    throw ArgumentError.value(records, 'records', 'must not be empty');
  }
  var ms = 0;
  int? promptTokens = 0;
  int? completionTokens = 0;
  String? outcome;
  for (final record in records) {
    ms += record.durationMs;
    final prompt = record.promptTokens;
    promptTokens = prompt == null || promptTokens == null
        ? null
        : promptTokens + prompt;
    final completion = record.completionTokens;
    completionTokens = completion == null || completionTokens == null
        ? null
        : completionTokens + completion;
    if (outcome == null && record.outcome != 'ok') outcome = record.outcome;
  }
  return GoldenCall(
    ms: ms,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    outcome: outcome ?? 'ok',
  );
}

/// Which of the four things happened to one item: it landed on its gold
/// storyline, it landed nowhere (which is right for the 35 items gold files
/// nowhere), it landed somewhere else, or a failed call left it unfiled.
///
/// Shared by the per-item line and the tally so the printed rows and the
/// summary can never disagree about what a row was.
String derivedBucket(GoldenItem item, DerivedStoryline derived) {
  final id = derived.id;
  if (id == null) return 'incomplete';
  if (id == 'none') return 'none';
  return id == item.gold.storylineId ? 'gold' : 'other';
}

/// How the gold candidate answered, for the per-item line. An item gold files
/// nowhere has no gold candidate and prints `-`.
String goldCell(List<ConfirmOutcome> outcomes) {
  for (final outcome in outcomes) {
    if (outcome.kind != CandidateKind.gold) continue;
    final result = outcome.result;
    if (result == null) return 'failed';
    if (outcome.accepted) return 'yes(${result.confidence})';
    if (outcome.lowYes) return 'low-yes';
    return 'no';
  }
  return '-';
}

// ── the run's own arithmetic ───────────────────────────────────────────

/// A rate and the two numbers under it. Never a bare percentage: 1 of 2 and 40
/// of 80 are both 50%, and only one of them is worth reading.
String _rate(int accepted, int n) =>
    '$accepted/$n (${n == 0 ? '—' : '${(accepted * 100 / n).round()}%'})';

/// What a storyline replay saw, counted directly.
///
/// BESIDE the scorer, never instead of it: `score_run.py` reads the derived
/// `storyline.id` and applies the must/should/may/forbidden rules, and that is
/// the number a ledger row quotes. These counters answer the questions a single
/// derived id cannot — whether the model said yes to the gold storyline at all,
/// how often it said yes to a trap, how often it said yes to a storyline drawn
/// at random, and how much of its judgement it hedged into `low`, which the
/// service throws away.
class StorylineTally {
  /// The gold candidate of every `must` item, and of every `should` item, that
  /// answered at all. A failed gold call is counted in [derivedIncomplete]
  /// rather than here: a denominator that included it would report a miss the
  /// model never made. `may` items are excluded from both — gold says either
  /// answer is defensible, so a rate over them measures nothing.
  int goldMustN = 0;
  int goldMustAccepted = 0;
  int goldShouldN = 0;
  int goldShouldAccepted = 0;

  int forbiddenN = 0;
  int forbiddenAccepted = 0;
  int extraN = 0;
  int extraAccepted = 0;

  /// Yeses the service declines, across every kind of candidate.
  int lowYes = 0;

  int acceptedHigh = 0;
  int acceptedMedium = 0;

  int derivedGold = 0;
  int derivedNone = 0;
  int derivedOther = 0;
  int derivedIncomplete = 0;

  /// The 35 items gold files nowhere, and how many of them this run also filed
  /// nowhere. The other half of recall, and the half a bounded candidate list
  /// makes hardest: every question these items were asked had "no" for an
  /// answer.
  int goldNoneN = 0;
  int goldNoneDerivedNone = 0;

  int ties = 0;

  void add(
    GoldenItem item,
    List<ConfirmOutcome> outcomes,
    DerivedStoryline derived,
  ) {
    for (final outcome in outcomes) {
      if (outcome.lowYes) lowYes++;
      final result = outcome.result;
      if (result == null) continue;
      if (outcome.accepted) {
        if (result.confidence == 'high') {
          acceptedHigh++;
        } else {
          acceptedMedium++;
        }
      }
      switch (outcome.kind) {
        case CandidateKind.gold:
          final strength = item.gold.storylineStrength;
          // Unreachable from the live path: `candidatesFor` never offers
          // `none` as a candidate, so `kindOf` cannot call one gold on an item
          // gold files nowhere. It stands so a hand-built outcome in a test
          // cannot put a gold-none item into the gold denominators.
          if (item.gold.storylineId == 'none') break;
          if (strength == 'must') {
            goldMustN++;
            if (outcome.accepted) goldMustAccepted++;
          } else if (strength == 'should') {
            goldShouldN++;
            if (outcome.accepted) goldShouldAccepted++;
          }
        case CandidateKind.forbidden:
          forbiddenN++;
          if (outcome.accepted) forbiddenAccepted++;
        case CandidateKind.extra:
          extraN++;
          if (outcome.accepted) extraAccepted++;
      }
    }

    switch (derivedBucket(item, derived)) {
      case 'gold':
        derivedGold++;
      case 'none':
        derivedNone++;
      case 'incomplete':
        derivedIncomplete++;
      default:
        derivedOther++;
    }

    if (item.gold.storylineId == 'none' && derived.id != null) {
      goldNoneN++;
      if (derived.id == 'none') goldNoneDerivedNone++;
    }

    if (derived.tie) ties++;
  }

  Map<String, Object?> toJson() => {
        'gold_must': {'n': goldMustN, 'accepted': goldMustAccepted},
        'gold_should': {'n': goldShouldN, 'accepted': goldShouldAccepted},
        'forbidden': {'n': forbiddenN, 'accepted': forbiddenAccepted},
        'extra': {'n': extraN, 'accepted': extraAccepted},
        'low_yes': lowYes,
        'accepted_confidence': {'high': acceptedHigh, 'medium': acceptedMedium},
        'derived': {
          'gold': derivedGold,
          'none': derivedNone,
          'other': derivedOther,
          'incomplete': derivedIncomplete,
        },
        'gold_none': {'n': goldNoneN, 'derived_none': goldNoneDerivedNone},
        'ties': ties,
      };

  /// Counts, rates and nothing else — no slug, no title, no evidence. The set
  /// and the registry are real correspondence and this repository is public.
  String table() => 'storyline confirm:\n'
      '  gold accepted  must ${_rate(goldMustAccepted, goldMustN)}'
      '   should ${_rate(goldShouldAccepted, goldShouldN)}\n'
      '  forbidden accepted ${_rate(forbiddenAccepted, forbiddenN)}'
      '   extra accepted ${_rate(extraAccepted, extraN)}\n'
      '  accepted confidence  high $acceptedHigh  medium $acceptedMedium'
      '   low-confidence yeses (declined) $lowYes\n'
      '  derived  gold $derivedGold  none $derivedNone  other $derivedOther'
      '  incomplete $derivedIncomplete  ties $ties\n'
      '  gold-none filed nowhere ${_rate(goldNoneDerivedNone, goldNoneN)}';
}
