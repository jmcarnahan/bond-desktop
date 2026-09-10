import 'dart:convert';

import 'package:bond_inbox/models/context_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two compiled value classes, and their tolerance.
///
/// Both are read on the draft path and on a settings render, and both decode
/// a column this app wrote. That is exactly the combination where a throw is
/// unacceptable: a row corrupted by hand, or written by a build with a
/// different idea of the shape, must cost a line of a brief rather than the
/// render around it.
void main() {
  group('ContextFileDigest', () {
    const digest = ContextFileDigest(
      purpose: 'Works out what the Marrowfield renewal costs.',
      findings: ['The renewal is 2,600 a month.'],
      questionsAnswered: ['What does the renewal cost?'],
      inputs: ['data/rates.csv'],
      kindHint: 'analysis',
    );

    test('round-trips through JSON with every key present', () {
      final json = digest.toJson();
      expect(json.keys.toSet(), {
        'purpose',
        'findings',
        'questions_answered',
        'inputs',
        'kind_hint',
      });

      final back = ContextFileDigest.decode(jsonEncode(json))!;
      expect(back.purpose, digest.purpose);
      expect(back.findings, digest.findings);
      expect(back.questionsAnswered, digest.questionsAnswered);
      expect(back.inputs, digest.inputs);
      expect(back.kindHint, 'analysis');
    });

    test('an empty digest still writes all five keys', () {
      expect(const ContextFileDigest().toJson(), {
        'purpose': '',
        'findings': <String>[],
        'questions_answered': <String>[],
        'inputs': <String>[],
        'kind_hint': 'other',
      });
    });

    test('decode answers null for everything that is not a digest', () {
      expect(ContextFileDigest.decode(null), isNull);
      expect(ContextFileDigest.decode(''), isNull);
      expect(ContextFileDigest.decode('not json at all'), isNull);
      expect(ContextFileDigest.decode('[1, 2, 3]'), isNull);
    });

    test('fromJson drops what is not a string rather than throwing', () {
      final back = ContextFileDigest.decode(
        '{"purpose": 7, "findings": [1, "kept", null], "kind_hint": 3}',
      )!;

      expect(back.purpose, '');
      expect(back.findings, ['kept']);
      expect(back.kindHint, 'other');
    });
  });

  group('ContextBrief', () {
    const brief = ContextBrief(
      about: 'Atlas is where the renewal analysis lives.',
      replyGuidance: ['Keep it short.'],
      keyFacts: ['The renewal is 2,600 a month.'],
      pointers: [(topic: 'Pricing', path: 'analysis/pricing.md')],
      vocabulary: ['Marrowfield'],
    );

    test('round-trips, with pointers as topic and path objects', () {
      final json = brief.toJson();
      expect(json['pointers'], [
        {'topic': 'Pricing', 'path': 'analysis/pricing.md'},
      ]);

      final back = ContextBrief.decode(jsonEncode(json))!;
      expect(back.about, brief.about);
      expect(back.replyGuidance, brief.replyGuidance);
      expect(back.keyFacts, brief.keyFacts);
      expect(back.vocabulary, brief.vocabulary);
      expect(back.pointers.single.topic, 'Pricing');
      expect(back.pointers.single.path, 'analysis/pricing.md');
    });

    test('an empty brief still writes all five keys', () {
      expect(const ContextBrief().toJson().keys.toSet(), {
        'about',
        'reply_guidance',
        'key_facts',
        'pointers',
        'vocabulary',
      });
    });

    test('decode answers null for everything that is not a brief', () {
      expect(ContextBrief.decode(null), isNull);
      expect(ContextBrief.decode(''), isNull);
      expect(ContextBrief.decode('{unterminated'), isNull);
      expect(ContextBrief.decode('"a string"'), isNull);
    });

    test('a half-written pointer is dropped rather than half-rendered', () {
      final back = ContextBrief.decode(
        '{"pointers": [{"topic": "Pricing"}, {"path": "p.md"}, '
        '{"topic": "Rates", "path": "r.md"}, "not a map"]}',
      )!;

      expect(back.pointers, hasLength(1));
      expect(back.pointers.single.topic, 'Rates');
    });

    test('a decoded column meets the same trim and ceiling the task applies',
        () {
      final pointers = <Map<String, String>>[
        {'topic': '  Pricing  ', 'path': '  analysis/pricing.md  '},
        {'topic': '   ', 'path': 'blank.md'},
        for (var i = 0; i < 20; i++)
          {'topic': 'topic $i', 'path': 'p$i.md'},
      ];

      final back = ContextBrief.decode(jsonEncode({'pointers': pointers}))!;

      // A column is not only ever written by this build's validator: an
      // earlier build's row, or a hand-edited one, reaches `decode` having
      // met no ceiling at all, and what comes out of it goes into a prompt.
      expect(back.pointers, hasLength(ContextBrief.maxPointers));
      expect(back.pointers.first.topic, 'Pricing');
      expect(back.pointers.first.path, 'analysis/pricing.md');
      expect(
        [for (final pointer in back.pointers) pointer.path],
        isNot(contains('blank.md')),
      );
    });
  });
}
