import 'dart:convert';

import '../models/message_models.dart';
import 'chat_roster.dart' show isTeamsNamesSubject;
import 'conversation_state.dart';

/// The text a conversation becomes before anything measures it against another
/// conversation.
///
/// Its own file since Round E Phase 1, for two reasons. The first is a cycle:
/// the card builder lived in `extract_handler.dart` and the row recipe in
/// `storyline_service.dart`, and each imported the other for its half, so
/// neither file could be read without the other. The second is that the card
/// is now a VARIABLE rather than a constant — Round D measured two shapes of
/// it and Round E measures five — and a variable with a home is a variable a
/// bench can ask for by name.
///
/// Everything here is pure: a row map in, a string out, no store, no clock and
/// no client. That is what lets `make golden-vector` price a card without
/// running the app.

/// The text a conversation is embedded from.
///
/// Always four segments joined by ` | `, empty ones included: the shape is
/// fixed so the same thread produces the same card twice, which is what makes
/// [cardHash] a usable "has anything changed" test. Order runs from most to
/// least stable — subject, who is on it, what it is about, what was last said
/// — so a passing remark moves the vector less than a change of topic.
String buildConversationCard({
  required String? subject,
  required List<String> participants,
  required List<String> topics,
  required String? summary,
}) =>
    [
      subject?.trim() ?? '',
      participants.join(', '),
      topics.join(', '),
      summary?.trim() ?? '',
    ].join(' | ');

/// Which of the four segments ride inside the CLUSTERING vector.
///
/// One enum and not a set of flags, because these are the shapes that have
/// been measured against one mailbox and not an arbitrary combination: a row
/// in the ledger names one of these words, and a word that was never run has
/// no row. Every variant goes through [buildConversationCard]'s four-segment
/// shape with the segments it drops left EMPTY rather than removed, so the
/// joiner, the segment count and therefore [cardHash] mean the same thing
/// whichever one the app is on.
///
/// The prompts are not on this axis at all. The naming and membership tasks
/// read [buildConversationCard]'s full card whatever the vector does — who is
/// on a thread is the strongest thing a model can be told about it, and the
/// reason to drop the people from the VECTOR is the opposite case: in a
/// mailbox where one team is on everything, the same names in every card pull
/// every pair of threads together.
enum ClusteringCardVariant {
  /// `subject |  | topics | summary` — what the app ships.
  topics,

  /// `subject | participants | topics | summary` — what it shipped before
  /// Round D Phase 2, and byte-identical to the prompt card.
  participants,

  /// `subject |  |  | ` — the subject line alone, the lexical control.
  subject,

  /// `subject |  | topics | ` — the durable half, with the newest summary
  /// left out so a thread's vector stops moving every time somebody replies.
  subjectTopics,

  /// ` |  | topics | summary` — what the thread is about with no subject line
  /// at all, for a mailbox whose subjects are boilerplate.
  summary,

  /// `subject |  | project, topics | summary` built from the THREAD rather
  /// than its newest message (decision-model round, Phase 8): the topics of
  /// the thread's newest [threadCardMessages] kept inbound messages merged
  /// (case-insensitively de-duplicated, newest first, at most
  /// [threadCardTopicCap]), the thread's `project` — the most frequent
  /// non-empty one across those messages, ties to the newest — in front of
  /// them, and the newest kept inbound summary. Its data comes from
  /// `MessageStore.threadCardData`, which `MessageStore.clusteringCardData`
  /// picks for this variant.
  ///
  /// It also leaves the subject EMPTY on an untitled Teams chat — one whose
  /// subject is the participant names the sync wrote on first sight
  /// ([isTeamsNamesSubject]) — so the same few names on every chat stop
  /// pulling unrelated chats together. That rule rides on this variant only,
  /// on purpose: the two changes are measured together by one
  /// `SWEEP_CARD=thread` row, and every other variant stays byte-identical to
  /// the rows already in the ledger. Display is untouched; the names stay the
  /// chat's subject everywhere a person reads it.
  thread,

  /// `subject |  | topics | summary` — exactly [topics], the shipped card,
  /// except that an untitled Teams chat ([isTeamsNamesSubject]) gets an
  /// EMPTY subject. The untitled rule alone, measured apart from the thread
  /// merge after `SWEEP_CARD=thread` cost one `storyline.id` point.
  topicsUntitled,
}

/// How many of a thread's newest kept inbound messages the
/// [ClusteringCardVariant.thread] card reads.
const int threadCardMessages = 5;

/// How many merged topics the [ClusteringCardVariant.thread] card carries.
const int threadCardTopicCap = 5;

