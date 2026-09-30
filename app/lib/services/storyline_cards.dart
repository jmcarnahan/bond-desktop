/// The card and vector statics both halves of the storyline work read.
///
/// They came out of `storyline_service.dart` when that file was split into the
/// service, `StorylineEdits` and `StorylineGrouper`: every one of them but
/// [clusteringCardFor] is a pure function of its arguments, and the passes
/// that build a card or order a cluster have to do it the same way.
/// [clusteringCardFor] reads the store (the thread text, the card data), and
/// lives here because it is the one entry to a thread's card. Public rather
/// than private to one half for exactly that reason, and re-exported by
/// `storyline_service.dart` so nothing that imported the service for them
/// has to change.
library;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'clustering_card.dart';
import 'conversation_state.dart';
import 'decision/storyline_state.dart' show renderStorylineCharter;
import 'decision/storyline_thread_input.dart';
import 'llm/embeddings_client.dart';
import 'llm/storyline_tasks.dart';

/// The indexes of the [take] vectors nearest the centroid of [vectors], most
/// central first; ties by index. Every index when [take] is at least
/// `vectors.length`.
///
/// The order is what makes dropping a card safe: the naming call reads a
/// cluster's cards in this order, so what falls off the end is the member
/// least like the rest, not whichever one the store happened to list last.
/// A cluster with no averageable vector keeps the store's order, which is
/// the honest answer when there is no centre to sort around.
List<int> centralIndexes(
  List<List<double>> vectors, {
  required int take,
}) {
  final all = [for (var i = 0; i < vectors.length; i++) i];
  // `mean` rather than `centroid`: the local would otherwise shadow the
  // top-level function it is initialised from.
  final mean = centroid(vectors);
  if (mean == null) return all.take(take).toList();
  final scored = [
    for (var i = 0; i < vectors.length; i++)
      (index: i, score: cosine(vectors[i], mean)),
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
/// The numbers are 1-based, so the namer can refer to a thread by the number
/// a person would read it under. Dropping whole cards rather than
/// truncating the joined string is the whole change: the old prompt fitted
/// every card into four thousand characters by cutting each one to eighty
/// characters, which left the model a list of subject lines. The sweep
/// orders by centrality, so a dropped card is an edge; the bootstrap path
/// passes member order and a dropped card there is the last member.
List<String> numberedCards(List<String> cards) {
  const separator = '\n---\n';
  final numbered = <String>[
    for (var i = 0; i < cards.length; i++)
      clampCard('[${i + 1}] ${cards[i]}'),
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

String clampCard(String card) =>
    card.length > NameStorylineTask.cardCap
        ? card.substring(0, NameStorylineTask.cardCap)
        : card;

/// The mean vector, or null when there is nothing to average. Not
/// re-normalised — [cosine] divides by both norms itself.
List<double>? centroid(List<List<double>> vectors) {
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

/// A thread's identity across sources, for set membership. Newline-joined
/// because a newline can appear in neither half.
String threadKey(String source, String conversationKey) =>
    '$source\n$conversationKey';

/// The card the NAMING prompt reads: the thin card plus the newest inbound
/// triage summary, and deliberately no topics.
///
/// Naming sees every member thread at once under one 4000-character cap, and
/// a topic list is the segment that says least per character it costs — the
/// sentence describing what was last said is what a title comes out of. The
/// membership prompt, which reads ONE card, can afford both. The newest
/// message's own words ([newestMessageExcerpt]) in place of the summary were
/// measured on 2026-09-30 at 55/98 against the summary's 60/98 on `make
/// golden-sweep` and do not ship.
String namingCardForConversationRow(
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

/// The card a THREAD is embedded from under [variant]: the one entry every
/// place that embeds a thread goes through (the assign pass and the golden
/// seed), so a bench and the app cannot build two cards.
///
/// [ClusteringCardVariant.text] is the thread text the decision model's
/// storyline questions read ([storylineThreadTextFor]), rendered over the
/// store, and [row] is not read. Every other variant is the pure
/// [clusteringCardForConversationRow] over [row] — the conversation row the
/// caller already holds — and the store's [MessageStore.clusteringCardData]
/// for that variant.
Future<String> clusteringCardFor(
  MessageStore store,
  String source,
  String conversationKey,
  Map<String, Object?> row, {
  ClusteringCardVariant variant = shippedClusteringCard,
}) async {
  if (variant == ClusteringCardVariant.text) {
    return (await storylineThreadTextFor(store, source, conversationKey)).text;
  }
  return clusteringCardForConversationRow(
    row,
    await store.clusteringCardData(source, conversationKey, variant: variant),
    variant: variant,
  );
}

/// The text a storyline's CHARTER is embedded from, for a storyline with no
/// member vector to average.
///
/// Under [ClusteringCardVariant.text] it is the decision model's own charter
/// rendering ([renderStorylineCharter]), so a charter and a thread text are
/// the same renderer family in one space. Every other card is
/// [buildClusteringCard] with the title in the subject slot and the charter
/// in the summary slot — `title |  |  | charter` for the shipped shapes, the
/// shape the threads it is compared with were built in.
String charterCardFor(
  String title,
  String charter, {
  ClusteringCardVariant variant = shippedClusteringCard,
}) =>
    variant == ClusteringCardVariant.text
        ? renderStorylineCharter(title: title, charter: charter)
        : buildClusteringCard(
            subject: title,
            participants: const [],
            topics: const [],
            summary: charter,
            variant: variant,
          );
