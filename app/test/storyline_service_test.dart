import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bond_inbox/data/conversation_vec_index.dart';
// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
// `show`: the one thing this file wants from the extraction pass is the hash
// function behind both storyline hash recipes.
import 'package:bond_inbox/services/extract_handler.dart' show cardHash;
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

/// An [LlmClient] that answers from a per-schema script and never opens a
/// socket.
///
/// Keyed on `schemaName` rather than on call order because the two storyline
/// tasks interleave: an assignment that confirms a membership may go straight
/// on to name the storyline, and a positional script would silently hand the
/// naming task the next confirmation answer.
class FakeLlm extends LlmClient {
  final Map<String, List<Object>> scripts;

  final List<String> schemas = [];
  final List<String> userMessages = [];
  final List<double> temperatures = [];

  FakeLlm(this.scripts) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  int callsFor(String schemaName) =>
      schemas.where((s) => s == schemaName).length;

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    schemas.add(schemaName);
    userMessages.add(user);
    temperatures.add(temperature);
    await Future<void>.delayed(const Duration(milliseconds: 1));

    final script = scripts[schemaName];
    if (script == null || script.isEmpty) {
      throw StateError('no scripted answer for $schemaName');
    }
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// A [FakeLlm] that runs [onCall] before answering — how a test lands a user
/// action in the middle of a model call.
class HookedFakeLlm extends FakeLlm {
  final Future<void> Function(String schemaName) onCall;

  HookedFakeLlm(super.scripts, this.onCall);

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    await onCall(schemaName);
    return super.completeJson(
      system: system,
      user: user,
      schema: schema,
      schemaName: schemaName,
      maxTokens: maxTokens,
      temperature: temperature,
      think: think,
    );
  }
}

/// A real [MessageStore] over a real database that counts the two reads the
/// assignment pass hoisted out of its candidate loop.
///
/// A count rather than a stub because the store is not mockable and should not
/// be: what these tests pin is that ONE pass makes ONE of each call however
/// many storylines it walks, and only the store can say how many it was asked.
class CountingStore extends MessageStore {
  int memberContextCalls = 0;
  int blockedIdCalls = 0;

  CountingStore(super.db);

  @override
  Future<List<Map<String, Object?>>> memberContextRows(
    List<String> storylineIds, {
    required String embedModel,
  }) {
    memberContextCalls++;
    return super.memberContextRows(storylineIds, embedModel: embedModel);
  }

  @override
  Future<Set<String>> blockedStorylineIdsFor(
    String source,
    String conversationKey,
  ) {
    blockedIdCalls++;
    return super.blockedStorylineIdsFor(source, conversationKey);
  }
}

/// A [MessageStore] that counts the sweep's KNN probes.
///
/// [CountingStore]'s shape and its reason: the store is not mockable and
/// should not be, and only it can say whether the indexed path ran at all. A
/// count of zero is how the equivalence test below would notice that its
/// "indexed" run had quietly fallen back and was comparing the arithmetic
/// against itself.
class ProbingStore extends MessageStore {
  int neighborProbes = 0;

  ProbingStore(super.db);

  @override
  Future<List<({String source, String key, double similarity})>>
      conversationNeighbors(Uint8List vector, {required int k}) {
    neighborProbes++;
    return super.conversationNeighbors(vector, k: k);
  }
}

/// A [MessageStore] that reports no clustering index, whatever this process
/// has loaded.
///
/// The seam for the fallback, overriding the one method that decides: a failed
/// backfill, a missing native extension and a connection opened before the
/// extension was registered all reach the sweep as this same `null`. Faking it
/// here rather than unloading a process-global native extension, which is not
/// something a test can do to the rest of the suite.
class UnindexedStore extends MessageStore {
  UnindexedStore(super.db);

  @override
  Future<int?> prepareConversationIndex({required String embedModel}) async =>
      null;
}

/// A unit vector whose cosine against `[1, 0]` is exactly [c]. Two dimensions
/// is all these tests need — the gates are cosine thresholds, and a 768-wide
/// vector would only make the arithmetic harder to read.
List<double> vectorAt(double c) => [c, math.sqrt(1 - c * c)];

Map<String, dynamic> confirmAnswer({
  String evidence = 'Both concern the website redesign.',
  bool belongs = true,
  String confidence = 'high',
}) =>
    {'evidence': evidence, 'belongs': belongs, 'confidence': confidence};

Map<String, dynamic> nameAnswer({
  String title = 'Website redesign',
  String summary = 'The studio is reviewing the homepage copy.',
  String charter = 'The redesign of the Northline Studio website — the '
      'homepage copy, the new photography, and the launch date.',
}) =>
    {
      'evidence': 'shared deal',
      'title': title,
      'summary': summary,
      'charter': charter,
    };

/// The refresh task's answer. Shaped like [nameAnswer] and defaulted to the
/// text `seedStoryline` already stores, so a test that scripts nothing in
/// particular is scripting the continuity answer — the description coming back
/// unchanged, which is what this pass is supposed to do most of the time.
Map<String, dynamic> refineAnswer({
  String evidence = 'Every thread is still the website redesign.',
  String title = 'Website redesign',
  String summary = 'The studio is reviewing the homepage copy.',
  String charter = 'The redesign of the Northline Studio website — the '
      'homepage copy, the new photography, and the launch date.',
}) =>
    {
      'evidence': evidence,
      'title': title,
      'summary': summary,
      'charter': charter,
    };

/// The recap task's answer. Both lists are non-empty by default, so a test
/// that scripts nothing in particular still exercises the JSON round trip the
/// two columns are for.
Map<String, dynamic> recapAnswer({
  String evidence = 'The studio moved the launch date.',
  String recap = 'The homepage copy is approved and the launch moved to '
      'October 9. Sarah is waiting on the photography.',
  List<String> openItems = const ['Sarah owes the photo selects to Dana'],
  List<String> decisions = const ['Launch moved to October 9'],
}) =>
    {
      'evidence': evidence,
      'recap': recap,
      'open_items': openItems,
      'decisions': decisions,
    };

