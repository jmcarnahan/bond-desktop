import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/conversation_state.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/storyline_clustering.dart';
import 'package:bond_inbox/services/storyline_lint.dart';
import 'package:bond_inbox/services/storyline_service.dart';

import 'golden_set.dart';

/// Everything the sweep replay decides that is not a model call.
///
/// The live test drives the app's own `StorylineService` over a seeded
/// mailbox; what it then has to work out is which gold storyline each app
/// storyline turned out to BE, and therefore which `storyline.id` every golden
/// item was filed under. That is the whole of this file, and it is pure so
/// that `golden_sweep_test.dart` can pin it offline — the live run needs three
/// servers and is `@Skip`'d, so nothing inside it is covered by the gate.
///
/// **Nothing here scores anything.** The derived id goes into a run file and
/// `golden/tools/score_run.py` applies the must/should/may/forbidden rules to
/// it, exactly as for every other golden row. The tallies below are the run's
/// own arithmetic about its own behaviour — how pure the groups were, how much
/// of each effort it gathered, how big the biggest group got — which is a
/// different question from "was it right".
///
/// **Everything it prints is counts, ratios and enums.** The storylines this
/// measures are named out of real mail, so no title, charter, evidence
/// sentence, subject, participant or slug reaches stdout. The slug-keyed maps
/// exist in [SweepTally.toJson] alone, which lands in the git-ignored result
/// JSON beside the run file that already holds the real content.

/// The one thread id both halves agree on: `'<source>\n<key>'`, the same
/// composite `StorylineService._threadKey` writes. Source is half of a
/// thread's identity — the two connectors mint keys with no knowledge of each
/// other.
String threadKeyOf(String source, String conversationKey) =>
    '$source\n$conversationKey';

/// The id an app storyline that maps to no gold effort is read as.
///
/// A miss on every gold value INCLUDING `none`, and that is intended: an item
/// filed into a group that answers to nothing is not an item filed nowhere. It
/// is an item filed into junk, and the scorer should say so.
const String unmappedId = 'unmapped';

/// The id an item in no storyline at all is read as — the assertion "no
/// storyline", which 35 items of the real set carry as their gold label.
const String noneId = 'none';

/// Which gold effort each app storyline turned out to be.
///
/// **Plurality of its members' gold ids**: the slug held by at least half of
/// the members that carry one, and by at least two of them. Anything else is
/// [unmappedId]. Two of them, because a single member is not evidence of what
/// a group is about, and a storyline of two threads that agree is; half,
/// because a group that is mostly one effort IS that effort with some
/// contamination, and the contamination is what [SweepTally.purity] reports.
///
/// `none` never wins. A thread gold files nowhere carries no slug, so it is
/// outside the denominator entirely — a storyline built only from such threads
/// maps nowhere, which is the honest reading of a group assembled out of mail
/// that belongs to no effort.
///
/// A tie at exactly half goes to the alphabetically smaller slug, which is
/// blind to gold and deterministic. Ties are rare and the mapping has to be a
/// pure function: two readings of one run must not disagree.
Map<String, String> mapStorylinesToSlugs({
  required Map<String, List<String>> members,
  required Map<String, String> goldByThread,
}) {
  final mapping = <String, String>{};
  for (final entry in members.entries) {
    mapping[entry.key] = _pluralitySlug(entry.value, goldByThread) ?? unmappedId;
  }
  return mapping;
}

/// The slug a plurality of [threads] carries, or null when none qualifies.
String? _pluralitySlug(List<String> threads, Map<String, String> goldByThread) {
  final counts = <String, int>{};
  var carrying = 0;
  for (final thread in threads) {
    final slug = goldByThread[thread];
    if (slug == null || slug == noneId || slug.isEmpty) continue;
    carrying++;
    counts[slug] = (counts[slug] ?? 0) + 1;
  }
  if (carrying == 0) return null;

  String? best;
  var bestCount = 0;
  for (final slug in counts.keys.toList()..sort()) {
    if (counts[slug]! > bestCount) {
      best = slug;
      bestCount = counts[slug]!;
    }
  }
  if (best == null || bestCount < 2) return null;
  return bestCount * 2 >= carrying ? best : null;
}

/// The share of [threads] carrying a gold slug that carry the plurality one.
///
/// NULL when no member carries a slug at all. Not zero: a group of threads
/// gold files nowhere is not an impure group, it is a group there is nothing
/// to be pure about, and averaging a zero in would report the sweep as dirtier
/// than it was. [mapStorylinesToSlugs] reads the same case as unmapped.
double? purityOf(List<String> threads, Map<String, String> goldByThread) {
  final counts = <String, int>{};
  var carrying = 0;
  for (final thread in threads) {
    final slug = goldByThread[thread];
    if (slug == null || slug == noneId || slug.isEmpty) continue;
    carrying++;
    counts[slug] = (counts[slug] ?? 0) + 1;
  }
  if (carrying == 0) return null;
  final top = counts.values.fold(0, (a, b) => a > b ? a : b);
  return top / carrying;
}

/// The `storyline.id` this run filed every item under.
///
/// Three answers and no fourth: the slug of the storyline the item's THREAD
/// landed in, [unmappedId] when that storyline maps to no gold effort, and
/// [noneId] when the thread is in no storyline. Two golden items drawn from
/// one conversation therefore derive the same id, because the app files
/// threads and not messages.
Map<String, String> deriveSweepIds({
  required List<GoldenItem> items,
  required Map<String, String> storylineByThread,
  required Map<String, String> slugByStoryline,
}) {
  final derived = <String, String>{};
  for (final item in items) {
    final storyline =
        storylineByThread[threadKeyOf(item.source, item.conversationKey)];
    derived[item.id] =
        storyline == null ? noneId : (slugByStoryline[storyline] ?? unmappedId);
  }
  return derived;
}

/// The gold slug of every thread the set draws from.
///
/// Keyed by thread for [deriveSweepIds]'s reason. When two items of one
/// conversation disagree, the one that names an effort wins over the one that
/// names none: gold files threads under an effort, and an item drawn from a
/// filed thread that happens to carry `none` is a statement about that
/// message, not about the thread.
Map<String, String> goldSlugByThread(GoldenSet set) {
  final byThread = <String, String>{};
  for (final item in set.items) {
    final key = threadKeyOf(item.source, item.conversationKey);
    final slug = item.gold.storylineId;
    final existing = byThread[key];
    if (existing == null || (existing == noneId && slug != noneId)) {
      byThread[key] = slug;
    }
  }
  return byThread;
}

