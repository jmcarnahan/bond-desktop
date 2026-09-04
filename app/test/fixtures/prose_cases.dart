import 'package:bond_inbox/services/extract_handler.dart'
    show buildConversationCard;

import 'corpus.dart';

/// The work the PROSE slot is asked to do, written down once.
///
/// `corpus.dart` is the mail the bulk slot classifies; this is the other half
/// of the app's model work — naming a storyline and drafting a reply — and it
/// needs its own fixtures because neither task takes a single message as
/// input. Naming takes a whole storyline's worth of conversation cards;
/// drafting takes a thread and the message at the end of it.
///
/// Entirely fictional, and deliberately so, for the same reason `corpus.dart`
/// is: this repo is public. The inbox belongs to Alex Rivera, who runs a small
/// design practice and reads work and home mail in the same list. Nothing here
/// describes a real person, a real project, or a real transaction.
///
/// Nothing in this file is an expectation. A title and a drafted reply are
/// prose, and prose is judged by reading it — see `llm_prose_live_test.dart`,
/// which prints every answer verbatim and scores none of them.

/// One storyline's threads, as the naming task sees them.
///
/// Every card comes from the REAL [buildConversationCard], not from a
/// hand-typed string that looks like one. The four-segment ` | ` shape is what
/// `NameStorylineTask.buildUserMessage` joins and what the embedding path
/// produces, and a fixture that drifted from it would bench the model on input
/// the app never sends.
class NameCase {
  /// Stable slug, so a row in the live table names the case it came from.
  final String id;

  /// Two to four cards, all plainly about ONE nameable thing. That is the
  /// whole design of the set: a storyline the model cannot name because its
  /// threads have nothing in common tests the fixture, not the model.
  final List<String> cards;

  const NameCase(this.id, this.cards);
}

/// One thread to draft a reply to, named by corpus id rather than copied.
///
/// The message bodies live in `corpus.dart` and are referenced from here, so
/// the two cannot drift: a draft benched against a body that no longer matches
/// the one triage sees would be benching a mailbox that does not exist.
class DraftCase {
  final String id;

  /// Corpus entry ids, OLDEST FIRST — the order `DraftInput.thread` wants.
  /// The reply target is the last one, and it is always inbound: a draft
  /// answering the owner's own message would be answering nobody.
  final List<String> messageIds;

  const DraftCase(this.id, this.messageIds);
}

