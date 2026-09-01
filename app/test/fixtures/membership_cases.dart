import 'package:bond_inbox/models/storyline_models.dart';

/// The membership judgements the confirm task should get right, written down
/// once so a prompt change can be measured rather than argued about.
///
/// Entirely fictional, for the reason `corpus.dart` is: this repo is public.
/// The inbox belongs to Alex Rivera, who runs a small design practice and
/// reads work and home mail in the same list.
///
/// Nothing here is asserted offline. A membership verdict is a judgement, and
/// a threshold pinned in an offline test would fail on the next model swap for
/// no defect — [MembershipCase.expectBelongs] is documentation the live
/// harness prints a table against, and a person decides whether the number is
/// good enough. See `llm_membership_live_test.dart`.

/// One membership judgement the confirm task should get right.
class MembershipCase {
  /// Stable slug, so a row in the live table names the case it came from.
  final String id;

  /// The storyline as stored — title, summary and charter, exactly the three
  /// fields `ConfirmMembershipTask.buildUserMessage` reads.
  final Storyline storyline;

  /// Everyone on the storyline's member threads, as the service collects them.
  final List<String> participants;

  /// The candidate thread's card: four ` | `-joined segments — subject,
  /// participants, topics, summary — empty ones included, the same shape
  /// `buildConversationCard` produces.
  final String candidateCard;

  /// What the SERVICE should conclude, not merely what the model should
  /// answer: the service reads a `low` confidence as a no, so the verdict
  /// compared against this is `belongs && confidence != 'low'`.
  final bool expectBelongs;

  /// Whether missing this one disqualifies a server from running confirm. The
  /// hard cases are worth measuring and not worth gating on — a genuinely
  /// borderline thread is one a person would also hesitate over.
  final bool mustPass;

  /// Why this case is in the set. Read when a run regresses.
  final String note;

  const MembershipCase({
    required this.id,
    required this.storyline,
    required this.participants,
    required this.candidateCard,
    required this.expectBelongs,
    required this.mustPass,
    required this.note,
  });
}

