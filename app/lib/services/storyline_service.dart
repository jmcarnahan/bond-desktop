import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../data/context_store.dart';
import '../data/conversation_vec_index.dart';
import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/context_models.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import 'activity_log.dart';
import 'attachments/attachment_markers.dart';
import 'conversation_state.dart';
import 'extract_handler.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/storyline_tasks.dart';
import 'owner_lookup.dart';
import 'pipeline_progress.dart';
import 'storyline_clustering.dart';
import 'storyline_lint.dart';

/// Every number the storyline logic turns on, in one place.
///
/// They are constants rather than settings because there is nothing useful a
/// user could do with them, and because tuning them means re-reading the
/// clustering behaviour as a whole — a gate moved on its own turns a feature
/// that groups too little into one that groups wrongly, which is the failure
/// users actually notice.
class StorylineTuning {
  /// Cosine a thread must reach against a storyline's centroid to be worth a
  /// model call. Deliberately well below "obviously the same thread": the
  /// embedding is a filter that decides what the model looks at, and the model
  /// is what decides membership.
  static const double assignCosineGate = 0.60;

  /// The gate when the thread shares enough people with the storyline. Who is
  /// on a thread is the single strongest signal that two threads are the same
  /// deal, so it buys a look the vector alone would not have earned. How many
  /// people "enough" is, and who does not count, is
  /// [assignOverlapMinShared].
  static const double assignCosineGateWithOverlap = 0.50;

  /// How many shared people, none of them the owner, earn
  /// [assignCosineGateWithOverlap].
  ///
  /// The lower gate used to fire on ANY shared participant, and in a one-team
  /// mailbox every pair of threads shares someone — so the discount was the
  /// rule rather than the exception and the real gate was 0.50. Two shared
  /// people who are not the owner is a GROUP, which is the signal the
  /// discount was meant to buy. The owner is never evidence of anything: they
  /// are on every thread in their own mailbox.
  static const int assignOverlapMinShared = 2;

  /// How close the second-best candidate has to sit to the best one before
  /// the cosine is no longer allowed to pick between them.
  ///
  /// The 4B tied fifteen times on the golden replay, and taking the first of
  /// two candidates at 0.61 and 0.60 was a coin toss dressed as a ranking.
  /// Within this margin both are asked and the ANSWER decides — the
  /// confident yes, and the higher cosine only when the answers agree.
  static const double assignTieMargin = 0.03;

  /// The floor share of a window's automatic adds a storyline must exceed
  /// before it can be called a catch-all. See [catchAllFairShareMultiple] for
  /// the other half of the threshold.
  static const double catchAllShare = 0.30;

  /// How many times its fair share a storyline must take to be
  /// disproportionate, where fair is `1 / k` and `k` is the number of
  /// storylines that received at least one automatic add in the window.
  ///
  /// The threshold is `max(catchAllShare, catchAllFairShareMultiple / k)`,
  /// because a flat share cannot tell a catch-all from arithmetic when there
  /// are few storylines: with two storylines one of them always holds at
  /// least half, and with three at least a third, so a flat 30% would exclude
  /// the larger of any two from auto-assign forever and then the smaller one
  /// as soon as it caught up, and the pass would file nothing at all. Twice
  /// its fair share is disproportionate at any `k`, and the floor stops a
  /// mailbox with twenty storylines from calling 11% a catch-all. With one or
  /// two storylines the threshold is 100% or more and the rule never fires,
  /// which is right: there is nothing for a catch-all to be a catch-all OF.
  static const int catchAllFairShareMultiple = 2;

  /// How many automatic adds the window needs before its shape means
  /// anything. Fewer than this is not a pattern.
  static const int catchAllMinAdds = 10;

  /// How far back the catch-all rule looks, in days.
  static const int catchAllWindowDays = 7;

  /// Cosine two conversations must reach for the pair to count as a LINK.
  /// Higher than the assignment gates because there is no existing group to
  /// score a candidate against — the only thing holding a cluster together is
  /// how close its members sit to each other.
  ///
  /// A link is no longer a join. Reaching this against ONE member of a group
  /// used to be enough to be in it, which is what chained the golden mailbox
  /// into a single storyline holding 56% of every filed thread on 2026-09-18.
  /// A candidate now needs two links and half the members — see
  /// [clusterBySimilarity], which owns the rule and every compare in it.
  ///
  /// Still a filter and not a verdict: what the cluster produces is a
  /// shortlist and a name, and every member of it is then confirmed against
  /// that name one thread at a time, exactly as an assignment is. In a
  /// mailbox where every thread shares the same boilerplate, neighbours at
  /// this cosine can be about entirely different things, and the confirm
  /// stage is what catches that — raising the number here would only make the
  /// pass propose less.
  static const double clusterLinkThreshold = 0.65;

  /// A storyline of one is just a thread. This is the SURVIVOR floor, applied
  /// after the confirms have spoken: see [proposeMinClusterSize] for how many
  /// threads a cosine cluster needs before it is worth asking about at all.
  static const int minClusterSize = 2;

  /// How many threads one COSINE cluster needs before the sweep spends a
  /// naming call on it.
  ///
  /// Two threads that merely embed alike are a coincidence, and the confirms
  /// cannot rescue a pair: they are judged against a charter written from
  /// those same two threads, so a coincidence describes itself and then agrees
  /// with its own description. Three is a pattern — something a charter can be
  /// wrong about. [minClusterSize] stays the floor AFTER the confirms, so a
  /// three-thread proposal that loses one member still ships as a storyline of
  /// two.
  ///
  /// A SERIES seeded by the subject pre-pass is already at least
  /// [seriesMinSize], so this never turns one away.
  static const int proposeMinClusterSize = 3;

  /// How many threads sharing one series key make a SERIES the sweep seeds as
  /// a cluster of its own, ahead of the cosine clustering.
  ///
  /// Three, for [proposeMinClusterSize]'s reason and one of its own: two
  /// threads with the same folded subject are usually a thread and its
  /// forward, while a third issue is what makes something recurring.
  static const int seriesMinSize = 3;

  /// How many member cards the naming call reads: the ones nearest the
  /// cluster's centroid, each whole under [NameStorylineTask.cardCap].
  ///
  /// Twelve because [maxClusterSize] is twelve, so a cluster that formed under
  /// the cap is shown entire; a seeded series that ran longer is shown its
  /// most central twelve. The old prompt fitted forty cards into four thousand
  /// characters by taking eighty-three characters of each, which is a subject
  /// line and nothing the name could follow from.
  static const int namingCards = 12;

  /// How many threads one cluster may hold before it stops accepting members.
  ///
  /// Not a limit on how large a storyline may grow — the assign pass, the
  /// recruit lap and a person's own filing all add members without asking
  /// this — but on how large a group may get before anybody has looked at it.
  /// A proposal of twelve threads is already more than a person reads before
  /// answering, and every thread past that is a naming call describing
  /// something more general than the one it would have described without it.
  /// Twelve is also well under where the measured blobs sat: the largest
  /// storyline of the 2026-09-18 golden sweep held 56% of every filed thread.
  ///
  /// A cluster that reaches it is re-clustered at a higher threshold rather
  /// than truncated. Truncating would make the result depend on the store's
  /// order in a way nothing could explain to a user.
  static const int maxClusterSize = 12;

  /// The mean pairwise cosine a cluster has to reach to be worth naming.
  ///
  /// Read off the golden sweep of 2026-09-18, which printed the cosine of
  /// every pair inside every storyline it formed. Below 0.55 there were 17
  /// pairs out of 861 even inside the chained blobs, so a floor there would
  /// never bite; the 0.55 to 0.60 band is where a blob's mean sits and a
  /// tight cluster's does not.
  ///
  /// A cluster under it is split at a higher threshold, and what is still
  /// under it at [clusterSplitCeiling] is dropped for the pass — no naming
  /// call, and no tombstone either, because nothing was asked.
  static const double clusterCoherenceFloor = 0.60;

  /// How much higher each re-clustering rung asks for. Small enough that a
  /// group that is nearly two groups comes apart at the seam rather than
  /// shattering into singletons.
  static const double clusterSplitStep = 0.05;

  /// The top of that ladder. Past this the question stops being useful: two
  /// threads at 0.85 are near-duplicates of each other, and a group that is
  /// still incoherent when only near-duplicates count as linked was never one
  /// group.
  static const double clusterSplitCeiling = 0.85;

  /// How many unanswered suggestions may sit in the rail at once. A wall of
  /// proposals is not a feature; it is a chore, and it gets dismissed as one.
  static const int maxPendingSuggestions = 3;

  /// All this floor asks is that there be something to pair: below two
  /// unassigned threads — mail or chat — there is no pair for any rule to
  /// consider, so the pass returns before it reads a vector. It says nothing
  /// about whether the pool holds a group worth naming. That is
  /// [proposeMinClusterSize]'s question on the cosine side and the series
  /// pre-pass's on the subject side, and [clusterLinkThreshold], the
  /// per-member confirm and [maxPendingSuggestions] decide the rest. Raising
  /// this floor would only starve a light mailbox of its first storyline
  /// without sparing a single model call.
  static const int sweepMinUnassigned = 2;

  /// How many threads one recruit pass may put in front of the model. A
  /// charter save is one user action, and eight confirmations is already the
  /// most model time any single click in this app spends — past the top eight
  /// by cosine, a candidate was not close enough for a missed-thread hunt to
  /// be the pass that finds it.
  static const int recruitMaxCandidates = 8;

  /// How much of a storyline's charter the confirm task is judged against, in
  /// characters. The clamp bites often — most real charters are longer than
  /// this, so what the model reads is usually the opening of a description
  /// rather than the whole of one — which made it look like something worth
  /// raising.
  ///
  /// Measured 2026-09-16, the 4B, the same cards at 400 / 800 / 1200: the
  /// scorer's `storyline.id` went 81% / 78% / 77% and forbidden-accept went
  /// 20% / 25% / 26%. So a longer charter did not buy recall, it cost
  /// precision: more charter is more surface for a candidate to match
  /// against, and the 4B matched on it. The cap stays at 400.
  ///
  /// It stays a PARAMETER of the task rather than going back to a constant
  /// inside it, and `GOLDEN_CHARTER_CAP` stays with it: this answer is one
  /// model's, and the 27B or whatever replaces it can be asked the same
  /// question without a code change.
  static const int charterCap = 400;

  /// Whether the text a conversation is EMBEDDED from carries the people on
  /// it — [buildClusteringCard]'s `withParticipants`.
  ///
  /// True is what shipped until 2026-09-18, and it was the suspect: in a
  /// mailbox where one team is on everything, the participants segment is the
  /// same handful of names in every card, so every pair of threads embeds
  /// alike and the sweep proposes the team rather than the work. The cards the
  /// MODEL reads are unaffected either way. This is the vector, not the
  /// prompt.
  ///
  /// Measured in Round D Phase 1 by `make golden-sweep SWEEP_CARD=
  /// participants|topics`, twice each, over the same 95 seeded conversations.
  /// The rule was written before the runs: `topics` ships only if it beats
  /// `participants` by at least four points on `storyline.id` on both passes,
  /// or ties within four with a smaller largest-storyline share and no fewer
  /// correct positives. It beat it by eight — 31 of 98 against 23 of 98 —
  /// with purity over the storylines that carried gold members moving from
  /// 44% to 71% and the largest storyline's share of every filed thread
  /// falling from 56% to 47%. Neither card produced a correct positive, which
  /// is the chaining the join rule above is what removes.
  ///
  /// So it ships false. Flipping it orphans every stored conversation vector
  /// by construction, since every read filters on the tag, so it moved
  /// together with [EmbeddingsClient.modelTag] (now `…/clustering-v2`) and the
  /// `clustering_card_v2` one-shot in `sync_service.dart`, which requeues the
  /// assign pass for the old-tag threads a slice at a time until they carry a
  /// vector in the new geometry.
  static const bool participantsInClusteringCard = false;
}

/// What one pass of [StorylineService.assignConversation] concluded.
///
/// The pass files nothing most of the time, and until this existed there was
/// no way to tell the several reasons for that apart — a thread the model
/// turned down, a thread the user had blocked, and a thread nothing came
/// close to all looked identical from the outside, including in the activity
/// log.
enum AssignOutcome {
  /// Filed into a storyline.
  assigned,

  /// Nothing cleared the cosine gate, or there was nothing to compare against.
  /// The common case, and an unremarkable one.
  noCandidate,

  /// The model looked and said no — `belongs: false`, or a yes it was not
  /// confident about.
  rejected,

  /// The only storylines it could have joined are ones the user took it out
  /// of. Their "no" still holds.
  blocked,

  /// The only storyline it cleared the gate for is one that has been taking
  /// more than its share of the automatic adds lately. Not filed: a group
  /// that swallows the mailbox is a group whose charter admits everything,
  /// and one more thread in it would be one more thread to un-file. That
  /// storyline's automatic members are queued for a re-check instead.
  catchAll,

  /// Every inbound message in the conversation is gated; nothing kept is
  /// there to file. Closed without an embedding or a model call — there is no
  /// card that would say anything true about a thread the gates threw out,
  /// and a vector built from one is what grows a junk storyline.
  gated,
}

/// What one storyline's membership looks like to the two comparison passes:
/// the mean of its members' vectors, everyone on any member thread, and the
/// member threads themselves. Built by `StorylineService._memberContexts`.
typedef _MemberContext = ({
  List<double>? centroid,
  Set<String> participants,
  Set<String> memberThreads,
});

/// Groups conversations into storylines, and applies the user's corrections.
///
/// Two entry points do the automatic work — [assignConversation] runs when one
/// thread's embedding changes, [sweep] runs when the mailbox as a whole might
/// have grown a new group — and both are the bodies of work items, so both may
/// be interrupted at any await and re-run from scratch.
///
/// Everything below them is a user action and touches no model at all: a
/// person renaming, keeping, dismissing or re-filing a storyline is not a
/// thing to ask a model about.
class StorylineService {
  /// What the sweep and the recruit READ. Every embedded thread, whichever
  /// connector it arrived through — a storyline is about a topic, not a
  /// transport, and a mail-and-chat pair about the same launch is exactly the
  /// cluster this exists to find.
  static const List<String> _sources = ['email', 'teams'];

  /// What the sweep and recruit WORK ROWS are labelled with, which is a
  /// different thing entirely. The `source` column on those rows is a label,
  /// not a scope — their entity ids are storyline ids and the literal
  /// `'sweep'` — and every such row ever written carries `'email'`. Changing
  /// the label would strand the existing rows' idempotence keys and re-run
  /// work that is already done.
  ///
  /// Also the fallback for a conversation row that carries no source of its
  /// own: such a row was written before there was a second connector, so it is
  /// mail.
  static const String _workSource = 'email';

  final MessageStore _store;
  final LlmClient _client;

  /// Where membership questions go. Deciding whether one thread belongs to a
  /// group is a label under a tight schema, re-checked in Dart — the small
  /// model answers it in a fraction of the time and the app is not measurably
  /// worse for it. Naming stays on [_client] because a title and a summary are
  /// prose a person reads, and there the bigger model shows.
  ///
  /// Defaults to [_client], so a caller that passes one client gets the
  /// single-server behaviour this service had before there were two.
  final LlmClient _confirmClient;

  /// Notes what the two automatic passes actually DID onto the row the worker
  /// is about to write. Only the outcomes: both passes are no-ops most of the
  /// time, and an unnoted no-op is suppressed rather than logged — see
  /// `ActivityLog.record`. Nothing here calls `record` itself; the worker owns
  /// the row, this only fills it in.
  final ActivityLog _log;

  /// How a thread whose embedding is missing gets one. Optional: given none,
  /// the pass parks on a missing vector exactly as it always did, which is what
  /// every caller that never embeds — the user actions, most tests — wants.
  final EmbeddingsClient? _embeddings;

  /// Cryptographic randomness for ids. Not for secrecy — for the guarantee
  /// that two ids generated in the same millisecond differ, which a
  /// time-seeded generator does not give.
  static final math.Random _random = math.Random.secure();

  /// Announces a hand-filed membership to an open home screen. It carries the
  /// tick and NOT the write — the stamp happens either way, see
  /// [PipelineProgress.noteStorylineLink]. Only the user actions use it; the
  /// automatic passes are recorded by the handlers, which hold their own
  /// recorder. Defaulted to the disabled one, so the several hundred tests
  /// that build this service without a home screen in sight cost nothing.
  final PipelineProgress _progress;

  /// The library of registered directories, or null on a build with none.
  ///
  /// Optional for [_embeddings]'s reason: a service given none behaves exactly
  /// as it did before there were directories — no recap footer, no charter
  /// offered — which is what every caller that predates them is entitled to.
  final ContextStore? _context;

  /// Who the owner is, for the overlap rule in [assignConversation]: the
  /// owner is on every thread in their own mailbox, so counting them as a
  /// shared person would earn the lower gate for any two threads at all.
  ///
  /// Asked once, by [memoizedOwner], and degraded the same way the needs-you
  /// handler's is: a lookup that threw is forgotten and reads as null until
  /// one answers, which leaves the overlap rule counting everyone as not the
  /// owner and so STRICTER, never looser. Tests pass a literal; the app
  /// passes the same closure the needs-you handler takes.
  final OwnerLookup _owner;

  StorylineService(
    this._store,
    LlmClient client, {
    LlmClient? confirmClient,
    ActivityLog? activityLog,
    this._embeddings,
    this._progress = const PipelineProgress.disabled(),
    ContextStore? contextStore,
    OwnerLookup? owner,
  })  : _client = client,
        _confirmClient = confirmClient ?? client,
        _context = contextStore,
        _owner = memoizedOwner(owner ?? (() async => null)),
        _log = activityLog ?? ActivityLog.disabled();

  // ── automatic: one thread ──────────────────────────────────────────────

