import 'package:bond_inbox/models/message_models.dart';

import 'corpus.dart' show userAddress;

/// The messages the needs-you judgement is hard on, written down once.
///
/// Chosen for the shape of the mistake each one invites rather than for
/// volume: a group mail that names the owner halfway down, a one-to-one chat
/// that wants nothing, an ask that was already answered. The deterministic
/// floor settles two of them and reads the rest as silence, which is exactly
/// the residue the model is asked about.
///
/// **Offline tests assert only WELL-FORMEDNESS of this set** — unique ids,
/// both verdicts present, every name and address fictional, [floorSaysYes]
/// agreeing with `needsYouFloor`. Accuracy is a live-bench question: whether a
/// small model gets `mention-in-body` right is a fact about the model, and an
/// offline test pinning it would fail on the next model swap for no defect.
///
/// Entirely fictional, and deliberately so: this repo is public. The inbox
/// belongs to Alex Rivera, who runs a small design practice; every mail
/// address is an `example.com` subdomain and every chat sender is a display
/// name over a `teams:` handle.
class NeedsYouCase {
  /// Stable slug, so a failure names the case it came from.
  final String id;

  /// The message being judged.
  final Message message;

  /// What came before it on the thread, oldest first. Never contains
  /// [message].
  final List<Message> thread;

  /// The owner's own criteria, where the case is about them.
  final String? userRules;

  /// What a good model should answer.
  final bool expectNeedsYou;

  /// Whether `needsYouFloor` already settles this one. Where it does, the
  /// model is never asked — which is a design fact worth having written down
  /// beside the cases where the floor and a good answer disagree.
  final bool floorSaysYes;

  /// Gating flag for the live bench. Offline tests never read it: it says
  /// which cases a model must get right to be shippable, not which ones this
  /// file is allowed to contain.
  final bool mustPass;

  /// Why this case is here, in one sentence.
  final String note;

  const NeedsYouCase({
    required this.id,
    required this.message,
    this.thread = const [],
    this.userRules,
    required this.expectNeedsYou,
    required this.floorSaysYes,
    required this.mustPass,
    required this.note,
  });
}

Message _mail({
  required String id,
  required String from,
  required String address,
  required String subject,
  required String body,
  List<String> to = const [userAddress],
  bool addressedMe = false,
  String receivedAt = '2026-09-01T09:00:00Z',
}) =>
    Message(
      id: id,
      outbound: false,
      fromName: from,
      fromAddress: address,
      subject: subject,
      bodyText: body,
      receivedAt: receivedAt,
      to: to,
      addressedMe: addressedMe,
    );

Message _chat({
  required String id,
  required String from,
  required String handle,
  required String body,
  bool addressedMe = false,
  String receivedAt = '2026-09-01T09:00:00Z',
}) =>
    Message(
      id: id,
      source: 'teams',
      outbound: false,
      fromName: from,
      fromAddress: 'teams:$handle',
      bodyText: body,
      receivedAt: receivedAt,
      addressedMe: addressedMe,
    );

Message _sent({
  required String id,
  required String body,
  String receivedAt = '2026-08-31T09:00:00Z',
}) =>
    Message(id: id, outbound: true, bodyText: body, receivedAt: receivedAt);

const List<String> _projectTeam = [
  userAddress,
  'priya.natarajan@northwind.example.com',
  'sam.okonkwo@northwind.example.com',
];