const List<MembershipCase> membershipCases = [
  MembershipCase(
    id: 'friday-dinner-thin',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Friday dinner',
      summary: 'Waiting on a headcount before the table is booked.',
      charter: "Planning the Friday dinner at Alex's place — scheduling, the "
          'guest list, and who brings what.',
      status: 'active',
    ),
    participants: ['Priya Natarajan', 'Jordan Beck'],
    candidateCard: 'Friday dinner | Caitlin Zhao |  | ',
    expectBelongs: true,
    mustPass: false,
    note: 'The live repro shape: the right answer is in the subject and '
        'nowhere else, and the only person on it is new. Deliberately hard — '
        'this is the case the enriched card exists to fix.',
  ),
  MembershipCase(
    id: 'friday-dinner-enriched',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Friday dinner',
      summary: 'Waiting on a headcount before the table is booked.',
      charter: "Planning the Friday dinner at Alex's place — scheduling, the "
          'guest list, and who brings what.',
      status: 'active',
    ),
    participants: ['Priya Natarajan', 'Jordan Beck'],
    candidateCard: 'Friday dinner | Caitlin Zhao | dinner plans, scheduling | '
        'Asks what time to come on Friday and offers to bring dessert.',
    expectBelongs: true,
    mustPass: true,
    note: 'The same thread with topics and a summary attached. If this one '
        'misses, enrichment bought nothing.',
  ),
  MembershipCase(
    id: 'invoice-same-kind',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Meridian Print invoice',
      summary: 'The reprint charge is disputed and a corrected invoice is due.',
      charter: 'The disputed invoice from Meridian Print for the gallery '
          'catalogue reprint — the charge itself, the correction, and paying '
          'it.',
      status: 'active',
    ),
    participants: ['Marisa Okonkwo', 'Accounts Receivable'],
    candidateCard: 'Invoice 4471 | Fernbrook Supply Billing | invoice, '
        'payment due | Sends the July supply invoice and asks for payment '
        'within thirty days.',
    expectBelongs: false,
    mustPass: true,
    note: 'Two invoices are the same KIND of thing and nothing else. The '
        'failure this prompt is most often accused of.',
  ),
  MembershipCase(
    id: 'trip-same-kind',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Tahoe trip',
      summary: 'The cabin is held and the drive is still being arranged.',
      charter: 'The weekend trip to Tahoe in October — the cabin booking, who '
          'is driving, and what to pack.',
      status: 'active',
    ),
    participants: ['Jordan Beck', 'Rosa Delgado'],
    candidateCard: 'Portland studio visit | Nina Alvarez | travel, '
        'scheduling | Proposes flying up on the 14th to walk the Portland '
        'site before the install.',
    expectBelongs: false,
    mustPass: true,
    note: 'Both are travel, and the vocabulary overlaps hard — flights, '
        'dates, packing. Neither is the other trip.',
  ),
  MembershipCase(
    id: 'vocabulary-coincidence',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Website redesign',
      summary: 'The studio is reviewing the homepage copy.',
      charter: 'The redesign of the Northline Studio website — the homepage '
          'copy, the new photography, and the launch date.',
      status: 'active',
    ),
    participants: ['Amara Okafor', 'Li Chen'],
    candidateCard: 'Five website tips for small studios | Design Weekly |  | '
        'A newsletter roundup of homepage copy advice and portfolio layout '
        'ideas.',
    expectBelongs: false,
    mustPass: true,
    note: 'Every word matches and none of it is about this project. What the '
        '"coincidence of vocabulary" clause in the prompt is for.',
  ),
  MembershipCase(
    id: 'teams-candidate',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Gallery catalogue',
      summary: 'The printer is waiting on final page proofs.',
      charter: 'Producing the spring gallery catalogue — the page proofs, the '
          'print run, and the delivery date.',
      status: 'active',
    ),
    participants: ['Marisa Okonkwo', 'Li Chen'],
    candidateCard: 'Catalogue standup | Li Chen, Amara Okafor | proofs, '
        'print schedule | Says the last two spreads are proofed and the '
        'printer can have them tomorrow.',
    expectBelongs: true,
    mustPass: false,
    note: 'A Teams-shaped card: a channel title rather than a subject line, '
        'and colleagues rather than a sender. Same project, different medium.',
  ),
  MembershipCase(
    id: 'empty-charter-fallback',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Brightsea patio build',
      summary: 'The permit is filed and the framing starts once it clears.',
      status: 'active',
    ),
    participants: ['Dana Whitfield', 'Tom Alvarez'],
    candidateCard: 'Patio permit update | Dana Whitfield | permit, framing | '
        'Says the patio permit cleared and asks to start framing on Monday.',
    expectBelongs: true,
    mustPass: true,
    note: 'No charter, so the prompt falls back to the summary. A storyline '
        'written before charters existed must still work.',
  ),
  MembershipCase(
    id: 'narrowed-charter',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Chen wedding venue',
      summary: 'Two halls are held and the deposit is due Friday.',
      charter: 'Only the venue booking for the Chen wedding — the halls, the '
          'walkthrough, and the deposit. Not general wedding planning.',
      status: 'active',
    ),
    participants: ['Li Chen', 'Rosa Delgado'],
    candidateCard: 'Invitation proofs | Li Chen | invitations, printing | '
        'Sends three invitation layouts and asks which typeface to use.',
    expectBelongs: false,
    mustPass: true,
    note: 'Charter obedience. Shared people, same wedding, and the charter '
        'says no — a user who narrowed the scope has to be obeyed or the '
        'edit box is decoration.',
  ),
  MembershipCase(
    id: 'new-vendor-joins',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Gallery catalogue',
      summary: 'The printer is waiting on final page proofs.',
      charter: 'Producing the spring gallery catalogue — the page proofs, the '
          'print run, and the delivery date.',
      status: 'active',
    ),
    participants: ['Marisa Okonkwo', 'Li Chen'],
    candidateCard: 'Catalogue paper stock | Skylark Bindery |  | Quotes two '
        'paper stocks for the spring catalogue run and asks which to hold.',
    expectBelongs: true,
    mustPass: true,
    note: 'A vendor the storyline has never seen, unmistakably about this '
        'catalogue. The participants-are-context rule, stated positively.',
  ),
  MembershipCase(
    id: 'same-people-different-topic',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Q3 offsite',
      summary: 'The venue is booked and the agenda is still open.',
      charter: 'The Q3 team offsite in September — the venue, the agenda, and '
          'who is travelling.',
      status: 'active',
    ),
    participants: ['Jordan Beck', 'Amara Okafor'],
    candidateCard: 'Invoice 2208 | Jordan Beck | invoice, payment | Forwards '
        "the framing invoice and asks whether it is Alex's to pay.",
    expectBelongs: false,
    mustPass: true,
    note: 'Participants-as-context cuts both ways: the most familiar name on '
        'the storyline, and nothing to do with the offsite.',
  ),
  MembershipCase(
    id: 'carpool-new-parent',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Soccer carpool',
      summary: 'Thursday pickup is still uncovered.',
      charter: "Arranging the weekday carpool for Saturday soccer — who "
          'drives which day, pickup times, and the field address.',
      status: 'active',
    ),
    participants: ['Rosa Delgado', 'Sam Okafor'],
    candidateCard: 'Thursday pickup | Priya Natarajan |  | Offers to take '
        "Thursday's pickup if practice still ends at five.",
    expectBelongs: true,
    mustPass: false,
    note: 'A personal storyline, a new parent, and a thin card — the domestic '
        'twin of friday-dinner-thin.',
  ),
  MembershipCase(
    id: 'borderline-countertops',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Kitchen remodel',
      summary: 'The cabinets are ordered and the counter decision is open.',
      charter: 'The kitchen remodel at home — the cabinets, the counters, and '
          'scheduling the installers.',
      status: 'active',
    ),
    participants: ['Dana Whitfield', 'Tom Alvarez'],
    candidateCard: 'Countertop samples | Stoneline Surfaces |  | ',
    expectBelongs: true,
    mustPass: false,
    note: 'Genuinely borderline: countertops are named in the charter, and '
        'nothing says this company was ever asked. Written expecting a no, '
        'but both servers answered yes/high (measured 2026-09-01) — samples '
        'arriving while the counter decision is open reads as the remodel — '
        'so the expectation was recalibrated, not the models. Still worth '
        'watching: a yes here on a colder charter would be over-grouping.',
  ),
];
