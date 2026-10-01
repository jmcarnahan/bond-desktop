import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/reply_policy.dart'
    show automatedGateReasons;
import 'package:bond_inbox/widgets/home_result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';

void main() {
  group('the constants', () {
    test('are the values fitted on the golden set', () {
      expect(DecisionPolicy.gateDrop, 0.70);
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

    test('learnedGateReasons is exactly the words it can write', () {
      final written = <String>{
        for (final reason in decisionOptions['drop_reason']!)
          ?learnedGateReason(fakeAnswers(gateDrop: 0.9, dropReason: reason)),
      };
      expect(learnedGateReasons, written);
      // The owner's Ignore is never the model's word.
      expect(learnedGateReasons, isNot(contains('user')));
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

    test("the owner's answer is worded before any intent", () {
      final model = fakeAnswers(intent: 'approval', needsYou: 0.9);
      expect(needsYouYesReason(model.withNeedsYou('no')),
          'You removed a message like this from Needs You.');
      expect(needsYouYesReason(model.withNeedsYou('no', exact: true)),
          'You removed this message from Needs You.');
      expect(needsYouYesReason(model.withNeedsYou('yes')),
          'You added a message like this to Needs You.');
      expect(needsYouYesReason(model.withNeedsYou('yes', exact: true)),
          'You added this message to Needs You.');
    });

    test("the owner's answer survives the stored blob's round trip", () {
      final json = {
        ...fakeAnswers(needsYou: 0.9).withNeedsYou('no').toJson(),
        'owner_known': true,
        'owner_answer': 'no',
        'owner_label_id': 3,
        'owner_cosine': 0.99,
        'owner_exact': false,
      };
      final back = DecisionAnswers.fromJson(json);
      expect(back.fields.keys, isNot(contains('owner_answer')));
      expect(back.ownerAnswer, 'no');
      expect(back.ownerExact, isFalse);
      expect(back.p('needs_you', 'yes'), 0.0);
      expect(needsYouYesReason(back),
          'You removed a message like this from Needs You.');
      expect(DecisionAnswers.fromJson(fakeAnswers().toJson()).ownerAnswer,
          isNull);
    });

    test('needsYouP is the decision\'s p(yes), or null with no head', () {
      expect(needsYouP(fakeAnswers(needsYou: 0.37)), closeTo(0.37, 1e-9));
      expect(needsYouP(DecisionAnswers(const {})), isNull);
    });
  });
}
