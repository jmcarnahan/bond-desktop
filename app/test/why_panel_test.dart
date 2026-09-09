import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/extract_task.dart'
    show ExtractionResult;
import 'package:bond_inbox/widgets/why_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The explanation beside a message.
///
/// Two claims run through every case here. The verdict is TRI-STATE and the
/// panel never collapses it — "not judged yet" and "not flagged" are different
/// answers. And every line is a sentence: no JSON, no stored token, nothing
/// that reads as a field name.
void main() {
  final now = DateTime(2026, 9, 8, 10);

  Message msg({
    bool? needsYouVerdict,
    String? needsYouReason,
    String? gateReason,
    String triageStatus = 'triaged',
    String? summary = 'They want the survey back.',
    String? urgency = 'high',
    String? category = 'work',
    String? label = 'survey',
    bool? needsAction,
    bool? replyExpected,
    String? deadline,
    bool addressedMe = false,
    List<String> actionItems = const [],
  }) =>
      Message(
        id: 'm1',
        outbound: false,
        fromName: 'Dana Whitfield',
        fromAddress: 'dana@example.test',
        receivedAt: '2026-09-07T10:00:00Z',
        subject: 'The survey',
        bodyText: 'Body.',
        needsYouVerdict: needsYouVerdict,
        needsYouReason: needsYouReason,
        gateReason: gateReason,
        triageStatus: triageStatus,
        summary: summary,
        urgency: urgency,
        category: category,
        label: label,
        needsAction: needsAction,
        replyExpected: replyExpected,
        deadline: deadline,
        addressedMe: addressedMe,
        actionItems: actionItems,
      );

  Future<void> pump(
    WidgetTester tester, {
    Message? message,
    Conversation? conversation,
    ExtractionResult? extraction,
    Map<String, Object?>? ai,
    double threshold = 1.0,
    VoidCallback? onWhatHappened,
  }) async {
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WhyPanelBody(
          message: message ?? msg(),
          conversation: conversation,
          extraction: extraction,
          ai: ai,
          threshold: threshold,
          now: now,
          onWhatHappened: onWhatHappened,
        ),
      ),
    ));
  }

  /// Every piece of text the panel put on screen.
  List<String> texts(WidgetTester tester) => [
        for (final w in tester.widgetList<Text>(find.byType(Text)))
          w.data ?? '',
      ];

  group('the verdict', () {
    testWidgets('true is Needs you, with the reason spelled out',
        (tester) async {
      await pump(
        tester,
        message: msg(needsYouVerdict: true, needsYouReason: 'teams_direct'),
      );

      expect(find.text('Needs you'), findsOneWidget);
      // The stored token is a token; the reader gets the sentence.
      expect(find.text('A direct message to you on Teams.'), findsOneWidget);
      expect(find.text('teams_direct'), findsNothing);
    });

    testWidgets('the model\'s own evidence line is shown as written',
        (tester) async {
      await pump(
        tester,
        message: msg(
          needsYouVerdict: true,
          needsYouReason: 'She asked you to confirm the closing date.',
        ),
      );

      expect(
        find.text('She asked you to confirm the closing date.'),
        findsOneWidget,
      );
    });

    testWidgets('false is Not flagged', (tester) async {
      await pump(tester, message: msg(needsYouVerdict: false));

      expect(find.text('Not flagged'), findsOneWidget);
      expect(
        find.text('The pass judged it does not need you.'),
        findsOneWidget,
      );
    });

    testWidgets('null is Not judged yet, which is not the same as no',
        (tester) async {
      await pump(tester, message: msg());

      expect(find.text('Not judged yet'), findsOneWidget);
      expect(
        find.text('The needs-you pass has not reached this message.'),
        findsOneWidget,
      );
      expect(find.text('Not flagged'), findsNothing);
    });

    testWidgets('a gated message says which gate took it, in words',
        (tester) async {
      // The gate writes snake_case tokens; the panel reads them as words.
      await pump(tester, message: msg(gateReason: 'teams_source'));

      expect(find.text('Skipped by the gate: teams source.'), findsOneWidget);
    });
  });

  group('triage', () {
    testWidgets('a message triage has not reached says so', (tester) async {
      await pump(tester, message: msg(triageStatus: 'pending'));

      expect(find.text('Triage has not run yet.'), findsOneWidget);
      // And none of the labels a pending row would carry empty.
      expect(find.textContaining('Urgency'), findsNothing);
    });

    testWidgets('the summary, then the labels on one line', (tester) async {
      await pump(tester);

      expect(find.text('They want the survey back.'), findsOneWidget);
      expect(
        find.text('Urgency high · Category work · Label survey'),
        findsOneWidget,
      );
    });
  });

  group('what is being asked', () {
    testWidgets('action, reply, deadline, who it was addressed to',
        (tester) async {
      await pump(
        tester,
        message: msg(
          needsAction: true,
          replyExpected: true,
          deadline: 'by Friday',
          addressedMe: true,
          actionItems: const ['Send the survey', 'Confirm the date'],
        ),
      );

      expect(find.text('Asks for action.'), findsOneWidget);
      expect(find.text('A reply is expected.'), findsOneWidget);
      expect(find.text('Deadline: by Friday'), findsOneWidget);
      expect(find.text('Addressed to you directly.'), findsOneWidget);
      expect(find.text('• Send the survey'), findsOneWidget);
      expect(find.text('• Confirm the date'), findsOneWidget);
    });

    testWidgets('an unjudged reply expectation is not a no', (tester) async {
      await pump(tester, message: msg(needsAction: false));

      expect(find.text('No action asked.'), findsOneWidget);
      expect(
        find.text('Not judged whether a reply is expected.'),
        findsOneWidget,
      );
      expect(find.text('Not addressed to you alone.'), findsOneWidget);
    });
  });

  group('attention', () {
    testWidgets('an unscored thread says so rather than showing a zero',
        (tester) async {
      await pump(tester, conversation: const Conversation(id: 'c1'));

      expect(find.text('Not scored yet.'), findsOneWidget);
    });

    testWidgets('the score is reported against the reader\'s own threshold',
        (tester) async {
      await pump(
        tester,
        conversation: const Conversation(id: 'c1', attentionScore: 1.4),
        threshold: 1.0,
      );

      expect(
        find.text('Attention 1.4 — above your threshold of 1.0.'),
        findsOneWidget,
      );
    });

    testWidgets('a score under the line reads as below', (tester) async {
      await pump(
        tester,
        conversation: const Conversation(id: 'c1', attentionScore: 0.4),
        threshold: 1.0,
      );

      expect(
        find.text('Attention 0.4 — below your threshold of 1.0.'),
        findsOneWidget,
      );
    });

    testWidgets('each way a thread reaches Later is named in words',
        (tester) async {
      for (final (reason, sentence) in [
        ('user', 'In Later — you sent it there.'),
        ('sender_pref', 'In Later — a rule about the sender.'),
        ('low_value', 'In Later — the model judged it low value.'),
        (null, 'In Later — filed by the app.'),
      ]) {
        await pump(tester, ai: {'bucket': 'later', 'bucket_reason': reason});
        expect(find.text(sentence), findsOneWidget, reason: 'for $reason');
      }
    });

    testWidgets('a thread in the inbox on the reader\'s say-so names both ways '
        'it got there', (tester) async {
      // Keep in inbox and a Later date coming due write the same two columns,
      // and the row cannot say which happened — so the sentence must not
      // claim one of them.
      await pump(tester, ai: const {'bucket': null, 'bucket_reason': 'user'});

      expect(
        find.text('In your inbox on your say-so — kept here, or back from '
            'Later on its date.'),
        findsOneWidget,
      );
    });

    testWidgets('a deferral with a date says when it comes back',
        (tester) async {
      await pump(tester, ai: const {
        'bucket': 'later',
        'bucket_reason': 'user',
        'snoozed_until': '2026-09-09T09:00:00.000000Z',
      });

      expect(find.text('Back tomorrow.'), findsOneWidget);
    });
  });

  group('what the model pulled out', () {
    testWidgets('nothing extracted says so', (tester) async {
      await pump(tester);
      expect(find.text('Not yet extracted.'), findsOneWidget);
    });

    testWidgets('the evidence sentence, the labels, and the lists',
        (tester) async {
      await pump(
        tester,
        extraction: const ExtractionResult(
          evidence: 'Dana is chasing the survey for lot 14.',
          topics: ['survey', 'lot 14'],
          people: ['Dana Whitfield'],
          organizations: ['Harbourline'],
          project: 'Lot 14',
          intent: 'request',
          importance: 'high',
        ),
      );

      expect(
        find.text('Dana is chasing the survey for lot 14.'),
        findsOneWidget,
      );
      expect(find.text('Intent request · Importance high'), findsOneWidget);
      expect(find.text('Topics: survey, lot 14'), findsOneWidget);
      expect(find.text('People: Dana Whitfield'), findsOneWidget);
      expect(find.text('Organizations: Harbourline'), findsOneWidget);
      expect(find.text('Project: Lot 14'), findsOneWidget);
    });

    testWidgets('an empty list is left out rather than drawn empty',
        (tester) async {
      await pump(
        tester,
        extraction: const ExtractionResult(
          evidence: '',
          topics: [],
          people: [],
          organizations: [],
          project: '',
          intent: 'fyi',
          importance: 'normal',
        ),
      );

      expect(find.text('Intent fyi · Importance normal'), findsOneWidget);
      expect(find.textContaining('Topics'), findsNothing);
      expect(find.textContaining('Project'), findsNothing);
    });
  });

  testWidgets('a message that is no longer stored says so and stops',
      (tester) async {
    // Built directly rather than through the helper: the helper's default is
    // a real message, and null is the whole point of this case.
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WhyPanelBody(
          message: null,
          conversation: null,
          extraction: null,
          ai: null,
          threshold: 1,
          now: now,
        ),
      ),
    ));

    expect(find.text('This message is no longer stored.'), findsOneWidget);
    expect(find.byKey(WhyPanelBody.verdictKey), findsNothing);
  });

  testWidgets('nothing on the panel is a stored shape', (tester) async {
    await pump(
      tester,
      message: msg(
        needsYouVerdict: true,
        needsYouReason: 'teams_direct',
        needsAction: true,
        replyExpected: false,
        deadline: 'by Friday',
        addressedMe: true,
        actionItems: const ['Send the survey'],
        gateReason: 'teams_source',
        // Snake_case on purpose, in every field that takes a stored word:
        // the sweep below is only a sweep if a token that slipped through
        // unworded would trip it.
        urgency: 'very_high',
        category: 'work_request',
        label: 'survey_chase',
      ),
      conversation: const Conversation(id: 'c1', attentionScore: 1.4),
      ai: const {'bucket': 'later', 'bucket_reason': 'low_value'},
      extraction: const ExtractionResult(
        evidence: 'Dana is chasing the survey.',
        topics: ['survey'],
        people: [],
        organizations: [],
        project: '',
        intent: 'request',
        importance: 'high',
      ),
    );

    for (final text in texts(tester)) {
      expect(text.contains('{'), isFalse, reason: 'raw JSON in "$text"');
      expect(text.contains('}'), isFalse, reason: 'raw JSON in "$text"');
      expect(text.contains('_'), isFalse, reason: 'a stored token in "$text"');
    }
  });

  group('the door to the history', () {
    testWidgets('a host that has one gets the button, and it fires',
        (tester) async {
      var opened = 0;
      await pump(tester, onWhatHappened: () => opened++);

      expect(find.byKey(WhyPanelBody.whatHappenedKey), findsOneWidget);
      await tester.tap(find.byKey(WhyPanelBody.whatHappenedKey));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('a host without one draws no button at all', (tester) async {
      await pump(tester);

      // Not a disabled button: a dead link to a screen this build does not
      // have is worse than no link.
      expect(find.byKey(WhyPanelBody.whatHappenedKey), findsNothing);
      expect(find.textContaining('What happened'), findsNothing);
    });
  });
}
