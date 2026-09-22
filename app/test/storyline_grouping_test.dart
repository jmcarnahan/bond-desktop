import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The model-read grouping: the cosine pass draws a neighbourhood and
/// [GroupThreadsTask] says what is inside it.
///
/// Dark behind `StorylineTuning.groupingMode`, which reads
/// `GroupingMode.cosine` on every shipped build, so every test here but the
/// last passes the mode in through the service's test-only constructor
/// parameter rather than flipping a const the rest of the suite reads.
///
/// Nothing here scripts a group by NUMBER. The cards are numbered in
/// centrality order, which is the service's business and not a thing a test
/// should hard-code; instead [groupLlm] is told which THREADS go together
/// and reads the numbering off the call it was handed. What the tests pin is
/// the mapping back — that the numbers the model answers with come home to the
/// threads whose cards carried them.

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
/// thread its own series key — three subjects differing by a digit run read as
/// one recurring series to the sweep's pre-pass and never reach the pool.
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

/// The body of the one fence in a built user message.
String fenceBody(String message) => message
    .split('<untrusted_data source="threads">')
    .last
    .split('</untrusted_data>')
    .first;

/// The thread keys of a grouping call's cards, in the order the service
/// numbered them.
List<String> numberedKeys(String user, Iterable<String> keys) => [
      for (final card in fenceBody(user).split('\n---\n'))
        keys.firstWhere(
          (key) => card.contains(subjectOf(key)),
          orElse: () => throw StateError('no known thread in card: $card'),
        ),
    ];

/// The thread keys each grouping call was sent, in call order.
///
/// Read back out of the user messages the client recorded rather than kept
/// in a field of its own: the numbering IS what the service built, so
/// deriving it cannot drift from the call it describes.
List<List<String>> numberingsOf(ScriptedLlm llm, Iterable<String> keys) => [
      for (final call in llm.calls)
        if (call.schemaName == 'storyline_group')
          numberedKeys(call.user, keys),
    ];

/// The grouping answer, computed from the call the service actually made.
///
/// [groups] names the threads that go together, in call order, the last entry
/// repeating once the list runs out; [rawGroups] writes them as card NUMBERS
/// instead, for the cases about numbers no card carries, and takes precedence.
/// Either way the mapping back through the numbering is the whole point, so
/// it happens here, where the call is.
FutureOr<Map<String, dynamic>> Function(LlmCall) groupingAnswer({
  required List<String> keys,
  List<List<List<String>>> groups = const [],
  List<List<int>>? rawGroups,
}) {
  var calls = 0;
  return (LlmCall call) {
    final order = numberedKeys(call.user, keys);
    final at = calls++;
    if (rawGroups case final List<List<int>> raw) {
      return {
        'groups': [
          for (final group in raw)
            {'threads': group, 'why': 'They are one specific piece of work.'},
        ],
      };
    }
    final answer = groups.isEmpty
        ? const <List<String>>[]
        : groups[at < groups.length ? at : groups.length - 1];
    return {
      'groups': [
        for (final group in answer)
          {
            'threads': [
              for (final key in group)
                if (order.contains(key)) order.indexOf(key) + 1,
            ],
            'why': 'They are one specific piece of work.',
          },
      ],
    };
  };
}

/// A client that answers from a per-schema script, and answers a grouping call
/// from a list of thread KEYS mapped back through the numbering the service
/// actually sent. [groupThrows] is thrown instead of answering one.
ScriptedLlm groupLlm({
  required List<String> keys,
  Map<String, List<Object>> scripts = const {},
  List<List<List<String>>> groups = const [],
  Object? groupThrows,
  List<List<int>>? rawGroups,
}) {
  final llm = ScriptedLlm();
  scripts.forEach(llm.scriptFor);
  llm.answer(
    'storyline_group',
    groupThrows ??
        groupingAnswer(keys: keys, groups: groups, rawGroups: rawGroups),
  );
  return llm;
}

