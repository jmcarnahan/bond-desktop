import 'dart:convert';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/widgets/brief_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The event panel's Brief section, prop-only: each state's sentence, the
/// brief itself, the thread chips and Regenerate.
void main() {
  final now = DateTime.utc(2026, 9, 29, 16);

  EventBrief ready({bool withThreads = true}) {
    final brief = MeetingBrief(
      headline: 'Dana is waiting on the quote.',
      points: const [
        BriefPoint(text: 'The quote is owed.', thread: 0),
        BriefPoint(text: 'Nothing else is open.'),
      ],
      openAsks: const [
        BriefAskOut(person: 'Dana', ask: 'Send the quote', thread: 0),
      ],
      prep: const ['Have the quote ready'],
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
  var regenerated = 0;

  setUp(() {
    opened.clear();
    regenerated = 0;
  });

  Future<void> pump(WidgetTester tester, EventBriefView? view,
      {bool? eligible, String? reason}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BriefSection(
          view: view,
          eligible: eligible,
          ineligibleReason: reason,
          now: now,
          onOpenThread: (s, k) => opened.add((s, k)),
          onRegenerate: () => regenerated++,
        ),
      ),
    ));
  }

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