/// The dedupe key the service writes for a member set, spelled out: the
/// `'<source>\n<key>'` composites, sorted, newline-joined, hashed. The same
/// recipe `_hashOfThreads` uses — written out here rather than reached for,
/// because a test that computed the hash by calling the code under test would
/// agree with it however wrong both were.
String memberHashOf(List<String> keys, {String source = 'email'}) =>
    cardHash(([for (final key in keys) '$source\n$key']..sort()).join('\n'));

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed(
    MessageStore into,
    String key, {
    List<double>? vector,
    List<String> participants = const [],
    String state = 'waiting',
    String lastMessageAt = '2026-08-28T10:00:00Z',
    String? subject,
    String embedModel = EmbeddingsClient.modelTag,
    String source = 'email',
  }) async {
    await into.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject ?? 'Subject for $key',
      'state': state,
      'last_message_at': lastMessageAt,
      'participants_json':
          '[${participants.map((p) => '{"name":"$p"}').join(',')}]',
    });
    if (vector == null) return;
    await into.upsertConversationAi(
      source,
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: 'h-$key',
      embedModel: embedModel,
    );
  }

  /// One message on a thread, and with it the `message_progress` row
  /// `upsertMessage` writes — the row the storyline pointer lands on.
  Future<void> seedMessage(
    MessageStore into,
    String key,
    String id, {
    String receivedAt = '2026-08-28T10:00:00Z',
    String source = 'email',
    String direction = 'inbound',
    String fromName = 'Sarah',
    String? body,
  }) =>
      into.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': direction,
        'subject': 'Subject for $key',
        'from_name': fromName,
        'from_address': 'sarah@example.com',
        'received_at': receivedAt,
        'body_text': body ?? 'body of $id',
      });

  /// The storyline pointer one message carries, straight from the column the
  /// home feed joins on.
  Future<String?> pointerOf(String id, {String source = 'email'}) async =>
      (await db
              .customSelect(
                'SELECT storyline_id FROM message_progress '
                'WHERE source = ? AND source_message_id = ?',
                variables: [Variable(source), Variable(id)],
              )
              .getSingle())
          .data['storyline_id'] as String?;

  /// Pins when a membership was made. `added_at` is written at millisecond
  /// resolution, and every test below that turns on WHICH membership is oldest
  /// says so here rather than trusting two writes to land in different
  /// milliseconds.
  Future<void> memberAddedAt(String id, String key, String iso) =>
      db.customUpdate(
        'UPDATE storyline_members SET added_at = ? '
        'WHERE storyline_id = ? AND source = ? AND conversation_key = ?',
        variables: [Variable(iso), Variable(id), const Variable('email'),
            Variable(key)],
      );

  /// A storyline with one member, both already embedded.
  Future<void> seedStoryline(
    MessageStore into, {
    String id = 'sl-1',
    String status = 'active',
    String? summary = 'The studio is reviewing the homepage copy.',
    // A storyline named since charters existed has one. The tests that care
    // about the backfill pass null and say so.
    String? charter = 'The redesign of the Northline Studio website — the '
        'homepage copy, the new photography, and the launch date.',
    bool titleLocked = false,
    String memberKey = 'member',
    List<double>? memberVector,
    List<String> memberParticipants = const ['Sarah Chen'],
  }) async {
    await seed(
      into,
      memberKey,
      vector: memberVector ?? vectorAt(1),
      participants: memberParticipants,
    );
    await into.insertStoryline(
      id: id,
      title: 'Website redesign',
      summary: summary,
      charter: charter,
      status: status,
      createdBy: 'auto',
    );
    if (titleLocked) await into.updateStoryline(id, titleLocked: true);
    await into.addStorylineMember(id, 'email', memberKey, addedBy: 'auto');
  }

  /// Runs the refresh a preceding action queued, exactly as
  /// `StorylineRefreshHandler` would: take the pending row, hand its entity id
  /// to the service.
  ///
  /// Every path that changes a storyline's membership now QUEUES the
  /// re-description instead of making it inline, so a test about what the
  /// description says has two halves — the action, and the drain. Returns the
  /// storyline id the row named, or null when nothing was queued.
  /// Stamps a storyline as having been described exactly as its members stand
  /// — the state the refresh gate short-circuits on. Both columns, because the
  /// gate is an equality test between them and `seedStoryline` writes neither.
  Future<void> markDescribed(String id, List<String> keys) =>
      store.updateStoryline(
        id,
        memberHash: memberHashOf(keys),
        refreshedMemberHash: memberHashOf(keys),
        refreshedMemberCount: keys.length,
      );

  Future<String?> drainRefresh(StorylineService service) async {
    final work = await store.nextPendingWork('storyline_refresh');
    if (work == null) return null;
    final id = work['entity_id'] as String;
    await service.refresh(id);
    return id;
  }

  /// The same, for the recap row — exactly what `StorylineRecapHandler` does.
  Future<String?> drainRecap(StorylineService service) async {
    final work = await store.nextPendingWork('storyline_recap');
    if (work == null) return null;
    final id = work['entity_id'] as String;
    await service.recap(id);
    return id;
  }

  group('assignConversation', () {
    test('a candidate over the gate is confirmed once and filed', () async {
      await seedStoryline(store);
      await seed(store, 'c1',
          vector: vectorAt(0.8), lastMessageAt: '2026-08-29T10:00:00Z');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.callsFor('storyline_membership'), 1);
      // The summary and the charter are both already there, so nothing needs
      // naming.
      expect(llm.callsFor('storyline_name'), 0);
      final members = await store.membersOf('sl-1');
      expect(members.map((m) => m.conversationKey), ['member', 'c1']);
      final added = members.last;
      expect(added.addedBy, 'auto');
      expect(added.evidence, 'Both concern the website redesign.');
      // The activity stamp follows the thread that joined.
      expect((await store.getStoryline('sl-1'))!.lastActivityAt,
          '2026-08-29T10:00:00Z');
    });

    test('runs at temperature zero — the same pair must answer the same twice',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.temperatures, [0]);
    });

    test('a candidate under the gate never reaches the model', () async {
      await seedStoryline(store);
      // 0.55 is under the plain gate of 0.60 and there is nobody in common.
      await seed(store, 'c1', vector: vectorAt(0.55), participants: const ['Ann Lu']);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a shared participant lowers the gate', () async {
      await seedStoryline(store, memberParticipants: const ['Sarah Chen']);
      // The same vector as the test above, and the same 0.55 cosine. The only
      // difference is that Sarah is on both threads.
      await seed(store, 'c1',
          vector: vectorAt(0.55), participants: const ['sarah chen']);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('a blocked thread is skipped entirely', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      // The user already said no. A confident model does not get to overrule
      // that by being confident again.
      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a thread already in the storyline is not re-judged', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
    });

    test('a "no" adds nothing and blocks nothing', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(await store.membersOf('sl-1'), hasLength(1));
      // Only a person's "no" is durable. A model that changes its mind next
      // week should be free to.
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
    });

    test('a low-confidence yes is a no', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'low')],
      });

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(await store.membersOf('sl-1'), hasLength(1));
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
    });

    test('a thread with no embedding parks rather than filing it as done',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      // The park is the point. Returning quietly wrote the work row `done`,
      // so a thread whose embedding had not landed yet — an embedding server
      // that was down for an afternoon — was never considered again.
      await expectLater(
        StorylineService(store, llm).assignConversation('email', 'c1'),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a vector from another embedding model is not comparable', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(1), embedModel: 'some-other-model');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      // Same as having none at all: a cosine across two models' spaces is a
      // number with no meaning that still sorts.
      await expectLater(
        StorylineService(store, llm).assignConversation('email', 'c1'),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(llm.schemas, isEmpty);
    });

    test('a storyline whose members have no vectors is skipped', () async {
      await seed(store, 'member');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'member', addedBy: 'auto');
      await seed(store, 'c1', vector: vectorAt(1));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
    });

    test('an unknown conversation returns silently', () async {
      await seedStoryline(store);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'nope');

      expect(llm.schemas, isEmpty);
    });

    test('only the best candidate is judged, whatever the mailbox looks like',
        () async {
      await seedStoryline(store, id: 'sl-far', memberKey: 'far-member');
      await seedStoryline(store,
          id: 'sl-near',
          memberKey: 'near-member',
          memberVector: vectorAt(0.95));
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      // One call, and it went to the closer storyline: 0.9 against the near
      // one's 0.95 member beats 0.9 against the far one's [1, 0].
      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-near'), hasLength(2));
      expect(await store.membersOf('sl-far'), hasLength(1));
    });

    test('a storyline with no summary is named, and a locked title is kept',
        () async {
      await seedStoryline(store, summary: null, titleLocked: true);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer(title: 'A name the model preferred')],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      // The assignment queues the description rather than writing it; the
      // drain is what dials the model. See the refresh group below.
      await drainRefresh(service);

      final storyline = (await store.getStoryline('sl-1'))!;
      // The user named it. No later pass takes that back.
      expect(storyline.title, 'Website redesign');
      // The summary describes where things stand, which no rename claimed.
      expect(storyline.summary, 'The studio is reviewing the homepage copy.');
    });

    test('an unlocked title is replaced when the storyline is named',
        () async {
      await seedStoryline(store, summary: null);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer(title: 'Brightsea launch')],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      expect((await store.getStoryline('sl-1'))!.title, 'Brightsea launch');
    });

    test('a suggestion still collects members while it waits', () async {
      await seedStoryline(store, status: 'suggested');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('one pass reads member context once, not per candidate', () async {
      final counting = CountingStore(db);
      // Three live storylines to walk. Read one candidate at a time this is
      // three of each call — and a query per member inside each of them.
      await seedStoryline(counting,
          id: 'sl-far', memberKey: 'far', memberVector: vectorAt(-0.9));
      await seedStoryline(counting,
          id: 'sl-near', memberKey: 'near', memberVector: vectorAt(0.95));
      await seedStoryline(counting,
          id: 'sl-blocked', memberKey: 'blocked', memberVector: vectorAt(1));
      await seed(counting, 'c1', vector: vectorAt(0.9));
      // So the hoisted block read is exercised too, not merely made.
      await counting.removeStorylineMember('sl-blocked', 'email', 'c1',
          block: true);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final outcome = await StorylineService(counting, llm)
          .assignConversation('email', 'c1');

      expect(counting.memberContextCalls, 1);
      expect(counting.blockedIdCalls, 1);
      // And it still picks the right storyline of the three: the blocked one
      // sits closest and is passed over, the far one never comes near the
      // gate.
      expect(outcome, AssignOutcome.assigned);
      expect(
        (await counting.membersOf('sl-near')).map((m) => m.conversationKey),
        ['near', 'c1'],
      );
      expect(await counting.membersOf('sl-blocked'), hasLength(1));
    });
  });

  /// The pass files nothing most of the time, and the several reasons for that
  /// used to be one silence. Everything downstream — the activity row, and the
  /// question of whether the thread is worth looking at again — turns on which
  /// of them it was.
  group('assignConversation outcomes', () {
    test('a filing is assigned', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.assigned,
      );
    });

    test('a model that says no is rejected, not merely nothing', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.rejected,
      );
    });

    test('a low-confidence yes is rejected too', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'low')],
      });

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.rejected,
      );
    });

    test('nothing over the gate is noCandidate — the common case', () async {
      await seedStoryline(store);
      await seed(store, 'c1',
          vector: vectorAt(0.55), participants: const ['Ann Lu']);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.noCandidate,
      );
    });

    test('a thread the user pulled out says blocked, not noCandidate',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.blocked,
      );
    });

    test('a conversation that no longer exists is noCandidate, not a park',
        () async {
      await seedStoryline(store);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      // Parking on it would hold the queue open forever for a thread no
      // embedding is ever coming for.
      expect(
        await StorylineService(store, llm).assignConversation('email', 'gone'),
        AssignOutcome.noCandidate,
      );
    });
  });

  /// What the model is actually shown, and what it is judged against.
  ///
  /// Both halves are invisible from every other assertion in this file: a
  /// thinner card and a charter that never got written still file threads and
  /// still pass every membership test above. They only show up in whether the
  /// answers are RIGHT, which is measured live.
  group('the charter and the enriched card', () {
    /// The newest inbound message on a thread, with the two things the card
    /// enrichment reads: a triage summary, and an extraction to pull topics
    /// from.
    Future<void> seedInbound(
      String key, {
      String? summary,
      String? extractionJson,
    }) async {
      await store.upsertMessage({
        'source_message_id': 'm-$key',
        'conversation_key': key,
        'direction': 'inbound',
        'received_at': '2026-08-29T10:00:00Z',
      });
      if (summary != null) {
        await db.customStatement(
          'UPDATE messages SET summary = ? WHERE source_message_id = ?',
          [summary, 'm-$key'],
        );
      }
      if (extractionJson != null) {
        await store.writeExtraction('email', 'm-$key', extractionJson);
      }
    }

    String confirmMessageOf(FakeLlm llm) =>
        llm.userMessages[llm.schemas.indexOf('storyline_membership')];

    test('the candidate card carries the topics and the triage summary',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      await seedInbound(
        'c1',
        summary: 'Asks what time to come on Friday and offers dessert.',
        extractionJson: '{"topics":["dinner plans","scheduling"]}',
      );
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      final user = confirmMessageOf(llm);
      expect(user, contains('dinner plans, scheduling'));
      expect(user,
          contains('Asks what time to come on Friday and offers dessert.'));
    });

    test('a thread with no extraction still gets judged, on a thinner card',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      await seedInbound('c1', summary: 'Asks what time to come on Friday.');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      // Enrichment is a bonus, never a requirement: the summary is there, the
      // topics segment is empty, and the call went out.
      final user = confirmMessageOf(llm);
      expect(user, contains('Asks what time to come on Friday.'));
      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('a corrupt extraction costs the topics and nothing else', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      await seedInbound(
        'c1',
        summary: 'Asks what time to come on Friday.',
        extractionJson: 'not json at all',
      );
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(confirmMessageOf(llm), contains('Asks what time to come'));
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('naming cards carry the summary but never the topics', () async {
      await seedStoryline(store, summary: null, charter: null);
      await seedInbound(
        'member',
        summary: 'The studio sent the homepage copy back.',
        extractionJson: '{"topics":["homepage copy","review"]}',
      );
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      final naming = llm.userMessages[llm.schemas.indexOf('storyline_name')];
      expect(naming, contains('The studio sent the homepage copy back.'));
      // Naming reads every member card under one cap, and a topic list is the
      // segment that says least per character it costs.
      expect(naming, isNot(contains('homepage copy, review')));
    });

    test('a storyline with no charter gets one, even when it has a summary',
        () async {
      // The pre-charter shape: named by an older build, so the summary is
      // there and the charter is not. One naming call backfills it.
      await seedStoryline(store, charter: null);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      expect(llm.callsFor('storyline_name'), 1);
      expect((await store.getStoryline('sl-1'))!.charter,
          startsWith('The redesign of the Northline Studio website'));
    });

    test('an edited charter is never taken back', () async {
      await seedStoryline(store, summary: null, charter: null);
      await store.updateStoryline(
        'sl-1',
        charter: 'Only the homepage copy. Not the photography.',
        charterLocked: true,
      );
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      final storyline = (await store.getStoryline('sl-1'))!;
      // The naming call still happened — the summary was missing — and it
      // still refreshed the summary. The charter is the user's.
      expect(storyline.summary, 'The studio is reviewing the homepage copy.');
      expect(storyline.charter, 'Only the homepage copy. Not the photography.');
      expect(storyline.charterLocked, isTrue);
    });

    test('a charter saved while naming is in flight is not overwritten',
        () async {
      // The backfill's naming call takes seconds against a real server. A
      // user who opens About and saves their own charter in that window has
      // set the lock — and the write that lands after the model returns must
      // honor the lock as it is NOW, not as it was when the call started.
      await seedStoryline(store, charter: null);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = HookedFakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      }, (schemaName) async {
        if (schemaName != 'storyline_name') return;
        await store.updateStoryline('sl-1',
            charter: 'Only the launch.', charterLocked: true);
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, 'Only the launch.');
      expect(storyline.charterLocked, isTrue);
    });

    test('a storyline that has both is left alone', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      // No script for naming: a second backfill call would throw here, which
      // is what makes "converges" a claim this test can check.
      expect(llm.callsFor('storyline_name'), 0);
      // And nothing is queued to make one later either. A storyline that
      // reads well and grew by one thread is left as it is — see 'one quiet
      // thread does not wake the describer'.
      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('a proposed storyline is stored with its charter', () async {
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect((await store.loadStorylines()).single.charter,
          startsWith('The redesign of the Northline Studio website'));
    });

    test('a model that offered no charter leaves the column null', () async {
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));
      final llm = FakeLlm({
        'storyline_name': [nameAnswer(charter: '')],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // NULL rather than '': a storyline with no charter is judged against its
      // summary, and an empty string would be judged against nothing.
      expect((await store.loadStorylines()).single.charter, isNull);
    });

    test('nine member summaries still fit under the naming cap', () async {
      await store.insertStoryline(
        id: 'sl-big',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      for (var i = 0; i < 9; i++) {
        await seed(store, 'big-$i', vector: vectorAt(1));
        await seedInbound('big-$i', summary: 's' * 600);
        await store.addStorylineMember('sl-big', 'email', 'big-$i',
            addedBy: 'auto');
      }
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      // The cards are clamped as a SET, not one by one — a storyline of nine
      // threads has to fit in one prompt however long each summary ran.
      final naming = llm.userMessages[llm.schemas.indexOf('storyline_name')];
      expect('s'.allMatches(naming).length, lessThanOrEqualTo(4000));
    });
  });

  group('sweep', () {
    /// Four unassigned threads: c1 and c2 link, c3 and c4 link to nothing.
    Future<void> seedMailbox(MessageStore into) async {
      await seed(into, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
    }

    test('a lone unassigned thread is below the gate', () async {
      // One thread is nothing to pair, and a storyline of one is just a
      // thread — the sweep does not reach the model at all.
      await seed(store, 'c1', vector: vectorAt(1));
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('two similar threads are enough for the sweep to propose', () async {
      // Pins the gate at two: a light mailbox has to be able to form its
      // first storyline, not wait until it is busy enough.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(), confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');

      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(), {'c1', 'c2'});
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 2);
    });

    test('a cluster becomes one suggestion with its confirmed members',
        () async {
      await seedMailbox(store);
      // One answer per member, in the order the sweep reads the rows — newest
      // first, so c1 then c2. Distinct sentences, because the point of the
      // stage is that each thread gets its own reason rather than the
      // cluster's.
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(evidence: 'c1 is the homepage copy review.'),
          confirmAnswer(evidence: 'c2 is the same review, continued.'),
        ],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');
      expect(storyline.title, 'Website redesign');
      expect(storyline.summary, 'The studio is reviewing the homepage copy.');
      expect(storyline.id, startsWith('sl-'));
      expect(storyline.lastActivityAt, '2026-08-29T04:00:00Z');

      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(), {'c1', 'c2'});
      expect(members.every((m) => m.addedBy == 'auto'), isTrue);
      // Each member carries what the model said about IT — the blanket
      // "clustered together" was the pass claiming a justification nothing
      // had produced.
      expect(
        {for (final m in members) m.conversationKey: m.evidence},
        {
          'c1': 'c1 is the homepage copy review.',
          'c2': 'c2 is the same review, continued.',
        },
      );
      // Named once, then every member of the cluster judged against that name.
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 2);
      // Naming and confirming alike: an unchanged mailbox swept twice must
      // propose the same storyline out of the same threads.
      expect(llm.temperatures, [0, 0, 0]);
    });

    test('a thread the model says does not belong is left out', () async {
      // Three linked threads and one loner, so the cluster is c1/c2/c3 and
      // losing one member still leaves a proposable pair.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(
            evidence: 'This is a vacation request, not the redesign.',
            belongs: false,
          ),
        ],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2'});
      // Nothing is blocked and nothing is filed, so the rejected thread is
      // back in the pool the next sweep reads — only a person's "no" is
      // permanent.
      expect(await store.assignedOrBlockedKeys('email'), isNot(contains('c3')));
    });

    test('a suggestion born smaller than its cluster is recognised dismissed',
        () async {
      // The confirm pass drops c3, so the stored members are the pair while
      // the cluster was the trio — the two hashes must differ AT INSERT, which
      // is what pins the survivor-set `member_hash` write. Written as the
      // cluster's hash instead, this dismissal would go unrecognised the
      // moment c3 left the pool.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(belongs: false),
        ],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      final first = (await store.loadStorylines()).single;
      final hashes = (await db
              .customSelect(
                'SELECT member_hash, cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(first.id)],
              )
              .getSingle())
          .data;
      expect(hashes['member_hash'], isNot(hashes['cluster_hash']));

      await service.dismissSuggestion(first.id);

      // c3 finishes, so the next sweep clusters the pair alone — the set the
      // user was shown and refused. Only the member arm can know that: the
      // cluster arm still names the trio.
      await store.setConversationState('email', 'c3', ConversationState.done);
      await service.sweep();

      expect(await store.loadStorylines(), isEmpty);
      expect(llm.callsFor('storyline_name'), 1);
    });

    test('a yes the model is not confident about is a no', () async {
      await seedMailbox(store);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(confidence: 'low'),
        ],
      });

      await StorylineService(store, llm).sweep();

      // One survivor is not a storyline, so the pass files nothing — the same
      // rule the assignment and recruit paths apply to a low answer.
      expect(await store.loadStorylines(), isEmpty);
    });

    test('a cluster the model rejects outright is never proposed twice',
        () async {
      await seedMailbox(store);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(belongs: false)],
      });
      final service = StorylineService(store, llm);

      await service.sweep();

      // A tombstone: named, hashed over the whole cluster, and empty. It
      // exists so the identical cluster — its members went straight back into
      // the unassigned pool — cannot be re-judged for ever.
      final tombstone =
          (await store.loadStorylines(statuses: const ['dismissed'])).single;
      expect(tombstone.createdBy, 'auto');
      expect(tombstone.title, 'Website redesign');
      expect(await store.membersOf(tombstone.id), isEmpty);
      final hashes = (await db
              .customSelect(
                'SELECT member_hash, cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(tombstone.id)],
              )
              .getSingle())
          .data;
      // The cluster is this row's only identity: no member rows were written,
      // so there is no stored set for `member_hash` to describe.
      expect(hashes['cluster_hash'], isNotNull);
      expect(hashes['member_hash'], null);
      expect(
          await store
              .dismissedHashExistsAny([hashes['cluster_hash']! as String]),
          isTrue);
      // Nothing to answer in the rail.
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);

      final callsAfterFirst = llm.schemas.length;
      await service.sweep();

      // Caught by the hash check before the naming call, so the second sweep
      // costs nothing at all — not even the cheap confirmations.
      expect(llm.schemas, hasLength(callsAfterFirst));
    });

    test('a done thread is never the start of a story', () async {
      await seedMailbox(store);
      store.setConversationState('email', 'c2', ConversationState.done);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // c1's only partner is finished. The three threads left are well over
      // the sweep's floor, so the pass runs — and c1, c3 and c4 sit too far
      // apart to link, so no cluster forms and no model is dialled.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('threads already in a storyline are left alone', () async {
      await seedMailbox(store);
      await store.insertStoryline(
        id: 'sl-existing',
        title: 'Existing',
        status: 'active',
        createdBy: 'user',
      );
      await store.addStorylineMember('sl-existing', 'email', 'c1', addedBy: 'user');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // c1 is spoken for, which leaves three unassigned threads — over the
      // sweep's floor, so the pass runs. What keeps it silent is that c1 was
      // c2's only partner: c2, c3 and c4 link to nothing at
      // `clusterLinkThreshold`, so no cluster forms and no model is dialled.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), hasLength(1));
    });

    test('a dismissed cluster is not proposed again', () async {
      await seedMailbox(store);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      final first = (await store.loadStorylines()).single;
      final hash = (await db
              .customSelect(
                'SELECT member_hash FROM storylines WHERE id = ?',
                variables: [Variable(first.id)],
              )
              .getSingle())
          .data['member_hash'];
      expect(hash, isNotNull);
      await service.dismissSuggestion(first.id);

      // Dismissing frees c1 and c2 again, so the same four threads are back on
      // the table and the clustering is deterministic — without the hash guard
      // this would re-propose the group the user just threw away.
      await service.sweep();

      expect(await store.loadStorylines(), isEmpty);
      expect(llm.callsFor('storyline_name'), 1);
    });

    test('a dismissed cluster whose membership drifted is not proposed again',
        () async {
      await seedMailbox(store);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      final first = (await store.loadStorylines()).single;

      // The drift: the user files a third thread into the suggestion by hand,
      // which rewrites `member_hash` over the bigger set. `cluster_hash` is
      // untouched — it names the pair the sweep actually built and asked
      // about.
      await service.addThread(first.id, 'email', 'c3');
      final hashes = (await db
              .customSelect(
                'SELECT member_hash, cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(first.id)],
              )
              .getSingle())
          .data;
      expect(hashes['member_hash'], isNot(hashes['cluster_hash']));

      await service.dismissSuggestion(first.id);

      // c1 and c2 are free again and still the only pair close enough to
      // link — c3 sits at cosine 0 — so the identical cluster re-forms. Only
      // the cluster arm can recognise it: the member hash now describes three
      // threads, and no cluster will ever hash to that.
      await service.sweep();

      expect(await store.loadStorylines(), isEmpty);
      expect(llm.callsFor('storyline_name'), 1);
    });

    test('a storyline the user pruned before dismissing is recognised by its '
        'members', () async {
      // Three threads tight enough to cluster as one.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      final first = (await store.loadStorylines()).single;
      expect((await store.membersOf(first.id)).map((m) => m.conversationKey),
          ['c1', 'c2', 'c3']);

      // The user takes one thread out and then throws the rest away. What
      // they said no to is the PAIR, which is what `member_hash` now holds.
      await service.removeThread(first.id, 'email', 'c3');
      await service.dismissSuggestion(first.id);

      // c3 finishes, so the next sweep's pool is the pair alone and the
      // cluster it builds hashes to something the proposal-time
      // `cluster_hash` — taken over all three — cannot match.
      await store.setConversationState('email', 'c3', ConversationState.done);
      await service.sweep();

      expect(await store.loadStorylines(), isEmpty);
      expect(llm.callsFor('storyline_name'), 1);
    });

    test('a dismissed cluster does not consume the room a new one needs',
        () async {
      // Two distinct clusters: A (a1, a2) around vectorAt(1), B (b1, b2)
      // around vectorAt(-0.9). A's rows are newer, so the deterministic pass
      // builds A first and stable sorting keeps it ranked first.
      await seed(store, 'a1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'a2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'b1',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'b2',
          vector: vectorAt(-0.95), lastMessageAt: '2026-08-29T01:00:00Z');
      // Two unrelated pending suggestions squeeze the room down to one slot.
      for (var i = 0; i < 2; i++) {
        await store.insertStoryline(
          id: 'sl-pending-$i',
          title: 'Pending $i',
          status: 'suggested',
          createdBy: 'auto',
        );
      }
      final llm = FakeLlm({
        'storyline_name': [nameAnswer(), nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      // Sweep #1: the single slot goes to A, the larger-ranked cluster.
      await service.sweep();
      final proposedA = (await store.loadStorylines(statuses: const ['suggested']))
          .where((s) => s.id.startsWith('sl-') && !s.id.startsWith('sl-pending'))
          .single;
      expect((await store.membersOf(proposedA.id)).map((m) => m.conversationKey).toSet(),
          {'a1', 'a2'});
      await service.dismissSuggestion(proposedA.id);

      // Sweep #2: A is ranked first again and its hash is dismissed. That
      // must not eat the slot — B, which the user has never seen, gets it.
      await service.sweep();

      final proposedB = (await store.loadStorylines(statuses: const ['suggested']))
          .where((s) => s.id.startsWith('sl-') && !s.id.startsWith('sl-pending'))
          .single;
      expect((await store.membersOf(proposedB.id)).map((m) => m.conversationKey).toSet(),
          {'b1', 'b2'});
      expect(llm.callsFor('storyline_name'), 2);
    });

    test('the pending-suggestion cap stops the sweep before it starts',
        () async {
      await seedMailbox(store);
      for (var i = 0; i < 3; i++) {
        await store.insertStoryline(
          id: 'sl-pending-$i',
          title: 'Pending $i',
          status: 'suggested',
          createdBy: 'auto',
        );
      }
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), hasLength(3));
    });

    test('clustering is deterministic — same mailbox, same groups', () async {
      Future<Set<String>> clusterOf(BondDatabase into) async {
        final target = MessageStore(into);
        await seedMailbox(target);
        // The same script on both sides, so the only thing that could differ
        // between the two runs is the clustering itself.
        await StorylineService(
          target,
          FakeLlm({
            'storyline_name': [nameAnswer()],
            'storyline_membership': [confirmAnswer()],
          }),
        ).sweep();
        final storyline = (await target.loadStorylines()).single;
        return (await target.membersOf(storyline.id))
            .map((m) => m.conversationKey)
            .toSet();
      }

      final a = testDb();
      final b = testDb();
      addTearDown(a.close);
      addTearDown(b.close);

      expect(await clusterOf(a), await clusterOf(b));
    });

    test('a mail thread and a chat about the same thing become one storyline',
        () async {
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 't1',
          source: 'teams',
          vector: vectorAt(0.9),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(), {'c1', 't1'});
      // Each member carries the source it arrived through, so every later
      // read of the storyline — the episode list, a membership re-check —
      // goes to the right connector for it.
      expect(
        {for (final m in members) m.conversationKey: m.source},
        {'c1': 'email', 't1': 'teams'},
      );
    });

    test('a pair of chats can be the seed of a storyline on their own',
        () async {
      await seed(store, 't1',
          source: 'teams',
          vector: vectorAt(1),
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 't2',
          source: 'teams',
          vector: vectorAt(0.9),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(), {'t1', 't2'});
      expect(members.every((m) => m.source == 'teams'), isTrue);
    });

    /// A chat and its mail partner, plus a second pair with nothing to do with
    /// them. Whatever happens to the chat, the second pair is still there to
    /// be proposed — which is what makes "the chat was left out" an assertion
    /// about the chat rather than about the sweep's floor.
    Future<void> seedMixedMailbox(MessageStore into) async {
      await seed(into, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T05:00:00Z');
      await seed(into, 't1',
          source: 'teams',
          vector: vectorAt(0.9),
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c5',
          vector: vectorAt(-0.95), lastMessageAt: '2026-08-29T01:00:00Z');
      await into.insertStoryline(
        id: 'sl-existing',
        title: 'Existing',
        status: 'active',
        createdBy: 'user',
      );
    }

    test('a chat already in a storyline is not swept into a new one', () async {
      await seedMixedMailbox(store);
      await store.addStorylineMember('sl-existing', 'teams', 't1',
          addedBy: 'user');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // t1 is spoken for, so c1 has no partner left. The unrelated pair is
      // what gets proposed instead.
      final proposed = (await store.loadStorylines(
        statuses: const ['suggested'],
      )).single;
      expect((await store.membersOf(proposed.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c4', 'c5'});
    });

    test('a chat the user pulled out of a storyline is not swept back in',
        () async {
      await seedMixedMailbox(store);
      // Blocking without a membership to delete is how a removal records the
      // user's "no" — and the sweep must honour it for a chat exactly as it
      // does for a mail thread.
      await store.removeStorylineMember('sl-existing', 'teams', 't1',
          block: true);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final proposed = (await store.loadStorylines(
        statuses: const ['suggested'],
      )).single;
      expect((await store.membersOf(proposed.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c4', 'c5'});
    });

    /// One key on two connectors, plus a third thread to pair whichever of
    /// them is still free. Normal, and not a collision to be avoided: the mail
    /// and chat connectors mint their keys with no knowledge of each other.
    Future<void> seedSharedKeyMailbox(MessageStore into) async {
      await seed(into, 'shared',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'shared',
          source: 'teams',
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      await into.insertStoryline(
        id: 'sl-existing',
        title: 'Existing',
        status: 'active',
        createdBy: 'user',
      );
    }

    test('a chat and a mail thread sharing a conversation key are not confused',
        () async {
      await seedSharedKeyMailbox(store);
      // The MAIL thread is spoken for. The chat under the same key has never
      // been looked at.
      await store.addStorylineMember('sl-existing', 'email', 'shared',
          addedBy: 'user');
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // Read as a bare key, "shared is taken" swallowed the chat as well and
      // left the pool one lone thread — under the sweep's floor, so nothing
      // was ever proposed.
      final proposed =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(
        {
          for (final m in await store.membersOf(proposed.id))
            m.conversationKey: m.source,
        },
        {'shared': 'teams', 'c2': 'email'},
      );
    });

    test('a thread taken by one source is still available in the other',
        () async {
      await seedSharedKeyMailbox(store);
      // The block arm of the same confusion. The user's "no" was about the
      // chat, and it says nothing about the mail thread under that key.
      await store.removeStorylineMember('sl-existing', 'teams', 'shared',
          block: true);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final proposed =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(
        {
          for (final m in await store.membersOf(proposed.id))
            m.conversationKey: m.source,
        },
        {'shared': 'email', 'c2': 'email'},
      );
    });

    test('a dismissed cluster is recognised under either hash recipe',
        () async {
      await seedMailbox(store);
      // The tombstone an older build left: hashed over the bare conversation
      // keys, before the recipe folded the connector in. Nothing can rewrite
      // it — a cluster thrown out below the minimum size has no member rows to
      // rebuild what it was — so recognition has to keep speaking that
      // language for as long as the row exists.
      await store.insertStoryline(
        id: 'sl-old',
        title: 'Website redesign',
        status: 'dismissed',
        createdBy: 'auto',
        clusterHash: cardHash('c1\nc2'),
      );
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // The sweep rebuilds exactly that pair, and stops on a hash nothing in
      // the app writes any more — before a single model call.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });
  });

  group('user actions', () {
    test('creating a storyline locks its title and files the thread', () async {
      await seed(store, 'c1', lastMessageAt: '2026-08-29T10:00:00Z');
      final service =
          StorylineService(store, FakeLlm(const {}));

      final id = await service.createStoryline(
        'Brightsea launch',
        source: 'email',
        conversationKey: 'c1',
      );

      final storyline = (await store.getStoryline(id))!;
      expect(storyline.title, 'Brightsea launch');
      expect(storyline.status, 'active');
      expect(storyline.createdBy, 'user');
      expect(storyline.titleLocked, isTrue);
      expect(storyline.lastActivityAt, '2026-08-29T10:00:00Z');
      expect((await store.membersOf(id)).single.addedBy, 'user');
    });

    test('two ids in a row differ', () async {
      expect(newStorylineId(), isNot(newStorylineId()));
      expect(newStorylineId(), matches(RegExp(r'^sl-[0-9a-f]{16}$')));
    });

    test('keep and dismiss move the status and nothing else', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        status: 'suggested',
        createdBy: 'auto',
        memberHash: 'h1',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.keepSuggestion('sl-1');
      expect((await store.getStoryline('sl-1'))!.status, 'active');

      await service.dismissSuggestion('sl-1');
      final dismissed = (await store.getStoryline('sl-1'))!;
      expect(dismissed.status, 'dismissed');
      expect(dismissed.summary, 'The studio is reviewing the homepage copy.');
      // The member rows are the record of what the user was shown, and the
      // hashes on the row are what recognise the group when it re-forms.
      expect(await store.membersOf('sl-1'), hasLength(1));
      expect(await store.dismissedHashExistsAny(['h1']), isTrue);
    });

    test('renaming locks the title', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Untitled storyline',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));

      await service.rename('sl-1', 'Brightsea launch');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.title, 'Brightsea launch');
      expect(storyline.titleLocked, isTrue);
    });

    test('removing a thread always blocks it', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.removeThread('sl-1', 'email', 'c1');

      expect(await store.membersOf('sl-1'), isEmpty);
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test('adding a thread back un-blocks it', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));
      await service.addThread('sl-1', 'email', 'c1');
      await service.removeThread('sl-1', 'email', 'c1');

      await service.addThread('sl-1', 'email', 'c1');

      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      expect(await store.membersOf('sl-1'), hasLength(1));
      // The same fact the picker reads: a thread still listed here is one the
      // Add-to pane would refuse to offer back.
      expect(await store.blockedThreadsOf('sl-1'), isEmpty);
    });

    test('filing a thread into a suggestion accepts it', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'suggested',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      // Nothing is left to ask the user about a group they are already
      // putting threads into.
      expect((await store.getStoryline('sl-1'))!.status, 'active');
    });

    test('and filing into a kept one leaves its status alone', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      expect((await store.getStoryline('sl-1'))!.status, 'active');
    });
  });

  /// Where a hand-filed thread SHOWS UP. The timeline and the rail read
  /// member rows; the home feed and the hot strip read
  /// `message_progress.storyline_id`, and until the user actions stamped it a
  /// thread the user filed appeared on half the app.
  group('the pointer a user action leaves', () {
    test('a hand-added thread is visible where the pipeline stamped rows',
        () async {
      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1', receivedAt: '2026-08-27T09:00:00Z');
      await seedMessage(store, 'c1', 'm2', receivedAt: '2026-08-28T09:00:00Z');
      // Another thread entirely — the stamp is per conversation.
      await seed(store, 'c2');
      await seedMessage(store, 'c2', 'm9');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      expect(await pointerOf('m1'), 'sl-1');
      expect(await pointerOf('m2'), 'sl-1');
      expect(await pointerOf('m9'), isNull);
    });

    test('adding to a second storyline does not steal the pointer', () async {
      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1');
      for (final id in ['sl-1', 'sl-2']) {
        await store.insertStoryline(
          id: id,
          title: 'Website redesign',
          status: 'active',
          createdBy: 'auto',
        );
      }
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await memberAddedAt('sl-1', 'c1', '2026-08-01T00:00:00Z');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.addThread('sl-2', 'email', 'c1');

      // Oldest membership wins, because that is the id
      // `PipelineProgress.assignedStorylineId` would pick — the two answers
      // have to agree or they fight over the column.
      expect(await pointerOf('m1'), 'sl-1');
      expect(await store.storylineIdsFor('email', 'c1'), ['sl-1', 'sl-2']);
    });

    test('a clear hands the pointer to the remaining membership', () async {
      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1');
      for (final id in ['sl-1', 'sl-2']) {
        await store.insertStoryline(
          id: id,
          title: 'Website redesign',
          status: 'active',
          createdBy: 'auto',
        );
        await store.addStorylineMember(id, 'email', 'c1', addedBy: 'auto');
      }
      await memberAddedAt('sl-1', 'c1', '2026-08-01T00:00:00Z');
      await memberAddedAt('sl-2', 'c1', '2026-08-02T00:00:00Z');
      await store.stampStorylineId('email', 'c1', storylineId: 'sl-1');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.removeThread('sl-1', 'email', 'c1');

      // Not blank: the thread still belongs to sl-2, and a feed row that went
      // empty would be saying it belongs to nothing.
      expect(await pointerOf('m1'), 'sl-2');
    });

    test('removing the last membership leaves the rows pointing at nothing',
        () async {
      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));
      await service.addThread('sl-1', 'email', 'c1');

      await service.removeThread('sl-1', 'email', 'c1');

      expect(await pointerOf('m1'), isNull);
    });

    test('a hand-filed thread ticks the screen once per message it moved',
        () async {
      final bus = ProgressBus();
      addTearDown(bus.dispose);
      final ticks = <ProgressTick>[];
      bus.ticks.listen(ticks.add);

      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1', receivedAt: '2026-08-27T09:00:00Z');
      await seedMessage(store, 'c1', 'm2', receivedAt: '2026-08-28T09:00:00Z');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(
        store,
        FakeLlm(const {}),
        progress: PipelineProgress(store, bus: bus),
      );

      await service.addThread('sl-1', 'email', 'c1');
      await pumpEventQueue();

      expect(ticks.map((t) => t.sourceMessageId), ['m1', 'm2']);
      expect(ticks.map((t) => t.stage).toSet(), {'storyline'});
      expect(ticks.map((t) => t.state).toSet(), {'done'});
      // The feed's sort key rides along, so a listener can tell a patch from a
      // prepend without re-reading.
      expect(ticks.first.receivedAt, '2026-08-27T09:00:00Z');
    });
  });

  /// What the two automatic passes tell the activity log they did.
  ///
  /// Load-bearing rather than decorative: a pass that notes nothing looks
  /// identical to one that did nothing, and `ActivityLog.record` suppresses the
  /// latter. An assignment that forgot to note would silently stop appearing on
  /// the activity panel, and no other assertion in this file would move.
  group('what the passes note', () {
    test('a filing names the storyline it filed into', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(
        store,
        FakeLlm({'storyline_membership': [confirmAnswer()]}),
        activityLog: log,
      ).assignConversation('email', 'c1');

      await log.record('storyline', source: 'email', entityId: 'c1');

      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.detail['assigned'], 'Website redesign');
    });

    test('a pass that filed nothing notes nothing, and so writes no row',
        () async {
      await seedStoryline(store);
      // Under the gate, so the model is never consulted and nothing is filed.
      await seed(store, 'c1', vector: vectorAt(0.1));
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(
        store,
        FakeLlm({'storyline_membership': [confirmAnswer()]}),
        activityLog: log,
      ).assignConversation('email', 'c1');

      await log.record('storyline', source: 'email', entityId: 'c1');

      expect(await store.recentActivity(), isEmpty);
    });

    /// Runs a sweep with [llm] and returns the recorded activity detail.
    Future<Map<String, Object?>> sweepAndRecord(FakeLlm llm) async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await StorylineService(store, llm, activityLog: log).sweep();
      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');
      final rows = await store.recentActivity();
      if (rows.isEmpty) return const {};
      return ActivityEvent.fromRow(rows.single).detail;
    }

    test('a sweep counts its proposals once, not once per cluster', () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.9));
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));

      final detail = await sweepAndRecord(FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      }));

      expect(detail['proposed'], 1);
      // Threads, not clusters: the proposal held both members of the one
      // cluster and the model turned nothing away.
      expect(detail['confirmed'], 2);
      expect(detail['rejected'], 0);
    });

    test('a sweep that proposed nothing still reports what it turned away',
        () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.9));
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));

      final detail = await sweepAndRecord(FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(belongs: false)],
      }));

      // The recruit precedent: consulted and said no is an answer, and the
      // rejections are what keep the row out of the quiet-kind check.
      expect(detail['proposed'], 0);
      expect(detail['confirmed'], 0);
      expect(detail['rejected'], 2);
    });

    test('a sweep whose every cluster was already dismissed stays quiet',
        () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.9));
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);
      await service.sweep();
      await service
          .dismissSuggestion((await store.loadStorylines()).single.id);

      final detail = await sweepAndRecord(llm);

      // The pass reached a cluster and noted its tally, but every number in
      // it is zero — the hash check turned the cluster away before any model
      // call — and the log suppresses that as the genuine nothing it is.
      expect(detail, isEmpty);
    });

    test('a sweep with nothing to cluster writes no row at all', () async {
      // Under the unassigned floor, so no cluster ever reaches the model and
      // there is not even a tally to be zero about.
      await seed(store, 'c1', vector: vectorAt(1));

      final detail = await sweepAndRecord(FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      }));

      expect(detail, isEmpty);
    });
  });

  group('the recruit pass', () {
    /// Runs a recruit with [llm] and returns the recorded activity detail —
    /// every recruit notes, so the row is part of the pass's contract.
    Future<Map<String, Object?>> recruitAndRecord(
      FakeLlm llm, {
      String id = 'sl-1',
    }) async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await StorylineService(store, llm, activityLog: log).recruit(id);
      await log.record('storyline_recruit', source: 'email', entityId: id);
      final rows = await store.recentActivity();
      if (rows.isEmpty) return const {};
      return ActivityEvent.fromRow(rows.single).detail;
    }

    test('a candidate over the gate is confirmed against the charter and filed',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1',
          vector: vectorAt(0.8), lastMessageAt: '2026-08-30T10:00:00Z');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      // Exactly one confirmation: the member's own thread also has a vector —
      // at cosine 1.0 it would top the ranking — so one call is also the
      // proof that members are excluded.
      expect(llm.callsFor('storyline_membership'), 1);
      expect(llm.userMessages.single, contains('Charter:'));
      final members = await store.membersOf('sl-1');
      expect(members.map((m) => m.conversationKey), ['member', 'c1']);
      expect(members.last.addedBy, 'auto');
      expect(members.last.evidence, 'Both concern the website redesign.');
      final hashRow = await db
          .customSelect(
            'SELECT member_hash FROM storylines WHERE id = ?',
            variables: [Variable('sl-1')],
          )
          .getSingle();
      expect(hashRow.data['member_hash'], isNotNull);
      expect((await store.getStoryline('sl-1'))!.lastActivityAt,
          '2026-08-30T10:00:00Z');
      expect(detail['recruited'], 1);
      expect(detail['considered'], 1);
    });

    test('a chat is recruited into a storyline the same way a thread is',
        () async {
      await seedStoryline(store);
      await seed(store, 't1',
          source: 'teams',
          vector: vectorAt(0.8),
          lastMessageAt: '2026-08-30T10:00:00Z');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 1);
      final joined = (await store.membersOf('sl-1')).last;
      expect(joined.conversationKey, 't1');
      expect(joined.source, 'teams');
      expect(detail['recruited'], 1);
    });

    test('the gate is the LOWER one even with nobody in common', () async {
      await seedStoryline(store, memberParticipants: const ['Sarah Chen']);
      // 0.55 with disjoint people: assignment would demand 0.60 here. The
      // user's charter is what buys the look instead of a shared name.
      await seed(store, 'c1',
          vector: vectorAt(0.55), participants: const ['Ann Lu']);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('under the gate never reaches the model', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.45));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.schemas, isEmpty);
      // An all-zero recruit is a quiet kind's genuine nothing: noted by the
      // service, suppressed by the log. "0 of 5" would have shown.
      expect(detail, isEmpty);
    });

    test('a blocked thread is never even considered', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      // Removing a non-member with block: true records the user's "no"
      // without ever having had a membership to delete.
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.schemas, isEmpty);
      expect(detail, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a block is about one connector, not one key', () async {
      await seedStoryline(store);
      // Two threads under one key, one per connector — which is normal: the
      // mail and chat connectors mint keys with no knowledge of each other.
      // The user's "no" was about the chat.
      await seed(store, 'shared', vector: vectorAt(0.95));
      await seed(store, 'shared', source: 'teams', vector: vectorAt(0.95));
      await store.removeStorylineMember('sl-1', 'teams', 'shared',
          block: true);
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 1);
      expect(detail['considered'], 1);
      final joined = (await store.membersOf('sl-1')).last;
      expect(joined.conversationKey, 'shared');
      expect(joined.source, 'email');
    });

    test('the pass is capped at the top eight by cosine', () async {
      await seedStoryline(store);
      // Ten over the gate, at distinct cosines. The two weakest must never
      // reach the model, however agreeable it is scripted to be.
      for (var i = 0; i < 10; i++) {
        await seed(store, 'c$i', vector: vectorAt(0.51 + 0.04 * i));
      }
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 8);
      expect(detail['considered'], 8);
      final keys = (await store.membersOf('sl-1'))
          .map((m) => m.conversationKey)
          .toSet();
      // c0 (0.51) and c1 (0.55) are ranks nine and ten.
      expect(keys.contains('c0'), false);
      expect(keys.contains('c1'), false);
      expect(keys.contains('c9'), true);
    });

    test('a low-confidence yes is a no', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'low')],
      });

      final detail = await recruitAndRecord(llm);

      expect(await store.membersOf('sl-1'), hasLength(1));
      expect(detail['recruited'], 0);
      expect(detail['considered'], 1);
    });

    test('a dismissed storyline is not resurrected by a queued recruit',
        () async {
      await seedStoryline(store, status: 'dismissed');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(store, llm, activityLog: log).recruit('sl-1');
      await log.record('storyline_recruit', source: 'email', entityId: 'sl-1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
      // Nothing noted, so nothing recorded: this pass genuinely did nothing.
      expect(await store.recentActivity(), isEmpty);
    });

    test('a storyline with no member vectors reports an empty pass', () async {
      await seed(store, 'bare');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'user',
      );
      await store.addStorylineMember('sl-1', 'email', 'bare', addedBy: 'user');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.schemas, isEmpty);
      expect(detail, isEmpty);
    });

    test('an unavailable server parks the pass and keeps what already landed',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.9));
      await seed(store, 'c2', vector: vectorAt(0.8));
      final llm = FakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          const LlmUnavailableException('server off'),
        ],
      });

      await expectLater(
        StorylineService(store, llm).recruit('sl-1'),
        throwsA(isA<LlmUnavailableException>()),
      );

      // The first candidate stays filed; the re-run after the park skips it
      // as a member and picks up where this one stopped.
      expect(
        (await store.membersOf('sl-1')).map((m) => m.conversationKey),
        ['member', 'c1'],
      );
    });
  });

  group('setCharter', () {
    test('a save trims, locks, and queues one recruit', () async {
      await seedStoryline(store);
      final llm = FakeLlm(const {});

      await StorylineService(store, llm)
          .setCharter('sl-1', '  Only the venue booking.  ');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, 'Only the venue booking.');
      expect(storyline.charterLocked, true);
      final work = await store.nextPendingWork('storyline_recruit');
      expect(work?['entity_id'], 'sl-1');
      // The save writes and queues; the model is for the drain to consult.
      expect(llm.schemas, isEmpty);
    });

    test('clearing unlocks, drafts nothing, and recruits nothing', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1', charterLocked: true);

      await StorylineService(store, FakeLlm(const {}))
          .setCharter('sl-1', '   ');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, null);
      expect(storyline.charterLocked, false);
      expect(await store.nextPendingWork('storyline_recruit'), null);
    });

    test('a second save revives a recruit the drain already finished',
        () async {
      await seedStoryline(store);
      final service = StorylineService(store, FakeLlm(const {}));

      await service.setCharter('sl-1', 'First charter.');
      await store.writeWork('storyline_recruit', 'email', 'sl-1',
          status: 'done');
      await service.setCharter('sl-1', 'Second charter.');

      final work = await store.nextPendingWork('storyline_recruit');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a save clears a suggestion the user has now answered', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charterSuggestion: 'Also the launch party.');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.setCharter('sl-1', 'Only the homepage copy.');

      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('and clearing the charter clears it too', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charterSuggestion: 'Also the launch party.');
      final service = StorylineService(store, FakeLlm(const {}));

      await service.setCharter('sl-1', '   ');

      // An offer written against criteria that no longer exist is not an offer
      // worth showing.
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('dismissing a suggestion leaves the charter and its lock alone',
        () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charter: 'Only the homepage copy.',
          charterLocked: true,
          charterSuggestion: 'Also the launch party.');

      await StorylineService(store, FakeLlm(const {}))
          .dismissCharterSuggestion('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charterSuggestion, isNull);
      expect(storyline.charter, 'Only the homepage copy.');
      expect(storyline.charterLocked, isTrue);
    });
  });

  group('refresh', () {
    /// The charter the model widens to in the tests below — the stored one
    /// with one clause added, which is what "minimal drift" looks like when it
    /// works.
    const widened = 'The redesign of the Northline Studio website — the '
        'homepage copy, the new photography, the launch date, and the launch '
        'party.';

    test('a hand-added thread widens a model-authored charter', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_refresh': [
          refineAnswer(
            title: 'Website redesign and launch',
            summary: 'The launch party venue is the open question.',
            charter: widened,
          )
        ],
      });
      final service = StorylineService(store, llm);

      await service.addThread('sl-1', 'email', 'c2');
      expect(await drainRefresh(service), 'sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // The charter is the model's own text, so the model may amend it.
      expect(storyline.charter, widened);
      expect(storyline.charterSuggestion, isNull);
      expect(storyline.title, 'Website redesign and launch');
      expect(storyline.summary, 'The launch party venue is the open question.');
      // Described as the two threads it now holds.
      expect(storyline.refreshedMemberHash, memberHashOf(['member', 'c2']));
      expect(storyline.refreshedMemberCount, 2);
    });

    test('runs at temperature zero — the same members must read the same twice',
        () async {
      await seedStoryline(store);
      final llm = FakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.temperatures, [0]);
    });

    test('a hand-added thread never touches a charter the user wrote',
        () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charter: 'Only the homepage copy.', charterLocked: true);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_refresh': [
          refineAnswer(charter: 'The homepage copy and the launch party.')
        ],
      });
      final service = StorylineService(store, llm);

      await service.addThread('sl-1', 'email', 'c2');
      await drainRefresh(service);

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, 'Only the homepage copy.');
      expect(storyline.charterLocked, isTrue);
      // The model's version is parked where the About block can offer it,
      // which is the whole difference between this and the test above.
      expect(storyline.charterSuggestion,
          'The homepage copy and the launch party.');
    });

    test('a charter that no longer fits earns a suggestion, not an overwrite',
        () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charter: 'Only the homepage copy.', charterLocked: true);
      final llm = FakeLlm({
        'storyline_refresh': [refineAnswer(charter: widened)],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, 'Only the homepage copy.');
      expect(storyline.charterSuggestion, widened);
      // A parked suggestion changes no criteria, so nothing goes hunting on
      // the strength of it. The recruit waits for the user to accept.
      expect(await store.nextPendingWork('storyline_recruit'), isNull);
    });

    test('a suggestion the charter caught up with is cleared', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1', charterLocked: true);
      await store.updateStoryline('sl-1',
          charterSuggestion: 'A wider charter nobody needs any more.');
      // The model answers with the stored charter, spaced differently: the
      // same sentence, so there is nothing left to offer.
      final llm = FakeLlm({
        'storyline_refresh': [
          refineAnswer(
            charter: '  The redesign of the Northline Studio website —   the '
                'homepage copy, the new photography, and the launch date. ',
          )
        ],
      });

      await StorylineService(store, llm).refresh('sl-1');

      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('a locked title survives a refresh that renamed everything else',
        () async {
      await seedStoryline(store, titleLocked: true);
      final llm = FakeLlm({
        'storyline_refresh': [
          refineAnswer(
            title: 'A name the model preferred',
            summary: 'The photography is back.',
            charter: widened,
          )
        ],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.title, 'Website redesign');
      expect(storyline.summary, 'The photography is back.');
      expect(storyline.charter, widened);
    });

    test('a summary is refreshed even when both locks are set', () async {
      await seedStoryline(store, titleLocked: true);
      await store.updateStoryline('sl-1', charterLocked: true);
      final llm = FakeLlm({
        'storyline_refresh': [
          refineAnswer(
            title: 'A name the model preferred',
            summary: 'The launch date moved to October.',
            charter: widened,
          )
        ],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // Both locks hold, and the one thing neither lock claimed still moves:
      // where the storyline STANDS is not something a rename took ownership
      // of.
      expect(storyline.title, 'Website redesign');
      expect(storyline.charter,
          startsWith('The redesign of the Northline Studio website'));
      expect(storyline.charterSuggestion, widened);
      expect(storyline.summary, 'The launch date moved to October.');
    });

    test('an empty title from the model keeps the stored one', () async {
      await seedStoryline(store);
      final llm = FakeLlm({'storyline_refresh': [refineAnswer(title: '')]});

      await StorylineService(store, llm).refresh('sl-1');

      // The naming task would have written 'Untitled storyline' here. A
      // storyline being re-described already has a name.
      expect((await store.getStoryline('sl-1'))!.title, 'Website redesign');
    });

    test('a refresh that describes an unchanged member set never reaches the '
        'model', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      // An empty script: any call at all throws rather than answering.
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.schemas, isEmpty);
    });

    test('the threads that joined since the last description are pointed out',
        () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c2', subject: 'Launch party venue');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'user');
      await store.updateStoryline('sl-1',
          memberHash: memberHashOf(['member', 'c2']));
      // Which member is newest is the only thing the "new" fence can be
      // derived from, so it is pinned rather than left to two writes landing
      // in different milliseconds.
      await memberAddedAt('sl-1', 'member', '2026-08-01T09:00:00Z');
      await memberAddedAt('sl-1', 'c2', '2026-08-02T09:00:00Z');
      final llm = FakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      final newFence = llm.userMessages.single.split('"new_threads"').last;
      expect(newFence, contains('Launch party venue'));
      expect(newFence, isNot(contains('Subject for member')));
      // And the whole membership still rides the threads fence.
      expect(llm.userMessages.single, contains('Subject for member'));
    });

    test('a storyline described before anyone counted its members points out '
        'nothing', () async {
      await seedStoryline(store);
      // A pre-feature row: the hash says the description is stale, but there
      // is no count to subtract, so nothing is KNOWN to be new.
      await store.updateStoryline('sl-1',
          memberHash: memberHashOf(['member']),
          refreshedMemberHash: 'an-older-member-set');
      final llm = FakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      final newFence = llm.userMessages.single.split('"new_threads"').last;
      expect(newFence, contains('(none)'));
    });

    test('a thread added while the refresh was in flight leaves the hash stale',
        () async {
      await seedStoryline(store);
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = HookedFakeLlm({
        'storyline_refresh': [refineAnswer()],
      }, (schemaName) async {
        if (schemaName != 'storyline_refresh') return;
        await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'user');
        await store.updateStoryline('sl-1',
            memberHash: memberHashOf(['member', 'c2']));
      });

      await StorylineService(store, llm).refresh('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // Stamped with what the description actually saw — one thread — even
      // though there are two now. The gate reads that as stale and the pass
      // runs again, which is the only outcome that describes the new thread.
      expect(storyline.refreshedMemberHash, memberHashOf(['member']));
      expect(storyline.refreshedMemberCount, 1);
      expect(storyline.memberHash, memberHashOf(['member', 'c2']));
    });

    test('a charter the refresh did not change recruits nothing', () async {
      await seedStoryline(store);
      final llm = FakeLlm({
        'storyline_refresh': [
          // The stored charter with its spacing mangled. A model that returns
          // the same sentence differently spaced has changed nothing, and
          // treating that as a change would put refresh and recruit into a
          // loop that re-ran on every drain.
          refineAnswer(
            charter: 'The redesign of the Northline Studio website —  the '
                'homepage copy,\nthe new photography, and the launch date.',
          )
        ],
      });

      await StorylineService(store, llm).refresh('sl-1');

      expect(await store.nextPendingWork('storyline_recruit'), isNull);
    });

    test('a charter the refresh widened sends the model hunting', () async {
      await seedStoryline(store);
      final llm = FakeLlm({
        'storyline_refresh': [refineAnswer(charter: widened)],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final work = await store.nextPendingWork('storyline_recruit');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a dismissed storyline is not refreshed', () async {
      await seedStoryline(store, status: 'dismissed');
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.schemas, isEmpty);
    });

    test('a storyline emptied by removals is not refreshed', () async {
      await seedStoryline(store);
      await store.removeStorylineMember('sl-1', 'email', 'member',
          block: true);
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      // No cards, so nothing to describe it from — and nothing is stamped
      // either, so the storyline is described the moment it holds a thread
      // again.
      expect(llm.schemas, isEmpty);
      expect((await store.getStoryline('sl-1'))!.refreshedMemberHash, isNull);
    });

    test('clearing a charter re-drafts one', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1', charterLocked: true);
      final llm = FakeLlm({
        'storyline_name': [nameAnswer(charter: 'A charter the model drafted.')],
      });
      final service = StorylineService(store, llm);

      await service.setCharter('sl-1', '   ');
      expect(await drainRefresh(service), 'sl-1');

      // The bootstrap branch, not the refresh one: a storyline with no charter
      // it is allowed to have is being described for the first time again, and
      // there is no current text for the continuity prompt to preserve.
      expect(llm.schemas, ['storyline_name']);
      expect((await store.getStoryline('sl-1'))!.charter,
          'A charter the model drafted.');
    });

    test('a recruit that filed threads refreshes the name', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).recruit('sl-1');

      final work = await store.nextPendingWork('storyline_refresh');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a recruit that filed nothing leaves the description alone', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });

      await StorylineService(store, llm).recruit('sl-1');

      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('one quiet thread does not wake the describer', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      // It reads well and it grew by one. Re-describing on every thread that
      // lands would dial the 27B all day to write the same sentence; the
      // sweep's catch-up picks this up when the mailbox next syncs.
      expect(await store.membersOf('sl-1'), hasLength(2));
      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('two threads since the last description do wake it', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c1', vector: vectorAt(0.9));
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer(), confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await service.assignConversation('email', 'c2');

      final work = await store.nextPendingWork('storyline_refresh');
      expect(work?['entity_id'], 'sl-1');
    });

    test('the sweep requeues a storyline whose refresh was swallowed',
        () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          memberHash: memberHashOf(['member']));
      // The lost wakeup: `requeueWork` revives only done and error rows, so a
      // refresh queued while an earlier one was `processing` vanished. All
      // that is left of it is a finished row and a description that does not
      // match the members.
      await store.writeWork('storyline_refresh', 'email', 'sl-1',
          status: 'done');

      await StorylineService(store, FakeLlm(const {})).sweep();

      // Found by the durable question rather than by an event — and found on
      // a sweep that returned early, which is why the catch-up runs before
      // the early returns rather than after them.
      final work = await store.nextPendingWork('storyline_refresh');
      expect(work?['entity_id'], 'sl-1');
    });

    test('the sweep leaves a storyline that already reads well alone',
        () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await store.writeWork('storyline_refresh', 'email', 'sl-1',
          status: 'done');

      await StorylineService(store, FakeLlm(const {})).sweep();

      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('an unknown storyline is a quiet no-op, not a throw', () async {
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-nope');

      expect(llm.schemas, isEmpty);
    });
  });

  group('recap', () {
    /// A storyline of two threads with messages on both, interleaved in time.
    /// The recap's whole point is that it reads them as one chronology.
    Future<void> seedTwoThreads() async {
      await seedStoryline(store);
      await seed(store, 'c2');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'user');
      await seedMessage(store, 'member', 'm1',
          receivedAt: '2026-08-01T09:00:00Z', body: 'the copy looks good');
      await seedMessage(store, 'c2', 'm2',
          receivedAt: '2026-08-01T10:00:00Z',
          fromName: 'Dana',
          body: 'the venue is booked');
      await seedMessage(store, 'member', 'm3',
          receivedAt: '2026-08-01T11:00:00Z',
          direction: 'outbound',
          body: 'sending it on to the studio');
    }

    test('a recap reads the newest messages across every member thread',
        () async {
      await seedTwoThreads();
      final llm = FakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, ['storyline_recap']);
      final user = llm.userMessages.single;
      // Both threads, and in the order they were said rather than the order
      // the store handed them over: "where does this stand now" is a question
      // about the end of a sequence.
      expect(user.indexOf('the copy looks good'),
          lessThan(user.indexOf('the venue is booked')));
      expect(user.indexOf('the venue is booked'),
          lessThan(user.indexOf('sending it on to the studio')));
      // Each line names its thread and who spoke, and the owner's own message
      // is theirs rather than a name the reader would have to recognise.
      expect(user, contains('[Subject for member] Sarah: the copy looks good'));
      expect(user, contains('[Subject for c2] Dana: the venue is booked'));
      expect(user, contains('You: sending it on to the studio'));
    });

    test('runs at temperature zero — the same window must read the same twice',
        () async {
      await seedTwoThreads();
      final llm = FakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.temperatures, [0]);
    });

    test('a recap that has seen the newest message never reaches the model',
        () async {
      await seedTwoThreads();
      await store.updateStoryline('sl-1',
          recapThrough: '2026-08-01T11:00:00Z', recapText: 'Already said.');
      // An empty script: any call at all throws rather than answering.
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, isEmpty);
      expect((await store.getStoryline('sl-1'))!.recapText, 'Already said.');
    });

    test('a burst of arrivals coalesces into one recap call', () async {
      await seedTwoThreads();
      // Three messages landing in member threads is three requeues — what
      // `ExtractHandler` writes as each one's facts land.
      for (var i = 0; i < 3; i++) {
        await store.requeueWork('storyline_recap', 'email', 'sl-1');
      }
      final llm = FakeLlm({'storyline_recap': [recapAnswer()]});
      final service = StorylineService(store, llm);

      // One row on the queue for three arrivals, because `requeueWork` is
      // keyed on `(kind, source, entity_id)`.
      expect(await store.workCounts('storyline_recap'), {'pending': 1});
      expect(await drainRecap(service), 'sl-1');

      // And the one pass that ran read the whole burst, which is the point:
      // the recap describes current state, so coalescing loses nothing.
      expect(llm.callsFor('storyline_recap'), 1);
    });

    test('a dismissed storyline gets no recap', () async {
      await seedStoryline(store, status: 'dismissed');
      await seedMessage(store, 'member', 'm1');
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, isEmpty);
    });

    test('a storyline with nothing said in it is a quiet no-op', () async {
      await seedStoryline(store);
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, isEmpty);
      expect((await store.getStoryline('sl-1'))!.recapThrough, isNull);
    });

    test('open items and decisions survive the round trip', () async {
      await seedTwoThreads();
      final llm = FakeLlm({
        'storyline_recap': [
          recapAnswer(
            recap: 'The launch is set and the photos are the last thing.',
            openItems: const ['Dana owes Sarah the photo selects', 'Book the room'],
            decisions: const ['Launch moved to October 9'],
          )
        ],
      });

      await StorylineService(store, llm).recap('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.recapText,
          'The launch is set and the photos are the last thing.');
      expect(jsonDecode(storyline.recapOpenJson!),
          ['Dana owes Sarah the photo selects', 'Book the room']);
      expect(jsonDecode(storyline.recapDecisionsJson!),
          ['Launch moved to October 9']);
      // The watermark is the newest message the call actually read.
      expect(storyline.recapThrough, '2026-08-01T11:00:00Z');
    });

    test('an honest empty list is stored as an empty list', () async {
      await seedTwoThreads();
      final llm = FakeLlm({
        'storyline_recap': [
          recapAnswer(openItems: const [], decisions: const [])
        ],
      });

      await StorylineService(store, llm).recap('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // Not null and not absent: "the model looked and found nothing
      // outstanding" is a different fact from "no recap has run".
      expect(jsonDecode(storyline.recapOpenJson!), isEmpty);
      expect(jsonDecode(storyline.recapDecisionsJson!), isEmpty);
    });

    test('a previous recap rides into the next call', () async {
      await seedTwoThreads();
      await store.updateStoryline('sl-1',
          recapText: 'The studio was still reviewing the homepage copy.',
          recapThrough: '2026-08-01T09:00:00Z');
      final llm = FakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      // Carried forward rather than started from scratch, which is what keeps
      // the block from re-narrating the whole storyline every time a message
      // lands.
      expect(llm.userMessages.single,
          contains('Previous recap: The studio was still reviewing the '
              'homepage copy.'));
    });

    test('the storyline the recap is about rides in with it', () async {
      await seedTwoThreads();
      final llm = FakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.userMessages.single, contains('Title: Website redesign'));
      expect(llm.userMessages.single,
          contains('Charter: The redesign of the Northline Studio website'));
    });

    test('a message landing while the recap ran leaves the watermark behind it',
        () async {
      await seedTwoThreads();
      final llm = HookedFakeLlm({
        'storyline_recap': [recapAnswer()],
      }, (schemaName) async {
        if (schemaName != 'storyline_recap') return;
        await seedMessage(store, 'c2', 'm4',
            receivedAt: '2026-08-01T12:00:00Z', body: 'one more thing');
      });

      await StorylineService(store, llm).recap('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // Stamped with the newest message the call actually READ, not the newest
      // there is now. Claiming otherwise would leave the gate reading fresh
      // and that message would never be recapped.
      expect(storyline.recapThrough, '2026-08-01T11:00:00Z');

      // Which the gate reads as stale, so the pass runs again — the only
      // outcome that gets the new message into the recap.
      final second = FakeLlm({'storyline_recap': [recapAnswer()]});
      await StorylineService(store, second).recap('sl-1');
      expect(second.callsFor('storyline_recap'), 1);
      expect(second.userMessages.single, contains('one more thing'));
    });

    test('a model with nothing to say does not blank a good recap', () async {
      await seedTwoThreads();
      await store.updateStoryline('sl-1',
          recapText: 'A recap worth keeping.',
          recapOpenJson: '["something still open"]',
          recapThrough: '2026-08-01T09:00:00Z');
      final llm = FakeLlm({'storyline_recap': [recapAnswer(recap: '   ')]});

      await StorylineService(store, llm).recap('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(llm.callsFor('storyline_recap'), 1);
      // Nothing written at all — not the text, not the lists, not the
      // watermark. A thin answer must never cost the user the catch-up they
      // had, and leaving the watermark behind means the next message asks
      // again.
      expect(storyline.recapText, 'A recap worth keeping.');
      expect(storyline.recapOpenJson, '["something still open"]');
      expect(storyline.recapThrough, '2026-08-01T09:00:00Z');
    });

    test('a hand-added thread recaps the storyline', () async {
      await seedStoryline(store);
      await seed(store, 'c2');
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).addThread('sl-1', 'email', 'c2');

      // A thread filed by hand brings its own messages, so where this
      // storyline stands changed the moment it landed.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a refresh queues a recap behind it', () async {
      await seedStoryline(store);
      final llm = FakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      // Membership moved, so the story moved: the recap was written against a
      // set of threads that is no longer the whole story.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a refresh that found nothing changed queues no recap', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.schemas, isEmpty);
      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('an unknown storyline is a quiet no-op, not a throw', () async {
      final llm = FakeLlm(const {});

      await StorylineService(store, llm).recap('sl-nope');

      expect(llm.schemas, isEmpty);
    });
  });

  group('the indexed sweep', () {
    // The native asset is expected to be here. The guard exists so a build
    // without code assets reports a skip rather than failures about geometry.
    late bool available;
    setUpAll(() {
      available = ensureSqliteVecLoaded();
      if (!available) {
        printOnFailure('sqlite-vec native asset missing — vec tests skipped');
      }
    });

    /// Every thread this corpus holds: its key, when it last moved, and where
    /// it sits.
    ///
    /// Ten threads in five orthogonal planes, so a group's geometry can be
    /// read off its own two angles and nothing else. [ray]'s planes are
    /// mutually orthogonal, which puts every cross-group cosine at exactly 0
    /// and leaves only the within-group angles to reason about.
    ///
    ///  * `a1 a2 a3` — three rays 0.05 rad apart: a cluster of three.
    ///  * `b1 b2` — the same, one plane over: a cluster of two.
    ///  * `e1 e2` — `acos(0.652)` apart, so 0.002 ABOVE the 0.65 link
    ///    threshold: a cluster the gate only just admits.
    ///  * `f1 f2` — `acos(0.648)` apart, 0.002 BELOW it: two singletons, and
    ///    the other side of the same `>=`.
    ///  * `n1` — alone in a plane of its own.
    ///
    /// The two 0.002 margins are the edge this pins, and they are deliberately
    /// margins rather than an exact 0.65. The index computes its distances
    /// natively over packed float32 and the fallback accumulates a dot product
    /// in Dart; the two agree to about 1e-6 (see
    /// `conversation_vec_index_test.dart`), which is far inside 0.002 and far
    /// outside anything that could make a pair land exactly ON the threshold
    /// reproducibly. A test written at exactly 0.65 would be a coin toss about
    /// float representation rather than a statement about the gate.
    const threshold = 0.65;
    final corpus = <({String key, String at, int plane, double angle})>[
      (key: 'a1', at: '2026-08-29T10:00:00Z', plane: 0, angle: 0.00),
      (key: 'a2', at: '2026-08-29T09:00:00Z', plane: 0, angle: 0.05),
      (key: 'a3', at: '2026-08-29T08:00:00Z', plane: 0, angle: 0.10),
      (key: 'b1', at: '2026-08-29T07:00:00Z', plane: 1, angle: 0.00),
      (key: 'b2', at: '2026-08-29T06:00:00Z', plane: 1, angle: 0.05),
      (key: 'e1', at: '2026-08-29T05:00:00Z', plane: 2, angle: 0.00),
      (
        key: 'e2',
        at: '2026-08-29T04:00:00Z',
        plane: 2,
        angle: math.acos(threshold + 0.002),
      ),
      (key: 'f1', at: '2026-08-29T03:00:00Z', plane: 3, angle: 0.00),
      (
        key: 'f2',
        at: '2026-08-29T02:00:00Z',
        plane: 3,
        angle: math.acos(threshold - 0.002),
      ),
      (key: 'n1', at: '2026-08-29T01:00:00Z', plane: 4, angle: 0.00),
    ];

    /// A unit vector in the plane spanned by dimensions `2 * plane` and
    /// `2 * plane + 1`, at [radians], padded to the index's width.
    List<double> ray(int plane, double radians) {
      final v = List<double>.filled(ConversationVectorIndex.dims, 0.0);
      v[plane * 2] = math.cos(radians);
      v[plane * 2 + 1] = math.sin(radians);
      return v;
    }

    Future<void> seedCorpus(MessageStore into) async {
      for (final thread in corpus) {
        await seed(
          into,
          thread.key,
          vector: ray(thread.plane, thread.angle),
          lastMessageAt: thread.at,
        );
      }
    }

    /// The model this corpus is scripted against: three clusters reach it in
    /// size order — `a` (three), then `b` and `e` (two each, in the order they
    /// were built) — and the last of them is thrown out whole, so the pass
    /// leaves a tombstone behind as well as two suggestions.
    FakeLlm scriptedLlm() => FakeLlm({
          'storyline_name': [
            nameAnswer(title: 'The first group'),
            nameAnswer(title: 'The second group'),
            nameAnswer(title: 'The rejected group'),
          ],
          'storyline_membership': [
            confirmAnswer(evidence: 'a1'),
            confirmAnswer(evidence: 'a2'),
            confirmAnswer(evidence: 'a3'),
            confirmAnswer(evidence: 'b1'),
            confirmAnswer(evidence: 'b2'),
            confirmAnswer(belongs: false, evidence: 'e1 is not this'),
            confirmAnswer(belongs: false, evidence: 'e2 is not this'),
          ],
        });

    /// Everything the sweep decided, in a form two runs can be compared by:
    /// the status, the title, BOTH hashes, and the member set of every
    /// storyline the pass wrote — sorted, so nothing turns on the random ids.
    ///
    /// `cluster_hash` is in here on purpose. It is the identity a dismissed
    /// cluster is tombstoned under, and the reason the clustering function has
    /// to be a pure function of its input: if the two paths grouped the same
    /// threads differently, this column is where it would show.
    Future<List<String>> decisionsOf(BondDatabase d, MessageStore s) async {
      final rows = await d
          .customSelect('SELECT id, title, status, member_hash, cluster_hash '
              'FROM storylines')
          .get();
      final out = <String>[];
      for (final row in rows) {
        final members = await s.membersOf(row.data['id'] as String);
        final keys = [
          for (final m in members) '${m.source}/${m.conversationKey}',
        ]..sort();
        out.add('${row.data['status']} | ${row.data['title']} | '
            'member=${row.data['member_hash']} | '
            'cluster=${row.data['cluster_hash']} | ${keys.join(',')}');
      }
      return out..sort();
    }

    test('the index and the arithmetic agree on every cluster', () async {
      if (!available) return;

      final indexedDb = vecTestDb();
      final indexedStore = ProbingStore(indexedDb);
      await seedCorpus(indexedStore);
      final indexedLlm = scriptedLlm();
      await StorylineService(indexedStore, indexedLlm).sweep();
      final indexed = await decisionsOf(indexedDb, indexedStore);
      final probes = indexedStore.neighborProbes;
      await indexedDb.close();

      final plainDb = vecTestDb();
      final plainStore = UnindexedStore(plainDb);
      await seedCorpus(plainStore);
      final plainLlm = scriptedLlm();
      await StorylineService(plainStore, plainLlm).sweep();
      final plain = await decisionsOf(plainDb, plainStore);
      await plainDb.close();

      // One probe per candidate, which is what says the index path actually
      // ran. Without it a silent fallback would make this test compare the
      // arithmetic against itself and pass for the wrong reason.
      expect(probes, corpus.length);

      // The whole claim of this phase, in one line.
      expect(indexed, plain);

      // And what they agree ON, spelled out, so a change that broke both
      // paths identically could not slip through as an equivalence.
      expect(indexed, hasLength(3));
      expect(
        indexed.map((d) => d.split(' | ').last).toList(),
        [
          // The rejected cluster keeps no members — it is a tombstone.
          '',
          'email/a1,email/a2,email/a3',
          'email/b1,email/b2',
        ],
      );
      // e1 and e2 sit 0.002 above the gate and were grouped — into the third
      // cluster, the one the model threw out. f1 and f2 sit 0.002 below it and
      // never became a cluster at all, which is why exactly three groups were
      // named and not four.
      expect(indexed.where((d) => d.startsWith('dismissed')), hasLength(1));
      expect(indexedLlm.callsFor('storyline_name'), 3);
      expect(indexedLlm.schemas, plainLlm.schemas);
      expect(indexedLlm.userMessages, plainLlm.userMessages);
    });

    test('a corpus the index cannot answer for falls back without proposing '
        'nonsense', () async {
      if (!available) return;

      // The store reports no index, which is what a failed backfill, a missing
      // native extension, and a connection opened before the extension was
      // registered all look like from the sweep's side.
      final db = vecTestDb();
      final store = UnindexedStore(db);
      await seedCorpus(store);
      final llm = scriptedLlm();

      await StorylineService(store, llm).sweep();

      final members = <String, List<String>>{};
      for (final storyline in await store.loadStorylines()) {
        members[storyline.title] = [
          for (final m in await store.membersOf(storyline.id)) m.conversationKey,
        ]..sort();
      }
      expect(members['The first group'], ['a1', 'a2', 'a3']);
      expect(members['The second group'], ['b1', 'b2']);
      await db.close();
    });

    test('one candidate at the wrong width sends the whole pass to the '
        'arithmetic', () async {
      if (!available) return;

      // A corpus caught mid-model-change: the index skips the narrow row, so
      // it holds a hole exactly where a link might be. Trusting it for the
      // rows it DID absorb would be the one way this feature could quietly
      // change what the app proposes, so the pass declines the index entirely.
      final db = vecTestDb();
      final store = ProbingStore(db);
      await seedCorpus(store);
      await seed(store, 'narrow',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T00:30:00Z');
      final llm = scriptedLlm();

      await StorylineService(store, llm).sweep();

      expect(store.neighborProbes, 0);
      final members = <String, List<String>>{};
      for (final storyline in await store.loadStorylines()) {
        members[storyline.title] = [
          for (final m in await store.membersOf(storyline.id)) m.conversationKey,
        ]..sort();
      }
      expect(members['The first group'], ['a1', 'a2', 'a3']);
      expect(members['The second group'], ['b1', 'b2']);
      await db.close();
    });
  });
}