Map<String, dynamic> confirmAnswer() => const {
      'evidence': 'Both concern the same specific piece of work.',
      'belongs': true,
      'confidence': 'high',
    };

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
    MessageStore into,
    String key, {
    required double at,
    required String lastMessageAt,
  }) async {
    await into.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subjectOf(key),
      'state': 'waiting',
      'last_message_at': lastMessageAt,
      'participants_json': jsonEncode([
        {'name': 'Sarah Chen'},
      ]),
    });
    await into.upsertMessage({
      'source': 'email',
      'source_message_id': 'kept-$key',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subjectOf(key),
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': lastMessageAt,
      'body_text': 'body of kept-$key',
      'triage_status': 'triaged',
    });
    await into.upsertConversationAi(
      'email',
      key,
      embedding: encodeEmbedding(atDegrees(at)),
      embeddedHash: 'h-$key',
      embedModel: EmbeddingsClient.modelTag,
    );
  }

  /// Seven threads within twelve degrees of each other: every pair is far
  /// above `groupingNeighbourhoodThreshold`, so they are ONE neighbourhood,
  /// and seven cards fit one call.
  Future<List<String>> seedOneNeighbourhood(MessageStore into) async {
    final keys = [for (var i = 1; i <= 7; i++) 'g$i'];
    for (var i = 0; i < keys.length; i++) {
      await seed(
        into,
        keys[i],
        at: i * 2,
        // Newest first, which is the pool's own order.
        lastMessageAt: '2026-08-2${9 - i}T10:00:00Z',
      );
    }
    return keys;
  }

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

  group('the model reads a neighbourhood', () {
    test('two groups become two clusters and the outlier joins neither',
        () async {
      // Seven and not five: a group under `proposeMinClusterSize` is dropped,
      // so two proposable groups plus a thread that belongs to neither is
      // three plus three plus one.
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g1', 'g2', 'g3'],
            ['g4', 'g5', 'g6'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        groupingMode: GroupingMode.model,
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
      ).sweep();

      final numberings = numberingsOf(llm, keys);

      // One call over the whole neighbourhood, then a naming call per group.
      expect(llm.callsFor('storyline_group'), 1);
      expect(llm.callsFor('storyline_name'), 2);
      expect(numberings.single.toSet(), keys.toSet());
      // Two clusters, in the order the model named them, members ascending in
      // the pool's order.
      expect(
        [for (final cluster in seen) cluster.threads.map((t) => t.key).toList()],
        [
          ['g1', 'g2', 'g3'],
          ['g4', 'g5', 'g6'],
        ],
      );
      // And the seventh is in nothing: two storylines of three.
      final storylines = await store.loadStorylines(statuses: const ['suggested']);
      expect(storylines, hasLength(2));
      for (final storyline in storylines) {
        expect(await store.membersOf(storyline.id), hasLength(3));
      }
    });

    test('the call is made at temperature 0, on the naming client', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g1', 'g2', 'g3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );

      await StorylineService(store, llm, groupingMode: GroupingMode.model)
          .sweep();

      // Determinism rests on it: the tombstone recognises a cluster by its
      // member set, so a pass that grouped differently on a second run would
      // re-propose what the user threw away.
      expect(llm.temperatures[llm.schemas.indexOf('storyline_group')], 0);
    });

    test('a group under the propose floor is dropped', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g1', 'g2'],
          ],
        ],
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      // A pair is a coincidence describing itself: the confirms judge it
      // against a charter written from those same two threads.
      expect(llm.callsFor('storyline_name'), 0);
      expect(await store.loadStorylines(), isEmpty);
      expect(detail['grouping_calls'], 1);
      expect(detail['grouped'], 0);
      expect(detail['grouping_failed'], 0);
    });

    test('a number the model repeated is used once', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g1', 'g2', 'g1', 'g3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        groupingMode: GroupingMode.model,
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
      ).sweep();

      expect(seen.single.threads.map((t) => t.key), ['g1', 'g2', 'g3']);
      expect(await store.membersOf((await store.loadStorylines()).single.id),
          hasLength(3));
    });

    test('an answer naming nothing leaves the neighbourhood ungrouped',
        () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(keys: keys, groups: const [[]]);
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      expect(detail['grouping_calls'], 1);
      expect(detail['grouping_failed'], 1);
      expect(detail['grouped'], 0);
      expect(await store.loadStorylines(), isEmpty);
    });
  });

  group('a grouping call that fails', () {
    test('counts and carries on, rather than ending the pass', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groupThrows: const LlmFormatException('not an object'),
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      expect(detail['grouping_calls'], 1);
      expect(detail['grouping_failed'], 1);
      expect(detail['grouped'], 0);
      expect(detail['grouping_unfit'], 0);
      expect(llm.callsFor('storyline_name'), 0);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('an unavailable server parks the pass instead', () async {
      // The namer's own behaviour, matched: the work row goes back pending
      // with its attempt unspent rather than the mailbox being written off as
      // ungroupable because a server was down for an afternoon.
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groupThrows: const LlmUnavailableException('server down'),
      );

      await expectLater(
        StorylineService(store, llm, groupingMode: GroupingMode.model).sweep(),
        throwsA(isA<LlmUnavailableException>()),
      );
    });
  });

  group('a neighbourhood the card budget cannot hold', () {
    /// [near] threads on one axis and [far] threads 64° off it. Every cross
    /// pair sits at cosine 0.438: above `groupingNeighbourhoodThreshold`
    /// (0.41) so the two sets are one neighbourhood, and below the first rung
    /// of the split ladder (0.46) so they come apart at exactly that seam.
    Future<List<String>> seedTwoLobes(int near, int far) async {
      final keys = <String>[];
      var stamp = 40;
      for (var i = 1; i <= near; i++) {
        keys.add('n$i');
        await seed(store, 'n$i',
            at: 0, lastMessageAt: '2026-08-29T10:${stamp--}:00Z');
      }
      for (var i = 1; i <= far; i++) {
        keys.add('f$i');
        await seed(store, 'f$i',
            at: 64, lastMessageAt: '2026-08-29T10:${stamp--}:00Z');
      }
      return keys;
    }

    test('splits up the ladder into pieces that each fit, grouped separately',
        () async {
      // Thirteen threads, one more than the twelve whole cards a call holds.
      final keys = await seedTwoLobes(7, 6);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['n1', 'n2', 'n3'],
          ],
          [
            ['f1', 'f2', 'f3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      final numberings = numberingsOf(llm, keys);

      // Two calls, one per piece, and neither piece was truncated: seven
      // cards then six, every thread shown exactly once.
      expect(detail['grouping_calls'], 2);
      expect(detail['grouping_unfit'], 0);
      expect(detail['grouped'], 6);
      expect(numberings.map((order) => order.length), [7, 6]);
      expect(
        {for (final order in numberings) ...order},
        keys.toSet(),
      );
      expect(llm.callsFor('storyline_name'), 2);
    });

    test('a piece too small to group is counted unfit and never asked',
        () async {
      // Eleven on one axis and two on the other: the split leaves a piece of
      // two, which is under `groupingNeighbourhoodMinSize`.
      final keys = await seedTwoLobes(11, 2);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['n1', 'n2', 'n3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      expect(detail['grouping_calls'], 1);
      expect(detail['grouping_unfit'], 1);
      expect(numberingsOf(llm, keys).single, hasLength(11));
      // Nothing was asked about the pair, so nothing is tombstoned either.
      expect(await store.dismissedHashExistsAny(const ['nothing']), isFalse);
    });
  });

  group('the order and the budget', () {
    test('the clusters come back largest first, ties by first member',
        () async {
      // The same order `clusterBySimilarity` hands the cosine path back in,
      // and it decides what ships: the sweep breaks at `room`, so a proposal
      // of four threads should take a slot ahead of one of three however the
      // model happened to list them.
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g1', 'g2', 'g3'],
            ['g4', 'g5', 'g6', 'g7'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        groupingMode: GroupingMode.model,
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
      ).sweep();

      expect(
        [for (final cluster in seen) cluster.threads.map((t) => t.key).toList()],
        [
          ['g4', 'g5', 'g6', 'g7'],
          ['g1', 'g2', 'g3'],
        ],
      );
    });

    test('two groups of a size are ordered by their first member', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['g5', 'g6', 'g7'],
            ['g1', 'g2', 'g3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        groupingMode: GroupingMode.model,
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
      ).sweep();

      expect(
        [for (final cluster in seen) cluster.threads.first.key],
        ['g1', 'g5'],
      );
    });

    test('the room the sweep has left is a budget on the CALLS', () async {
      // Three neighbourhoods eighty degrees apart, so no pair across them
      // links at `groupingNeighbourhoodThreshold` and each is a piece of its
      // own. Two suggestions already sitting in the rail leave room for one.
      var stamp = 40;
      final keys = <String>[];
      for (final (lobe, angle) in [('a', 0.0), ('b', 80.0), ('c', 160.0)]) {
        for (var i = 1; i <= 3; i++) {
          keys.add('$lobe$i');
          await seed(store, '$lobe$i',
              at: angle, lastMessageAt: '2026-08-29T10:${stamp--}:00Z');
        }
      }
      for (final id in ['sl-old1', 'sl-old2']) {
        await store.insertStoryline(
          id: id,
          title: 'Something already proposed',
          status: 'suggested',
          createdBy: 'auto',
        );
      }
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['a1', 'a2', 'a3'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      // One call, not three: a prose call per neighbourhood to build a list
      // the caller reads one entry of is the cost this budget exists for.
      expect(detail['grouping_calls'], 1);
      // And the two neighbourhoods never asked about are not `unfit`: nothing
      // was judged about them.
      expect(detail['grouping_unfit'], 0);
      expect(llm.callsFor('storyline_name'), 1);
    });
  });

  group('numbers no card carries', () {
    test('a number past the count and a zero are ignored', () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        rawGroups: const [
          [1, 99, 2, 0, 3, -4],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final seen = <SeenCluster>[];

      await StorylineService(
        store,
        llm,
        groupingMode: GroupingMode.model,
        clusterObserver: (threads, outcome) =>
            seen.add((threads: threads, outcome: outcome)),
      ).sweep();

      // Three real cards left, which still clears the propose floor.
      expect(seen.single.threads, hasLength(3));
      expect(seen.single.threads.map((t) => t.key).toSet(),
          numberingsOf(llm, keys).single.take(3).toSet());
    });

    test('a group is dropped when the numbers it loses take it under the floor',
        () async {
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        rawGroups: const [
          [1, 2, 99],
        ],
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.model,
        ),
        log,
      );

      expect(detail['grouping_calls'], 1);
      expect(detail['grouped'], 0);
      expect(await store.loadStorylines(), isEmpty);
    });
  });

  group('the whole pool, in chunks of its own order', () {
    /// [count] threads spread right round the circle, so no two consecutive
    /// pool rows are neighbours and the cosine pass would draw nothing like
    /// these chunks. `lastMessageAt` strictly descends, which is the pool's
    /// own order.
    ///
    /// The keys are zero-padded to three digits so that no thread's spelled
    /// subject is a PREFIX of another's: `subjectOf('p1')` sits inside
    /// `subjectOf('p11')`, and [numberedKeys] reads a card back by the first
    /// subject it contains.
    Future<List<String>> seedPool(int count) async {
      final keys = <String>[];
      for (var i = 0; i < count; i++) {
        final key = 'p${(i + 1).toString().padLeft(3, '0')}';
        keys.add(key);
        final second = 3599 - i * 30;
        await seed(
          store,
          key,
          at: i * 3.6,
          lastMessageAt: '2026-08-29T10:'
              '${(second ~/ 60).toString().padLeft(2, '0')}:'
              '${(second % 60).toString().padLeft(2, '0')}Z',
        );
      }
      return keys;
    }

    /// The pool in the order the service reads it, which is the order the
    /// chunks are cut from. Read from the store rather than assumed, so the
    /// assertion is about the chunking and not about the seeding.
    Future<List<String>> poolOrder() async => [
          for (final row in await store.conversationsWithEmbeddings(
            embedModel: EmbeddingsClient.modelTag,
            sources: const ['email', 'teams'],
          ))
            row['conversation_key'] as String,
        ];

    test('a hundred threads are three calls, cut in pool order', () async {
      final keys = await seedPool(100);
      final llm = groupLlm(
        keys: keys,
        groups: [
          // The first chunk names three, the second four, the third nothing:
          // the two groups come back largest first however the pool ordered
          // the calls.
          [
            ['p001', 'p002', 'p003'],
          ],
          [
            ['p049', 'p050', 'p051', 'p052'],
          ],
          const [],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final seen = <SeenCluster>[];

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.pool,
          clusterObserver: (threads, outcome) =>
              seen.add((threads: threads, outcome: outcome)),
        ),
        log,
      );

      final numberings = numberingsOf(llm, keys);

      // Three calls of 48, 48 and 4, and not one neighbourhood: the threads
      // are spread round the whole circle, so the cosine ladder would have
      // drawn something else entirely.
      expect(detail['grouping_calls'], 3);
      expect(detail['grouping_unfit'], 0);
      expect(numberings.map((order) => order.length), [48, 48, 4]);

      // Each call holds exactly its slice of the pool's own order. The cards
      // inside one call are ordered by centrality, so the slices are compared
      // as sets.
      final pool = await poolOrder();
      expect(numberings[0].toSet(), pool.sublist(0, 48).toSet());
      expect(numberings[1].toSet(), pool.sublist(48, 96).toSet());
      expect(numberings[2].toSet(), pool.sublist(96).toSet());

      // Largest first, whichever chunk found it.
      expect(
        [for (final cluster in seen) cluster.threads.map((t) => t.key).toList()],
        [
          ['p049', 'p050', 'p051', 'p052'],
          ['p001', 'p002', 'p003'],
        ],
      );
    });

    test('a tail chunk under the minimum is unfit and never asked', () async {
      // Fifty threads: forty-eight in the first chunk and two in the second,
      // which is under `groupingNeighbourhoodMinSize`.
      final keys = await seedPool(50);
      final llm = groupLlm(
        keys: keys,
        groups: [
          [
            ['p001', 'p002', 'p003'],
          ],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.pool,
        ),
        log,
      );

      expect(detail['grouping_calls'], 1);
      expect(detail['grouping_unfit'], 1);
      expect(numberingsOf(llm, keys).single, hasLength(48));
    });

    test('the room the sweep has left does NOT stop the chunk loop', () async {
      // The opposite of the cosine path's rule, deliberately: reading the
      // whole pool is what this mode is for, and `room` is at most three, so a
      // first chunk that filled it would leave the rest of the mailbox unread
      // for the sake of one prose call. A hundred threads, and one suggestion
      // already in the rail so there is room for two.
      final keys = await seedPool(100);
      await store.insertStoryline(
        id: 'sl-old1',
        title: 'Something already proposed',
        status: 'suggested',
        createdBy: 'auto',
      );
      final llm = groupLlm(
        keys: keys,
        groups: [
          // The first chunk alone returns three groups, one more than there is
          // room for.
          [
            ['p001', 'p002', 'p003'],
            ['p004', 'p005', 'p006'],
            ['p007', 'p008', 'p009'],
          ],
          [
            ['p049', 'p050', 'p051'],
          ],
          const [],
        ],
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      final detail = await sweepDetail(
        StorylineService(
          store,
          llm,
          activityLog: log,
          groupingMode: GroupingMode.pool,
        ),
        log,
      );

      // Every chunk was asked, and the fourth group the pool found was seen
      // even though the first chunk had already overrun `room`.
      expect(detail['grouping_calls'], 3);
      expect(detail['grouping_unfit'], 0);
      expect(detail['grouped'], 12);

      // And the caller still spends only what it has: two slots left, two
      // naming calls, two new storylines beside the one already there.
      expect(llm.callsFor('storyline_name'), 2);
      expect(
        await store.loadStorylines(statuses: const ['suggested']),
        hasLength(3),
      );
    });
  });

  group('determinism and the shipped default', () {
    test('two identical mailboxes group identically', () async {
      final otherDb = testDb();
      final other = MessageStore(otherDb);
      addTearDown(otherDb.close);

      Future<List<List<String>>> run(MessageStore into) async {
        final keys = await seedOneNeighbourhood(into);
        final llm = groupLlm(
          keys: keys,
          groups: [
            [
              ['g3', 'g1', 'g2'],
              ['g6', 'g5', 'g4'],
            ],
          ],
          scripts: {
            'storyline_name': [nameAnswer()],
            'storyline_membership': [confirmAnswer()],
          },
        );
        final seen = <SeenCluster>[];
        await StorylineService(
          into,
          llm,
          groupingMode: GroupingMode.model,
          clusterObserver: (threads, outcome) =>
              seen.add((threads: threads, outcome: outcome)),
        ).sweep();
        return [
          for (final cluster in seen) cluster.threads.map((t) => t.key).toList(),
        ];
      }

      final first = await run(store);
      final second = await run(other);

      // Members ascending whatever order the model listed them in, and the
      // groups in the order it named them — which is what keeps a tombstone
      // answering for the same set on a second pass.
      expect(first, [
        ['g1', 'g2', 'g3'],
        ['g4', 'g5', 'g6'],
      ]);
      expect(second, first);
    });

    test('the shipped mode never constructs a grouping call', () async {
      // No `groupingMode` argument: the service takes
      // `StorylineTuning.groupingMode`, and the fake has no grouping answer to
      // give — a call would throw rather than pass quietly.
      final keys = await seedOneNeighbourhood(store);
      final llm = groupLlm(
        keys: keys,
        scripts: {
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        },
      );

      await StorylineService(store, llm).sweep();

      // Cosine and neither of the two dark modes: `model` reads a
      // neighbourhood and `pool` reads the whole pool, and both ship behind a
      // pre-registered rule in `docs/pipeline/06-storylines.md`.
      expect(StorylineTuning.groupingMode, GroupingMode.cosine);
      expect(StorylineTuning.groupingMode, isNot(GroupingMode.model));
      expect(StorylineTuning.groupingMode, isNot(GroupingMode.pool));
      expect(llm.callsFor('storyline_group'), 0);
      expect(llm.schemas, isNot(contains('storyline_group')));
      // And the cosine pass did its own job: one cluster of seven, named.
      expect(llm.callsFor('storyline_name'), 1);
    });
  });
}
