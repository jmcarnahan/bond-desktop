import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_set.dart';
import 'fixtures/golden_storyline.dart';

/// The storyline replay's pure half, against the FICTIONAL fixtures.
///
/// Everything the live run decides around a model call: which card a candidate
/// is judged as, which answers the service would have accepted, which storyline
/// a set of answers derives, and what the whole pass tallied. The live test
/// itself is `@Skip`'d and can be covered by nothing, so this is where a change
/// to any of that has to fail.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';

  late Map<String, dynamic> rawFixture;
  late GoldenSet set;
  late Directory tmp;

  setUp(() {
    rawFixture =
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
    set = GoldenSet.fromJson(rawFixture);
    tmp = Directory.systemTemp.createTempSync('golden-cards');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  // ── the cards ────────────────────────────────────────────────────────

  test('a run file yields topics and summary, and skips what carries neither',
      () {
    final cards = GoldenCards.fromRunJson([
      {
        'id': 'email:fx-a',
        'extract': {
          'topics': ['the addendum', 7, '', 'the allowance'],
        },
        'triage': {'summary': 'A term is still open.'},
      },
      {
        'id': 'email:fx-b',
        'triage': {'summary': 'Only a summary here.'},
      },
      {
        'id': 'email:fx-c',
        'extract': {
          'topics': ['only topics'],
        },
      },
      {'id': 'email:fx-d', 'stratum': 'gate-edge'},
    ]);

    expect(cards.size, 3);
    // A non-string topic and an empty one are dropped, the way the app's own
    // `_topicsOf` drops them.
    expect(cards.byId['email:fx-a']!.topics, ['the addendum', 'the allowance']);
    expect(cards.byId['email:fx-a']!.summary, 'A term is still open.');
    expect(cards.byId['email:fx-b']!.topics, isEmpty);
    expect(cards.byId['email:fx-c']!.summary, isNull);
    expect(cards.byId.containsKey('email:fx-d'), isFalse);
  });

  test('a summary of whitespace is no summary, so the entry carded nothing',
      () {
    // A blank summary puts nothing in the card's fourth segment, so counting
    // the entry would overstate how many items the run file actually carded.
    final cards = GoldenCards.fromRunJson([
      {
        'id': 'email:fx-blank',
        'triage': {'summary': '  '},
      },
    ]);

    expect(cards.size, 0);
    expect(cards.byId.containsKey('email:fx-blank'), isFalse);
  });

  test('a missing run file says what GOLDEN_RUN wants', () async {
    await expectLater(
      loadGoldenCards('${tmp.path}/no-such-run.json'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('GOLDEN_RUN'),
      )),
    );
  });

  test('a file that is not an array is refused as not a run file', () async {
    // The shape a golden SET has, which is the neighbouring file and so the
    // likeliest thing to be pointed at by mistake.
    final wrong = File('${tmp.path}/not-a-run.json')
      ..writeAsStringSync('{"items": []}');
    await expectLater(
      loadGoldenCards(wrong.path),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('not a run file'),
      )),
    );
  });

  test('a candidate card is the app\'s card, Re:/Fwd: stripped', () {
    final item = _itemWithSubject(
      rawFixture,
      'email:fx-keep-tail',
      'Re: Fwd: Addendum for the River Street suite',
    );
    const card = GoldenCard(
      topics: ['the addendum', 'the allowance'],
      summary: 'A term is still open.',
    );

    final built = candidateCardFor(item, card);
    expect(
      built,
      buildConversationCard(
        subject: 'Addendum for the River Street suite',
        participants: item.conversationParticipants,
        topics: card.topics,
        summary: card.summary,
      ),
    );
    expect(built, startsWith('Addendum for the River Street suite | '));
  });

  test('a card the run file has nothing for keeps its two blank segments', () {
    final item = set.byId['email:fx-keep-tail']!;
    // Four segments, always: the app's card is the same shape whether or not
    // the thread was ever enriched, which is what makes it hashable.
    expect(
      candidateCardFor(item, null),
      'Addendum for the River Street suite | '
      'Dana Whitfield, Alex Rivera, Priya Raman |  | ',
    );
  });

  // ── one confirmation ─────────────────────────────────────────────────

  test('a candidate is gold, forbidden or extra', () {
    final item = set.byId['email:fx-keep-tail']!;
    expect(kindOf(item, 'river-office-lease'), CandidateKind.gold);
    expect(kindOf(item, 'studio-website-redesign'), CandidateKind.forbidden);
    expect(kindOf(item, 'ANTI-person-hub'), CandidateKind.forbidden);
    expect(kindOf(item, 'spring-portfolio-review'), CandidateKind.extra);
  });

  test('an accept follows the service\'s rule, and low is not one', () {
    expect(_outcome(belongs: true, confidence: 'high').accepted, isTrue);
    expect(_outcome(belongs: true, confidence: 'medium').accepted, isTrue);

    final hedged = _outcome(belongs: true, confidence: 'low');
    expect(hedged.accepted, isFalse);
    expect(hedged.lowYes, isTrue);

    final no = _outcome(belongs: false, confidence: 'high');
    expect(no.accepted, isFalse);
    expect(no.lowYes, isFalse);

    const failed = ConfirmOutcome(
      slug: 'fx-effort-01',
      kind: CandidateKind.extra,
      result: null,
    );
    expect(failed.accepted, isFalse);
    expect(failed.lowYes, isFalse);
  });

  // ── what a set of confirmations derives ──────────────────────────────

  test('no accept files the item nowhere', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-b', belongs: false, confidence: 'high'),
      _outcome(slug: 'fx-a', belongs: true, confidence: 'low'),
    ]);
    expect(derived.id, 'none');
    expect(derived.tie, isFalse);
  });

  test('one high beats two mediums', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', belongs: true, confidence: 'medium'),
      _outcome(slug: 'fx-z', belongs: true, confidence: 'high'),
      _outcome(slug: 'fx-b', belongs: true, confidence: 'medium'),
    ]);
    expect(derived.id, 'fx-z');
    expect(derived.tie, isFalse);
  });

  test('a tie at the top goes alphabetically, and is counted', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-z', belongs: true, confidence: 'high'),
      _outcome(slug: 'fx-a', belongs: true, confidence: 'high'),
    ]);
    // Alphabetical, never candidate order: candidate order leads with gold,
    // and a tie-break that took the first would flatter every recall number.
    expect(derived.id, 'fx-a');
    expect(derived.tie, isTrue);
  });

  test('a single accept is not a tie', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', belongs: true, confidence: 'medium'),
      _outcome(slug: 'fx-b', belongs: false, confidence: 'high'),
    ]);
    expect(derived.id, 'fx-a');
    expect(derived.tie, isFalse);
  });

  test('a failed candidate leaves the item unfiled, accept or no accept', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', belongs: true, confidence: 'high'),
      const ConfirmOutcome(
        slug: 'fx-b',
        kind: CandidateKind.extra,
        result: null,
      ),
    ]);
    expect(derived.id, isNull);
    expect(derived.tie, isFalse);
  });

  // ── what the stage cost ──────────────────────────────────────────────

  test('an item\'s confirmations sum into one call record', () {
    final call = summariseCalls([
      _record(ms: 400, promptTokens: 900, completionTokens: 40),
      _record(ms: 350, promptTokens: 880, completionTokens: 35),
    ]);
    expect(call.ms, 750);
    expect(call.promptTokens, 1780);
    expect(call.completionTokens, 75);
    expect(call.outcome, 'ok');
  });

  test('one unreported usage poisons the token sums to null', () {
    final call = summariseCalls([
      _record(ms: 400, promptTokens: 900, completionTokens: 40),
      _record(ms: 350),
    ]);
    expect(call.ms, 750);
    expect(call.promptTokens, isNull);
    expect(call.completionTokens, isNull);
  });

  test('the stage takes the FIRST non-ok outcome, and empty is an error', () {
    final call = summariseCalls([
      _record(ms: 10, outcome: 'ok'),
      _record(ms: 20, outcome: 'unavailable'),
      _record(ms: 30, outcome: 'format'),
    ]);
    expect(call.outcome, 'unavailable');
    expect(() => summariseCalls(const []), throwsArgumentError);
  });

  // ── the run's own arithmetic ─────────────────────────────────────────

  test('the tally counts every kind, bucket and hedge', () {
    final tally = StorylineTally();

    // A `must` item that landed on gold, said yes to a trap, and said no to
    // the extra.
    final must = set.byId['email:fx-keep-tail']!;
    final mustOutcomes = [
      _outcome(
        slug: 'river-office-lease',
        kind: CandidateKind.gold,
        belongs: true,
        confidence: 'high',
      ),
      _outcome(
        slug: 'studio-website-redesign',
        kind: CandidateKind.forbidden,
        belongs: true,
        confidence: 'medium',
      ),
      _outcome(
        slug: 'spring-portfolio-review',
        belongs: false,
        confidence: 'high',
      ),
    ];
    tally.add(must, mustOutcomes, deriveStorylineId(mustOutcomes));

    // A `should` item that hedged on gold and lost a candidate to a failure,
    // so it is unfiled — but its gold call ANSWERED, so it still counts in the
    // should denominator.
    final should = set.byId['email:fx-reply']!;
    final shouldOutcomes = [
      _outcome(
        slug: 'river-office-lease',
        kind: CandidateKind.gold,
        belongs: true,
        confidence: 'low',
      ),
      const ConfirmOutcome(
        slug: 'spring-portfolio-review',
        kind: CandidateKind.extra,
        result: null,
      ),
    ];
    tally.add(should, shouldOutcomes, deriveStorylineId(shouldOutcomes));

    // An item gold files nowhere, which this run also filed nowhere.
    final nowhere = set.byId['teams:fx-floor']!;
    final nowhereOutcomes = [
      _outcome(
        slug: 'river-office-lease',
        belongs: false,
        confidence: 'medium',
      ),
      _outcome(
        slug: 'studio-website-redesign',
        belongs: true,
        confidence: 'low',
      ),
    ];
    tally.add(nowhere, nowhereOutcomes, deriveStorylineId(nowhereOutcomes));

    expect(tally.goldMustN, 1);
    expect(tally.goldMustAccepted, 1);
    expect(tally.goldShouldN, 1);
    expect(tally.goldShouldAccepted, 0);
    expect(tally.forbiddenN, 1);
    expect(tally.forbiddenAccepted, 1);
    // Three extras were asked; the one that failed carries no answer to count.
    expect(tally.extraN, 3);
    expect(tally.extraAccepted, 0);
    expect(tally.lowYes, 2);
    expect(tally.acceptedHigh, 1);
    expect(tally.acceptedMedium, 1);
    expect(tally.derivedGold, 1);
    expect(tally.derivedNone, 1);
    expect(tally.derivedOther, 0);
    expect(tally.derivedIncomplete, 1);
    expect(tally.goldNoneN, 1);
    expect(tally.goldNoneDerivedNone, 1);
    expect(tally.ties, 0);

    final json = tally.toJson();
    expect((json['gold_must']! as Map)['accepted'], 1);
    expect((json['derived']! as Map)['incomplete'], 1);
    expect((json['gold_none']! as Map)['derived_none'], 1);
  });

  test('the tally\'s table prints rates and never a slug', () {
    final tally = StorylineTally();
    final item = set.byId['email:fx-keep-tail']!;
    final outcomes = [
      _outcome(
        slug: 'river-office-lease',
        kind: CandidateKind.gold,
        belongs: true,
        confidence: 'high',
      ),
    ];
    tally.add(item, outcomes, deriveStorylineId(outcomes));

    final table = tally.table();
    expect(table, contains('1/1 (100%)'));
    // Registry slugs are derived from real project names; scrollback is how
    // they leak, so the summary carries counts only.
    expect(table, isNot(contains('river-office-lease')));
  });

  test('an item lands in exactly one derived bucket', () {
    final gold = set.byId['email:fx-keep-tail']!;
    expect(
      derivedBucket(gold, const DerivedStoryline(id: null, tie: false)),
      'incomplete',
    );
    expect(
      derivedBucket(
        gold,
        const DerivedStoryline(id: 'river-office-lease', tie: false),
      ),
      'gold',
    );
    expect(
      derivedBucket(gold, const DerivedStoryline(id: 'none', tie: false)),
      'none',
    );
    expect(
      derivedBucket(
        gold,
        const DerivedStoryline(id: 'studio-website-redesign', tie: false),
      ),
      'other',
    );
  });

  test('the gold cell says how the gold candidate answered', () {
    expect(goldCell([_outcome(belongs: true, confidence: 'high')]), '-');
    expect(
      goldCell([
        _outcome(
          kind: CandidateKind.gold,
          belongs: true,
          confidence: 'medium',
        ),
      ]),
      'yes(medium)',
    );
    expect(
      goldCell([
        _outcome(kind: CandidateKind.gold, belongs: true, confidence: 'low'),
      ]),
      'low-yes',
    );
    expect(
      goldCell([
        _outcome(kind: CandidateKind.gold, belongs: false, confidence: 'high'),
      ]),
      'no',
    );
    expect(
      goldCell(const [
        ConfirmOutcome(
          slug: 'fx-a',
          kind: CandidateKind.gold,
          result: null,
        ),
      ]),
      'failed',
    );
  });
}

/// One golden item rebuilt with a different subject, so the Re:/Fw: stripping
/// can be exercised without a second fixture entry.
GoldenItem _itemWithSubject(
  Map<String, dynamic> rawFixture,
  String id,
  String subject,
) {
  final raw = (rawFixture['items']! as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((entry) => entry['id'] == id);
  final copy = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
  (copy['conversation']! as Map<String, dynamic>)['subject'] = subject;
  return GoldenItem.fromJson(copy);
}

ConfirmOutcome _outcome({
  String slug = 'fx-effort-01',
  CandidateKind kind = CandidateKind.extra,
  required bool belongs,
  required String confidence,
}) =>
    ConfirmOutcome(
      slug: slug,
      kind: kind,
      result: ConfirmResult(
        evidence: 'both mention the same thing',
        belongs: belongs,
        confidence: confidence,
      ),
    );

/// A call record in the shape the client emits one, for the arithmetic above.
LlmCallRecord _record({
  required int ms,
  int? promptTokens,
  int? completionTokens,
  String outcome = 'ok',
}) =>
    LlmCallRecord(
      label: 'storyline_membership',
      durationMs: ms,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      outcome: outcome,
    );