/// How many golden THREADS gold files under each slug — the coverage
/// denominators. `none` is not a slug and is left out.
Map<String, int> goldThreadsBySlug(GoldenSet set) {
  final counts = <String, int>{};
  for (final slug in goldSlugByThread(set).values) {
    if (slug == noneId || slug.isEmpty) continue;
    counts[slug] = (counts[slug] ?? 0) + 1;
  }
  return counts;
}

/// The live storylines and their members, as the store holds them after a run.
class SweepMembership {
  /// Storyline id → the thread keys it holds, in `membersOf` order.
  final Map<String, List<String>> threadsByStoryline;

  /// The transpose. A thread is a member of at most one live storyline in
  /// practice — the assign pass files into one and the sweep's taken-set keeps
  /// it out afterwards — and the LAST writer wins here if that ever stops
  /// being true, which the largest-share number would make visible.
  final Map<String, String> storylineByThread;

  const SweepMembership({
    required this.threadsByStoryline,
    required this.storylineByThread,
  });

  int get storylines => threadsByStoryline.length;

  int get filedThreads => storylineByThread.length;

  /// The largest storyline's share of every thread filed anywhere — the
  /// chaining number. 0 when nothing was filed.
  double get largestShare {
    if (storylineByThread.isEmpty) return 0;
    var largest = 0;
    for (final threads in threadsByStoryline.values) {
      if (threads.length > largest) largest = threads.length;
    }
    return largest / storylineByThread.length;
  }
}

/// Reads the memberships back out of the store after a sweep.
///
/// `suggested` AND `active`, which is the set `assignConversation` itself
/// considers: a suggestion nobody has answered is still a group a thread can
/// belong to. Dismissed rows are tombstones and hold no live membership.
Future<SweepMembership> readSweepMembership(MessageStore store) async {
  final threadsByStoryline = <String, List<String>>{};
  final storylineByThread = <String, String>{};
  for (final storyline
      in await store.loadStorylines(statuses: const ['suggested', 'active'])) {
    final threads = <String>[];
    for (final member in await store.membersOf(storyline.id)) {
      final key = threadKeyOf(member.source, member.conversationKey);
      threads.add(key);
      storylineByThread[key] = storyline.id;
    }
    threadsByStoryline[storyline.id] = threads;
  }
  return SweepMembership(
    threadsByStoryline: threadsByStoryline,
    storylineByThread: storylineByThread,
  );
}

/// The cosine bins the clustering floor is read from — four edges, five bins.
///
/// The bottom bin is everything under the loosest gate either pass uses and
/// the top is everything at or above `clusterLinkThreshold`, so the three in
/// between are the range a coherence floor could plausibly be set in. Counted
/// over every pair INSIDE a cluster the sweep formed, which is the population
/// the floor would judge.
///
/// On the embeddinggemma scale. The Qwen vector shipped in Round E runs its
/// gates at 0.48 / 0.43, under the bottom edge, so on that scale this
/// histogram reads close to one bucket and `separation.points` at 0.65 is
/// off-scale; the scale-free columns (recall-70 and cross-5) are the read.
/// Rescaling the edges is a Round F harness item (plan gotcha 64, item 10);
/// kept as is so the Round D rows stay comparable.
const List<double> cosineBinEdges = [0.50, 0.55, 0.60, 0.65];

/// The bins' names, for a printed row. Enums, not data.
const List<String> cosineBinLabels = [
  '<0.50',
  '0.50-0.55',
  '0.55-0.60',
  '0.60-0.65',
  '>=0.65',
];

/// [similarities] counted into [cosineBinLabels]' five buckets.
List<int> cosineBins(Iterable<double> similarities) {
  final bins = List<int>.filled(cosineBinLabels.length, 0);
  for (final value in similarities) {
    var index = cosineBinEdges.length;
    for (var i = 0; i < cosineBinEdges.length; i++) {
      if (value < cosineBinEdges[i]) {
        index = i;
        break;
      }
    }
    bins[index]++;
  }
  return bins;
}

/// One storyline's own description, as the lint reads it.
class LintCandidate {
  final String title;
  final String charter;
  final List<String> participants;

  const LintCandidate({
    required this.title,
    required this.charter,
    required this.participants,
  });
}

