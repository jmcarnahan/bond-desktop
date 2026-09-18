import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bond_inbox/models/storyline_models.dart';

import 'golden_json.dart';
import 'golden_set.dart';

/// The gold storyline registry, read back into the shapes the confirm task
/// takes.
///
/// The registry is the hand-written answer to "what efforts does this mailbox
/// actually have": thirty storylines with a charter apiece, plus the
/// anti-storylines that name the wrong groupings a model keeps reaching for.
/// Like the set itself it is real correspondence and lives OUTSIDE version
/// control, so nothing here knows a path — callers pass one (`GOLDEN_REGISTRY`,
/// which the Makefile fills) and the committed tests read the small fictional
/// fixture beside this file instead.
///
/// The job here is the same narrow one `golden_set.dart` has: rebuild what the
/// app would have handed `ConfirmMembershipTask`, so a replay puts the SAME
/// prompt in front of a model that the pipeline puts there. Nothing here scores
/// anything — `golden/tools/score_run.py` is the scorer of record.

/// One registry storyline, as the registry writes it.
class RegistryStoryline {
  final String slug;
  final String title;

  /// What belongs to this effort, in the registry author's words. This is what
  /// membership is judged against — the app's own `storylines.charter` column
  /// holds the same kind of sentence, drafted by the naming pass.
  final String charter;

  final List<String> includes;
  final List<String> excludes;

  /// `conversation_key` of every member, as the registry writes it. Carried
  /// for a reader of the file rather than for the replay: the replay's
  /// population is the golden set, and a member with no golden item is a
  /// thread nothing in this round asks about.
  final List<String> memberKeys;

  final List<String> forbiddenNeighbors;

  const RegistryStoryline({
    required this.slug,
    required this.title,
    required this.charter,
    required this.includes,
    required this.excludes,
    required this.memberKeys,
    required this.forbiddenNeighbors,
  });

  /// The registry storyline as the confirm task sees one.
  ///
  /// The slug IS the id: the run file records the id this replay filed an item
  /// under, and the scorer's gold ids are slugs. `status: 'active'` and
  /// `createdBy: 'gold'` say what this row is — a group that exists, put there
  /// by a hand rather than by the sweep — and nothing in the prompt reads
  /// either.
  ///
  /// The summary stays NULL on purpose. `ConfirmMembershipTask.buildUserMessage`
  /// renders the charter when there is one and the summary when there is not,
  /// never both, so a summary here could only be dead weight — or, worse, the
  /// line a charterless storyline would have been judged on.
  Storyline toAppStoryline() => Storyline(
        id: slug,
        title: title,
        charter: charter,
        status: 'active',
        createdBy: 'gold',
      );

  static RegistryStoryline fromJson(Map<String, dynamic> json) =>
      RegistryStoryline(
        slug: asString(json['slug']),
        title: asString(json['title']),
        charter: asString(json['charter']),
        includes: asStrings(json['includes']),
        excludes: asStrings(json['excludes']),
        memberKeys: [
          for (final member in asList(json['members']))
            asString(asMap(member)['conversation_key']),
        ],
        forbiddenNeighbors: asStrings(json['forbidden_neighbors']),
      );
}

/// The whole registry: the storylines a candidate can be filed into, and the
/// anti-storylines it must not be.
class GoldenRegistry {
  /// In FILE order, which is the order the registry author wrote them in and
  /// the order the candidate extras are drawn from. Deterministic and
  /// arbitrary, which is exactly what a false-positive probe wants.
  final List<RegistryStoryline> storylines;

  /// `ANTI-*` slugs. Never instantiated as a [Storyline]: an anti-storyline
  /// has no charter to judge against and no membership to offer — it is a
  /// named MISTAKE, and it is scored only through the `forbidden` lists of the
  /// real storylines.
  final List<String> antiSlugs;

  GoldenRegistry({required this.storylines, required this.antiSlugs});

  late final Map<String, RegistryStoryline> bySlug = {
    for (final storyline in storylines) storyline.slug: storyline,
  };

  List<String> get slugs => [for (final s in storylines) s.slug];

  static GoldenRegistry fromJson(Map<String, dynamic> json) => GoldenRegistry(
        storylines: [
          for (final entry in asList(json['storylines']))
            RegistryStoryline.fromJson(asMap(entry)),
        ],
        antiSlugs: [
          for (final entry in asList(json['anti_storylines']))
            asString(asMap(entry)['slug']),
        ],
      );
}

/// Reads a storyline registry off disk.
///
/// Throws rather than returning an empty registry, for `loadGoldenSet`'s
/// reason: the registry is git-ignored and machine-local by design, so "no
/// file" is the normal failure and it deserves a message that says what to set.
Future<GoldenRegistry> loadGoldenRegistry(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw StateError(
      'no storyline registry at $path — it is git-ignored and machine-local; '
      'point GOLDEN_REGISTRY at it in local.mk, or pass '
      '--dart-define=GOLDEN_REGISTRY=…',
    );
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map || decoded['storylines'] is! List) {
    throw StateError(
      'the file at $path is not a storyline registry — no `storylines` array '
      'in it',
    );
  }
  return GoldenRegistry.fromJson(decoded.cast<String, dynamic>());
}

