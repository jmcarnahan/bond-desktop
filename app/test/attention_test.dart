import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/attention.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every score below is computed at [now], so nothing here depends on the day
/// the suite runs.
final DateTime _now = DateTime.utc(2026, 8, 29, 12);

Conversation _conv({
  ConversationState state = ConversationState.needsReply,
  CtaUrgency urgency = CtaUrgency.normal,
  DateTime? lastMessageAt,
  String? lastMessageRaw,
}) {
  return Conversation(
    id: 'c1',
    state: state,
    ctaUrgency: urgency,
    lastMessageAt:
        lastMessageRaw ?? (lastMessageAt ?? _now).toUtc().toIso8601String(),
  );
}

double _score({
  ConversationState state = ConversationState.needsReply,
  CtaUrgency urgency = CtaUrgency.normal,
  String? intent,
  double replyRate = 0,
  String? senderPref,
  DateTime? lastMessageAt,
  String? lastMessageRaw,
  bool? replyExpected,
  bool? needsAction,
  String? deadline,
  bool addressedMe = false,
}) {
  return attentionScore(
    conversation: _conv(
      state: state,
      urgency: urgency,
      lastMessageAt: lastMessageAt,
      lastMessageRaw: lastMessageRaw,
    ),
    latestIntent: intent,
    senderReplyRate: replyRate,
    senderPref: senderPref,
    latestReplyExpected: replyExpected,
    latestNeedsAction: needsAction,
    latestDeadline: deadline,
    addressedMe: addressedMe,
    now: _now,
  );
}

