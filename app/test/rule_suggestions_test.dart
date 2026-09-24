import 'dart:convert';

import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/services/rule_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the app would offer to do about the mail the owner keeps filing by hand
/// — requirement 12d. Every case here is a count of THREADS and a sentence, and
/// nothing in the file stages a database: the rows are arguments.
RuleEvidence _thread(
  String key, {
  String from = 'noreply@jira.example.com',
  String subject = 'BOND-41 updated',
  String? kind,
  String source = 'email',
}) =>
    RuleEvidence(
      source: source,
      conversationKey: key,
      senderAddress: from,
      subject: subject,
      classification: kind,
    );

LabelRule _rule(String kind, String value) => LabelRule(
      id: 'r-$kind-$value',
      labelId: 'fyi',
      scopeKind: kind,
      scopeValue: value,
      disposition: LabelRule.hideNeedsYou,
    );

void main() {
  group('the evidence a row carries', () {
    test('reads the sender, folded, and its domain', () {
      final e = RuleEvidence.fromRow(const {
        'source': 'email',
        'conversation_key': 'c1',
        'from_address': '  NoReply@Jira.Example.com ',
        'subject': 'BOND-41 updated',
      });

      expect(e.senderAddress, 'noreply@jira.example.com');
      expect(e.senderDomain, 'jira.example.com');
      expect(e.threadKey, 'email|c1');
    });

    test('names the kind of mail through the one classifier', () {
      final e = RuleEvidence.fromRow({
        'source': 'email',
        'conversation_key': 'c1',
        'from_address': 'calendar@example.com',
        'subject': 'Accepted: Design review',
        'source_meta_json': jsonEncode({'meeting': 'meetingAccepted'}),
      });

      expect(e.classification, 'meeting_response');
    });

    test('a row with nothing on it groups with nothing', () {
      final e = RuleEvidence.fromRow(const {});

      expect(e.senderAddress, '');
      expect(e.senderDomain, '');
      expect(e.classification, isNull);
      expect(e.subjectPrefix, isNull);
    });

    group('the front of a subject', () {
      String? prefix(String subject) =>
          _thread('c', subject: subject).subjectPrefix;

      test('a bracketed tag at the very start, folded', () {
        expect(prefix('[JIRA] BOND-41 updated'), '[jira]');
      });

      test('a short leading colon', () {
        expect(prefix('Accepted: Design review'), 'accepted:');
      });

      test('a colon in the middle of a sentence is prose', () {
        expect(
          prefix('Could you take a look at this before Friday: the copy'),
          isNull,
        );
      });

      test('and two characters are not a prefix', () {
        expect(prefix('A: yes'), isNull);
        expect(prefix(''), isNull);
      });
    });
  });

  group('suggestRules', () {
    test('three dismissals of one sender is an offer, with the count', () {
      final out = suggestRules(dismissed: [
        _thread('a'),
        _thread('b'),
        _thread('c'),
      ]);

      expect(out.map((s) => s.scopeKind), [LabelRule.scopeSender]);
      expect(out.single.scopeValue, 'noreply@jira.example.com');
      expect(out.single.disposition, LabelRule.hideNeedsYou);
      expect(out.single.threadCount, 3);
      expect(
        out.single.words,
        "You've dismissed 3 threads from noreply@jira.example.com. "
        'Hide these from Needs You in future?',
      );
    });

    test('two is a coincidence and the app says nothing', () {
      final out = suggestRules(dismissed: [_thread('a'), _thread('b')]);

      expect(out, isEmpty);
    });

    test('the same thread dismissed three times is one opinion', () {
      final out = suggestRules(dismissed: [
        _thread('a'),
        _thread('a'),
        _thread('a'),
      ]);

      expect(out, isEmpty);
    });

    test('and one thread per connector is two threads', () {
      final out = suggestRules(dismissed: [
        _thread('a', source: 'email'),
        _thread('a', source: 'teams'),
        _thread('b', source: 'email'),
      ]);

      expect(out.single.threadCount, 3);
    });

    test('a domain offer needs more than one address behind it', () {
      // Three threads from one person is a rule about that person; the domain
      // rule would also cover everyone they work with.
      final narrow = suggestRules(dismissed: [
        _thread('a'),
        _thread('b'),
        _thread('c'),
      ]);
      expect(narrow.map((s) => s.scopeKind), [LabelRule.scopeSender]);

      final wide = suggestRules(dismissed: [
        _thread('a', from: 'bot@jira.example.com'),
        _thread('b', from: 'noreply@jira.example.com'),
        _thread('c', from: 'tickets@jira.example.com'),
      ]);
      expect(wide.map((s) => s.scopeKind), [LabelRule.scopeDomain]);
      expect(wide.single.scopeValue, 'jira.example.com');
    });

    test('a kind of mail reads as words, never as the stored token', () {
      final out = suggestRules(dismissed: [
        _thread('a', from: 'a@example.com', kind: 'tracker_notification'),
        _thread('b', from: 'b@example.com', kind: 'tracker_notification'),
        _thread('c', from: 'c@example.com', kind: 'tracker_notification'),
      ]);

      final kinds = out.where((s) => s.scopeKind == LabelRule.scopeClassification);
      expect(kinds.single.words, contains('3 ticket notifications'));
      expect(kinds.single.words, isNot(contains('tracker_notification')));
    });

    test('a subject prefix is an offer of its own', () {
      final out = suggestRules(dismissed: [
        _thread('a', from: 'a@example.com', subject: '[JIRA] BOND-1 updated'),
        _thread('b', from: 'b@example.com', subject: '[JIRA] BOND-2 updated'),
        _thread('c', from: 'c@example.com', subject: '[JIRA] BOND-3 updated'),
      ]);

      final subjects = out.where((s) => s.scopeKind == LabelRule.scopeSubject);
      expect(subjects.single.scopeValue, '[jira]');
      expect(subjects.single.words, contains("threads starting '[jira]'"));
    });

    test('a rule the owner already has is not offered again', () {
      final evidence = [_thread('a'), _thread('b'), _thread('c')];

      expect(suggestRules(dismissed: evidence), isNotEmpty);
      expect(
        suggestRules(
          dismissed: evidence,
          existing: [_rule(LabelRule.scopeSender, 'noreply@jira.example.com')],
        ),
        isEmpty,
      );
    });

    test('nor one they already answered about the sender', () {
      expect(
        suggestRules(
          dismissed: [_thread('a'), _thread('b'), _thread('c')],
          settledSenders: {'NoReply@Jira.Example.com'},
        ),
        isEmpty,
      );
    });

    test('a "not now" is remembered by the offer\'s own key', () {
      final evidence = [_thread('a'), _thread('b'), _thread('c')];
      final offer = suggestRules(dismissed: evidence).single;

      expect(offer.key, 'hide_needs_you:sender:noreply@jira.example.com');
      expect(
        suggestRules(dismissed: evidence, suppressed: {offer.key}),
        isEmpty,
      );
    });

    test('best evidence first, then the order the matcher would apply', () {
      final out = suggestRules(dismissed: [
        // Four threads from one sender, which is also four on the domain — and
        // the domain has a second address behind it, so both are offered.
        _thread('a'),
        _thread('b'),
        _thread('c'),
        _thread('d', from: 'tickets@jira.example.com'),
        _thread('e', from: 'tickets@jira.example.com'),
        _thread('f', from: 'tickets@jira.example.com'),
      ]);

      expect(
        out.map((s) => '${s.scopeKind}:${s.threadCount}'),
        ['domain:6', 'sender:3', 'sender:3'],
      );
      // Ties on the count fall to the value, so the answer never depends on the
      // order the rows arrived in.
      final senders =
          out.where((s) => s.scopeKind == LabelRule.scopeSender).toList();
      expect(senders.first.scopeValue, 'noreply@jira.example.com');
      expect(senders.last.scopeValue, 'tickets@jira.example.com');
    });

    test('an anonymous row is never a rule about the empty string', () {
      final out = suggestRules(dismissed: [
        _thread('a', from: ''),
        _thread('b', from: ''),
        _thread('c', from: ''),
      ]);

      expect(out, isEmpty);
    });

    group('the reverse offer', () {
      List<RuleEvidence> replies(String from) => [
            _thread('r1', from: from),
            _thread('r2', from: from),
            _thread('r3', from: from),
          ];

      test('three threads the owner answered is an offer to keep them', () {
        final out = suggestRules(
          dismissed: const [],
          kept: replies('alex.rivera@example.com'),
        );

        expect(out.single.disposition, RuleSuggestion.keepInNeedsYou);
        expect(out.single.isLabelRule, isFalse);
        expect(
          out.single.words,
          'You keep coming back to alex.rivera@example.com. '
          'Always keep them in Needs You?',
        );
        expect(out.single.acceptWords, 'Always keep');
      });

      test('senders only: a domain is not a relationship', () {
        final out = suggestRules(
          dismissed: const [],
          kept: [
            _thread('r1', from: 'alex.rivera@example.com'),
            _thread('r2', from: 'dana.okonjo@example.com'),
            _thread('r3', from: 'sam.patel@example.com'),
          ],
        );

        expect(out, isEmpty);
      });

      test('a sender the app is about to offer to hide is left out of both',
          () {
        const who = 'alex.rivera@example.com';
        final out = suggestRules(
          dismissed: [
            _thread('a', from: who),
            _thread('b', from: who),
            _thread('c', from: who),
          ],
          kept: replies(who),
          existing: [_rule(LabelRule.scopeSender, who)],
        );

        expect(out, isEmpty);
      });

      test('but one finished thread among many replies is not a disagreement',
          () {
        const who = 'alex.rivera@example.com';
        final out = suggestRules(
          dismissed: [_thread('a', from: who)],
          kept: replies(who),
        );

        expect(out.single.disposition, RuleSuggestion.keepInNeedsYou);
      });
    });

    test('a threshold of nothing offers nothing', () {
      expect(
        suggestRules(dismissed: [_thread('a')], threshold: 0),
        isEmpty,
      );
    });
  });
}