/// How many of [storylines] each lint verdict would refuse, plus how many it
/// passes.
///
/// Counted rather than applied: in Phase 1 `charterLint` is not wired into
/// `_propose` at all, so this says what the rule WOULD have thrown away if it
/// had been — which is the number that decides whether wiring it is worth a
/// round. The keys are the lint's own verdicts and `clean`; no charter and no
/// title is ever returned.
Map<String, int> charterLintCounts(List<LintCandidate> storylines) {
  final counts = <String, int>{
    'clean': 0,
    'placeholder': 0,
    'person': 0,
    'category': 0,
  };
  for (final storyline in storylines) {
    final reason = charterLint(
          title: storyline.title,
          charter: storyline.charter,
          participants: storyline.participants,
        ) ??
        'clean';
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  return counts;
}

/// One report from the service's `clusterObserver` seam: a cluster the sweep
/// asked about, and the one word for what became of it.
///
/// [threads] are [threadKeyOf] keys, the cluster as the clustering formed it —
/// before the namer's outliers narrowed it and without the fragment siblings
/// that ride its members. The words are the seam's five: `formed`,
/// `incoherent`, `lint`, `thin`, `answered`.
typedef JudgedCluster = ({List<String> threads, String outcome});

/// The clusters behind [judged], one entry per distinct thread set.
///
/// The keep-all loop re-runs the sweep until a pass proposes nothing, so a
/// cluster the first pass tombstoned is rebuilt identically on the second and
/// reported again as `answered` — the same group, judged once and recognised
/// afterwards. Counting both would say the sweep formed twice as many clusters
/// as it did, so the reports are de-duplicated by their SORTED thread keys.
///
/// The first report of a set wins, with one exception: an `answered` yields to
/// the first report that says what the models actually decided, whichever pass
/// carried it. A set that was only ever `answered` stays `answered` — the
/// tombstone was written before this run and there is no verdict to recover.
/// Output is in first-seen order.
List<JudgedCluster> distinctClusters(Iterable<JudgedCluster> judged) {
  final order = <String>[];
  final bySet = <String, JudgedCluster>{};
  for (final cluster in judged) {
    // NUL, because no thread key can carry one: a plain separator would let
    // two different sets collide into one id.
    final id = (cluster.threads.toList()..sort()).join('\u0000');
    final held = bySet[id];
    if (held == null) {
      order.add(id);
      bySet[id] = cluster;
      continue;
    }
    if (held.outcome == 'answered' && cluster.outcome != 'answered') {
      bySet[id] = cluster;
    }
  }
  return [for (final id in order) bySet[id]!];
}

/// How pure a set of clusters was BEFORE the namer saw them.
///
/// The one number Phase 5 could not read: the store keeps no record of a
/// cluster the namer declined beyond its tombstone hash, so a namer that
/// refuses gold-pure groups and a clustering that builds mixed ones look
/// identical from the outside. Read per outcome, the two come apart — pure
/// declined clusters accuse the naming rule, mixed ones accuse the clustering.
class ClusterPurity {
  /// Clusters in this bucket, the ones with nothing to say about purity
  /// included.
  final int clusters;

  /// How many of them carry at least one gold slug, which is how many
  /// [mean] is over.
  final int withCarrier;

  /// The mean plurality share over [withCarrier] clusters. 0 when none carry a
  /// slug, which is a statement about the denominator and not about purity.
  final double mean;

  /// Clusters whose share is at least 0.7 — the "mostly one effort" line.
  final int pureAt70;

  /// Clusters whose members all carry the same slug.
  final int pureAt100;

  /// Each cluster's share in input order, null where no member carries a slug.
  /// [toJson] alone; no key and no slug rides it.
  final List<double?> shares;

  /// Each cluster's size in input order, counted as the sweep formed it.
  final List<int> sizes;

  const ClusterPurity({
    required this.clusters,
    required this.withCarrier,
    required this.mean,
    required this.pureAt70,
    required this.pureAt100,
    required this.shares,
    required this.sizes,
  });

  /// [purityOf] over every cluster, summarised.
  ///
  /// A cluster no member of which carries a gold slug counts in [clusters] and
  /// [sizes] and in nothing else: it is not a dirty cluster, it is one there is
  /// nothing to be pure about, and averaging a zero in would report the
  /// clustering as worse than it was.
  factory ClusterPurity.of(
    Iterable<JudgedCluster> clusters,
    Map<String, String> goldByThread,
  ) {
    final shares = <double?>[];
    final sizes = <int>[];
    for (final cluster in clusters) {
      shares.add(purityOf(cluster.threads, goldByThread));
      sizes.add(cluster.threads.length);
    }
    final carried = shares.whereType<double>().toList();
    return ClusterPurity(
      clusters: shares.length,
      withCarrier: carried.length,
      mean: carried.isEmpty
          ? 0
          : carried.fold(0.0, (sum, v) => sum + v) / carried.length,
      pureAt70: carried.where((share) => share >= 0.7).length,
      pureAt100: carried.where((share) => share >= 1.0).length,
      shares: shares,
      sizes: sizes,
    );
  }

  Map<String, Object?> toJson() => {
        'clusters': clusters,
        'with_carrier': withCarrier,
        'mean': mean,
        'pure_at_70': pureAt70,
        'pure_at_100': pureAt100,
        'shares': shares,
        'sizes': sizes,
      };

  /// Counts and ratios, for the printed table.
  String line() =>
      '$clusters ${clusters == 1 ? 'cluster' : 'clusters'}, '
      'mean ${pct(mean)} over $withCarrier, '
      '>=70% $pureAt70, 100% $pureAt100';
}

/// The outcome words present in [distinct], each with its clusters' purity.
///
/// In the seam's own order, absent words skipped, and with one derived bucket:
/// `declined` is every cluster the sweep judged and did not ship — the namer's
/// refusals, the lint's, and the groups the confirms thinned out — which is the
/// bucket `formed` is read against. It overlaps the three it unions, so
/// [SweepTally.clustersJudged] leaves it out.
Map<String, ClusterPurity> clusterPurityByOutcome(
  List<JudgedCluster> distinct,
  Map<String, String> goldByThread,
) {
  const order = ['formed', 'incoherent', 'lint', 'thin', 'answered'];
  const declinedWords = {'incoherent', 'lint', 'thin'};
  final byOutcome = <String, ClusterPurity>{};
  for (final outcome in order) {
    final bucket = [
      for (final cluster in distinct)
        if (cluster.outcome == outcome) cluster,
    ];
    if (bucket.isEmpty) continue;
    byOutcome[outcome] = ClusterPurity.of(bucket, goldByThread);
  }
  final declined = [
    for (final cluster in distinct)
      if (declinedWords.contains(cluster.outcome)) cluster,
  ];
  if (declined.isNotEmpty) {
    byOutcome['declined'] = ClusterPurity.of(declined, goldByThread);
  }
  return byOutcome;
}

/// Every pool pair's cosine, split by whether the two threads are the same
/// gold effort.
///
/// The separability read, and the ceiling on every threshold the clustering
/// could be given: a floor that keeps the in-effort pairs and drops the rest
/// exists only where [sameEffort] sits above [crossEffort]. If the three
/// populations lie on top of each other, no threshold separates them and the
/// vector is what has to change.
///
/// [withNone] is every pair at least one side of which gold files nowhere or
/// carries no slug at all. Kept apart from [crossEffort] because the two ask
/// different questions: two efforts that should not be joined, against a
/// thread that belongs to no effort in the first place.
({List<double> sameEffort, List<double> crossEffort, List<double> withNone})
    pairCosinesOf({
  required Map<String, List<double>> vectors,
  required Map<String, String> goldByThread,
}) {
  final sameEffort = <double>[];
  final crossEffort = <double>[];
  final withNone = <double>[];
  // Sorted, so the three populations do not depend on the order the caller
  // happened to build the map in.
  final keys = vectors.keys.toList()..sort();
  String? slugOf(String key) {
    final slug = goldByThread[key];
    if (slug == null || slug.isEmpty || slug == noneId) return null;
    return slug;
  }

  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      final value = cosine(vectors[keys[i]]!, vectors[keys[j]]!);
      final a = slugOf(keys[i]);
      final b = slugOf(keys[j]);
      if (a == null || b == null) {
        withNone.add(value);
      } else if (a == b) {
        sameEffort.add(value);
      } else {
        crossEffort.add(value);
      }
    }
  }
  return (
    sameEffort: sameEffort,
    crossEffort: crossEffort,
    withNone: withNone,
  );
}

/// The commonest English function words, dropped before two subjects are
/// compared.
///
/// Thirty of them, and the list is a CONST rather than a stemmer or a
/// frequency cut over the corpus: the whole point of the lexical lines is to
/// be a ruler the vector can be held against, and a ruler whose marks move
/// with the mailbox measures nothing. `re`, `fw` and `fwd` are in it as a belt
/// to `stripReFw`'s braces — a subject that carries one mid-line, which a
/// forwarded forward does, still loses it here.
const List<String> subjectStopwords = [
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'for', 'on', //
  'at', 'by', 'with', 'from', 'is', 'are', 'was', 'be', 'as', 're', //
  'fw', 'fwd', 'this', 'that', 'it', 'your', 'our', 'my', 'you', 'we', //
];

