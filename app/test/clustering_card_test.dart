import 'dart:convert';

import 'package:bond_inbox/services/clustering_card.dart';
import 'package:flutter_test/flutter_test.dart';

/// The five clustering cards, byte for byte, on a fictional row.
///
/// Every variant here is a ledger row somebody will compare against another
/// ledger row, and the only thing that makes two rows comparable is that the
/// card the bench embedded and the card the app embeds are the same bytes. A
/// segment that quietly moved, a joiner that changed, a dropped segment that
/// vanished instead of emptying: each of those would leave the numbers looking
/// fine and meaning nothing.
void main() {
  // Fictional, on example.com, like every fixture in this repository.
  final row = <String, Object?>{
    'source': 'email',
    'conversation_key': 'email:fx-conv-lease',
    'subject': 'Re: Addendum for the River Street suite',
    'participants_json': jsonEncode([
      {'name': 'Dana Whitfield', 'email': 'dana@example.com'},
      {'name': 'Priya Raman', 'email': 'priya@example.com'},
      {'name': '', 'email': 'noreply@example.com'},
    ]),
    'state': 'needs_reply',
    'cta_urgency': 'normal',
  };
  final cardData = <String, Object?>{
    'extraction_json': jsonEncode({
      'topics': ['fit-out schedule', 'capped allowance'],
    }),
    'summary': 'Dana asks for a decision on the allowance clause.',
  };

  String cardFor(ClusteringCardVariant variant) =>
      clusteringCardForConversationRow(row, cardData, variant: variant);

  group('the five variants', () {
    test('each one is the four-segment shape with its own segments kept', () {
      // Written out rather than derived, because a builder that agreed with a
      // derivation of itself would agree with itself however wrong both were.
      expect(
        cardFor(ClusteringCardVariant.topics),
        'Addendum for the River Street suite |  | '
        'fit-out schedule, capped allowance | '
        'Dana asks for a decision on the allowance clause.',
      );
      expect(
        cardFor(ClusteringCardVariant.participants),
        'Addendum for the River Street suite | '
        'Dana Whitfield, Priya Raman, noreply@example.com | '
        'fit-out schedule, capped allowance | '
        'Dana asks for a decision on the allowance clause.',
      );
      expect(
        cardFor(ClusteringCardVariant.subject),
        'Addendum for the River Street suite |  |  | ',
      );
      expect(
        cardFor(ClusteringCardVariant.subjectTopics),
        'Addendum for the River Street suite |  | '
        'fit-out schedule, capped allowance | ',
      );
      expect(
        cardFor(ClusteringCardVariant.summary),
        ' |  | fit-out schedule, capped allowance | '
        'Dana asks for a decision on the allowance clause.',
      );
    });

    test('all five are four segments, dropped ones empty and not absent', () {
      for (final variant in ClusteringCardVariant.values) {
        expect(
          cardFor(variant).split(' | '),
          hasLength(4),
          reason: '${variant.name} is not four segments',
        );
      }
    });

    test('the shipped card is what the builder produced before the move', () {
      // The byte-identity pin. This literal is the string Round D's
      // `buildClusteringCard(withParticipants: false)` produced over this same
      // row, and it is hard-coded rather than computed so that moving the
      // recipe into this module cannot have changed it. Every conversation
      // vector in every install was taken over a card of exactly this shape.
      expect(shippedClusteringCard, ClusteringCardVariant.topics);
      expect(
        clusteringCardForConversationRow(row, cardData),
        'Addendum for the River Street suite |  | '
        'fit-out schedule, capped allowance | '
        'Dana asks for a decision on the allowance clause.',
      );
    });

    test('the subject loses its Re: and a blank display is not a person', () {
      // `stripReFw` on the subject and the display rule on the people, both
      // inherited rather than reimplemented: the participants card names the
      // address of the person whose name the connector did not carry, and
      // never an empty slot between two commas.
      expect(
        cardFor(ClusteringCardVariant.participants),
        isNot(contains('Re:')),
      );
      expect(
        cardFor(ClusteringCardVariant.participants),
        isNot(contains(', ,')),
      );
    });

    test('a row with nothing stored is still four segments', () {
      expect(
        clusteringCardForConversationRow(const {}, null),
        ' |  |  | ',
      );
    });
  });

  group('buildConversationCard', () {
    test('is four segments, empty ones included', () {
      expect(
        buildConversationCard(
          subject: 'Launch date',
          participants: const ['Sarah', 'Tom'],
          topics: const ['launch', 'homepage copy'],
          summary: 'Shipping Thursday.',
        ),
        'Launch date | Sarah, Tom | launch, homepage copy | Shipping Thursday.',
      );
      // Fixed shape, so the same thread always produces the same card — which
      // is what makes the hash a usable "has anything changed" test.
      expect(
        buildConversationCard(
          subject: null,
          participants: const [],
          topics: const [],
          summary: null,
        ),
        ' |  |  | ',
      );
    });
  });

  group('buildClusteringCard over its arguments', () {
    String built(ClusteringCardVariant variant) => buildClusteringCard(
          subject: 'Launch date',
          participants: const ['Sarah', 'Tom'],
          topics: const ['launch', 'homepage copy'],
          summary: 'Shipping Thursday.',
          variant: variant,
        );

    test('the participants variant is the prompt card', () {
      expect(
        built(ClusteringCardVariant.participants),
        buildConversationCard(
          subject: 'Launch date',
          participants: const ['Sarah', 'Tom'],
          topics: const ['launch', 'homepage copy'],
          summary: 'Shipping Thursday.',
        ),
      );
    });

    test('the summary variant drops the subject and keeps the rest', () {
      expect(
        built(ClusteringCardVariant.summary),
        ' |  | launch, homepage copy | Shipping Thursday.',
      );
    });

    test('the subject variant is the subject and three empties', () {
      expect(built(ClusteringCardVariant.subject), 'Launch date |  |  | ');
    });
  });

  group('parseClusteringCardVariant', () {
    test('accepts the five names, case and space insensitively', () {
      expect(parseClusteringCardVariant('topics'), ClusteringCardVariant.topics);
      expect(
        parseClusteringCardVariant('participants'),
        ClusteringCardVariant.participants,
      );
      expect(
        parseClusteringCardVariant(' SUBJECT '),
        ClusteringCardVariant.subject,
      );
      expect(
        parseClusteringCardVariant('subject_topics'),
        ClusteringCardVariant.subjectTopics,
      );
      expect(
        parseClusteringCardVariant('summary'),
        ClusteringCardVariant.summary,
      );
    });

    test('refuses anything else, loudly', () {
      // Loud rather than defaulted: a typo that quietly measured the shipped
      // card twice would put two rows in the ledger that look like an A/B and
      // are not.
      for (final raw in ['', 'subjectTopics', 'people', 'topic', 'none']) {
        expect(
          () => parseClusteringCardVariant(raw),
          throwsArgumentError,
          reason: '$raw should not name a variant',
        );
      }
    });

    test('every enum value has a name the parser accepts', () {
      // So a sixth variant cannot ship unreachable from the bench, and so the
      // word a result file records is the word the define takes.
      for (final variant in ClusteringCardVariant.values) {
        expect(parseClusteringCardVariant(variant.wireName), variant);
      }
      expect(ClusteringCardVariant.subjectTopics.wireName, 'subject_topics');
      expect(ClusteringCardVariant.topics.wireName, 'topics');
    });
  });

  group('topicsOfExtraction', () {
    test('reads the topics a stored extraction carries', () {
      expect(
        topicsOfExtraction(jsonEncode({
          'topics': ['fit-out schedule', '', 42, 'capped allowance'],
        })),
        ['fit-out schedule', 'capped allowance'],
      );
    });

    test('every way of failing gives no topics', () {
      // Each of these is a row some older build wrote, and the card the app
      // sent before there were any topics is the honest answer to all of them.
      for (final raw in <Object?>[
        null,
        '',
        'not json',
        jsonEncode({'topics': 'one string'}),
        jsonEncode(['a list']),
        7,
      ]) {
        expect(topicsOfExtraction(raw), isEmpty, reason: '$raw');
      }
    });
  });
}
