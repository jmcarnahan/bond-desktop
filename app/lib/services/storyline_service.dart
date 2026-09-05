import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/conversation_vec_index.dart';
import '../data/message_store.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import 'activity_log.dart';
import 'conversation_state.dart';
import 'extract_handler.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/storyline_tasks.dart';
import 'pipeline_progress.dart';

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

  /// The gate when the thread shares at least one person with the storyline.
  /// Who is on a thread is the single strongest signal that two threads are
  /// the same deal, so it buys a look the vector alone would not have earned.
  static const double assignCosineGateWithOverlap = 0.50;

  /// Cosine two conversations must reach to land in the same proposed cluster.
  /// Higher than the assignment gates because there is no existing group to
  /// score a candidate against — the only thing holding a cluster together is
  /// how close its members sit to each other.
  ///
  /// Still a filter and not a verdict: what the cluster produces is a
  /// shortlist and a name, and every member of it is then confirmed against
  /// that name one thread at a time, exactly as an assignment is. In a
  /// mailbox where every thread shares the same boilerplate, neighbours at
  /// this cosine can be about entirely different things, and the confirm
  /// stage is what catches that — raising the number here would only make the
  /// pass propose less.
  static const double clusterLinkThreshold = 0.65;

  /// A storyline of one is just a thread.
  static const int minClusterSize = 2;

  /// How many unanswered suggestions may sit in the rail at once. A wall of
  /// proposals is not a feature; it is a chore, and it gets dismissed as one.
  static const int maxPendingSuggestions = 3;

  /// All this floor asks is that there be something to pair: two unassigned
  /// threads — mail or chat — already make a cluster, per [minClusterSize],
  /// and below that the pass has nothing it could propose. Whether the pair
  /// is worth proposing is decided elsewhere, by [clusterLinkThreshold], the
  /// per-member confirm, and [maxPendingSuggestions]. Waiting for a busier
  /// mailbox only starves a light one of its first storyline.
  static const int sweepMinUnassigned = 2;

  /// How many threads one recruit pass may put in front of the model. A
  /// charter save is one user action, and eight confirmations is already the
  /// most model time any single click in this app spends — past the top eight
  /// by cosine, a candidate was not close enough for a missed-thread hunt to
  /// be the pass that finds it.
  static const int recruitMaxCandidates = 8;
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

  /// Never returned: a thread with no comparable vector is not a thread that
  /// failed, it is a thread whose embedding has not been written yet. The pass
  /// first tries to write it — the card needs no model call, only the
  /// conversation row and the facts already extracted — and only when that
  /// attempt finds no server does it throw [LlmUnavailableException] to park
  /// the queue rather than answering. Named here because it is the fifth thing
  /// the pass can conclude and the park is where it went.
  noVector,
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

  StorylineService(
    this._store,
    LlmClient client, {
    LlmClient? confirmClient,
    ActivityLog? activityLog,
    EmbeddingsClient? embeddings,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _client = client,
        _confirmClient = confirmClient ?? client,
        _log = activityLog ?? ActivityLog.disabled(),
        _embeddings = embeddings,
        _progress = progress;

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

    // Written here when the store has none — see [_reembed]. Null comes back
    // only from an embedding the server refused to give; the other two endings
    // throw and park.
    final vector = await _vectorFor(source, conversationKey) ??
        await _reembed(source, conversationKey, row);
    if (vector == null) return AssignOutcome.noCandidate;

    final conversation = Conversation.fromRow(row);
    final participants = _displaysOf(conversation);

    // Suggestions included: a thread that belongs to a group the user has not
    // answered yet still belongs to it, and waiting would mean the suggestion
    // is judged on a member set that stopped growing.
    final candidates = await _store.loadStorylines(
      statuses: const ['suggested', 'active'],
    );

    Storyline? best;
    var bestScore = 0.0;
    // Only to tell the two empty-handed endings apart: a thread the user
    // pulled OUT of the one storyline it fits is a different fact from a
    // thread nothing came close to.
    var blocked = false;

    // Two reads for the whole pass, not two per candidate. Both questions the
    // loop below asks are about state that cannot change while it runs, and
    // asking them one storyline at a time made filing one thread cost a query
    // per storyline plus a query per member of each — the pass got slower
    // every time the mailbox grew a group.
    final contexts =
        await _memberContexts([for (final s in candidates) s.id]);
    final blockedIn =
        await _store.blockedStorylineIdsFor(source, conversationKey);

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

      final overlap = participants
          .any((display) => context.participants.contains(display.toLowerCase()));
      final gate = overlap
          ? StorylineTuning.assignCosineGateWithOverlap
          : StorylineTuning.assignCosineGate;

      final score = cosine(vector, centroid);
      if (score < gate) continue;
      if (best == null || score > bestScore) {
        best = storyline;
        bestScore = score;
      }
    }

    if (best == null) {
      return blocked ? AssignOutcome.blocked : AssignOutcome.noCandidate;
    }

    final cardData = await _store.newestInboundCardData(source, conversationKey);

    final result = await runTask(
      _confirmClient,
      const ConfirmMembershipTask(),
      ConfirmInput(
        storyline: best,
        storylineParticipants: await _participantsOfStoryline(best.id),
        candidateCard: enrichedCardForConversationRow(row, cardData),
      ),
      // Zero: the same thread judged against the same storyline twice must
      // give the same answer, or a re-run after a restart would move threads
      // between groups for no reason a user could see.
      temperature: 0,
    );

    // A `low` answer is a no. Nothing is blocked either way — only a person
    // removing a thread creates a block, because only a person's "no" should
    // still hold the next time the model changes its mind.
    if (!result.belongs || result.confidence == 'low') {
      return AssignOutcome.rejected;
    }

    await _store.addStorylineMember(
      best.id,
      source,
      conversationKey,
      addedBy: 'auto',
      evidence: result.evidence,
    );
    await _store.updateStoryline(
      best.id,
      memberHash: await _memberHashOf(best.id),
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
    _log.note({'assigned': best.title});

    final lastMessageAt = conversation.lastMessageAt;
    if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
      await _store.touchStorylineActivity(best.id, lastMessageAt);
    }

    await _enqueueRefreshAfterAssign(best);
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
        messageLines: [for (final row in rows.reversed) _recapLine(row)],
      ),
      // Zero, like every other storyline call: the same window recapped twice
      // must read the same, or a re-run after a park would rewrite the block
      // a user is looking at for no reason they could see.
      temperature: 0,
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
  static String _recapLine(Map<String, Object?> row) {
    final subject = stripReFw(row['subject'] as String?);
    final sender = row['direction'] == 'outbound'
        ? 'You'
        : (row['from_name'] as String? ?? '');
    final preview = row['body_preview'] as String?;
    final body = (preview != null && preview.isNotEmpty)
        ? preview
        : (row['body_text'] as String? ?? '');
    final text = body.trim();
    return '${subject.isEmpty ? '' : '[$subject] '}$sender: '
        '${text.length > _recapLineCap ? text.substring(0, _recapLineCap) : text}';
  }

  /// How much of one message reaches the recap. A dozen of these has to fit
  /// under [StorylineRecapTask]'s window cap with the thread names and the
  /// senders, and a preview is what a person skimming their inbox sees — past
  /// that it is quoted thread and signature.
  static const int _recapLineCap = 400;

  /// The first description: the same naming call a fresh cluster gets.
  ///
  /// Returns the charter it wrote, or null when it wrote none.
  Future<String?> _bootstrapDescription(
    String storylineId,
    List<String> cards,
  ) async {
    final result = await runTask(
      _client,
      const NameStorylineTask(),
      NameInput(cards),
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
      await _store.updateStoryline(storylineId, charter: result.charter);
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

      // Scored, then top-N. Ties break on the store's own order (newest first,
      // key ascending), and the sort is made deterministic by index because
      // List.sort makes no stability promise of its own.
      final scored = <({int index, Map<String, Object?> row, double score})>[];
      var index = 0;
      for (final row in await _store.conversationsWithEmbeddings(
        embedModel: EmbeddingsClient.modelTag,
        sources: _sources,
      )) {
        final order = index++;
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
        final score = cosine(vector, centroid);
        if (score < StorylineTuning.assignCosineGateWithOverlap) continue;
        scored.add((index: order, row: row, score: score));
      }
      scored.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.index.compareTo(b.index);
      });
      final considered =
          scored.take(StorylineTuning.recruitMaxCandidates).toList();

      // One snapshot for every candidate: the storyline as the user saved it is
      // what all eight are judged against, not a group that grows under the
      // later candidates as the earlier ones land.
      final storylineParticipants = await _participantsOfStoryline(storylineId);

      var recruited = 0;
      for (final candidate in considered) {
        final row = candidate.row;
        final rowSource = row['source'] as String? ?? _workSource;
        final key = row['conversation_key'] as String? ?? '';
        final cardData = await _store.newestInboundCardData(rowSource, key);

        final result = await runTask(
          _confirmClient,
          const ConfirmMembershipTask(),
          ConfirmInput(
            storyline: storyline,
            storylineParticipants: storylineParticipants,
            candidateCard: enrichedCardForConversationRow(row, cardData),
          ),
          // Zero for the reason assignment runs at zero: a re-run after a park
          // must not move different threads.
          temperature: 0,
        );
        if (!result.belongs || result.confidence == 'low') continue;

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
    for (final row in await _store.conversationsWithEmbeddings(
      embedModel: EmbeddingsClient.modelTag,
      sources: _sources,
    )) {
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty) continue;
      final rowSource = row['source'] as String? ?? _workSource;
      if (taken.contains(_threadKey(rowSource, key))) continue;
      // A finished thread is not the start of a story. Grouping done mail
      // would fill the rail with history nobody asked to be reminded of.
      if ((row['state'] as String?) == 'done') continue;
      final blob = row['embedding'];
      if (blob is! Uint8List) continue;
      final vector = decodeEmbedding(blob);
      if (vector.isEmpty) continue;
      rows.add(row);
      vectors.add(vector);
    }

    if (rows.length < StorylineTuning.sweepMinUnassigned) return;

    // Pair-discovery, on the index when there is one and in Dart when there is
    // not. The two answers are the same clusters either way — see
    // [_indexedLinks] — so nothing below this line knows which ran.
    final clusters = await _clusterCandidates(rows, vectors);

    // Room is spent on PROPOSALS, not on clusters considered: the pass is
    // deterministic and largest-first, so a dismissed cluster that merely
    // consumed a slot would consume that same slot on every future sweep and
    // permanently starve the genuinely new clusters ranked behind it.
    var proposed = 0;
    var confirmed = 0;
    var rejected = 0;
    var attempted = 0;
    for (final cluster in clusters) {
      if (proposed >= room) break;
      final tally = await _propose([for (final index in cluster) rows[index]]);
      attempted++;
      if (tally.proposed) proposed++;
      // Summed across every cluster the pass named, the tombstoned ones
      // included: the model's rejections are work it did and an answer it
      // gave, and a cluster that was thrown out entirely is the most
      // interesting row this pass can write.
      confirmed += tally.confirmed;
      rejected += tally.rejected;
    }

    // Once at the end, not once per proposal: the sweep is one unit of work
    // and gets one row, so a per-cluster note would just overwrite itself.
    // Zeroes included — the log decides what a person sees, and its
    // quiet-kind check is what suppresses the all-zero pass as the genuine
    // nothing it is. Skipped entirely when no cluster reached the model,
    // because then there is not even a tally to be zero about.
    if (attempted > 0) {
      _log.note({
        'proposed': proposed,
        'confirmed': confirmed,
        'rejected': rejected,
      });
    }
  }

  /// The clusters this sweep will consider, from whichever pair-discovery is
  /// available.
  ///
  /// The split is deliberate and narrow: finding the linked PAIRS is the part
  /// an index can do faster, and forming the clusters out of them is the part
  /// whose determinism the tombstones depend on. So both paths hand the same
  /// question to the same [_clusterBy], and the only thing that varies is who
  /// answered "does row i link to row j".
  Future<List<List<int>>> _clusterCandidates(
    List<Map<String, Object?>> rows,
    List<List<double>> vectors,
  ) async {
    final links = await _indexedLinks(rows, vectors);
    if (links == null) return _cluster(vectors);
    return _clusterBy(vectors.length, (i, j) => links[i].contains(j));
  }

  /// The link adjacency read off the vec0 index, or null when the index cannot
  /// answer for this candidate set and the caller must do the arithmetic.
  ///
  /// **This is an equivalence, not an approximation.** Every probe asks for as
  /// many neighbours as the index HOLDS, so each one comes back with the whole
  /// corpus and the same `>=` against the same threshold decides each pair. The
  /// win being bought is that the distances are computed natively over packed
  /// float32 instead of a Dart triple-accumulation per pair; it is emphatically
  /// not an asymptotic one, and asking for fewer neighbours to get one would
  /// mean the sweep proposing different storylines depending on whether an
  /// optional native extension had loaded. Note that the index holds the whole
  /// clustering corpus and the candidates are a subset of it — filed and
  /// finished threads are indexed too — which is exactly why `k` is the index's
  /// row count and not the candidate count: a `k` of the latter would let
  /// already-filed threads crowd a genuine candidate out of a probe's answer.
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
  Future<List<Set<int>>?> _indexedLinks(
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

    final links = [for (var i = 0; i < rows.length; i++) <int>{}];
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
        if (hit.similarity < StorylineTuning.clusterLinkThreshold) continue;
        // Written both ways from either sighting. Cosine is symmetric and each
        // probe sees the whole corpus, so this is a formality — but it is the
        // formality that makes the adjacency a genuine undirected graph rather
        // than something whose clusters could turn on which row was probed
        // first.
        links[i].add(j);
        links[j].add(i);
      }
      if (!foundSelf) {
        _reportBruteForce('the index does not hold every candidate');
        return null;
      }
    }
    return links;
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

  /// Single-link greedy agglomeration over [vectors], every pair compared in
  /// Dart — the fallback, and the definition both paths are measured against.
  ///
  /// Full agglomerative clustering — repeatedly merging the closest pair —
  /// would find slightly better groups and is O(n³) on a list that is
  /// re-clustered after every sync. This pass is O(n²) against a mailbox of a
  /// few hundred live threads, and the model call behind each proposal is the
  /// part that decides quality anyway.
  static List<List<int>> _cluster(List<List<double>> vectors) => _clusterBy(
        vectors.length,
        (i, j) =>
            cosine(vectors[i], vectors[j]) >=
            StorylineTuning.clusterLinkThreshold,
      );

  /// Single-link greedy agglomeration, in one pass, over [count] rows and the
  /// one question [linked] answers about them.
  ///
  /// Each conversation, in the order the store handed them over (newest first,
  /// key ascending — a total order with no ties), joins the FIRST existing
  /// cluster holding a member it links to, and otherwise opens one of its own.
  /// That makes the result a pure function of the input: same rows and same
  /// links in, same clusters out, which is what
  /// [MessageStore.dismissedHashExistsAny] depends on to recognise a suggestion
  /// the user already threw away. [linked] is therefore required to be pure and
  /// symmetric — both callers above satisfy that, one by arithmetic and one by
  /// construction — because a link that depended on the order it was asked in
  /// would put that property back at risk.
  ///
  /// Returned largest-first, so the [take] above keeps the strongest
  /// proposals; ties break on the earlier cluster, which preserves the recency
  /// order the rows arrived in.
  static List<List<int>> _clusterBy(
    int count,
    bool Function(int i, int j) linked,
  ) {
    final clusters = <List<int>>[];
    for (var i = 0; i < count; i++) {
      var joined = false;
      for (final cluster in clusters) {
        final links = cluster.any((member) => linked(i, member));
        if (!links) continue;
        cluster.add(i);
        joined = true;
        break;
      }
      if (!joined) clusters.add([i]);
    }

    final kept = [
      for (final cluster in clusters)
        if (cluster.length >= StorylineTuning.minClusterSize) cluster,
    ];
    // A stable sort, so equal-sized clusters keep the order they were built
    // in rather than an arbitrary one.
    kept.sort((a, b) => b.length.compareTo(a.length));
    return kept;
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
  /// Returns a tally rather than a bool: the sweep budgets its room on
  /// proposals, but the activity row is about the judging, which happens
  /// whether or not anything is proposed.
  Future<({bool proposed, int confirmed, int rejected})> _propose(
    List<Map<String, Object?>> rows,
  ) async {
    const nothing = (proposed: false, confirmed: 0, rejected: 0);

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

    final cards = <String>[];
    for (final row in rows) {
      cards.add(_namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          row['source'] as String? ?? _workSource,
          row['conversation_key'] as String? ?? '',
        ),
      ));
    }

    final result = await runTask(
      _client,
      const NameStorylineTask(),
      NameInput(cards),
      temperature: 0,
    );

    final id = newStorylineId();
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

    // Everyone in the cluster, computed once: all the candidates are judged
    // against the same group, not against one that shrinks as its members are
    // rejected out from under the later questions.
    final seen = <String>{};
    final storylineParticipants = <String>[];
    for (final row in rows) {
      for (final display in _displaysOf(Conversation.fromRow(row))) {
        if (seen.add(display.toLowerCase())) storylineParticipants.add(display);
      }
    }

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

      final confirm = await runTask(
        _confirmClient,
        const ConfirmMembershipTask(),
        ConfirmInput(
          storyline: proposal,
          storylineParticipants: storylineParticipants,
          candidateCard: enrichedCardForConversationRow(row, cardData),
        ),
        // Zero, for the reason the other two membership paths run at zero: the
        // same thread judged against the same group twice must answer the same
        // way, or a sweep re-run after a restart would propose a different
        // storyline out of an unchanged mailbox.
        temperature: 0,
      );
      // A `low` yes is a no — the identical rule [assignConversation] and
      // [recruit] apply.
      if (!confirm.belongs || confirm.confidence == 'low') {
        rejected++;
        continue;
      }
      survivors.add((row: row, evidence: confirm.evidence));
    }

    if (survivors.length < StorylineTuning.minClusterSize) {
      // A tombstone rather than nothing at all. The cluster is deterministic
      // and its members go straight back into the unassigned pool, so without
      // a row carrying its hash this same group would re-spend a naming call
      // and one confirmation per member on every sync, forever, to reach the
      // same answer. Dismissed is exactly the right status for that: nothing
      // renders it, and `dismissedHashExistsAny` above stops the rebuilt
      // cluster before any model is dialled.
      //
      // `member_hash` stays null on purpose: no member rows are written below
      // this branch, so there is no stored set for it to describe. The cluster
      // is the only identity this row has, and the only one anything can
      // rebuild.
      await _store.insertStoryline(
        id: id,
        title: result.title,
        summary: result.summary,
        charter: result.charter.isEmpty ? null : result.charter,
        status: 'dismissed',
        createdBy: 'auto',
        clusterHash: clusterHash,
      );
      return (proposed: false, confirmed: survivors.length, rejected: rejected);
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
    return (proposed: true, confirmed: survivors.length, rejected: rejected);
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
    await _store.addStorylineMember(id, source, key, addedBy: 'user');
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
  /// its own gate still describing a thread that is gone.
  Future<void> removeThread(String id, String source, String key) async {
    await _store.removeStorylineMember(id, source, key, block: true);
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Cleared with the hash, for the reason spelled out in
      // [assignConversation].
      recapThrough: null,
    );
    _progress.noteStorylineLink(
      source,
      await _store.stampStorylineId(source, key, clearingStorylineId: id),
    );
    await _stampPointer(source, key);
    await _store.requeueWork('storyline_refresh', _workSource, id);
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
    final embeddings = _embeddings;
    if (embeddings == null) {
      // `embed`, not `reason`: the worker's park writes its own
      // `{'reason': 'model_unavailable'}` and its merge wins on a collision.
      _log.note({'embed': 'missing'});
      throw const LlmUnavailableException(
        'No embedding for this thread yet — run: make embed',
      );
    }

    final card = enrichedCardForConversationRow(
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
