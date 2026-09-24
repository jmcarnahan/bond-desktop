import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/services/label_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one authority on what a standing rule matches, table-tested.
///
/// Pure, so there is no database here and no clock: every case is a list of
/// rules and one message's fields. Three callers ask this question — the triage
/// gate about arriving mail, the needs-you pass about a message it is judging,
/// and `MessageStore.applyLabelRule` about the mail already stored — and the
/// whole reason the function exists is that they must get the same answer.

void main() {
  /// A rule over one scope, with the defaults every case but its own ignores.
  LabelRule ruleOn(
    String kind,
    String value, {
    String id = 'rule-1',
    String labelId = 'later-aaaa',
    String disposition = LabelRule.hideNeedsYou,
  }) =>
      LabelRule(
        id: id,
        labelId: labelId,
        scopeKind: kind,
        // Folded on the way into the store, so a rule in hand is already
        // lowercased — see `MessageStore.labelRuleScopeKey`.
        scopeValue: value.toLowerCase(),
        disposition: disposition,
      );

  group('sender scope', () {
    test('matches one mailbox, whatever the casing on either side', () {
      final rules = [ruleOn(LabelRule.scopeSender, 'alerts@tracker.example.com')];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'Alerts@Tracker.Example.com',
        )?.id,
        'rule-1',
      );
    });

    test('a different mailbox at the same domain is a different mailbox', () {
      final rules = [ruleOn(LabelRule.scopeSender, 'alex@example.com')];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'alex@eu.example.com',
        ),
        isNull,
      );
    });

    test('no sender at all matches nothing', () {
      final rules = [ruleOn(LabelRule.scopeSender, 'alex@example.com')];

      expect(matchLabelRule(rules, source: 'email'), isNull);
      expect(
        matchLabelRule(rules, source: 'email', senderAddress: '  '),
        isNull,
      );
    });
  });

  group('domain scope', () {
    test('matches the domain itself and any subdomain of it', () {
      final rules = [ruleOn(LabelRule.scopeDomain, 'example.com')];

      for (final address in [
        'alex@example.com',
        'noreply@mail.example.com',
        'ci@builds.eu.example.com',
      ]) {
        expect(
          matchLabelRule(rules, source: 'email', senderAddress: address)?.id,
          'rule-1',
          reason: address,
        );
      }
    });

    test('a domain that merely ends with the same letters does not match', () {
      final rules = [ruleOn(LabelRule.scopeDomain, 'example.com')];

      // The leading dot in the suffix test is the whole of this case: without
      // it, a rule about one organisation would quietly cover another whose
      // name happens to end the same way.
      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'sales@notexample.com',
        ),
        isNull,
      );
    });

    test('a Teams sender cannot match a domain rule', () {
      final rules = [ruleOn(LabelRule.scopeDomain, 'example.com')];

      // Chat addresses are `teams:<id>` with no `@` in them, which is why the
      // matcher needs no `source` test of its own.
      expect(
        matchLabelRule(
          rules,
          source: 'teams',
          senderAddress: 'teams:19:chat-id-example.com',
        ),
        isNull,
      );
    });

    test('an address with nothing after the @ matches nothing', () {
      final rules = [ruleOn(LabelRule.scopeDomain, 'example.com')];

      expect(
        matchLabelRule(rules, source: 'email', senderAddress: 'broken@'),
        isNull,
      );
    });
  });

  group('subject scope', () {
    test('matches a prefix, case-insensitively', () {
      final rules = [ruleOn(LabelRule.scopeSubject, 'Accepted:')];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          subject: 'ACCEPTED: Quarterly planning',
        )?.id,
        'rule-1',
      );
    });

    test('a prefix in the middle of a subject is not a prefix', () {
      final rules = [ruleOn(LabelRule.scopeSubject, 'Accepted:')];

      // A reply quoting the subject is the case this refuses: `Re: Accepted: …`
      // is somebody talking about the response, not the response.
      expect(
        matchLabelRule(
          rules,
          source: 'email',
          subject: 'Re: Accepted: Quarterly planning',
        ),
        isNull,
      );
    });
  });

  group('classification scope', () {
    test('matches the string the caller computed, exactly', () {
      final rules = [ruleOn(LabelRule.scopeClassification, 'meeting_response')];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          classification: 'meeting_response',
        )?.id,
        'rule-1',
      );
      expect(
        matchLabelRule(
          rules,
          source: 'email',
          classification: 'tracker_notification',
        ),
        isNull,
      );
    });

    test('a caller that cannot name the kind matches no such rule', () {
      final rules = [ruleOn(LabelRule.scopeClassification, 'meeting_response')];

      // What a build with no classifier wired hands over, and what it must read
      // as: the sender and domain rules still work, this one simply sleeps.
      expect(matchLabelRule(rules, source: 'email'), isNull);
    });
  });

  group('precedence', () {
    test('sender beats domain beats subject beats classification', () {
      final rules = [
        ruleOn(LabelRule.scopeClassification, 'meeting_response', id: 'r-class'),
        ruleOn(LabelRule.scopeSubject, 'accepted:', id: 'r-subject'),
        ruleOn(LabelRule.scopeDomain, 'example.com', id: 'r-domain'),
        ruleOn(LabelRule.scopeSender, 'alex@example.com', id: 'r-sender'),
      ];

      String? winner(List<LabelRule> from) => matchLabelRule(
            from,
            source: 'email',
            senderAddress: 'alex@example.com',
            subject: 'Accepted: Quarterly planning',
            classification: 'meeting_response',
          )?.id;

      expect(winner(rules), 'r-sender');
      expect(winner(rules.sublist(0, 3)), 'r-domain');
      expect(winner(rules.sublist(0, 2)), 'r-subject');
      expect(winner(rules.sublist(0, 1)), 'r-class');
    });

    test('the answer does not depend on the order the rules came back in', () {
      final rules = [
        ruleOn(LabelRule.scopeDomain, 'example.com', id: 'r-domain'),
        ruleOn(LabelRule.scopeSender, 'alex@example.com', id: 'r-sender'),
      ];

      expect(
        matchLabelRule(
          rules.reversed.toList(),
          source: 'email',
          senderAddress: 'alex@example.com',
        )?.id,
        'r-sender',
      );
    });

    test('within one kind the longer scope wins', () {
      final rules = [
        ruleOn(LabelRule.scopeDomain, 'example.com', id: 'r-wide'),
        ruleOn(LabelRule.scopeDomain, 'eu.example.com', id: 'r-narrow'),
      ];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'ci@eu.example.com',
        )?.id,
        'r-narrow',
      );
    });

    test('an exact tie is broken the same way every time', () {
      final rules = [
        ruleOn(LabelRule.scopeSubject, 'bbbbbbbb:', id: 'r-b'),
        ruleOn(LabelRule.scopeSubject, 'aaaaaaaa:', id: 'r-a'),
      ];

      // Two rules of the same kind and the same length cannot both match a real
      // subject, so this is about the tie-break being deterministic rather than
      // about which of two prefixes is more specific.
      expect(
        matchLabelRule(rules, source: 'email', subject: 'aaaaaaaa:')?.id,
        'r-a',
      );
    });
  });

  group('degenerate rows', () {
    test('an empty rule list is null, not a throw', () {
      expect(
        matchLabelRule(const [], source: 'email', senderAddress: 'a@b.example.com'),
        isNull,
      );
    });

    test('a scope kind this build does not know is inert', () {
      final rules = [ruleOn('display_name', 'Alex Rivera')];

      // The scope set is open — `context_links.scope_kind` is the precedent — so
      // a rule written by a later build must do nothing here rather than throw
      // inside a drain.
      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'alex@example.com',
          senderName: 'Alex Rivera',
        ),
        isNull,
      );
    });

    test('a rule with an empty scope value matches nothing', () {
      final rules = [ruleOn(LabelRule.scopeSender, '')];

      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'alex@example.com',
        ),
        isNull,
      );
    });

    test('the exception flag is not the matcher business', () {
      final rules = [
        LabelRule(
          id: 'rule-1',
          labelId: 'later-aaaa',
          scopeKind: LabelRule.scopeSender,
          scopeValue: 'alerts@tracker.example.com',
          disposition: LabelRule.hideNeedsYou,
          unlessMentionsMe: false,
        ),
      ];

      // A rule MATCHES either way; what the exception costs is spent through
      // the needs-you floor by the callers.
      expect(
        matchLabelRule(
          rules,
          source: 'email',
          senderAddress: 'alerts@tracker.example.com',
        )?.unlessMentionsMe,
        isFalse,
      );
    });
  });
}
