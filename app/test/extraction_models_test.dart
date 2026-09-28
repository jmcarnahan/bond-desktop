import 'dart:convert';

import 'package:bond_inbox/models/extraction_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ExtractionResult`, the decoded `message_ai.extraction_json`. New rows are
/// `{topics, project, intent, importance}`; rows an older build wrote also
/// carry the retired extraction call's evidence, people and organizations.
void main() {
  test('a new row round-trips through its stored form', () {
    const result = ExtractionResult(
      topics: ['launch date'],
      project: 'Website redesign',
      intent: 'request',
      importance: 'high',
    );

    final back = ExtractionResult.fromJson(
      jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
    );
    expect(back.toJson(), result.toJson());
    expect(back.evidence, '');
    expect(back.people, isEmpty);
    expect(back.organizations, isEmpty);
  });

  test('toJson leaves out empty evidence, people and organizations', () {
    const result = ExtractionResult(
      topics: [],
      project: '',
      intent: 'fyi',
      importance: 'normal',
    );

    expect(result.toJson().keys.toSet(),
        {'topics', 'project', 'intent', 'importance'});
  });

  test("an old row's evidence, people and organizations are read and kept",
      () {
    final old = ExtractionResult.fromJson(const {
      'evidence': 'Sarah is asking whether the launch holds.',
      'topics': ['launch date'],
      'people': ['Sarah Chen'],
      'organizations': ['Northline'],
      'project': 'Website redesign',
      'intent': 'question',
      'importance': 'normal',
    });

    expect(old.evidence, 'Sarah is asking whether the launch holds.');
    expect(old.people, ['Sarah Chen']);
    expect(old.organizations, ['Northline']);
    expect(old.toJson()['evidence'], old.evidence);
    expect(old.toJson()['people'], ['Sarah Chen']);
    expect(old.toJson()['organizations'], ['Northline']);
  });

  test('a sparse or odd blob reads the quiet middle, never throws', () {
    final r = ExtractionResult.fromJson(const {'topics': 'not a list'});
    expect(r.topics, isEmpty);
    expect(r.project, '');
    expect(r.intent, 'fyi');
    expect(r.importance, 'normal');
    expect(ExtractionResult.fallback().toJson(),
        ExtractionResult.fromJson(const {}).toJson());
  });
}
