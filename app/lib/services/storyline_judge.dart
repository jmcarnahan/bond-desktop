import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../data/message_store.dart';
import '../models/storyline_models.dart';
import 'decision/decision_client.dart';
import 'decision/decision_questions.dart';
import 'decision/storyline_state.dart';
import 'decision/storyline_thread_input.dart';

/// The numbers every storyline judgement is read against: the decision
/// model's `member_of`, `same_effort` and `charter_specific` p(yes), and the
/// cosine retrieval in front of them.
///
/// The membership thresholds and the charter threshold are FITTED on the
/// golden set against the ModernBERT v3 student (2026-09-30); [linkTau] and
/// [pairBudgetPerPass] are PROVISIONAL, because they are read only by the
/// decision grouping, which is a bench arm. Every one moves only with a
/// `make golden-storyline`, `golden-declared` or `golden-sweep` row on each
/// side, like every `DecisionPolicy` and `StorylineTuning` number. One file,
/// so a threshold is never spelled twice.
abstract final class StorylinePolicy {
  /// A thread joins a storyline the owner KEPT at p(member_of = yes) ≥ this.
  ///
  /// Fitted 2026-09-30 on v3: the confirm bench (`make golden-storyline`)
  /// scores 89/98 at 0.50, 40 of 48 must-links, with 6 of 88 forbidden
  /// accepts (7%), against the box 27B's 84/98 and 8%; the declared bench
  /// (`make golden-declared`) scores 84/98 at both 0.50 and 0.60, with 39
  /// correct positives at 0.50 against 35 at 0.60 and 4 forbidden at both,
  /// so the lower cut keeps four more right answers for no wrong one.
  static const double acceptActive = 0.50;

  /// A thread joins a storyline nobody has kept yet — an automatic
  /// suggestion, and the sweep's own unsaved proposal — at p ≥ this. Higher
  /// than [acceptActive] for the reason the old rule held such a storyline to
  /// `high`: filing into a group the owner has never looked at is how the
  /// blobs grew.
  ///
  /// Fitted 2026-09-30 on v3 with the shipped cosine grouping and the model
  /// charter check (`make golden-sweep`): 0.70 scored 59/98 with 14 correct
  /// positives and 3 forbidden hits, 0.74 scored 60/98 with 16 and 3, in
  /// line with the training session's own fit of the member_of cut.
  static const double acceptSuggested = 0.74;

  /// The cosine a live storyline must reach against a thread, at its centroid
  /// or at its nearest member, to be asked about it at all — and the
  /// shortlist floor of the recruit and the sweep's probe. A loose floor: the
  /// vector decides what the model looks at, never membership.
  static const double assignRetrievalFloor = 0.30;

  /// How many storylines the assign pass asks about per ranking: the top
  /// this-many by centroid cosine and the top this-many by nearest-member
  /// cosine, merged.
  static const int assignTopK = 3;

  /// How many nearest pool threads, by clustering-vector cosine, each pool
  /// thread proposes as `same_effort` candidates in a sweep pass. The vector
  /// only proposes the pair; the decision model judges it.
  static const int pairNeighbours = 10;

  /// The cosine a neighbour must reach to be proposed as a pair at all. As
  /// loose as [assignRetrievalFloor], for the same reason: retrieval, never
  /// a verdict.
  static const double pairRetrievalFloor = 0.30;

  /// How many NEW pairs one sweep pass may send to the decision model. The
  /// answers are cached (`pair_decisions`), so a pool larger than this
  /// converges over a few passes, newest threads' pairs first; a pair left
  /// unscored reads as p = 0 in the pass that skipped it.
  ///
  /// PROVISIONAL, read only by the decision bench arm. The golden pool of 71
  /// threads proposes about 570 candidate pairs, so a first pass over it
  /// defers (2026-09-30: 400 scored, 166 deferred, 5 clusters deferred), and
  /// the golden sweep bench keeps running passes while clusters are deferred.
  static const int pairBudgetPerPass = 400;