/// Everyone on any thread the set files under [slug] — except the thread named
/// by [excludingConversation] — de-duplicated, in first-seen order.
///
/// Mirrors `_participantsOfStoryline` in
/// `lib/services/storyline_service.dart:2554`, which walks the storyline's
/// member rows and unions the display names of each member's conversation:
/// same union, same first-seen order, same case-insensitive de-duplication,
/// same rule that an empty display name is not a person. The list is the
/// strongest signal a confirm prompt carries, so a replay that built it any
/// other way would be judging a storyline the app never describes.
///
/// [excludingConversation] is what makes it the app's list rather than a
/// leak. The app asks about a CANDIDATE, which by construction is not yet a
/// member, so the storyline it is judged against never contains it. Unioning
/// the whole set would put the candidate's own people into the `People:` line
/// of every gold storyline it is asked about — the candidate card's
/// participants segment, handed back as evidence — and the gold-accept rate,
/// which is the headline number of the whole run, would be measuring that
/// hint. The exclusion is by CONVERSATION rather than by item id because two
/// golden items drawn from one conversation are one thread, and the app files
/// threads.
///
/// The trade is honest and goes the safe way. A storyline whose only golden
/// item is the candidate arrives with an empty `People:` line, which is
/// THINNER than the prompt the app would send for a storyline that already
/// had members — so the replay penalises the model rather than flattering it,
/// and the run counts how many gold candidates were judged that way.
///
/// The SET is the source rather than the registry's own member list because
/// the registry records conversation keys and no names: the golden items are
/// the only place a name and a slug meet. Four of the thirty slugs carry no
/// golden item at all and come back empty whatever is excluded.
List<String> participantsFor(
  String slug,
  GoldenSet set, {
  String? excludingConversation,
}) {
  final seen = <String>{};
  final displays = <String>[];
  for (final item in set.items) {
    if (item.gold.storylineId != slug) continue;
    if (excludingConversation != null &&
        item.conversationKey == excludingConversation) {
      continue;
    }
    for (final display in item.conversationParticipants) {
      if (display.isEmpty) continue;
      if (seen.add(display.toLowerCase())) displays.add(display);
    }
  }
  return displays;
}

/// The storylines [item] is asked about, in the order they are asked.
///
/// BOUNDED, and that is the whole design. Confirming every item against every
/// registry storyline is thirty calls an item and three thousand over the set;
/// this list is three to six, about four and a half on average, and 453 over
/// the set. What it gives up is the question "would the model have picked a
/// storyline nobody suggested", which the sweep and the embedding shortlist
/// answer in the app and which no confirm call can answer on its own.
///
/// Three parts, in this order:
///
/// 1. The gold storyline, when the item has one — the recall question.
/// 2. Every registry storyline gold marks FORBIDDEN on this item, in gold's
///    order — the trap. `ANTI-*` slugs are dropped here: an anti-storyline has
///    no charter to judge against, and it is scored through the real
///    storylines' forbidden lists instead.
/// 3. [extras] further storylines, drawn from whatever is left — the
///    false-positive probe. Without them a model that answered "yes" to
///    everything would look perfect on recall and only slightly wrong on the
///    traps.
///
/// The extras are drawn by a shuffle SEEDED with the item's own id, so two
/// runs of two different candidates are asked the same questions and their
/// numbers can be read against each other. A random draw would make every row
/// in the ledger a different exam.
List<String> candidatesFor(
  GoldenItem item,
  GoldenRegistry registry, {
  int extras = 3,
}) {
  final chosen = <String>[];
  final seen = <String>{};
  void take(String slug) {
    if (seen.add(slug)) chosen.add(slug);
  }

  final gold = item.gold.storylineId;
  if (gold != 'none' && registry.bySlug.containsKey(gold)) take(gold);
  for (final slug in item.gold.storylineForbidden) {
    if (registry.bySlug.containsKey(slug)) take(slug);
  }

  final rest = [
    for (final slug in registry.slugs)
      if (!seen.contains(slug)) slug,
  ]..shuffle(Random(stableSeed(item.id)));
  for (final slug in rest.take(extras)) {
    take(slug);
  }
  return chosen;
}

/// A stable 32-bit hash of [text] — FNV-1a over its UTF-16 code units.
///
/// Hand-rolled rather than `String.hashCode` because `hashCode` is not
/// specified to be stable across Dart versions, platforms or even runs, and a
/// candidate list that changed with an SDK upgrade would silently change what
/// a rerun measures — two ledger rows that looked comparable and were not.
int stableSeed(String text) {
  var hash = 2166136261;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash;
}
