/// The question set the decision model answers: the nine message fields
/// (`decision_heads.dart` `decisionFields`) and the three storyline questions.
///
/// jev-prototype's question set v5 (`tmp/questions_v5.json`, frozen in
/// `docs/PLAN-storyline-questions-training.md` §3). The texts below are
/// DOCUMENTATION: the model was trained on them and the heads encode them, so
/// nothing sends them anywhere, but a change to any of them is a new
/// [decisionQhash] and a new model.
library;

/// The question-set hash every decision model this build reads was trained
/// under: jev's `qhash_v5()`, which covers the whole set (the message fields'
/// own hash and the three storyline questions). The heads file carries it and
/// a stored decision records it; a row under another hash was answered by
/// another model and is treated as undecided.
const String decisionQhash = 'f495a7dc48aa34d5';

/// One storyline question, in head order after the nine message fields.
enum StorylineQuestion {
  /// Asked of a pair of threads, in both orders
  /// (`renderStorylinePair`).
  sameEffort('same_effort', 'pair'),

  /// Asked of a storyline's charter over one thread
  /// (`renderStorylineMembership`).
  memberOf('member_of', 'membership'),

  /// Asked of a storyline's title and charter alone
  /// (`renderStorylineCharter`).
  charterSpecific('charter_specific', 'charter');

  /// The question's id in the heads file and in `onCall` labels.
  final String id;

  /// The renderer the heads file names for it.
  final String renderer;

  const StorylineQuestion(this.id, this.renderer);

  /// Every storyline question's options, in head-output order.
  static const List<String> options = ['yes', 'no'];
}

/// `same_effort`'s text.
const String sameEffortPrompt =
    'Are these two threads about the same specific project, event or topic, '
    'not merely the same team, sender or kind of message?';

/// `member_of`'s text.
const String memberOfPrompt =
    'Does this thread belong to the storyline above: is it part of the one '
    'specific effort its title and charter describe, not merely about the '
    'same people, team or kind of message?';

/// `charter_specific`'s text.
const String charterSpecificPrompt =
    'Does this describe one specific effort, rather than a person, team or '
    'category?';
