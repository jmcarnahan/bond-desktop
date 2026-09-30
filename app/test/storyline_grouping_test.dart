import 'dart:convert';
import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/storyline_thread_input.dart'
    show storylineThreadTextFor;
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionUnavailableException;
import 'package:bond_inbox/services/storyline_judge.dart' show StorylineJudge;
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The decision grouping: cosine proposes candidate pairs, the decision
/// model's `same_effort` judges each one, the answers are cached in
/// `pair_decisions`, and average linkage over the judged pairs forms the
/// clusters the namer then only writes text for.
///
/// The bench arm since the v3 sweep rows (`StorylineTuning.groupingMode` ships
/// cosine), so every service here is built with `GroupingMode.decision`.
///
/// Every test scripts its `same_effort` answers explicitly — the fake's
/// default is a no — by the thread each state carries, never by call order:
/// which pairs are asked, and in what order, is what several tests here pin.

/// One report from the `clusterObserver` seam.
typedef SeenCluster = ({
  List<({String source, String key})> threads,
  String outcome,
});

/// A unit vector [degrees] around from `[1, 0]`, so the cosine of any two of
/// them is the cosine of the angle between them and a test can write the
/// geometry it means.
List<double> atDegrees(double degrees) {
  final radians = degrees * math.pi / 180;
  return [math.cos(radians), math.sin(radians)];
}

/// [key] with every digit spelled out, so the default subject gives each
/// thread its own series key — subjects differing by a digit run share one,
/// and would be candidate pairs (and a seeded series) whatever the vectors
/// said.
String spellDigits(String key) {
  const words = {
    '0': 'zero',
    '1': 'one',
    '2': 'two',
    '3': 'three',
    '4': 'four',
    '5': 'five',
    '6': 'six',
    '7': 'seven',
    '8': 'eight',
    '9': 'nine',
  };
  final out = StringBuffer();
  for (final rune in key.split('')) {
    final word = words[rune];
    if (word == null) {
      out.write(rune);
    } else {
      out.write(out.isEmpty ? word : ' $word');
    }
  }
  return out.toString();
}

String subjectOf(String key) => 'Subject for ${spellDigits(key)}';

/// The marker [sameEffortAmong] reads a thread by: its seeded body.
String marker(String key) => 'kept-$key';

/// The thread keys a `same_effort` state is about, A then B.
(String, String) keysOf(String state) {
  final (a, b) = pairTextsOf(state);
  String keyIn(String text) =>
      RegExp(r'kept-([A-Za-z0-9]+)').firstMatch(text)!.group(1)!;
  return (keyIn(a), keyIn(b));
}

