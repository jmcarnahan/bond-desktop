import 'package:bond_inbox/services/llm/context_digest_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The file-digest prompt, its schema and its validator, with no model.
///
/// Two things are being pinned. The schema has to be one this llama-server
/// build can turn into a grammar — flat, no `$defs`, `maxItems` only on
/// arrays of strings — because a schema it cannot convert fails the request
/// outright rather than being ignored. And `validate` has to survive
/// anything: a grammar guarantees the shape of an answer and nothing about
/// its sense.
void main() {
  const task = ContextDigestTask();
  final now = DateTime(2026, 9, 9);

  ContextDigestInput inputOf({String text = 'The renewal is 2,600 a month.'}) =>
      ContextDigestInput(
        relPath: 'analysis/pricing.md',
        kind: 'doc',
        text: text,
        now: now,
      );

  group('the schema', () {
    test('is flat: no \$defs anywhere in it', () {
      expect(task.schema.containsKey(r'$defs'), isFalse);
      expect(task.schema.toString(), isNot(contains(r'$defs')));
    });

    test('carries maxItems only under arrays of strings', () {
      final properties = task.schema['properties']! as Map<String, dynamic>;
      for (final entry in properties.entries) {
        final property = entry.value as Map<String, dynamic>;
        if (property['type'] != 'array') {
          expect(property.containsKey('maxItems'), isFalse, reason: entry.key);
          continue;
        }
        final items = property['items']! as Map<String, dynamic>;
        expect(items['type'], 'string', reason: entry.key);
        expect(property['maxItems'], isA<int>(), reason: entry.key);
      }
    });

    test('requires every property it declares, and allows no others', () {
      final properties = task.schema['properties']! as Map<String, dynamic>;
      expect(
        (task.schema['required']! as List).toSet(),
        properties.keys.toSet(),
      );
      expect(task.schema['additionalProperties'], isFalse);
    });

    test('names the stage the settings table and the model slot know', () {
      expect(task.schemaName, 'context_file_digest');
    });
  });

  group('validate', () {
    test('an empty answer is an empty digest rather than a throw', () {
      final digest = task.validate(const {});

      expect(digest.purpose, '');
      expect(digest.findings, isEmpty);
      expect(digest.questionsAnswered, isEmpty);
      expect(digest.inputs, isEmpty);
      expect(digest.kindHint, 'other');
    });

    test('values of the wrong type read as absent', () {
      final digest = task.validate(const {
        'purpose': 42,
        'findings': 'not a list',
        'questions_answered': {'no': 'map'},
        'inputs': null,
        'kind_hint': 7,
      });

      expect(digest.purpose, '');
      expect(digest.findings, isEmpty);
      expect(digest.questionsAnswered, isEmpty);
      expect(digest.inputs, isEmpty);
      expect(digest.kindHint, 'other');
    });

    test('a kind_hint outside the enum falls back to other', () {
      // The vocabulary is what a reader groups on; a one-off word from a
      // model that ignored its enum would be a category with one member in
      // it forever.
      expect(task.validate(const {'kind_hint': 'notebook'}).kindHint, 'other');
      expect(task.validate(const {'kind_hint': 'analysis'}).kindHint,
          'analysis');
    });

    test('counts and lengths are clamped', () {
      final digest = task.validate({
        'purpose': 'p' * 900,
        'findings': [for (var i = 0; i < 12; i++) 'f' * 400],
        'questions_answered': [for (var i = 0; i < 12; i++) 'q' * 400],
        'inputs': [for (var i = 0; i < 12; i++) 'i' * 400],
        'kind_hint': 'analysis',
      });

      expect(digest.purpose.length, 300);
      expect(digest.findings, hasLength(6));
      expect(digest.findings.first.length, 200);
      expect(digest.questionsAnswered, hasLength(5));
      expect(digest.questionsAnswered.first.length, 160);
      expect(digest.inputs, hasLength(5));
      expect(digest.inputs.first.length, 160);
    });

    test('blank entries are dropped rather than kept as empty lines', () {
      final digest = task.validate(const {
        'findings': ['  ', 'The renewal is 2,600.', ''],
      });

      expect(digest.findings, ['The renewal is 2,600.']);
    });
  });

  group('the user message', () {
    test('anchors the date outside the fence and fences the file inside it',
        () {
      final built = task.buildUserMessage(inputOf());

      expect(built, contains('Today is 2026-09-09 (Wednesday).'));
      expect(built, contains('<untrusted_data source="file">'));
      expect(built, contains('analysis/pricing.md (doc)'));
      expect(built, contains('The renewal is 2,600 a month.'));
    });

    test('clamps the file at six thousand characters', () {
      final built = task.buildUserMessage(inputOf(text: 'x' * 9000));

      // Nothing else in this message carries an `x`, so counting them is
      // counting the file's own characters.
      expect(built.split('x').length - 1, ContextDigestTask.textCap);
    });

    test('the system prompt is the identical string before and after', () {
      // The prefix cache is keyed on the bytes: a per-call rebuild that
      // happened to match would still cost the cache.
      final before = task.systemPrompt;
      task.buildUserMessage(inputOf());
      task.buildUserMessage(inputOf(text: 'Something else entirely.'));

      expect(identical(task.systemPrompt, before), isTrue);
    });
  });
}
