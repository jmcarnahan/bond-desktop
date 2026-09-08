/// How a search turns two rankings into one answer.
///
/// Pure arithmetic and string work over the models, with no I/O and no imports
/// above `models/` — which is what lets `MessageStore` reach down for
/// [buildFtsQuery] without the data layer growing a dependency on a service.
///
/// The problem it exists to solve: a nearest-neighbour index has no notion of
/// "nothing here is about that". Ask it for fifty neighbours and it returns
/// fifty, however far away they are, so "invoice" came back with the whole
/// mailbox. Words have the opposite failure — they find the message that
/// happens to contain "12" and rank it beside the one that answers the
/// question. One score built from both, with a floor under it, is what makes
/// an empty answer possible.
library;

import 'dart:math' as math;

import '../models/attachment_models.dart';
import '../models/home_models.dart';

/// Every number the ranking depends on, in one place.
///
/// Calibrated against a live mailbox on 2026-09-08 rather than chosen for
/// roundness. What the probe measured: a true hit sits at cosine distance
/// 0.43–0.64, noise starts at about 0.65, and the best row for a query the
/// mailbox contains NOTHING about was 0.77. So 0.45 is "as good as this
/// corpus gets" and 0.80 is "past the point where anything is real".
class SearchTuning {
  const SearchTuning._();

  /// The distance at and below which a vector hit is as relevant as they come.
  static const double vectorNear = 0.45;

  /// The distance at and above which a vector hit is worth nothing.
  static const double vectorFar = 0.80;

  /// The two halves of the score. Equal on purpose: the probe found neither
  /// signal reliably better than the other, and a row strong in one alone
  /// should show at half strength rather than lead.
  static const double vectorWeight = 0.5;
  static const double keywordWeight = 0.5;

  /// The floor. A row scoring under this is dropped rather than shown, which
  /// is the whole reason "Nothing matches that" became a possible answer.
  ///
  /// 0.25 is exactly "half-credit on one signal and nothing on the other" —
  /// low enough that a words-only hit on a gate-dropped newsletter still
  /// surfaces, high enough that the fiftieth neighbour does not.
  static const double minScore = 0.25;

  /// How many documents a search names, after the per-file collapse. Small
  /// because they sit above the message hits, and a page of passages would
  /// bury the thing most people came for.
  static const int documentLimit = 6;

  /// How many words of a query reach the index. A question-shaped query has a
  /// long tail of terms that add nothing but coverage denominators.
  static const int maxTerms = 8;

  /// How deep the keyword pass reads before fusion. Wider than the page
  /// because the floor and the vector half both cut into it afterwards.
  static const int keywordFetch = 200;
}

/// The words a query is not about.
///
/// English function words, plus the four nouns that describe the CONTAINER
/// rather than the content — a person typing "what messages are about lunch
/// plans" is asking about lunch, and leaving "messages" in the query makes
/// every message in the mailbox a partial match.
///
/// Removed only when removing them leaves something: "how are you" is a real
/// query for someone who remembers those exact words, and answering it with
/// silence because every word is on this list would be worse than answering
/// it badly.
const Set<String> searchStopwords = {
  'a',
  'about',
  'an',
  'and',
  'are',
  'as',
  'at',
  'be',
  'been',
  'but',
  'by',
  'can',
  'could',
  'did',
  'do',
  'does',
  'for',
  'from',
  'had',
  'has',
  'have',
  'he',
  'her',
  'his',
  'how',
  'i',
  'if',
  'in',
  'is',
  'it',
  'its',
  'me',
  'my',
  'no',
  'nor',
  'not',
  'of',
  'on',
  'or',
  'our',
  'she',
  'so',
  'that',
  'the',
  'their',
  'them',
  'then',
  'there',
  'these',
  'they',
  'this',
  'those',
  'to',
  'us',
  'was',
  'we',
  'were',
  'what',
  'when',
  'where',
  'which',
  'who',
  'whom',
  'why',
  'will',
  'with',
  'would',
  'you',
  'your',
  'message',
  'messages',
  'email',
  'emails',
  'mail',
};

