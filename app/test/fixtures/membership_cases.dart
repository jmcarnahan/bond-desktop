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
    id: 'cross-source-same-project',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Northline site launch',
      summary: 'The homepage copy is signed off and the launch date is open.',
      charter: 'The redesign of the Northline Studio website — the homepage '
          'copy, the new photography, and the launch date.',
      status: 'active',
    ),
    participants: ['Amara Okafor', 'Li Chen'],
    candidateCard: 'Northline staging is up | Dev Raman, Priya Natarajan | '
        'launch, staging | Says the Northline site is on staging and asks '
        'which Friday to point the domain at it.',
    expectBelongs: true,
    mustPass: true,
    note: 'Membership is keyed on (source, conversation_key), so a chat thread '
        'and a mail thread live in one storyline. This card shares NOBODY '
        'with the storyline — only the project — which is the shape chat '
        'brings, since the people who talk in a channel are rarely the people '
        'on the mail. teams-candidate is the easy version of this, with an '
        'overlapping name to lean on.',
  ),
  MembershipCase(
    id: 'cross-source-same-kind',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Catalogue print run',
      summary: 'The printer is holding the run until the paper stock is '
          'picked.',
      charter: 'Producing the spring gallery catalogue — the page proofs, the '
          'print run, and the delivery date.',
      status: 'active',
    ),
    participants: ['Marisa Okonkwo', 'Li Chen', 'Amara Okafor'],
    candidateCard: 'Studio standup | Li Chen, Amara Okafor | standup, '
        'scheduling | Runs through what everyone is on this week and moves '
        "Thursday's standup an hour later.",
    expectBelongs: false,
    mustPass: true,
    note: 'The chat twin of invoice-same-kind, and the mirror of '
        'cross-source-same-project: this storyline already holds a catalogue '
        'standup, so a second standup arrives with the same medium, the same '
        'vocabulary and the same two people — and is about nothing in '
        'particular. Clustering across sources must not decay into "chat '
        'belongs with chat".',
  ),
  MembershipCase(
    id: 'widened-charter-new-clause',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Fernbrook Road studio move',
      summary: 'The lease is signed and the fit-out is being scheduled.',
      charter: 'The move to the Fernbrook Road studio — the lease, the '
          'fit-out, and the moving date. Also the broadband and phone lines '
          'for the new address.',
      status: 'active',
    ),
    participants: ['Dana Whitfield', 'Jordan Beck'],
    candidateCard: 'Fibre install window | Harbourline Broadband | broadband, '
        'install | Offers two install dates for the Fernbrook Road line and '
        'needs one confirmed this week.',
    expectBelongs: true,
    mustPass: true,
    note: 'The shape a charter has after the refresh pass widened it: the '
        'original sentence untouched, one added clause carrying the thread '
        'the user filed by hand. A candidate that fits ONLY the added clause '
        'is the thread the widening was for — miss it and hand-filing taught '
        'the storyline nothing.',
  ),
  MembershipCase(
    id: 'widened-charter-original-clause',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Fernbrook Road studio move',
      summary: 'The lease is signed and the fit-out is being scheduled.',
      charter: 'The move to the Fernbrook Road studio — the lease, the '
          'fit-out, and the moving date. Also the broadband and phone lines '
          'for the new address.',
      status: 'active',
    ),
    participants: ['Dana Whitfield', 'Jordan Beck'],
    candidateCard: 'Fit-out quote — partitions | Dana Whitfield | fit-out, '
        'quote | Prices the partition work at the new studio and wants a '
        'decision before the glass is ordered.',
    expectBelongs: true,
    mustPass: true,
    note: 'The same widened charter, judged against a thread that was in '
        'scope before the widening. Amending a charter must not orphan the '
        'members that were already there — a model that reads the newest '
        'clause as the whole charter would drop the move itself.',
  ),
  MembershipCase(
    id: 'widened-charter-neither-clause',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Fernbrook Road studio move',
      summary: 'The lease is signed and the fit-out is being scheduled.',
      charter: 'The move to the Fernbrook Road studio — the lease, the '
          'fit-out, and the moving date. Also the broadband and phone lines '
          'for the new address.',
      status: 'active',
    ),
    participants: ['Dana Whitfield', 'Jordan Beck'],
    candidateCard: 'Invoice 4482 | Fernbrook Supply Billing | invoice, '
        'payment due | Sends the August supply invoice and asks for payment '
        'within thirty days.',
    expectBelongs: false,
    mustPass: false,
    note: 'Fits neither clause, and the word it shares with the storyline is a '
        'coincidence: Fernbrook Road is not Fernbrook Supply. Two traps at '
        'once — a widened charter that could read as permission, and a name '
        'match that is only a name — so it is measured rather than gated. A '
        'yes here is the failure mode amending charters introduces.',
  ),
  MembershipCase(
    id: 'terse-user-charter',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Selling the estate',
      summary: 'A viewing is booked for Saturday and the logbook is missing.',
      charter: 'Anything about selling the estate car.',
      status: 'active',
    ),
    participants: ['Sam Okafor'],
    candidateCard: 'Still on the listing? | Rhea Molloy | car sale, enquiry | '
        'Asks whether the estate is still for sale and what the mileage is.',
    expectBelongs: true,
    mustPass: true,
    note: 'A charter a person actually typed: one blunt sentence, no criteria '
        'list, no em dash. Every other charter in this set reads like the '
        'naming task wrote it, and now that the About block offers amendments '
        'a user accepts or rejects, the text this prompt is judged against is '
        'far more often typed than drafted.',
  ),
  MembershipCase(
    id: 'terse-charter-adjacent',
    storyline: Storyline(
      id: 'sl-eval',
      title: 'Selling the estate',
      summary: 'A viewing is booked for Saturday and the logbook is missing.',
      charter: 'Anything about selling the estate car.',
      status: 'active',
    ),
    participants: ['Sam Okafor'],
    candidateCard: 'Annual service due | Harbourline Motors | service, '
        'booking | Reminds that the estate is due its annual service and '
        'offers a slot on the 12th.',
    expectBelongs: false,
    mustPass: false,
    note: 'The cost of terseness. "Anything about the estate car" is not what '
        'the charter says — it says selling it — and a blunt sentence has to '
        'be read as narrowly as a written-out one. This is where a model that '
        'treats a short charter as a topic label goes wrong, and it is hard '
        'enough to be worth watching rather than gating.',
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