/// The variant the app embeds.
///
/// Round D Phase 2 measured [ClusteringCardVariant.topics] against
/// [ClusteringCardVariant.participants] through `make golden-sweep
/// SWEEP_CARD=participants|topics`, twice each, over the same 95 seeded
/// conversations. The rule was written before the runs: `topics` ships only if
/// it beats `participants` by at least four points on `storyline.id` on both
/// passes, or ties within four with a smaller largest-storyline share and no
/// fewer correct positives. It beat it by eight — 31 of 98 against 23 of 98 —
/// with purity over the storylines that carried gold members moving from 44%
/// to 71% and the largest storyline's share of every filed thread falling from
/// 56% to 47%. Neither card produced a correct positive.
///
/// Round E Phase 1 measures the other three through `make golden-vector`,
/// which reads the vector alone and needs no chat model to do it.
///
/// Moving this constant orphans every stored conversation vector by
/// construction, since every read filters on the tag, so it moves together
/// with [EmbeddingsClient.modelTag] and the one-shot in `sync_service.dart`
/// that requeues the old-tag threads a slice at a time until they carry a
/// vector in the new geometry.
const ClusteringCardVariant shippedClusteringCard = ClusteringCardVariant.topics;

/// The text a conversation is EMBEDDED from: [buildConversationCard]'s shape
/// with [variant]'s segments kept and the rest left empty.
String buildClusteringCard({
  String? subject,
  required List<String> participants,
  required List<String> topics,
  String? summary,
  required ClusteringCardVariant variant,
}) =>
    switch (variant) {
      // `thread` and `topicsUntitled` are the shipped shape too: the thread's
      // facts arrive already merged (project first, then the topics), and an
      // untitled chat's subject already emptied, from
      // [clusteringCardForConversationRow].
      ClusteringCardVariant.topics ||
      ClusteringCardVariant.topicsUntitled ||
      ClusteringCardVariant.thread =>
        buildConversationCard(
          subject: subject,
          participants: const [],
          topics: topics,
          summary: summary,
        ),
      ClusteringCardVariant.participants => buildConversationCard(
          subject: subject,
          participants: participants,
          topics: topics,
          summary: summary,
        ),
      ClusteringCardVariant.subject => buildConversationCard(
          subject: subject,
          participants: const [],
          topics: const [],
          summary: null,
        ),
      ClusteringCardVariant.subjectTopics => buildConversationCard(
          subject: subject,
          participants: const [],
          topics: topics,
          summary: null,
        ),
      ClusteringCardVariant.summary => buildConversationCard(
          subject: null,
          participants: const [],
          topics: topics,
          summary: summary,
        ),
    };

/// The word a variant is named by on a command line and in a result file.
///
/// `subjectTopics` is `subject_topics` on the wire and nowhere else: Dart
/// spells an enum in camel case and a define is typed by hand in snake case,
/// and a result file that recorded the Dart spelling could not be matched
/// against the `SWEEP_CARD=` that produced it; `topicsUntitled` is
/// `topics_untitled` for the same reason. Every other variant is its own
/// name. [parseClusteringCardVariant] round-trips this.
extension ClusteringCardVariantWire on ClusteringCardVariant {
  String get wireName => switch (this) {
        ClusteringCardVariant.subjectTopics => 'subject_topics',
        ClusteringCardVariant.topicsUntitled => 'topics_untitled',
        _ => name,
      };
}

/// The variant a define names, or a thrown [ArgumentError].
///
/// Loud rather than defaulted: this define IS the variable the vector bench
/// was built to price, and a typo that quietly measured one card twice would
/// put two rows in the ledger that look like an A/B and are not.
ClusteringCardVariant parseClusteringCardVariant(String raw) =>
    switch (raw.trim().toLowerCase()) {
      'topics' => ClusteringCardVariant.topics,
      'participants' => ClusteringCardVariant.participants,
      'subject' => ClusteringCardVariant.subject,
      'subject_topics' => ClusteringCardVariant.subjectTopics,
      'summary' => ClusteringCardVariant.summary,
      'thread' => ClusteringCardVariant.thread,
      'topics_untitled' => ClusteringCardVariant.topicsUntitled,
      _ => throw ArgumentError.value(
          raw,
          'SWEEP_CARD',
          'must be one of participants, topics, subject, subject_topics, '
              'summary, thread, topics_untitled',
        ),
    };