/// One subject as a bag of words: `Re: Budget review (Q3)` → `{budget,
/// review, q3}`.
///
/// Lower-cased, split on anything that is not a word character, one-character
/// tokens and [subjectStopwords] dropped. A set and not a list, because what
/// the overlap asks is which words two subjects have in common and not how
/// often either says one.
Set<String> subjectTokens(String? subject) {
  final stripped = stripReFw(subject).toLowerCase();
  return {
    for (final token in stripped.split(RegExp(r'[^a-z0-9]+')))
      if (token.length >= 2 && !subjectStopwords.contains(token)) token,
  };
}

/// The bins a subject overlap is read in — three edges, four buckets.
///
/// `0` is its own bucket rather than the bottom of a range, because two
/// subjects with NO word in common is the interesting case: it is the pool the
/// vector has to separate on meaning alone.
const List<String> overlapBinLabels = ['0', '0-0.25', '0.25-0.5', '>=0.5'];

/// [values] counted into [overlapBinLabels]' four buckets.
List<int> overlapBins(Iterable<double> values) {
  final bins = List<int>.filled(overlapBinLabels.length, 0);
  for (final value in values) {
    if (value <= 0) {
      bins[0]++;
    } else if (value < 0.25) {
      bins[1]++;
    } else if (value < 0.5) {
      bins[2]++;
    } else {
      bins[3]++;
    }
  }
  return bins;
}

/// Every pool pair's subject overlap, split the way [pairCosinesOf] splits the
/// cosines.
///
/// Jaccard over [subjectTokens]: the shared words over the words either
/// subject uses. The question it answers is how much of what the vector does
/// a `LIKE` over the subject line would have done — a cheap rule that
/// separated the efforts as well as the embedding would make the embedding the
/// wrong thing to spend a round on.
///
/// Two empty subjects score 0 rather than 1. An empty union is not agreement.
({List<double> sameEffort, List<double> crossEffort, List<double> withNone})
    pairSubjectOverlapOf({
  required Map<String, String> subjectByThread,
  required Map<String, String> goldByThread,
}) {
  final keys = subjectByThread.keys.toList()..sort();
  final tokens = {
    for (final key in keys) key: subjectTokens(subjectByThread[key]),
  };
  return _pairsBy(
    keys: keys,
    goldByThread: goldByThread,
    value: (a, b) {
      final left = tokens[a]!;
      final right = tokens[b]!;
      if (left.isEmpty && right.isEmpty) return 0;
      final shared = left.intersection(right).length;
      final union = left.union(right).length;
      return union == 0 ? 0 : shared / union;
    },
  );
}

/// The bins a shared-people count is read in.
const List<String> sharedPeopleBinLabels = ['0', '1', '2+'];

/// [counts] counted into [sharedPeopleBinLabels]' three buckets.
List<int> sharedPeopleBins(Iterable<double> counts) {
  final bins = List<int>.filled(sharedPeopleBinLabels.length, 0);
  for (final count in counts) {
    bins[count <= 0 ? 0 : (count < 2 ? 1 : 2)]++;
  }
  return bins;
}

/// How many non-owner people every pool pair shares, split the way
/// [pairCosinesOf] splits the cosines.
///
/// Displays, lower-cased, the owner's own removed — the owner is on every
/// thread in their own mailbox, so counting them would put every pair in the
/// same bucket and say nothing. The same "two shared people" the assign
/// shortlist's overlap rule counts, read over the whole pool.
({List<double> sameEffort, List<double> crossEffort, List<double> withNone})
    pairSharedPeopleOf({
  required Map<String, List<String>> participantsByThread,
  required Map<String, String> goldByThread,
  required Set<String> ownerDisplays,
}) {
  final keys = participantsByThread.keys.toList()..sort();
  final owner = {
    for (final display in ownerDisplays)
      if (display.trim().isNotEmpty) display.trim().toLowerCase(),
  };
  final people = {
    for (final key in keys)
      key: {
        for (final display in participantsByThread[key] ?? const <String>[])
          if (display.trim().isNotEmpty &&
              !owner.contains(display.trim().toLowerCase()))
            display.trim().toLowerCase(),
      },
  };
  return _pairsBy(
    keys: keys,
    goldByThread: goldByThread,
    value: (a, b) => people[a]!.intersection(people[b]!).length.toDouble(),
  );
}

/// The three populations [pairCosinesOf] splits into, over any per-pair
/// number. One walk, one rule for what `none` means, so the three lexical and
/// geometric lines can never disagree about which pairs they counted.
({List<double> sameEffort, List<double> crossEffort, List<double> withNone})
    _pairsBy({
  required List<String> keys,
  required Map<String, String> goldByThread,
  required double Function(String a, String b) value,
}) {
  final sameEffort = <double>[];
  final crossEffort = <double>[];
  final withNone = <double>[];
  String? slugOf(String key) {
    final slug = goldByThread[key];
    if (slug == null || slug.isEmpty || slug == noneId) return null;
    return slug;
  }

  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      final measured = value(keys[i], keys[j]);
      final a = slugOf(keys[i]);
      final b = slugOf(keys[j]);
      if (a == null || b == null) {
        withNone.add(measured);
      } else if (a == b) {
        sameEffort.add(measured);
      } else {
        crossEffort.add(measured);
      }
    }
  }
  return (
    sameEffort: sameEffort,
    crossEffort: crossEffort,
    withNone: withNone,
  );
}