/// A typed query, translated into something FTS5 will accept.
///
/// [terms] is what coverage is measured against — one rowid query per term —
/// and [match] is the expression the index is actually asked. They are one
/// object because a caller that computed coverage over a different word list
/// than it searched with would produce fractions that mean nothing.
class FtsQuery {
  /// The content words, lowercased, in the order they were typed.
  final List<String> terms;

  /// [terms] quoted and joined with OR.
  final String match;

  const FtsQuery(this.terms, this.match);
}

/// Turns what a person typed into an FTS5 MATCH expression, or null when
/// there are no words in it at all.
///
/// Built rather than passed through, and that is the whole point: FTS5's query
/// language reads `-` as exclusion, `:` as a column filter and a bare `NOT` as
/// an operator, so `retool -test`, `crm:login` and "not urgent" would each
/// either throw or quietly search for something else. Quoting every term makes
/// the parser read words as words.
///
/// OR and not AND. A question-shaped query ("what did the bank say about the
/// closing date") has words no single message contains all of, and AND answers
/// it with nothing. The coverage factor in [keywordRelevance] is what puts the
/// row matching five of six terms above the row matching one — which is the
/// job AND was doing badly.
///
/// No prefix `*`: the porter tokenizer already stems, so "plans" finds "plan".
///
/// The embedding still sees the untouched query. Meaning is not improved by
/// throwing away function words.
FtsQuery? buildFtsQuery(String text) {
  final tokens = [
    for (final match in RegExp(r"[\p{L}\p{N}']+", unicode: true).allMatches(text))
      match[0]!.toLowerCase(),
  ];
  if (tokens.isEmpty) return null;
  final content = [
    for (final token in tokens)
      if (!searchStopwords.contains(token)) token,
  ];
  // De-duplicated, and it is coverage rather than the wasted slot that makes
  // it matter: the fraction is counted once per element of [terms], so
  // 'lunch lunch plans' would score a row containing only "lunch" at two of
  // three instead of the honest one of two. A set literal built from a list
  // keeps insertion order, so nothing about the typed order moves.
  final terms = (content.isEmpty ? tokens : content)
      .toSet()
      .take(SearchTuning.maxTerms)
      .toList(growable: false);
  return FtsQuery(terms, [for (final term in terms) quoteTerm(term)].join(' OR '));
}

/// One term as an FTS5 string literal — double-quoted, with any quote inside
/// it doubled.
///
/// Public because the store asks the index one term at a time to work out
/// coverage, and a second spelling of this rule is how the coverage query and
/// the search query would start disagreeing about what a term is.
String quoteTerm(String term) => '"${term.replaceAll('"', '""')}"';

/// A vector hit's distance as a relevance from 0 to 1.
///
/// A ramp rather than `1 - distance`, because the useful range is narrow and
/// sits nowhere near either end: everything this corpus returns lands between
/// about 0.43 and 1.0, so the raw complement would compress every real
/// distinction into the top third of the scale and give a meaningless
/// neighbour 0.2 for free.
double vectorRelevance(double distance) {
  // A NaN would survive everything below it: `clamp` compares, and every
  // comparison against NaN is false, so it would pass the floor and then sort
  // ABOVE every real hit under `double.compareTo`'s total order. Nothing this
  // app runs produces one; the guard is one line and the failure would be a
  // nonsense row at the top of the page.
  if (!distance.isFinite) return 0;
  const near = SearchTuning.vectorNear;
  const far = SearchTuning.vectorFar;
  return ((far - distance) / (far - near)).clamp(0.0, 1.0);
}

