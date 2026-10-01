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
        // The thread text is not four segments and is not built here — see
        // 'the text and excerpt variants' below.
        if (variant == ClusteringCardVariant.text) continue;
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
      expect(
        parseClusteringCardVariant('thread'),
        ClusteringCardVariant.thread,
      );
      expect(
        parseClusteringCardVariant('topics_untitled'),
        ClusteringCardVariant.topicsUntitled,
      );
      expect(parseClusteringCardVariant('text'), ClusteringCardVariant.text);
      expect(
        parseClusteringCardVariant(' Excerpt '),
        ClusteringCardVariant.excerpt,
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
      expect(ClusteringCardVariant.text.wireName, 'text');
      expect(ClusteringCardVariant.excerpt.wireName, 'excerpt');
    });
  });

  group('the text and excerpt variants', () {
    test('the text card cannot be built from four segments', () {
      // It is the thread text, which needs the store: `clusteringCardFor`
      // in `storyline_cards.dart` is the one way to it.
      expect(
        () => buildClusteringCard(
          subject: 'Launch date',
          participants: const [],
          topics: const [],
          summary: 'Shipping Thursday.',
          variant: ClusteringCardVariant.text,
        ),
        throwsArgumentError,
      );
      expect(
        () => cardFor(ClusteringCardVariant.text),
        throwsArgumentError,
      );
    });

    test('the excerpt card is the subject and the newest message, nothing else',
        () {
      final withBody = {
        ...cardData,
        'body_text': 'Could you sign the addendum by Friday?',
        'body_preview': 'Could you sign',
      };
      expect(
        clusteringCardForConversationRow(row, withBody,
            variant: ClusteringCardVariant.excerpt),
        'Addendum for the River Street suite |  |  | '
        'Could you sign the addendum by Friday?',
      );
      // No body yet: the card is still four segments, the last one empty,
      // and the summary never stands in for it.
      expect(
        cardFor(ClusteringCardVariant.excerpt),
        'Addendum for the River Street suite |  |  | ',
      );
    });

    test('newestMessageExcerpt prefers the body, then the preview', () {
      expect(
        newestMessageExcerpt({
          'body_text': 'The full body.',
          'body_preview': 'The preview.',
        }),
        'The full body.',
      );
      // An unfetched body is empty, and Graph's preview is what there is.
      expect(
        newestMessageExcerpt({'body_text': '', 'body_preview': 'The preview.'}),
        'The preview.',
      );
      expect(newestMessageExcerpt({'body_preview': 'The preview.'}),
          'The preview.');
      expect(newestMessageExcerpt(null), '');
      expect(newestMessageExcerpt(const {}), '');
    });

    test('newestMessageExcerpt strips markers and collapses whitespace', () {
      expect(
        newestMessageExcerpt({
          'body_text': '  Here is the plan.\n\n[[att:plan.pdf]]\t  See above.  ',
        }),
        'Here is the plan. See above.',
      );
      // Collapsing is the thread text's own rule, not only after a marker.
      expect(
        newestMessageExcerpt({'body_text': 'One\n\ntwo   three'}),
        'One two three',
      );
    });

    test('newestMessageExcerpt caps at 300 code points, not code units', () {
      // Each emoji is ONE code point and TWO UTF-16 units: a unit count would
      // stop at 150 of them and could split one in half.
      final emoji = '\u{1F333}' * 400;
      final excerpt = newestMessageExcerpt({'body_text': emoji});
      expect(excerpt.runes.length, 300);
      expect(excerpt.length, 600);
      expect(excerpt, '\u{1F333}' * 300);
    });
  });

  group('the thread variant', () {
    String blob({List<String> topics = const [], String project = ''}) =>
        jsonEncode({'topics': topics, 'project': project});

    // Fictional, on example.com. Newest first, as the store returns them.
    final threadData = <String, Object?>{
      'summary': 'Dana confirms the fit-out starts on the ninth.',
      'thread_extractions': [
        blob(
          topics: ['fit-out schedule', 'Keys handover'],
          project: 'River Street lease',
        ),
        blob(topics: ['capped allowance', 'FIT-OUT SCHEDULE']),
        blob(
          topics: ['keys handover', 'parking permits', 'signage'],
          project: 'river street lease',
        ),
        blob(topics: ['insurance certificate', 'move date'], project: 'Move'),
        null,
      ],
    };

    test('merges, de-duplicates and caps the topics, project first', () {
      expect(
        clusteringCardForConversationRow(
          row,
          threadData,
          variant: ClusteringCardVariant.thread,
        ),
        'Addendum for the River Street suite |  | '
        'River Street lease, fit-out schedule, Keys handover, '
        'capped allowance, parking permits, signage | '
        'Dana confirms the fit-out starts on the ninth.',
      );
    });

    test('threadCardTopics: the most frequent project, ties to the newest', () {
      expect(
        threadCardTopics([
          blob(project: 'Signage'),
          blob(project: 'Parking'),
          blob(project: 'parking'),
        ]),
        ['Parking'],
      );
      expect(
        threadCardTopics([
          blob(project: 'Signage'),
          blob(project: 'Parking'),
        ]),
        ['Signage'],
      );
      expect(threadCardTopics([blob(topics: ['a']), null, 'not json']), ['a']);
      expect(threadCardTopics(const []), isEmpty);
    });

    test('a topic equal to the project is not repeated', () {
      expect(
        threadCardTopics([
          blob(topics: ['Signage', 'permits'], project: 'signage'),
        ]),
        ['signage', 'permits'],
      );
    });

    test('a map with no thread list reads as a one-message thread', () {
      expect(
        clusteringCardForConversationRow(
          row,
          cardData,
          variant: ClusteringCardVariant.thread,
        ),
        cardFor(ClusteringCardVariant.topics),
      );
    });

    final teamsParticipants = [
      {'name': 'Dana Whitfield', 'email': 'teams:u1'},
      {'name': 'Priya Raman', 'email': 'teams:u2'},
    ];
    Map<String, Object?> teamsRow(String subject) => {
          'source': 'teams',
          'conversation_key': 'teams:fx-chat',
          'subject': subject,
          'participants_json': jsonEncode(teamsParticipants),
        };

    test('an untitled Teams chat has no subject on the card', () {
      expect(
        clusteringCardForConversationRow(
          teamsRow('Dana Whitfield, Priya Raman'),
          threadData,
          variant: ClusteringCardVariant.thread,
        ),
        startsWith(' |  | River Street lease, '),
      );
    });

    test('the names subject stays on every other variant', () {
      expect(
        clusteringCardForConversationRow(
          teamsRow('Dana Whitfield, Priya Raman'),
          cardData,
        ),
        startsWith('Dana Whitfield, Priya Raman |  | '),
      );
    });

    test('a titled Teams chat keeps its topic', () {
      expect(
        clusteringCardForConversationRow(
          teamsRow('Suite fit-out'),
          threadData,
          variant: ClusteringCardVariant.thread,
        ),
        startsWith('Suite fit-out |  | River Street lease, '),
      );
    });

    test('a mail thread named like its people keeps its subject', () {
      // The untitled rule is Teams-only: a mail subject is always somebody's
      // words, whatever they are.
      expect(
        clusteringCardForConversationRow(
          {
            ...teamsRow('Dana Whitfield, Priya Raman'),
            'source': 'email',
          },
          threadData,
          variant: ClusteringCardVariant.thread,
        ),
        startsWith('Dana Whitfield, Priya Raman |  | '),
      );
    });
  });

  group('the topics_untitled variant', () {
    final teamsParticipants = [
      {'name': 'Dana Whitfield', 'email': 'teams:u1'},
      {'name': 'Priya Raman', 'email': 'teams:u2'},
    ];
    Map<String, Object?> teamsRow(String subject) => {
          'source': 'teams',
          'conversation_key': 'teams:fx-chat',
          'subject': subject,
          'participants_json': jsonEncode(teamsParticipants),
        };
    String card(Map<String, Object?> row, ClusteringCardVariant variant) =>
        clusteringCardForConversationRow(row, cardData, variant: variant);

    test('is byte-identical to topics on mail', () {
      expect(
        card(row, ClusteringCardVariant.topicsUntitled),
        card(row, ClusteringCardVariant.topics),
      );
      // A mail subject that happens to be names is still somebody's words.
      final namedMail = {
        ...teamsRow('Dana Whitfield, Priya Raman'),
        'source': 'email',
      };
      expect(
        card(namedMail, ClusteringCardVariant.topicsUntitled),
        card(namedMail, ClusteringCardVariant.topics),
      );
    });

    test('is byte-identical to topics on a titled chat', () {
      expect(
        card(teamsRow('Suite fit-out'), ClusteringCardVariant.topicsUntitled),
        card(teamsRow('Suite fit-out'), ClusteringCardVariant.topics),
      );
    });

    test('leaves the subject empty on an untitled chat', () {
      expect(
        card(
          teamsRow('Dana Whitfield, Priya Raman'),
          ClusteringCardVariant.topicsUntitled,
        ),
        ' |  | fit-out schedule, capped allowance | '
        'Dana asks for a decision on the allowance clause.',
      );
      expect(
        card(teamsRow('Dana Whitfield, Priya Raman'),
            ClusteringCardVariant.topics),
        startsWith('Dana Whitfield, Priya Raman |  | '),
      );
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
