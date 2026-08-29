import '../models/message_models.dart';

/// Hardcoded inbox used until the Graph sync lands. Everything here is
/// invented — no real borrower, address, or loan number appears.
///
/// The set is chosen to exercise the UI rather than to look tidy: every
/// [ConversationState] and every [CtaUrgency] is represented, one body runs
/// past the bubble's 600-character collapse threshold, and one carries the
/// literal `[cid:…]` token that Graph's HTML→text conversion leaves behind.

/// ISO timestamp [d] before now — fixtures stay "within the last week"
/// however long after they were written the app runs.
String _ago(Duration d) =>
    DateTime.now().toUtc().subtract(d).toIso8601String();

final String _t2h = _ago(const Duration(hours: 2));
final String _t5h = _ago(const Duration(hours: 5));
final String _t20h = _ago(const Duration(hours: 20));
final String _t1d = _ago(const Duration(days: 1, hours: 3));
final String _t2d = _ago(const Duration(days: 2, hours: 1));
final String _t3d = _ago(const Duration(days: 3, hours: 4));
final String _t4d = _ago(const Duration(days: 4, hours: 2));
final String _t5d = _ago(const Duration(days: 5, hours: 6));
final String _t6d = _ago(const Duration(days: 6, hours: 1));

final List<Conversation> fixtureConversations = [
  Conversation(
    id: 'conv-alder-cd',
    subject: 'Closing Disclosure — 412 Alder Court',
    participants: const [
      Participant(name: 'Sarah Whitfield', email: 'swhitfield@harborline.com'),
      Participant(name: 'Marcus Reed', email: 'marcus.reed@example.com'),
    ],
    category: 'closing',
    state: ConversationState.needsReply,
    ctaText: 'Return signed CD to Sarah before Thursday EOD',
    ctaUrgency: CtaUrgency.urgent,
    messageCount: 3,
    inboundCount: 2,
    lastInboundAt: _t2h,
    lastOutboundAt: _t20h,
    lastMessageAt: _t2h,
    lastMessagePreview:
        'The three-day window starts the moment you acknowledge receipt, so '
        'we need the signed copy back Thursday.',
  ),
  Conversation(
    id: 'conv-windham-lock',
    subject: 'Rate lock expires Friday — 8829 Windham Way',
    participants: const [
      Participant(name: 'Priya Raghavan', email: 'praghavan@example.com'),
    ],
    category: 'rate_lock',
    state: ConversationState.needsReply,
    ctaText: 'Confirm whether Priya wants to extend the lock or float',
    ctaUrgency: CtaUrgency.high,
    messageCount: 4,
    inboundCount: 2,
    lastInboundAt: _t5h,
    lastOutboundAt: _t1d,
    lastMessageAt: _t5h,
    lastMessagePreview:
        'If the extension is only a quarter point I would rather lock it in '
        'than gamble on next week.',
  ),
  Conversation(
    id: 'conv-nguyen-docs',
    subject: 'Missing paystubs — Nguyen refinance',
    participants: const [
      Participant(name: 'Daniel Nguyen', email: 'dnguyen@example.com'),
    ],
    category: 'documents',
    state: ConversationState.needsReply,
    ctaText: 'Send Daniel the secure upload link for the two missing paystubs',
    ctaUrgency: CtaUrgency.normal,
    messageCount: 2,
    inboundCount: 1,
    lastInboundAt: _t20h,
    lastOutboundAt: _t2d,
    lastMessageAt: _t20h,
    lastMessagePreview:
        'I tried the portal twice last night and it kept timing out on the '
        'second upload.',
  ),
  Conversation(
    id: 'conv-harbor-appraisal',
    subject: 'Appraisal scheduled — 55 Harbor Point Rd',
    participants: const [
      Participant(name: 'Kendra Osei', email: 'kosei@meridianappraisal.com'),
    ],
    category: 'appraisal',
    state: ConversationState.waiting,
    ctaUrgency: CtaUrgency.normal,
    messageCount: 3,
    inboundCount: 2,
    lastInboundAt: _t1d,
    lastOutboundAt: _t2d,
    lastMessageAt: _t1d,
    lastMessagePreview:
        'Inspector is booked for Tuesday at 9. Report turnaround is running '
        'about four business days right now.',
  ),
  Conversation(
    id: 'conv-delgado-uw',
    subject: 'Conditional approval issued — Delgado file',
    participants: const [
      Participant(name: 'Ruth Alvarado', email: 'ralvarado@harborline.com'),
    ],
    category: 'underwriting',
    state: ConversationState.waiting,
    ctaUrgency: CtaUrgency.low,
    messageCount: 2,
    inboundCount: 1,
    lastInboundAt: _t2d,
    lastOutboundAt: _t3d,
    lastMessageAt: _t2d,
    lastMessagePreview:
        'Underwriting signed off with six conditions. Full list below — none '
        'of them are blockers.',
  ),
  Conversation(
    id: 'conv-bellweather-title',
    subject: 'Title commitment received — Bellweather',
    participants: const [
      Participant(name: 'Tomas Lindqvist', email: 'tlindqvist@bellwethertitle.com'),
    ],
    category: 'title',
    state: ConversationState.waiting,
    ctaUrgency: CtaUrgency.normal,
    messageCount: 2,
    inboundCount: 1,
    lastInboundAt: _t4d,
    lastOutboundAt: _t5d,
    lastMessageAt: _t4d,
    lastMessagePreview:
        'Commitment is clean apart from an old mechanic lien that was '
        'released in 2019 — we have the release on file.',
  ),
  Conversation(
    id: 'conv-okafor-preapproval',
    subject: 'Pre-approval letter — Okafor',
    participants: const [
      Participant(name: 'Adaeze Okafor', email: 'aokafor@example.com'),
    ],
    category: 'pre_approval',
    state: ConversationState.done,
    ctaUrgency: CtaUrgency.low,
    messageCount: 3,
    inboundCount: 2,
    lastInboundAt: _t5d,
    lastOutboundAt: _t5d,
    lastMessageAt: _t5d,
    lastMessagePreview: 'Got it, thank you — forwarding to our agent now.',
  ),
  Conversation(
    id: 'conv-sycamore-funded',
    subject: 'Wire confirmation — 1204 Sycamore',
    participants: const [
      Participant(name: 'Gail Prentice', email: 'gprentice@harborline.com'),
    ],
    category: 'funding',
    state: ConversationState.done,
    ctaUrgency: CtaUrgency.normal,
    messageCount: 2,
    inboundCount: 1,
    lastInboundAt: _t6d,
    lastOutboundAt: _t6d,
    lastMessageAt: _t6d,
    lastMessagePreview: 'Funds landed at 10:42 this morning. File is closed.',
  ),
];

