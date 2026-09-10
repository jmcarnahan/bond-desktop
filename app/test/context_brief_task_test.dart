import 'package:bond_inbox/services/llm/context_brief_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brief prompt, its schema and its validator, with no model.
///
/// The interesting half is `pointers`: it is the one array of OBJECTS in any
/// schema this app sends, so it is the one that must NOT carry `minItems` or
/// `maxItems` — the grammar converter handles those on arrays of scalars
/// only, and a schema it cannot convert fails the whole request. The ceiling
/// therefore has to hold in `validate`, and this file is what says so.
void main() {
  const task = ContextBriefTask();
  final now = DateTime(2026, 9, 9);

  ContextBriefInput inputOf({
    String displayName = 'atlas',
    String claudeMd = '# Atlas\n\nReplies here stay short.\n',
    String fileMap = 'docs/pricing.md · What the renewal costs · How much?',
  }) =>
      ContextBriefInput(
        displayName: displayName,
        claudeMd: claudeMd,
        fileMap: fileMap,
        now: now,
      );

  group('the schema', () {
    test('is flat: no \$defs anywhere in it', () {
      expect(task.schema.containsKey(r'$defs'), isFalse);
      expect(task.schema.toString(), isNot(contains(r'$defs')));
    });

    test('maxItems appears only on the arrays of strings', () {
      final properties = task.schema['properties']! as Map<String, dynamic>;
      for (final entry in properties.entries) {
        final property = entry.value as Map<String, dynamic>;
        if (property['type'] != 'array') {
          expect(property.containsKey('maxItems'), isFalse, reason: entry.key);
          continue;
        }
        final items = property['items']! as Map<String, dynamic>;
        if (items['type'] == 'string') {
          expect(property['maxItems'], isA<int>(), reason: entry.key);
        } else {
          expect(property.containsKey('maxItems'), isFalse, reason: entry.key);
          expect(property.containsKey('minItems'), isFalse, reason: entry.key);
        }
      }
    });

    test('the pointer object is itself flat and closed', () {
      final pointers =
          (task.schema['properties']! as Map<String, dynamic>)['pointers']!
              as Map<String, dynamic>;
      final items = pointers['items']! as Map<String, dynamic>;

      expect(items['type'], 'object');
      expect((items['required']! as List).toSet(), {'topic', 'path'});
      expect(items['additionalProperties'], isFalse);
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
      expect(task.schemaName, 'context_brief');
    });
  });

  group('validate', () {
    test('an empty answer is an empty brief rather than a throw', () {
      final brief = task.validate(const {});

      expect(brief.about, '');
      expect(brief.replyGuidance, isEmpty);
      expect(brief.keyFacts, isEmpty);
      expect(brief.pointers, isEmpty);
      expect(brief.vocabulary, isEmpty);
    });

    test('values of the wrong type read as absent', () {
      final brief = task.validate(const {
        'about': 42,
        'reply_guidance': 'not a list',
        'key_facts': null,
        'pointers': 'not a list either',
        'vocabulary': {'no': 'map'},
      });

      expect(brief.about, '');
      expect(brief.replyGuidance, isEmpty);
      expect(brief.keyFacts, isEmpty);
      expect(brief.pointers, isEmpty);
      expect(brief.vocabulary, isEmpty);
    });

    test('counts and lengths are clamped', () {
      final brief = task.validate({
        'about': 'a' * 900,
        'reply_guidance': [for (var i = 0; i < 12; i++) 'g' * 400],
        'key_facts': [for (var i = 0; i < 20; i++) 'f' * 400],
        'vocabulary': [for (var i = 0; i < 30; i++) 'v' * 200],
        'pointers': const <Object>[],
      });

      expect(brief.about.length, 400);
      expect(brief.replyGuidance, hasLength(6));
      expect(brief.replyGuidance.first.length, 200);
      expect(brief.keyFacts, hasLength(8));
      expect(brief.keyFacts.first.length, 200);
      expect(brief.vocabulary, hasLength(12));
      expect(brief.vocabulary.first.length, 60);
    });

    test('pointers are clamped at ten, which the schema deliberately is not',
        () {
      final brief = task.validate({
        'pointers': [
          for (var i = 0; i < 25; i++) {'topic': 'topic $i', 'path': 'p$i.md'},
        ],
      });

      expect(brief.pointers, hasLength(10));
      expect(brief.pointers.first.topic, 'topic 0');
      expect(brief.pointers.first.path, 'p0.md');
    });

    test('a pointer missing either half is dropped', () {
      // A topic with no path cites nothing and a path with no topic answers
      // nothing; either way there is no half-pointer worth rendering.
      final brief = task.validate(const {
        'pointers': [
          {'topic': 'Pricing'},
          {'path': 'docs/pricing.md'},
          {'topic': '  ', 'path': 'docs/pricing.md'},
          {'topic': 'Pricing', 'path': 'docs/pricing.md'},
          'not a map',
        ],
      });

      expect(brief.pointers, hasLength(1));
      expect(brief.pointers.single.path, 'docs/pricing.md');
    });
  });

  group('the user message', () {
    test('fences the name, the notes and the map apart', () {
      final built = task.buildUserMessage(inputOf());

      expect(built, contains('Today is 2026-09-09 (Wednesday).'));
      expect(built, contains('<untrusted_data source="directory_name">'));
      expect(built, contains('<untrusted_data source="claude_md">'));
      expect(built, contains('<untrusted_data source="file_map">'));
      expect(built, contains('Replies here stay short.'));
      expect(built, contains('What the renewal costs'));
    });

    test('an absent half is omitted rather than fenced as nothing', () {
      final noNotes = task.buildUserMessage(inputOf(claudeMd: ''));
      expect(noNotes, isNot(contains('claude_md')));
      expect(noNotes, contains('file_map'));

      final noMap = task.buildUserMessage(inputOf(fileMap: ''));
      expect(noMap, isNot(contains('file_map')));
      expect(noMap, contains('claude_md'));
    });

    test('the notes and the map are each clamped at eight thousand', () {
      final built = task.buildUserMessage(
        inputOf(claudeMd: 'x' * 12000, fileMap: 'z' * 12000),
      );

      // Neither letter appears anywhere else in the message, so counting
      // them is counting what survived each clamp.
      expect(built.split('x').length - 1, ContextBriefTask.notesCap);
      expect(built.split('z').length - 1, ContextBriefTask.fileMapCap);
    });

    test('the system prompt is the identical string before and after', () {
      final before = task.systemPrompt;
      task.buildUserMessage(inputOf());
      task.buildUserMessage(inputOf(claudeMd: '', fileMap: 'a · b · c'));

      expect(identical(task.systemPrompt, before), isTrue);
    });
  });
}