/// A bm25 score as a relevance from 0 to 1, relative to the best score this
/// query found, discounted by how much of the query the row actually matched.
///
/// bm25 has no absolute scale — it depends on the corpus, the query and the
/// column weights — so the only honest reading of it is "how close to the best
/// thing here". [coverage] is the correction that ratio needs: a passage that
/// matched one rare term out of six can top the bm25 ranking on that term's
/// rarity alone, and `sqrt` discounts it without erasing it (a row matching
/// one of four terms keeps half its score, not a quarter).
double keywordRelevance({
  required double bm25,
  required double best,
  required double coverage,
}) {
  if (best <= 0) return 0;
  return ((bm25 / best) * math.sqrt(coverage.clamp(0.0, 1.0)))
      .clamp(0.0, 1.0);
}

/// Merges the two message rankings into the one list a screen shows.
///
/// Keyed on [HomeFeedRow.feedKey] rather than the message id: an id is unique
/// only within its connector, and a set keyed on half a key would drop a Teams
/// message because an email happened to share its id.
///
/// A missing signal scores zero rather than being imputed — a row the index
/// never saw (a gate-dropped message has no vector at all) is not penalised
/// for it beyond losing the half of the score it could not earn, which is
/// exactly the proportion the reader should see it at.
///
/// Null for either list means the pass did not run. It is treated the same as
/// empty here on purpose: the sentence explaining a half-search belongs on the
/// result, not in the arithmetic.
List<SearchHit> fuseMessages({
  required List<SemanticHit>? semantic,
  required List<KeywordHit>? keywords,
  required int limit,
}) {
  final distances = <String, double>{};
  final rows = <String, HomeFeedRow>{};
  for (final hit in semantic ?? const <SemanticHit>[]) {
    final key = hit.row.feedKey;
    rows.putIfAbsent(key, () => hit.row);
    distances[key] = hit.distance;
  }

  var best = 0.0;
  for (final hit in keywords ?? const <KeywordHit>[]) {
    if (hit.bm25 > best) best = hit.bm25;
  }
  final scores = <String, double>{};
  final coverages = <String, double>{};
  for (final hit in keywords ?? const <KeywordHit>[]) {
    final key = hit.row.feedKey;
    rows.putIfAbsent(key, () => hit.row);
    scores[key] = hit.bm25;
    coverages[key] = hit.coverage;
  }

  final fused = <SearchHit>[];
  for (final entry in rows.entries) {
    final distance = distances[entry.key];
    final bm25 = scores[entry.key];
    final vr = distance == null ? 0.0 : vectorRelevance(distance);
    final kr = bm25 == null
        ? 0.0
        : keywordRelevance(
            bm25: bm25,
            best: best,
            coverage: coverages[entry.key] ?? 0,
          );
    final score =
        SearchTuning.vectorWeight * vr + SearchTuning.keywordWeight * kr;
    if (score < SearchTuning.minScore) continue;
    fused.add(
      SearchHit(
        row: entry.value,
        score: score,
        distance: distance,
        bm25: bm25,
        matchedBy: distance == null
            ? MatchedBy.words
            : bm25 == null
                ? MatchedBy.meaning
                : MatchedBy.both,
      ),
    );
  }

  // Score, then recency, then the key — the last only so that two rows the
  // first two cannot separate come back in the same order every time.
  fused.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byDate = b.row.receivedAt.compareTo(a.row.receivedAt);
    if (byDate != 0) return byDate;
    return a.row.feedKey.compareTo(b.row.feedKey);
  });
  return fused.length <= limit ? fused : fused.sublist(0, limit);
}

