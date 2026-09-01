import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/membership_cases.dart';

/// The charter half of the storyline prompts: what the confirm task judges
/// against, and where the naming task's draft of it comes from.
///
/// Plumbing only. Whether a model gets these judgements RIGHT is measured live
/// by `llm_membership_live_test.dart` against `fixtures/membership_cases.dart`
/// — pinning a verdict here would fail on the next model swap for no defect.

Storyline _storyline({
  String title = 'Website redesign',
  String? summary = 'Waiting on the homepage copy review.',
  String? charter,
}) =>
    Storyline(
      id: 'sl-1',
      title: title,
      summary: summary,
      charter: charter,
      status: 'active',
    );

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
  const confirm = ConfirmMembershipTask();
  const name = NameStorylineTask();

  group('the confirm prompt judges against the charter', () {
    test('a storyline with a charter is described by it, and only by it', () {
      final user = confirm.buildUserMessage(ConfirmInput(
        storyline: _storyline(
          charter: 'Planning the Friday dinner — scheduling, the guest list, '
              'and who brings what.',
        ),
        storylineParticipants: const ['Priya Natarajan', 'Jordan Beck'],
        candidateCard: 'Friday dinner | Caitlin Zhao |  | ',
      ));

      expect(user, contains('Charter: Planning the Friday dinner'));
      // Never both: two descriptions of the same group let the model pick
      // whichever one agrees with the answer it already had.
      expect(user, isNot(contains('Summary:')));
      expect(user, contains('Title: Website redesign'));
      expect(user, contains('People: Priya Natarajan, Jordan Beck'));
      expect(user, contains('<untrusted_data source="storyline">'));
      expect(user, contains('<untrusted_data source="candidate_thread">'));
      expect(user, contains('Friday dinner | Caitlin Zhao'));
    });

    test('no charter falls back to the summary — an old storyline still works',
        () {
      for (final charter in [null, '', '   ']) {
        final user = confirm.buildUserMessage(ConfirmInput(
          storyline: _storyline(charter: charter),
          storylineParticipants: const [],
          candidateCard: 'card',
        ));

        expect(user, contains('Summary: Waiting on the homepage copy review.'));
        expect(user, isNot(contains('Charter:')));
      }
    });

    test('a long charter is clamped, and the card still is too', () {
      final user = confirm.buildUserMessage(ConfirmInput(
        storyline: _storyline(charter: 'c' * 900),
        storylineParticipants: const [],
        candidateCard: 'z' * 5000,
      ));

      // A run of exactly 400, and not one more — counting every 'c' in the
      // message would also count the ones in the fence tags.
      expect(user, contains('c' * 400));
      expect(user, isNot(contains('c' * 401)));
      expect('z'.allMatches(user).length, 1200);
    });
  });

  group('the naming task drafts a charter', () {
    test('the schema asks for one, last — the grammar emits in this order', () {
      final properties = name.schema['properties'] as Map<String, dynamic>;

      expect(
          properties.keys.toList(), ['evidence', 'title', 'summary', 'charter']);
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

  group('the membership eval set', () {
    test('every case is a card the app could actually have built', () {
      // Four ` | ` segments, empty ones included — the shape
      // `buildConversationCard` produces and the shape the prompt was written
      // against. A three-segment card would silently move the summary into the
      // topics slot.
      for (final entry in membershipCases) {
        expect(entry.candidateCard.split(' | '), hasLength(4),
            reason: entry.id);
      }
    });

    test('ids are unique, and every case says why it exists', () {
      expect(membershipCases.map((c) => c.id).toSet(),
          hasLength(membershipCases.length));
      for (final entry in membershipCases) {
        expect(entry.note, isNotEmpty, reason: entry.id);
      }
    });

    test('both answers are represented, and the hard cases are not must-pass',
        () {
      expect(membershipCases.where((c) => c.expectBelongs), isNotEmpty);
      expect(membershipCases.where((c) => !c.expectBelongs), isNotEmpty);
      // The set is worth nothing as a gate if every case in it is winnable.
      expect(membershipCases.where((c) => !c.mustPass), isNotEmpty);
    });
  });
}