  /// Considers one conversation for every live storyline, and files it into at
  /// most one.
  ///
  /// The shape is a funnel, and each stage exists to make the next one
  /// cheaper: the vector gate picks candidates for free, the best candidate
  /// alone reaches the model, and the model's answer is the only thing that
  /// creates a membership. At most one confirmation call per thread, whatever
  /// the mailbox looks like.
  ///
  /// A thread with no comparable vector is embedded here and then carries on —
  /// and PARKS the queue only when that cannot be done. Nothing about such a
  /// thread failed, its embedding simply has not been written yet, and the
  /// worker's park is the only outcome that puts the row back as `pending`
  /// with its attempt unspent. Returning quietly wrote the row `done` and lost
  /// the thread — an embedding server that was down for an afternoon meant a
  /// day of mail that was never considered for a storyline. Only the
  /// `storyline` kind parks; extraction, the sweep and drafting are on other
  /// servers and carry on.
  Future<AssignOutcome> assignConversation(
    String source,
    String conversationKey,
  ) async {
    final row = await _store.getConversationRow(source, conversationKey);
    // Read BEFORE the vector: a conversation that no longer exists has no
    // embedding coming, so parking on it would hold the queue open forever
    // for a thread nothing can ever file.
    if (row == null) return AssignOutcome.noCandidate;

    // Before the vector, so [_reembed] is never reached for such a thread and
    // no embedding call is spent on one. A conversation whose every inbound
    // message was gated has nothing kept to file: the card would be built out
    // of mail the pipeline already decided was never said, and one sender's
    // gated threads look alike enough to cluster into a proposal about them.
    if (await _store.keptInboundCount(source, conversationKey) == 0) {
      return AssignOutcome.gated;
    }

    // Written here when the store has none — see [_reembed]. Null comes back
    // only from an embedding the server refused to give; the other two endings
    // throw and park.
    final vector = await _vectorFor(source, conversationKey) ??
        await _reembed(source, conversationKey, row);
    if (vector == null) return AssignOutcome.noCandidate;

    final conversation = Conversation.fromRow(row);
    // The owner is left out of this list and ONLY this list: the storyline's
    // own people, read by [_memberContexts] and [_participantsOfStoryline],
    // are context the model reads and are not the owner's business.
    final owner = await _owner();
    final participants = _nonOwnerDisplaysOf(conversation, owner);

    // Suggestions included: a thread that belongs to a group the user has not
    // answered yet still belongs to it, and waiting would mean the suggestion
    // is judged on a member set that stopped growing.
    final candidates = await _store.loadStorylines(
      statuses: const ['suggested', 'active'],
    );

    Storyline? best;
    var bestScore = 0.0;
    // The runner-up, kept because a cosine ranking inside
    // [StorylineTuning.assignTieMargin] is not a ranking. Ties on score keep
    // the earlier candidate on top, which is the store's order.
    Storyline? second;
    var secondScore = 0.0;
    // Only to tell the empty-handed endings apart: a thread the user pulled
    // OUT of the one storyline it fits is a different fact from a thread
    // nothing came close to, and both differ from a thread whose one
    // qualifying group has been swallowing the mailbox.
    var blocked = false;
    var skippedCatchAll = false;
    final audits = <String>[];

    // Two reads for the whole pass, not two per candidate. Both questions the
    // loop below asks are about state that cannot change while it runs, and
    // asking them one storyline at a time made filing one thread cost a query
    // per storyline plus a query per member of each — the pass got slower
    // every time the mailbox grew a group.
    final contexts =
        await _memberContexts([for (final s in candidates) s.id]);
    final blockedIn =
        await _store.blockedStorylineIdsFor(source, conversationKey);
    // One read for the whole pass, like the two above, and the same reason:
    // the window's shape cannot change while this loop runs.
    final catchAlls = await _catchAllIds();

    for (final storyline in candidates) {
      if (blockedIn.contains(storyline.id)) {
        blocked = true;
        continue;
      }

      // Absent means a storyline with no members at all — nothing to compare
      // against, the same ending an absent centroid gets below.
      final context = contexts[storyline.id];
      if (context == null) continue;
      if (context.memberThreads.contains(_threadKey(source, conversationKey))) {
        continue;
      }

      // A storyline whose members have no vectors cannot be compared against
      // anything. Skipped rather than guessed at.
      final centroid = context.centroid;
      if (centroid == null) continue;

      final shared = participants
          .where((display) => context.participants.contains(display.toLowerCase()))
          .length;
      final gate = shared >= StorylineTuning.assignOverlapMinShared
          ? StorylineTuning.assignCosineGateWithOverlap
          : StorylineTuning.assignCosineGate;

      final score = cosine(vector, centroid);
      if (score < gate) continue;

      // AFTER the gate on purpose: a catch-all this thread would not have
      // joined anyway is not "the only qualifying candidate", and must not
      // produce the [AssignOutcome.catchAll] ending or queue an audit.
      if (catchAlls.ids.contains(storyline.id)) {
        skippedCatchAll = true;
        audits.add(storyline.id);
        continue;
      }

      if (best == null || score > bestScore) {
        second = best;
        secondScore = bestScore;
        best = storyline;
        bestScore = score;
      } else if (second == null || score > secondScore) {
        second = storyline;
        secondScore = score;
      }
    }

    // The re-check the skip is worth: a group taking more than its share of
    // the adds has members that do not belong in it, and the audit is the
    // narrowing this app already has.
    //
    // At most ONE audit per catch-all per window, which is what
    // [MessageStore.requeueWorkIfStale] buys over a plain requeue. The audit
    // runs at temperature 0 against an unchanged charter, so asking it again
    // this afternoon spends one confirm per automatic member to be told what
    // it was told this morning — and a storyline excluded from auto-assign
    // can only change through a refresh or a person, either of which queues
    // its own pass. A plain requeue collapses only while the row is still
    // `pending`; once it drained the next arriving thread would revive it,
    // and a mailbox that keeps delivering would re-audit all day.
    for (final id in audits) {
      await _store.requeueWorkIfStale(
        'storyline_audit',
        _workSource,
        id,
        touchedBefore: catchAlls.since,
      );
    }

    // Copied into finals so flow analysis can promote them: `best` and
    // `second` are nullable locals the loop above assigns, and the branches
    // below read them as non-null.
    final top = best;
    final runnerUp = second;
    if (top == null) {
      if (skippedCatchAll) return AssignOutcome.catchAll;
      return blocked ? AssignOutcome.blocked : AssignOutcome.noCandidate;
    }

    final cardData = await _store.newestInboundCardData(source, conversationKey);

    // One candidate, asked. The owner's own examples for that storyline are
    // read here rather than above because a pass that ends up asking two
    // storylines wants each one's own history, not the winner's.
    Future<ConfirmResult> judge(Storyline candidate) async => _confirm(
          candidate,
          await _participantsOfStoryline(candidate.id),
          row,
          cardData,
          examples: await _examplesFor(candidate.id),
        );

    final Storyline chosen;
    final ConfirmResult result;
    var confirmed = 1;
    if (runnerUp != null &&
        bestScore - secondScore <= StorylineTuning.assignTieMargin) {
      // Inside the margin the cosine has stopped ranking, so both are asked
      // and the answers rank them: the more confident yes wins, and an equal
      // confidence leaves the higher cosine — [top], asked first — on top.
      confirmed = 2;
      final topAnswer = await judge(top);
      final runnerUpAnswer = await judge(runnerUp);
      ({Storyline storyline, ConfirmResult result})? winner;
      if (_accepts(topAnswer, top)) {
        winner = (storyline: top, result: topAnswer);
      }
      if (_accepts(runnerUpAnswer, runnerUp) &&
          (winner == null ||
              _confidenceRank(runnerUpAnswer.confidence) >
                  _confidenceRank(winner.result.confidence))) {
        winner = (storyline: runnerUp, result: runnerUpAnswer);
      }
      // Nothing is blocked on a no either way — only a person removing a
      // thread creates a block, because only a person's "no" should still
      // hold the next time the model changes its mind.
      if (winner == null) return AssignOutcome.rejected;
      chosen = winner.storyline;
      result = winner.result;
    } else {
      final answer = await judge(top);
      if (!_accepts(answer, top)) return AssignOutcome.rejected;
      chosen = top;
      result = answer;
    }

    await _store.addStorylineMember(
      chosen.id,
      source,
      conversationKey,
      addedBy: 'auto',
      evidence: result.evidence,
    );
    await _store.updateStoryline(
      chosen.id,
      memberHash: await _memberHashOf(chosen.id),
      // Membership is part of the story, so a membership change retires the
      // recap's watermark. That watermark was measured against the OLD member
      // set, and letting it gate a recap over the NEW one is how a thread
      // filed in August — every message on it older than the mark — reaches a
      // storyline screen whose centrepiece never mentions it. An explicit
      // clear, not an omission: `recapThrough` takes the v10 sentinel, and
      // leaving it out is what "do not touch this column" means. The next
      // recap re-reads the whole window across the current members and stamps
      // a fresh mark, so this costs one call and never a loop. Every other
      // site that writes `member_hash` does the same — see this comment.
      recapThrough: null,
    );
    // The name rather than the id, because this is read by a person in the
    // activity panel, and because a filing that happened is the whole point of
    // the pass — an unnoted one would be indistinguishable from the far more
    // common pass that filed nothing.
    //
    // `confirmed` rides along only when the pass asked twice, so a reader of
    // the log can tell a near-tie that was decided by the model from the
    // ordinary single question.
    _log.note({
      'assigned': chosen.title,
      if (confirmed > 1) 'confirmed': confirmed,
    });

    final lastMessageAt = conversation.lastMessageAt;
    if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
      await _store.touchStorylineActivity(chosen.id, lastMessageAt);
    }

