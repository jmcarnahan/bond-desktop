import 'package:bond_inbox/services/llm/context_select_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The section-pick prompt, its schema and its validator, with no model.
///
/// The interesting half is `read`: it is an array of OBJECTS, so — like the
/// brief's `pointers` — it must NOT carry `minItems` or `maxItems`, because
/// the grammar converter handles those on arrays of scalars only and a schema
/// it cannot convert fails the whole request. The ceiling therefore has to
/// hold in `validate`, and this file is what says so.
///
/// The second property pinned here is that nothing throws. This call sits in
/// the middle of building a prompt, on a path whose whole contract is that a
/// failure costs the citations and never the reply.
void main() {
  const task = ContextSelectTask();
  final now = DateTime(2026, 9, 9);

  ContextSelectInput inputOf({
    String message = 'Re: Renewal quote\nWhat does the renewal come to?',
    List<({String topic, String path})> pointers = const [
      (topic: 'renewal rates', path: 'docs/pricing.md'),
    ],
    List<({String name, String description})> skills = const [
      (name: 'vendor-replies', description: 'Quote a renewal rate.'),
    ],
    List<({String path, String locator, String preview})> candidates = const [
      (
        path: 'docs/pricing.md',
        locator: 'Pricing > Q4 rates',
        preview: 'Standard freight is 41 credits per pallet.',
      ),
    ],
  }) =>
      ContextSelectInput(
        message: message,
        pointers: pointers,
        skills: skills,
        candidates: candidates,
        now: now,
      );

  group('the schema', () {
    test('is flat: no \$defs anywhere in it', () {
      expect(task.schema.containsKey(r'$defs'), isFalse);
      expect(task.schema.toString(), isNot(contains(r'$defs')));
    });

    test('maxItems appears only on the array of strings', () {
      final properties = task.schema['properties']! as Map<String, dynamic>;
      final read = properties['read']! as Map<String, dynamic>;
      final skills = properties['skills']! as Map<String, dynamic>;

      // The array of objects carries neither ceiling — `validate` does.
      expect(read.containsKey('maxItems'), isFalse);
      expect(read.containsKey('minItems'), isFalse);
      expect(skills['maxItems'], ContextSelectTask.maxSkills);
    });

    test('the read object is itself flat and closed', () {
      final read =
          (task.schema['properties']! as Map<String, dynamic>)['read']!
              as Map<String, dynamic>;
      final items = read['items']! as Map<String, dynamic>;

      expect(items['type'], 'object');
      expect((items['required']! as List).toSet(), {'path', 'locator'});
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
      expect(task.schemaName, 'context_select');
    });
  });

  group('the user message', () {
    test('fences the message, the pointers, the skills and the passages apart',
        () {
      final built = task.buildUserMessage(inputOf());

      expect(built, contains('Today is 2026-09-09 (Wednesday).'));
      expect(built, contains('<untrusted_data source="message">'));
      expect(built, contains('<untrusted_data source="pointers">'));
      expect(built, contains('<untrusted_data source="skills">'));
      expect(built, contains('<untrusted_data source="candidates">'));
      expect(built, contains('renewal rates · docs/pricing.md'));
      expect(built, contains('vendor-replies · Quote a renewal rate.'));
      expect(built, contains('docs/pricing.md · Pricing &gt; Q4 rates · '));
    });

    test('an absent half is omitted rather than fenced as nothing', () {
      final noPointers = task.buildUserMessage(inputOf(pointers: const []));
      expect(noPointers, isNot(contains('pointers')));
      expect(noPointers, contains('candidates'));

      final noSkills = task.buildUserMessage(inputOf(skills: const []));
      expect(noSkills, isNot(contains('source="skills"')));

      final noCandidates = task.buildUserMessage(inputOf(candidates: const []));
      expect(noCandidates, isNot(contains('candidates')));
      expect(noCandidates, contains('pointers'));
    });

    test('the message is clamped at fifteen hundred', () {
      // The letter appears nowhere else in the message, so counting it is
      // counting what survived the clamp.
      final built = task.buildUserMessage(inputOf(message: 'x' * 4000));
      expect(built.split('x').length - 1, ContextSelectTask.messageCap);
    });

    test('the candidate list stops at twelve', () {
      final built = task.buildUserMessage(inputOf(
        candidates: [
          for (var i = 0; i < 30; i++)
            (path: 'docs/f$i.md', locator: 'S$i', preview: 'body $i'),
        ],
      ));

      expect(built, contains('docs/f11.md'));
      expect(built, isNot(contains('docs/f12.md')));
    });

    test('a preview is one line, and only the first words of it', () {
      final built = task.buildUserMessage(inputOf(
        candidates: [
          (
            path: 'docs/pricing.md',
            locator: 'Pricing',
            // Newlines and runs of spaces, which would turn one candidate
            // into three lines of a list that is read one per line.
            preview: 'The desk\n\npublishes   one sheet. ${'y' * 400}',
          ),
        ],
      ));

      final line = built
          .split('\n')
          .firstWhere((line) => line.startsWith('docs/pricing.md · Pricing'));
      // path · locator · preview, and the preview clamped.
      expect(line, contains('The desk publishes one sheet.'));
      expect(built.split('y').length - 1, lessThan(400));
      expect(line.split(' · ').last.length, ContextSelectTask.previewCap);
    });

    test('a candidate with no locator says whole file', () {
      final built = task.buildUserMessage(inputOf(
        candidates: const [
          (path: 'notes.md', locator: '', preview: 'Rates are reviewed.'),
        ],
      ));

      expect(built, contains('notes.md · whole file · Rates are reviewed.'));
    });

    test('the pointer list stops at ten', () {
      final built = task.buildUserMessage(inputOf(
        pointers: [
          for (var i = 0; i < 25; i++) (topic: 'topic $i', path: 'p$i.md'),
        ],
      ));

      expect(built, contains('topic 9 · p9.md'));
      expect(built, isNot(contains('topic 10 · p10.md')));
    });

    test('the system prompt is the identical string before and after', () {
      final before = task.systemPrompt;
      task.buildUserMessage(inputOf());
      task.buildUserMessage(inputOf(
        pointers: const [],
        skills: const [],
        candidates: const [],
      ));

      expect(identical(task.systemPrompt, before), isTrue);
    });
  });

  group('validate', () {
    test('an empty answer is an empty selection rather than a throw', () {
      final selection = task.validate(const {});

      expect(selection.read, isEmpty);
      expect(selection.skills, isEmpty);
      expect(selection.reason, '');
      expect(selection.isEmpty, isTrue);
    });

    test('garbage of the wrong type reads as nothing chosen', () {
      final selection = task.validate(const {'read': 'x', 'skills': 3});

      expect(selection.read, isEmpty);
      expect(selection.skills, isEmpty);
      expect(selection.reason, '');
      expect(selection.isEmpty, ContextSelection.none.isEmpty);
    });

    test('two reads and two skills is the ceiling', () {
      final selection = task.validate({
        'read': [
          for (var i = 0; i < 6; i++) {'path': 'p$i.md', 'locator': 'S$i'},
        ],
        'skills': [for (var i = 0; i < 6; i++) 'skill-$i'],
        'reason': 'r' * 900,
      });

      expect(selection.read, hasLength(ContextSelectTask.maxRead));
      expect(selection.read.first.path, 'p0.md');
      expect(selection.read.first.locator, 'S0');
      expect(selection.skills, hasLength(ContextSelectTask.maxSkills));
      expect(selection.skills.first, 'skill-0');
      expect(selection.reason.length, 200);
    });

    test('a read with no path is dropped, and a missing locator is empty', () {
      // A locator with nothing to locate it in names no file; a path on its
      // own is the legal way to ask for a whole one.
      final selection = task.validate(const {
        'read': [
          {'locator': 'Pricing'},
          {'path': '  ', 'locator': 'Pricing'},
          'not a map',
          {'path': 'docs/pricing.md'},
        ],
        'skills': ['  ', 'vendor-replies'],
      });

      expect(selection.read, hasLength(1));
      expect(selection.read.single.path, 'docs/pricing.md');
      expect(selection.read.single.locator, '');
      expect(selection.skills, ['vendor-replies']);
    });

    test('paths and locators are clamped', () {
      final selection = task.validate({
        'read': [
          {'path': 'p' * 900, 'locator': 'l' * 900},
        ],
      });

      expect(selection.read.single.path.length, 200);
      expect(selection.read.single.locator.length, 200);
    });

    test('a reason alone has still chosen nothing', () {
      final selection = task.validate(const {
        'read': <Object>[],
        'skills': <Object>[],
        'reason': 'The passages already answer it.',
      });

      expect(selection.isEmpty, isTrue);
      expect(selection.reason, 'The passages already answer it.');
    });
  });
}