final Map<String, List<Message>> fixtureThreads = {
  'conv-alder-cd': [
    Message(
      id: 'msg-alder-1',
      outbound: false,
      fromName: 'Sarah Whitfield',
      fromAddress: 'swhitfield@harborline.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t1d,
      subject: 'Closing Disclosure — 412 Alder Court',
      bodyText:
          'Hi — the CD for 412 Alder Court is out for signature. Marcus is '
          'copied.\n\nClosing is set for the 14th, so the three-day window is '
          'tight. Let me know once he has acknowledged it.\n\nSarah',
      triageStatus: 'done',
      urgency: 'high',
      category: 'closing',
      summary: 'CD issued for 412 Alder Court; signature needed before the 14th.',
      needsAction: true,
      actionItems: const ['Get the CD acknowledged', 'Confirm closing date'],
    ),
    Message(
      id: 'msg-alder-2',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['swhitfield@harborline.com'],
      receivedAt: _t20h,
      subject: 'RE: Closing Disclosure — 412 Alder Court',
      bodyText:
          'Thanks Sarah. I walked Marcus through it this afternoon and he is '
          'signing tonight. I will confirm as soon as the acknowledgement '
          'comes through.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-alder-3',
      outbound: false,
      fromName: 'Sarah Whitfield',
      fromAddress: 'swhitfield@harborline.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t2h,
      subject: 'RE: Closing Disclosure — 412 Alder Court',
      bodyText:
          'The three-day window starts the moment you acknowledge receipt, so '
          'we need the signed copy back Thursday. Anything later and we are '
          'rescheduling the table.\n\nSarah Whitfield\nClosing Coordinator, '
          'Harborline Lending\n[cid:image001.png]\n(503) 555-0148',
      triageStatus: 'done',
      urgency: 'urgent',
      category: 'closing',
      summary: 'Signed CD must be back by Thursday or closing reschedules.',
      needsAction: true,
      actionItems: const ['Return signed CD by Thursday EOD'],
    ),
  ],
  'conv-windham-lock': [
    Message(
      id: 'msg-windham-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['praghavan@example.com'],
      receivedAt: _t3d,
      subject: 'Rate lock expires Friday — 8829 Windham Way',
      bodyText:
          'Priya — your lock on 8829 Windham Way runs out Friday at close of '
          'business. We can extend fifteen days for a fee, or let it float and '
          'relock at whatever the market gives us Monday.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-windham-2',
      outbound: false,
      fromName: 'Priya Raghavan',
      fromAddress: 'praghavan@example.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t2d,
      subject: 'RE: Rate lock expires Friday — 8829 Windham Way',
      bodyText: 'What does the extension actually cost?',
      triageStatus: 'done',
      urgency: 'normal',
      category: 'rate_lock',
      summary: 'Borrower asking for the cost of a lock extension.',
      needsAction: true,
      actionItems: const ['Quote the 15-day extension fee'],
    ),
    Message(
      id: 'msg-windham-3',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['praghavan@example.com'],
      receivedAt: _t1d,
      subject: 'RE: Rate lock expires Friday — 8829 Windham Way',
      bodyText:
          'Fifteen days runs 0.25 points, so about \$1,100 on your loan '
          'amount. Floating costs nothing up front but you are exposed to '
          'Monday\'s pricing.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-windham-4',
      outbound: false,
      fromName: 'Priya Raghavan',
      fromAddress: 'praghavan@example.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t5h,
      subject: 'RE: Rate lock expires Friday — 8829 Windham Way',
      bodyText:
          'If the extension is only a quarter point I would rather lock it in '
          'than gamble on next week. Can you start that today?',
      triageStatus: 'done',
      urgency: 'high',
      category: 'rate_lock',
      summary: 'Borrower wants the 15-day extension started today.',
      needsAction: true,
      actionItems: const ['Submit the lock extension'],
    ),
  ],
  'conv-nguyen-docs': [
    Message(
      id: 'msg-nguyen-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['dnguyen@example.com'],
      receivedAt: _t2d,
      subject: 'Missing paystubs — Nguyen refinance',
      bodyText:
          'Daniel — processing flagged two paystubs missing from the packet: '
          'the ones covering the last two pay periods. Portal link is the same '
          'one you used for the bank statements.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-nguyen-2',
      outbound: false,
      fromName: 'Daniel Nguyen',
      fromAddress: 'dnguyen@example.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t20h,
      subject: 'RE: Missing paystubs — Nguyen refinance',
      bodyText:
          'I tried the portal twice last night and it kept timing out on the '
          'second upload. Is there another way to get these to you? I have '
          'them as PDFs already.',
      triageStatus: 'done',
      urgency: 'normal',
      category: 'documents',
      summary: 'Borrower blocked by portal timeouts; needs another upload path.',
      needsAction: true,
      actionItems: const ['Send a fresh secure upload link'],
    ),
  ],
  'conv-harbor-appraisal': [
    Message(
      id: 'msg-harbor-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['kosei@meridianappraisal.com'],
      receivedAt: _t3d,
      subject: 'Appraisal order — 55 Harbor Point Rd',
      bodyText:
          'Kendra — ordering the appraisal on 55 Harbor Point Rd. Access is '
          'through the listing agent; contact details are in the order.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-harbor-2',
      outbound: false,
      fromName: 'Kendra Osei',
      fromAddress: 'kosei@meridianappraisal.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t2d,
      subject: 'RE: Appraisal order — 55 Harbor Point Rd',
      bodyText: 'Received. Reaching out to the agent for access today.',
      triageStatus: 'done',
      urgency: 'low',
      category: 'appraisal',
      summary: 'Appraiser acknowledged the order.',
      needsAction: false,
    ),
    Message(
      id: 'msg-harbor-3',
      outbound: false,
      fromName: 'Kendra Osei',
      fromAddress: 'kosei@meridianappraisal.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t1d,
      subject: 'RE: Appraisal order — 55 Harbor Point Rd',
      bodyText:
          'Inspector is booked for Tuesday at 9. Report turnaround is running '
          'about four business days right now, so plan on the following '
          'Monday for the finished report.',
      triageStatus: 'done',
      urgency: 'low',
      category: 'appraisal',
      summary: 'Inspection Tuesday 9am; report expected the following Monday.',
      needsAction: false,
    ),
  ],
  'conv-delgado-uw': [
    Message(
      id: 'msg-delgado-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['ralvarado@harborline.com'],
      receivedAt: _t3d,
      subject: 'Delgado file — status?',
      bodyText: 'Ruth, any read on where the Delgado file landed in UW?',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-delgado-2',
      outbound: false,
      fromName: 'Ruth Alvarado',
      fromAddress: 'ralvarado@harborline.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t2d,
      subject: 'RE: Delgado file — status?',
      bodyText:
          'Underwriting signed off with six conditions. Full list below — none '
          'of them are blockers, and four are things the borrower already sent '
          'once through the old portal.\n\n'
          '1. Most recent two months of statements for the joint checking '
          'account ending 4417, all pages including the intentionally blank '
          'ones.\n'
          '2. Written explanation for the \$6,200 deposit on the 12th. If it '
          'is the vehicle sale we discussed, the bill of sale plus the title '
          'transfer covers it.\n'
          '3. Verification of employment for the borrower, dated within ten '
          'days of closing. Processing normally pulls this themselves but the '
          'employer would not take the automated request.\n'
          '4. Homeowners policy showing twelve months prepaid, with the '
          'lender clause naming us exactly as it appears on the commitment.\n'
          '5. Signed 4506-C. The one in the file predates the address change '
          'and underwriting will not accept it.\n'
          '6. Evidence the old HELOC on the departing residence is closed, '
          'not merely paid to zero.\n\n'
          'I would chase 2 and 6 first — those are the two that actually take '
          'a third party to produce. Everything else is a same-day ask.\n\n'
          'Ruth',
      triageStatus: 'done',
      urgency: 'normal',
      category: 'underwriting',
      summary:
          'Conditional approval with six conditions; deposit LOX and HELOC '
          'closure are the long poles.',
      needsAction: true,
      actionItems: const [
        'Request the \$6,200 deposit explanation',
        'Get evidence the HELOC is closed',
      ],
    ),
  ],
  'conv-bellweather-title': [
    Message(
      id: 'msg-bellweather-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['tlindqvist@bellwethertitle.com'],
      receivedAt: _t5d,
      subject: 'Title order — Bellweather',
      bodyText: 'Tomas — opening title on this one. Commitment when you have it.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-bellweather-2',
      outbound: false,
      fromName: 'Tomas Lindqvist',
      fromAddress: 'tlindqvist@bellwethertitle.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t4d,
      subject: 'RE: Title order — Bellweather',
      bodyText:
          'Commitment is clean apart from an old mechanic lien that was '
          'released in 2019 — we have the release on file and it will not '
          'show on the final policy.',
      triageStatus: 'done',
      urgency: 'low',
      category: 'title',
      summary: 'Title commitment clean; released 2019 lien is documented.',
      needsAction: false,
    ),
  ],
  'conv-okafor-preapproval': [
    Message(
      id: 'msg-okafor-1',
      outbound: false,
      fromName: 'Adaeze Okafor',
      fromAddress: 'aokafor@example.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t6d,
      subject: 'Pre-approval letter',
      bodyText:
          'Our agent needs the pre-approval letter before we can put in an '
          'offer this weekend. Can you send it over?',
      triageStatus: 'done',
      urgency: 'high',
      category: 'pre_approval',
      summary: 'Borrower needs the pre-approval letter for a weekend offer.',
      needsAction: true,
      actionItems: const ['Issue the pre-approval letter'],
    ),
    Message(
      id: 'msg-okafor-2',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['aokafor@example.com'],
      receivedAt: _t5d,
      subject: 'RE: Pre-approval letter',
      bodyText:
          'Attached — good through the end of next month at the amount we '
          'discussed. Shout if the agent needs it reissued at a different '
          'number.',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-okafor-3',
      outbound: false,
      fromName: 'Adaeze Okafor',
      fromAddress: 'aokafor@example.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t5d,
      subject: 'RE: Pre-approval letter',
      bodyText: 'Got it, thank you — forwarding to our agent now.',
      triageStatus: 'done',
      urgency: 'low',
      category: 'pre_approval',
      summary: 'Borrower confirmed receipt.',
      needsAction: false,
    ),
  ],
  'conv-sycamore-funded': [
    Message(
      id: 'msg-sycamore-1',
      outbound: true,
      fromName: 'You',
      fromAddress: 'lo@harborline.com',
      to: const ['gprentice@harborline.com'],
      receivedAt: _t6d,
      subject: 'Wire status — 1204 Sycamore',
      bodyText: 'Gail — has the wire gone out on 1204 Sycamore?',
      triageStatus: 'skipped',
      gateReason: 'outbound',
    ),
    Message(
      id: 'msg-sycamore-2',
      outbound: false,
      fromName: 'Gail Prentice',
      fromAddress: 'gprentice@harborline.com',
      to: const ['lo@harborline.com'],
      receivedAt: _t6d,
      subject: 'RE: Wire status — 1204 Sycamore',
      bodyText: 'Funds landed at 10:42 this morning. File is closed.',
      triageStatus: 'done',
      urgency: 'low',
      category: 'funding',
      summary: 'Wire funded; file closed.',
      needsAction: false,
    ),
  ],
};