/// The card a conversation is EMBEDDED from, built from a stored row and the
/// stored facts of its newest kept inbound message.
///
/// The one recipe over one data source, so the embed handler and the sweep's
/// own re-embed cannot drift apart and the stored hash column means one thing.
/// [variant] defaults to what the app ships, so the two callers inside `lib/`
/// pass nothing and cannot drift from it; it is a parameter at all for the
/// benches, which price a card the app is NOT currently writing through this
/// same recipe rather than through a second copy of it.
///
/// For [ClusteringCardVariant.thread], [cardData] is
/// `MessageStore.threadCardData`'s shape: the newest kept inbound message's
/// `summary` and `extraction_json`, plus `thread_extractions`, the
/// extraction blobs of the thread's newest [threadCardMessages] kept inbound
/// messages, newest first. A map without that list (an older caller, or
/// `newestInboundCardData`) reads as a one-message thread.
String clusteringCardForConversationRow(
  Map<String, Object?> row,
  Map<String, Object?>? cardData, {
  ClusteringCardVariant variant = shippedClusteringCard,
}) {
  final conversation = Conversation.fromRow(row);
  bool untitledChat() =>
      conversation.source == 'teams' &&
      isTeamsNamesSubject(conversation.subject, [
        for (final participant in conversation.participants)
          {'name': participant.name, 'email': participant.email},
      ]);
  if (variant == ClusteringCardVariant.topicsUntitled && untitledChat()) {
    return buildClusteringCard(
      subject: null,
      participants: const [],
      topics: topicsOfExtraction(cardData?['extraction_json']),
      summary: cardData?['summary'] as String?,
      variant: variant,
    );
  }
  if (variant == ClusteringCardVariant.thread) {
    final raw = cardData?['thread_extractions'];
    final extractions = raw is List
        ? List<Object?>.of(raw)
        : [cardData?['extraction_json']];
    return buildClusteringCard(
      subject: untitledChat() ? null : stripReFw(conversation.subject),
      participants: const [],
      topics: threadCardTopics(extractions),
      summary: cardData?['summary'] as String?,
      variant: variant,
    );
  }
  return buildClusteringCard(
    subject: stripReFw(conversation.subject),
    participants: [
      for (final participant in conversation.participants)
        if (participant.display.isNotEmpty) participant.display,
    ],
    topics: topicsOfExtraction(cardData?['extraction_json']),
    summary: cardData?['summary'] as String?,
    variant: variant,
  );
}

/// The `topics` list out of a stored extraction blob, or nothing. Every step
/// can fail against a row an older build wrote, and every failure is the same
/// answer: no topics, which is the card this app sent before there were any.
List<String> topicsOfExtraction(Object? extractionJson) {
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

/// The `project` string out of a stored extraction blob, trimmed, or empty.
/// Fails to empty for [topicsOfExtraction]'s reason.
String projectOfExtraction(Object? extractionJson) {
  if (extractionJson is! String || extractionJson.isEmpty) return '';
  final Object? decoded;
  try {
    decoded = jsonDecode(extractionJson);
  } on FormatException {
    return '';
  }
  if (decoded is! Map) return '';
  final project = decoded['project'];
  return project is String ? project.trim() : '';
}

/// The third segment of the [ClusteringCardVariant.thread] card, over the
/// thread's extraction blobs NEWEST FIRST: the thread's project, then its
/// merged topics.
///
/// The project is the most frequent non-empty one, counted
/// case-insensitively; a tie goes to the one seen first, which is the newest,
/// and it is spelled the way that message spelled it. The topics are every
/// blob's topics in order — newest message first, each message's own order
/// inside it — de-duplicated case-insensitively (a topic equal to the project
/// is dropped as a duplicate of it) and capped at [threadCardTopicCap]. The
/// project does not count against the cap.
List<String> threadCardTopics(List<Object?> extractionsNewestFirst) {
  final counts = <String, int>{};
  final spelling = <String, String>{};
  for (final blob in extractionsNewestFirst) {
    final project = projectOfExtraction(blob);
    if (project.isEmpty) continue;
    final key = project.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    spelling.putIfAbsent(key, () => project);
  }
  String? project;
  var best = 0;
  // Insertion order is newest-first, and only a strictly larger count
  // replaces the leader, so a tie stays with the newest.
  for (final entry in counts.entries) {
    if (entry.value > best) {
      best = entry.value;
      project = spelling[entry.key];
    }
  }

  final seen = <String>{if (project != null) project.toLowerCase()};
  final topics = <String>[];
  outer:
  for (final blob in extractionsNewestFirst) {
    for (final topic in topicsOfExtraction(blob)) {
      final trimmed = topic.trim();
      if (trimmed.isEmpty) continue;
      if (!seen.add(trimmed.toLowerCase())) continue;
      topics.add(trimmed);
      if (topics.length >= threadCardTopicCap) break outer;
    }
  }
  return [?project, ...topics];
}