  /// Two clusters merge while the mean `same_effort` p between them is at
  /// least this (average linkage), and a member whose mean p to the rest of
  /// its cluster falls under it is an outlier and returns to the pool.
  ///
  /// PROVISIONAL and not shipped: read only by the decision bench arm. The
  /// scale is the v3 student's, whose `same_effort` p over the golden pool
  /// is compressed near zero (AUC 0.888; 5% false links at 50% recall sits at
  /// p 0.01, 13% at 70% recall at p 0.002), so a neutral 0.5 links nothing.
  /// Golden sweep rows on 2026-09-30 (id score / correct positives /
  /// forbidden hits / formed): 0.0018 → 57/98, 13, 5, 6; 0.004 → 55/98, 13,
  /// 4, 8; 0.008 → 51/98, 18, 7, 10; 0.0135 → 50/98, 0, 0 on one
  /// budget-bound pass. 0.008 is the row with the most correct positives.
  static const double linkTau = 0.008;

  /// A named cluster's title and charter pass the charter check at
  /// p(charter_specific = yes) ≥ this; under it the cluster is filed
  /// `possible`, as the regex lint files one.
  ///
  /// Fitted 2026-09-30 on v3 with the cosine grouping (`make golden-sweep`):
  /// the model check at 0.50 refused 5 of 9 charters and scored 60/98 (16
  /// correct positives, 3 forbidden) against the regex lint's 54/98 (17, 3).
  static const double charterSpecificTau = 0.50;
}

/// One membership judgement: the decision model's p(yes), and the sentence a
/// person reads for it on the timeline card and after "Filed in".
@immutable
class MembershipAnswer {
  final double p;
  final String evidence;

  const MembershipAnswer({required this.p, required this.evidence});

  /// The templated sentence: the model gives a number, not a reason, so the
  /// evidence says what the number was and nothing it cannot back.
  factory MembershipAnswer.of(double p) => MembershipAnswer(
        p: p,
        evidence: 'The decision model put this thread at '
            '${(p * 100).round()}% for this storyline.',
      );
}