    await _enqueueRefreshAfterAssign(chosen);
    return AssignOutcome.assigned;
  }

  /// Decides whether one automatically filed thread is worth re-describing a
  /// storyline for, and queues the pass when it is.
  ///
  /// A row on the queue rather than a call, and a gated row at that. Every
  /// USER action enqueues a refresh unconditionally — a person who files a
  /// thread by hand is telling the app the group has changed, and they are
  /// looking at it. This path is the other one: threads arriving on their own,
  /// one at a time, all day. Refreshing on each of them would dial the 27B
  /// once per filed thread to re-write a description that reads the same, and
  /// a name that churns every time a thread lands reads as instability.
  ///
  /// So the gate is the three cases where the description is genuinely behind:
  /// a storyline with nothing to say for itself (no summary), one that never
  /// drafted a charter and is not forbidden from having one, and one that has
  /// grown by two or more members since it was last described. The last is a
  /// count comparison rather than a timer because it is deterministic — a
  /// re-run after a restart makes the same decision. Single-thread growth
  /// coalesces into the sweep's catch-up instead, which asks the durable
  /// question once per pass.
  ///
  /// Either way the cost is bounded: `requeueWork` is keyed on
  /// `(kind, source, entity_id)`, so a storyline that collects ten threads in
  /// one drain gets one refresh, not ten.
  ///
  /// And the gate is narrower than it looks. Every assignment moves
  /// `member_hash`, so on any drain that also holds a sweep row the catch-up
  /// at the head of [sweep] queues the refresh whatever this decided — which
  /// is every drain a sync starts. What this gate actually governs is the
  /// drains with no sweep row in them, a pump the UI kicked off: there, and
  /// only there, is a single quiet thread's refresh genuinely deferred to the
  /// next sync.
  Future<void> _enqueueRefreshAfterAssign(Storyline storyline) async {
    final summary = (storyline.summary ?? '').trim();
    final charter = (storyline.charter ?? '').trim();
    var wake = summary.isEmpty || (charter.isEmpty && !storyline.charterLocked);

    final described = storyline.refreshedMemberCount;
    // Null means never described, which the first clause has already caught
    // for every storyline that has nothing written — a described-but-uncounted
    // row is a pre-feature one, and the sweep's catch-up owns it.
    if (!wake && described != null) {
      final now = (await _store.membersOf(storyline.id)).length;
      wake = now - described >= 2;
    }
    if (!wake) return;
    await _store.requeueWork('storyline_refresh', _workSource, storyline.id);
  }

  // ── automatic: one storyline, on its own membership ────────────────────

  /// Re-describes a storyline whose membership has moved.
  ///
  /// The pass that replaced converge-and-stop. A storyline used to be named
  /// once and then never again: the title, summary and charter it got on the
  /// day it was proposed were the ones it kept, however many threads joined
  /// afterwards and however little the original description still fit. This
  /// runs whenever the member set differs from the one the last description
  /// was written against — and the equality of those two hashes is what stops
  /// it running when nothing changed.
  ///
  /// Two branches, because describing a storyline for the first time and
  /// re-describing one are different questions. A storyline with no summary,
  /// or no charter it is allowed to have, is BOOTSTRAPPED with the same naming
  /// call the sweep uses on a fresh cluster. One that already reads well is
  /// EVOLVED: the model is handed what it says today and asked to change as
  /// little as possible.
  ///
  /// Locks are honoured in both, and honoured twice: read before the call so
  /// the model knows, and re-read after it so a user who renamed the storyline
  /// while it ran still wins. A locked charter is never overwritten — the
  /// model's version is parked in `charter_suggestion` for the About block to
  /// offer.
  Future<void> refresh(String storylineId) async {
    final storyline = await _store.getStoryline(storylineId);
    // Dismissed between the enqueue and the drain. Re-describing it would
    // spend a call on a group nothing renders.
    if (storyline == null ||
        (storyline.status != 'active' && storyline.status != 'suggested')) {
      return;
    }

    final members = await _store.membersOf(storylineId);
    // The stored column is what the gate compares, because the stamp below
    // writes to the same column and the two must speak one recipe. Derived
    // from the member rows only when the column was never written — an older
    // row, or one seeded straight into the store — so that such a storyline
    // still converges instead of re-describing itself on every trigger.
    final memberHash = storyline.memberHash ??
        _hashOfThreads([
          for (final member in members)
            (source: member.source, key: member.conversationKey),
        ]);

    // Null means never described, and never described is not the same as
    // unchanged: that storyline gets its first draft below.
    final described = storyline.refreshedMemberHash;
    if (described != null && described == memberHash) return;

    // A storyline whose members were all removed, or whose conversation rows
    // are gone, has nothing to describe it from — and nothing to describe IS a
    // description of the empty set, so it is stamped like any other answer.
    // Returning without the stamp left the description permanently behind the
    // members, which the sweep's catch-up would re-queue on every sync
    // forever. A later membership change moves `member_hash` and re-fires this
    // pass, which is the only event that could make the answer different.
    final cards = await _cardsOf(members);
    if (cards.isEmpty) {
      await _store.updateStoryline(
        storylineId,
        memberHash: await _healedMemberHash(storyline, memberHash),
        refreshedMemberHash: memberHash,
        refreshedMemberCount: members.length,
      );
      return;
    }

    // Everything the writes below compare against is captured HERE, before
    // the model is dialled. See the stamp at the end for why.
    final preCount = members.length;
    final preCharter = storyline.charter;

    final summary = (storyline.summary ?? '').trim();
    final charter = (storyline.charter ?? '').trim();
    final bootstrap =
        summary.isEmpty || (charter.isEmpty && !storyline.charterLocked);

    // What the unlocked path actually wrote to the charter column, and null
    // when it wrote nothing. A parked suggestion is deliberately not this: it
    // changes no criteria, so it recruits nothing.
    final String? wroteCharter = bootstrap
        ? await _bootstrapDescription(storylineId, cards)
        : await _evolveDescription(
            storylineId,
            storyline,
            cards,
            _newSince(storyline.refreshedMemberCount, preCount, cards.length),
            await _removedCardsOf(storylineId),
          );

    // The PRE-call hash and count, not the current ones. A thread filed by
    // hand while the model was thinking is a thread this description never
    // saw, and stamping what is true NOW would claim otherwise — the gate
    // above would then read as "unchanged" and that thread would never be
    // described. Stamping the old value leaves the storyline stale, which
    // re-fires the pass, which is the correct outcome.
    await _store.updateStoryline(
      storylineId,
      memberHash: await _healedMemberHash(storyline, memberHash),
      refreshedMemberHash: memberHash,
      refreshedMemberCount: preCount,
    );

    // The charter is the membership contract, so a charter that moved is a
    // reason to go looking again — the same thing a user saving one does.
    // Only a real change, compared normalized: a model that returns the same
    // sentences with different spacing must not put the pair into a loop.
    if (wroteCharter != null &&
        _normalized(wroteCharter) != _normalized(preCharter ?? '')) {
      await _store.requeueWork('storyline_recruit', _workSource, storylineId);
    }

    // Unconditional, and only on the passes that got this far: reaching here
    // means the member set moved, and a storyline that gained or lost a thread
    // is a storyline whose state of play changed — the recap was written
    // against messages that are no longer the whole story. The two early
    // returns above skip this deliberately; a refresh that found nothing
    // changed changed nothing for the recap either.
    await _store.requeueWork('storyline_recap', _workSource, storylineId);
  }

  /// The value [refresh] should write to `member_hash`, or null to leave the
  /// column alone — [MessageStore.updateStoryline] takes this one as a plain
  /// nullable, so null means "not this call's business".
  ///
  /// A one-time heal for rows seeded before anything wrote the column: a
  /// fixture, or a storyline from before the hash existed. The refresh gate
  /// falls back to deriving the hash from the member rows when the column is
  /// NULL, but the sweep's catch-up asks SQL —
  /// `refreshed_member_hash IS NOT member_hash` — and NULL is not any hash, so
  /// such a row is stale forever however many times the pass runs. The gate
  /// and the column have to speak the same value or the catch-up never closes.
  ///
  /// Re-read rather than trusted from the snapshot, because the caller took
  /// that snapshot before dialling the model: a thread filed while the model
  /// was thinking wrote a NEWER hash, and overwriting it with the derived
  /// pre-call one would make the two columns agree about a member set that no
  /// longer exists — the one outcome the pre-call stamp exists to prevent.
  Future<String?> _healedMemberHash(Storyline snapshot, String derived) async {
    if (snapshot.memberHash != null) return null;
    final current = await _store.getStoryline(snapshot.id);
    return current?.memberHash == null ? derived : null;
  }

  // ── automatic: one storyline, on what was said in it ───────────────────

  /// Writes where a storyline stands right now, for a reader who has been
  /// away.
  ///
  /// The one pass that runs on MESSAGES rather than on membership. The other
  /// three describe a storyline so the app can act on it — a title for a row,
  /// a charter to judge threads against — and all of them go quiet the moment
  /// the member set settles. This one keeps moving as long as people are
  /// talking, because that is what the user asked for: something to check in
  /// on periodically instead of re-reading the last few days of a thread.
  ///
  /// It must be useful when there is nothing to do. An inbox that only speaks
  /// up about work owed is silent about the storylines that are going well,
  /// and "going well" is exactly what someone coming back from a week away
  /// wants to be told.
  ///
  /// The window is the newest [MessageStore.recentStorylineMessages] across
  /// every member thread, merged into one chronology. Not per thread: a
  /// storyline is one story told in several places, and a per-thread recap
  /// would be the thing the reader is already doing by hand.
  Future<void> recap(String storylineId) async {
    final storyline = await _store.getStoryline(storylineId);
    // Dismissed between the enqueue and the drain. Recapping it would spend a
    // call describing a group nothing renders.
    if (storyline == null ||
        (storyline.status != 'active' && storyline.status != 'suggested')) {
      return;
    }

    // Newest first, as the store hands them over. Empty means a storyline
    // whose threads hold nothing the recap may read — every member emptied,
    // or every message gated — and there is nothing to say about it. Quiet,
    // like the recruit's own empty ending.
    final rows = await _store.recentStorylineMessages(storylineId);
    if (rows.isEmpty) return;

    // The watermark, taken BEFORE the model is dialled and before the list is
    // reversed. The store orders `received_at DESC`, and SQLite sorts NULLs
    // last under DESC, so the first row carries the newest timestamp there is.
    final newestSeen = rows.first['received_at'] as String?;
    // Every message in the window arrived without a timestamp — nothing here
    // can move a watermark, and a recap that cannot stamp one would re-run on
    // every trigger for the rest of the database's life.
    if (newestSeen == null || newestSeen.isEmpty) return;

    // The staleness gate, before the call rather than after it. ISO-8601 with
    // a fixed offset compares correctly as a string — that is the format's
    // whole point, and every timestamp this app stores is written that way —
    // so no parsing is needed to ask "has the recap already read this?"
    final through = storyline.recapThrough;
    if (through != null && through.compareTo(newestSeen) >= 0) return;

    // What the documents in this window say, one query per source rather than
    // a join onto the window read: the window query is already a UNION across
    // every member thread, and hanging a second LEFT JOIN off it would make
    // the common case — a storyline with no attachments anywhere — pay for the
    // rare one.
    final digests = await _digestsForWindow(rows);
    // The pinned documents whose messages are NOT in the window, as a footer.
    // A document somebody pinned is a document they said matters past the
    // moment it arrived, and the window ages out in a fortnight.
    final pinnedLines = await _pinnedRecapLines(storylineId, rows);
    // What the projects linked to this storyline ARE, as a second footer.
    final directoryLines = await _directoryRecapLines(storylineId);

    final result = await runTask(
      _client,
      const StorylineRecapTask(),
      RecapInput(
        title: storyline.title,
        charter: storyline.charter ?? '',
        previousRecap: storyline.recapText ?? '',
        // Reversed into chronological order: the model is being asked where
        // things stand at the END of the sequence, and a sequence read
        // backwards ends at the oldest message.
        messageLines: [
          for (final row in rows.reversed)
            _recapLine(
              row,
              digests[_windowKey(row)] ?? const [],
            ),
          ...pinnedLines,
          ...directoryLines,
        ],
      ),
      // Zero, like every other storyline call: the same window recapped twice
      // must read the same, or a re-run after a park would rewrite the block
      // a user is looking at for no reason they could see.
      temperature: 0,
      // Named rather than left to `runTask`'s generic ceiling: the task
      // measured what a recap actually costs, so the budget is the task's.
      maxTokens: StorylineRecapTask.maxTokens,
    );

    // A model with nothing to say must not blank a good recap: the stored text
    // and both lists stand, which is a far better failure than a storyline
    // screen that went empty because one call came back thin.
    //
    // The watermark still moves, and it is not claiming the recap covers these
    // messages — it records that the model was ASKED about this window and
    // declined it. Without the stamp the sweep's catch-up finds the same
    // storyline stale on every single sync and re-dials the 27B, at
    // temperature zero, over the same window, for an answer that cannot come
    // back different. The next message to land moves the window, and a
    // different window is a different question — which is exactly when asking
    // again is worth a call.
    if (result.recap.isEmpty) {
      await _store.updateStoryline(storylineId, recapThrough: newestSeen);
      return;
    }

    await _store.updateStoryline(
      storylineId,
      recapText: result.recap,
      recapOpenJson: jsonEncode(result.openItems),
      recapDecisionsJson: jsonEncode(result.decisions),
      // The PRE-call watermark, for the reason the refresh stamps its pre-call
      // hash: a message that landed while the model was thinking is a message
      // this recap never read, and stamping what is true NOW would claim
      // otherwise — the gate above would then read as fresh and that message
      // would never be recapped. Stamping the older value leaves the pass
      // stale, which re-fires it.
      recapThrough: newestSeen,
    );
  }

  /// One stored message as the recap prompt reads it: which thread it is on,
  /// who said it, and what they said.
  ///
  /// `[subject] sender: text`, and no timestamp — the window is already in
  /// order, and a date in every line is a date the model can misattribute in a
  /// prompt whose strictest rule is to invent none.
  ///
  /// The subject bracket is dropped entirely when there is none, rather than
  /// rendered empty. A chat has no subject and its conversation may have no
  /// topic either; `[]` would tell the model a thread name was missing rather
  /// than that this one has none — the same distinction `buildMessageBlock`
  /// draws by omitting the `Subject:` line for chats.
  ///
  /// The owner's own messages are `You`, exactly as the triage prompt's thread
  /// tail renders them. It is the cheapest way to answer the question the
  /// recap most has to get right: a thread whose last word is the reader's is
  /// a thread nobody is waiting on them for.
  static String _recapLine(
    Map<String, Object?> row,
    List<Map<String, Object?>> digests,
  ) {
    final subject = stripReFw(row['subject'] as String?);
    final sender = row['direction'] == 'outbound'
        ? 'You'
        : (row['from_name'] as String? ?? '');
    final preview = row['body_preview'] as String?;
    final body = (preview != null && preview.isNotEmpty)
        ? preview
        : (row['body_text'] as String? ?? '');
    // Markers out, for [buildMessageBlock]'s reason: a recap window is quoted
    // text, and a `[[att:…]]` in it is a token nobody typed.
    final text = stripAttachmentMarkers(body);
    return '${subject.isEmpty ? '' : '[$subject] '}$sender: '
        '${text.length > _recapLineCap ? text.substring(0, _recapLineCap) : text}'
        '${_attachmentSuffix(digests)}';
  }

  /// What the documents on ONE message say, appended to its line.
  ///
  /// The FACTS and not the summary, because a recap's job is to carry the
  /// figures and dates a person would otherwise reopen the file for — "the
  /// quote came in" is already what the message line says, and "at 48,200,
  /// valid 30 days" is what it cannot say.
  ///
  /// A document with no facts contributes nothing rather than an empty
  /// bracket: the message line already announces that a file arrived.
  ///
  /// The angle brackets are the app's own punctuation and the text inside them
  /// is the model's, which is why the cap clamps the INNER text — a suffix cut
  /// at [_recapAttachmentCap] with its closing ⟩ lopped off would read as an
  /// unterminated aside for the rest of the window.
  static String _attachmentSuffix(List<Map<String, Object?>> digests) {
    final buffer = StringBuffer();
    for (final row in digests) {
      final digest = decodeAttachmentDigest(row['digest_json'] as String?);
      if (digest == null || digest.facts.isEmpty) continue;
      final name = (row['name'] as String?)?.trim() ?? '';
      buffer.write(
        ' ⟨${_clampInner('attached ${name.isEmpty ? 'a file' : name}: '
            '${digest.facts.join('; ')}')}⟩',
      );
    }
    return buffer.toString();
  }

  /// What each project linked to this storyline IS, one line each.
  ///
  /// A footer for the pins' reason and not an interleaved line: the window is
  /// a chronology, and a registered folder did not happen on a date. It sits
  /// after the pins because it is the broadest thing in the prompt — the
  /// project the whole story is inside.
  ///
  /// The brief's `about` and not its facts or its guidance. `about` is the
  /// sentence that says what the project IS, which is the only thing a recap
  /// needs from it; the facts are for a reply that has to be correct about a
  /// number, and standing reply guidance has nothing to say to a summary
  /// nobody sends.
  ///
  /// A linked directory with no brief contributes NOTHING, rather than its
  /// name alone. A brief is written the first time anything reads the folder,
  /// so no brief means nothing has been read yet, and a bare name in a prompt
  /// is a word the model would have to guess the meaning of.
  Future<List<String>> _directoryRecapLines(String storylineId) async {
    final context = _context;
    if (context == null) return const [];
    final lines = <String>[];
    for (final dirId in await context.dirIdsLinkedTo(
      ContextScopeKind.storyline,
      // A storyline's ids are already global, so the connector half of a link
      // is empty for every one of them.
      '',
      storylineId,
    )) {
      final dir = await context.directory(dirId);
      final about = ContextBrief.decode(dir?.briefJson)?.about.trim() ?? '';
      if (dir == null || about.isEmpty) continue;
      lines.add('⟨${_clampInner('directory ${dir.displayName}: $about')}⟩');
    }
    return lines;
  }

  /// The documents pinned to this storyline whose messages the window does not
  /// already carry.
  ///
  /// A footer rather than an interleaved line, and after every message line:
  /// the window is chronological and a pin has no place in that order — it is
  /// the reader saying "and this file, whenever it arrived". The summary and
  /// not the facts here, because a pinned document is usually being named for
  /// what it IS rather than for a figure in it.
  ///
  /// A pin whose message IS in the window is skipped: its own line already
  /// carries the facts, and saying it twice is how a recap starts reading as
  /// though two things happened.
  Future<List<String>> _pinnedRecapLines(
    String storylineId,
    List<Map<String, Object?>> window,
  ) async {
    final inWindow = {for (final row in window) _windowKey(row)};
    final lines = <String>[];
    for (final row in await _store.pinnedAttachmentsForStoryline(storylineId)) {
      if (inWindow.contains(_windowKey(row))) continue;
      final name = (row['name'] as String?)?.trim() ?? '';
      final summary =
          decodeAttachmentDigest(row['digest_json'] as String?)?.summary ?? '';
      final label = 'pinned ${name.isEmpty ? 'a file' : name}'
          '${summary.isEmpty ? '' : ': $summary'}';
      lines.add('⟨${_clampInner(label)}⟩');
    }
    return lines;
  }

  /// The digested attachments of every message in the window, keyed
  /// `source|source_message_id`.
  ///
  /// One query per distinct source, which in practice is one or two. Never
  /// filtered by direction: the window carries the owner's own messages on
  /// purpose (they are what says nobody is waiting), and the quote the owner
  /// sent is exactly as much of the story as the one they received.
  Future<Map<String, List<Map<String, Object?>>>> _digestsForWindow(
    List<Map<String, Object?>> rows,
  ) async {
    final bySource = <String, List<String>>{};
    for (final row in rows) {
      final source = row['source'] as String? ?? '';
      final id = row['source_message_id'] as String? ?? '';
      if (source.isEmpty || id.isEmpty) continue;
      (bySource[source] ??= []).add(id);
    }
    final digests = <String, List<Map<String, Object?>>>{};
    for (final entry in bySource.entries) {
      final found = await _store.digestsForMessages(entry.key, entry.value);
      found.forEach((id, attachments) {
        digests['${entry.key}|$id'] = attachments;
      });
    }
    return digests;
  }

  /// How a window row and a pinned row name the same message. `source` alone
  /// is not an identity — a mail id and a chat id are the same alphabet.
  static String _windowKey(Map<String, Object?> row) =>
      '${row['source']}|${row['source_message_id']}';

  /// One attachment aside, clamped. See [_attachmentSuffix] for why the clamp
  /// is inside the brackets rather than around them.
  static String _clampInner(String text) => text.length > _recapAttachmentCap
      ? text.substring(0, _recapAttachmentCap)
      : text;

  /// How much of one document reaches a recap line. Short on purpose: a dozen
  /// message lines with a document apiece still has to fit under
  /// [StorylineRecapTask]'s window cap alongside the messages themselves, and
  /// the aside is a pointer to the file rather than a substitute for it.
  static const int _recapAttachmentCap = 160;

  /// How much of one message reaches the recap. A dozen of these has to fit
  /// under [StorylineRecapTask]'s window cap with the thread names and the
  /// senders, and a preview is what a person skimming their inbox sees — past
  /// that it is quoted thread and signature.
  static const int _recapLineCap = 400;

  /// The first description: the same naming call a fresh cluster gets.
  ///
  /// Returns the charter it wrote, or null when it wrote none.
  ///
  /// The cards are numbered the same way the sweep numbers them, so the
  /// prompt's sentence about threads "as listed in [brackets]" is true here
  /// too. What comes back in `coherent` and `outliers` is IGNORED by design: a
  /// storyline a person made by hand is not the sweep's to split, and a model
  /// told to find the odd thread out will always find one.
  Future<String?> _bootstrapDescription(
    String storylineId,
    List<String> cards,
  ) async {
    final result = await runTask(
      _client,
      const NameStorylineTask(),
      NameInput(_numberedCards(cards)),
      temperature: 0,
    );

    // Re-read before writing: the naming call takes seconds, and a user who
    // renamed the storyline or saved a charter while it ran has set a lock
    // this pass must honor. Deciding from the pre-call snapshot would
    // overwrite their text with the model's — and leave the lock set, so no
    // later pass would ever re-draft over the damage.
    final fresh = await _store.getStoryline(storylineId);
    if (fresh == null) return null;

    await _store.updateStoryline(
      storylineId,
      // A locked title is the user's, and no later pass may take it back. The
      // summary is refreshed either way — it describes where the storyline
      // stands, which is not something a rename claimed ownership of.
      title: fresh.titleLocked ? null : result.title,
      summary: result.summary,
    );

    // A separate, conditional write: a locked charter is the user's, the same
    // contract `title_locked` gives the title. An empty answer is not written
    // either — a storyline whose charter was never drafted is judged against
    // its summary, which is strictly better than judging it against nothing.
    if (fresh.charterLocked || result.charter.isEmpty) return null;
    await _store.updateStoryline(storylineId, charter: result.charter);
    return result.charter;
  }

  /// The re-description: what it says today, what is in it now, and what
  /// joined — with the smallest change that makes those agree.
  ///
  /// Returns the charter it wrote to the CHARTER COLUMN, or null. A suggestion
  /// parked for a locked charter is not a write: it changes nothing anything
  /// else reads, and until the user accepts it no membership question is
  /// judged differently.
  Future<String?> _evolveDescription(
    String storylineId,
    Storyline storyline,
    List<String> cards,
    int newCount,
    List<String> removedCards,
  ) async {
    final result = await runTask(
      _client,
      const RefineStorylineTask(),
      RefineInput(
        currentTitle: storyline.title,
        currentSummary: storyline.summary ?? '',
        currentCharter: storyline.charter ?? '',
        titleLocked: storyline.titleLocked,
        charterLocked: storyline.charterLocked,
        memberCards: cards,
        addedCards: cards.sublist(cards.length - newCount),
        removedCards: removedCards,
      ),
      // Zero, like every other storyline call: the same members described
      // twice must come back the same, or a re-run after a park would rewrite
      // a title for no reason a user could see.
      temperature: 0,
    );

    // The same post-call re-read the first draft makes, for the same reason:
    // a lock set while the model was thinking is the newer fact.
    final fresh = await _store.getStoryline(storylineId);
    if (fresh == null) return null;

    // Each field written on its own terms. An empty answer is the model
    // declining to change that field, and what is stored stands — this is why
    // the refresh validator has no placeholder title where the naming one
    // does.
    if (!fresh.titleLocked &&
        result.title.isNotEmpty &&
        result.title != fresh.title) {
      await _store.updateStoryline(storylineId, title: result.title);
    }
    if (result.summary.isNotEmpty) {
      await _store.updateStoryline(storylineId, summary: result.summary);
    }

    if (!fresh.charterLocked) {
      if (result.charter.isEmpty) return null;
      // The suggestion is cleared with the same write. A directory's brief can
      // park an offer against a blank unlocked charter, and this pass has just
      // written the sentence that offer was proposing to fill in — leaving it
      // would ask the person to accept a suggestion for a charter that now
      // exists and that they never asked to replace.
      await _store.updateStoryline(
        storylineId,
        charter: result.charter,
        charterSuggestion: null,
      );
      return result.charter;
    }

    // Locked: the model's charter is an offer, not a write. Compared
    // normalized, because a model that echoes the user's sentence back with
    // different spacing is agreeing with it, and offering a person their own
    // words as an update is noise. Nothing to offer also CLEARS — a suggestion
    // parked against an older member set is stale the moment this pass decides
    // the charter already fits.
    final suggestion = result.charter;
    final stale = suggestion.isEmpty ||
        _normalized(suggestion) == _normalized(fresh.charter ?? '');
    await _store.updateStoryline(
      storylineId,
      charterSuggestion: stale ? null : suggestion,
    );
    return null;
  }

  /// How many of the member cards, in membership order, the last description
  /// never saw.
  ///
  /// An approximation, and deliberately one. Nothing carries provenance to the
  /// refresh: `payload_json` is NULL on every requeued row (a queue that
  /// remembered which thread woke it would answer for a drain that already
  /// coalesced ten of them), so the only facts available are how many members
  /// there were when the description was written and the order the members
  /// were added in. The newest N by `added_at` stand in for "the ones that
  /// joined", which is exactly right unless a removal happened in between, and
  /// then it is a smaller N — never a wrong slice.
  ///
  /// Clamped both ends: an unknown or larger previous count means nothing is
  /// KNOWN to be new, and the answer can never exceed the cards in hand, since
  /// a member whose conversation row is gone contributes no card.
  static int _newSince(int? describedCount, int memberCount, int available) {
    if (describedCount == null) return 0;
    final grown = memberCount - describedCount;
    if (grown <= 0) return 0;
    return grown > available ? available : grown;
  }

  /// Offers a directory's brief as the charter of every storyline linked to
  /// it. Returns how many were written.
  ///
  /// The SECOND source of a charter suggestion, beside the refresh pass, and
  /// it answers a question the refresh cannot: the refresh reads the member
  /// threads and says what they have in common, where a project's `about` says
  /// what the owner set out to do. A storyline linked to a folder the person
  /// registered is a storyline whose subject already has a written definition.
  ///
  /// Three rules decide who gets one, and every other state is left alone:
  ///
  /// 1. **No charter and not locked** — the suggestion is offered.
  /// 2. **Locked with no suggestion parked** — offered. A lock says the
  ///    stored sentence is the person's own; it does not say they never want
  ///    to hear another idea.
  /// 3. **Locked with a suggestion already parked** — untouched. They have
  ///    not answered the first offer, and replacing it would lose an idea they
  ///    were still looking at.
  ///
  /// An unlocked storyline that HAS a charter is the refresh pass's business
  /// and not this one's — that sentence moves with the member set, and a
  /// directory link is not a change to who is in the group.
  ///
  /// The write is a SUGGESTION even onto an empty charter, and that is the
  /// rule this method exists to keep. A charter is the membership criteria:
  /// [recruitForCharter] hunts the mailbox on it, and threads get filed under
  /// it. A sentence a model lifted out of a `CLAUDE.md` that the person has
  /// never read must not start recruiting threads on their behalf — Use this
  /// is one tap, and it is the tap that makes it theirs.
  Future<int> offerDirectoryCharters(String dirId) async {
    final context = _context;
    if (context == null) return 0;
    final dir = await context.directory(dirId);
    final about = ContextBrief.decode(dir?.briefJson)?.about.trim() ?? '';
    if (about.isEmpty) return 0;

    var offered = 0;
    for (final link in await context.linksFor(dirId)) {
      if (link.scopeKind != ContextScopeKind.storyline) continue;
      final storyline = await _store.getStoryline(link.scopeKey);
      // Dismissed or gone between the link and the brief. Neither renders a
      // charter, so neither can be offered one.
      if (storyline == null) continue;
      if (storyline.status != 'active' && storyline.status != 'suggested') {
        continue;
      }
      // Normalized, on the refresh's rule: the same sentence with different
      // spacing is the sentence they already have.
      if (_normalized(about) == _normalized(storyline.charter ?? '')) continue;

      final blank = (storyline.charter ?? '').trim().isEmpty;
      final offerable = (blank && !storyline.charterLocked) ||
          (storyline.charterLocked && storyline.charterSuggestion == null);
      if (!offerable) continue;

      await _store.updateStoryline(link.scopeKey, charterSuggestion: about);
      offered++;
    }
    return offered;
  }

  // ── automatic: one storyline, on the user's charter ────────────────────

  /// Hunts for member threads the assignment pass missed, against a charter
  /// the user just wrote. Queued only by [setCharter] — this is the model
  /// answering an edit, not a pass that runs on its own.
  ///
  /// The same funnel as [assignConversation] turned inside out: one storyline,
  /// every embedded thread as a candidate. The gate is the LOWER assignment
  /// gate for every candidate, overlap or not — the user's charter is a
  /// stronger invitation to look than a shared participant is — and the top
  /// [StorylineTuning.recruitMaxCandidates] by cosine each get the same
  /// confirmation call a normal assignment gets, against that charter.
  ///
  /// It hunts until the charter stops moving under it — see the loop below for
  /// why a save that lands mid-hunt has no other way of being noticed.
  Future<void> recruit(String storylineId) async {
    final found = await _store.getStoryline(storylineId);
    // Dismissed between the save and the drain. Recruiting into it would
    // resurrect a group the user threw away, silently.
    if (found == null ||
        (found.status != 'active' && found.status != 'suggested')) {
      return;
    }
    var storyline = found;

    // The hunt runs again when the charter it hunted with is no longer the
    // charter on the row. `requeueWork` cannot cover this one: a save that
    // lands while this pass is running enqueues against its OWN `processing`
    // row and is swallowed, and unlike the refresh and the recap there is no
    // sweep catch-up to find it later — nothing durable records that a
    // charter was never hunted with. So the pass carries its own wakeup.
    //
    // Bounded by the user, not by the model: an extra lap happens only when a
    // save landed DURING the previous one, and at temperature zero a lap with
    // no save in it would ask the same questions of the same threads and get
    // the same answers. Membership only grows, so each lap has fewer
    // candidates left to consider than the last.
    bool charterMoved;
    do {
      // What this lap is hunting with, kept so the bottom can tell whether it
      // is still what the row says.
      final charterUsed = _normalized(storyline.charter ?? '');

      final context = await _memberContext(storylineId);
      final centroid = context.centroid;
      if (centroid == null) {
        // No member vectors means no ranking. The all-zero note is quiet on
        // purpose — the log's quiet-kind check suppresses it as the genuine
        // nothing it is (see the note at the end of this method).
        _log.note({'recruited': 0, 'considered': 0});
        return;
      }

      // One read of the blocks, not one per candidate. The loop below walks
      // every embedded thread in the mailbox, and the user is sitting in front
      // of the charter they just saved waiting for this pass — a query per
      // thread turned that wait into a function of mailbox size. Same set, same
      // gate, same order.
      final blocked = await _store.blockedThreadsOf(storylineId);

      // Everything this lap could still consider, in the store's own order:
      // not a member, not blocked, and carrying a readable vector.
      final candidates =
          <({Map<String, Object?> row, List<double> vector})>[];
      for (final row in await _store.conversationsWithEmbeddings(
        embedModel: EmbeddingsClient.modelTag,
        sources: _sources,
      )) {
        final key = row['conversation_key'] as String? ?? '';
        if (key.isEmpty) continue;
        final rowSource = row['source'] as String? ?? _workSource;
        final thread = _threadKey(rowSource, key);
        if (context.memberThreads.contains(thread)) continue;
        if (blocked.contains(thread)) continue;
        final blob = row['embedding'];
        if (blob is! Uint8List) continue;
        final vector = decodeEmbedding(blob);
        if (vector.isEmpty) continue;
        candidates.add((row: row, vector: vector));
      }
      // Scored, then top-N — [_shortlist], the same recipe the sweep's probe
      // runs over the finished threads.
      final considered = _shortlist(
        candidates,
        centroid,
        gate: StorylineTuning.assignCosineGateWithOverlap,
        take: StorylineTuning.recruitMaxCandidates,
      );

      // One snapshot for every candidate: the storyline as the user saved it is
      // what all eight are judged against, not a group that grows under the
      // later candidates as the earlier ones land.
      final storylineParticipants = await _participantsOfStoryline(storylineId);
      // And one read of the owner's examples, for the same reason and one
      // more: they are the constant prefix of all eight prompts, so fetching
      // them per candidate would buy queries and change nothing.
      final examples = await _examplesFor(storylineId);

      var recruited = 0;
      for (final candidate in considered) {
        final row = candidate.row;
        final rowSource = row['source'] as String? ?? _workSource;
        final key = row['conversation_key'] as String? ?? '';
        final cardData = await _store.newestInboundCardData(rowSource, key);

        final result = await _confirm(
          storyline,
          storylineParticipants,
          row,
          cardData,
          examples: examples,
        );
        if (!_accepts(result, storyline)) continue;

        await _store.addStorylineMember(
          storylineId,
          rowSource,
          key,
          addedBy: 'auto',
          evidence: result.evidence,
        );
        final lastMessageAt = row['last_message_at'] as String?;
        if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
          await _store.touchStorylineActivity(storylineId, lastMessageAt);
        }
        // In the same breath as the membership write, like every other add
        // path: a park on a later candidate must not leave the hash describing
        // a set that no longer exists. At most eight extra writes.
        await _store.updateStoryline(
          storylineId,
          memberHash: await _memberHashOf(storylineId),
          // Cleared with the hash, for the reason spelled out in
          // [assignConversation]: this thread's messages may all predate the
          // mark, and a mark taken over the old members must not gate the
          // recap over the new ones.
          recapThrough: null,
        );
        recruited++;
      }

      // A recruit that filed anything changed what this storyline is, and the
      // description was written against the smaller group. Queued rather than
      // called: the refresh handler is registered BEFORE this one, so the row
      // waits for the next pump — a deliberate damper on the one cycle these
      // two passes could form, since a refresh that widens a charter queues a
      // recruit right back.
      if (recruited > 0) {
        await _store.requeueWork('storyline_refresh', _workSource, storylineId);
      }
      // Always, zeroes included — the log is what decides what a person sees.
      // "Recruited 0 of 5" survives its quiet-kind check and shows: the model
      // was consulted and said no, which is an answer. An all-zero pass is
      // suppressed there as the genuine nothing it is.
      _log.note({'recruited': recruited, 'considered': considered.length});

      final fresh = await _store.getStoryline(storylineId);
      // Dismissed while the hunt ran — the same judgement as the guard at the
      // top, asked again because a whole pass has gone by since.
      if (fresh == null ||
          (fresh.status != 'active' && fresh.status != 'suggested')) {
        return;
      }
      charterMoved = _normalized(fresh.charter ?? '') != charterUsed;
      if (charterMoved) storyline = fresh;
    } while (charterMoved);
  }

  // ── automatic: one storyline, on the owner's removal ───────────────────

  /// Re-checks a storyline's AUTOMATIC members against its charter and the
  /// owner's examples. Queued by [removeThread] and by the About section's
  /// "Re-check members"; runs after the refresh that a removal also queues
  /// (handler order), so it judges against the narrowed charter.
  ///
  /// Members the owner filed by hand are never audited: their membership is
  /// the owner's word. A rejected member is removed WITH a block whose
  /// `blocked_by = 'audit'` and whose evidence is the audit's own reason —
  /// unblocked, the recruit the refresh just woke would file it straight back.
  /// Idempotent: a run that removes nothing writes nothing and queues nothing;
  /// it still notes what it checked, the way the recruit notes a lap that
  /// filed nothing — and a pass that reached no model at all says nothing,
  /// because `storyline_audit` is quiet-listed and every value it notes is
  /// then a zero.
  ///
  /// Every removal carries its own bookkeeping, [recruit]'s recipe exactly:
  /// the member hash, the recap pointer and the thread's own storyline stamp
  /// are written with the removal that caused them rather than after the loop.
  /// A model server that goes away mid-pass parks the whole item, and a
  /// storyline whose hash still described members that are gone would be left
  /// behind by that park. The two requeues at the end are the exception, and
  /// they are safe to lose: the next sync's hash catch-up finds a storyline
  /// whose members moved.
  Future<void> audit(String storylineId) async {
    final storyline = await _store.getStoryline(storylineId);
    // Dismissed between the removal and the drain. Re-judging it would spend a
    // call per member on a group nothing renders.
    if (storyline == null ||
        (storyline.status != 'active' && storyline.status != 'suggested')) {
      return;
    }

    // Everything the model put here, and nothing the owner did. `addedByUser`
    // rather than an equality against `'auto'`: any provenance that is not the
    // owner's own hand is the app's, and the app's work is what this re-reads.
    final auto = [
      for (final member in await _store.membersOf(storylineId))
        if (!member.addedByUser) member,
    ];
    if (auto.isEmpty) return;

    // One snapshot for every member, [recruit]'s recipe exactly: all of them
    // are judged against the group as it stood when the pass began, not
    // against one that shrinks under the later questions as the earlier
    // members are removed out from under them.
    final participants = await _participantsOfStoryline(storylineId);
    final examples = await _examplesFor(storylineId);

    final removed = <Map<String, Object?>>[];
    var checked = 0;
    for (final member in auto) {
      final row = await _store.getConversationRow(
        member.source,
        member.conversationKey,
      );
      // A member whose conversation row is gone has no card to judge. Left
      // alone rather than removed: nothing about it is known to be wrong, and
      // the refresh already treats such a member as contributing no card.
      if (row == null) continue;
      final cardData = await _store.newestInboundCardData(
        member.source,
        member.conversationKey,
      );

      final result = await _confirm(
        storyline,
        participants,
        row,
        cardData,
        examples: examples,
      );
      checked++;
      // The kept members are the accepted ones; everything [_accepts] turns
      // down goes, which is this pass's whole job.
      if (_accepts(result, storyline)) continue;

      // Blocked, not merely removed. The recruit handler runs AFTER this one,
      // so an unblocked removal would be re-filed in the same drain, by a pass
      // reading the same charter this one just judged against.
      await _store.removeStorylineMember(
        storylineId,
        member.source,
        member.conversationKey,
        block: true,
        blockedBy: 'audit',
        evidence: result.evidence,
      );
      removed.add({
        'source': member.source,
        'conversation_key': member.conversationKey,
        'subject': row['subject'],
        'evidence': result.evidence,
      });

      // The bookkeeping belongs to THIS removal and rides with it, because the
      // loop can be interrupted at any await — the next member's call finding
      // no server parks the whole pass — and a storyline left describing
      // members that are gone is worse than one that shrank halfway. The hash
      // and the recap pointer are the storyline's own record; the stamp is the
      // per-thread one the feed and the hot strip read, which know nothing
      // about member rows and would otherwise still show the thread as filed.
      await _store.updateStoryline(
        storylineId,
        memberHash: await _memberHashOf(storylineId),
        // Cleared with the hash, for the reason spelled out in
        // [assignConversation].
        recapThrough: null,
        // The recap goes too, for the reason [removeThread] spells out: the
        // recap pass carries the previous recap forward and cannot tell which
        // of its sentences came from the member this pass just took out. Only
        // a removal does this — an addition leaves the recap standing.
        recapText: null,
        recapOpenJson: null,
        recapDecisionsJson: null,
      );
      _progress.noteStorylineLink(
        member.source,
        await _store.stampStorylineId(
          member.source,
          member.conversationKey,
          clearingStorylineId: storylineId,
        ),
      );
      await _stampPointer(member.source, member.conversationKey);
    }

    // Noted onto the worker's row rather than recorded as a row of its own,
    // the recruit's convention: the audit runs only inside a drain, and a
    // `record` here would leave the worker writing a second, empty row for
    // the same item. `checked` is what keeps a "removed nothing" pass
    // visible — the model was consulted and said keep, which is an answer;
    // the kind is quiet-listed so a pass that reached no model says nothing.
    _log.note({'checked': checked, if (removed.isNotEmpty) 'removed': removed});

    // Nothing moved, so nothing is queued. The common ending: a storyline the
    // owner corrected once usually holds together.
    if (removed.isEmpty) return;

    // Both passes, and in this order. The title, the summary and the charter
    // describe a group that is now smaller, so the refresh has to follow the
    // members rather than wait for the next sync to notice the hash moved; the
    // recap was written against the same larger group.
    await _store.requeueWork('storyline_refresh', _workSource, storylineId);
    await _store.requeueWork('storyline_recap', _workSource, storylineId);
  }

  // ── automatic: the whole mailbox ───────────────────────────────────────

  /// Proposes new storylines out of whatever is not in one yet.
  ///
  /// Runs after every sync of either connector, and is a no-op nearly every
  /// time: it does nothing while suggestions are already waiting, nothing when
  /// there is too little unassigned conversation to group, and nothing when
  /// the clusters it finds have all been dismissed before.
  ///
  /// A cluster is a shortlist, not a decision. Each one is named, and then
  /// every thread in it is confirmed against that name individually — the same
  /// question [assignConversation] asks — so a group that merely embeds alike
  /// cannot ship as a storyline.
  ///
  /// Mail and chat are clustered together, in one pool. A thread and a chat
  /// about the same launch are one story, and the pass that cannot see both
  /// would propose the half it can.
  ///
  /// Finished threads join but never seed. They are kept out of the clustering
  /// — a storyline built from done mail is a pile of history nobody asked for
  /// — and handed instead to the probe at the end of [_propose], which offers
  /// the closest of them to a storyline this pass just gave birth to. Without
  /// that, a thread marked done on Monday could never be part of a story that
  /// formed on Tuesday, while [recruit] has always been free to find it.
  Future<void> sweep() async {
    // Before the early returns, not after them, and that placement is the
    // whole point: this heals refreshes that were LOST, and the sweep returns
    // early on nearly every pass — there is usually no room and usually
    // nothing unassigned to cluster. `requeueWork` revives only `done` and
    // `error` rows, so a refresh queued while an earlier one was `processing`
    // vanishes, and every other trigger fires on an event that has already
    // gone by. Asking the durable question once per sync is what makes "the
    // description eventually matches the members" true rather than likely.
    // Costs one query and, on a mailbox where nothing moved, nothing else.
    for (final id in await _store.staleRefreshStorylineIds()) {
      await _store.requeueWork('storyline_refresh', _workSource, id);
    }

    // The same heal for the recap, and it has more to fix than the refresh
    // does. The recap's other triggers all fire on a message arriving, so a
    // storyline that is already described and has had no new mail reaches
    // none of them — which is every storyline the v10 backfill called
    // described, none of which has ever been recapped, plus any recap wakeup
    // a `processing` row swallowed. The recap handler drains AFTER this one,
    // so what is queued here runs in the same pass.
    for (final id in await _store.staleRecapStorylineIds()) {
      await _store.requeueWork('storyline_recap', _workSource, id);
    }

    final pending =
        (await _store.loadStorylines(statuses: const ['suggested'])).length;
    final room = StorylineTuning.maxPendingSuggestions - pending;
    if (room <= 0) return;

    // Asked per source and unioned as [_threadKey] composites, because source
    // and key together are what identifies a thread. The two connectors mint
    // their keys with no knowledge of each other, and a flat set of bare keys
    // let a chat that was already filed away — or one the user had pulled out
    // of a storyline — hide an unrelated mail thread that happened to share
    // its key from every sweep that ever ran.
    final taken = {
      for (final source in _sources)
        for (final key in await _store.assignedOrBlockedKeys(source))
          _threadKey(source, key),
    };
    final rows = <Map<String, Object?>>[];
    final vectors = <List<double>>[];
    // The finished threads this pass may OFFER but never group — see the
    // divert below, and [_propose]'s probe for what becomes of them.
    final doneCandidates = <({Map<String, Object?> row, List<double> vector})>[];
    for (final row in await _store.conversationsWithEmbeddings(
      embedModel: EmbeddingsClient.modelTag,
      sources: _sources,
    )) {
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty) continue;
      final rowSource = row['source'] as String? ?? _workSource;
      // Before the divert, deliberately: a thread already filed into a
      // storyline, or one the user pulled out of one, is not on offer to a new
      // storyline either.
      if (taken.contains(_threadKey(rowSource, key))) continue;
      final blob = row['embedding'];
      if (blob is! Uint8List) continue;
      final vector = decodeEmbedding(blob);
      if (vector.isEmpty) continue;
      // A finished thread is not the start of a story. Grouping done mail
      // would fill the rail with history nobody asked to be reminded of — so
      // it is diverted rather than discarded: it may JOIN a storyline born in
      // this pass, it just never seeds one. Diverted rows count toward
      // neither the unassigned floor below nor the clustering, which is what
      // keeps "never seeds one" true rather than nearly true.
      if ((row['state'] as String?) == 'done') {
        doneCandidates.add((row: row, vector: vector));
        continue;
      }
      rows.add(row);
      vectors.add(vector);
    }

    if (rows.length < StorylineTuning.sweepMinUnassigned) return;

    // The subject, before the geometry. A recurring series reads as one thing
    // to a person and as nothing in particular to an embedding, and the two
    // answers it needs are opposite: a series somebody takes part in is a
    // storyline the cosine pass would never have found, and a series nobody
    // has ever answered is a notification feed that must not be named at all.
    final series = _seriesOf(rows);

    // What is left for the cosine clustering: everything the pre-pass neither
    // seeded nor excluded. The indexes the clustering returns are into THIS
    // list, so they are mapped back through [poolIndexes] before anything
    // reads `rows`.
    final seeded = {for (final group in series.seeded) ...group};
    final poolIndexes = [
      for (var i = 0; i < rows.length; i++)
        if (!seeded.contains(i) && !series.excluded.contains(i)) i,
    ];
    final poolRows = [for (final index in poolIndexes) rows[index]];
    final poolVectors = [for (final index in poolIndexes) vectors[index]];

    // Pair-discovery, on the index when there is one and in Dart when there is
    // not. The two answers are the same clusters either way — see
    // [_indexedSimilarities] — so nothing below this line knows which ran.
    //
    // Skipped outright under two rows. `clusterBySimilarity` handles a count
    // of 0 and 1 perfectly well, but a pool that small cannot produce a
    // cluster of [StorylineTuning.proposeMinClusterSize] and the index probe
    // is a query, so the guard is here rather than relied on there.
    final cosineClusters = poolRows.length < 2
        ? const <List<int>>[]
        : await _clusterCandidates(poolRows, poolVectors);

    // Series first, in the order [_seriesOf] produced them, then the cosine
    // clusters in the order the clustering returned them (largest first). The
    // order is what `room` is spent in, and it is a pure function of the
    // store's order either way, which is what the tombstones rest on.
    final clusters = <List<int>>[
      ...series.seeded,
      for (final cluster in cosineClusters)
        [for (final index in cluster) poolIndexes[index]],
    ];
    final seriesSeeded = series.seeded.length;
    final seriesExcluded = series.excluded.length;

    // Room is spent on PROPOSALS, not on clusters considered: the pass is
    // deterministic and largest-first, so a dismissed cluster that merely
    // consumed a slot would consume that same slot on every future sweep and
    // permanently starve the genuinely new clusters ranked behind it.
    var proposed = 0;
    var confirmed = 0;
    var rejected = 0;
    var joined = 0;
    var attempted = 0;
    // The three the namer decides: a cluster it refused, a cluster the charter
    // lint refused, and the individual threads it named as not belonging.
    var incoherent = 0;
    var lintRejected = 0;
    var outliersDropped = 0;
    // The taken-set of this pass, growing as it runs. `taken` above was read
    // before any of these storylines existed, and the same `doneCandidates`
    // list is offered to every proposal — so without this, a finished thread
    // sitting between two newborn clusters could be offered to both and join
    // both, which is a state no other automatic path can produce: the
    // assignment pass files a thread into its single best storyline, and the
    // sweep's own taken-set keeps it out of the pool afterwards.
    final claimedByProbe = <String>{};
    for (final cluster in clusters) {
      if (proposed >= room) break;
      final tally = await _propose(
        [for (final index in cluster) rows[index]],
        [for (final index in cluster) vectors[index]],
        doneCandidates: doneCandidates,
        claimedByProbe: claimedByProbe,
      );
      attempted++;
      if (tally.proposed) proposed++;
      // Summed across every cluster the pass named, the tombstoned ones
      // included: the model's rejections are work it did and an answer it
      // gave, and a cluster that was thrown out entirely is the most
      // interesting row this pass can write.
      confirmed += tally.confirmed;
      rejected += tally.rejected;
      // Kept apart from the two above on purpose: `confirmed` and `rejected`
      // count the CLUSTER's members being judged, and a finished thread the
      // probe pulled in was never part of the cluster.
      joined += tally.joined;
      incoherent += tally.incoherent;
      lintRejected += tally.lint;
      outliersDropped += tally.outliers;
    }

    // Once at the end, not once per proposal: the sweep is one unit of work
    // and gets one row, so a per-cluster note would just overwrite itself.
    // Zeroes included — the log decides what a person sees, and its
    // quiet-kind check is what suppresses the all-zero pass as the genuine
    // nothing it is. Skipped entirely when no cluster reached the model,
    // because then there is not even a tally to be zero about.
    if (attempted > 0 || seriesExcluded > 0) {
      _log.note({
        'proposed': proposed,
        'confirmed': confirmed,
        'rejected': rejected,
        // A number, always, and never a null or a string: the quiet-kind
        // check reads these as numerics, and a non-numeric here would make
        // every all-zero sweep loud again. That holds for the five below too,
        // `lint` included: the reason the lint gave is on the tombstone, and
        // what this row carries is how many there were.
        'joined': joined,
        'series': seriesSeeded,
        'series_excluded': seriesExcluded,
        'incoherent': incoherent,
        'lint': lintRejected,
        'outliers': outliersDropped,
      });
    }
  }

  /// The subject pre-pass: which pool rows are a recurring SERIES the sweep
  /// should seed as a cluster of its own, and which are a notification feed it
  /// should leave alone this pass.
  ///
  /// Pure over the row maps and O(n) over them, so it costs no query and adds
  /// nothing the clustering does not already walk. Grouping is by
  /// [seriesKeyFor] alone: a subject with every date, ticket id and number
  /// folded away. An empty key never groups — an unnamed thread has nothing in
  /// common with another unnamed thread.
  ///
  /// A group of at least [StorylineTuning.seriesMinSize] is a series, and then
  /// one question decides which kind. NOTIFICATION-SHAPED means every thread
  /// in it has been answered by nobody (`message_count - inbound_count == 0`,
  /// the conversation's own counters) AND one address sent the newest kept
  /// inbound message in all of them. That is a feed: a system writing to a
  /// mailbox, every issue looking like the last, which a naming call would
  /// happily describe as "vendor notifications" and a charter would then admit
  /// forever. Its rows leave the pool for this pass, noted rather than
  /// tombstoned, because nothing was asked of any model.
  ///
  /// Every other series is seeded: a recurring thing people take part in — a
  /// standup, an invoice run somebody replies to — which the cosine pass would
  /// never have found, because two issues of one series share a shape and not
  /// a subject matter. It goes through the same naming and the same confirms
  /// as any cluster, so a seed is a question and not a verdict.
  ///
  /// A seeded group is capped at [StorylineTuning.maxClusterSize] and takes
  /// the FIRST of its members in row order, which is the newest: the rest are
  /// neither seeded nor excluded, so they stay in the cosine pool and are
  /// there for a later pass.
  static ({List<List<int>> seeded, Set<int> excluded}) _seriesOf(
    List<Map<String, Object?>> rows,
  ) {
    // Insertion-ordered, and the rows are walked in order, so every group's
    // indexes ascend and the groups themselves come out in first-member
    // order. The sweep spends its room in that order, so it has to be a
    // function of the store's order and nothing else.
    final byKey = <String, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      final key = seriesKeyFor(rows[i]['subject'] as String?);
      if (key.isEmpty) continue;
      byKey.putIfAbsent(key, () => <int>[]).add(i);
    }

    final seeded = <List<int>>[];
    final excluded = <int>{};
    for (final group in byKey.values) {
      if (group.length < StorylineTuning.seriesMinSize) continue;
      if (_isNotificationShaped(rows, group)) {
        excluded.addAll(group);
        continue;
      }
      seeded.add(group.take(StorylineTuning.maxClusterSize).toList());
    }
    return (seeded: seeded, excluded: excluded);
  }

  /// Whether [group] is a feed rather than an effort: nobody in the mailbox
  /// has ever replied in any of these threads, and one address wrote the
  /// newest kept inbound message in every one of them.
  ///
  /// Both halves are required. A series nobody answered but several people
  /// wrote is a group of correspondents, not a broadcast; a series one address
  /// wrote and somebody answered is a conversation, whatever its subject looks
  /// like. A missing sender is a no, because an unknown address cannot be
  /// evidence that every issue came from one place.
  ///
  /// `inbound_count` must be positive as well, and that is the difference
  /// between unanswered and unknown. Both counters default to zero on a
  /// conversation nothing has recomputed, and `0 - 0 == 0` would read as
  /// "nobody replied" on a row that has never been counted — while the pool
  /// query has already proved the thread holds a kept inbound message, so zero
  /// inbound is stale rather than true. A stale row is not evidence of a feed.
  static bool _isNotificationShaped(
    List<Map<String, Object?>> rows,
    List<int> group,
  ) {
    String? sender;
    for (final index in group) {
      final row = rows[index];
      final messages = (row['message_count'] as int?) ?? 0;
      final inbound = (row['inbound_count'] as int?) ?? 0;
      if (inbound <= 0 || messages - inbound != 0) return false;
      final from =
          ((row['newest_kept_from'] as String?) ?? '').trim().toLowerCase();
      if (from.isEmpty) return false;
      if (sender == null) {
        sender = from;
      } else if (sender != from) {
        return false;
      }
    }
    return sender != null;
  }

  /// The clusters this sweep will consider, from whichever pair-discovery is
  /// available.
  ///
  /// The split is deliberate and narrow: measuring the pairs is the part an
  /// index can do faster, and forming the clusters out of them is the part
  /// whose determinism the tombstones depend on. So both paths build the same
  /// table of similarities and hand it to the same [_clusterBy], and the only
  /// thing that varies is who measured "how close are rows i and j".
  Future<List<List<int>>> _clusterCandidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    final table = await _indexedSimilarities(rows, vectors) ??
        _arithmeticSimilarities(vectors);
    return _clusterBy(vectors.length, table.get);
  }

  /// The clustering rule, with this app's numbers in it. The rule itself lives
  /// in [clusterBySimilarity], which knows nothing about storylines — see its
  /// doc for the join rule, the cap, the coherence floor and the split ladder,
  /// and for why the whole thing has to be a pure function of the row order
  /// the store handed over.
  static List<List<int>> _clusterBy(
    int count,
    double Function(int i, int j) sim,
  ) =>
      clusterBySimilarity(
        count,
        sim,
        threshold: StorylineTuning.clusterLinkThreshold,
        // The PROPOSE floor, not the survivor floor: what comes back here is
        // a question to spend a naming call on, and a pair is not one.
        minSize: StorylineTuning.proposeMinClusterSize,
        maxSize: StorylineTuning.maxClusterSize,
        floor: StorylineTuning.clusterCoherenceFloor,
        step: StorylineTuning.clusterSplitStep,
        ceiling: StorylineTuning.clusterSplitCeiling,
      );

  /// Every candidate pair's similarity, computed in Dart — the fallback, and
  /// the definition the index path is measured against.
  ///
  /// Full agglomerative clustering — repeatedly merging the closest pair —
  /// would find slightly better groups and is O(n³) on a list that is
  /// re-clustered after every sync. This is O(n²) against a mailbox of a few
  /// hundred live threads, and the model call behind each proposal is the part
  /// that decides quality anyway.
  static PairSimilarities _arithmeticSimilarities(
    List<List<double>> vectors,
  ) {
    final table = PairSimilarities(vectors.length);
    for (var i = 0; i < vectors.length; i++) {
      for (var j = i + 1; j < vectors.length; j++) {
        table.set(i, j, cosine(vectors[i], vectors[j]));
      }
    }
    return table;
  }

  /// The candidate pair similarities read off the vec0 index, or null when the
  /// index cannot answer for this candidate set and the caller must do the
  /// arithmetic.
  ///
  /// **This is an equivalence, not an approximation.** Every probe asks for as
  /// many neighbours as the index HOLDS, so each one comes back with the whole
  /// corpus and every candidate pair is seen — twice, once from each end, at
  /// the same number. A pair no probe reported reads 0 out of the table, which
  /// is below every threshold the clustering compares against. The win being
  /// bought is that the distances are computed natively over packed float32
  /// instead of a Dart triple-accumulation per pair; it is emphatically not an
  /// asymptotic one, and asking for fewer neighbours to get one would mean the
  /// sweep proposing different storylines depending on whether an optional
  /// native extension had loaded. Note that the index holds the whole
  /// clustering corpus and the candidates are a subset of it — filed and
  /// finished threads are indexed too — which is exactly why `k` is the index's
  /// row count and not the candidate count: a `k` of the latter would let
  /// already-filed threads crowd a genuine candidate out of a probe's answer.
  ///
  /// What this does NOT do any more is decide anything. It used to return a
  /// boolean adjacency, applying the link threshold as it read each hit; the
  /// compare now lives in [clusterBySimilarity], because the coherence floor
  /// is a mean over every pair inside a cluster and the new join rule puts
  /// sub-threshold pairs inside one by construction.
  ///
  /// Four ways to decline, and each of them says why — once per distinct
  /// reason, per process:
  ///
  /// * a candidate whose vector is not the index's width — a corpus caught
  ///   mid-model-change has rows the index skipped, and a hole in the index is
  ///   a link the probes cannot find;
  /// * no usable index at all, which is the ordinary state of a build without
  ///   the native extension;
  /// * a candidate whose stored embedding is not bytes, which is a corrupt row
  ///   rather than a missing feature;
  /// * a probe that does not find its own row, which is the one cheap check
  ///   that says the index really does hold every candidate.
  ///
  /// The answer is the same in all four — fall back to the arithmetic, cluster
  /// identically, propose the same storylines — so none of them is an error.
  /// But a build that quietly clusters the slow way forever and a corpus with
  /// one bad row are very different things to be told about, and the report is
  /// the only place that distinction survives.
  Future<PairSimilarities?> _indexedSimilarities(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    for (final vector in vectors) {
      if (vector.length != ConversationVectorIndex.dims) {
        _reportBruteForce("a candidate vector is not the index's width");
        return null;
      }
    }

    final indexed = await _store.prepareConversationIndex(
      embedModel: EmbeddingsClient.modelTag,
    );
    if (indexed == null) {
      _reportBruteForce('no usable index');
      return null;
    }

    final position = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final source = rows[i]['source'] as String? ?? _workSource;
      final key = rows[i]['conversation_key'] as String? ?? '';
      position[_threadKey(source, key)] = i;
    }

    final table = PairSimilarities(rows.length);
    for (var i = 0; i < rows.length; i++) {
      final blob = rows[i]['embedding'];
      if (blob is! Uint8List) {
        _reportBruteForce('a candidate blob is not bytes');
        return null;
      }
      final hits = await _store.conversationNeighbors(blob, k: indexed);
      var foundSelf = false;
      for (final hit in hits) {
        final j = position[_threadKey(hit.source, hit.key)];
        if (j == null) continue;
        if (j == i) {
          foundSelf = true;
          continue;
        }
        // Stored once for the unordered pair, whichever end reported it.
        // Cosine is symmetric and each probe sees the whole corpus, so the
        // second sighting writes the number the first one did — which is what
        // makes the table a genuine symmetric measure rather than something
        // whose clusters could turn on which row was probed first.
        table.set(i, j, hit.similarity);
      }
      if (!foundSelf) {
        _reportBruteForce('the index does not hold every candidate');
        return null;
      }
    }
    return table;
  }

  /// Reasons already reported. Static because the interesting thing is the
  /// BUILD — an app without the native extension falls back on every sweep
  /// forever, and a line per sweep would be noise about a fact that cannot
  /// change.
  static final Set<String> _fallbackReported = {};

  /// Says once, per process, per distinct [reason], that the sweep is
  /// clustering the slow way.
  ///
  /// Keyed on the reason rather than on the fact, exactly like
  /// `EmbeddingsClient._fail`: the four declines are told apart by nothing
  /// else, and a single flag would let whichever one happened first hide the
  /// rest for the life of the process.
  static void _reportBruteForce(String reason) {
    if (!_fallbackReported.add(reason)) return;
    debugPrint('storylines: sweeping by arithmetic — $reason');
  }

  /// Names one cluster, asks whether each of its threads actually belongs
  /// under that name, and stores the survivors as a suggestion.
  ///
  /// The naming call reads the whole cluster — a group is named after what
  /// most of it is about, and hiding the outliers from that call would only
  /// make the name worse. What comes back is then the criteria: the title, the
  /// summary and above all the charter the model just wrote are what each
  /// thread is confirmed against, one at a time. Before this, a cluster shipped
  /// whole, and a naming pass that wrote "this excludes unrelated work
  /// requests" would file the unrelated work requests anyway.
  ///
  /// A storyline that IS born then runs one bounded probe over
  /// [doneCandidates] — the finished threads the sweep diverted out of the
  /// clustering — offering the closest of them the same membership question
  /// its cluster members just answered. It runs here, before the return,
  /// rather than as a pass of its own: the recap row was queued a few lines
  /// above and the recap handler drains after the sweep's in this same pass,
  /// so a thread that joins now is in the storyline's very first recap.
  ///
  /// Returns a tally rather than a bool: the sweep budgets its room on
  /// proposals, but the activity row is about the judging, which happens
  /// whether or not anything is proposed. `confirmed` and `rejected` are the
  /// CLUSTER's members being judged and nothing else — the probe's own
  /// confirmations are reported only as `joined`, because a finished thread
  /// that was offered and turned away was never a member of the group the
  /// user is being asked about.
  /// [claimedByProbe] is the sweep's running set of threads an earlier
  /// proposal in the SAME pass already took — read and written by the probe,
  /// so one finished thread joins at most one newborn storyline.
  Future<
      ({
        bool proposed,
        int confirmed,
        int rejected,
        int joined,
        int incoherent,
        int lint,
        int outliers,
      })> _propose(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors, {
    List<({Map<String, Object?> row, List<double> vector})> doneCandidates =
        const [],
    Set<String>? claimedByProbe,
  }) async {
    const nothing = (
      proposed: false,
      confirmed: 0,
      rejected: 0,
      joined: 0,
      incoherent: 0,
      lint: 0,
      outliers: 0,
    );

    final threads = [
      for (final row in rows)
        (
          source: row['source'] as String? ?? _workSource,
          key: row['conversation_key'] as String? ?? '',
        ),
    ];
    final clusterHash = _hashOfThreads(threads);
    // Both recipes for the one candidate set: the tombstones an older build
    // wrote hashed the bare keys and can never be rewritten, so recognition
    // has to keep speaking that language too. See [_legacyHashOfThreads].
    if (await _store.dismissedHashExistsAny(
      [clusterHash, _legacyHashOfThreads(threads)],
    )) {
      return nothing;
    }

    // Everyone in the WHOLE cluster, computed once and before the naming
    // call: all the candidates are judged against the same group, not against
    // one that shrinks as its members are rejected out from under the later
    // questions — and the charter lint needs it to tell a charter from a
    // roster of the people who happen to be on these threads.
    final seen = <String>{};
    final storylineParticipants = <String>[];
    for (final row in rows) {
      for (final display in _displaysOf(Conversation.fromRow(row))) {
        if (seen.add(display.toLowerCase())) storylineParticipants.add(display);
      }
    }

    final id = newStorylineId();
    final named = await _name(rows, vectors);
    final result = named.result;

    // The model's own out, read as the live model actually uses it. Asked the
    // prompt as it ships, the 27B answers `coherent: false` whenever ANY
    // thread does not belong and then lists those threads in `outliers`,
    // writing its title and charter for the group that remains — which is
    // what the prompt's own sentence tells it to do. Measured on the golden
    // pool: eight clusters of eight came back false, four of them listing
    // every thread and the rest listing 4 of 7, 3 of 6, 2 of 3 and 1 of 3. So
    // `false` means "not all of them", and tombstoning on it threw away every
    // cluster the sweep formed.
    //
    // What is left of the out is the two answers that name no group to keep:
    // `false` with an empty outlier list, which is the model declining
    // outright, and a kept set under [StorylineTuning.minClusterSize], which
    // is the same refusal spelled as a list. Everything else proceeds on the
    // kept threads, `coherent` false or true alike, and the per-member
    // confirms are the guard on them: each is judged against the charter the
    // model wrote for the group it kept, and `minClusterSize` is applied again
    // to the survivors.
    //
    // The tombstone carries the ORIGINAL cluster's hash, so the identical set
    // is recognised by `dismissedHashExistsAny` next pass and costs nothing.
    final dropped = rows.length - named.kept.length;
    if ((!result.coherent && result.outliers.isEmpty) ||
        named.kept.length < StorylineTuning.minClusterSize) {
      await _tombstone(id, result, clusterHash);
      return (
        proposed: false,
        confirmed: 0,
        rejected: 0,
        joined: 0,
        incoherent: 1,
        lint: 0,
        outliers: 0,
      );
    }

    // The charter the confirms are about to be judged against, read before a
    // single one is spent. A placeholder, a roster of the cluster's own
    // people, or a bare class of message is a charter that admits everything,
    // and the confirm stage cannot refuse what the charter allows.
    final lintReason = charterLint(
      title: result.title,
      charter: result.charter,
      participants: storylineParticipants,
    );
    if (lintReason != null) {
      await _tombstone(id, result, clusterHash);
      return (
        proposed: false,
        confirmed: 0,
        rejected: 0,
        joined: 0,
        incoherent: 0,
        lint: 1,
        outliers: 0,
      );
    }

    // The outliers are simply not confirmed and not members. Nothing is
    // written for them and nothing blocks them: they go back into the pool,
    // where the next pass may cluster them with something they do belong to.
    // `rows` is narrowed because everything below reads it: the confirms, the
    // member writes and the participants the probe re-reads. `vectors` is NOT,
    // and deliberately: nothing past this line reads it. The probe builds its
    // centroid by decoding `survivor.row['embedding']` for the threads that
    // actually survived the confirms, which is a different set again, so
    // narrowing the parameter here would be a store nobody loads.
    final outliersDropped = dropped;
    rows = [for (final index in named.kept) rows[index]];

    // Never stored, and deliberately so: this exists only to give
    // [ConfirmInput] the group to judge against, and the whole point of the
    // pass is that some of these threads may not survive being judged. What
    // reaches the database is decided below, once the answers are in.
    final proposal = Storyline(
      id: id,
      title: result.title,
      summary: result.summary,
      charter: result.charter.isEmpty ? null : result.charter,
      status: 'suggested',
      createdBy: 'auto',
    );

    // No cap on how many of these a cluster may spend, unlike [recruit]'s
    // eight. The cost is bounded by identity rather than by count: a cluster
    // is confirmed once ever, because the hash checks above and the tombstone
    // below mean the same set of threads never reaches this line twice — and
    // the confirmations run on the small local model.
    final survivors = <({Map<String, Object?> row, String evidence})>[];
    var rejected = 0;
    for (final row in rows) {
      final source = row['source'] as String? ?? _workSource;
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty) continue;
      final cardData = await _store.newestInboundCardData(source, key);

      // No examples: the proposal has no owner history by construction.
      final confirm = await _confirm(
        proposal,
        storylineParticipants,
        row,
        cardData,
      );
      // The proposal is `suggested`, so [_accepts] holds every member of a
      // newborn storyline to `high`.
      if (!_accepts(confirm, proposal)) {
        rejected++;
        continue;
      }
      survivors.add((row: row, evidence: confirm.evidence));
    }

    if (survivors.length < StorylineTuning.minClusterSize) {
      await _tombstone(id, result, clusterHash);
      // No probe on this branch, and that is the point of saying so: a group
      // the model just threw out must not go recruiting history to make
      // itself big enough to ship.
      return (
        proposed: false,
        confirmed: survivors.length,
        rejected: rejected,
        joined: 0,
        incoherent: 0,
        lint: 0,
        outliers: outliersDropped,
      );
    }

    final memberHash = _hashOfThreads([
      for (final survivor in survivors)
        (
          source: survivor.row['source'] as String? ?? _workSource,
          key: survivor.row['conversation_key'] as String? ?? '',
        ),
    ]);
    await _store.insertStoryline(
      id: id,
      title: result.title,
      summary: result.summary,
      charter: result.charter.isEmpty ? null : result.charter,
      status: 'suggested',
      createdBy: 'auto',
      // Two hashes, because they answer two different questions once
      // confirmation drops a thread. `member_hash` describes who is stored
      // here, and every later membership write keeps it true. `cluster_hash`
      // names the group the sweep built and the user is being asked about; it
      // is never written again. Dismissing this returns every member to the
      // sweep pool (`assignedOrBlockedKeys` counts only suggested and active
      // storylines), so the identical cluster re-forms on the next sweep and
      // the cheap check above recognises it — before a single model call is
      // spent re-deriving an answer the user already refused.
      memberHash: memberHash,
      clusterHash: clusterHash,
    );
    // Born described. The proposal IS the description: [NameStorylineTask]
    // wrote this title, summary and charter from this exact member set,
    // seconds ago, so stamping the refresh columns here records something
    // true rather than claiming a pass ran. Leaving them null would have the
    // next sweep's refresh catch-up spend a Refine call re-describing a set
    // that has not moved — and this is the same claim the v10 backfill makes
    // about every storyline it found already described.
    await _store.updateStoryline(
      id,
      refreshedMemberHash: memberHash,
      refreshedMemberCount: survivors.length,
    );
    // Recapped in the same drain rather than a sync later. The recap handler
    // runs after the sweep's, so a storyline born in this pass shows its
    // recap the first time the user ever sees it — without this it waits for
    // the next sweep's catch-up to notice it has never been read.
    await _store.requeueWork('storyline_recap', _workSource, id);
    for (final survivor in survivors) {
      await _store.addStorylineMember(
        id,
        survivor.row['source'] as String? ?? _workSource,
        survivor.row['conversation_key'] as String? ?? '',
        addedBy: 'auto',
        // The model's own sentence about this thread, the same provenance the
        // other two add paths record. The cluster is no longer its own reason.
        evidence: survivor.evidence,
      );
      final lastMessageAt = survivor.row['last_message_at'] as String?;
      if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
        await _store.touchStorylineActivity(id, lastMessageAt);
      }
    }

    // The probe: join, not seed. The storyline exists now, so the finished
    // threads the sweep would not cluster can be asked the one question that
    // was never available to them — not "are you the start of a story", which
    // they are not, but "do you belong to this one".
    var joined = 0;
    final claimed = claimedByProbe ?? <String>{};
    if (doneCandidates.isNotEmpty) {
      // The centroid over the SURVIVOR vectors, computed in memory rather
      // than through [_memberContext]: the member rows were written a few
      // lines above, and reading them back would buy a query to learn what
      // this stack frame is already holding.
      final survivorVectors = <List<double>>[];
      for (final survivor in survivors) {
        final blob = survivor.row['embedding'];
        if (blob is! Uint8List) continue;
        final vector = decodeEmbedding(blob);
        if (vector.isNotEmpty) survivorVectors.add(vector);
      }
      final centroid = _centroid(survivorVectors);
      if (centroid != null) {
        final memberThreads = {
          for (final survivor in survivors)
            _threadKey(
              survivor.row['source'] as String? ?? _workSource,
              survivor.row['conversation_key'] as String? ?? '',
            ),
        };

        // The finished threads still on offer, in the order the sweep
        // diverted them.
        final offered = <({Map<String, Object?> row, List<double> vector})>[];
        for (final candidate in doneCandidates) {
          final row = candidate.row;
          final key = row['conversation_key'] as String? ?? '';
          if (key.isEmpty) continue;
          final rowSource = row['source'] as String? ?? _workSource;
          final thread = _threadKey(rowSource, key);
          if (memberThreads.contains(thread)) continue;
          // Taken by an earlier proposal in this same pass — the sweep's
          // taken-set could not know about it, because that storyline did not
          // exist when the set was read.
          if (claimed.contains(thread)) continue;
          offered.add(candidate);
        }
        // Scored, then top-N — [_shortlist], [recruit]'s recipe exactly, at
        // the lower assignment gate for the recruit's reason: the embedding
        // decides what the model looks at, and the model decides membership.
        final considered = _shortlist(
          offered,
          centroid,
          gate: StorylineTuning.assignCosineGateWithOverlap,
          take: StorylineTuning.recruitMaxCandidates,
        );

        if (considered.isNotEmpty) {
          // Read back from the stored members, not the `storylineParticipants`
          // list above: that one still holds everyone the confirm stage
          // rejected, and a finished thread is judged against the group as it
          // actually stands — the same snapshot [recruit] takes.
          final postParticipants = await _participantsOfStoryline(id);
          for (final candidate in considered) {
            final row = candidate.row;
            final rowSource = row['source'] as String? ?? _workSource;
            final key = row['conversation_key'] as String? ?? '';
            final cardData = await _store.newestInboundCardData(rowSource, key);

            // No examples: the proposal has no owner history by construction.
            final confirm = await _confirm(
              proposal,
              postParticipants,
              row,
              cardData,
            );
            // The same rule the cluster members above were held to.
            if (!_accepts(confirm, proposal)) continue;

            await _store.addStorylineMember(
              id,
              rowSource,
              key,
              addedBy: 'auto',
              evidence: confirm.evidence,
            );
            final lastMessageAt = row['last_message_at'] as String?;
            if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
              await _store.touchStorylineActivity(id, lastMessageAt);
            }
            claimed.add(_threadKey(rowSource, key));
            joined++;

            // In the same breath as the membership write, for [recruit]'s
            // reason: a server that parks on a LATER candidate must not leave
            // the hashes describing a set that no longer exists. Both hash
            // columns, and their equality is the point — the storyline is
            // born described (the title, summary and charter were written
            // seconds ago), and leaving `member_hash` ahead of
            // `refreshed_member_hash` would put this row into
            // `staleRefreshStorylineIds` and spend a 27B Refine call on a
            // description that is already right. The count follows the same
            // truth, and `recapThrough` is cleared exactly as every other
            // member-add path clears it, so the recap already queued above
            // covers the threads that just joined. At most eight extra
            // writes, the same cost recruit accepts.
            //
            // `cluster_hash` is untouched, here as everywhere: it names the
            // group the sweep built and the user is being asked about, and
            // the probe did not change that question.
            final finalHash = await _memberHashOf(id);
            await _store.updateStoryline(
              id,
              memberHash: finalHash,
              refreshedMemberHash: finalHash,
              refreshedMemberCount: survivors.length + joined,
              recapThrough: null,
            );
          }
        }
      }
    }

    return (
      proposed: true,
      confirmed: survivors.length,
      rejected: rejected,
      joined: joined,
      incoherent: 0,
      lint: 0,
      outliers: outliersDropped,
    );
  }

  /// One naming call over the cluster's most central cards, and what it said.
  ///
  /// [kept] are the indexes into [rows] the model did NOT name as outliers, in
  /// order. `vectors[i]` is `rows[i]`'s decoded vector, which is what makes
  /// "most central" answerable here rather than a second decode.
  ///
  /// The range check on the outlier numbers is this method's rather than the
  /// task's: only the caller knows how many cards it numbered, and a number
  /// past the end is a card the model never saw.
  Future<({NameResult result, List<int> kept})> _name(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    var central = _centralIndexes(
      vectors,
      take: StorylineTuning.namingCards,
    );
    final cards = <String>[];
    for (final index in central) {
      final row = rows[index];
      cards.add(_namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          row['source'] as String? ?? _workSource,
          row['conversation_key'] as String? ?? '',
        ),
      ));
    }
    final numbered = _numberedCards(cards);
    // Dropping from the far end can leave fewer cards than there are central
    // indexes, and card `[k]` must keep meaning the k-th of what was SENT.
    final shown = numbered.length;
    central = central.take(shown).toList();

    final result = await runTask(
      _client,
      const NameStorylineTask(),
      NameInput(numbered),
      temperature: 0,
    );

    final outliers = <int>{
      for (final number in result.outliers)
        if (number >= 1 && number <= shown) central[number - 1],
    };
    return (
      result: result,
      kept: [
        for (var i = 0; i < rows.length; i++)
          if (!outliers.contains(i)) i,
      ],
    );
  }

  /// The `dismissed` row a refused cluster leaves behind, so the identical set
  /// never costs a model call again.
  ///
  /// One insert site, three reasons: the namer said these threads are not one
  /// storyline, the charter lint refused what it wrote, or the confirms left
  /// fewer than [StorylineTuning.minClusterSize] survivors. The cluster is
  /// deterministic and its members go straight back into the unassigned pool,
  /// so without a row carrying its hash this same group would re-spend a
  /// naming call and one confirmation per member on every sync, forever, to
  /// reach the same answer. Dismissed is exactly the right status for that:
  /// nothing renders it, and `dismissedHashExistsAny` stops the rebuilt
  /// cluster before any model is dialled.
  ///
  /// `member_hash` stays null on purpose: no member rows are ever written for
  /// a tombstoned cluster, so there is no stored set for it to describe. The
  /// cluster is the only identity this row has, and the only one anything can
  /// rebuild.
  ///
  /// [clusterHash] is always the ORIGINAL cluster's, the question that was
  /// asked, even when outliers had already been dropped: what must not be
  /// asked twice is the group the sweep built.
  Future<void> _tombstone(
    String id,
    NameResult result,
    String clusterHash,
  ) async {
    await _store.insertStoryline(
      id: id,
      title: result.title,
      summary: result.summary,
      charter: result.charter.isEmpty ? null : result.charter,
      status: 'dismissed',
      createdBy: 'auto',
      clusterHash: clusterHash,
    );
  }

  // ── user actions ───────────────────────────────────────────────────────

  /// Starts a storyline around one thread. Active immediately and titled by
  /// the user, so it never appears as something to accept — a person does not
  /// need the app's permission for a group they just made.
  Future<String> createStoryline(
    String title, {
    required String source,
    required String conversationKey,
  }) async {
    final id = newStorylineId();
    await _store.insertStoryline(
      id: id,
      title: title,
      status: 'active',
      createdBy: 'user',
    );
    await _store.updateStoryline(id, titleLocked: true);
    await addThread(id, source, conversationKey);
    return id;
  }

  Future<void> keepSuggestion(String id) =>
      _store.updateStoryline(id, status: 'active');

  /// Retires a storyline — a suggestion the user never wanted, or a kept one
  /// they are done with. Nothing else moves: the row keeps both hashes, which
  /// is what [MessageStore.dismissedHashExistsAny] reads when the very next
  /// sweep rebuilds the same cluster, and the member rows stay as the record
  /// of what the user was actually shown.
  Future<void> dismissSuggestion(String id) =>
      _store.updateStoryline(id, status: 'dismissed');

  /// Brings a dismissed storyline back as a suggestion — the state it was in
  /// before the owner said no, so the same Keep / Dismiss question is asked
  /// again. The tombstone check keys on `status = 'dismissed'`, so restoring
  /// also lifts the block on re-proposing this member set. Members were kept
  /// on dismissal, so nothing else needs rebuilding.
  Future<void> restoreDismissed(String id) =>
      _store.updateStoryline(id, status: 'suggested');

  Future<void> rename(String id, String title) =>
      _store.updateStoryline(id, title: title, titleLocked: true);

  /// Saves the user's charter and sends the model hunting with it.
  ///
  /// A non-empty save locks the charter — the same contract a rename gives the
  /// title — and queues one [recruit] pass, revived rather than merely
  /// enqueued so the second edit of the day recruits again. Clearing the text
  /// unlocks and queues a [refresh] instead: the About block promises that
  /// clearing a charter lets the model draft a new one, and until this queued
  /// something that promise was not kept. Nothing is recruited on the strength
  /// of criteria the user just deleted — the refresh writes a charter, and the
  /// re-arm inside it is what goes looking afterwards.
  ///
  /// Both arms clear any parked suggestion. The user has just said what
  /// belongs in this storyline; an offer written against what they said
  /// before is stale by definition, and leaving it on screen would ask them
  /// to answer a question they have already answered.
  Future<void> setCharter(String id, String charter) async {
    final trimmed = charter.trim();
    if (trimmed.isEmpty) {
      await _store.updateStoryline(
        id,
        charter: null,
        charterLocked: false,
        charterSuggestion: null,
      );
      await _store.requeueWork('storyline_refresh', _workSource, id);
      return;
    }
    await _store.updateStoryline(
      id,
      charter: trimmed,
      charterLocked: true,
      charterSuggestion: null,
    );
    await _store.requeueWork('storyline_recruit', _workSource, id);
  }

  /// Throws away the charter the refresh pass parked. Nothing else moves: the
  /// user's own charter and its lock are untouched, and the next refresh that
  /// finds the group has outgrown it may park another — which is right, since
  /// by then it is a different group.
  Future<void> dismissCharterSuggestion(String id) =>
      _store.updateStoryline(id, charterSuggestion: null);

  /// Files a thread into a storyline by hand. The member write clears any
  /// block the user's own earlier removal left, which is what makes putting a
  /// thread back work at all — see [MessageStore.addStorylineMember].
  ///
  /// It also stamps the thread's messages, which is what makes the filing
  /// VISIBLE. The home feed and the hot-storylines strip both read
  /// `message_progress.storyline_id` and know nothing about member rows, so a
  /// thread added by hand used to appear on the timeline and the rail and
  /// nowhere else.
  ///
  /// And it queues a [refresh], unconditionally — unlike the automatic path,
  /// which is gated. A person filing a thread by hand is saying this group is
  /// about that too, and they are looking at the description while they say
  /// it.
  ///
  /// It queues a [recap] for the same reason, and the two are separate
  /// requeues rather than one: the thread that just arrived brings its own
  /// messages, so where this storyline STANDS changed the moment it was filed,
  /// not only what the storyline is about. The refresh queues one of these
  /// too, but only when it gets past its own gate — and a hand-filed thread is
  /// the case where the user is watching.
  Future<void> addThread(String id, String source, String key) async {
    // Evidence, on a `user` row, and it is not decoration: this membership is
    // read back as an EXAMPLE by the confirm prompt (see [_examplesFor]), and
    // a removal copies the member's evidence onto its block. A row with none
    // would hand a later removal a negative example that says nothing.
    await _store.addStorylineMember(
      id,
      source,
      key,
      addedBy: 'user',
      evidence: 'Filed by you',
    );
    final storyline = await _store.getStoryline(id);
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Cleared with the hash, for the reason spelled out in
      // [assignConversation] — and this is the path it was written for. A
      // thread a person files by hand is usually one they went looking for,
      // which means an old one, and without this the recap requeued below
      // would find the mark already past every message on it and return
      // having said nothing.
      recapThrough: null,
      // Filing a thread into a suggestion is accepting it — the same write
      // [keepSuggestion] makes. Nothing is left to ask about a group the user
      // is already putting threads into.
      status: storyline?.status == 'suggested' ? 'active' : null,
    );
    await _stampPointer(source, key);
    final row = await _store.getConversationRow(source, key);
    final lastMessageAt = row?['last_message_at'] as String?;
    if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
      await _store.touchStorylineActivity(id, lastMessageAt);
    }
    await _store.requeueWork('storyline_refresh', _workSource, id);
    await _store.requeueWork('storyline_recap', _workSource, id);
  }

  /// Takes a thread out, and blocks it from coming back. Always blocking:
  /// there is no other way for a user to reach this, and an unblocked removal
  /// would be undone by the next assignment pass.
  ///
  /// The clear names [id] rather than blanking the column, and then whatever
  /// membership is LEFT takes the pointer over: a thread in two storylines
  /// pulled out of one still belongs to the other, and a feed row that went
  /// blank would be telling the user it belongs to nothing.
  ///
  /// A removal changes what the storyline is about as surely as an addition
  /// does, so it queues the same [refresh]. A storyline emptied down to
  /// nothing is safe: the pass stamps on a member set with no cards and says
  /// nothing.
  ///
  /// It is also the one membership change that adds no message anywhere, which
  /// is why clearing the recap watermark matters most here: the recap the
  /// refresh tail queues has no new mail to make it stale, and would return at
  /// its own gate still describing a thread that is gone. The stored recap is
  /// cleared with the watermark, so the recap this queues starts from the
  /// remaining threads rather than carrying the departed one forward.
  ///
  /// And it queues an [audit] as well as the refresh. A removal is the owner
  /// saying the model got this group wrong, and the threads the same reasoning
  /// filed here are still sitting in it — so the automatic members are
  /// re-judged. The audit handler is registered AFTER the refresh handler, so
  /// the two run in that order within one drain and the audit judges against
  /// the charter the refresh has just narrowed.
  Future<void> removeThread(String id, String source, String key) async {
    // `blocked_by: 'user'` — the owner's own "no", which is the only kind the
    // confirm prompt ever learns from. The evidence is copied off the member
    // row by the store, so the block records what the model thought when it
    // filed the thread the owner is now taking out.
    await _store.removeStorylineMember(
      id,
      source,
      key,
      block: true,
      blockedBy: 'user',
    );
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Cleared with the hash, for the reason spelled out in
      // [assignConversation].
      recapThrough: null,
      // And the recap itself goes with the members, which is what makes a
      // removal different from every other membership change. The recap pass
      // is handed the previous recap and told to carry forward what is still
      // true, and it has no way to know which sentence came from the thread
      // that just left — so a paragraph naming that thread would survive every
      // rewrite. Cleared, the recap this removal queues is written from the
      // remaining threads alone. An addition clears nothing: new mail adds
      // facts, it never invalidates the ones already written.
      recapText: null,
      recapOpenJson: null,
      recapDecisionsJson: null,
    );
    _progress.noteStorylineLink(
      source,
      await _store.stampStorylineId(source, key, clearingStorylineId: id),
    );
    await _stampPointer(source, key);
    await _store.requeueWork('storyline_refresh', _workSource, id);
    await _store.requeueWork('storyline_audit', _workSource, id);
  }

  /// A gate's removal of one thread from every live storyline it is in, and
  /// how many memberships that came to.
  ///
  /// The sibling of [removeThread], and everything that method does to keep a
  /// storyline honest about its members is done here too: the member row goes,
  /// a block goes in its place, the member hash is recomputed, the recap and
  /// its watermark are cleared for the reason [removeThread] spells out, the
  /// per-thread pointer is re-stamped onto whatever membership is left, and a
  /// refresh is queued because a group that lost a thread describes something
  /// slightly different now.
  ///
  /// Three things differ, and each of them is the point:
  ///
  /// - `blocked_by: 'gate'` with an explicit evidence string. A block's
  ///   evidence defaults to the MEMBER's own — what the model thought when it
  ///   filed the thread — and that is the wrong sentence here, because this
  ///   removal is not a judgement about the group at all. The block says why
  ///   the thread left: nothing in it was ever meant for a model.
  /// - no audit. [removeThread] queues one because the owner removing a thread
  ///   is the owner saying the model got this group wrong, and the threads the
  ///   same reasoning filed here deserve re-judging. A gate says nothing about
  ///   the model's reasoning — the thread should never have reached it — so
  ///   there is no lesson to spread.
  /// - a `user`-added membership is left exactly where it is. The owner filed
  ///   that thread by hand, and a gate does not overrule a person.
  ///
  /// The block outlives a Restore, deliberately. Restoring one message puts it
  /// back in front of the model; whether its thread belongs in this storyline
  /// is a separate question, and "Allow again" is where the owner answers it.
  Future<int> evictGatedThread(String source, String key) async {
    var evicted = 0;
    for (final id in await _store.storylineIdsFor(source, key)) {
      final member = (await _store.membersOf(id)).where(
        (m) => m.source == source && m.conversationKey == key,
      );
      if (member.isEmpty) continue;
      if (member.first.addedBy == 'user') continue;
      await _store.removeStorylineMember(
        id,
        source,
        key,
        block: true,
        blockedBy: 'gate',
        evidence: 'every inbound message in this thread was gated',
      );
      await _store.updateStoryline(
        id,
        memberHash: await _memberHashOf(id),
        recapThrough: null,
        recapText: null,
        recapOpenJson: null,
        recapDecisionsJson: null,
      );
      _progress.noteStorylineLink(
        source,
        await _store.stampStorylineId(source, key, clearingStorylineId: id),
      );
      await _stampPointer(source, key);
      await _store.requeueWork('storyline_refresh', _workSource, id);
      evicted++;
    }
    return evicted;
  }

  /// Lifts a block and nothing else — "Allow again".
  ///
  /// The thread is NOT re-filed: the owner is withdrawing a veto, not making a
  /// membership. Whether it belongs is a question the model may now answer on
  /// its own judgement the next time a pass considers the thread, which is
  /// what makes this different from [addThread].
  ///
  /// Nothing is queued. There is no membership change to re-describe and
  /// nothing new to recap — the storyline is exactly as it was a moment ago,
  /// and only the set of threads a future pass may look at has widened.
  Future<void> unblockThread(String id, String source, String key) async {
    await _store.unblockStorylineMember(id, source, key);
    await _log.record(
      'storyline_unblock',
      source: source,
      entityId: key,
      detail: {'storyline_id': id},
    );
  }

  /// Points a thread's messages at the storyline the rest of the app would
  /// say it is in, or leaves them alone when it is in none.
  ///
  /// The id is `storylineIdsFor(...).first` — deliberately the same pick
  /// [PipelineProgress.assignedStorylineId] makes, which is oldest membership
  /// first. So filing a thread into a SECOND storyline stamps the first one it
  /// joined, not the one just chosen: the two answers must agree, or the feed
  /// row and the automatic pass would fight over the column every time the
  /// thread was touched.
  Future<void> _stampPointer(String source, String key) async {
    final ids = await _store.storylineIdsFor(source, key);
    if (ids.isEmpty) return;
    _progress.noteStorylineLink(
      source,
      await _store.stampStorylineId(source, key, storylineId: ids.first),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────

  /// One conversation's stored vector, or null when it has none this model can
  /// compare. The model tag check is not optional: vectors from two embedding
  /// models occupy different spaces, and a cosine across them is a number with
  /// no meaning that still sorts.
  Future<List<double>?> _vectorFor(
    String source,
    String conversationKey,
  ) async {
    final ai = await _store.getConversationAi(source, conversationKey);
    if (ai == null) return null;
    if (ai['embed_model'] != EmbeddingsClient.modelTag) return null;
    final blob = ai['embedding'];
    if (blob is! Uint8List) return null;
    final vector = decodeEmbedding(blob);
    return vector.isEmpty ? null : vector;
  }

  /// Writes the embedding a thread is missing, so that a park on it can heal
  /// itself once the server is back.
  ///
  /// Nothing else in the app will write it. Extraction embeds a thread once,
  /// and by the time the storyline pass parks the extract row is already
  /// `done` — `enqueueExtractBacklog` will not re-queue it and nothing
  /// requeues the `extract` kind — so a park on a missing vector used to park
  /// again on every drain, forever, for a thread whose extraction call had
  /// already been spent. No re-extraction is needed to fix that: the card the
  /// vector comes from is rebuilt out of the conversation row and the facts
  /// already stored, exactly as [ExtractHandler] built it at extraction time.
  ///
  /// Null comes back only from a REJECTED answer — a server that answered
  /// something that is not a vector will answer the same thing next time, so
  /// parking on it would park forever. Unavailable throws instead: that park
  /// is what brings this thread back the moment `make embed` is running, and
  /// the retry it waits for is this same re-embed.
  Future<List<double>?> _reembed(
    String source,
    String conversationKey,
    Map<String, Object?> row,
  ) async {
    // The belt to [assignConversation]'s braces, and it is here because this
    // is the only place that WRITES an embedding outside extraction: the
    // sweep, the recruit lap and a future caller all arrive through it. A
    // thread with nothing kept gets no vector — `null` is this method's
    // existing "rejected, do not park" ending, which is the right one: the
    // answer will not change on the next drain either.
    if (await _store.keptInboundCount(source, conversationKey) == 0) {
      _log.note({'embed': 'gated'});
      return null;
    }

    final embeddings = _embeddings;
    if (embeddings == null) {
      // `embed`, not `reason`: the worker's park writes its own
      // `{'reason': 'model_unavailable'}` and its merge wins on a collision.
      _log.note({'embed': 'missing'});
      throw const LlmUnavailableException(
        'No embedding for this thread yet — run: make embed',
      );
    }

    final card = clusteringCardForConversationRow(
      row,
      await _store.newestInboundCardData(source, conversationKey),
    );
    final embedded = await embeddings.embedResult(card);
    final vector = embedded.vector;
    if (vector == null) {
      if (embedded.outcome == EmbedOutcome.unavailable) {
        _log.note({'embed': 'unavailable'});
        throw const LlmUnavailableException(
          'No embedding for this thread yet — run: make embed',
        );
      }
      // Quiet, the same deliberate drop the extraction path makes on
      // deterministic nonsense. The thread embeds again with its next real
      // message.
      _log.note({'embed': 'rejected'});
      return null;
    }

    // The identical write [ExtractHandler._refreshCard] makes, hash included:
    // a vector stored without one would be re-embedded by the next extraction
    // whether or not the thread had changed.
    await _store.upsertConversationAi(
      source,
      conversationKey,
      embedding: encodeEmbedding(vector),
      embeddedHash: cardHash(card),
      embedModel: EmbeddingsClient.modelTag,
    );
    return vector;
  }

  /// The best [take] of [candidates] against one [centroid]: scored by cosine,
  /// everything under [gate] dropped, highest first.
  ///
  /// The one recipe for "many threads against one storyline" — the recruit lap
  /// and the sweep's finished-thread probe both ask exactly this, of different
  /// lists. The assignment pass is the transpose, one thread against many
  /// centroids with a per-candidate gate, and does not come through here.
  ///
  /// Ties break on arrival order, which is the store's own (newest first, key
  /// ascending), and that tiebreak is spelled out rather than left implicit
  /// because `List.sort` makes no stability promise and both callers have to
  /// answer the same way twice.
  static List<({Map<String, Object?> row, double score})> _shortlist(
    Iterable<({Map<String, Object?> row, List<double> vector})> candidates,
    List<double> centroid, {
    required double gate,
    required int take,
  }) {
    final scored =
        <({int index, Map<String, Object?> row, double score})>[];
    var order = 0;
    for (final candidate in candidates) {
      final index = order++;
      final score = cosine(candidate.vector, centroid);
      if (score < gate) continue;
      scored.add((index: index, row: candidate.row, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    // The arrival index stays inside: it exists to break the sort's ties and
    // neither caller has any use for it afterwards.
    return [
      for (final candidate in scored.take(take))
        (row: candidate.row, score: candidate.score),
    ];
  }

  /// The indexes of the [take] vectors nearest the centroid of [vectors], most
  /// central first; ties by index. Every index when [take] is at least
  /// `vectors.length`.
  ///
  /// The order is what makes dropping a card safe: the naming call reads a
  /// cluster's cards in this order, so what falls off the end is the member
  /// least like the rest, not whichever one the store happened to list last.
  /// A cluster with no averageable vector keeps the store's order, which is
  /// the honest answer when there is no centre to sort around.
  static List<int> _centralIndexes(
    List<List<double>> vectors, {
    required int take,
  }) {
    final all = [for (var i = 0; i < vectors.length; i++) i];
    final centroid = _centroid(vectors);
    if (centroid == null) return all.take(take).toList();
    final scored = [
      for (var i = 0; i < vectors.length; i++)
        (index: i, score: cosine(vectors[i], centroid)),
    ];
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      // Ties by index, so one cluster reads one way twice — the property the
      // tombstones and the determinism test both rest on.
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    return [for (final entry in scored.take(take)) entry.index];
  }

  /// [cards] numbered `[1] `, `[2] `, … in the order given, each clamped to
  /// [NameStorylineTask.cardCap] AFTER its number is prefixed, then whole
  /// cards dropped from the END until the set joined with `\n---\n` fits
  /// [NameStorylineTask.cardsCap].
  ///
  /// The numbers are what the prompt's `outliers` rule points at, so they are
  /// 1-based and the caller maps them back. Dropping whole cards rather than
  /// truncating the joined string is the whole change: the old prompt fitted
  /// every card into four thousand characters by cutting each one to eighty
  /// characters, which left the model a list of subject lines. The sweep
  /// orders by centrality, so a dropped card is an edge; the bootstrap path
  /// passes member order and a dropped card there is the last member.
  static List<String> _numberedCards(List<String> cards) {
    const separator = '\n---\n';
    final numbered = <String>[
      for (var i = 0; i < cards.length; i++)
        _clampCard('[${i + 1}] ${cards[i]}'),
    ];
    var total = 0;
    final kept = <String>[];
    for (final card in numbered) {
      final cost = card.length + (kept.isEmpty ? 0 : separator.length);
      if (total + cost > NameStorylineTask.cardsCap) break;
      kept.add(card);
      total += cost;
    }
    return kept;
  }

  static String _clampCard(String card) =>
      card.length > NameStorylineTask.cardCap
          ? card.substring(0, NameStorylineTask.cardCap)
          : card;

  /// The mean vector, or null when there is nothing to average. Not
  /// re-normalised — [cosine] divides by both norms itself.
  static List<double>? _centroid(List<List<double>> vectors) {
    if (vectors.isEmpty) return null;
    final length = vectors.first.length;
    final sum = List<double>.filled(length, 0);
    var counted = 0;
    for (final vector in vectors) {
      // A vector of a different width came from a different model. Dropped
      // rather than truncated: half a vector is not a shorter vector.
      if (vector.length != length) continue;
      for (var i = 0; i < length; i++) {
        sum[i] += vector[i];
      }
      counted++;
    }
    if (counted == 0) return null;
    return [for (final value in sum) value / counted];
  }

  /// Several storylines' members, read in ONE store call: per storyline the
  /// mean member vector (null when no member has one), every member
  /// participant lower-cased, and the member threads themselves as
  /// [_threadKey]s.
  ///
  /// Shared by [assignConversation] and [recruit], which is the point — the
  /// two passes are mirror images, and a centroid computed two ways would let
  /// them disagree about the same storyline.
  ///
  /// Batched because [assignConversation] asks this of every live storyline
  /// before it files one thread: read one storyline at a time it cost a query
  /// per member of the whole mailbox's storyline set, for every thread that
  /// arrived. A storyline with no members is simply absent from the map, which
  /// callers read as [_emptyContext] — which is what it is.
  Future<Map<String, _MemberContext>> _memberContexts(
    List<String> storylineIds,
  ) async {
    final vectors = <String, List<List<double>>>{};
    final participants = <String, Set<String>>{};
    final memberThreads = <String, Set<String>>{};
    for (final row in await _store.memberContextRows(
      storylineIds,
      embedModel: EmbeddingsClient.modelTag,
    )) {
      final id = row['storyline_id'] as String? ?? '';
      if (id.isEmpty) continue;
      final source = row['source'] as String? ?? _workSource;
      final key = row['conversation_key'] as String? ?? '';
      memberThreads
          .putIfAbsent(id, () => <String>{})
          .add(_threadKey(source, key));

      // Null on a member the store found no comparable vector for — the join
      // is what enforces the embedding model, for the reason [_vectorFor]
      // gives. Such a member is still a member; it just cannot be averaged.
      final blob = row['embedding'];
      if (blob is Uint8List) {
        final vector = decodeEmbedding(blob);
        if (vector.isNotEmpty) vectors.putIfAbsent(id, () => []).add(vector);
      }

      // Empty on a member whose conversation row is gone: the row still
      // arrives, carrying no participants, exactly as the per-member read it
      // replaced skipped a missing row without dropping the membership.
      final into = participants.putIfAbsent(id, () => <String>{});
      for (final display in _displaysOf(Conversation.fromRow(row))) {
        into.add(display.toLowerCase());
      }
    }
    return {
      for (final entry in memberThreads.entries)
        entry.key: (
          centroid: _centroid(vectors[entry.key] ?? const <List<double>>[]),
          participants: participants[entry.key] ?? const <String>{},
          memberThreads: entry.value,
        ),
    };
  }

  /// [_memberContexts] for one storyline, so the single-storyline callers read
  /// as they always did and there is still only one implementation.
  Future<_MemberContext> _memberContext(String storylineId) async =>
      (await _memberContexts([storylineId]))[storylineId] ?? _emptyContext;

  /// What a storyline nobody has filed anything into looks like: nothing to
  /// average, nobody on it, no members.
  static const _MemberContext _emptyContext = (
    centroid: null,
    participants: <String>{},
    memberThreads: <String>{},
  );

  /// A thread's identity across sources, for set membership. Newline-joined
  /// because a newline can appear in neither half.
  static String _threadKey(String source, String conversationKey) =>
      '$source\n$conversationKey';

  static List<String> _displaysOf(Conversation conversation) => [
        for (final participant in conversation.participants)
          if (participant.display.isNotEmpty) participant.display,
      ];

  /// [_displaysOf] minus the owner.
  ///
  /// A participant IS the owner when its display or its address matches the
  /// owner's name or address, case-insensitively and trimmed. A null owner,
  /// or an owner with neither field, removes nobody: until the lookup
  /// answers, every participant counts as not the owner, which keeps the
  /// overlap rule stricter rather than looser.
  ///
  /// A namesake is dropped too — another Pat Owner on the thread is read as
  /// the owner and does not count toward the overlap. Deliberate: the cost of
  /// that is one thread that missed the lower gate, and the cost of the other
  /// reading is the discount firing on the one person who is on every thread
  /// in the mailbox.
  static List<String> _nonOwnerDisplaysOf(
    Conversation conversation,
    OwnerIdentity? owner,
  ) {
    String norm(String? value) => (value ?? '').trim().toLowerCase();
    final names = {norm(owner?.name), norm(owner?.address)}..remove('');
    if (names.isEmpty) return _displaysOf(conversation);
    return [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty &&
            !names.contains(norm(participant.display)) &&
            !names.contains(norm(participant.email)))
          participant.display,
    ];
  }

  /// The one membership question this file asks, at temperature 0, with the
  /// charter clamped at [StorylineTuning.charterCap].
  ///
  /// Every one of the five confirm sites — assign, recruit, the sweep's
  /// members, its probe and the audit — comes through here, so the task, the
  /// clamp, the temperature and the card recipe cannot drift apart. Zero
  /// because the same thread judged against the same storyline twice must
  /// give the same answer, or a re-run after a park or a restart would move
  /// threads between groups for no reason a user could see.
  ///
  /// [examples] is null for the sweep's proposal, which has no owner history
  /// by construction.
  Future<ConfirmResult> _confirm(
    Storyline storyline,
    List<String> storylineParticipants,
    Map<String, Object?> row,
    Map<String, Object?>? cardData, {
    ({List<String> kept, List<String> removed})? examples,
  }) =>
      runTask(
        _confirmClient,
        const ConfirmMembershipTask(charterCap: StorylineTuning.charterCap),
        ConfirmInput(
          storyline: storyline,
          storylineParticipants: storylineParticipants,
          candidateCard: enrichedCardForConversationRow(row, cardData),
          keptExamples: examples?.kept ?? const [],
          removedExamples: examples?.removed ?? const [],
        ),
        temperature: 0,
      );

  /// THE membership rule: a yes the model was confident enough about
  /// ([ConfirmResult.accepted] — `belongs`, and not `low`), and for a
  /// storyline nobody has kept yet, `high`.
  ///
  /// Auto-filing into a group the owner has never looked at needs the
  /// strongest answer the model gives: a `medium` yes into such a group is
  /// how the blobs grew. The sweep judges its members against an UNSAVED
  /// proposal whose status is `suggested`, so a newborn storyline's members
  /// are held to `high` too, on purpose. An `active` storyline — one the
  /// owner kept — takes `medium`, as it always did.
  static bool _accepts(ConfirmResult result, Storyline storyline) =>
      result.accepted &&
      (storyline.status != 'suggested' || result.confidence == 'high');

  /// `high` over `medium` over anything else, for the near-tie in
  /// [assignConversation] and nothing else: it ranks two yeses, never decides
  /// whether one is a yes.
  static int _confidenceRank(String confidence) =>
      confidence == 'high' ? 2 : (confidence == 'medium' ? 1 : 0);

  /// The storylines that have lately been taking more than their share of the
  /// automatic adds, and the floor of the window they were read over. Empty
  /// whenever the window is too thin to mean anything.
  ///
  /// The floor rides along because the caller needs the same instant twice:
  /// once to ask who the catch-alls are, and once to say how recently their
  /// audit must have run for another one to be worth queueing.
  Future<({Set<String> ids, String since})> _catchAllIds() async {
    // Stamped the way [MessageStore.addStorylineMember] stamps `added_at`, so
    // the string compare in the query is between two strings of one shape.
    final since = MessageStore.isoStamp(
      DateTime.now()
          .subtract(const Duration(days: StorylineTuning.catchAllWindowDays)),
    );
    final shares = await _store.autoMembershipShares(since);
    return (
      ids: catchAllsOf(
        byStoryline: shares.byStoryline,
        total: shares.total,
      ),
      since: since,
    );
  }

  /// The arithmetic of the catch-all rule, separated from the read so it can
  /// be asked directly: the ids whose share of [total] strictly exceeds
  /// `max(catchAllShare, catchAllFairShareMultiple / k)`, where `k` is how
  /// many storylines received an add at all. See
  /// [StorylineTuning.catchAllFairShareMultiple] for why the threshold has
  /// two halves.
  @visibleForTesting
  static Set<String> catchAllsOf({
    required Map<String, int> byStoryline,
    required int total,
  }) {
    if (total < StorylineTuning.catchAllMinAdds) return const {};
    final k = byStoryline.length;
    if (k == 0) return const {};
    final threshold = math.max(
      StorylineTuning.catchAllShare,
      StorylineTuning.catchAllFairShareMultiple / k,
    );
    return {
      for (final entry in byStoryline.entries)
        if (entry.value > threshold * total) entry.key,
    };
  }

  /// Everyone on any member thread, de-duplicated, in first-seen order.
  Future<List<String>> _participantsOfStoryline(String storylineId) async {
    final seen = <String>{};
    final displays = <String>[];
    for (final member in await _store.membersOf(storylineId)) {
      final row = await _store.getConversationRow(
        member.source,
        member.conversationKey,
      );
      if (row == null) continue;
      for (final display in _displaysOf(Conversation.fromRow(row))) {
        if (seen.add(display.toLowerCase())) displays.add(display);
      }
    }
    return displays;
  }

  /// The naming card of every member that still has a conversation row, in
  /// the order the members were given.
  ///
  /// Takes the members rather than the id because [refresh] needs the same
  /// list twice — to count them and to card them — and because the ORDER is
  /// load-bearing there: `membersOf` sorts by `added_at`, which is what lets
  /// the tail of this list stand in for "the threads that just joined".
  Future<List<String>> _cardsOf(List<StorylineMember> members) async {
    final cards = <String>[];
    for (final member in members) {
      final row = await _store.getConversationRow(
        member.source,
        member.conversationKey,
      );
      if (row == null) continue;
      cards.add(_namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          member.source,
          member.conversationKey,
        ),
      ));
    }
    return cards;
  }

  /// How many of each kind of example ride into a confirm prompt. Three: the
  /// owner's latest word is what teaches, and a fourth card buys tokens on
  /// every membership question this storyline will ever ask.
  static const int _examplesEach = 3;

  /// Up to three threads the owner filed by hand and up to three they took
  /// out, as the enriched cards the confirm task reads — newest first, so the
  /// lesson is the owner's latest word. Removed means `blocked_by = 'user'`
  /// ONLY: an audit's rejection is a consequence of the owner's "no", not a
  /// second lesson, and feeding it back would let the model teach itself.
  /// Fetched once per pass and reused for every confirm in it.
  ///
  /// The count is taken AFTER the gone-thread filter, on both lists: a thread
  /// the app no longer stores teaches nothing, and cutting the list to three
  /// first would let three deleted threads crowd out the lessons that are
  /// still there.
  Future<({List<String> kept, List<String> removed})> _examplesFor(
    String storylineId,
  ) async {
    final kept = <String>[];
    for (final member in await _store.userMembersOf(storylineId)) {
      if (kept.length == _examplesEach) break;
      final card = await _cardOf(member.source, member.conversationKey);
      if (card != null) kept.add(card);
    }
    final removed = <String>[];
    for (final block in await _store.blocksOf(storylineId, blockedBy: 'user')) {
      if (removed.length == _examplesEach) break;
      final card = await _cardOf(block.source, block.conversationKey);
      if (card != null) removed.add(card);
    }
    return (kept: kept, removed: removed);
  }

  /// One thread's enriched card, or null when its conversation row is gone —
  /// a block outlives the thread it was written about, and an example nothing
  /// can be said about is left out rather than rendered blank.
  Future<String?> _cardOf(String source, String conversationKey) async {
    final row = await _store.getConversationRow(source, conversationKey);
    if (row == null) return null;
    return enrichedCardForConversationRow(
      row,
      await _store.newestInboundCardData(source, conversationKey),
    );
  }

  /// The threads the OWNER removed from this storyline, as the naming cards
  /// the refresh prompt's other card fences carry — newest first, up to
  /// [_examplesEach].
  ///
  /// The owner's blocks only, for [_examplesFor]'s reason: an audit's block is
  /// a consequence of a lesson the owner already taught, and handing it back
  /// as grounds to narrow the charter would let one removal ratchet a
  /// storyline shut. The count is taken after the gone-thread filter, for
  /// [_examplesFor]'s other reason.
  Future<List<String>> _removedCardsOf(String storylineId) async {
    final cards = <String>[];
    for (final block in await _store.blocksOf(storylineId, blockedBy: 'user')) {
      if (cards.length == _examplesEach) break;
      final row = await _store.getConversationRow(
        block.source,
        block.conversationKey,
      );
      if (row == null) continue;
      cards.add(_namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          block.source,
          block.conversationKey,
        ),
      ));
    }
    return cards;
  }

  /// Two pieces of prose compared as the same sentence: trimmed, runs of
  /// whitespace flattened to one space, lower-cased.
  ///
  /// Used only to decide whether the charter MOVED — never to decide what is
  /// stored, which is always the text exactly as it came back. A model that
  /// returns the same charter with a newline where a space was has changed
  /// nothing, and treating that as a change would put the refresh and the
  /// recruit into a loop that re-ran on every drain.
  static String _normalized(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// The dedupe key for a storyline's current member set, read from the
  /// stored member rows — the source on each row, never an assumed one, since
  /// that half of a thread's identity is exactly what the hash is folding in.
  Future<String> _memberHashOf(String storylineId) async {
    return _hashOfThreads([
      for (final member in await _store.membersOf(storylineId))
        (source: member.source, key: member.conversationKey),
    ]);
  }

  /// Sorted, newline-joined, hashed — the mechanic both recipes below share.
  /// Sorted because membership is a set: the same threads arriving in a
  /// different order are the same storyline.
  String _hashOfParts(Iterable<String> parts) =>
      cardHash((parts.toList()..sort()).join('\n'));

  /// The one recipe behind every hash this service WRITES, to either column:
  /// the `'<source>\n<key>'` composites of the threads involved.
  ///
  /// The source is half of a thread's identity. The mail and chat connectors
  /// mint their keys with no knowledge of each other, so a hash over the bare
  /// key alone called a chat and a mail thread that happened to share one the
  /// same group — and a dismissal of the one silenced the other for ever.
  String _hashOfThreads(Iterable<({String source, String key})> threads) =>
      _hashOfParts([for (final t in threads) _threadKey(t.source, t.key)]);

  /// The recipe those writes used before the source was folded in: the bare
  /// conversation keys, otherwise identical.
  ///
  /// Nothing writes it any more and nothing can rewrite what it wrote. A
  /// cluster the model threw out entirely is tombstoned with no member rows at
  /// all, so there is nothing left to re-hash it from: the old string on that
  /// row is the only surviving record of what the user was spared, and it has
  /// to keep answering for as long as the database does. Every dismissal check
  /// therefore offers both recipes for the same candidate set — see
  /// [MessageStore.dismissedHashExistsAny] — and takes either.
  String _legacyHashOfThreads(
    Iterable<({String source, String key})> threads,
  ) =>
      _hashOfParts([for (final t in threads) t.key]);
}