final List<NeedsYouCase> needsYouCases = [
  NeedsYouCase(
    id: 'mention-in-body',
    message: _mail(
      id: 'ny-mention',
      from: 'Priya Natarajan',
      address: 'priya.natarajan@northwind.example.com',
      subject: 'Riverside signage — final proofs',
      body: 'Proofs are attached for everyone to look over.\n\n'
          'Alex, can you sign off on the wayfinding sheet before Friday? '
          'The printer holds our slot until then.\n\n'
          'Sam, nothing needed from you on this one.',
      to: _projectTeam,
    ),
    expectNeedsYou: true,
    floorSaysYes: false,
    mustPass: true,
    note: 'A group mail that names the owner and asks them for a sign-off. '
        'The envelope says group; the body says Alex.',
  ),
  NeedsYouCase(
    id: 'group-chat-at-mention',
    message: _chat(
      id: 'ny-at-mention',
      from: 'Sam Okonkwo',
      handle: 'sam-okonkwo',
      body: '@Alex Rivera which of the two type treatments are we going with? '
          'I can start the production files as soon as you call it.',
      addressedMe: true,
    ),
    expectNeedsYou: true,
    floorSaysYes: true,
    mustPass: true,
    note: 'An @mention in a group chat. The floor already writes the yes, so '
        'the model is never asked — the case is here because a change that '
        'lowered the floor would have to answer for it.',
  ),
  NeedsYouCase(
    id: 'one-to-one-fyi',
    message: _chat(
      id: 'ny-1to1-fyi',
      from: 'Sam Okonkwo',
      handle: 'sam-okonkwo',
      body: 'fyi the staging deploy went out fine, nothing needed from you',
      addressedMe: true,
    ),
    expectNeedsYou: false,
    floorSaysYes: true,
    mustPass: false,
    note: 'The tension, written down: a 1:1 chat that wants nothing. The floor '
        'says yes and the floor wins, because it runs first and the model is '
        'never asked. Not a mustPass — the model is not wrong here, it is '
        'overruled.',
  ),
  NeedsYouCase(
    id: 'sole-recipient-fyi',
    message: _mail(
      id: 'ny-sole-fyi',
      from: 'Dana Whitfield',
      address: 'dana.whitfield@northwind.example.com',
      subject: 'Studio notes for the week',
      body: 'Passing on the week in one place so nobody has to chase it.\n\n'
          'The Riverside install slipped a day, the new laser cutter is in, '
          'and the storage unit lease renews itself in October.\n\n'
          'Nothing to do with any of it — just so you have seen it.',
      addressedMe: true,
    ),
    expectNeedsYou: false,
    floorSaysYes: false,
    mustPass: true,
    note: 'Sent to the owner and nobody else, and asks for nothing. The case '
        'that stops "sole recipient" being read as a verdict.',
  ),
  NeedsYouCase(
    id: 'sole-recipient-buried-ask',
    message: _mail(
      id: 'ny-buried-ask',
      from: 'Dana Whitfield',
      address: 'dana.whitfield@northwind.example.com',
      subject: 'Riverside — where things stand',
      body: 'Long one, sorry.\n\n'
          'The fabricator finished the brackets and they look right. '
          'Permitting came back clean. The install crew is booked for the '
          'week of the 14th and the lift is reserved.\n\n'
          'One thing I cannot move without you: the budget line for the '
          'second lift needs your approval, or we do the upper panels by '
          'ladder and lose a day.\n\n'
          'Otherwise everything is on rails.',
      addressedMe: true,
    ),
    expectNeedsYou: true,
    floorSaysYes: false,
    mustPass: true,
    note: 'The ask is one paragraph inside a status update. A model that '
        'reads the first line and stops gets this wrong.',
  ),
  NeedsYouCase(
    id: 'newsletter',
    message: _mail(
      id: 'ny-newsletter',
      from: 'Type & Grid Weekly',
      address: 'letters@typeandgrid.example.com',
      subject: 'Issue 212: the return of the sans',
      body: 'This week: three studios on why they went back to a grotesque, '
          'a foundry interview, and the reader letters.\n\n'
          'Read the issue. Forward it to a friend. '
          'Unsubscribe at any time from the link below.',
      addressedMe: true,
    ),
    expectNeedsYou: false,
    floorSaysYes: false,
    mustPass: true,
    note: 'A bulk newsletter that happens to arrive on a sole-recipient '
        'envelope, which is how every newsletter arrives.',
  ),
  NeedsYouCase(
    id: 'automated-notice',
    message: _mail(
      id: 'ny-automated',
      from: 'Build Robot',
      address: 'no-reply@builds.northwind.example.com',
      subject: '[riverside-site] Build #4821 succeeded',
      body: 'Branch main, commit 9f2ac41, 4 minutes 12 seconds.\n\n'
          'All 118 checks passed. Artifacts are retained for 30 days.\n\n'
          'This message was generated automatically. Do not reply.',
      addressedMe: true,
    ),
    expectNeedsYou: false,
    floorSaysYes: false,
    mustPass: true,
    note: 'A machine telling the owner something went fine. Nothing to read '
        'and nothing to do.',
  ),
  NeedsYouCase(
    id: 'boss-delegation',
    message: _mail(
      id: 'ny-delegation',
      from: 'Marguerite Okafor',
      address: 'marguerite.okafor@northwind.example.com',
      subject: 'Who is taking the Harbour brief',
      body: 'We said we would answer Harbour by the end of the month and '
          'nobody has picked it up.\n\n'
          'Alex is taking this one. Alex — put the brief together and send it '
          'to them directly; loop me in when it goes.',
      to: _projectTeam,
    ),
    expectNeedsYou: true,
    floorSaysYes: false,
    mustPass: true,
    note: 'A task handed to the owner by name in front of the group. No '
        'question mark anywhere in it.',
  ),
  NeedsYouCase(
    id: 'bystander-thread',
    message: _mail(
      id: 'ny-bystander',
      from: 'Sam Okonkwo',
      address: 'sam.okonkwo@northwind.example.com',
      subject: 'Re: Colour proofs for Harbour',
      body: 'Priya — I will re-run the proofs tonight with the warmer stock '
          'and send them over in the morning. Can you have the press check '
          'booked for Thursday?',
      to: _projectTeam,
    ),
    thread: [
      _mail(
        id: 'ny-bystander-0',
        from: 'Priya Natarajan',
        address: 'priya.natarajan@northwind.example.com',
        subject: 'Colour proofs for Harbour',
        body: 'The proofs came back cold. Sam, can you re-run them on the '
            'warmer stock?',
        to: _projectTeam,
        receivedAt: '2026-08-31T16:00:00Z',
      ),
    ],
    expectNeedsYou: false,
    floorSaysYes: false,
    mustPass: true,
    note: 'Two other people arranging work between themselves on a thread the '
        'owner is copied on. Plenty of asks, none of them theirs.',
  ),
  NeedsYouCase(
    id: 'already-resolved',
    message: _mail(
      id: 'ny-resolved',
      from: 'Dana Whitfield',
      address: 'dana.whitfield@northwind.example.com',
      subject: 'Re: Storage unit access code',
      body: 'Got it, thanks — that worked. Nothing else needed.',
      addressedMe: true,
    ),
    thread: [
      _mail(
        id: 'ny-resolved-0',
        from: 'Dana Whitfield',
        address: 'dana.whitfield@northwind.example.com',
        subject: 'Storage unit access code',
        body: 'What is the gate code for the storage unit? I am outside it.',
        addressedMe: true,
        receivedAt: '2026-08-31T14:00:00Z',
      ),
      _sent(
        id: 'ny-resolved-1',
        body: 'It is 4417, then the green button.',
        receivedAt: '2026-08-31T14:06:00Z',
      ),
    ],
    expectNeedsYou: false,
    floorSaysYes: false,
    mustPass: true,
    note: 'The ask was made, the owner answered it, and this message closes '
        'it. A model reading only the last message sees a sole-recipient '
        'note from a colleague.',
  ),
  NeedsYouCase(
    id: 'user-rule-widens',
    message: _mail(
      id: 'ny-user-rule',
      from: 'Copperleaf Fabrication',
      address: 'billing@copperleaf.example.com',
      subject: 'Invoice 20418 — Riverside brackets',
      body: 'Invoice 20418 is attached, due in 30 days.\n\n'
          'Payment details are unchanged. No action is required if you have '
          'already paid.',
      addressedMe: true,
    ),
    userRules: 'Invoices and anything about money always need me, even when '
        'they say no action is required. I am the only one who pays them.',
    expectNeedsYou: true,
    floorSaysYes: false,
    mustPass: false,
    note: 'False under the default rules — an automated notice asking for '
        'nothing — and true under the owner\'s. The one case that exists to '
        'show the rules field changing an answer.',
  ),
];