void main() {
  group('hard zeros', () {
    test('a later sender scores nothing, however loud the thread', () {
      expect(
        _score(urgency: CtaUrgency.urgent, intent: 'request', senderPref: 'later'),
        0,
      );
    });

    test('a done thread scores nothing', () {
      expect(_score(state: ConversationState.done), 0);
    });

    test('a later sender beats a done check — both are zero anyway', () {
      expect(
        _score(state: ConversationState.done, senderPref: 'later'),
        0,
      );
    });
  });

  group('base by state', () {
    test('needs reply is the unit', () {
      expect(_score(), closeTo(AttentionTuning.needsReplyBase, 1e-9));
    });

    test('waiting starts well below it', () {
      expect(
        _score(state: ConversationState.waiting),
        closeTo(AttentionTuning.waitingBase, 1e-9),
      );
    });
  });

  group('urgency multipliers', () {
    test('urgent multiplies by 1.5', () {
      expect(_score(urgency: CtaUrgency.urgent), closeTo(1.5, 1e-9));
    });

    test('high multiplies by 1.2', () {
      expect(_score(urgency: CtaUrgency.high), closeTo(1.2, 1e-9));
    });

    test('normal and low both leave the base alone', () {
      // `low` deliberately does not discount: a thread the user owes a reply on
      // is still theirs to answer however unhurried the ask reads.
      expect(_score(urgency: CtaUrgency.normal), closeTo(1.0, 1e-9));
      expect(_score(urgency: CtaUrgency.low), closeTo(1.0, 1e-9));
    });
  });

  group('question bonus by intent', () {
    for (final intent in AttentionTuning.askingIntents) {
      test('$intent earns the bonus', () {
        expect(
          _score(intent: intent),
          closeTo(1.0 + AttentionTuning.questionBonus, 1e-9),
        );
      });
    }

    for (final intent in ['fyi', 'transactional', 'social', 'scheduling']) {
      test('$intent does not', () {
        expect(_score(intent: intent), closeTo(1.0, 1e-9));
      });
    }

    test('no extraction yet earns nothing and throws nothing', () {
      expect(_score(intent: null), closeTo(1.0, 1e-9));
    });

    test('an intent nobody has heard of earns nothing', () {
      expect(_score(intent: 'wharrgarbl'), closeTo(1.0, 1e-9));
    });
  });

  group('sender reply rate', () {
    test('a fully-answered sender adds the whole allowance', () {
      expect(
        _score(replyRate: 1),
        closeTo(1.0 + AttentionTuning.replyRateMax, 1e-9),
      );
    });

    test('half answered adds half of it', () {
      expect(
        _score(replyRate: 0.5),
        closeTo(1.0 + AttentionTuning.replyRateMax / 2, 1e-9),
      );
    });

    test('a rate outside 0..1 is clamped rather than trusted', () {
      expect(
        _score(replyRate: 40),
        closeTo(1.0 + AttentionTuning.replyRateMax, 1e-9),
      );
      expect(_score(replyRate: -5), closeTo(1.0, 1e-9));
    });
  });

  group('recency decay', () {
    test('a thread halves after exactly one half-life', () {
      expect(AttentionTuning.recencyHalfLifeDays, 7,
          reason: 'the durations below are written in days');
      expect(
        _score(lastMessageAt: _now.subtract(const Duration(days: 7))),
        closeTo(0.5, 1e-9),
      );
    });

    test('and quarters after two', () {
      expect(
        _score(lastMessageAt: _now.subtract(const Duration(days: 14))),
        closeTo(0.25, 1e-9),
      );
    });

    test('a thread that just landed does not decay at all', () {
      expect(_score(lastMessageAt: _now), closeTo(1.0, 1e-9));
    });

    test('a timestamp in the future does not boost anything either', () {
      // Clock skew between the mail server and the laptop is routine, and it
      // must never be able to rank a thread above one that just arrived.
      expect(
        _score(lastMessageAt: _now.add(const Duration(days: 30))),
        closeTo(1.0, 1e-9),
      );
    });

    test('an unparseable timestamp does not decay — it does not zero out', () {
      // The failure this guards: a metadata bug scoring real mail to the
      // bottom, where nobody would ever see it.
      expect(_score(lastMessageRaw: 'not a date'), closeTo(1.0, 1e-9));
      expect(_score(lastMessageRaw: ''), closeTo(1.0, 1e-9));
    });

    test('a null timestamp behaves the same way', () {
      expect(
        attentionScore(
          conversation: const Conversation(id: 'c1'),
          now: _now,
        ),
        closeTo(AttentionTuning.waitingBase, 1e-9),
      );
    });
  });

  group('keep boost', () {
    test('a kept sender is multiplied, not floored', () {
      expect(
        _score(senderPref: 'keep'),
        closeTo(1.0 * AttentionTuning.keepBoost, 1e-9),
      );
    });

    test('a kept sender on an old thread still decays', () {
      // The point of a boost over a floor: the user said the sender matters, not
      // that a month-old message from them outranks this morning's question.
      expect(
        _score(
          senderPref: 'keep',
          lastMessageAt: _now.subtract(const Duration(days: 7)),
        ),
        closeTo(0.5 * AttentionTuning.keepBoost, 1e-9),
      );
    });

    test('no rule at all leaves the score alone', () {
      expect(_score(senderPref: null), closeTo(1.0, 1e-9));
    });
  });

  group('the quiet FYI temper', () {
    /// The shape the temper is written for: a thread the state machine calls
    /// needs-reply because an inbound message went unanswered, which triage
    /// then read as nobody actually waiting.
    double quiet({
      String? intent = 'fyi',
      double replyRate = 0,
      CtaUrgency urgency = CtaUrgency.normal,
      bool? replyExpected = false,
      bool? needsAction = false,
      String? deadline,
      String? senderPref,
      bool addressedMe = false,
    }) =>
        _score(
          intent: intent,
          replyRate: replyRate,
          urgency: urgency,
          replyExpected: replyExpected,
          needsAction: needsAction,
          deadline: deadline,
          senderPref: senderPref,
          addressedMe: addressedMe,
        );

    test('drops a needs-reply thread to the waiting base', () {
      expect(quiet(), closeTo(AttentionTuning.waitingBase, 1e-9));
      expect(quiet(), lessThan(AttentionTuning.defaultThreshold),
          reason: 'the whole point: it leaves Needs You');
    });

    test('the temper skips the reply-rate bonus', () {
      // The regression this exists for. 0.35 + 0.2 = 0.55 would put a
      // well-answered sender's FYI straight back over the 0.5 threshold — the
      // exact thread the temper is quieting.
      expect(quiet(replyRate: 1), closeTo(0.35, 1e-9));
      expect(quiet(replyRate: 1), lessThan(AttentionTuning.defaultThreshold));
    });

    test('a never-judged thread is not tempered', () {
      // NULL means triage v2 never looked. Only a positive "no reply wanted"
      // tempers; absence of evidence scores exactly as it did before v2.
      expect(quiet(replyExpected: null), closeTo(1.0, 1e-9));
      expect(quiet(replyExpected: null, replyRate: 1), closeTo(1.2, 1e-9));
    });

    test('and neither is one triage said a reply IS expected', () {
      expect(quiet(replyExpected: true), closeTo(1.0, 1e-9));
    });

    test('a named deadline blocks the temper', () {
      expect(quiet(deadline: 'by Friday'), closeTo(1.0, 1e-9));
      // An empty deadline is the store's "named none" and does not block it.
      expect(quiet(deadline: ''), closeTo(0.35, 1e-9));
    });

    test('a needed action blocks it', () {
      expect(quiet(needsAction: true), closeTo(1.0, 1e-9));
      // Unjudged needs_action does not block — only a positive one does.
      expect(quiet(needsAction: null), closeTo(0.35, 1e-9));
    });

    test('transactional tempers the same way fyi does', () {
      for (final intent in AttentionTuning.quietIntents) {
        expect(quiet(intent: intent), closeTo(0.35, 1e-9),
            reason: '$intent is a quiet intent');
      }
    });

    test('an asking intent never tempers, whatever triage said', () {
      // Asking and quiet intents are disjoint sets, which is why the question
      // bonus needs no guard of its own.
      for (final intent in AttentionTuning.askingIntents) {
        expect(quiet(intent: intent), closeTo(1.25, 1e-9),
            reason: '$intent still earns the question bonus off the full base');
      }
      expect(
        AttentionTuning.askingIntents
            .intersection(AttentionTuning.quietIntents),
        isEmpty,
      );
    });

    test('an unextracted thread is not tempered', () {
      // No intent means nothing read the message. Triage's reply_expected
      // alone is not enough to quiet a thread.
      expect(quiet(intent: null), closeTo(1.0, 1e-9));
    });

    test('urgency still applies through the temper', () {
      // Deliberate, and the conservative failure: a thread triage rated urgent
      // clears the threshold at 0.525 and stays in Needs You. Showing one
      // quiet thread too many beats hiding an urgent one.
      expect(quiet(urgency: CtaUrgency.urgent), closeTo(0.525, 1e-9));
      expect(
        quiet(urgency: CtaUrgency.urgent),
        greaterThan(AttentionTuning.defaultThreshold),
      );
      // `high` does not rescue it.
      expect(quiet(urgency: CtaUrgency.high), closeTo(0.42, 1e-9));
    });

    test('a keep sender does not rescue a tempered thread either', () {
      expect(quiet(senderPref: 'keep'), closeTo(0.4375, 1e-9));
      expect(
        quiet(senderPref: 'keep'),
        lessThan(AttentionTuning.defaultThreshold),
      );
    });

    test('a waiting thread is unaffected — it was already at that base', () {
      expect(
        _score(state: ConversationState.waiting, intent: 'fyi',
            replyExpected: false, needsAction: false),
        closeTo(AttentionTuning.waitingBase, 1e-9),
      );
    });
  });

  group('direct boost', () {
    test('a message addressed to the user alone is multiplied', () {
      expect(
        _score(addressedMe: true, replyExpected: true),
        closeTo(1.0 * AttentionTuning.directBoost, 1e-9),
      );
    });

    test('and one triage has never judged is boosted too', () {
      // `!= false`, not `== true`: a direct message nobody has ruled on is
      // exactly the message this rule exists to not miss.
      expect(
        _score(addressedMe: true, replyExpected: null),
        closeTo(1.25, 1e-9),
      );
    });

    test('only an explicit "no reply wanted" declines it', () {
      // Tempered rather than boosted, and the two are mutually exclusive by
      // construction: the temper requires the same explicit false.
      expect(
        _score(
          addressedMe: true,
          replyExpected: false,
          needsAction: false,
          intent: 'fyi',
        ),
        closeTo(0.35, 1e-9),
      );
    });

    test('not being addressed leaves the score alone', () {
      expect(_score(addressedMe: false, replyExpected: true), closeTo(1.0, 1e-9));
    });

    test('it stacks with keep and still respects the ceiling', () {
      // 1.0 × 1.25 × 1.25 = 1.5625, under the clamp.
      expect(
        _score(addressedMe: true, senderPref: 'keep'),
        closeTo(1.5625, 1e-9),
      );
      // Everything at once overshoots to 3.05 and lands on the ceiling.
      expect(
        _score(
          urgency: CtaUrgency.urgent,
          intent: 'request',
          replyRate: 1,
          senderPref: 'keep',
          addressedMe: true,
        ),
        AttentionTuning.maxScore,
      );
    });

    test('a direct message on a dismissed sender is still zero', () {
      // The hard zeros run first and nothing downstream can undo them.
      expect(
        _score(addressedMe: true, senderPref: 'later'),
        0,
      );
    });
  });

  group('clamp', () {
    test('everything at once still lands at the ceiling, not past it', () {
      final score = _score(
        urgency: CtaUrgency.urgent,
        intent: 'request',
        replyRate: 1,
        senderPref: 'keep',
      );
      expect(score, AttentionTuning.maxScore);
    });

    test('nothing ever goes negative', () {
      expect(_score(replyRate: -100), greaterThanOrEqualTo(0));
    });
  });

  group('bucketFor', () {
    test('a later rule defers whatever the model thinks', () {
      expect(
        bucketFor(
          senderPref: 'later',
          intent: 'request',
          importance: 'high',
          needsReply: false,
        ),
        'later',
      );
    });

    test('a keep rule keeps it, whatever the model thinks', () {
      expect(
        bucketFor(
          senderPref: 'keep',
          intent: 'fyi',
          importance: 'low',
          needsReply: false,
        ),
        isNull,
      );
    });

    test('a needs-reply thread is never deferred by the model', () {
      // The one failure this feature cannot afford: hiding work the user is
      // holding up.
      expect(
        bucketFor(intent: 'fyi', importance: 'low', needsReply: true),
        isNull,
      );
    });

    test('but a later RULE still beats needs-reply', () {
      // A person's standing instruction outranks the state machine. They asked.
      expect(
        bucketFor(
          senderPref: 'later',
          intent: 'question',
          importance: 'high',
          needsReply: true,
        ),
        'later',
      );
    });

    test('low importance plus a quiet intent defers', () {
      for (final intent in AttentionTuning.quietIntents) {
        expect(
          bucketFor(intent: intent, importance: 'low', needsReply: false),
          'later',
          reason: '$intent at low importance should defer',
        );
      }
    });

    test('low importance with an asking intent does not', () {
      for (final intent in AttentionTuning.askingIntents) {
        expect(
          bucketFor(intent: intent, importance: 'low', needsReply: false),
          isNull,
          reason: 'someone asking for something is not low value',
        );
      }
    });

    test('a quiet intent at normal or high importance does not', () {
      expect(
        bucketFor(intent: 'fyi', importance: 'normal', needsReply: false),
        isNull,
      );
      expect(
        bucketFor(intent: 'fyi', importance: 'high', needsReply: false),
        isNull,
      );
    });

    test('values nobody recognises fall through to the inbox', () {
      expect(
        bucketFor(intent: 'wharrgarbl', importance: '?', needsReply: false),
        isNull,
      );
    });
  });

  group('bucketReasonFor', () {
    test('names the rule when a rule did it', () {
      expect(bucketReasonFor('later'), 'sender_pref');
    });

    test('and the guess when the model did', () {
      expect(bucketReasonFor(null), 'low_value');
      expect(bucketReasonFor('keep'), 'low_value');
    });
  });
}