/// How far apart the two populations lie — the one number a candidate vector
/// is chosen on.
///
/// [points] is the same-effort share at or above [at] minus the cross-effort
/// share, in whole percentage points. Round D's shipped vector scores 25 (74
/// against 49), which is why a link at the shipped threshold is a same-effort
/// pair about five percent of the time.
///
/// [recall70Cosine] is the highest cosine a threshold could be set at while
/// still linking at least 70% of the same-effort pairs, and
/// [recall70CrossPct] is the share of CROSS-effort pairs that clears the same
/// bar. Highest and not lowest: every cosine below it links seven in ten too,
/// so the lowest would always be the smallest number in the list and the cross
/// share beside it would always read 100%. What a reader wants is how high the
/// bar can go before recall breaks.
///
/// [cross5Cosine] is the mirror, and the PRECISION number: the lowest cosine
/// at which no more than one cross-effort pair in twenty still links.
/// [cross5SameRecallPct] is the share of same-effort pairs that survives it
/// and [cross5CrossPct] the share of cross-effort pairs that does. Lowest
/// here, for the same reason recall's is highest: every cosine above it admits
/// fewer cross pairs, so the interesting one is the loosest bar that still
/// holds the line.
///
/// [cross5CrossPct] is on the record rather than assumed to be 5, because it
/// is not always 5: a cross list too short or too flat for any of its values
/// to carry one pair in twenty has no such cosine, the top of the list is
/// returned instead, and this share above 5% is the only thing that says the
/// rung is a fallback rather than the precision point.
///
/// Both exist because the cosine SCALE moves with the model and the prefix —
/// measured 2026-09-19, recall-70 ran from 0.31 to 0.72 across the candidates
/// — so [points], which is read at a fixed 0.65, compares two configurations
/// of ONE model and nothing else. The two cosines and the two shares beside
/// them are scale-free, and they are what a candidate is chosen on.
///
/// An empty same-effort list yields zeros rather than a ratio over nothing:
/// there is no recall to report when nothing could be recalled. An empty cross
/// list means nothing has to be kept out, so [cross5Cosine] is the highest
/// same-effort value, which links one pair.
({
  int points,
  double recall70Cosine,
  int recall70CrossPct,
  double cross5Cosine,
  int cross5SameRecallPct,
  int cross5CrossPct,
}) separationOf({
  required List<double> sameEffort,
  required List<double> crossEffort,
  double at = 0.65,
}) {
  int sharePct(List<double> values, double bar) => values.isEmpty
      ? 0
      : (values.where((v) => v >= bar).length * 100 / values.length).round();

  final points = sharePct(sameEffort, at) - sharePct(crossEffort, at);
  if (sameEffort.isEmpty) {
    return (
      points: points,
      recall70Cosine: 0,
      recall70CrossPct: 0,
      cross5Cosine: 0,
      cross5SameRecallPct: 0,
      cross5CrossPct: 0,
    );
  }

  // Ascending, then the LAST value whose "at or above me" share still clears
  // seven in ten. Walking the values rather than interpolating a percentile
  // keeps the answer a cosine the data actually contains, which is what makes
  // the share beside it a real count rather than an estimate.
  final sortedSame = [...sameEffort]..sort();
  var recall70 = sortedSame.first;
  var firstOfValue = 0;
  for (var i = 0; i < sortedSame.length; i++) {
    if (i > 0 && sortedSame[i] != sortedSame[i - 1]) firstOfValue = i;
    final atOrAbove = sortedSame.length - firstOfValue;
    if (atOrAbove * 100 >= sortedSame.length * 70) recall70 = sortedSame[i];
  }

  // The same walk over the cross list, taking the FIRST value whose share has
  // fallen to one in twenty. A list where even the largest value is held by
  // more than 5% of the pairs has no such cosine — it takes fewer than twenty
  // distinct values to manage that — and the largest is returned, with the
  // share beside it saying so.
  final sortedCross = [...crossEffort]..sort();
  var cross5 = sortedSame.last;
  if (sortedCross.isNotEmpty) {
    cross5 = sortedCross.last;
    firstOfValue = 0;
    for (var i = 0; i < sortedCross.length; i++) {
      if (i > 0 && sortedCross[i] != sortedCross[i - 1]) firstOfValue = i;
      final atOrAbove = sortedCross.length - firstOfValue;
      if (atOrAbove * 100 <= sortedCross.length * 5) {
        cross5 = sortedCross[i];
        break;
      }
    }
  }

  return (
    points: points,
    recall70Cosine: recall70,
    recall70CrossPct: sharePct(crossEffort, recall70),
    cross5Cosine: cross5,
    cross5SameRecallPct: sharePct(sameEffort, cross5),
    cross5CrossPct: sharePct(crossEffort, cross5),
  );
}

/// How many pool pairs sit INSIDE one would-form cluster, split by whether the
/// two threads share a gold effort.
///
/// The precision-and-recall reading of a whole ladder rung in three numbers:
/// [same] is what the rung gathered, [cross] is what it mixed in, and [none]
/// is what it swept up that gold files nowhere. Read against the pool's own
/// totals, which is what makes a rung on one model comparable to a rung on
/// another however differently their cosines are scaled.
///
/// The clusters a rung produces are disjoint, so no pair is counted twice.
({int same, int cross, int none}) pairsInsideClusters(
  Iterable<JudgedCluster> clusters,
  Map<String, String> goldByThread,
) {
  var same = 0;
  var cross = 0;
  var none = 0;
  String? slugOf(String key) {
    final slug = goldByThread[key];
    if (slug == null || slug.isEmpty || slug == noneId) return null;
    return slug;
  }

  for (final cluster in clusters) {
    final threads = cluster.threads;
    for (var i = 0; i < threads.length; i++) {
      for (var j = i + 1; j < threads.length; j++) {
        final a = slugOf(threads[i]);
        final b = slugOf(threads[j]);
        if (a == null || b == null) {
          none++;
        } else if (a == b) {
          same++;
        } else {
          cross++;
        }
      }
    }
  }
  return (same: same, cross: cross, none: none);
}

/// One rung of the would-form ladder, printed. Counts and a cosine, nothing
/// else: [ClusterPurity.line] carries no key and no slug.
String wouldFormLine({
  required String label,
  required double threshold,
  required ClusterPurity purity,
  required ({int same, int cross, int none}) inside,
  required int sameTotal,
}) =>
    '  would-form at $label ${threshold.toStringAsFixed(2)}: ${purity.line()}'
    ' · same-effort pairs inside ${inside.same} of $sameTotal'
    ' · cross-effort pairs inside ${inside.cross}';

/// One rung, for a result file.
Map<String, Object?> wouldFormJson({
  required double threshold,
  required ClusterPurity purity,
  required ({int same, int cross, int none}) inside,
}) =>
    {
      'threshold': threshold,
      'purity': purity.toJson(),
      'inside_same': inside.same,
      'inside_cross': inside.cross,
      'inside_none': inside.none,
    };