/// A fresh storyline id: `sl-` and sixteen hex characters.
///
/// Hand-rolled rather than a uuid dependency — nothing joins on the format,
/// nothing parses it, and 64 bits of randomness is far past what a local
/// database of a few hundred rows can collide on.
String newStorylineId() {
  final buffer = StringBuffer('sl-');
  for (var i = 0; i < 16; i++) {
    buffer.write(StorylineService._random.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}

/// The card text for a stored conversation row.
///
/// Deliberately NOT the card that produced the row's embedding: that one is
/// built during extraction and carries the extracted topics and the triage
/// summary, neither of which is stored on the conversation. What is here is
/// the durable half — the subject and who is on the thread — and it is what
/// the naming and membership prompts read.
///
/// The vector already carries the rest. This text is what a model reads, and
/// re-deriving the full card would mean re-running an extraction to name a
/// storyline.
String cardForConversationRow(Map<String, Object?> row) {
  final conversation = Conversation.fromRow(row);
  return buildConversationCard(
    subject: stripReFw(conversation.subject),
    participants: [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty) participant.display,
    ],
    topics: const [],
    summary: null,
  );
}

/// The card the NAMING prompt reads: the thin card plus the newest inbound
/// triage summary, and deliberately no topics.
///
/// Naming sees every member thread at once under one 4000-character cap, and
/// a topic list is the segment that says least per character it costs — the
/// sentence describing what was last said is what a title comes out of. The
/// membership prompt, which reads ONE card, can afford both.
String _namingCardForConversationRow(
  Map<String, Object?> row,
  Map<String, Object?>? cardData,
) {
  final conversation = Conversation.fromRow(row);
  return buildConversationCard(
    subject: stripReFw(conversation.subject),
    participants: [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty) participant.display,
    ],
    topics: const [],
    summary: cardData?['summary'] as String?,
  );
}