/// The same arithmetic over document passages, grouped per FILE BEFORE any of
/// it runs.
///
/// Per file and not per attachment row: the same PDF attached to two messages
/// is two `attachments` rows with two ids, and a reader who searched for it
/// once wants to see it once. `blobSha256` is the identity when the bytes have
/// been fetched; name and size stand in when they have not, which is a weaker
/// claim but the only one available before a download.
///
/// Grouped FIRST, which is the difference from [fuseMessages] and the reason
/// this reads the way it does. The two halves arrive at different grain — the
/// vector side is already thinned to one passage per attachment row, the word
/// side deliberately is not — so scoring passages and collapsing afterwards
/// would leave a file the two halves found in DIFFERENT passages as two
/// single-signal entries, each earning half a score, and the better half
/// kept. A lease both halves matched moderately would then fall under the
/// floor that a message in the identical position clears. Grouping first is
/// what gives a file the both-signals boost the fusion exists to give.
///
/// The file's numbers are its BEST of each: the nearest distance any of its
/// passages reached, and the strongest bm25 with the coverage that earned it.
/// The passage SHOWN is the one behind whichever half scored higher, because
/// that is the fragment that explains why the file is on the page.
List<AttachmentChunkHit> fuseDocuments({
  required List<AttachmentChunkHit>? semantic,
  required List<AttachmentChunkHit>? keywords,
}) {
  var best = 0.0;
  for (final hit in keywords ?? const <AttachmentChunkHit>[]) {
    final bm25 = hit.bm25;
    if (bm25 != null && bm25 > best) best = bm25;
  }

  final byFile = <String, _FileSignals>{};
  for (final hit in <AttachmentChunkHit>[...?semantic, ...?keywords]) {
    final signals =
        byFile.putIfAbsent(documentIdentity(hit), _FileSignals.new);
    final distance = hit.distance;
    if (distance != null &&
        (signals.distance == null || distance < signals.distance!)) {
      signals.distance = distance;
      signals.nearest = hit;
    }
    final bm25 = hit.bm25;
    if (bm25 != null && (signals.bm25 == null || bm25 > signals.bm25!)) {
      signals.bm25 = bm25;
      signals.coverage = hit.coverage;
      signals.strongest = hit;
    }
  }

  final scored = <({AttachmentChunkHit hit, double score})>[];
  for (final signals in byFile.values) {
    final distance = signals.distance;
    final bm25 = signals.bm25;
    final vr = distance == null ? 0.0 : vectorRelevance(distance);
    final kr = bm25 == null
        ? 0.0
        : keywordRelevance(
            bm25: bm25,
            best: best,
            coverage: signals.coverage ?? 0,
          );
    final score =
        SearchTuning.vectorWeight * vr + SearchTuning.keywordWeight * kr;
    if (score < SearchTuning.minScore) continue;
    // Ties go to the vector passage: it is the one already thinned to the
    // single best passage of its attachment, so it is the safer thing to quote.
    final representative =
        (kr > vr ? signals.strongest : signals.nearest) ??
            signals.strongest ??
            signals.nearest;
    if (representative == null) continue;
    scored.add((
      // Carrying the FILE's numbers and not the passage's own, so a screen
      // reading `distance` or `bm25` off a hit reads what the score was
      // actually built from.
      hit: representative.withSignals(
        distance: distance,
        bm25: bm25,
        coverage: signals.coverage,
      ),
      score: score,
    ));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.hit.chunkId.compareTo(b.hit.chunkId);
  });

  return [
    for (final entry in scored.take(SearchTuning.documentLimit)) entry.hit,
  ];
}

/// The best each half of the search did on ONE file, and the passage behind
/// each.
///
/// Mutable and private: it exists for the length of one [fuseDocuments] call,
/// as the accumulator of a grouping pass, and a copy-on-write record would
/// allocate once per passage to say the same thing.
class _FileSignals {
  double? distance;
  AttachmentChunkHit? nearest;
  double? bm25;
  double? coverage;
  AttachmentChunkHit? strongest;
}

/// What makes two attachment rows the same FILE.
///
/// Named rather than inlined because the collapse and any later "you have seen
/// this one" have to agree about it byte for byte.
String documentIdentity(AttachmentChunkHit hit) =>
    hit.ref.blobSha256 ?? '${hit.ref.name}|${hit.ref.size}';
