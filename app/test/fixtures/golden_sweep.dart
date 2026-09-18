import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/storyline_lint.dart';

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

  const SweepTally({
    required this.formed,
    required this.tombstoned,
    required this.lintRejected,
    required this.incoherent,
    required this.seriesSeeded,
    required this.seriesExcluded,
    required this.outliersDropped,
    required this.purityByStoryline,
    required this.coverageBySlug,
    required this.largestShare,
    required this.correctPositives,
    required this.forbiddenByAnti,
    required this.unmapped,
    required this.filedNowhere,
    required this.callsByKind,
    required this.callsPerPass,
    required this.wallPerPassMs,
    required this.cosineBins,
    required this.lintCounts,
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
        'calls_per_pass': callsPerPass,
        'wall_per_pass_ms': wallPerPassMs,
        'cosine_bins': {
          for (var i = 0; i < cosineBinLabels.length; i++)
            cosineBinLabels[i]: cosineBins[i],
        },
        'lint': lintCounts,
      };

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
    return 'sweep:\n'
        '  storylines  formed $formed  tombstoned $tombstoned'
        '  lint-rejected $lintRejected  incoherent $incoherent\n'
        '  series  seeded $seriesSeeded  excluded $seriesExcluded'
        '  outliers dropped $outliersDropped\n'
        '  purity mean ${_pct(purityMean)} over $purityWithCarrier of '
        '${purityByStoryline.length} storylines   '
        'coverage mean ${_pct(coverageMean)} over '
        '${coverageBySlug.length} gold efforts\n'
        '  largest storyline ${_pct(largestShare)} of all filed threads\n'
        '  items  correct positives $correctPositives  unmapped $unmapped'
        '  filed nowhere $filedNowhere  forbidden hits $forbiddenHits '
        'over ${forbiddenByAnti.length} buckets\n'
        '  calls  $calls   per pass ${callsPerPass.join(', ')}\n'
        '  wall per pass ms ${wallPerPassMs.join(', ')}\n'
        '  in-cluster cosines  $bins\n'
        '  charter lint over live storylines (should be 0)  $lint';
  }

  static String _pct(double share) => '${(share * 100).round()}%';
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
