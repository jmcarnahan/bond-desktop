import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:flutter_test/flutter_test.dart';

/// The question texts a systemone server is asked are jev-prototype's
/// question set v5, copied byte for byte. The fixture is the handoff file
/// itself (`tmp/questions_v5.json`), never edited by hand; a mismatch here
/// means a Kev server would be asked questions it was not trained on.
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/decision/systemone_questions_v5.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  /// Each question as `[id, instructions, ...options]`, a plain list so
  /// `equals` compares it element by element (a record holding a list
  /// compares that list by identity).
  List<List<String>> read(String key) => [
        for (final q in fixture[key] as List)
          [
            q['id'] as String,
            q['instructions'] as String,
            ...(q['options'] as List).cast<String>(),
          ],
      ];

  test("the file's qhash is the build's", () {
    expect(fixture['qhash'], decisionQhash);
  });

  test('the nine message questions match the file: ids, text, option order',
      () {
    expect(
      [
        for (final q in systemOneMessageQuestions)
          [q.id, q.instructions, ...q.options],
      ],
      read('message'),
    );
  });

  test('the message questions are the heads fields, in head order', () {
    expect([for (final q in systemOneMessageQuestions) q.id], decisionFields);
    for (final q in systemOneMessageQuestions) {
      expect(q.options, decisionOptions[q.id], reason: q.id);
    }
  });

  test('the three storyline questions match the file', () {
    expect(
      [
        for (final q in StorylineQuestion.values)
          [q.id, q.instructions, ...StorylineQuestion.options],
      ],
      read('storyline'),
    );
  });
}
