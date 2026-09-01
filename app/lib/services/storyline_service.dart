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
  /// Higher than the assignment gates because a suggestion has no existing
  /// group to be judged against — the cluster IS the claim.
  static const double clusterLinkThreshold = 0.65;

  /// A storyline of one is just a thread.
  static const int minClusterSize = 2;

  /// How many unanswered suggestions may sit in the rail at once. A wall of
  /// proposals is not a feature; it is a chore, and it gets dismissed as one.
  static const int maxPendingSuggestions = 3;

  /// Below this there is not enough unassigned mail for a cluster to mean
  /// anything, and the sweep would be proposing groups out of noise.
  static const int sweepMinUnassigned = 4;
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
  static const String _source = 'email';

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

  /// Cryptographic randomness for ids. Not for secrecy — for the guarantee
  /// that two ids generated in the same millisecond differ, which a
  /// time-seeded generator does not give.
  static final math.Random _random = math.Random.secure();

  StorylineService(
    this._store,
    LlmClient client, {
    LlmClient? confirmClient,
    ActivityLog? activityLog,
  })  : _client = client,
        _confirmClient = confirmClient ?? client,
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
  Future<void> assignConversation(String source, String conversationKey) async {
    final vector = await _vectorFor(source, conversationKey);
    // No comparable vector yet. Silent rather than an error: the extraction
    // handler re-queues this item the moment it writes an embedding, so the
    // thread is not lost, it is simply not ready.
    if (vector == null) return;

    final row = await _store.getConversationRow(source, conversationKey);
    if (row == null) return;

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

    for (final storyline in candidates) {
      if (await _store.isMemberBlocked(storyline.id, source, conversationKey)) {
        continue;
      }

      final members = await _store.membersOf(storyline.id);
      if (members.any((m) =>
          m.source == source && m.conversationKey == conversationKey)) {
        continue;
      }

      final vectors = <List<double>>[];
      final memberParticipants = <String>{};
      for (final member in members) {
        final memberVector =
            await _vectorFor(member.source, member.conversationKey);
        if (memberVector != null) vectors.add(memberVector);
        final memberRow = await _store.getConversationRow(
          member.source,
          member.conversationKey,
        );
        if (memberRow == null) continue;
        for (final display in _displaysOf(Conversation.fromRow(memberRow))) {
          memberParticipants.add(display.toLowerCase());
        }
      }
      // A storyline whose members have no vectors cannot be compared against
      // anything. Skipped rather than guessed at.
      final centroid = _centroid(vectors);
      if (centroid == null) continue;

      final overlap = participants
          .any((display) => memberParticipants.contains(display.toLowerCase()));
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

    if (best == null) return;

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
    if (!result.belongs || result.confidence == 'low') return;

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

    await _store.updateStoryline(
      storylineId,
      // A locked title is the user's, and no later pass may take it back. The
      // summary is refreshed either way — it describes where the storyline
      // stands, which is not something a rename claimed ownership of.
      title: storyline.titleLocked ? null : result.title,
      summary: result.summary,
    );

    // A separate, conditional write: a locked charter is the user's, the same
    // contract `title_locked` gives the title. An empty answer is not written
    // either — a storyline whose charter was never drafted is judged against
    // its summary, which is strictly better than judging it against nothing.
    if (!storyline.charterLocked && result.charter.isNotEmpty) {
      await _store.updateStoryline(storylineId, charter: result.charter);
    }
  }

  // ── automatic: the whole mailbox ───────────────────────────────────────

  /// Proposes new storylines out of whatever is not in one yet.
  ///
  /// Runs after every sync, and is a no-op nearly every time: it does nothing
  /// while suggestions are already waiting, nothing when there is too little
  /// unassigned mail to group, and nothing when the clusters it finds have all
  /// been dismissed before.
  Future<void> sweep() async {
    final pending =
        (await _store.loadStorylines(statuses: const ['suggested'])).length;
    final room = StorylineTuning.maxPendingSuggestions - pending;
    if (room <= 0) return;

    final taken = await _store.assignedOrBlockedKeys(_source);
    final rows = <Map<String, Object?>>[];
    final vectors = <List<double>>[];
    for (final row in await _store.conversationsWithEmbeddings(
      embedModel: EmbeddingsClient.modelTag,
      sources: const [_source],
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
    for (final cluster in _cluster(vectors)) {
      if (proposed >= room) break;
      if (await _propose([for (final index in cluster) rows[index]])) {
        proposed++;
      }
    }

    // Once at the end, not once per proposal: the sweep is one unit of work
    // and gets one row, so a per-cluster note would just overwrite itself.
    if (proposed > 0) _log.note({'proposed': proposed});
  }

  /// Single-link greedy agglomeration, in one pass.
  ///
  /// Each conversation, in the order the store handed them over (newest first,
  /// key ascending — a total order with no ties), joins the FIRST existing
  /// cluster holding a member it links to, and otherwise opens one of its own.
  /// That makes the result a pure function of the input: same rows and same
  /// vectors in, same clusters out, which is what
  /// [MessageStore.dismissedMemberHashExists] depends on to recognise a
  /// suggestion the user already threw away.
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

  /// Names one cluster and stores it as a suggestion. Returns whether a
  /// suggestion was actually created, so the sweep can budget its room on
  /// results rather than attempts.
  Future<bool> _propose(List<Map<String, Object?>> rows) async {
    final keys = [
      for (final row in rows) row['conversation_key'] as String? ?? '',
    ]..sort();
    final memberHash = cardHash(keys.join('\n'));
    if (await _store.dismissedMemberHashExists(memberHash)) return false;

    final cards = <String>[];
    for (final row in rows) {
      cards.add(_namingCardForConversationRow(
        row,
        await _store.newestInboundCardData(
          row['source'] as String? ?? _source,
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
    await _store.insertStoryline(
      id: id,
      title: result.title,
      summary: result.summary,
      charter: result.charter.isEmpty ? null : result.charter,
      status: 'suggested',
      createdBy: 'auto',
      memberHash: memberHash,
    );
    for (final row in rows) {
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty) continue;
      await _store.addStorylineMember(
        id,
        row['source'] as String? ?? _source,
        key,
        addedBy: 'auto',
        // The cluster is its own reason: nothing judged these threads
        // individually, so claiming a per-thread justification would be
        // inventing one.
        evidence: 'clustered together',
      );
      final lastMessageAt = row['last_message_at'] as String?;
      if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
        await _store.touchStorylineActivity(id, lastMessageAt);
      }
    }
    return true;
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

  /// Dismisses a suggestion. The member rows stay: they are what
  /// `member_hash` was computed over, and deleting them would leave the app
  /// unable to recognise the same cluster when the very next sweep rebuilds
  /// it.
  Future<void> dismissSuggestion(String id) =>
      _store.updateStoryline(id, status: 'dismissed');

  Future<void> rename(String id, String title) =>
      _store.updateStoryline(id, title: title, titleLocked: true);

  Future<void> addThread(String id, String source, String key) async {
    await _store.addStorylineMember(id, source, key, addedBy: 'user');
    await _store.updateStoryline(id, memberHash: await _memberHashOf(id));
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
    final keys = [
      for (final member in await _store.membersOf(storylineId))
        member.conversationKey,
    ]..sort();
    return cardHash(keys.join('\n'));
  }
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
