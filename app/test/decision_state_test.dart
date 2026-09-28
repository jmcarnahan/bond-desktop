import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart renderer against the states the Python decision service rendered
/// for the same raw fields (`render_cases.json`, 40 fictional cases written by
/// jev-prototype's `distill/export/render_fixtures.py`). Byte for byte: the
/// model was trained on the Python's output, so any difference is a model
/// input nobody measured.

/// Where two strings first differ, and a window of each around it, so a red
/// case says what moved rather than dumping two 4000-character states.
String _firstDifference(String actual, String expected) {
  final n = actual.length < expected.length ? actual.length : expected.length;
  var i = 0;
  while (i < n && actual.codeUnitAt(i) == expected.codeUnitAt(i)) {
    i++;
  }
  String window(String s) {
    final from = i < 40 ? 0 : i - 40;
    final to = i + 40 > s.length ? s.length : i + 40;
    return jsonEncode(s.substring(from, to));
  }

  return 'first difference at UTF-16 index $i '
      '(actual length ${actual.length}, expected ${expected.length})\n'
      '  actual:   ${window(actual)}\n'
      '  expected: ${window(expected)}';
}

DecisionInput _inputFor(Map<String, dynamic> c) {
  final m = c['message'] as Map<String, dynamic>;
  return DecisionInput(
    owner: c['owner'] as String?,
    source: m['source'] as String? ?? 'email',
    fromName: m['from_name'] as String?,
    fromAddress: m['from_address'] as String?,
    subject: m['subject'] as String?,
    receivedAt: m['received_at'] as String?,
    bodyText: m['body_text'] as String?,
    bodyPreview: m['body_preview'] as String?,
    addressedMe: (m['addressed_me'] as num?) == 1,
    toCount: (m['to_count'] as num?)?.toInt() ?? 0,
    attachments: [
      for (final a in (c['attachments'] as List).cast<Map<String, dynamic>>())
        DecisionAttachment(
          name: a['name'] as String?,
          isInline: a['is_inline'] == true,
          cardText: a['card_text'] as String?,
        ),
    ],
    tail: [
      for (final t in (c['tail'] as List).cast<Map<String, dynamic>>())
        DecisionTailItem(
          who: t['who'] as String? ?? '',
          text: t['text'] as String? ?? '',
        ),
    ],
  );
}

void main() {
  final cases = (jsonDecode(
    File('test/fixtures/decision/render_cases.json').readAsStringSync(),
  ) as List)
      .cast<Map<String, dynamic>>();

  test('the fixture carries all forty cases', () {
    expect(cases, hasLength(40));
  });

  group('renderDecisionState matches the Python service', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final offset = (c['utc_offset_minutes'] as num).toInt();
        final actual = renderDecisionState(
          _inputFor(c),
          toLocal: (utc) => utc.add(Duration(minutes: offset)),
        );
        final expected = c['expected_state'] as String;
        if (actual != expected) {
          fail(_firstDifference(actual, expected));
        }
      });
    }
  });

  group('renderDecisionStateFromParts composes as render_state does', () {
    const block = 'From: Ada Park <ada@example.org>\nSubject: Hi\n'
        'Received: 2026-09-15T16:00:00Z\n\nBody:\nhello';

    test('no owner, no tail: date, directness, message', () {
      expect(
        renderDecisionStateFromParts(
          now: '2026-09-15 (Tuesday)',
          directnessLine: 'Addressed to: only you.',
          messageBlock: block,
        ),
        'Today is 2026-09-15 (Tuesday).\n\n'
        'Addressed to: only you.\n\n'
        'The message to judge:\n$block',
      );
    });

    test('an empty owner renders no owner line', () {
      expect(
        renderDecisionStateFromParts(
          owner: '',
          now: 'x',
          directnessLine: 'd',
          messageBlock: 'm',
        ),
        'Today is x.\n\nd\n\nThe message to judge:\nm',
      );
    });

    test('owner and tail, and the tail text is never capped', () {
      final long = 'a' * 500;
      expect(
        renderDecisionStateFromParts(
          owner: 'Sam Rivera <sam@example.org>',
          now: '2026-09-15 (Tuesday)',
          directnessLine: 'Addressed to: you and 2 others.',
          messageBlock: block,
          tail: [
            const DecisionTailItem(who: 'You', text: 'first'),
            const DecisionTailItem(who: 'Ada Park', text: 'second'),
            const DecisionTailItem(who: '', text: 'third'),
            DecisionTailItem(who: 'Lee', text: long),
          ],
        ),
        'The reader, the owner of this inbox, is Sam Rivera '
        '<sam@example.org>. Any mention of that name or address refers to '
        'the reader.\n\n'
        'Today is 2026-09-15 (Tuesday).\n\n'
        'Addressed to: you and 2 others.\n\n'
        'Recent thread before this message, oldest first, for context only:\n'
        'You: first\n---\nAda Park: second\n---\n: third\n---\nLee: $long'
        '\n\n'
        'The message to judge:\n$block',
      );
    });
  });

  group('the edges the fixture does not reach', () {
    test('a stamp that does not parse keeps its first ten characters', () {
      expect(decisionNowAnchor('yesterday afternoon'), 'yesterday ');
      expect(decisionNowAnchor(null), '');
      expect(decisionNowAnchor(''), '');
    });

    test('a naive stamp is read as the wall time it names', () {
      expect(
        decisionNowAnchor(
          '2026-09-15T23:30:00',
          toLocal: (_) => throw StateError('a naive stamp is never converted'),
        ),
        '2026-09-15 (Tuesday)',
      );
    });

    test('an img marker stays, as it did in training', () {
      expect(
        stripDecisionMarkers('see [[att:a1]]  and [[img:i1]]'),
        'see and [[img:i1]]',
      );
    });

    test('a body without a marker is returned untouched', () {
      expect(stripDecisionMarkers('  a   b  \n\n\n\nc '), '  a   b  \n\n\n\nc ');
    });

    test('caps count code points and never split an emoji', () {
      final emoji = '\u{1F600}' * 5;
      expect(cutCodePoints(emoji, 3), '\u{1F600}' * 3);
      expect(cutCodePoints(emoji, 3).runes.length, 3);
    });

    test('Python whitespace, not Dart’s, is stripped', () {
      expect(pythonStrip('\u001Cx\u001F'), 'x');
      expect(pythonStrip('﻿x'), '﻿x');
    });
  });
}