Map<String, dynamic> nameAnswer() => const {
      'evidence': 'shared deal',
      'title': 'Website redesign',
      'summary': 'The studio is reviewing the homepage copy.',
      'charter': 'The redesign of the Northline Studio website — the homepage '
          'copy, the new photography, and the launch date.',
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One embedded, unfiled thread. [at] is its angle in degrees; the cosine of
  /// any two seeded threads is the cosine of the angle between them.
  Future<void> seed(
    String key, {
    required double at,
    required String lastMessageAt,
    String? subject,
    String? bodyText,
    String? bodyPreview,
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject ?? subjectOf(key),
      'state': 'waiting',
      'last_message_at': lastMessageAt,
      'participants_json': jsonEncode([
        {'name': 'Sarah Chen'},
      ]),
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'kept-$key',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject ?? subjectOf(key),
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': lastMessageAt,
      'body_text': bodyText ?? 'body of kept-$key',
      'body_preview': ?bodyPreview,
      'triage_status': 'triaged',
    });
    await store.upsertConversationAi(
      'email',
      key,
      embedding: encodeEmbedding(atDegrees(at)),
      embeddedHash: 'h-$key',
      embedModel: EmbeddingsClient.modelTag,
    );
  }

  /// [count] threads within a few degrees of each other, newest first: every
  /// pair is a cosine candidate.
  Future<List<String>> seedNear(int count, {String prefix = 'g'}) async {
    final keys = [for (var i = 1; i <= count; i++) '$prefix$i'];
    final now = DateTime.utc(2026, 8, 29, 12);
    for (var i = 0; i < keys.length; i++) {
      await seed(
        keys[i],
        at: i * 0.5,
        lastMessageAt: now.subtract(Duration(minutes: i)).toIso8601String(),
      );
    }
    return keys;
  }

  /// A client whose storyline questions are scripted: `same_effort` by
  /// [sameEffort], and every charter and member a yes over both bars.
  ScriptedLlm llmWith(Object sameEffort) => ScriptedLlm()
    ..answer('storyline_name', nameAnswer())
    ..answer('same_effort', sameEffort)
    ..answer('charter_specific', const {'p': 0.9})
    ..answer('member_of', const {'p': 0.9});

  /// The pairs a client was asked about, as sorted key pairs, once each
  /// (both orders of a pair are one pair).
  Set<(String, String)> askedPairs(ScriptedLlm llm) => {
        for (final call in llm.calls)
          if (call.schemaName == 'same_effort')
          switch (keysOf(call.user)) {
            (final a, final b) => a.compareTo(b) < 0 ? (a, b) : (b, a),
          },
      };

  /// The sweep's own activity row, as a detail map.
  Future<Map<String, Object?>> sweepDetail(
    StorylineService service,
    ActivityLog log,
  ) async {
    await service.sweep();
    await log.record('storyline_sweep', source: 'email', entityId: 'sweep');
    final rows = await store.recentActivity();
    if (rows.isEmpty) return const {};
    return ActivityEvent.fromRow(rows.first).detail;
  }

  Future<int> cachedPairs() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM pair_decisions')
          .getSingle())
      .data['n'] as int;

  group('the decision model judges the pairs', () {
    test('a coherent trio proposes, an incoherent trio does not', () async {
      // Six threads all near each other by cosine, so every pair is asked.
      // g1, g3 and g5 are one effort; g2, g4 and g6 are three.
      await seedNear(6);
      final llm = llmWith(sameEffortAmong([
        [marker('g1'), marker('g3'), marker('g5')],
      ]));
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), hasLength(15));
      // The namer is asked about the one cluster the pairs formed, and
      // nothing else: the incoherent trio never reaches it.
      expect(llm.callsFor('storyline_name'), 1);
      expect(seen, hasLength(1));
      expect([for (final t in seen.single.threads) t.key], ['g1', 'g3', 'g5']);
      expect(seen.single.outcome, 'formed');
      final storylines = await store.loadStorylines(statuses: ['suggested']);
      expect(storylines, hasLength(1));
      expect(
        {for (final m in await store.membersOf(storylines.single.id)) m.conversationKey},
        {'g1', 'g3', 'g5'},
      );
    });

    test('an outlier returns to the pool before the namer sees the cluster',
        () async {
      // g1–g3 are one effort with g4; g5 is sure only of g4, which seats it
      // with the rest at a mean of 0.525 and leaves its own mean to the rest
      // at 0.325 — an outlier, dropped before naming.
      await seedNear(5);
      final p = <(String, String), double>{
        ('g1', 'g2'): onLinkScale(0.9),
        ('g1', 'g3'): onLinkScale(0.9),
        ('g2', 'g3'): onLinkScale(0.9),
        ('g4', 'g5'): onLinkScale(1.0),
        ('g1', 'g4'): onLinkScale(0.95),
        ('g2', 'g4'): onLinkScale(0.95),
        ('g3', 'g4'): onLinkScale(0.95),
        ('g1', 'g5'): onLinkScale(0.1),
        ('g2', 'g5'): onLinkScale(0.1),
        ('g3', 'g5'): onLinkScale(0.1),
      };
      final llm = llmWith((LlmCall call) {
        final (a, b) = keysOf(call.user);
        return {'p': p[a.compareTo(b) < 0 ? (a, b) : (b, a)] ?? 0.0};
      });
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          judge: scriptedJudge(store, llm),
          activityLog: log,
          groupingMode: GroupingMode.decision,
        ),
        log,
      );

      final storyline =
          (await store.loadStorylines(statuses: ['suggested'])).single;
      expect(
        {for (final m in await store.membersOf(storyline.id)) m.conversationKey},
        {'g1', 'g2', 'g3', 'g4'},
      );
      // Never judged against the charter: it was not in the cluster named.
      expect(
        llm.calls.where((c) =>
            c.schemaName == 'member_of' && c.user.contains(marker('g5'))),
        isEmpty,
      );
      expect(detail['outliers'], 1);
      expect(await store.assignedOrBlockedKeys('email'), isNot(contains('g5')));
    });

    test('a pair far apart by cosine is never asked', () async {
      await seed('a1', at: 0, lastMessageAt: '2026-08-29T10:00:00Z');
      await seed('a2', at: 1, lastMessageAt: '2026-08-29T09:00:00Z');
      await seed('b1', at: 90, lastMessageAt: '2026-08-29T08:00:00Z');
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), {('a1', 'a2')});
    });

    test('each thread proposes only its nearest neighbours', () async {
      // Twelve threads at one angle: every cosine ties, so each thread's
      // nearest ten are the first ten others in pool order. The two OLDEST
      // threads each list the ten newest and never each other, so every pair
      // but that one is asked.
      final keys = <String>[];
      for (var i = 0; i < 12; i++) {
        final key = 'n${String.fromCharCode(97 + i)}';
        keys.add(key);
        await seed(
          key,
          at: 0,
          lastMessageAt:
              DateTime.utc(2026, 8, 29, 12).subtract(Duration(minutes: i))
                  .toIso8601String(),
        );
      }
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      final asked = askedPairs(llm);
      expect(asked, hasLength(12 * 11 ~/ 2 - 1));
      expect(asked, isNot(contains((keys[10], keys[11]))));
    });

    test('two threads sharing a series key are asked whatever the cosine says',
        () async {
      // Orthogonal vectors, one folded subject: a series pre-pass needs three
      // to seed, so both stay in the pool, and the subject makes them a
      // candidate pair the vector never would.
      await seed('s1',
          at: 0,
          subject: 'Budget review 2026-09-01',
          lastMessageAt: '2026-08-29T10:00:00Z');
      await seed('s2',
          at: 90,
          subject: 'Budget review 2026-09-08',
          lastMessageAt: '2026-08-29T09:00:00Z');
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), {('s1', 's2')});
    });

    test('a fragment of one subject outside the fold window is asked too',
        () async {
      // One subject, one set of people, three weeks apart: too far apart for
      // the fragment fold, so both reach the pool — and the fragment key is
      // a series key, so the pair is a candidate.
      await seed('f1',
          at: 0,
          subject: 'Studio keys',
          lastMessageAt: '2026-08-29T10:00:00Z');
      await seed('f2',
          at: 90,
          subject: 'Re: Studio keys',
          lastMessageAt: '2026-08-05T10:00:00Z');
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), {('f1', 'f2')});
    });
  });

  group('a cluster is completed before it is named', () {
    test('a trio whose third pair was never a candidate is completed, not '
        'dropped', () async {
      // t1 and t3 sit 120 degrees apart, under the retrieval floor, so the
      // vector never proposes them; t2 is 60 degrees from each. The two
      // answered pairs form the trio, and its missing pair is asked before
      // the trio is named.
      await seed('t1', at: 0, lastMessageAt: '2026-08-29T10:00:00Z');
      await seed('t2', at: 60, lastMessageAt: '2026-08-29T09:00:00Z');
      await seed('t3', at: 120, lastMessageAt: '2026-08-29T08:00:00Z');
      final llm = llmWith(sameEffortAmong([
        [marker('t1'), marker('t2'), marker('t3')],
      ]));

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), {('t1', 't2'), ('t2', 't3'), ('t1', 't3')});
      final storyline =
          (await store.loadStorylines(statuses: ['suggested'])).single;
      expect(
        {for (final m in await store.membersOf(storyline.id)) m.conversationKey},
        {'t1', 't2', 't3'},
      );
    });

    test('a completed pair that says no takes the cluster apart', () async {
      // The same geometry, but the pair nobody proposed is a no: on the full
      // matrix t1 and t3 average (0.9 + 0.05) / 2 against the rest, under
      // the bar on its own scale ([onLinkScale]), and the trio does not
      // survive to be named.
      await seed('t1', at: 0, lastMessageAt: '2026-08-29T10:00:00Z');
      await seed('t2', at: 60, lastMessageAt: '2026-08-29T09:00:00Z');
      await seed('t3', at: 120, lastMessageAt: '2026-08-29T08:00:00Z');
      // t1–t2 and t2–t3 yes, so the optimistic round forms the chain.
      final llm = llmWith((LlmCall call) {
        final (a, b) = keysOf(call.user);
        final pair = ([a, b]..sort()).join(' ');
        return {'p': onLinkScale(pair == 't1 t3' ? 0.05 : 0.9)};
      });

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), contains(('t1', 't3')));
      expect(llm.callsFor('storyline_name'), 0);
    });

    test('a large effort whose threads are not all neighbours forms whole',
        () async {
      // Four threads 50 degrees apart: only neighbours clear the retrieval
      // floor, so the vector proposes a chain of three pairs. Read as zero,
      // the three unproposed pairs would split the effort into pairs; asked,
      // they complete it.
      for (var i = 0; i < 4; i++) {
        await seed('e${String.fromCharCode(97 + i)}',
            at: i * 50.0,
            lastMessageAt: '2026-08-29T1$i:00:00Z');
      }
      final llm = llmWith(sameEffortAmong([
        [marker('ea'), marker('eb'), marker('ec'), marker('ed')],
      ]));

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), hasLength(6));
      final storyline =
          (await store.loadStorylines(statuses: ['suggested'])).single;
      expect(await store.membersOf(storyline.id), hasLength(4));
    });

    test('a cluster the budget cannot complete waits for the next pass',
        () async {
      // Fifty threads at one angle propose 445 pairs, and the first pass
      // spends all 400 of its budget on the newest of them. baa, baj and bba
      // are one effort; their pair baj–bba is one of the 45 left over, so the
      // trio forms on its two answered pairs and cannot be completed.
      String keyAt(int i) => 'b${i.toString().padLeft(2, '0')}'
          .replaceAllMapped(RegExp(r'\d'), (m) => 'abcdefghij'[int.parse(m[0]!)]);
      for (var i = 0; i < 50; i++) {
        await seed(
          keyAt(i),
          at: 0,
          lastMessageAt:
              DateTime.utc(2026, 8, 29, 12).subtract(Duration(minutes: i))
                  .toIso8601String(),
        );
      }
      final llm = llmWith(sameEffortAmong([
        [marker(keyAt(0)), marker(keyAt(9)), marker(keyAt(10))],
      ]));
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service = StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        activityLog: log,
        groupingMode: GroupingMode.decision,
      );

      final first = await sweepDetail(service, log);

      expect(first['clusters_deferred'], 1);
      expect(first['pairs_scored'], StorylinePolicy.pairBudgetPerPass);
      expect(llm.callsFor('storyline_name'), 0);
      expect(await store.loadStorylines(), isEmpty);

      final second = await sweepDetail(service, log);

      expect(second['clusters_deferred'], 0);
      final storyline =
          (await store.loadStorylines(statuses: ['suggested'])).single;
      expect(
        {for (final m in await store.membersOf(storyline.id)) m.conversationKey},
        {keyAt(0), keyAt(9), keyAt(10)},
      );
    });
  });

  group('the pair cache', () {
    test('a second pass asks nothing it already knows', () async {
      await seedNear(4);
      final decision = FakeDecisionClient.storyline();
      final judge = StorylineJudge(decision: decision, store: store);
      final service = StorylineService(
        store,
        ScriptedLlm(),
        judge: judge,
        groupingMode: GroupingMode.decision,
      );

      await service.sweep();
      expect(decision.statesFor(StorylineQuestion.sameEffort), hasLength(12));
      expect(await cachedPairs(), 6);

      decision.asks.clear();
      await service.sweep();
      expect(decision.statesFor(StorylineQuestion.sameEffort), isEmpty);
    });

    test('a thread whose text changed is asked again, and only its pairs',
        () async {
      await seedNear(4);
      final llm = llmWith(const {'p': 0.0});
      final service = StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      );
      await service.sweep();
      llm.calls.clear();

      // A new message on g2 changes its rendered text and so its hash.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'late-g2',
        'conversation_key': 'g2',
        'direction': 'inbound',
        'subject': subjectOf('g2'),
        'from_name': 'Sarah',
        'from_address': 'sarah@example.com',
        'received_at': '2026-08-29T13:00:00Z',
        'body_text': 'one more thing on this',
        'triage_status': 'triaged',
      });
      await service.sweep();

      expect(askedPairs(llm), {('g1', 'g2'), ('g2', 'g3'), ('g2', 'g4')});
    });

    test('answers the same model gave are used without asking', () async {
      await seedNear(3);
      final hashes = <String, String>{
        for (final key in ['g1', 'g2', 'g3'])
          key: (await storylineThreadTextFor(store, 'email', key)).cardHash,
      };
      await store.writePairDecisions([
        (a: hashes['g1']!, b: hashes['g2']!, p: 0.9),
        (a: hashes['g3']!, b: hashes['g1']!, p: 0.9),
        (a: hashes['g2']!, b: hashes['g3']!, p: 0.9),
      ], decidedBy: '$decisionQhash|fake-model');
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(llm.callsFor('same_effort'), 0);
      // The cached yeses formed the trio.
      expect(await store.loadStorylines(statuses: ['suggested']), hasLength(1));
    });

    test('answers under another question set are asked again', () async {
      await seedNear(3);
      final hashes = <String, String>{
        for (final key in ['g1', 'g2', 'g3'])
          key: (await storylineThreadTextFor(store, 'email', key)).cardHash,
      };
      await store.writePairDecisions([
        (a: hashes['g1']!, b: hashes['g2']!, p: 0.9),
        (a: hashes['g1']!, b: hashes['g3']!, p: 0.9),
        (a: hashes['g2']!, b: hashes['g3']!, p: 0.9),
      ], decidedBy: 'an-older-qhash|fake-model');
      final llm = llmWith(const {'p': 0.0});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      ).sweep();

      expect(askedPairs(llm), hasLength(3));
      expect(await store.loadStorylines(statuses: ['suggested']), isEmpty);
    });

    test('a decision backend swapped in re-asks every pair, and switching back '
        'finds the first cache warm', () async {
      await seedNear(3);
      final llm = llmWith(const {'p': 0.0});
      final decision = ScriptedDecisionClient(llm);
      final service = StorylineService(
        store,
        llm,
        judge: StorylineJudge(decision: decision, store: store),
        groupingMode: GroupingMode.decision,
      );

      await service.sweep();
      expect(askedPairs(llm), hasLength(3));
      llm.calls.clear();

      // The same model: every pair read back.
      await service.sweep();
      expect(llm.callsFor('same_effort'), 0);

      // Another model behind the same role (Kev on Your server in place of
      // this Mac's ModernBERT, or a re-installed heads file).
      decision.identity = 'systemone:kev-4b';
      await service.sweep();
      expect(askedPairs(llm), hasLength(3));
      // Both backends' answers stay: the prune is by age only, and every
      // read filters on its own key.
      final byModel = await db
          .customSelect(
              'SELECT DISTINCT qhash FROM pair_decisions ORDER BY qhash')
          .get();
      expect([for (final r in byModel) r.data['qhash']], [
        '$decisionQhash|fake-model',
        '$decisionQhash|systemone:kev-4b',
      ]);

      // Back to the first backend: nothing is asked again.
      decision.identity = 'fake-model';
      llm.calls.clear();
      await service.sweep();
      expect(llm.callsFor('same_effort'), 0);
    });

    test('rows older than a month are pruned at the top of a pass', () async {
      await seedNear(3);
      final llm = llmWith(const {'p': 0.0});
      final service = StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.decision,
      );
      await service.sweep();
      await store.writePairDecisions(const [
        (a: 'old-a', b: 'old-b', p: 0.9),
      ], decidedBy: '$decisionQhash|fake-model');
      await db.customUpdate(
        "UPDATE pair_decisions SET decided_at = '2020-01-01T00:00:00.000000Z' "
        "WHERE a_hash = 'old-a'",
      );
      expect(await cachedPairs(), 4);

      await service.sweep();

      expect(await cachedPairs(), 3);
    });

    test('the budget caps new pairs per pass, newest first, and the cache '
        'carries the rest', () async {
      // Fifty threads at one angle propose 445 pairs (see the neighbour test
      // for the shape): 400 are asked, 45 wait for the next pass.
      for (var i = 0; i < 50; i++) {
        await seed(
          'b${i.toString().padLeft(2, '0')}'
              .replaceAllMapped(RegExp(r'\d'), (m) => 'abcdefghij'[int.parse(m[0]!)]),
          at: 0,
          lastMessageAt:
              DateTime.utc(2026, 8, 29, 12).subtract(Duration(minutes: i))
                  .toIso8601String(),
        );
      }
      final decision = FakeDecisionClient.storyline();
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service = StorylineService(
        store,
        ScriptedLlm(),
        judge: StorylineJudge(decision: decision, store: store),
        activityLog: log,
        groupingMode: GroupingMode.decision,
      );

      final first = await sweepDetail(service, log);
      expect(first['pairs_scored'], StorylinePolicy.pairBudgetPerPass);
      expect(first['pairs_deferred'], 45);
      expect(first['pairs_cached'], 0);
      // Newest first: every pair of the newest thread was asked.
      final newest = (await storylineThreadTextFor(store, 'email', 'baa')).text;
      expect(
        decision
            .statesFor(StorylineQuestion.sameEffort)
            .where((state) => state.contains(newest)),
        isNotEmpty,
      );

      final second = await sweepDetail(service, log);
      expect(second['pairs_scored'], 45);
      expect(second['pairs_deferred'], 0);
      expect(second['pairs_cached'], 400);
    });

    test('a batch that fails parks the pass and keeps the batches before it',
        () async {
      // Twelve threads propose 65 pairs: a batch of 50, then one of 15.
      for (var i = 0; i < 12; i++) {
        await seed(
          'n${String.fromCharCode(97 + i)}',
          at: 0,
          lastMessageAt:
              DateTime.utc(2026, 8, 29, 12).subtract(Duration(minutes: i))
                  .toIso8601String(),
        );
      }
      final decision = _FailingPairs(failOn: 2);
      final service = StorylineService(
        store,
        ScriptedLlm(),
        judge: StorylineJudge(decision: decision, store: store),
        groupingMode: GroupingMode.decision,
      );

      await expectLater(
        service.sweep(),
        throwsA(isA<DecisionUnavailableException>()),
      );
      expect(await cachedPairs(), 50);

      decision.failOn = null;
      decision.asks.clear();
      await service.sweep();
      expect(decision.statesFor(StorylineQuestion.sameEffort), hasLength(30));
      expect(await cachedPairs(), 65);
    });
  });

  group('readiness and the body fetch', () {
    test('a parked decision model asks nothing, fetches nothing and writes '
        'nothing', () async {
      await seedNear(4);
      final decision = FakeDecisionClient.storyline()
        ..askError = const DecisionUnavailableException('decide is down');
      var fetches = 0;
      final llm = llmWith(const {'p': 0.9});

      await expectLater(
        StorylineService(
          store,
          llm,
          judge: StorylineJudge(
            decision: decision,
            store: store,
            ensureBodies: (_, _, _) async => fetches++,
          ),
          groupingMode: GroupingMode.decision,
        ).sweep(),
        throwsA(isA<DecisionUnavailableException>()),
      );

      expect(decision.readyChecks, 1);
      expect(decision.asks, isEmpty);
      expect(llm.calls, isEmpty);
      expect(fetches, 0);
      expect(await cachedPairs(), 0);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('a failed body fetch is not retried by the next pass inside five '
        'minutes', () async {
      await seed('p1',
          at: 0,
          bodyText: '',
          bodyPreview: 'preview of kept-p1',
          lastMessageAt: '2026-08-29T10:00:00Z');
      var fetches = 0;
      final judge = StorylineJudge(
        decision: FakeDecisionClient.storyline(),
        store: store,
        ensureBodies: (_, _, _) async {
          fetches++;
          throw StateError('mail is down');
        },
      );

      await judge.threadText('email', 'p1');
      judge.beginPass();
      await judge.threadText('email', 'p1');

      // A new pass forgets what landed, not what failed.
      expect(fetches, 1);
    });

    test('a thread showing its preview is fetched once per pass, however '
        'many questions read it', () async {
      // Every body is empty and the fetch fills nothing, so the preview is
      // still showing at every judgement: the pairs and the member confirms
      // all read these threads, and only the first asks for the body.
      final now = DateTime.utc(2026, 8, 29, 12);
      for (var i = 1; i <= 3; i++) {
        await seed(
          'p$i',
          at: i * 0.5,
          bodyText: '',
          bodyPreview: 'preview of kept-p$i',
          lastMessageAt: now.subtract(Duration(minutes: i)).toIso8601String(),
        );
      }
      final fetched = <String, int>{};
      final llm = llmWith(const {'p': 0.9});
      final service = StorylineService(
        store,
        llm,
        judge: StorylineJudge(
          decision: ScriptedDecisionClient(llm),
          store: store,
          ensureBodies: (_, key, _) async =>
              fetched[key] = (fetched[key] ?? 0) + 1,
        ),
        groupingMode: GroupingMode.decision,
      );

      await service.sweep();

      expect(llm.callsFor('member_of'), 3);
      expect(fetched, {'p1': 1, 'p2': 1, 'p3': 1});
    });
  });

  group('determinism and the baseline', () {
    test('two identical mailboxes group identically', () async {
      Future<List<Set<String>>> run(MessageStore into) async {
        final llm = llmWith(sameEffortAmong([
          [marker('g1'), marker('g2'), marker('g4')],
          [marker('g3'), marker('g5'), marker('g6')],
        ]));
        await StorylineService(
          into,
          llm,
          judge: scriptedJudge(into, llm),
          groupingMode: GroupingMode.decision,
        ).sweep();
        return [
          for (final s in await into.loadStorylines(statuses: ['suggested']))
            {for (final m in await into.membersOf(s.id)) m.conversationKey},
        ];
      }

      await seedNear(6);
      final first = await run(store);

      final otherDb = testDb();
      addTearDown(otherDb.close);
      final other = MessageStore(otherDb);
      final saved = store;
      store = other;
      await seedNear(6);
      store = saved;
      final second = await run(other);

      expect(first, hasLength(2));
      expect(second, first);
    });

    test('the cosine grouping asks no pair question', () async {
      await seedNear(4);
      final llm = llmWith(const {'p': 0.9});

      await StorylineService(
        store,
        llm,
        judge: scriptedJudge(store, llm),
        groupingMode: GroupingMode.cosine,
      ).sweep();

      expect(llm.callsFor('same_effort'), 0);
      expect(await cachedPairs(), 0);
      expect(await store.loadStorylines(statuses: ['suggested']), hasLength(1));
    });

    test('the cosine grouping ships, the decision grouping is the bench arm',
        () {
      expect(StorylineTuning.groupingMode, GroupingMode.cosine);
      expect(StorylineTuning.charterCheck, CharterCheck.model);
    });
  });

  test('the pair cache is keyed by both hashes in order, under its model',
      () async {
    await store.writePairDecisions(const [
      (a: 'zz', b: 'aa', p: 0.7),
    ], decidedBy: 'q1');

    final row = (await db
            .customSelect(
                'SELECT a_hash, b_hash, qhash, p FROM pair_decisions')
            .getSingle())
        .data;
    expect(row, {'a_hash': 'aa', 'b_hash': 'zz', 'qhash': 'q1', 'p': 0.7});
    expect(await store.pairDecisionsFor(['zz', 'aa', 'mm'], 'q1'),
        {('aa', 'zz'): 0.7});
    expect(await store.pairDecisionsFor(['zz', 'aa'], 'q2'), isEmpty);
    expect(await store.pairDecisionsFor(['zz'], 'q1'), isEmpty);
  });
}

/// A storyline decision client whose [failOn]-th `same_effort` batch throws
/// the park, and which answers every other state no.
class _FailingPairs extends FakeDecisionClient {
  _FailingPairs({this.failOn})
      : super((_) => throw StateError('decide never called'));

  int? failOn;
  int _pairBatches = 0;

  @override
  Future<List<double>> ask(
    StorylineQuestion question,
    List<String> states,
  ) async {
    if (question == StorylineQuestion.sameEffort) {
      _pairBatches++;
      if (_pairBatches == failOn) {
        throw const DecisionUnavailableException('decide went down');
      }
    }
    return super.ask(question, states);
  }
}
