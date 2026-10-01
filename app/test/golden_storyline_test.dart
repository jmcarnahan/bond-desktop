import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_judge.dart' show StorylinePolicy;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_set.dart';
import 'fixtures/golden_storyline.dart';

/// The storyline replay's pure half, against the FICTIONAL fixtures.
///
/// Everything the live run decides around a model call: which answers the
/// service would have accepted, which storyline a set of answers derives, and
/// what the whole pass tallied. The live test
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
    // `topicsOfExtraction` drops them.
    expect(cards.byId['email:fx-a']!.topics, ['the addendum', 'the allowance']);
    expect(cards.byId['email:fx-a']!.summary, 'A term is still open.');
    expect(cards.byId['email:fx-b']!.topics, isEmpty);
    expect(cards.byId['email:fx-c']!.summary, isNull);
    expect(cards.byId.containsKey('email:fx-d'), isFalse);
  });

  test('a run file carries the project for the thread card', () {
    final cards = GoldenCards.fromRunJson([
      {
        'id': 'email:fx-p',
        'extract': {
          'topics': ['the addendum'],
          'project': '  River Street lease ',
        },
      },
      {
        'id': 'email:fx-q',
        'extract': {'topics': <String>[], 'project': 'Garden fence'},
      },
      {
        'id': 'email:fx-r',
        'extract': {'topics': ['no project'], 'project': 7},
      },
    ]);

    expect(cards.byId['email:fx-p']!.project, 'River Street lease');
    // A project alone is something the thread card reads, so it counts.
    expect(cards.byId['email:fx-q']!.project, 'Garden fence');
    expect(cards.byId['email:fx-r']!.project, isEmpty);
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

  // ── one confirmation ─────────────────────────────────────────────────

  test('a candidate is gold, forbidden or extra', () {
    final item = set.byId['email:fx-keep-tail']!;
    expect(kindOf(item, 'river-office-lease'), CandidateKind.gold);
    expect(kindOf(item, 'studio-website-redesign'), CandidateKind.forbidden);
    expect(kindOf(item, 'ANTI-person-hub'), CandidateKind.forbidden);
    expect(kindOf(item, 'spring-portfolio-review'), CandidateKind.extra);
  });

  test('an accept follows the service\'s rule for a kept storyline', () {
    expect(_outcome(p: 0.9).accepted, isTrue);
    expect(_outcome(p: StorylinePolicy.acceptActive).accepted, isTrue);
    expect(_outcome(p: 0.49).accepted, isFalse);

    const failed = ConfirmOutcome(
      slug: 'fx-effort-01',
      kind: CandidateKind.extra,
      p: null,
    );
    expect(failed.accepted, isFalse);
  });

  // ── what a set of confirmations derives ──────────────────────────────

  test('no accept files the item nowhere', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-b', p: 0.1),
      _outcome(slug: 'fx-a', p: 0.4),
    ]);
    expect(derived.id, 'none');
    expect(derived.tie, isFalse);
  });

  test('the highest p wins', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', p: 0.6),
      _outcome(slug: 'fx-z', p: 0.9),
      _outcome(slug: 'fx-b', p: 0.7),
    ]);
    expect(derived.id, 'fx-z');
    expect(derived.tie, isFalse);
  });

  test('a tie at the top goes alphabetically, and is counted', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-z', p: 0.9),
      _outcome(slug: 'fx-a', p: 0.9),
    ]);
    // Alphabetical, never candidate order: candidate order leads with gold,
    // and a tie-break that took the first would flatter every recall number.
    expect(derived.id, 'fx-a');
    expect(derived.tie, isTrue);
  });

  test('a single accept is not a tie', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', p: 0.6),
      _outcome(slug: 'fx-b', p: 0.1),
    ]);
    expect(derived.id, 'fx-a');
    expect(derived.tie, isFalse);
  });

  test('a failed candidate leaves the item unfiled, accept or no accept', () {
    final derived = deriveStorylineId([
      _outcome(slug: 'fx-a', p: 0.9),
      const ConfirmOutcome(
        slug: 'fx-b',
        kind: CandidateKind.extra,
        p: null,
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

  test('the tally counts every kind and bucket', () {
    final tally = StorylineTally();

    // A `must` item that landed on gold, said yes to a trap, and said no to
    // the extra.
    final must = set.byId['email:fx-keep-tail']!;
    final mustOutcomes = [
      _outcome(slug: 'river-office-lease', kind: CandidateKind.gold, p: 0.9),
      _outcome(
        slug: 'studio-website-redesign',
        kind: CandidateKind.forbidden,
        p: 0.6,
      ),
      _outcome(slug: 'spring-portfolio-review', p: 0.1),
    ];
    tally.add(must, mustOutcomes, deriveStorylineId(mustOutcomes));

    // A `should` item under the bar on gold that lost a candidate to a
    // failure, so it is unfiled — but its gold call ANSWERED, so it still
    // counts in the should denominator.
    final should = set.byId['email:fx-reply']!;
    final shouldOutcomes = [
      _outcome(slug: 'river-office-lease', kind: CandidateKind.gold, p: 0.4),
      const ConfirmOutcome(
        slug: 'spring-portfolio-review',
        kind: CandidateKind.extra,
        p: null,
      ),
    ];
    tally.add(should, shouldOutcomes, deriveStorylineId(shouldOutcomes));

    // An item gold files nowhere, which this run also filed nowhere.
    final nowhere = set.byId['teams:fx-floor']!;
    final nowhereOutcomes = [
      _outcome(slug: 'river-office-lease', p: 0.2),
      _outcome(slug: 'studio-website-redesign', p: 0.4),
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
      _outcome(slug: 'river-office-lease', kind: CandidateKind.gold, p: 0.9),
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
    expect(goldCell([_outcome(p: 0.9)]), '-');
    expect(goldCell([_outcome(kind: CandidateKind.gold, p: 0.82)]),
        'yes(0.82)');
    expect(goldCell([_outcome(kind: CandidateKind.gold, p: 0.2)]), 'no(0.20)');
    expect(
      goldCell(const [
        ConfirmOutcome(slug: 'fx-a', kind: CandidateKind.gold, p: null),
      ]),
      'failed',
    );
  });
}

ConfirmOutcome _outcome({
  String slug = 'fx-effort-01',
  CandidateKind kind = CandidateKind.extra,
  required double p,
}) =>
    ConfirmOutcome(slug: slug, kind: kind, p: p);

/// A call record in the shape the client emits one, for the arithmetic above.
LlmCallRecord _record({
  required int ms,
  int? promptTokens,
  int? completionTokens,
  String outcome = 'ok',
}) =>
    LlmCallRecord(
      label: 'decision:member_of',
      durationMs: ms,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      outcome: outcome,
    );