/// The clusters a sweep WOULD form over a pool, without asking a model
/// anything.
///
/// `make golden-vector`'s first line, and the one piece of that stage with a
/// decision in it, so it lives here where `golden_sweep_test.dart` can pin it
/// offline rather than inside a bench nothing runs on the gate.
///
/// The fidelity rule: `sweep()` folds the FRAGMENTS first and clusters the
/// representatives, never the siblings, because a sibling is not a candidate
/// in its own right — it rides its representative's verdict. Round D found the
/// one or two folded rows on the golden pool changing the sweep's whole
/// outcome, so a reading that clustered them would be a reading of a pool the
/// app never clusters. [folded] is how many rows the fold took out, which is
/// how a run says whether the rule bit at all.
///
/// The SERIES pre-pass is not applied. It is private to the service and is
/// deliberately not widened for a bench; on the golden pool it has never
/// seeded or excluded anything, and [folded] beside the cluster line is what
/// makes a pool where that stopped being true visible.
///
/// [threshold] is the link cosine this rung asks about. The coherence floor
/// and the split ceiling move with it, one step under and four steps over, so
/// the ladder asks one question of every candidate rather than asking a
/// model whose cosines sit low whether it clears a bar set for another model.
///
/// [rows], [vectors] and [keys] are one pool in one order, index for index.
({List<JudgedCluster> clusters, int representatives, int folded})
    wouldFormClustersOf({
  required List<Map<String, Object?>> rows,
  required List<List<double>> vectors,
  required List<String> keys,
  required double threshold,
}) {
  final fragments = StorylineService.fragmentsOf(rows);
  final folded = fragments.siblings.values
      .fold<int>(0, (sum, group) => sum + group.length);
  // The indexes `clusterBySimilarity` returns are into THIS list, so they are
  // mapped back through it before anything reads a thread key — the same hop
  // `sweep()` makes through its own `poolIndexes`.
  final poolIndexes = fragments.representatives;

  final table = PairSimilarities(poolIndexes.length);
  for (var i = 0; i < poolIndexes.length; i++) {
    for (var j = i + 1; j < poolIndexes.length; j++) {
      table.set(
        i,
        j,
        cosine(vectors[poolIndexes[i]], vectors[poolIndexes[j]]),
      );
    }
  }
  final clusters = clusterBySimilarity(
    poolIndexes.length,
    table.get,
    threshold: threshold,
    minSize: StorylineTuning.proposeMinClusterSize,
    maxSize: StorylineTuning.maxClusterSize,
    // The coherence floor and the split ceiling ride WITH the threshold rather
    // than staying at the app's numbers, because the whole point of a rung
    // other than the shipped one is that the candidate model's cosines do not
    // live where the shipped one's do. The gaps are the app's: the floor sits
    // one step under the link and the ceiling four steps over it.
    floor: threshold - StorylineTuning.clusterSplitStep,
    step: StorylineTuning.clusterSplitStep,
    ceiling: threshold + 4 * StorylineTuning.clusterSplitStep,
  );

  return (
    clusters: [
      for (final cluster in clusters)
        (
          threads: [for (final index in cluster) keys[poolIndexes[index]]],
          outcome: 'would_form',
        ),
    ],
    representatives: poolIndexes.length,
    folded: folded,
  );
}

/// `<label> <count>` for every bucket, double-spaced. Top-level because both
/// stages of the sweep print the same rows and a second copy of the formatting
/// is a second thing to drift.
String binsLine(List<String> labels, List<int> counts) => [
      for (var i = 0; i < labels.length; i++) '${labels[i]} ${counts[i]}',
    ].join('  ');

/// The same counts keyed by their bucket's name, for a result file.
Map<String, int> labelledBins(List<String> labels, List<int> counts) => {
      for (var i = 0; i < labels.length; i++) labels[i]: counts[i],
    };

/// The subject-overlap row, the three populations side by side.
String subjectOverlapLine({
  required List<int> sameEffort,
  required List<int> crossEffort,
  required List<int> withNone,
}) =>
    '  pool pairs by subject overlap  same  '
    '${binsLine(overlapBinLabels, sameEffort)}'
    '   cross  ${binsLine(overlapBinLabels, crossEffort)}'
    '   none  ${binsLine(overlapBinLabels, withNone)}';

/// The shared-people row, the three populations side by side.
String sharedPeopleLine({
  required List<int> sameEffort,
  required List<int> crossEffort,
  required List<int> withNone,
}) =>
    '  pool pairs by shared people  same  '
    '${binsLine(sharedPeopleBinLabels, sameEffort)}'
    '   cross  ${binsLine(sharedPeopleBinLabels, crossEffort)}'
    '   none  ${binsLine(sharedPeopleBinLabels, withNone)}';

/// What [separationOf] returns, named once so the printers and the callers
/// cannot drift over a field.
typedef Separation = ({
  int points,
  double recall70Cosine,
  int recall70CrossPct,
  double cross5Cosine,
  int cross5SameRecallPct,
  int cross5CrossPct,
});

/// The separation row. Two decimals on the cosines, whole percents elsewhere.
String separationLine(Separation separation) =>
    'separation: ${separation.points} points at 0.65 · '
    'recall-70 cosine ${separation.recall70Cosine.toStringAsFixed(2)} · '
    'cross ${separation.recall70CrossPct}% · '
    'cross-5 cosine ${separation.cross5Cosine.toStringAsFixed(2)} · '
    'cross ${separation.cross5CrossPct}% · '
    'same ${separation.cross5SameRecallPct}%';

/// [separationLine]'s numbers, for a result file.
Map<String, Object?> separationJson(Separation separation) => {
      'points': separation.points,
      'recall_70_cosine': separation.recall70Cosine,
      'recall_70_cross_pct': separation.recall70CrossPct,
      'cross_5_cosine': separation.cross5Cosine,
      'cross_5_cross_pct': separation.cross5CrossPct,
      'cross_5_same_recall_pct': separation.cross5SameRecallPct,
    };

/// A share as a whole percent. Top-level because the cluster purity lines and
/// the tally's own both print one.
String pct(double share) => '${(share * 100).round()}%';

/// What one sweep replay did, counted.
///
/// Built once at the end of the run rather than accumulated, because every
/// number here is a fact about the FINAL state of the store plus the counters
/// the loop kept. Its [table] is what the run prints and its [toJson] is what
/// lands in the result file's `extra.sweep`.
class SweepTally {
  /// Live storylines at the end of the run.
  final int formed;

  /// Clusters the model or the tombstone check threw out — `dismissed` rows
  /// with `created_by = 'auto'`.
  final int tombstoned;

  /// Clusters the charter lint tombstoned, summed off the sweep's own
  /// activity rows.
  final int lintRejected;

  /// Clusters the namer refused, summed the same way: a `coherent: false` that
  /// named no outliers, or an outlier list that left fewer than two threads.
  /// Both are the model naming no group to keep, so neither contributes to
  /// [outliersDropped].
  final int incoherent;

  /// Series the pre-pass seeded as clusters of their own.
  final int seriesSeeded;

  /// Threads the pre-pass took out of the pool as notification-shaped.
  final int seriesExcluded;

  /// Threads the namer named as not belonging, dropped before the confirms.
  final int outliersDropped;

  /// Pool rows that were fragments of a member's own thread and joined on its
  /// verdict, never clustered, named or confirmed in their own right.
  final int fragmentsJoined;

  /// Pool rows folded onto a representative by the fragment rule, whether or
  /// not that representative shipped. [fragmentsJoined] is the subset that
  /// became members; this is how much the fold changed the pool.
  final int fragmentsFolded;

