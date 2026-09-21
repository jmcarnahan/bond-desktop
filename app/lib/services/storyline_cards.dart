/// The card and vector statics both halves of the storyline work read.
///
/// They came out of `storyline_service.dart` when that file was split into the
/// service, `StorylineEdits` and `StorylineGrouper`: every one of them is a
/// pure function of its arguments, and the naming pass, the grouping pass and
/// the confirms all have to build a card and order a cluster the same way or
/// the model that groups a thread reads something different from the model
/// that names it. Public rather than private to one half for exactly that
/// reason, and re-exported by `storyline_service.dart` so nothing that imported
/// the service for them has to change.
library;

import '../models/message_models.dart';
import 'clustering_card.dart';
import 'conversation_state.dart';
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
/// [cap], which defaults to [NameStorylineTask.cardsCap]. Only the grouping
/// call passes one, and only because `GroupingMode.pool` shows four times
/// as many cards as the namer ever does; every other caller builds to the
/// namer's set, which is what makes a card read the same to the model that
/// groups it as to the model that names it.
///
/// The numbers are what the prompt's `outliers` rule points at, so they are
/// 1-based and the caller maps them back. Dropping whole cards rather than
/// truncating the joined string is the whole change: the old prompt fitted
/// every card into four thousand characters by cutting each one to eighty
/// characters, which left the model a list of subject lines. The sweep
/// orders by centrality, so a dropped card is an edge; the bootstrap path
/// passes member order and a dropped card there is the last member.
List<String> numberedCards(
  List<String> cards, {
  int cap = NameStorylineTask.cardsCap,
}) {
  const separator = '\n---\n';
  final numbered = <String>[
    for (var i = 0; i < cards.length; i++)
      clampCard('[${i + 1}] ${cards[i]}'),
  ];
  var total = 0;
  final kept = <String>[];
  for (final card in numbered) {
    final cost = card.length + (kept.isEmpty ? 0 : separator.length);
    if (total + cost > cap) break;
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
/// membership prompt, which reads ONE card, can afford both.
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