/// The storyline questions, asked of the decision model over threads read
/// from the store.
///
/// Every judgement THROWS what the decision client throws, so the storyline
/// lane parks on a decision server that is down or misconfigured. There is no
/// language-model fallback: a membership the decision model cannot answer is
/// asked again when it can.
class StorylineJudge {
  // `this._…` in named parameters, as `DecisionClient` declares its own:
  // callers name them `decision:` and the rest, and the fields stay private.
  StorylineJudge({
    required this._decision,
    required this._store,
    this._ensureBodies,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DecisionClient _decision;
  final MessageStore _store;

  /// Fetches the named messages' bodies — the rendered rows still showing
  /// their preview — in one thread. In the app the mail sync's narrow
  /// `ensureBodiesFor`, which queues no attachment work; null (Teams, and
  /// every test that does not care) renders what is stored.
  final Future<void> Function(
    String source,
    String conversationKey,
    List<String> sourceMessageIds,
  )? _ensureBodies;

  final DateTime Function() _now;

  /// How long a thread whose body fetch failed is judged on its preview
  /// without asking again: the rest of a pass or a lap, and not every
  /// candidate of it. A mail server that is down fails every fetch alike.
  static const Duration fetchRetryAfter = Duration(minutes: 5);

  /// When each thread's last body fetch failed, as `'<source>\n<key>'`.
  final Map<String, DateTime> _fetchFailedAt = {};

  /// The fetches that already succeeded since [beginPass], as the thread and
  /// the preview ids asked for. A message whose fetched body is empty still
  /// renders its preview, so without this every judgement of its thread in a
  /// pass would fetch it again; a NEW preview row is a different set of ids
  /// and is fetched.
  final Set<String> _fetched = {};

  /// Throws the park a question would throw when the decision model plainly
  /// cannot answer, asking it nothing ([DecisionClient.ensureReady]). The
  /// sweep calls it before it spends a naming call on a cluster only the
  /// decision model can confirm.
  Future<void> ensureReady() => _decision.ensureReady();

  /// p(member_of = yes) for each of [threads] against [storyline], in order,
  /// in ONE request batch.
  ///
  /// The state is the storyline's title and charter over the thread's text.
  /// A storyline with no charter renders `(none)` in the charter slot, never
  /// its summary: the summary is display text, not the membership contract,
  /// and `(none)` is the state training includes for an uncharted
  /// storyline.
  Future<List<double>> memberOf(
    Storyline storyline,
    List<({String source, String key})> threads,
  ) async {
    if (threads.isEmpty) return const [];
    final states = <String>[];
    for (final thread in threads) {
      states.add(_membershipState(
        storyline,
        (await threadText(thread.source, thread.key)).text,
      ));
    }
    return _decision.ask(StorylineQuestion.memberOf, states);
  }

  /// p(member_of = yes) for ONE thread against each of [storylines], in
  /// order, in one batch: the thread's text is built once, with at most one
  /// body fetch, and each storyline gets its own state. The assign pass's
  /// question.
  Future<List<double>> memberOfEach(
    List<Storyline> storylines,
    ({String source, String key}) thread,
  ) async {
    if (storylines.isEmpty) return const [];
    final text = (await threadText(thread.source, thread.key)).text;
    return _decision.ask(StorylineQuestion.memberOf, [
      for (final storyline in storylines) _membershipState(storyline, text),
    ]);
  }

  /// p(charter_specific = yes): whether [title] and [charter] describe one
  /// specific effort rather than a person, team or category.
  Future<double> charterSpecific(String? title, String? charter) async {
    final p = await _decision.ask(StorylineQuestion.charterSpecific, [
      renderStorylineCharter(title: title, charter: charter),
    ]);
    return p.single;
  }

  /// p(same_effort = yes) for each pair of threads, in order: the mean over
  /// both orders ([DecisionClient.askPairs]). Each thread's text is built
  /// once however many pairs it is in.
  Future<List<double>> sameEffort(
    List<
            (
              ({String source, String key}),
              ({String source, String key}),
            )>
        pairs,
  ) async {
    if (pairs.isEmpty) return const [];
    final texts = <String, String>{};
    Future<String> textOf(({String source, String key}) thread) async {
      final id = '${thread.source}\n${thread.key}';
      return texts[id] ??= (await threadText(thread.source, thread.key)).text;
    }

    final rendered = <(String, String)>[];
    for (final (a, b) in pairs) {
      rendered.add((await textOf(a), await textOf(b)));
    }
    return sameEffortOfTexts(rendered);
  }

  /// [sameEffort] over thread texts the caller already built — the sweep's
  /// pair scoring, which builds each pool thread's text once per pass and
  /// needs its hash for the pair cache before it asks anything.
  Future<List<double>> sameEffortOfTexts(List<(String, String)> pairs) =>
      _decision.askPairs(pairs);

  /// Forgets which threads' body fetches already landed, so a pass that
  /// starts now may fetch each of them once more; inside the pass a thread is
  /// fetched at most once. The sweep calls it at the top of a pass. The
  /// FAILURE memo is not touched: a mail server that was down a minute ago is
  /// not asked again until [fetchRetryAfter] has passed, whichever pass asks.
  void beginPass() => _fetched.clear();

  /// Who answers `same_effort` now, as the sweep's pair cache keys it:
  /// `'<qhash>|<model identity>'` ([DecisionClient.modelIdentity]). Another
  /// question set, another backend or a re-installed model is another key,
  /// and its pairs are asked again.
  Future<String> decidedBy() async =>
      '$decisionQhash|${await _decision.modelIdentity()}';

  /// One thread's text, with the bodies of its preview rows fetched first.
  ///
  /// Training saw every message's own body; a preview is Graph's cut of the
  /// whole body, quoted chain included, so the rendered rows still carrying
  /// one ([StorylineThreadText.previewIds]) are fetched and the text is built
  /// again. The text is rebuilt even when the fetch throws partway, since the
  /// bodies that landed before the failure are real. A failure is logged,
  /// judged on what is stored, and not asked again for [fetchRetryAfter]: a
  /// mail server being down must neither park the storyline lane nor cost a
  /// failed round trip per candidate.
  Future<StorylineThreadText> threadText(String source, String key) async {
    final first = await storylineThreadTextFor(_store, source, key);
    final ensure = _ensureBodies;
    if (first.previewIds.isEmpty || ensure == null) return first;
    final id = '$source\n$key';
    final failedAt = _fetchFailedAt[id];
    if (failedAt != null && _now().difference(failedAt) < fetchRetryAfter) {
      return first;
    }
    final asked = '$id\n${first.previewIds.join('\n')}';
    if (_fetched.contains(asked)) return first;
    try {
      await ensure(source, key, first.previewIds);
      _fetchFailedAt.remove(id);
      _fetched.add(asked);
    } catch (e) {
      _fetchFailedAt[id] = _now();
      debugPrint('storyline judge: fetching bodies for $source failed: $e');
    }
    return storylineThreadTextFor(_store, source, key);
  }

  static String _membershipState(Storyline storyline, String threadText) =>
      renderStorylineMembership(
        title: storyline.title,
        charter: _nonBlank(storyline.charter),
        threadText: threadText,
      );

  static String? _nonBlank(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;
}