  /// Storyline id → the share of its gold-carrying members that agree, or
  /// null for a storyline no member of which carries a gold slug. Every live
  /// storyline is listed either way: a reader counting groups must see them
  /// all, and the null is the difference between a dirty group and one there
  /// is nothing to say about.
  final Map<String, double?> purityByStoryline;

  /// Gold slug → the share of its golden threads that reached the storyline
  /// mapped to it. Only slugs with at least two golden threads: one thread is
  /// not an effort a sweep could have gathered.
  final Map<String, double> coverageBySlug;

  /// The largest storyline's share of every filed thread.
  final double largestShare;

  /// Items whose derived id equals a non-`none` gold id — the number the app
  /// has never once produced.
  final int correctPositives;

  /// Forbidden slug → how many items were filed under it. The buckets are
  /// registry slugs, which is all a derived id can ever be: an `ANTI-*` slug
  /// names a MISTAKE and has no membership to be filed into, so it is reached
  /// through these lists rather than directly.
  final Map<String, int> forbiddenByAnti;

  /// Items filed into a storyline that maps nowhere.
  final int unmapped;

  /// Items in no storyline at all.
  final int filedNowhere;

  /// Model calls per task label — `storyline_name`, `storyline_membership`.
  final Map<String, int> callsByKind;

  /// Grouping calls the sweep made, summed off its own activity rows.
  ///
  /// Zero on a tree running `GroupingMode.cosine`, which is what ships: the
  /// sweep writes all four of these keys in either mode so that a row from
  /// the two trees is the same row with different numbers in it. The four
  /// default to 0 here for the same reason a missing key reads 0 — a ledger
  /// row taken before these existed is a cosine row, and that is what a
  /// cosine row says.
  final int groupingCalls;

  /// Threads a grouping call placed in a group big enough to propose.
  final int grouped;

  /// Grouping calls that left their piece ungrouped: the call threw, or it
  /// named no group at all.
  final int groupingFailed;

  /// Pieces dropped before any call — too few threads after a split, or still
  /// too wide to show in one call at the top of the ladder.
  final int groupingUnfit;

  /// Model calls made in each sweep pass, in pass order.
  final List<int> callsPerPass;

  /// Wall per sweep pass, in pass order.
  final List<int> wallPerPassMs;

  /// Pairs inside the clusters the sweep formed, by cosine bin.
  final List<int> cosineBins;

  /// What the lint would still refuse among the LIVE storylines, by verdict.
  ///
  /// Before Phase 3 this was the lint's whole reading, counted and not
  /// applied. Now the lint tombstones a cluster before its confirms, so what
  /// is left here is what SURVIVED that a lint pass would still refuse — and
  /// that should read zero. A non-zero entry is a bug report, not a
  /// measurement: either a charter reached a storyline by a path that does not
  /// lint, or the two readings disagree.
  final Map<String, int> lintCounts;

  /// Outcome word to the purity of the clusters the sweep judged under it,
  /// read BEFORE the namer narrowed or refused any of them. Carries the
  /// derived `declined` bucket as well as the seam's five words; see
  /// [clusterPurityByOutcome].
  final Map<String, ClusterPurity> clusterPurity;

  /// Pool pairs whose two threads are the same gold effort, by cosine bin.
  final List<int> sameEffortBins;

  /// Pool pairs whose two threads are two different gold efforts, by bin.
  final List<int> crossEffortBins;

  /// Pool pairs at least one side of which gold files nowhere, by bin.
  final List<int> withNoneBins;

  /// The same three populations by SUBJECT overlap, in [overlapBinLabels]'
  /// four buckets. The lexical ruler the cosine line is read against: a pool
  /// whose same-effort pairs already share subject words is one a much cheaper
  /// rule could have grouped.
  final List<int> sameSubjectBins;
  final List<int> crossSubjectBins;
  final List<int> withNoneSubjectBins;

  /// The same three populations by shared non-owner people, in
  /// [sharedPeopleBinLabels]' three buckets.
  final List<int> samePeopleBins;
  final List<int> crossPeopleBins;
  final List<int> withNonePeopleBins;

  /// What [separationOf] read off the cosine lists: the points between the two
  /// populations at the shipped threshold, what a 70%-recall threshold would
  /// cost in cross-effort pairs, and what a 5%-cross threshold would cost in
  /// same-effort ones.
  final Separation separation;

  const SweepTally({
    required this.formed,
    required this.tombstoned,
    required this.lintRejected,
    required this.incoherent,
    required this.seriesSeeded,
    required this.seriesExcluded,
    required this.outliersDropped,
    required this.fragmentsJoined,
    required this.fragmentsFolded,
    required this.purityByStoryline,
    required this.coverageBySlug,
    required this.largestShare,
    required this.correctPositives,
    required this.forbiddenByAnti,
    required this.unmapped,
    required this.filedNowhere,
    required this.callsByKind,
    this.groupingCalls = 0,
    this.grouped = 0,
    this.groupingFailed = 0,
    this.groupingUnfit = 0,
    required this.callsPerPass,
    required this.wallPerPassMs,
    required this.cosineBins,
    required this.lintCounts,
    required this.clusterPurity,
    required this.sameEffortBins,
    required this.crossEffortBins,
    required this.withNoneBins,
    required this.sameSubjectBins,
    required this.crossSubjectBins,
    required this.withNoneSubjectBins,
    required this.samePeopleBins,
    required this.crossPeopleBins,
    required this.withNonePeopleBins,
    required this.separation,
  });

  /// The mean of [purityByStoryline] over the storylines that HAVE one.
  ///
  /// A storyline whose members carry no gold slug is left out of both halves
  /// of the average rather than counted as zero, and [purityWithCarrier] says
  /// how many were averaged so the number cannot be read as covering more
  /// groups than it does.
  double get purityMean => _mean(purityByStoryline.values.whereType<double>());

  /// How many storylines the purity mean is over.
  int get purityWithCarrier =>
      purityByStoryline.values.whereType<double>().length;

  /// The mean of [coverageBySlug] over the slugs that have a denominator.
  double get coverageMean => _mean(coverageBySlug.values);

  int get forbiddenHits =>
      forbiddenByAnti.values.fold(0, (sum, count) => sum + count);

  /// How many distinct clusters the sweep asked a verdict about.
  ///
  /// `declined` is skipped: it is a union of three buckets that are already
  /// counted, so summing every entry would count each refused cluster twice.
  int get clustersJudged => clusterPurity.entries
      .where((entry) => entry.key != 'declined')
      .fold(0, (sum, entry) => sum + entry.value.clusters);

  static double _mean(Iterable<double> values) {
    if (values.isEmpty) return 0;
    return values.fold(0.0, (sum, v) => sum + v) / values.length;
  }

