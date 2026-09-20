import 'dart:convert';

import '../models/message_models.dart';
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
}

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
      ClusteringCardVariant.topics => buildConversationCard(
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
/// against the `SWEEP_CARD=` that produced it. Every other variant is its own
/// name. [parseClusteringCardVariant] round-trips this.
extension ClusteringCardVariantWire on ClusteringCardVariant {
  String get wireName =>
      this == ClusteringCardVariant.subjectTopics ? 'subject_topics' : name;
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
      _ => throw ArgumentError.value(
          raw,
          'SWEEP_CARD',
          'must be one of participants, topics, subject, subject_topics, '
              'summary',
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
String clusteringCardForConversationRow(
  Map<String, Object?> row,
  Map<String, Object?>? cardData, {
  ClusteringCardVariant variant = shippedClusteringCard,
}) {
  final conversation = Conversation.fromRow(row);
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