/// Five storylines to name. Varied on purpose — a kitchen, a talk, a car, a
/// fundraiser, a trip — because five sets of cards about neighbouring topics
/// would produce five titles nobody could tell apart, and telling them apart
/// is the whole judgement being made.
final List<NameCase> nameCases = [
  NameCase('kitchen-renovation', [
    buildConversationCard(
      subject: 'Quote for the kitchen — two options',
      participants: const ['Dana Whitfield', 'Alex Rivera'],
      topics: const ['kitchen remodel', 'quote'],
      summary: 'Dana prices keeping the layout against moving the sink and '
          'can hold an October slot until Friday.',
    ),
    buildConversationCard(
      subject: 'Worktop samples — walnut or the pale quartz',
      participants: const ['Dana Whitfield', 'Alex Rivera'],
      topics: const ['kitchen remodel', 'materials'],
      summary: 'Two worktop samples are at the house and Dana needs a pick '
          'before the supplier order goes in.',
    ),
    buildConversationCard(
      subject: 'Plumber availability for the sink move',
      participants: const ['Dana Whitfield', 'Ray Okonjo', 'Alex Rivera'],
      topics: const ['kitchen remodel', 'scheduling'],
      summary: 'Ray has two days free in the second week of October and '
          'wants them held or released.',
    ),
  ]),
  NameCase('conference-talk', [
    buildConversationCard(
      subject: 'Talk accepted — Northline Design Week',
      participants: const ['Priya Raman', 'Alex Rivera'],
      topics: const ['conference talk', 'acceptance'],
      summary: 'The forty-minute slot is confirmed for the Thursday morning '
          'track.',
    ),
    buildConversationCard(
      subject: 'Slides review before the dry run',
      participants: const ['Priya Raman', 'Tom Alvarez', 'Alex Rivera'],
      topics: const ['conference talk', 'slides'],
      summary: 'Priya has read the first draft and thinks the middle third '
          'runs long.',
    ),
    buildConversationCard(
      subject: 'AV check and speaker logistics',
      participants: const ['Northline Events', 'Alex Rivera'],
      topics: const ['conference talk', 'logistics'],
      summary: 'The venue needs a laptop adapter answer and offers a stage '
          'rehearsal on the Wednesday evening.',
    ),
  ]),
  NameCase('car-sale', [
    buildConversationCard(
      subject: 'Still selling the estate?',
      participants: const ['Sam Okafor', 'Alex Rivera'],
      topics: const ['car sale', 'enquiry'],
      summary: 'Sam asks whether the car is still available and what the '
          'service history looks like.',
    ),
    buildConversationCard(
      subject: 'Viewing on Saturday morning',
      participants: const ['Sam Okafor', 'Alex Rivera'],
      topics: const ['car sale', 'scheduling'],
      summary: 'A Saturday viewing is proposed and the logbook needs digging '
          'out beforehand.',
    ),
  ]),
  NameCase('school-fundraiser', [
    buildConversationCard(
      subject: 'Spring fair — volunteers still needed',
      participants: const ['Rosa Delgado', 'Alex Rivera'],
      topics: const ['school fundraiser', 'volunteers'],
      summary: 'Two stalls have nobody on them and the rota closes at the '
          'end of the month.',
    ),
    buildConversationCard(
      subject: 'Raffle prizes from local businesses',
      participants: const ['Rosa Delgado', 'Nina Alvarez', 'Alex Rivera'],
      topics: const ['school fundraiser', 'donations'],
      summary: 'Nina has three prizes promised and wants a letter she can '
          'hand to the rest.',
    ),
    buildConversationCard(
      subject: 'Cake stall pricing',
      participants: const ['Nina Alvarez', 'Alex Rivera'],
      topics: const ['school fundraiser', 'pricing'],
      summary: 'Last year the cakes sold out in an hour and Nina thinks the '
          'prices were too low.',
    ),
    buildConversationCard(
      subject: 'Fair floor plan — where the stalls go',
      participants: const ['Rosa Delgado', 'Alex Rivera'],
      topics: const ['school fundraiser', 'layout'],
      summary: 'The hall plan is drafted and the raffle table has nowhere '
          'sensible to sit.',
    ),
  ]),
  NameCase('hiking-trip', [
    buildConversationCard(
      subject: 'Three days on the ridge in October',
      participants: const ['Tom Alvarez', 'Dev Raman', 'Alex Rivera'],
      topics: const ['hiking trip', 'planning'],
      summary: 'Tom proposes the ridge route over a long weekend in October.',
    ),
    buildConversationCard(
      subject: 'Hut booking closes in two weeks',
      participants: const ['Dev Raman', 'Alex Rivera'],
      topics: const ['hiking trip', 'booking'],
      summary: 'The middle hut takes bookings a month ahead and needs a '
          'headcount.',
    ),
    buildConversationCard(
      subject: 'Who is driving and what are we carrying',
      participants: const ['Tom Alvarez', 'Dev Raman', 'Alex Rivera'],
      topics: const ['hiking trip', 'logistics'],
      summary: 'One car covers everyone if the packs go in the boot rather '
          'than a roof box.',
    ),
  ]),
];

/// Five threads to draft replies to.
///
/// Chosen because each one plainly asks for an answer — a yes or no, a pick
/// between two options, a question a reply has to address — since a draft of a
/// message nobody was waiting on tells you nothing about the model. One is
/// multi-message on purpose: `DraftTask` trims a thread from the OLD end and
/// answers the last message, and a set of five single-message threads would
/// never run that path.
const List<DraftCase> draftCases = [
  DraftCase('dinner-invitation', ['friday-dinner']),
  DraftCase('proposal-questions', ['client-question']),
  DraftCase('pickup-swap', ['school-pickup']),
  DraftCase('kitchen-quote-decision', ['contractor-quote']),
  DraftCase('launch-escalation', ['project-status-update', 'deadline-escalation']),
];

/// The messages of one draft case, oldest first — the list `DraftInput.thread`
/// takes, and whose last entry is the reply target.
List<CorpusEmail> draftThread(DraftCase draft) =>
    [for (final id in draft.messageIds) corpusById[id]!];
