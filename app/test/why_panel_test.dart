import 'package:bond_inbox/models/extraction_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart'
    show NeedsYouOverride;
import 'package:bond_inbox/services/decision/stored_decision.dart';
import 'package:bond_inbox/widgets/why_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';

/// The explanation beside a message.
///
/// Two claims run through every case here. The verdict is TRI-STATE and the
/// panel never collapses it — "not judged yet" and "not flagged" are different
/// answers. And every line is a sentence: no JSON, no stored token, nothing
/// that reads as a field name.
void main() {
  final now = DateTime(2026, 9, 8, 10);

  Message msg({
    double? needsYouP,
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
        needsYouP: needsYouP,
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
    double threshold = 0.35,
    VoidCallback? onWhatHappened,
    StoredDecision? decision,
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
          decision: decision,
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
    testWidgets('the probability is a percentage, with the reason spelled out',
        (tester) async {
      await pump(
        tester,
        message: msg(needsYouP: 0.9, needsYouReason: 'teams_direct'),
      );

      expect(find.text('Needs you: 90%'), findsOneWidget);
      expect(find.text('In Needs You: at or above your 35% line.'),
          findsOneWidget);
      // The stored token is a token; the reader gets the sentence.
      expect(find.text('A direct message to you on Teams.'), findsOneWidget);
      expect(find.text('teams_direct'), findsNothing);
    });

    testWidgets('the model\'s own evidence line is shown as written',
        (tester) async {
      await pump(
        tester,
        message: msg(
          needsYouP: 0.9,
          needsYouReason: 'She asked you to confirm the closing date.',
        ),
      );

      expect(
        find.text('She asked you to confirm the closing date.'),
        findsOneWidget,
      );
    });

    testWidgets('below the slider shows its number and says so, without '
        'the reason', (tester) async {
      // The reason is templated whatever the probability; under the line it
      // would claim an ask about a message the reader was told needs nothing.
      await pump(
        tester,
        message: msg(needsYouP: 0.1, needsYouReason: 'Asks you a question.'),
      );

      expect(find.text('Needs you: 10%'), findsOneWidget);
      expect(find.text('Not in Needs You: below your 35% line.'),
          findsOneWidget);
      expect(find.text('Asks you a question.'), findsNothing);
    });

    testWidgets('the percentage is floored, so it never contradicts the line',
        (tester) async {
      // Rounded, 0.296 would read "30%" beside "below your 30% line".
      for (final (p, shown, inside) in [
        (0.296, '29%', false),
        (0.2999, '29%', false),
        (0.30, '30%', true),
        (0.3001, '30%', true),
        (0.716, '71%', true),
      ]) {
        await pump(tester, message: msg(needsYouP: p), threshold: 0.30);
        expect(find.text('Needs you: $shown'), findsOneWidget, reason: '$p');
        expect(
          find.text(inside
              ? 'In Needs You: at or above your 30% line.'
              : 'Not in Needs You: below your 30% line.'),
          findsOneWidget,
          reason: '$p',
        );
      }
    });

    testWidgets("an earlier model's carried verdict shows no percentage",
        (tester) async {
      // v21 carried the old verdicts across as 1.0 and 0.0. With no decision
      // under this build's questions, no model said that number.
      await pump(tester, message: msg(needsYouP: 1.0));
      expect(find.text('Needs you: — (earlier model)'), findsOneWidget);
      expect(find.text('Needs you: 100%'), findsNothing);
      // It still counts against the slider.
      expect(find.text('In Needs You: at or above your 35% line.'),
          findsOneWidget);

      await pump(tester, message: msg(needsYouP: 0.0));
      expect(find.text('Needs you: — (earlier model)'), findsOneWidget);
      expect(find.text('Not in Needs You: below your 35% line.'),
          findsOneWidget);

      // Decided under this build's questions, the same number is the model's.
      await pump(
        tester,
        message: msg(needsYouP: 1.0),
        decision: StoredDecision(
          answers: fakeAnswers(),
          model: 'bond-decide-fake',
          needsYouP: 1.0,
        ),
      );
      expect(find.text('Needs you: 100%'), findsOneWidget);
    });

    testWidgets("the owner's removal reads as theirs, with its sentence "
        'below the line', (tester) async {
      await pump(
        tester,
        message: msg(
          needsYouP: 0.0,
          needsYouReason: 'You removed a message like this from Needs You.',
        ),
        decision: StoredDecision(
          answers: fakeAnswers(needsYou: 0.9).withNeedsYou('no'),
          model: 'bond-decide-fake',
          needsYouP: 0.0,
        ),
      );

      // From a message like this one, not this message: the headline says so.
      expect(find.text('Needs you: no — like one you removed'),
          findsOneWidget);
      expect(find.text('Needs you: 0%'), findsNothing);
      expect(
        find.text('You removed a message like this from Needs You.'),
        findsOneWidget,
      );
      expect(find.text('Not in Needs You: below your 35% line.'),
          findsOneWidget);
    });

    testWidgets("the owner's addition reads as theirs, with no percentage",
        (tester) async {
      await pump(
        tester,
        message: msg(
          needsYouP: 1.0,
          needsYouReason: 'You added this message to Needs You.',
        ),
        decision: StoredDecision(
          answers: fakeAnswers(needsYou: 0.1).withNeedsYou('yes', exact: true),
          model: 'bond-decide-fake',
          needsYouP: 1.0,
        ),
      );

      expect(find.text('Needs you: yes — you added it'), findsOneWidget);
      expect(find.text('Needs you: 100%'), findsNothing);
      expect(find.text('You added this message to Needs You.'), findsOneWidget);
      expect(find.text('In Needs You: at or above your 35% line.'),
          findsOneWidget);
    });

    testWidgets("the reader's own slider is the cut", (tester) async {
      await pump(tester, message: msg(needsYouP: 0.4), threshold: 0.3);
      expect(find.text('Needs you: 40%'), findsOneWidget);
      expect(find.text('In Needs You: at or above your 30% line.'),
          findsOneWidget);

      await pump(tester, message: msg(needsYouP: 0.4), threshold: 0.5);
      expect(find.text('Needs you: 40%'), findsOneWidget);
      expect(find.text('Not in Needs You: below your 50% line.'),
          findsOneWidget);
    });

    testWidgets('undecided is a dash, which is not the same as 0%',
        (tester) async {
      await pump(tester, message: msg());

      expect(find.text('Needs you: —'), findsOneWidget);
      expect(
        find.text('The needs-you pass has not reached this message.'),
        findsOneWidget,
      );
      expect(find.textContaining('Needs You:'), findsNothing);
      expect(find.text('Needs you: 0%'), findsNothing);
    });

    testWidgets('a gated message says which gate took it, in words',
        (tester) async {
      // The gate writes snake_case tokens; the panel reads them as words.
      await pump(tester, message: msg(gateReason: 'teams_source'));

      expect(find.text('Skipped by the gate: teams source.'), findsOneWidget);
    });

    testWidgets("the decision model's own gate reads in the label's words",
        (tester) async {
      await pump(tester, message: msg(gateReason: 'model_other'));

      expect(find.text('Skipped by the gate: automated.'), findsOneWidget);
    });

    testWidgets("the decision model's numbers are one line", (tester) async {
      await pump(
        tester,
        decision: StoredDecision(
          answers: fakeAnswers(),
          model: 'bond-decide-fake',
          gateP: 0.06,
          needsYouP: 0.713,
          needsActionP: 0.66,
          replyExpectedP: 0.1,
          latencyMs: 58,
        ),
      );

      expect(
        find.text('Decision model: gate keep 0.94, needs you 0.71, '
            'action 0.66, reply 0.10 · 58 ms'),
        findsOneWidget,
      );
    });

    testWidgets('a learned drop says drop, with its probability',
        (tester) async {
      await pump(
        tester,
        message: msg(gateReason: 'digest', triageStatus: 'skipped'),
        decision: StoredDecision(
          answers: fakeAnswers(gateDrop: 0.91),
          model: 'bond-decide-fake',
          gateP: 0.91,
          needsYouP: 0.02,
          needsActionP: 0.05,
          replyExpectedP: 0.03,
          latencyMs: 40,
        ),
      );

      expect(find.text('Skipped by the gate: digest.'), findsOneWidget);
      expect(
        find.text('Decision model: gate drop 0.91, needs you 0.02, '
            'action 0.05, reply 0.03 · 40 ms'),
        findsOneWidget,
      );
    });

    testWidgets('an owner-Ignored message reads what the model said, not a '
        'drop', (tester) async {
      // `user` is the owner's gate word, not the learned gate's, so the line
      // is the model's keep rather than "gate drop 0.05".
      await pump(
        tester,
        message: msg(gateReason: 'user', triageStatus: 'skipped'),
        decision: StoredDecision(
          answers: fakeAnswers(gateDrop: 0.05),
          model: 'bond-decide-fake',
          gateP: 0.05,
          needsYouP: 0.3,
          needsActionP: 0.2,
          replyExpectedP: 0.1,
          latencyMs: 40,
        ),
      );

      expect(
        find.text('Decision model: gate keep 0.95, needs you 0.30, '
            'action 0.20, reply 0.10 · 40 ms'),
        findsOneWidget,
      );
    });

    testWidgets('a learned word under the bar is not the model dropping it',
        (tester) async {
      // A rules gate can write a word the learned gate also writes; without
      // p(drop) over the bar the model did not take it.
      await pump(
        tester,
        message: msg(gateReason: 'newsletter', triageStatus: 'skipped'),
        decision: StoredDecision(
          answers: fakeAnswers(gateDrop: 0.2),
          model: 'bond-decide-fake',
          gateP: 0.2,
          needsYouP: 0.1,
          needsActionP: 0.1,
          replyExpectedP: 0.1,
        ),
      );

      expect(
        find.text('Decision model: gate keep 0.80, needs you 0.10, '
            'action 0.10, reply 0.10'),
        findsOneWidget,
      );
    });

    testWidgets('a kept message the head leaned against says so',
        (tester) async {
      await pump(
        tester,
        decision: StoredDecision(
          answers: fakeAnswers(gateDrop: 0.6),
          model: 'bond-decide-fake',
          gateP: 0.6,
          needsYouP: 0.4,
          needsActionP: 0.5,
          replyExpectedP: 0.5,
          latencyMs: 40,
        ),
      );

      expect(
        find.text('Decision model: gate keep (drop 0.60), needs you 0.40, '
            'action 0.50, reply 0.50 · 40 ms'),
        findsOneWidget,
      );
    });

    testWidgets('no decision, no line', (tester) async {
      await pump(tester);

      expect(
        texts(tester).where((t) => t.startsWith('Decision model')),
        isEmpty,
      );
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

  group('a row written since the decision model', () {
    // Triage wrote no label and the text stage writes no evidence, people or
    // organizations: each line is simply absent, never drawn empty.
    testWidgets('no label on the triage line', (tester) async {
      await pump(tester, message: msg(label: null));

      expect(find.text('Urgency high · Category work'), findsOneWidget);
      expect(find.textContaining('Label'), findsNothing);
    });

    testWidgets('no evidence, people or organizations lines', (tester) async {
      await pump(
        tester,
        extraction: const ExtractionResult(
          topics: ['survey'],
          project: 'Lot 14',
          intent: 'request',
          importance: 'high',
        ),
      );

      expect(find.text('Intent request · Importance high'), findsOneWidget);
      expect(find.text('Topics: survey'), findsOneWidget);
      expect(find.text('Project: Lot 14'), findsOneWidget);
      expect(find.textContaining('People'), findsNothing);
      expect(find.textContaining('Organizations'), findsNothing);
    });

    testWidgets('text not landed yet: the triage line alone', (tester) async {
      await pump(tester, message: msg(summary: null, label: null));

      expect(find.text('Urgency high · Category work'), findsOneWidget);
      expect(find.text('They want the survey back.'), findsNothing);
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

    testWidgets('the score is reported on its own, not against the slider',
        (tester) async {
      // The score orders Needs You; the slider cuts the needs-you
      // probability. Setting one against the other would explain nothing.
      await pump(
        tester,
        conversation: const Conversation(id: 'c1', attentionScore: 1.4),
      );

      expect(find.text('Attention 1.4.'), findsOneWidget);
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
        needsYouP: 0.9,
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
