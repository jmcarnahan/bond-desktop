/// The question set the decision model answers: the nine message fields
/// (`decision_heads.dart` `decisionFields`) and the three storyline questions.
///
/// jev-prototype's question set v5 (`tmp/questions_v5.json`, frozen in
/// `docs/PLAN-storyline-questions-training.md` §3). The encoder-heads kind
/// never sends these texts: the model was trained on them and the heads
/// encode them. The `systemone` kind (Kev on the owner's server) is ASKED
/// them, in the plain framing — the instructions verbatim, null criteria, the
/// options in this canonical order — so they are copied byte for byte from
/// the handoff file, which `test/fixtures/decision/systemone_questions_v5.json`
/// pins. A change to any of them is a new [decisionQhash] and a new model.
library;

import 'package:flutter/foundation.dart' show immutable;

/// The question-set hash every decision model this build reads was trained
/// under: jev's `qhash_v5()`, which covers the whole set (the message fields'
/// own hash and the three storyline questions). The heads file carries it,
/// a Kev server lists it on `/v1/models`, and a stored decision records it;
/// a row under another hash was answered by another model and is treated as
/// undecided.
const String decisionQhash = 'f495a7dc48aa34d5';

/// One question as a `systemone` server is asked it: the id, the plain
/// instructions and the options in canonical order.
@immutable
class SystemOneQuestion {
  final String id;
  final String instructions;
  final List<String> options;

  const SystemOneQuestion(this.id, this.instructions, this.options);
}

/// The nine message fields as a `systemone` server is asked them, in
/// `decisionFields` order, all nine in one request per message state.
const List<SystemOneQuestion> systemOneMessageQuestions = [
  SystemOneQuestion(
    'gate',
    'Keep this message in the reader\'s inbox (a person wrote it, or a '
        'machine asks the reader something personally), or drop it as '
        'machine traffic nobody needs to read?',
    ['keep', 'drop'],
  ),
  SystemOneQuestion(
    'drop_reason',
    'If this message were dropped from the inbox, which kind of traffic is '
        'it?',
    [
      'newsletter',
      'no_reply',
      'auto_generated',
      'monitoring',
      'ticket_system',
      'identity_service',
      'share_notification',
      'machine_sender',
      'digest',
      'cold_outreach',
      'outbound',
      'empty',
      'other',
    ],
  ),
  SystemOneQuestion(
    'category',
    'Is this message work, personal, a notification, or other?',
    ['work', 'personal', 'notification', 'other'],
  ),
  SystemOneQuestion(
    'urgency',
    'How urgent is this message for the reader: low, normal, high or urgent?',
    ['low', 'normal', 'high', 'urgent'],
  ),
  SystemOneQuestion(
    'needs_action',
    'Does the reader need to do something because of this message?',
    ['yes', 'no'],
  ),
  SystemOneQuestion(
    'reply_expected',
    'Is the sender waiting on an answer from the reader?',
    ['yes', 'no'],
  ),
  SystemOneQuestion(
    'needs_you',
    'Does the owner of this inbox need to look at this message or act on it '
        'personally?',
    ['yes', 'no'],
  ),
  SystemOneQuestion(
    'intent',
    'What does the sender want: a request, a question, an approval, '
        'scheduling, fyi, a transactional record, or something social?',
    [
      'request',
      'question',
      'approval',
      'scheduling',
      'fyi',
      'transactional',
      'social',
    ],
  ),
  SystemOneQuestion(
    'importance',
    'How much does this message matter to the reader\'s day: low, normal or '
        'high?',
    ['low', 'normal', 'high'],
  ),
];

/// One storyline question, in head order after the nine message fields.
enum StorylineQuestion {
  /// Asked of a pair of threads, in both orders
  /// (`renderStorylinePair`).
  sameEffort(
    'same_effort',
    'pair',
    'Are these two threads about the same specific project, event or topic, '
        'not merely the same team, sender or kind of message?',
  ),

  /// Asked of a storyline's charter over one thread
  /// (`renderStorylineMembership`).
  memberOf(
    'member_of',
    'membership',
    'Does this thread belong to the storyline above: is it part of the one '
        'specific effort its title and charter describe, not merely about the '
        'same people, team or kind of message?',
  ),

  /// Asked of a storyline's title and charter alone
  /// (`renderStorylineCharter`).
  charterSpecific(
    'charter_specific',
    'charter',
    'Does this describe one specific effort, rather than a person, team or '
        'category?',
  );

  /// The question's id in the heads file, on the `systemone` wire and in
  /// `onCall` labels.
  final String id;

  /// The renderer the heads file names for it.
  final String renderer;

  /// The plain text a `systemone` server is asked.
  final String instructions;

  const StorylineQuestion(this.id, this.renderer, this.instructions);

  /// Every storyline question's options, in head-output order.
  static const List<String> options = ['yes', 'no'];
}
