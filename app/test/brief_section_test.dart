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

  EventBrief ready({bool withThreads = true, bool withMaterials = true}) {
    final brief = MeetingBrief(
      headline: 'Dana is waiting on the quote.',
      points: const [
        BriefPoint(text: 'The quote is owed.', thread: 0),
        BriefPoint(text: 'Nothing else is open.'),
      ],
      openAsks: const [
        BriefAskOut(person: 'Dana', ask: 'Send the quote', thread: 0),
      ],
      materials: const [
        BriefMaterialOut(file: 0, takeaway: 'The deck prices the renewal at 12k.'),
        BriefMaterialOut(file: 1, takeaway: 'The sheet lists three open items.'),
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
      threads: withThreads
          ? const [
              BriefThreadRef(
                source: 'email',
                conversationKey: 'c-1',
                subject: 'Fabrikam renewal',
              ),
            ]
          : const [],
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

  setUp(() {
    opened.clear();
    files.clear();
    regenerated = 0;
  });

  Future<void> pump(WidgetTester tester, EventBriefView? view,
      {bool? eligible,
      String? reason,
      bool compact = false,
      bool canOpenFiles = true}) async {
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

  testWidgets('a ready brief also lists its materials and questions, in '
      'order', (tester) async {
    await pump(tester, EventBriefView(brief: ready()));

    expect(find.text('Materials'), findsOneWidget);
    expect(find.text('Questions'), findsOneWidget);
    expect(find.text('Renewal deck.pptx'), findsOneWidget);
    expect(find.text('The deck prices the renewal at 12k.'), findsOneWidget);
    expect(find.text('1. Is 12k the final number?'), findsOneWidget);
    expect(find.text('2. Who signs for Fabrikam?'), findsOneWidget);

    // Points, then Materials, then Questions, then Open asks, then Prep.
    final point = top(tester, find.byKey(BriefSection.pointKeyFor(1)));
    final materials = top(tester, find.text('Materials'));
    final secondFile = top(tester, find.byKey(BriefSection.materialTextKeyFor(1)));
    final questions = top(tester, find.text('Questions'));
    final secondQuestion = top(tester, find.byKey(BriefSection.questionKeyFor(1)));
    final asks = top(tester, find.text('Open asks'));
    final prep = top(tester, find.text('Prep'));
    expect(point, lessThan(materials));
    expect(materials, lessThan(secondFile));
    expect(secondFile, lessThan(questions));
    expect(questions, lessThan(secondQuestion));
    expect(secondQuestion, lessThan(asks));
    expect(asks, lessThan(prep));
  });

  testWidgets('a material chip opens its file; a missing ref draws the '
      'takeaway alone', (tester) async {
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

    // The second takeaway points at index 1, which the brief does not hold.
    expect(find.byKey(BriefSection.materialKeyFor(1)), findsNothing);
    expect(find.byKey(BriefSection.materialTextKeyFor(1)), findsOneWidget);
    expect(find.text('The sheet lists three open items.'), findsOneWidget);

    // No ref at all: both takeaways, no chip.
    await pump(tester, EventBriefView(brief: ready(withMaterials: false)));
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsNothing);
    expect(find.text('The deck prices the renewal at 12k.'), findsOneWidget);

    // No opener: the name is plain text, not a chip.
    await pump(tester, EventBriefView(brief: ready()), canOpenFiles: false);
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsNothing);
    expect(find.text('Renewal deck.pptx'), findsOneWidget);
  });

  testWidgets('compact draws points, materials, questions and asks — no '
      'heading, no footer, no status', (tester) async {
    await pump(tester, EventBriefView(brief: ready()), compact: true);

    expect(find.byKey(BriefSection.headlineKey), findsNothing,
        reason: 'the row\'s glance is the headline');
    expect(find.text('Dana is waiting on the quote.'), findsNothing);
    expect(find.byKey(BriefSection.statusKey), findsNothing);
    expect(find.textContaining('Generated'), findsNothing);
    expect(find.text('Brief'), findsNothing);
    expect(find.text('• The quote is owed.'), findsOneWidget);
    expect(find.byKey(BriefSection.materialKeyFor(0)), findsOneWidget);
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

  testWidgets('compact with no ready brief draws nothing', (tester) async {
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
    expect(status(tester), BriefSection.tooManyText);
    expect(BriefSection.tooManyText, 'No brief — too many people for a brief.');

    await pump(tester, const EventBriefView(), eligible: false);
    expect(status(tester), BriefSection.ineligibleText);

    // The no-read rules' own words, when nothing is stored yet.
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_far');
    expect(status(tester),
        'A brief is written in the 36 hours before the meeting.');
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'no_others');
    expect(status(tester), 'No brief — nobody else is invited.');
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'too_many');
    expect(status(tester), BriefSection.tooManyText);
    await pump(tester, const EventBriefView(),
        eligible: false, reason: 'cancelled');
    expect(status(tester), BriefSection.ineligibleText);

    await pump(tester, const EventBriefView());
    expect(status(tester), BriefSection.comingText);

    await pump(tester, null);
    expect(find.byKey(BriefSection.statusKey), findsNothing,
        reason: 'nothing while the read is in flight');
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

  testWidgets('a failed brief offers Regenerate', (tester) async {
    await pump(tester, EventBriefView(brief: row(EventBrief.failed)));
    expect(status(tester), BriefSection.failedText);
    await tester.tap(find.byKey(BriefSection.regenerateKey));
    expect(regenerated, 1);
  });
}