/// The card for a conversation row enriched with what the AI already knows
/// about the thread: extracted topics and the newest inbound triage summary.
/// Degrades to [cardForConversationRow]'s thin card when [cardData] is null
/// or its pieces are missing/corrupt — enrichment is a bonus, never a
/// requirement.
String enrichedCardForConversationRow(
  Map<String, Object?> row,
  Map<String, Object?>? cardData,
) {
  final conversation = Conversation.fromRow(row);
  return buildConversationCard(
    subject: stripReFw(conversation.subject),
    participants: [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty) participant.display,
    ],
    topics: _topicsOf(cardData?['extraction_json']),
    summary: cardData?['summary'] as String?,
  );
}

/// The card a conversation is EMBEDDED from, built from the same row and the
/// same stored facts [enrichedCardForConversationRow] reads.
///
/// Identical to that card while [StorylineTuning.participantsInClusteringCard]
/// is true, and that is the point of routing both through
/// [buildClusteringCard] rather than leaving the embed path on the prompt
/// path's recipe: the flag decides ONE of them. The prompts keep their people
/// whatever the vector does.
/// [withParticipants] defaults to the flag the app ships, so the one caller
/// inside this file passes nothing and cannot drift from it. It is a parameter
/// at all for the sweep bench, which prices both variants against one mailbox
/// and must be able to ask for the card the app is NOT currently writing —
/// through this same recipe, so what it measures is the app's card and not a
/// second copy of it.
String clusteringCardForConversationRow(
  Map<String, Object?> row,
  Map<String, Object?>? cardData, {
  bool withParticipants = StorylineTuning.participantsInClusteringCard,
}) {
  final conversation = Conversation.fromRow(row);
  return buildClusteringCard(
    subject: stripReFw(conversation.subject),
    participants: [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty) participant.display,
    ],
    topics: _topicsOf(cardData?['extraction_json']),
    summary: cardData?['summary'] as String?,
    withParticipants: withParticipants,
  );
}

/// The `topics` list out of a stored extraction blob, or nothing. Every step
/// can fail against a row an older build wrote, and every failure is the same
/// answer: no topics, which is the card this app sent before there were any.
List<String> _topicsOf(Object? extractionJson) {
  if (extractionJson is! String || extractionJson.isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(extractionJson);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map) return const [];
  final topics = decoded['topics'];
  if (topics is! List) return const [];
  return [
    for (final topic in topics)
      if (topic is String && topic.isNotEmpty) topic,
  ];
}
