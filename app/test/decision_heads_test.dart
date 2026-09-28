import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/decision_heads_fixture.dart';

/// Softmax written the naive way, independently of the code under test.
List<double> _softmax(List<double> logits) {
  final exps = [for (final l in logits) math.exp(l)];
  final sum = exps.reduce((a, b) => a + b);
  return [for (final e in exps) e / sum];
}

Matcher _refusal(String words) => isA<LlmFormatException>()
    .having((e) => e.message, 'message', contains(words));

void main() {
  group('apply', () {
    test('softmax of (W·v + b) / T, per field, against hand arithmetic', () {
      final heads = DecisionHeads.fromJson(syntheticHeadsJson(
        biases: {
          'gate': [0.1, -0.2],
          'urgency': [0.0, 0.5, -0.5, 0.25],
        },
        temperatures: {'gate': 0.2, 'urgency': 0.43},
      ));
      final answers = heads.apply(syntheticVector({
        axisOf('gate', 0): 0.3,
        axisOf('gate', 1): 0.1,
        axisOf('urgency', 0): 0.2,
        axisOf('urgency', 2): 1.5,
      }));

      final gate = _softmax([(0.3 + 0.1) / 0.2, (0.1 - 0.2) / 0.2]);
      expect(answers.p('gate', 'keep'), closeTo(gate[0], 1e-9));
      expect(answers.p('gate', 'drop'), closeTo(gate[1], 1e-9));
      expect(answers['gate'].choice, 'keep');
      expect(answers['gate'].confidence, closeTo(gate[0], 1e-9));

      final urgency = _softmax([
        (0.2 + 0.0) / 0.43,
        (0.0 + 0.5) / 0.43,
        (1.5 - 0.5) / 0.43,
        (0.0 + 0.25) / 0.43,
      ]);
      for (final (i, option) in decisionOptions['urgency']!.indexed) {
        expect(answers.p('urgency', option), closeTo(urgency[i], 1e-9),
            reason: option);
      }
      expect(answers['urgency'].choice, 'high');
      expect(answers['urgency'].confidence, closeTo(urgency[2], 1e-9));
    });

    test('every field is answered, and its probabilities sum to one', () {
      final answers = syntheticHeads().apply(syntheticVector({
        axisOf('intent', 4): 2.0,
        axisOf('importance', 2): -1.0,
      }));
      expect(answers.fields.keys, decisionFields);
      for (final field in decisionFields) {
        final probabilities = answers[field].probabilities;
        expect(probabilities.keys, decisionOptions[field]);
        expect(probabilities.values.reduce((a, b) => a + b),
            closeTo(1.0, 1e-12));
      }
      expect(answers['intent'].choice, 'fyi');
    });

    test('a tie goes to the first option', () {
      // Nothing written on category's axes and zero biases: four equal logits.
      final answers = syntheticHeads().apply(syntheticVector());
      expect(answers['category'].choice, 'work');
      expect(answers['category'].confidence, closeTo(0.25, 1e-12));
      // A tie between the second and third, ahead of the first.
      final tied = syntheticHeads().apply(syntheticVector({
        axisOf('urgency', 1): 1.0,
        axisOf('urgency', 2): 1.0,
      }));
      expect(tied['urgency'].choice, 'normal');
    });

    test('a huge logit does not overflow', () {
      final answers = syntheticHeads().apply(syntheticVector({
        axisOf('gate', 1): 5000.0,
      }));
      expect(answers['gate'].choice, 'drop');
      expect(answers.p('gate', 'drop'), 1.0);
      expect(answers.p('gate', 'keep'), 0.0);
    });

    test('a vector of the wrong width is refused', () {
      expect(
        () => syntheticHeads().apply(List.filled(768, 1.0)),
        throwsA(_refusal('768')),
      );
    });

    test('p is 0 for an option the field does not have, and [] throws for a '
        'field it does not answer', () {
      final answers = syntheticHeads().apply(syntheticVector());
      expect(answers.p('gate', 'maybe'), 0);
      expect(() => answers['colour'], throwsArgumentError);
    });
  });

  test('toJson and fromJson round trip', () {
    final answers = syntheticHeads().apply(syntheticVector({
      axisOf('needs_you', 0): 0.7,
      axisOf('drop_reason', 11): 3.0,
    }));
    final json = jsonDecode(jsonEncode(answers.toJson())) as Map<String, Object?>;
    expect((json['needs_you'] as Map)['choice'], 'yes');
    expect(((json['drop_reason'] as Map)['probabilities'] as Map).keys,
        decisionOptions['drop_reason']);

    final back = DecisionAnswers.fromJson(json);
    for (final field in decisionFields) {
      expect(back[field].choice, answers[field].choice);
      expect(back[field].confidence, answers[field].confidence);
      expect(back[field].probabilities, answers[field].probabilities);
    }
  });

  group('fromJson refuses a file it cannot trust', () {
    Map<String, Object?> fieldNamed(Map<String, Object?> json, String name) =>
        (json['fields'] as List)
            .cast<Map<String, Object?>>()
            .firstWhere((f) => f['name'] == name);

    test('the real header is accepted', () {
      final heads = syntheticHeads();
      expect(heads.model, 'bond-decide-synthetic');
      expect(heads.qhash, DecisionHeads.expectedQhash);
      expect(heads.hidden, 1024);
      expect(heads.maxTokens, 2048);
    });

    test('another question set', () {
      expect(
        () => DecisionHeads.fromJson(syntheticHeadsJson(qhash: 'deadbeef')),
        throwsA(_refusal('question set')),
      );
    });

    test('another schema', () {
      expect(
        () => DecisionHeads.fromJson(syntheticHeadsJson(schema: 2)),
        throwsA(_refusal('schema')),
      );
    });

    test('another pooling', () {
      expect(
        () => DecisionHeads.fromJson(syntheticHeadsJson(pooling: 'cls')),
        throwsA(_refusal('pools')),
      );
    });

    test('fields out of order', () {
      final json = syntheticHeadsJson();
      final fields = json['fields'] as List;
      final first = fields[0];
      fields[0] = fields[1];
      fields[1] = first;
      expect(() => DecisionHeads.fromJson(json),
          throwsA(_refusal('out of order')));
    });

    test('a field missing', () {
      final json = syntheticHeadsJson();
      (json['fields'] as List).removeLast();
      expect(() => DecisionHeads.fromJson(json),
          throwsA(_refusal('decision fields')));
    });

    test('options renamed or reordered', () {
      final renamed = syntheticHeadsJson();
      fieldNamed(renamed, 'category')['options'] = [
        'work',
        'personal',
        'notice',
        'other',
      ];
      expect(() => DecisionHeads.fromJson(renamed),
          throwsA(_refusal('options for category')));

      final reordered = syntheticHeadsJson();
      fieldNamed(reordered, 'gate')['options'] = ['drop', 'keep'];
      expect(() => DecisionHeads.fromJson(reordered),
          throwsA(_refusal('options for gate')));
    });

    test('a weight of the wrong shape', () {
      final rows = syntheticHeadsJson();
      (fieldNamed(rows, 'urgency')['weight'] as List).removeLast();
      expect(() => DecisionHeads.fromJson(rows),
          throwsA(_refusal('urgency weight')));

      final width = syntheticHeadsJson();
      ((fieldNamed(width, 'intent')['weight'] as List).first as List)
          .removeLast();
      expect(() => DecisionHeads.fromJson(width),
          throwsA(_refusal('1024 wide')));

      // Through JSON, so the rows are plain lists a string can go into.
      final text = jsonDecode(jsonEncode(syntheticHeadsJson()))
          as Map<String, Object?>;
      ((fieldNamed(text, 'gate')['weight'] as List).first as List)[3] = 'x';
      expect(() => DecisionHeads.fromJson(text),
          throwsA(_refusal('non-number')));
    });

    test('a bias of the wrong length', () {
      final json = syntheticHeadsJson(biases: {
        'importance': [0.0, 0.0],
      });
      expect(() => DecisionHeads.fromJson(json),
          throwsA(_refusal('importance bias')));
    });

    test('a temperature that is not a positive number', () {
      for (final bad in [0.0, -0.3, double.infinity, double.nan]) {
        expect(
          () => DecisionHeads.fromJson(
              syntheticHeadsJson(temperatures: {'needs_you': bad})),
          throwsA(_refusal('needs_you temperature')),
          reason: '$bad',
        );
      }
      final json = syntheticHeadsJson();
      fieldNamed(json, 'gate')['temperature'] = '0.2';
      expect(() => DecisionHeads.fromJson(json),
          throwsA(_refusal('gate temperature')));
    });
  });

  group('load', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('decide-heads'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads a heads file from disk', () async {
      final file = File('${dir.path}/decide-heads.json')
        ..writeAsStringSync(jsonEncode(syntheticHeadsJson()));
      final heads = await DecisionHeads.load(file);
      expect(heads.model, 'bond-decide-synthetic');
    });

    test('a file that is not JSON is a format error', () async {
      final file = File('${dir.path}/decide-heads.json')
        ..writeAsStringSync('not json');
      await expectLater(
          DecisionHeads.load(file), throwsA(isA<LlmFormatException>()));
    });
  });
}
