import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a storyline's charter comes from: the naming task's draft of it.
/// What judges a thread against the charter is the decision model's
/// `member_of` (`storyline_judge_test.dart`).
///
/// Plumbing only. Whether a model writes a GOOD charter is measured live —
/// pinning one here would fail on the next model swap for no defect.

Map<String, dynamic> _nameAnswer({
  Object? evidence = 'Every thread is about the website redesign.',
  Object? title = 'Website redesign',
  Object? summary = 'The photos are back and the studio is reviewing them.',
  Object? charter = 'The redesign of the Northline Studio website — the '
      'homepage copy, the new photography, and the launch date.',
}) =>
    {
      'evidence': evidence,
      'title': title,
      'summary': summary,
      'charter': charter,
    };

void main() {
  const name = NameStorylineTask();

  group('the naming task drafts a charter', () {
    test('the schema asks for one, last — the grammar emits in this order', () {
      final properties = name.schema['properties'] as Map<String, dynamic>;

      // The two judgements sit between the evidence and the title since Round
      // D; the charter is still the last thing the grammar emits.
      expect(properties.keys.toList(), [
        'evidence',
        'coherent',
        'outliers',
        'title',
        'summary',
        'charter',
      ]);
      expect(properties.keys.last, 'charter');
      expect(name.schema['required'], properties.keys.toList());
      expect((properties['charter'] as Map)['type'], 'string');
    });

    test('the prompt asks for criteria, not a status line', () {
      expect(name.systemPrompt, contains('- charter:'));
      expect(name.systemPrompt, contains('Membership criteria'));
      expect(name.systemPrompt,
          contains('so a new thread can be judged against it'));
    });

    test('a good charter passes through', () {
      expect(name.validate(_nameAnswer()).charter,
          startsWith('The redesign of the Northline Studio website'));
    });

    test('a missing or non-string charter is empty, not a throw', () {
      expect(name.validate(_nameAnswer(charter: null)).charter, '');
      expect(name.validate(const {}).charter, '');
      // Stringified rather than dropped, the way every other field is.
      expect(name.validate(_nameAnswer(charter: 7)).charter, '7');
    });

    test('a long charter is clamped', () {
      expect(name.validate(_nameAnswer(charter: 'c' * 900)).charter.length, 300);
    });
  });
}
