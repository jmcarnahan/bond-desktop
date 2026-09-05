import 'package:bond_inbox/services/extract_handler.dart'
    show buildConversationCard;

import 'corpus.dart';

/// The work the PROSE slot is asked to do, written down once.
///
/// `corpus.dart` is the mail the bulk slot classifies; this is the other half
/// of the app's model work — naming a storyline, catching a reader up on one,
/// and drafting a reply — and it needs its own fixtures because none of the
/// three takes a single message as input. Naming takes a whole storyline's
/// worth of conversation cards; a recap takes what was said across all of its
/// threads at once; drafting takes a thread and the message at the end of it.
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

/// One storyline to catch a reader up on, as the recap task sees it.
///
/// Unlike [NameCase] these lines are hand-written rather than built by the
/// production formatter, because the one that makes them
/// (`StorylineService._recapLine`) is private to the service and reads a store
/// row, not a model. The shape is pinned in `prose_cases_test.dart` instead:
/// `[subject] sender: text`, the subject bracket dropped when a chat has none,
/// and the inbox owner rendered as `You` — the distinction the recap most has
/// to get right, since a thread whose last word is the reader's is a thread
/// nobody is waiting on them for.
class RecapCase {
  /// Stable slug, so a row in the live table names the case it came from.
  final String id;

  final String title;

  /// The membership contract, exactly as the storyline stores it. Empty is
  /// legal — a storyline named before charters existed is recapped from its
  /// messages alone.
  final String charter;

  /// The recap as it stood before these messages, or empty for the first one.
  /// The interesting cases are the non-empty ones: the prompt asks the model
  /// to carry forward what is still true, and dropping an item that has just
  /// been settled is exactly the judgement being read.
  final String previousRecap;

  /// The window, OLDEST FIRST — the order `RecapInput.messageLines` wants,
  /// because the model is asked where things stand at the END of it.
  final List<String> messageLines;

  const RecapCase({
    required this.id,
    required this.title,
    required this.charter,
    required this.previousRecap,
    required this.messageLines,
  });
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

/// Three storylines to catch a reader up on.
///
/// The three are the states a recap has to handle, not three flavours of the
/// same one. A storyline mid-flight, where something was decided and something
/// else is still owed — the ordinary case. The SAME storyline a few messages
/// later, where the thing that was owed has just been settled: the previous
/// recap rides in saying it is open, and a model that merely rewrites what it
/// was handed will say so again. And a quiet storyline where nothing is
/// outstanding at all, which is the one the block most has to survive — an
/// inbox that only speaks up about work owed is silent about the storylines
/// that are going well, and inventing an open question to fill the list is
/// worse than an empty one.
///
/// They reuse the naming set's world (`conference-talk`, `kitchen-renovation`)
/// on purpose: reading a recap next to the cards it was written from is how a
/// person tells "carried forward" apart from "made up".
const List<RecapCase> recapCases = [
  RecapCase(
    id: 'talk-midflight',
    title: 'Northline Design Week talk',
    charter: 'The Northline Design Week talk — the accepted slot, the slides, '
        'and the venue logistics.',
    previousRecap: '',
    messageLines: [
      '[Talk accepted — Northline Design Week] Priya Raman: You are on the '
          'Thursday morning track, forty minutes including questions. Can you '
          'send a title and a one-paragraph blurb by the end of the week?',
      '[Talk accepted — Northline Design Week] You: Confirmed for Thursday '
          'morning. Title and blurb to follow.',
      '[Slides review before the dry run] Priya Raman: Read the first draft. '
          'The middle third runs long — I would cut the second case study '
          'entirely.',
      '[Slides review before the dry run] You: Agreed, the second case study '
          'goes. I will re-time it tonight.',
      '[AV check and speaker logistics] Northline Events: Do you need an HDMI '
          'adapter or will you present from our machine? We can also offer a '
          'stage rehearsal on the Wednesday evening.',
    ],
  ),
  RecapCase(
    id: 'talk-open-item-settled',
    title: 'Northline Design Week talk',
    charter: 'The Northline Design Week talk — the accepted slot, the slides, '
        'and the venue logistics.',
    previousRecap: 'The Thursday morning slot is confirmed and the slides are '
        'being cut down after Priya read the first draft. Alex still owes '
        'Priya a title and a blurb, and the venue is waiting on an answer '
        'about the adapter.',
    messageLines: [
      '[Talk accepted — Northline Design Week] You: Title and blurb attached '
          '— "Drawing before deciding", two hundred words.',
      '[Talk accepted — Northline Design Week] Priya Raman: Blurb is in the '
          'programme, thank you. Nothing else needed from you until the dry '
          'run.',
      '[AV check and speaker logistics] You: I will bring my own laptop and '
          'an HDMI adapter, so no need for yours.',
      '[AV check and speaker logistics] Northline Events: Noted. The '
          'Wednesday evening rehearsal is still open if you want it — let us '
          'know by Monday.',
    ],
  ),
  RecapCase(
    id: 'kitchen-quiet',
    title: 'Kitchen remodel',
    charter: 'The kitchen at home — the quote, the worktops, and scheduling '
        'the trades.',
    previousRecap: 'Dana is holding an October slot and the worktop pick has '
        'come down to walnut or the pale quartz. Ray has two days free in the '
        'second week of October and wants them held or released.',
    messageLines: [
      '[Worktop samples — walnut or the pale quartz] You: Going with the pale '
          'quartz.',
      '[Worktop samples — walnut or the pale quartz] Dana Whitfield: Ordered. '
          'Four week lead time, as quoted.',
      '[Plumber availability for the sink move] Ray Okonjo: Holding the 8th '
          'and the 9th then. Nothing needed from you until the week before.',
    ],
  ),
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
