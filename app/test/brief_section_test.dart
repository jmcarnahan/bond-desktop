import 'dart:convert';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/widgets/brief_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The event panel's Brief section, prop-only: each state's sentence, the
/// brief itself, the thread and material chips, Regenerate, and the
/// agenda's compact face.
void main() {
  final now = DateTime.utc(2026, 9, 29, 16);

  EventBrief ready(
      {bool withThreads = true,
      bool withMaterials = true,
      List<BriefPoint> morePoints = const [],
      String path = MeetingBrief.pathPeople,
      List<BriefThreadRef>? threadRefs}) {
    final brief = MeetingBrief(
      headline: 'Dana is waiting on the quote.',
      briefing: const [
        'You owe Dana the renewal quote.',
        'The deck sets it at 12k.',
      ],
      people: const [
        BriefPersonOut(name: 'Dana', line: 'Fabrikam buyer; asked for the quote.'),
        BriefPersonOut(name: 'Lee', line: 'Signs for Fabrikam.'),
      ],
      points: [
        const BriefPoint(text: 'The quote is owed.', thread: 0),
        const BriefPoint(text: 'Nothing else is open.'),
        ...morePoints,
      ],
      openAsks: const [
        BriefAskOut(person: 'Dana', ask: 'Send the quote', thread: 0),
      ],
      materials: const [
        BriefMaterialOut(file: 0, points: [
          'The deck prices the renewal at 12k.',
          'Phase two starts in March.',
        ]),
        BriefMaterialOut(file: 1, points: ['The sheet lists three open items.']),
      ],
      questions: const [
        'Is 12k the final number?',
        'Who signs for Fabrikam?',
      ],
      prep: const ['Have the quote ready'],
      materialRefs: withMaterials
          ? const [
              BriefMaterialRef(
                source: 'email',
                messageId: 'm-1',
                attachmentId: 'a-1',
                name: 'Renewal deck.pptx',
              ),
            ]
          : const [],
      path: path,
      threads: threadRefs ??
          (withThreads
          ? const [
              BriefThreadRef(
                source: 'email',
                conversationKey: 'c-1',
                subject: 'Fabrikam renewal',
              ),
            ]
          : const []),
    );
    return EventBrief(
      eventId: 'evt-1',
      inputsHash: 'h',
      status: EventBrief.ready,
      briefJson: jsonEncode(brief.toJson()),
      generatedAt: calendarStamp(now.subtract(const Duration(hours: 2))),
    );
  }

  EventBrief row(String status, {String hash = 'h'}) => EventBrief(
        eventId: 'evt-1',
        inputsHash: hash,
        status: status,
        generatedAt: calendarStamp(now),
      );

  final opened = <(String, String)>[];
  final files = <BriefMaterialRef>[];
  var regenerated = 0;
  var written = 0;

  setUp(() {
    opened.clear();
    files.clear();
    regenerated = 0;
    written = 0;
  });

  Future<void> pump(WidgetTester tester, EventBriefView? view,
      {bool? eligible,
      String? reason,
      bool compact = false,
      bool canOpenFiles = true,
      bool canWrite = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BriefSection(
            view: view,
            eligible: eligible,
            ineligibleReason: reason,
            now: now,
            compact: compact,
            onOpenThread: (s, k) => opened.add((s, k)),
            onOpenMaterial: canOpenFiles ? files.add : null,
            onRegenerate: () => regenerated++,
            onWrite: canWrite ? () => written++ : null,
          ),
        ),
      ),
    ));
  }

  /// The top of a widget found by [key], for reading the section's order.
  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(BriefSection.statusKey)).data!;

  testWidgets('a ready brief: headline, points, asks, prep and the footer',
      (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    expect(tester.widget<Text>(find.byKey(BriefSection.headlineKey)).data,
        'Dana is waiting on the quote.');
    expect(find.text('• The quote is owed.'), findsOneWidget);
    expect(find.text('• Nothing else is open.'), findsOneWidget);
    expect(find.text('Dana: Send the quote'), findsOneWidget);
    expect(find.text('• Have the quote ready'), findsOneWidget);
    expect(status(tester), 'Generated 2h ago');
    expect(find.byKey(BriefSection.regenerateKey), findsOneWidget);
    // Only a point that names a thread carries a chip.
    expect(find.byKey(BriefSection.pointThreadKeyFor(0)), findsOneWidget);
    expect(find.byKey(BriefSection.pointThreadKeyFor(1)), findsNothing);
  });

  testWidgets('the catch-up order: briefing, materials, people, questions, '
      'prep, open asks, references', (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    for (final label in [
      'Briefing',
      'From the materials',
      'People',
      'Questions',
      'Prep',
      'Open asks',
      'References',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Materials'), findsNothing);
    expect(find.text('Renewal deck.pptx'), findsOneWidget);
    expect(find.text('1. Is 12k the final number?'), findsOneWidget);
    expect(find.text('2. Who signs for Fabrikam?'), findsOneWidget);

    final order = [
      find.byKey(BriefSection.headlineKey),
      find.text('Briefing'),
      find.byKey(BriefSection.briefingKey),
      find.text('From the materials'),
      find.byKey(BriefSection.materialPointKeyFor(0, 1)),
      find.byKey(BriefSection.materialPointKeyFor(1, 0)),
      find.text('People'),
      find.byKey(BriefSection.personKeyFor(1)),
      find.text('Questions'),
      find.byKey(BriefSection.questionKeyFor(1)),
      find.text('Prep'),
      find.text('Open asks'),
      find.byKey(BriefSection.askKeyFor(0)),
      find.text('References'),
      find.byKey(BriefSection.pointKeyFor(0)),
      find.byKey(BriefSection.statusKey),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(top(tester, order[i - 1]), lessThan(top(tester, order[i])),
          reason: '${order[i - 1]} before ${order[i]}');
    }

    // The compact face keeps the same order.
    await pump(tester, EventBriefView(brief: ready()), compact: true);
    final compactOrder = [
      'Briefing',
      'From the materials',
      'People',
      'Questions',
      'Prep',
      'Open asks',
      'References',
    ];
    for (var i = 1; i < compactOrder.length; i++) {
      expect(top(tester, find.text(compactOrder[i - 1])),
          lessThan(top(tester, find.text(compactOrder[i]))),
          reason: '${compactOrder[i - 1]} before ${compactOrder[i]}');
    }
  });

  testWidgets('the briefing is one paragraph of its sentences',
      (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    final briefing = find.byKey(BriefSection.briefingKey);
    expect(briefing, findsOneWidget);
    expect(tester.widget<SelectableText>(briefing).data,
        'You owe Dana the renewal quote. The deck sets it at 12k.');
    expect(find.text('You owe Dana the renewal quote.'), findsNothing,
        reason: 'one paragraph, not a line per sentence');

    // A sentence cut at its cap ends in an ellipsis rather than running
    // into the next; one with its own punctuation is left alone.
    await pump(
        tester,
        EventBriefView(
            brief: _readyRow(
                const MeetingBrief(headline: 'Glance.', briefing: [
                  'The deck sets the price at',
                  'You owe the quote!',
                  'Dana said "by Friday."',
                ]),
                now)));
    expect(
        tester.widget<SelectableText>(find.byKey(BriefSection.briefingKey))
            .data,
        'The deck sets the price at… You owe the quote! '
        'Dana said "by Friday."');

    // No sentences, no block.
    await pump(
        tester,
        EventBriefView(
            brief: _readyRow(const MeetingBrief(headline: 'Just the glance.'),
                now)));
    expect(find.text('Briefing'), findsNothing);
    expect(find.byKey(BriefSection.briefingKey), findsNothing);
  });

  testWidgets('a person is a name and a line', (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    final person = find.byKey(BriefSection.personKeyFor(0));
    expect(person, findsOneWidget);
    final rich = tester.widget<Text>(
        find.descendant(of: person, matching: find.byType(Text)));
    expect(rich.textSpan!.toPlainText(),
        'Dana — Fabrikam buyer; asked for the quote.');
    final name = (rich.textSpan! as TextSpan).children!.first as TextSpan;
    expect(name.text, 'Dana');
    expect(name.style!.fontWeight, FontWeight.w600);
    expect(find.byKey(BriefSection.personKeyFor(1)), findsOneWidget);
    expect(find.byKey(BriefSection.personKeyFor(2)), findsNothing);

    // No name: the line alone, no dangling dash.
    await pump(
        tester,
        EventBriefView(
            brief: _readyRow(
                const MeetingBrief(headline: 'Glance.', people: [
                  BriefPersonOut(name: ' ', line: 'Signs for Fabrikam.'),
                ]),
                now)));
    final nameless = tester.widget<Text>(find.descendant(
        of: find.byKey(BriefSection.personKeyFor(0)),
        matching: find.byType(Text)));
    expect(nameless.textSpan!.toPlainText(), 'Signs for Fabrikam.');
  });

  testWidgets('the compact face shows three references at most; the panel '
      'shows them all', (tester) async {
    final brief = ready(morePoints: const [
      BriefPoint(text: 'Third point.'),
      BriefPoint(text: 'Fourth point.'),
      BriefPoint(text: 'Fifth point.'),
    ]);
    expect(BriefSection.compactPointsCap, 3);

    await pump(tester, EventBriefView(brief: brief), compact: true);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(BriefSection.pointKeyFor(i)), findsOneWidget);
    }
    expect(find.byKey(BriefSection.pointKeyFor(3)), findsNothing);
    expect(find.text('• Fourth point.'), findsNothing);

    await pump(tester, EventBriefView(brief: brief));
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(BriefSection.pointKeyFor(i)), findsOneWidget);
    }
    expect(find.text('• Fifth point.'), findsOneWidget);
  });

  testWidgets('a material draws its points as bullets under its chip; a '
      'missing ref draws the points alone', (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    final chip = find.byKey(BriefSection.materialKeyFor(0));
    expect(chip, findsOneWidget);
    expect(
        find.ancestor(of: chip, matching: find.byType(Tooltip)).evaluate()
            .map((e) => (e.widget as Tooltip).message),
        contains('Open the file'));
    await tester.tap(chip);
    expect(files, hasLength(1));
    expect(files.single.messageId, 'm-1');
    expect(files.single.attachmentId, 'a-1');

    // The chip, then its points as bullets, in order.
    expect(find.text('• The deck prices the renewal at 12k.'), findsOneWidget);
    expect(find.text('• Phase two starts in March.'), findsOneWidget);
    expect(top(tester, chip),
        lessThan(top(tester, find.byKey(BriefSection.materialPointKeyFor(0, 0)))));
    expect(top(tester, find.byKey(BriefSection.materialPointKeyFor(0, 0))),
        lessThan(top(tester, find.byKey(BriefSection.materialPointKeyFor(0, 1)))));
    expect(find.byKey(BriefSection.materialPointKeyFor(0, 2)), findsNothing);

    // The second material points at index 1, which the brief does not hold.
    expect(find.byKey(BriefSection.materialKeyFor(1)), findsNothing);
    expect(find.byKey(BriefSection.materialPointKeyFor(1, 0)), findsOneWidget);
    expect(find.text('• The sheet lists three open items.'), findsOneWidget);
    expect(find.text('(no name)'), findsNothing,
        reason: 'a missing ref draws no chip at all');

    // No ref at all: every point, no chip.
    await pump(tester, EventBriefView(brief: ready(withMaterials: false)));
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsNothing);
    expect(find.text('• The deck prices the renewal at 12k.'), findsOneWidget);
    expect(find.byKey(BriefSection.materialPointKeyFor(0, 1)), findsOneWidget);

    // No opener: the name is plain text, not a chip.
    await pump(tester, EventBriefView(brief: ready()), canOpenFiles: false);
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsNothing);
    expect(find.text('Renewal deck.pptx'), findsOneWidget);
  });

  testWidgets('compact draws the briefing, materials, people, questions, '
      'prep, asks and points — no heading, no footer, no status',
      (tester) async {
    await pump(tester, EventBriefView(brief: ready()), compact: true);

    expect(find.byKey(BriefSection.headlineKey), findsNothing,
        reason: 'the row\'s glance is the headline');
    expect(find.text('Dana is waiting on the quote.'), findsNothing);
    expect(find.byKey(BriefSection.statusKey), findsNothing);
    expect(find.textContaining('Generated'), findsNothing);
    expect(find.text('Brief'), findsNothing);
    expect(find.text('• The quote is owed.'), findsOneWidget);
    expect(find.byKey(BriefSection.briefingKey), findsOneWidget);
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsOneWidget);
    expect(find.byKey(BriefSection.personKeyFor(0)), findsOneWidget);
    expect(find.text('1. Is 12k the final number?'), findsOneWidget);
    expect(find.text('Dana: Send the quote'), findsOneWidget);
    expect(find.text('• Have the quote ready'), findsOneWidget);

    await tester.tap(find.byKey(BriefSection.pointThreadKeyFor(0)));
    expect(opened, [('email', 'c-1')]);
    await tester.tap(find.byKey(BriefSection.regenerateKey));
    expect(regenerated, 1);
  });

  testWidgets('compact says Rewriting… while a rewrite is queued, and offers '
      'no second press', (tester) async {
    await pump(tester, EventBriefView(brief: ready(), queued: true),
        compact: true);
    expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    expect(find.text(BriefSection.rewritingText), findsOneWidget);
    expect(find.text('• The quote is owed.'), findsOneWidget,
        reason: 'the old brief stands until the new one lands');

    await pump(
        tester,
        EventBriefView(brief: ready(), queued: true, processingOn: false),
        compact: true);
    expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    expect(find.text(BriefSection.pausedText), findsOneWidget);
  });

  testWidgets('compact with no ready brief draws nothing but the files '
      'sentence', (tester) async {
    for (final view in [
      null,
      const EventBriefView(queued: true),
      const EventBriefView(processingOn: false),
      EventBriefView(brief: row(EventBrief.failed)),
      EventBriefView(brief: row(EventBrief.skipped, hash: 'ineligible:no_mail')),
    ]) {
      await pump(tester, view, compact: true);
      expect(find.byType(Text), findsNothing, reason: '$view');
      expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    }
  });

  testWidgets('a thread chip opens its thread', (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    await tester.tap(find.byKey(BriefSection.pointThreadKeyFor(0)));
    await tester.tap(find.byKey(BriefSection.askThreadKeyFor(0)));
    expect(opened, [('email', 'c-1'), ('email', 'c-1')]);
    expect(find.text('Fabrikam renewal'), findsNWidgets(2));
  });

  testWidgets('a thread index the stored list does not hold draws no chip',
      (tester) async {
    await pump(tester, EventBriefView(brief: ready(withThreads: false)));
    expect(find.byKey(BriefSection.pointThreadKeyFor(0)), findsNothing);
  });

  testWidgets('Regenerate asks, and a brief being rewritten says so instead',
      (tester) async {
    await pump(tester, EventBriefView(brief: ready()));
    await tester.tap(find.byKey(BriefSection.regenerateKey));
    expect(regenerated, 1);

    await pump(tester, EventBriefView(brief: ready(), queued: true));
    expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    expect(find.text(BriefSection.rewritingText), findsOneWidget);
    expect(find.byKey(BriefSection.headlineKey), findsOneWidget,
        reason: 'the old brief stands until the new one lands');
  });

  testWidgets('processing off keeps a written brief and its Regenerate; one '
      'already asked for says it is paused', (tester) async {
    await pump(tester, EventBriefView(brief: ready(), processingOn: false));
    expect(find.byKey(BriefSection.headlineKey), findsOneWidget);
    expect(find.byKey(BriefSection.regenerateKey), findsOneWidget);

    await pump(tester,
        EventBriefView(brief: ready(), processingOn: false, queued: true));
    expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    expect(find.text(BriefSection.pausedText), findsOneWidget);
  });

  testWidgets('each sentence when there is no brief to show', (tester) async {
    await pump(tester, const EventBriefView(queued: true));
    expect(status(tester), BriefSection.writingText);

    await pump(tester, const EventBriefView(processingOn: false));
    expect(status(tester), BriefSection.pausedText);

    await pump(
      tester,
      EventBriefView(
          brief: row(EventBrief.skipped, hash: 'ineligible:no_mail')),
    );
    expect(status(tester), 'No brief — no recent mail with these people.');

    await pump(
      tester,
      EventBriefView(
          brief: row(EventBrief.skipped, hash: 'ineligible:no_others')),
    );
    expect(status(tester), BriefSection.noOthersText);

    await pump(
      tester,
      EventBriefView(
          brief: row(EventBrief.skipped, hash: 'ineligible:too_many')),
    );
    // No build writes too_many any more (there is no people cap): an older
    // build's stored row reads the generic sentence until the planner's next
    // pass replaces it.
    expect(status(tester), BriefSection.ineligibleText);

    await pump(tester, const EventBriefView(), eligible: false);
    expect(status(tester), BriefSection.ineligibleText);

    // The no-read rules' own words, when nothing is stored yet.
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_far');
    expect(status(tester), 'Briefs are written for today and tomorrow.');
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'no_others');
    expect(status(tester), 'No brief — nobody else is invited.');
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_many');
    expect(status(tester), BriefSection.ineligibleText);
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'cancelled');
    expect(status(tester), BriefSection.ineligibleText);

    await pump(tester, const EventBriefView());
    expect(status(tester), BriefSection.comingText);

    await pump(tester, null);
    expect(find.byKey(BriefSection.statusKey), findsNothing,
        reason: 'nothing while the read is in flight');
  });

  testWidgets('a materials_pending brief shows its sentence in both faces',
      (tester) async {
    final pending = EventBriefView(
        brief:
            row(EventBrief.skipped, hash: 'ineligible:materials_pending'));
    await pump(tester, pending);
    expect(status(tester), 'Reading the files sent ahead — brief coming.');
    expect(BriefSection.reasonText('materials_pending'),
        BriefSection.materialsPendingText);

    // Once the meeting has started (or the quick check says no for any
    // other reason) no brief is coming: its sentence wins.
    await pump(tester, pending, eligible: false, reason: 'past');
    expect(status(tester), BriefSection.startedText);

    await pump(tester, pending, compact: true);
    expect(status(tester), BriefSection.materialsPendingText);
    expect(find.byKey(BriefSection.regenerateKey), findsNothing);
    expect(find.byKey(BriefSection.headlineKey), findsNothing);
  });

  testWidgets('a decline or a cancel outranks a ready brief; another reason '
      'does not', (tester) async {
    for (final reason in ['declined', 'cancelled']) {
      await pump(tester, EventBriefView(brief: ready()),
          eligible: false, reason: reason);
      expect(find.byKey(BriefSection.headlineKey), findsNothing);
      expect(status(tester), BriefSection.ineligibleText);
    }
    // A meeting that has started keeps the brief it has.
    await pump(tester, EventBriefView(brief: ready()),
        eligible: false, reason: 'past');
    expect(find.byKey(BriefSection.headlineKey), findsOneWidget);
  });

  testWidgets('Write a brief shows for too far, no mail and coming, and calls '
      'onWrite', (tester) async {
    Future<void> pressWrite() async {
      expect(find.byKey(BriefSection.writeKey), findsOneWidget);
      expect(find.text(BriefSection.writeLabel), findsOneWidget);
      await tester.tap(find.byKey(BriefSection.writeKey));
    }

    // Too far off, nothing stored: the quick check's reason and the button.
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_far', canWrite: true);
    expect(status(tester), BriefSection.tooFarText);
    await pressWrite();
    expect(written, 1);

    // A skipped row for no mail — and one for too far, written by a
    // planner request the handler refused.
    for (final reason in ['no_mail', 'too_far']) {
      await pump(
          tester,
          EventBriefView(
              brief: row(EventBrief.skipped, hash: 'ineligible:$reason')),
          canWrite: true);
      expect(status(tester), BriefSection.reasonText(reason));
      await pressWrite();
    }
    expect(written, 3);

    // Nothing stored and nothing against it: coming, or now by hand.
    await pump(tester, const EventBriefView(), canWrite: true);
    expect(status(tester), BriefSection.comingText);
    await pressWrite();
    expect(written, 4);
    expect(regenerated, 0);

    // Null onWrite: the sentence alone.
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_far');
    expect(find.byKey(BriefSection.writeKey), findsNothing);
  });

  testWidgets('Write a brief: never for a started, cancelled or declined '
      'meeting, a ready or failed brief, or with processing off',
      (tester) async {
    Future<void> none(EventBriefView view,
        {bool? eligible, String? reason}) async {
      await pump(tester, view,
          eligible: eligible, reason: reason, canWrite: true);
      expect(find.byKey(BriefSection.writeKey), findsNothing,
          reason: '${view.brief?.status} $eligible $reason');
    }

    for (final reason in [
      'past',
      'cancelled',
      'declined',
      'no_others',
      'too_many',
    ]) {
      await none(const EventBriefView(), eligible: false, reason: reason);
    }
    for (final reason in ['no_others', 'too_many', 'materials_pending']) {
      await none(EventBriefView(
          brief: row(EventBrief.skipped, hash: 'ineligible:$reason')));
    }
    // A stored no_mail or too_far row over a meeting the quick check now
    // refuses for a reason a request does not lift: started, cancelled,
    // declined, nobody else.
    for (final stored in ['no_mail', 'too_far']) {
      for (final reason in ['past', 'cancelled', 'declined', 'no_others']) {
        await none(
            EventBriefView(
                brief: row(EventBrief.skipped, hash: 'ineligible:$stored')),
            eligible: false,
            reason: reason);
      }
    }
    // Waiting on the files, after the meeting has started.
    await none(
        EventBriefView(
            brief: row(EventBrief.skipped,
                hash: 'ineligible:materials_pending')),
        eligible: false,
        reason: 'past');
    await none(EventBriefView(brief: ready()));
    await none(EventBriefView(brief: row(EventBrief.failed)));
    await none(const EventBriefView(queued: true));
    await none(const EventBriefView(processingOn: false));
    await none(
        EventBriefView(
            processingOn: false,
            brief: row(EventBrief.skipped, hash: 'ineligible:no_mail')),
        eligible: false,
        reason: 'too_far');
    // The agenda's compact face never offers it.
    await pump(tester, const EventBriefView(), compact: true, canWrite: true);
    expect(find.byKey(BriefSection.writeKey), findsNothing);
  });

  testWidgets('a failed brief offers Regenerate', (tester) async {
    await pump(tester, EventBriefView(brief: row(EventBrief.failed)));
    expect(status(tester), BriefSection.failedText);
    await tester.tap(find.byKey(BriefSection.regenerateKey));
    expect(regenerated, 1);
  });

  group('the source caption', () {
    const invite = BriefThreadRef(
        source: 'email',
        conversationKey: 'c-inv',
        subject: 'Fabrikam renewal',
        invite: true);
    const found = BriefThreadRef(
        source: 'teams', conversationKey: 't-1', subject: 'Renewal chat');

    String caption(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(BriefSection.sourceKey)).data!;

    testWidgets('people, related and invite-alone, on both faces',
        (tester) async {
      for (final (brief, want) in [
        (ready(), BriefSection.fromPeopleText),
        (
          ready(
              path: MeetingBrief.pathRelated,
              threadRefs: const [invite, found]),
          BriefSection.fromRelatedText
        ),
        (
          ready(path: MeetingBrief.pathRelated, threadRefs: const [invite]),
          BriefSection.fromInviteText
        ),
        (ready(withThreads: false), BriefSection.fromInviteText),
        (
          ready(path: MeetingBrief.pathRelated, withThreads: false),
          BriefSection.fromInviteText
        ),
        // The people path with only the invite's own thread: no mail with
        // the people was found either.
        (ready(threadRefs: const [invite]), BriefSection.fromInviteText),
        (ready(threadRefs: const [invite, found]), BriefSection.fromPeopleText),
      ]) {
        for (final compact in [false, true]) {
          await pump(tester, EventBriefView(brief: brief), compact: compact);
          expect(find.byKey(BriefSection.sourceKey), findsOneWidget);
          expect(caption(tester), want, reason: 'compact: $compact');
        }
      }
      expect(BriefSection.fromPeopleText,
          'From your mail with the people in this meeting.');
      expect(BriefSection.fromRelatedText,
          'From threads related to this meeting — a sample, not everything '
          'on the subject.');
      expect(BriefSection.fromInviteText,
          'From the invite alone — no other threads were found.');
    });

    testWidgets('an old row with no path reads as the people path',
        (tester) async {
      final old = EventBrief(
        eventId: 'evt-1',
        inputsHash: 'h',
        status: EventBrief.ready,
        briefJson: '{"headline":"H.","threads":[{"source":"email",'
            '"conversation_key":"c-1","subject":"S"}]}',
        generatedAt: calendarStamp(now),
      );
      await pump(tester, EventBriefView(brief: old));
      expect(caption(tester), BriefSection.fromPeopleText);
    });

    testWidgets('the panel draws it above Generated; the agenda above '
        'Regenerate', (tester) async {
      await pump(tester, EventBriefView(brief: ready()));
      expect(
          tester.getTopLeft(find.byKey(BriefSection.sourceKey)).dy,
          lessThan(tester.getTopLeft(find.byKey(BriefSection.statusKey)).dy));
      await pump(tester, EventBriefView(brief: ready()), compact: true);
      expect(
          tester.getTopLeft(find.byKey(BriefSection.sourceKey)).dy,
          lessThan(
              tester.getTopLeft(find.byKey(BriefSection.regenerateKey)).dy));
    });

    testWidgets('no caption without a ready brief', (tester) async {
      for (final view in [
        EventBriefView(brief: row(EventBrief.skipped, hash: 'ineligible:no_mail')),
        EventBriefView(brief: row(EventBrief.failed)),
        const EventBriefView(),
        EventBriefView(
            brief: row(EventBrief.skipped,
                hash: 'ineligible:materials_pending')),
      ]) {
        for (final compact in [false, true]) {
          await pump(tester, view, compact: compact);
          expect(find.byKey(BriefSection.sourceKey), findsNothing,
              reason: '${view.brief?.status} compact: $compact');
        }
      }
    });
  });
}

/// A ready row holding [brief], generated two hours before [now].
EventBrief _readyRow(MeetingBrief brief, DateTime now) => EventBrief(
      eventId: 'evt-1',
      inputsHash: 'h',
      status: EventBrief.ready,
      briefJson: jsonEncode(brief.toJson()),
      generatedAt: calendarStamp(now.subtract(const Duration(hours: 2))),
    );
