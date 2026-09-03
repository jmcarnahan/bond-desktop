import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

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

  StorylineService(
    this._store,
    LlmClient client, {
    LlmClient? confirmClient,
    ActivityLog? activityLog,
    EmbeddingsClient? embeddings,
  })  : _client = client,
        _confirmClient = confirmClient ?? client,
        _log = activityLog ?? ActivityLog.disabled(),
        _embeddings = embeddings;

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

    for (final storyline in candidates) {
      if (await _store.isMemberBlocked(storyline.id, source, conversationKey)) {
        blocked = true;
        continue;
      }

      final context = await _memberContext(storyline.id);
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

    await _refreshName(best.id);
    return AssignOutcome.assigned;
  }

  /// Re-names a storyline when it has nothing to say for itself.
  ///
  /// Only when the summary or the charter is missing, NOT on every membership
  /// change. Naming costs a model call, assignment already spent one, and a
  /// storyline whose name churns every time a thread lands reads as
  /// instability rather than as freshness. A user who dislikes the name
  /// renames it, which locks it.
  ///
  /// The charter clause is what carries storylines written before there were
  /// charters: each gets ONE naming call to draft one, and then converges,
  /// because the same call that writes the charter also writes the summary.
  Future<void> _refreshName(String storylineId) async {
    final storyline = await _store.getStoryline(storylineId);
    if (storyline == null) return;
    final summary = storyline.summary;
    final hasSummary = summary != null && summary.trim().isNotEmpty;
    final needsCharter = !storyline.charterLocked &&
        (storyline.charter == null || storyline.charter!.trim().isEmpty);
    if (hasSummary && !needsCharter) return;

    final cards = await _cardsOf(storylineId);
    if (cards.isEmpty) return;

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
    if (fresh == null) return;

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
    if (!fresh.charterLocked && result.charter.isNotEmpty) {
      await _store.updateStoryline(storylineId, charter: result.charter);
    }
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
  Future<void> recruit(String storylineId) async {
    final storyline = await _store.getStoryline(storylineId);
    // Dismissed between the save and the drain. Recruiting into it would
    // resurrect a group the user threw away, silently.
    if (storyline == null ||
        (storyline.status != 'active' && storyline.status != 'suggested')) {
      return;
    }

    final context = await _memberContext(storylineId);
    final centroid = context.centroid;
    if (centroid == null) {
      // No member vectors means no ranking. The all-zero note is quiet on
      // purpose — the log's quiet-kind check suppresses it as the genuine
      // nothing it is (see the note at the end of this method).
      _log.note({'recruited': 0, 'considered': 0});
      return;
    }

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
      if (context.memberThreads.contains(_threadKey(rowSource, key))) continue;
      if (await _store.isMemberBlocked(storylineId, rowSource, key)) continue;
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
      );
      recruited++;
    }
    // Always, zeroes included — the log is what decides what a person sees.
    // "Recruited 0 of 5" survives its quiet-kind check and shows: the model
    // was consulted and said no, which is an answer. An all-zero pass is
    // suppressed there as the genuine nothing it is.
    _log.note({'recruited': recruited, 'considered': considered.length});
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
    final pending =
        (await _store.loadStorylines(statuses: const ['suggested'])).length;
    final room = StorylineTuning.maxPendingSuggestions - pending;
    if (room <= 0) return;

    // Asked per source and unioned. The keys are connector-issued and disjoint
    // across sources in practice — Graph conversation ids and chat ids share
    // no shape — so one flat set is safe to test membership against, and it is
    // what keeps a chat already in a storyline out of the next sweep's
    // clusters.
    final taken = {
      for (final source in _sources)
        ...await _store.assignedOrBlockedKeys(source),
    };
    final rows = <Map<String, Object?>>[];
    final vectors = <List<double>>[];
    for (final row in await _store.conversationsWithEmbeddings(
      embedModel: EmbeddingsClient.modelTag,
      sources: _sources,
    )) {
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty || taken.contains(key)) continue;
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

    // Room is spent on PROPOSALS, not on clusters considered: the pass is
    // deterministic and largest-first, so a dismissed cluster that merely
    // consumed a slot would consume that same slot on every future sweep and
    // permanently starve the genuinely new clusters ranked behind it.
    var proposed = 0;
    var confirmed = 0;
    var rejected = 0;
    var attempted = 0;
    for (final cluster in _cluster(vectors)) {
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

  /// Single-link greedy agglomeration, in one pass.
  ///
  /// Each conversation, in the order the store handed them over (newest first,
  /// key ascending — a total order with no ties), joins the FIRST existing
  /// cluster holding a member it links to, and otherwise opens one of its own.
  /// That makes the result a pure function of the input: same rows and same
  /// vectors in, same clusters out, which is what
  /// [MessageStore.dismissedHashExists] depends on to recognise a suggestion
  /// the user already threw away.
  ///
  /// Full agglomerative clustering — repeatedly merging the closest pair —
  /// would find slightly better groups and is O(n³) on a list that is
  /// re-clustered after every sync. This pass is O(n²) against a mailbox of a
  /// few hundred live threads, and the model call behind each proposal is the
  /// part that decides quality anyway.
  ///
  /// Returned largest-first, so the [take] above keeps the strongest
  /// proposals; ties break on the earlier cluster, which preserves the recency
  /// order the rows arrived in.
  static List<List<int>> _cluster(List<List<double>> vectors) {
    final clusters = <List<int>>[];
    for (var i = 0; i < vectors.length; i++) {
      var joined = false;
      for (final cluster in clusters) {
        final links = cluster.any(
          (member) =>
              cosine(vectors[i], vectors[member]) >=
              StorylineTuning.clusterLinkThreshold,
        );
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

    final clusterHash = _hashOfKeys([
      for (final row in rows) row['conversation_key'] as String? ?? '',
    ]);
    if (await _store.dismissedHashExists(clusterHash)) return nothing;

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
      // renders it, and `dismissedHashExists` above stops the rebuilt cluster
      // before any model is dialled.
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
      memberHash: _hashOfKeys([
        for (final survivor in survivors)
          survivor.row['conversation_key'] as String? ?? '',
      ]),
      clusterHash: clusterHash,
    );
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
  /// is what [MessageStore.dismissedHashExists] reads when the very next sweep
  /// rebuilds the same cluster, and the member rows stay as the record of what
  /// the user was actually shown.
  Future<void> dismissSuggestion(String id) =>
      _store.updateStoryline(id, status: 'dismissed');

  Future<void> rename(String id, String title) =>
      _store.updateStoryline(id, title: title, titleLocked: true);

  /// Saves the user's charter and sends the model hunting with it.
  ///
  /// A non-empty save locks the charter — the same contract a rename gives the
  /// title — and queues one [recruit] pass, revived rather than merely
  /// enqueued so the second edit of the day recruits again. Clearing the text
  /// unlocks instead: the next naming refresh re-drafts a charter, and nothing
  /// is recruited on the strength of a criteria the user just deleted.
  Future<void> setCharter(String id, String charter) async {
    final trimmed = charter.trim();
    if (trimmed.isEmpty) {
      await _store.updateStoryline(id, charter: null, charterLocked: false);
      return;
    }
    await _store.updateStoryline(id, charter: trimmed, charterLocked: true);
    await _store.requeueWork('storyline_recruit', _workSource, id);
  }

  /// Files a thread into a storyline by hand. The member write clears any
  /// block the user's own earlier removal left, which is what makes putting a
  /// thread back work at all — see [MessageStore.addStorylineMember].
  Future<void> addThread(String id, String source, String key) async {
    await _store.addStorylineMember(id, source, key, addedBy: 'user');
    final storyline = await _store.getStoryline(id);
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Filing a thread into a suggestion is accepting it — the same write
      // [keepSuggestion] makes. Nothing is left to ask about a group the user
      // is already putting threads into.
      status: storyline?.status == 'suggested' ? 'active' : null,
    );
    final row = await _store.getConversationRow(source, key);
    final lastMessageAt = row?['last_message_at'] as String?;
    if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
      await _store.touchStorylineActivity(id, lastMessageAt);
    }
  }

  /// Takes a thread out, and blocks it from coming back. Always blocking:
  /// there is no other way for a user to reach this, and an unblocked removal
  /// would be undone by the next assignment pass.
  Future<void> removeThread(String id, String source, String key) async {
    await _store.removeStorylineMember(id, source, key, block: true);
    await _store.updateStoryline(id, memberHash: await _memberHashOf(id));
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

  /// One storyline's members, read once for comparison work: the mean member
  /// vector (null when no member has one), every member participant
  /// lower-cased, and the member threads themselves as [_threadKey]s.
  ///
  /// Shared by [assignConversation] and [recruit], which is the point — the
  /// two passes are mirror images, and a centroid computed two ways would let
  /// them disagree about the same storyline.
  Future<
      ({
        List<double>? centroid,
        Set<String> participants,
        Set<String> memberThreads,
      })> _memberContext(String storylineId) async {
    final vectors = <List<double>>[];
    final participants = <String>{};
    final memberThreads = <String>{};
    for (final member in await _store.membersOf(storylineId)) {
      memberThreads.add(_threadKey(member.source, member.conversationKey));
      final vector = await _vectorFor(member.source, member.conversationKey);
      if (vector != null) vectors.add(vector);
      final row = await _store.getConversationRow(
        member.source,
        member.conversationKey,
      );
      if (row == null) continue;
      for (final display in _displaysOf(Conversation.fromRow(row))) {
        participants.add(display.toLowerCase());
      }
    }
    return (
      centroid: _centroid(vectors),
      participants: participants,
      memberThreads: memberThreads,
    );
  }

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

  Future<List<String>> _cardsOf(String storylineId) async {
    final cards = <String>[];
    for (final member in await _store.membersOf(storylineId)) {
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

  /// The dedupe key for a storyline's current member set: its conversation
  /// keys, sorted, hashed. Sorted because membership is a set — the same
  /// threads arriving in a different order are the same storyline.
  Future<String> _memberHashOf(String storylineId) async {
    return _hashOfKeys([
      for (final member in await _store.membersOf(storylineId))
        member.conversationKey,
    ]);
  }

  /// The one recipe behind `cluster_hash` and `member_hash`: conversation
  /// keys, sorted, newline-joined, hashed. Every writer goes through here —
  /// [MessageStore.dismissedHashExists] compares the two columns against a
  /// hash built the same way, so a second recipe drifting from this one would
  /// silently stop dismissals from being recognised.
  String _hashOfKeys(Iterable<String> keys) =>
      cardHash((keys.toList()..sort()).join('\n'));
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
