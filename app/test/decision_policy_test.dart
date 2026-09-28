import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/reply_policy.dart'
    show automatedGateReasons;
import 'package:bond_inbox/widgets/home_result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';

void main() {
  group('the constants', () {
    test('are the values fitted on the golden set', () {
      expect(DecisionPolicy.gateDrop, 0.70);
      expect(DecisionPolicy.needsYouYes, 0.65);
      expect(DecisionPolicy.needsYouYesCold, 0.85);
      expect(DecisionPolicy.needsYouNo, 0.35);
      expect(DecisionPolicy.booleanYes, 0.50);
      expect(DecisionPolicy.replyYes, 0.50);
    });
  });

  group('learnedGateReason', () {
    test('keeps below the bar', () {
      expect(
        learnedGateReason(
            fakeAnswers(gateDrop: 0.69, dropReason: 'newsletter')),
        isNull,
      );
    });

    test('drops at the bar, under the reason word', () {
      expect(
        learnedGateReason(fakeAnswers(gateDrop: 0.70, dropReason: 'digest')),
        'digest',
      );
    });

    test('never gates cold outreach', () {
      expect(
        learnedGateReason(
            fakeAnswers(gateDrop: 0.99, dropReason: 'cold_outreach')),
        isNull,
      );
    });

    test('maps every drop reason, and other to model_other', () {
      const expected = {
        'newsletter': 'newsletter',
        'no_reply': 'no_reply',
        'auto_generated': 'auto_generated',
        'monitoring': 'monitoring',
        'ticket_system': 'ticket_system',
        'identity_service': 'identity_service',
        'share_notification': 'share_notification',
        'machine_sender': 'machine_sender',
        'digest': 'digest',
        'outbound': 'outbound',
        'empty': 'empty',
        'other': 'model_other',
      };
      for (final reason in decisionOptions['drop_reason']!) {
        if (reason == 'cold_outreach') continue;
        expect(
          learnedGateReason(fakeAnswers(gateDrop: 0.9, dropReason: reason)),
          expected[reason],
          reason: reason,
        );
      }
    });

    test('every word it can write has a label a person can read', () {
      for (final reason in decisionOptions['drop_reason']!) {
        final word =
            learnedGateReason(fakeAnswers(gateDrop: 0.9, dropReason: reason));
        if (word == null) continue;
        expect(homeDropLabels, contains(word), reason: word);
      }
      expect(homeDropLabel('model_other'), 'Automated');
      expect(homeDropLabel('identity_service'), 'Sign-in notice');
    });

    test('the machine senders nobody replies to suppress a reply', () {
      for (final word in [
        'ticket_system',
        'identity_service',
        'share_notification',
        'digest',
      ]) {
        expect(automatedGateReasons, contains(word));
      }
      expect(automatedGateReasons, isNot(contains('model_other')));
    });
  });

  group('needsYouYesReason', () {
    test('reads the intent first', () {
      expect(needsYouYesReason(fakeAnswers(intent: 'approval')),
          'Asks you to approve something.');
      expect(needsYouYesReason(fakeAnswers(intent: 'question')),
          'Asks you a question.');
      expect(needsYouYesReason(fakeAnswers(intent: 'request')),
          'Asks you to do something.');
      expect(needsYouYesReason(fakeAnswers(intent: 'scheduling')),
          'Asks you about a time.');
    });

    test('then whether a reply is expected', () {
      expect(
        needsYouYesReason(fakeAnswers(intent: 'fyi', replyExpected: 0.5)),
        'Expects a reply from you.',
      );
    });

    test('and otherwise names the owner', () {
      expect(
        needsYouYesReason(fakeAnswers(intent: 'social', replyExpected: 0.49)),
        'Names you and needs your attention.',
      );
    });

    test('the no reason', () {
      expect(needsYouNoReason, 'Nothing here asks for you.');
    });
  });
}
