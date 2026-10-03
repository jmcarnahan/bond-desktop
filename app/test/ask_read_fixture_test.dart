import 'package:bond_inbox/services/calendar/ask_hints.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/llm/ask_read_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/ask_reads.dart';

/// The ask-reading fixture offline (docs/pipeline/14-calendar.md "Reading
/// the ask", the eval): it is well-formed and fictional, the RULES reader's
/// score over it is printed — never asserted, the repo's rule for a score —
/// and a hand-written perfect model reading of the hard rows resolves to
/// exactly what the fixture expects, which pins the resolution layer the
/// live eval (`make ask-read-eval`) leans on.
void main() {
  setUpAll(initCalendarZones);

  final cases = loadAskCases();

  test('the fixture is well-formed and fictional', () {
    expect(cases, hasLength(40));
    expect(cases.map((c) => c.id).toSet(), hasLength(40),
        reason: 'ids are unique');
    const keys = {'id', 'subject', 'body', 'sent_at', 'now', 'zone', 'expect'};
    const expectKeys = {'days', 'start', 'end', 'minutes', 'none'};
    // Anchored: the fictional name must BE the registered domain, so
    // `example.evil.com` fails.
    final hygiene = RegExp(
        r'^(?:[\w-]+\.)*(?:example|northwind|fabrikam|contoso|'
        r'adventure-?works|acme|fake|dummy|placeholder)\.'
        r'(?:com|org|net|example)$',
        caseSensitive: false);
    expect('example.evil.com', isNot(matches(hygiene)));
    expect('news.contoso.com', matches(hygiene));
    final hosts = RegExp(r'(?:@|https?://)([A-Za-z0-9.-]*[A-Za-z0-9])');
    for (final c in cases) {
      expect(c.json.keys.toSet().containsAll(keys), isTrue, reason: c.id);
      expect(c.expected.keys.toSet(), expectKeys, reason: c.id);
      expect(CalendarZone.tryNamed(c.json['zone'] as String), isNotNull,
          reason: c.id);
      c.sentAt;
      c.now;
      for (final m in hosts.allMatches('${c.subject}\n${c.body}')) {
        expect(m.group(1)!, matches(hygiene),
            reason: '${c.id}: ${m.group(1)} is not a fictional host');
      }
      if (c.expected['none'] == true) {
        expect(c.expected['days'], isEmpty, reason: c.id);
        expect(c.expected['start'], isNull, reason: c.id);
        expect(c.expected['minutes'], isNull, reason: c.id);
      }
    }
  });

  test('the rules reader scores the fixture', () {
    var right = 0;
    final misses = <String>[];
    for (final c in cases) {
      final hints = c.rules();
      expect(hints, isA<AskHints>(), reason: c.id);
      final got = askOutcome(hints);
      if (got == c.want) {
        right += 1;
      } else {
        misses.add('  miss ${c.id}: got $got want ${c.want}');
      }
    }
    // Printed, never asserted: a score is a measurement, not a gate.
    // ignore: avoid_print
    print(['rules: $right/${cases.length}', ...misses].join('\n'));
  });

  test('a perfect reading resolves the hard rows', () {
    // What a model that copies perfectly hands back for each.
    const perfect = {
      'monday-not-friday': AskRead(asksForTime: true, when: ['Monday']),
      'two-days-afternoon': AskRead(
          asksForTime: true,
          when: ['next Tuesday', 'next Thursday'],
          time: 'afternoon'),
      'next-week-afternoon': AskRead(
          asksForTime: true, when: ['next week'], time: 'in the afternoon'),
      'quick-call-tomorrow': AskRead(
          asksForTime: true, when: ['tomorrow'], duration: '20 min'),
      'newsletter-none': AskRead(),
    };
    for (final MapEntry(key: id, value: read) in perfect.entries) {
      final c = cases.singleWhere((c) => c.id == id);
      final hints = readAskHintsFromRead(
        read: read,
        subject: c.subject,
        body: c.body,
        now: c.now,
        zone: c.zone,
        sentAt: c.sentAt,
      );
      expect(askOutcome(hints), c.want, reason: id);
    }
  });
}
