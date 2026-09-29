import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../data/message_store.dart';
import '../models/storyline_models.dart';
import 'decision/decision_client.dart';
import 'decision/decision_questions.dart';
import 'decision/storyline_state.dart';
import 'decision/storyline_thread_input.dart';

/// The numbers every storyline membership judgement is read against: the
/// decision model's `member_of` p(yes) and the cosine retrieval in front of
/// it.
///
/// PROVISIONAL, every one of them. They were set from the Phase 2 as-is
/// evaluation (Kev v2 put `member_of` at 87/98 at 0.5 on the confirm bench)
/// and are refitted when the v3 model lands, with a `make golden-storyline`
/// row on each side, like every `DecisionPolicy` and `StorylineTuning`
/// number. One file, so a threshold is never spelled twice.
abstract final class StorylinePolicy {
  /// A thread joins a storyline the owner KEPT at p(member_of = yes) ≥ this.
  static const double acceptActive = 0.50;

  /// A thread joins a storyline nobody has kept yet — an automatic
  /// suggestion, and the sweep's own unsaved proposal — at p ≥ this. Higher
  /// than [acceptActive] for the reason the old rule held such a storyline to
  /// `high`: filing into a group the owner has never looked at is how the
  /// blobs grew.
  static const double acceptSuggested = 0.70;

  /// The cosine a live storyline must reach against a thread, at its centroid
  /// or at its nearest member, to be asked about it at all — and the
  /// shortlist floor of the recruit and the sweep's probe. A loose floor: the
  /// vector decides what the model looks at, never membership.
  static const double assignRetrievalFloor = 0.30;

  /// How many storylines the assign pass asks about per ranking: the top
  /// this-many by centroid cosine and the top this-many by nearest-member
  /// cosine, merged.
  static const int assignTopK = 3;
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

  /// Throws the park a question would throw when the decision model plainly
  /// cannot answer, asking it nothing ([DecisionClient.ensureReady]). The
  /// sweep calls it before it spends a naming call on a cluster only the
  /// decision model can confirm.
  Future<void> ensureReady() => _decision.ensureReady();

  /// p(member_of = yes) for each of [threads] against [storyline], in order,
  /// in ONE request batch.
  ///
  /// The state is the storyline's title and charter over the thread's text.
  /// A storyline with no charter is judged against its summary, since that is
  /// the nearest thing to a statement of what it holds; with neither, the
  /// renderer says `(none)`.
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
    return _decision.askPairs(rendered);
  }

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
    try {
      await ensure(source, key, first.previewIds);
      _fetchFailedAt.remove(id);
    } catch (e) {
      _fetchFailedAt[id] = _now();
      debugPrint('storyline judge: fetching bodies for $source failed: $e');
    }
    return storylineThreadTextFor(_store, source, key);
  }

  static String _membershipState(Storyline storyline, String threadText) =>
      renderStorylineMembership(
        title: storyline.title,
        charter: _nonBlank(storyline.charter) ?? _nonBlank(storyline.summary),
        threadText: threadText,
      );

  static String? _nonBlank(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;
}