  Map<String, Object?> toJson() => {
        'formed': formed,
        'tombstoned': tombstoned,
        'lint_rejected': lintRejected,
        'incoherent': incoherent,
        'series': seriesSeeded,
        'series_excluded': seriesExcluded,
        'outliers': outliersDropped,
        'fragments': fragmentsJoined,
        'folded': fragmentsFolded,
        'purity': {
          'mean': purityMean,
          'with_carrier': purityWithCarrier,
          'by_storyline': purityByStoryline,
        },
        'coverage': {
          'mean': coverageMean,
          'by_slug': coverageBySlug,
        },
        'largest_share': largestShare,
        'correct_positives': correctPositives,
        'forbidden': {
          'hits': forbiddenHits,
          'by_slug': forbiddenByAnti,
        },
        'unmapped': unmapped,
        'filed_nowhere': filedNowhere,
        'calls_by_kind': callsByKind,
        'grouping_calls': groupingCalls,
        'grouped': grouped,
        'grouping_failed': groupingFailed,
        'grouping_unfit': groupingUnfit,
        'calls_per_pass': callsPerPass,
        'wall_per_pass_ms': wallPerPassMs,
        'cosine_bins': {
          for (var i = 0; i < cosineBinLabels.length; i++)
            cosineBinLabels[i]: cosineBins[i],
        },
        'lint': lintCounts,
        'clusters': {
          for (final entry in clusterPurity.entries)
            entry.key: entry.value.toJson(),
        },
        'pair_bins': {
          'same_effort': _binsJson(sameEffortBins),
          'cross_effort': _binsJson(crossEffortBins),
          'with_none': _binsJson(withNoneBins),
        },
        'subject_overlap_bins': {
          'same_effort': labelledBins(overlapBinLabels, sameSubjectBins),
          'cross_effort': labelledBins(overlapBinLabels, crossSubjectBins),
          'with_none': labelledBins(overlapBinLabels, withNoneSubjectBins),
        },
        'shared_people_bins': {
          'same_effort': labelledBins(sharedPeopleBinLabels, samePeopleBins),
          'cross_effort': labelledBins(sharedPeopleBinLabels, crossPeopleBins),
          'with_none': labelledBins(sharedPeopleBinLabels, withNonePeopleBins),
        },
        'separation': separationJson(separation),
      };

  static Map<String, int> _binsJson(List<int> bins) =>
      labelledBins(cosineBinLabels, bins);

  /// Counts, ratios and enums. No slug and no storyline title: the per-slug
  /// maps above stay in [toJson], which lands in the git-ignored result file.
  String table() {
    final calls = [
      for (final entry in callsByKind.entries) '${entry.key} ${entry.value}',
    ].join('  ');
    final bins = [
      for (var i = 0; i < cosineBinLabels.length; i++)
        '${cosineBinLabels[i]} ${cosineBins[i]}',
    ].join('  ');
    final lint = [
      for (final entry in lintCounts.entries) '${entry.key} ${entry.value}',
    ].join('  ');
    String binsOf(List<int> counts) => binsLine(cosineBinLabels, counts);
    // A word the run never saw prints a zero rather than vanishing: a reader
    // comparing two ledger rows has to see the same five columns on both.
    int clustersAt(String outcome) => clusterPurity[outcome]?.clusters ?? 0;
    String purityAt(String outcome) =>
        clusterPurity[outcome]?.line() ?? 'none';
    return 'sweep:\n'
        '  storylines  formed $formed  tombstoned $tombstoned'
        '  lint-rejected $lintRejected  incoherent $incoherent\n'
        '  series  seeded $seriesSeeded  excluded $seriesExcluded'
        '  outliers dropped $outliersDropped  fragments $fragmentsJoined'
        '  folded $fragmentsFolded\n'
        '  purity mean ${pct(purityMean)} over $purityWithCarrier of '
        '${purityByStoryline.length} storylines   '
        'coverage mean ${pct(coverageMean)} over '
        '${coverageBySlug.length} gold efforts\n'
        '  largest storyline ${pct(largestShare)} of all filed threads\n'
        '  items  correct positives $correctPositives  unmapped $unmapped'
        '  filed nowhere $filedNowhere  forbidden hits $forbiddenHits '
        'over ${forbiddenByAnti.length} buckets\n'
        '  calls  $calls   per pass ${callsPerPass.join(', ')}'
        '   grouping calls $groupingCalls  grouped $grouped'
        '  failed $groupingFailed  unfit $groupingUnfit\n'
        '  wall per pass ms ${wallPerPassMs.join(', ')}\n'
        '  in-cluster cosines  $bins\n'
        '  clusters judged $clustersJudged'
        '  formed ${clustersAt('formed')}'
        '  incoherent ${clustersAt('incoherent')}'
        '  lint ${clustersAt('lint')}'
        '  thin ${clustersAt('thin')}'
        '  answered ${clustersAt('answered')}\n'
        '  purity before naming  formed: ${purityAt('formed')}\n'
        '                        declined: ${purityAt('declined')}\n'
        '  pool pairs by cosine  same effort  ${binsOf(sameEffortBins)}'
        '   cross effort  ${binsOf(crossEffortBins)}'
        '   with none  ${binsOf(withNoneBins)}\n'
        '${subjectOverlapLine(
          sameEffort: sameSubjectBins,
          crossEffort: crossSubjectBins,
          withNone: withNoneSubjectBins,
        )}\n'
        '${sharedPeopleLine(
          sameEffort: samePeopleBins,
          crossEffort: crossPeopleBins,
          withNone: withNonePeopleBins,
        )}\n'
        '  ${separationLine(separation)}\n'
        '  charter lint over live storylines (should be 0)  $lint';
  }

}

/// The coverage map: for every gold effort with at least two golden threads,
/// the share of them that reached the storyline mapped to it.
///
/// When two app storylines both map to one slug — a sweep that split an effort
/// in half — the bigger of them is the one measured, because coverage asks
/// "how much of this effort did the app gather in one place". The split itself
/// shows up as two storylines of low coverage rather than one of full.
Map<String, double> coverageBySlugOf({
  required GoldenSet set,
  required SweepMembership membership,
  required Map<String, String> slugByStoryline,
  required Map<String, String> goldByThread,
}) {
  final denominators = goldThreadsBySlug(set);
  final coverage = <String, double>{};
  for (final entry in denominators.entries) {
    final slug = entry.key;
    final total = entry.value;
    if (total < 2) continue;
    var best = 0;
    for (final storyline in membership.threadsByStoryline.entries) {
      if (slugByStoryline[storyline.key] != slug) continue;
      final held = storyline.value
          .where((thread) => goldByThread[thread] == slug)
          .length;
      if (held > best) best = held;
    }
    coverage[slug] = best / total;
  }
  return coverage;
}
