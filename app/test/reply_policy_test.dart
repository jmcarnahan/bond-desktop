import 'dart:convert';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/reply_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule in front of every reply path, exercised without a model.

Message inbound() => const Message(
      id: 'm1',
      outbound: false,
      fromName: 'Sarah',
      fromAddress: 'sarah@x.com',
      subject: 'Re: Launch date',
      bodyText: 'Can we still ship on Thursday?',
      receivedAt: '2026-08-29T10:00:00Z',
      addressedMe: true,
    );

void main() {
  /// The one authority three paths ask before offering a reply: the draft queue,
  /// the draft handler, and the composer's Suggest button.
  group('replySuppressed', () {
    /// A stored message carrying only the two fields this reads — the gate's own
    /// word, and the headers the detail fetch wrote.
    Message message({
      String? gateReason,
      Map<String, String>? headers,
      String? gateOverride,
    }) =>
        Message(
          id: 'm1',
          outbound: false,
          fromName: 'Tracker',
          fromAddress: 'notifications@tracker.example.com',
          subject: 'Amina left a comment',
          bodyText: 'View comment <https://tracker.example.com/t/41#c9>',
          gateReason: gateReason,
          gateOverride: gateOverride,
          sourceMetaJson:
              headers == null ? null : jsonEncode({'headers': headers}),
        );

    test('every gate reason that says a machine wrote it', () {
      for (final reason in automatedGateReasons) {
        expect(
          replySuppressed(message(gateReason: reason)),
          isTrue,
          reason: reason,
        );
      }
      expect(automatedGateReasons, hasLength(8));
    });

    test('the gate reasons that say nothing about a reply do not suppress', () {
      // `self`, `sender_rule`, `monitoring` and `machine_sender` all gate mail
      // for reasons that are not about whether an answer is owed, and
      // `teams_source` is not a judgement at all.
      for (final reason in [
        'self',
        'sender_rule',
        'monitoring',
        'machine_sender',
        'teams_source',
        // The decision model's catch-all says no more than `monitoring` does.
        'model_other',
      ]) {
        expect(
          replySuppressed(message(gateReason: reason)),
          isFalse,
          reason: reason,
        );
      }
    });

    test('an ordinary message from a person is not suppressed', () {
      expect(replySuppressed(message()), isFalse);
      expect(replySuppressed(inbound()), isFalse);
    });

    test('headers alone are enough — this is the arm that catches the case', () {
      // The mail in the report: nothing gated it, and triage read the body's
      // polite "please approve" as an ask.
      expect(
        replySuppressed(message(headers: {'Auto-Submitted': 'auto-generated'})),
        isTrue,
      );
      expect(
        replySuppressed(
          message(headers: {'List-Unsubscribe': '<https://x.example.com/u>'}),
        ),
        isTrue,
      );
    });

    test('a message the owner restored is not suppressed by its headers', () {
      // A colleague writing through a team list: gated as a newsletter, then
      // restored. Restore is the escape hatch from every gate, and the
      // classification is the judgement the owner just overruled.
      const list = {'List-Id': 'team.example.com'};
      expect(replySuppressed(message(headers: list)), isTrue);
      expect(
        replySuppressed(message(headers: list, gateOverride: 'user')),
        isFalse,
      );
      // And the column arrives from a stored row.
      expect(
        replySuppressed(Message.fromRow({
          'source_message_id': 'm1',
          'direction': 'inbound',
          'source_meta_json': jsonEncode({'headers': list}),
          'gate_override': 'user',
        })),
        isFalse,
      );
    });

    test('an invite and a tracker mention are deliberately NOT suppressed', () {
      // An invite asks for the reader's time; a tracker's mention is addressed
      // to the person reading it. The same line `gates.dart` draws.
      expect(
        replySuppressed(
          Message(
            id: 'm2',
            outbound: false,
            sourceMetaJson: jsonEncode({'meeting': 'meetingRequest'}),
          ),
        ),
        isFalse,
      );
      // A tracker header AND the list headers on the same message: the tracker
      // arm answers first, and its answer is not a suppression.
      expect(
        replySuppressed(
          message(headers: {
            'X-Jira-Fingerprint': 'f-1',
            'List-Id': 'tracker.example.com',
          }),
        ),
        isFalse,
      );
    });
  });

  /// The reply decision both the draft queue and the draft handler ask.
  group('replyVerdict', () {
    test('a decision below replyYes is a no, with the probability', () {
      final v = replyVerdict(replyExpectedP: 0.123, storedReplyExpected: 1);
      expect(v.skipWhy,
          'The decision model put the chance a reply is expected at 0.12.');
      expect(v.detail, {'decision': 'decision_model', 'reply_p': 0.12});
    });

    test('at or above replyYes is a yes, and the row still says why', () {
      final at = replyVerdict(
        replyExpectedP: DecisionPolicy.replyYes,
        storedReplyExpected: 0,
      );
      expect(at.skipWhy, isNull);
      final above = replyVerdict(replyExpectedP: 0.876, storedReplyExpected: 0);
      expect(above.skipWhy, isNull);
      expect(above.detail, {'decision': 'decision_model', 'reply_p': 0.88});
    });

    test('with no decision, the stored column: 0 is a no', () {
      final v = replyVerdict(replyExpectedP: null, storedReplyExpected: 0);
      expect(v.skipWhy, 'Triage judged no reply is expected.');
      expect(v.detail, {'decision': 'stored'});
    });

    test('and 1 or NULL proceeds', () {
      for (final stored in [1, null]) {
        final v = replyVerdict(replyExpectedP: null, storedReplyExpected: stored);
        expect(v.skipWhy, isNull, reason: '$stored');
        expect(v.detail, {'decision': 'stored'});
      }
    });
  });
}
