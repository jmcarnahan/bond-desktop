import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/conversation_vec_index.dart';
// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
// `show`: the charter centroid goes through the ONE clustering-card recipe,
// and this file pins its bytes against that same call rather than against a
// literal that would agree only until the shipped variant moved.
import 'package:bond_inbox/services/clustering_card.dart'
    show buildClusteringCard, shippedClusteringCard;
// `show`: the one thing this file wants from the extraction pass is the hash
// function behind both storyline hash recipes.
import 'package:bond_inbox/services/extract_handler.dart' show cardHash;
import 'package:bond_inbox/services/llm/embeddings_client.dart';
// `show`: what this file wants from the storyline tasks is the recap's own
// measured token ceiling and the naming call's two card caps.
import 'package:bond_inbox/services/llm/storyline_tasks.dart'
    show NameStorylineTask, StorylineRecapTask;
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/storyline_handler.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

/// One report from `StorylineService`'s `clusterObserver` seam: the cluster as
/// the sweep formed it, and the one word for what became of it.
typedef SeenCluster = ({
  List<({String source, String key})> threads,
  String outcome,
});

/// A [ScriptedLlm] that answers from a per-schema script and never opens a
/// socket.
///
/// Keyed on `schemaName` rather than on call order because the two storyline
/// tasks interleave: an assignment that confirms a membership may go straight
/// on to name the storyline, and a positional script would silently hand the
/// naming task the next confirmation answer.
///
/// Everything this file reads back — `schemas`, `userMessages`,
/// `temperatures`, `budgets`, `callsFor` — is a projection of the fixture's
/// one `calls` list, so the index-paired idiom below
/// (`userMessages[schemas.indexOf('storyline_name')]`) still holds.
ScriptedLlm fakeLlm(Map<String, List<Object>> scripts) {
  final llm = ScriptedLlm();
  scripts.forEach(llm.scriptFor);
  return llm;
}

/// An [EmbeddingsClient] that answers from memory and never opens a socket,
/// recording what it was asked to embed and under which prefix.
///
/// A subclass rather than a fake HTTP server because the one thing these tests
/// are about is the TEXT the charter centroid is built from, and a subclass is
/// the only double that can be read for it without decoding a request body.
class FakeEmbeddings extends EmbeddingsClient {
  final EmbedResult Function() _answer;

  final List<String> texts = [];
  final List<String> prefixes = [];

  FakeEmbeddings(this._answer)
      : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  /// A server that answers with the unit vector at cosine [c] against
  /// `vectorAt(1)`, the same two-dimensional geometry every other vector in
  /// this file lives in.
  factory FakeEmbeddings.at(double c) =>
      FakeEmbeddings(() => EmbedResult(EmbedOutcome.ok, vector: vectorAt(c)));

  /// A server that fails the same way every time. [EmbedOutcome.unavailable]
  /// is the park and [EmbedOutcome.rejected] is the quiet drop.
  factory FakeEmbeddings.failing(EmbedOutcome outcome) =>
      FakeEmbeddings(() => EmbedResult(outcome, reason: 'fake'));

  @override
  Future<EmbedResult> embedResult(
    String text, {
    String prefix = EmbeddingsClient.clusteringPrefix,
  }) async {
    texts.add(text);
    prefixes.add(prefix);
    return _answer();
  }
}

/// A [fakeLlm] that runs [onCall] before answering — how a test lands a user
/// action in the middle of a model call. The fixture's own `onCall` seam,
/// which runs inside the in-flight window and before the step.
ScriptedLlm hookedFakeLlm(
  Map<String, List<Object>> scripts,
  Future<void> Function(String schemaName) onCall,
) {
  final llm = ScriptedLlm(onCall: (call) => onCall(call.schemaName));
  scripts.forEach(llm.scriptFor);
  return llm;
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
/// is all these tests need — the gates are cosine thresholds, and a vector of
/// the width the app actually embeds at would only make the arithmetic harder
/// to read.
List<double> vectorAt(double c) => [c, math.sqrt(1 - c * c)];

Map<String, dynamic> confirmAnswer({
  String evidence = 'Both concern the website redesign.',
  bool belongs = true,
  String confidence = 'high',
}) =>
    {'evidence': evidence, 'belongs': belongs, 'confidence': confidence};

/// The naming task's answer.
///
/// [coherent] and [outliers] are emitted only when they are not the default,
/// so every script written before the namer could decline still reads as the
/// answer a server gave then — `validate` defaults a missing `coherent` to
/// true and a missing `outliers` to empty, which is what keeps those scripts
/// green.
Map<String, dynamic> nameAnswer({
  String title = 'Website redesign',
  String summary = 'The studio is reviewing the homepage copy.',
  String charter = 'The redesign of the Northline Studio website — the '
      'homepage copy, the new photography, and the launch date.',
  bool coherent = true,
  List<int> outliers = const [],
}) =>
    {
      'evidence': 'shared deal',
      'title': title,
      'summary': summary,
      'charter': charter,
      if (!coherent) 'coherent': false,
      if (outliers.isNotEmpty) 'outliers': outliers,
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

/// The body of one fence in a built user message — everything between its
/// opening tag and the next closing one.
///
/// Sliced rather than searched for, because "the subject is somewhere in the
/// message" is not what any of these tests mean: an example belongs in ITS
/// fence, and a card that leaked into the wrong one would still be `contains`.
String fenceBody(String message, String label) => message
    .split('<untrusted_data source="$label">')
    .last
    .split('</untrusted_data>')
    .first;

/// [key] with every digit spelled out, so the default subject gives each
/// thread its own series key. See the comment at `seed`'s subject.
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
    /// Participants with an ADDRESS as well as a name, for the one rule that
    /// reads both: the owner is recognised by either. Merged after
    /// [participants], which stays the short spelling every other test uses.
    List<({String? name, String? email})> participantRecords = const [],
    String state = 'waiting',
    String lastMessageAt = '2026-08-28T10:00:00Z',
    String? subject,
    String embedModel = EmbeddingsClient.modelTag,
    String source = 'email',
    bool keptInbound = true,
    int? messageCount,
    int? inboundCount,
    String fromAddress = 'sarah@example.com',
  }) async {
    await into.upsertConversation({
      'source': source,
      'conversation_key': key,
      // The digits are spelled out because the sweep's series pre-pass folds
      // every digit run in a subject to one placeholder: left as `c1`, `c2`,
      // `c3`, three default threads would read as one recurring series with
      // no outbound message and one sender, and the pre-pass would drop them
      // from the pool before the clustering ever saw them.
      'subject': subject ?? 'Subject for ${spellDigits(key)}',
      'state': state,
      'last_message_at': lastMessageAt,
      'participants_json': jsonEncode([
        for (final p in participants) {'name': p},
        for (final p in participantRecords) {'name': p.name, 'email': p.email},
      ]),
      // The series pre-pass's counters, written only when a test means to
      // build a shape that depends on them.
      'message_count': ?messageCount,
      'inbound_count': ?inboundCount,
    });
    if (vector == null) return;
    // A thread the gates emptied is not a candidate for anything — the assign
    // pass returns `AssignOutcome.gated` before it looks for a vector, and the
    // sweep pool asks for a kept inbound message too. A conversation carrying
    // an embedding and no messages at all is exactly that shape, and it is one
    // the app cannot produce: the embedding is written by extraction, which
    // does not run until triage has spoken. So a seeded VECTOR brings the
    // message it implies. Its id sorts below the ids these tests write by
    // hand, so a test's own message is still the thread's newest inbound; the
    // groups that read a thread's whole chronology pass `keptInbound: false`
    // and seed their own.
    if (keptInbound) {
      await into.upsertMessage({
        'source': source,
        'source_message_id': 'kept-$key',
        'conversation_key': key,
        'direction': 'inbound',
        'subject': subject ?? 'Subject for ${spellDigits(key)}',
        'from_name': 'Sarah',
        'from_address': fromAddress,
        'received_at': lastMessageAt,
        'body_text': 'body of kept-$key',
        'triage_status': 'triaged',
      });
    }
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
    String triageStatus = 'pending',
    String? gateReason,
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
        'triage_status': triageStatus,
        'gate_reason': gateReason,
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
    // Passed through to [seed]. The recap group reads a thread's whole
    // chronology and seeds every message it means to read, so it turns the
    // implied kept message off rather than counting one it did not write.
    bool keptInbound = true,
  }) async {
    await seed(
      into,
      memberKey,
      vector: memberVector ?? vectorAt(1),
      participants: memberParticipants,
      keptInbound: keptInbound,
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

  /// Whether [later] sorts after [earlier]. Both are ISO stamps and the
  /// comparison the drain makes is SQLite's string compare, so this is
  /// `compareTo` rather than `greaterThan` — `String` has no `<`, and the
  /// ordering matchers call it.
  bool sortsAfter(String later, String earlier) => later.compareTo(earlier) > 0;

  /// One work row's `created_at`, which is what the drain's `created_at DESC`
  /// claim order reads and what `refreshCreatedAt` moves.
  Future<String> workCreatedAt(String kind, String entityId) async {
    final row = await db
        .customSelect(
          'SELECT created_at FROM work_items '
          'WHERE task_kind = ? AND entity_id = ?',
          variables: [Variable(kind), Variable(entityId)],
        )
        .getSingle();
    return row.data['created_at'] as String;
  }

  /// Moves one work row's `created_at` back a day, so a later row's stamp is
  /// unambiguously newer than it. `_nowIso()` has millisecond precision and two
  /// rows written in one test can share a stamp; a claim-order assertion needs
  /// the two to be genuinely apart.
  Future<void> backdateWork(String kind, String entityId) => db.customUpdate(
        'UPDATE work_items SET created_at = ? '
        'WHERE task_kind = ? AND entity_id = ?',
        variables: [
          Variable(MessageStore.isoStamp(
              DateTime.now().subtract(const Duration(days: 1)))),
          Variable(kind),
          Variable(entityId),
        ],
      );

  /// How many pending rows of [kind] the queue holds. `nextPendingWork`
  /// answers whether there is one; this answers whether there is exactly one.
  Future<int> pendingCount(String kind) async {
    final rows = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM work_items "
          "WHERE task_kind = ? AND status = 'pending'",
          variables: [Variable(kind)],
        )
        .getSingle();
    return rows.data['n'] as int;
  }

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.temperatures, [0]);
    });

    test('a candidate under the gate never reaches the model', () async {
      await seedStoryline(store);
      // 0.40 is under the plain gate of 0.44 and there is nobody in common.
      await seed(store, 'c1', vector: vectorAt(0.40), participants: const ['Ann Lu']);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('two shared people lower the gate, one does not', () async {
      // The same vector as the test above, and the same 0.40 cosine. What
      // buys the discount is a GROUP in common: one shared person is what
      // every pair of threads in a one-team mailbox has, so the old rule made
      // the discounted gate the real one. Two is a group.
      await seedStoryline(store,
          memberParticipants: const ['Sarah Chen', 'Ann Lu']);
      await seed(store, 'c1',
          vector: vectorAt(0.40), participants: const ['sarah chen']);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.noCandidate);
      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));

      await seed(store, 'c2',
          vector: vectorAt(0.40), participants: const ['sarah chen', 'ann lu']);

      expect(await StorylineService(store, llm).assignConversation('email', 'c2'),
          AssignOutcome.assigned);
      expect(llm.callsFor('storyline_membership'), 1);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['member', 'c2']);
    });

    test('the owner never counts toward the overlap', () async {
      // The owner is on every thread in their own mailbox, so counting them
      // as a shared person would hand the discount to any two threads at all.
      await seedStoryline(store,
          memberParticipants: const ['Pat Owner', 'Ann Lu']);
      await seed(store, 'c1',
          vector: vectorAt(0.40), participants: const ['Pat Owner', 'Ann Lu']);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(
        store,
        llm,
        owner: () async => (name: 'Pat Owner', address: 'pat@example.com'),
      );

      // Two shared displays, but one of them is the owner: one shared person
      // is left, which is not a group.
      expect(await service.assignConversation('email', 'c1'),
          AssignOutcome.noCandidate);
      expect(llm.schemas, isEmpty);
    });

    test('a namesake of the owner is dropped from the overlap count too',
        () async {
      // The other side of the address rule: a DIFFERENT person spelled like
      // the owner is read as the owner and does not count. Deliberate, and
      // the doc comment on `_nonOwnerDisplaysOf` says why — the cost is one
      // thread that missed the lower gate, against a discount that would
      // otherwise fire on the one person who is on every thread in the
      // mailbox.
      await seedStoryline(store,
          memberParticipants: const ['Pat Owner', 'Ann Lu']);
      await seed(
        store,
        'c1',
        vector: vectorAt(0.40),
        participants: const ['Ann Lu'],
        participantRecords: const [
          (name: 'Pat Owner', email: 'pat.owner@partner.example.com'),
        ],
      );
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(
        store,
        llm,
        owner: () async => (name: 'Pat Owner', address: 'pat@example.com'),
      );

      // Two shared displays, one of them the owner's name: one shared person
      // is left, which is not a group.
      expect(await service.assignConversation('email', 'c1'),
          AssignOutcome.noCandidate);
      expect(llm.schemas, isEmpty);
    });

    test('and is recognised by address when the display says otherwise',
        () async {
      await seedStoryline(store,
          memberParticipants: const ['Pat Owner', 'Ann Lu']);
      await seed(
        store,
        'c1',
        vector: vectorAt(0.40),
        participants: const ['Ann Lu'],
        // The same person the storyline knows as "Pat Owner", writing from a
        // client that spells the display differently. The address is what
        // settles it.
        participantRecords: const [(name: 'P. Owner', email: 'pat@example.com')],
      );
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(
        store,
        llm,
        owner: () async => (name: 'Pat Owner', address: 'pat@example.com'),
      );

      expect(await service.assignConversation('email', 'c1'),
          AssignOutcome.noCandidate);
      expect(llm.schemas, isEmpty);
    });

    test('a lookup that throws counts everyone as not the owner, and is asked '
        'again', () async {
      // Until an answer arrives every participant counts, which keeps the
      // overlap rule STRICTER than it would otherwise be — never looser — and
      // the next thread asks again rather than inheriting one keychain
      // hiccup forever.
      await seedStoryline(store,
          memberParticipants: const ['Pat Owner', 'Ann Lu']);
      await seed(store, 'c1',
          vector: vectorAt(0.40), participants: const ['Pat Owner', 'Ann Lu']);
      await seed(store, 'c2',
          vector: vectorAt(0.40), participants: const ['Pat Owner', 'Ann Lu']);
      // A no, so the storyline's centroid does not move between the two
      // threads and the only thing that changed is who the owner is.
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });
      var lookups = 0;
      final service = StorylineService(
        store,
        llm,
        owner: () async {
          lookups++;
          if (lookups == 1) throw StateError('keychain unavailable');
          return (name: 'Pat Owner', address: 'pat@example.com');
        },
      );

      // Pat is a person like any other while the lookup is silent: two shared
      // people, so the discount applies, 0.40 clears 0.37 and the model is
      // asked.
      expect(await service.assignConversation('email', 'c1'),
          AssignOutcome.rejected);
      // The second thread is judged with the answer, so Pat drops out, one
      // shared person is left and nothing reaches the model at all.
      expect(await service.assignConversation('email', 'c2'),
          AssignOutcome.noCandidate);
      expect(llm.callsFor('storyline_membership'), 1);
      expect(lookups, 2);
    });

    /// Two live storylines a thread at `[1, 0]` sees at exactly [firstCosine]
    /// and [secondCosine]: a storyline's centroid is its single member's
    /// vector, so placing the member places the storyline.
    Future<void> seedTwoCandidates({
      required double firstCosine,
      required double secondCosine,
      String firstStatus = 'active',
      String secondStatus = 'active',
    }) async {
      await seedStoryline(store,
          id: 'sl-near',
          status: firstStatus,
          memberKey: 'near',
          memberVector: vectorAt(firstCosine));
      await seedStoryline(store,
          id: 'sl-far',
          status: secondStatus,
          memberKey: 'far',
          memberVector: vectorAt(secondCosine));
      await seed(store, 'c1', vector: vectorAt(1));
    }

    test('a near-tie confirms both and takes high over medium', () async {
      // 0.62 against 0.60 is a coin toss dressed as a ranking, so the cosine
      // stops deciding and the answers decide instead.
      await seedTwoCandidates(firstCosine: 0.62, secondCosine: 0.60);
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'high'),
        ],
      });

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.assigned);

      expect(llm.callsFor('storyline_membership'), 2);
      expect(await store.membersOf('sl-near'), hasLength(1));
      expect((await store.membersOf('sl-far')).map((m) => m.conversationKey),
          ['far', 'c1']);
    });

    test('and says in the log that it asked twice', () async {
      await seedTwoCandidates(firstCosine: 0.62, secondCosine: 0.60);
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'high'),
        ],
      });
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(store, llm, activityLog: log)
          .assignConversation('email', 'c1');
      await log.record('storyline', source: 'email', entityId: 'c1');

      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.detail['confirmed'], 2);
    });

    test('a near-tie on equal confidence takes the higher cosine', () async {
      await seedTwoCandidates(firstCosine: 0.62, secondCosine: 0.60);
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(), confirmAnswer()],
      });

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.callsFor('storyline_membership'), 2);
      expect((await store.membersOf('sl-near')).map((m) => m.conversationKey),
          ['near', 'c1']);
      expect(await store.membersOf('sl-far'), hasLength(1));
    });

    test('a near-tie where neither is accepted is rejected, once', () async {
      await seedTwoCandidates(firstCosine: 0.62, secondCosine: 0.60);
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(belongs: false),
          confirmAnswer(belongs: false),
        ],
      });

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.rejected);

      expect(llm.callsFor('storyline_membership'), 2);
      expect(await store.membersOf('sl-near'), hasLength(1));
      expect(await store.membersOf('sl-far'), hasLength(1));
    });

    test('a gap beyond the margin is still a ranking, and one question',
        () async {
      await seedTwoCandidates(firstCosine: 0.70, secondCosine: 0.60);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.callsFor('storyline_membership'), 1);
      expect((await store.membersOf('sl-near')).map((m) => m.conversationKey),
          ['near', 'c1']);
    });

    test('an active storyline takes a medium yes, as it always did', () async {
      // A group the owner kept is a group they have looked at.
      await seedStoryline(store, memberKey: 'kept');
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'medium')],
      });

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.assigned);
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('a suggested one needs high', () async {
      // Auto-filing into a group nobody has kept yet is what grew the blobs,
      // so it needs the strongest answer the model gives.
      await seedStoryline(store, status: 'suggested', memberKey: 'new');
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'medium')],
      });

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.rejected);
      // Asked, and turned down on the answer rather than kept from the model.
      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('and a high yes files into it', () async {
      await seedStoryline(store, status: 'suggested', memberKey: 'new');
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'high')],
      });

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.assigned);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['new', 'c1']);
    });

    test('a blocked thread is skipped entirely', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
    });

    test('a "no" adds nothing and blocks nothing', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      // The thread has something kept to say — otherwise the pass closes it
      // `gated` before it ever asks for a vector, and there is no park to
      // pin. `seed` writes no message of its own without a vector.
      await seedMessage(store, 'c1', 'c1-m1', triageStatus: 'triaged');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
    });

    test('an unknown conversation returns silently', () async {
      await seedStoryline(store);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.assigned,
      );
    });

    test('a model that says no is rejected, not merely nothing', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95));
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
          vector: vectorAt(0.40), participants: const ['Ann Lu']);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.blocked,
      );
    });

    test('a conversation that no longer exists is noCandidate, not a park',
        () async {
      await seedStoryline(store);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      // Parking on it would hold the queue open forever for a thread no
      // embedding is ever coming for.
      expect(
        await StorylineService(store, llm).assignConversation('email', 'gone'),
        AssignOutcome.noCandidate,
      );
    });

    test('a thread the gates emptied is gated, before any call is made',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', keptInbound: false);
      await seedMessage(store, 'c1', 'm1',
          triageStatus: 'skipped', gateReason: 'no_reply');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      // No embeddings client is given to this service, so a pass that
      // reached the re-embed would THROW rather than return — which is what
      // makes this assertion the proof that it did not: the guard sits
      // before the vector, not after it.
      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.gated,
      );
      expect(llm.schemas, isEmpty, reason: 'no model was asked');
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a gated thread that still carries an embedding is gated too',
        () async {
      // The embedding is the residue of the race this round closed:
      // extraction reached the message before triage did, embedded it, and
      // the vector outlived the verdict. It is not evidence of anything.
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95), keptInbound: false);
      await seedMessage(store, 'c1', 'm1',
          triageStatus: 'skipped', gateReason: 'newsletter');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.gated,
      );
      expect(llm.schemas, isEmpty);
    });

    test('one kept inbound is enough to be looked at again', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95), keptInbound: false);
      await seedMessage(store, 'c1', 'gated',
          receivedAt: '2026-08-28T11:00:00Z',
          triageStatus: 'skipped',
          gateReason: 'no_reply');
      await seedMessage(store, 'c1', 'kept', triageStatus: 'triaged');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.assigned,
      );
    });

    test('a thread of nothing but the user\'s own sends is gated', () async {
      // Outbound is born `skipped`/`outbound`. Counting it as kept would make
      // every thread the user ever answered look like a candidate.
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.95), keptInbound: false);
      await seedMessage(store, 'c1', 'mine',
          direction: 'outbound',
          triageStatus: 'skipped',
          gateReason: 'outbound');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(
        await StorylineService(store, llm).assignConversation('email', 'c1'),
        AssignOutcome.gated,
      );
    });
  });

  /// The rule that stops one group swallowing the mailbox.
  ///
  /// The Phase 3 sweep bench ended with two storylines holding 71% of every
  /// filed thread, all of it put there by the assign pass — so a storyline
  /// taking a disproportionate share of the recent automatic adds is treated
  /// as a charter that admits everything, skipped as a candidate, and sent to
  /// the audit instead of grown further.
  group('the catch-all', () {
    /// A storyline with [adds] membership rows, the FIRST of which carries
    /// [vector] and the rest nothing. The centroid is the first member's, so
    /// a test places a storyline in space and loads its recent-add count
    /// independently of each other.
    Future<void> seedGroup(
      String id, {
      required int adds,
      List<double>? vector,
      String addedBy = 'auto',
      String status = 'active',
    }) async {
      await store.insertStoryline(
        id: id,
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        charter: 'The redesign of the Northline Studio website.',
        status: status,
        createdBy: 'auto',
      );
      for (var i = 0; i < adds; i++) {
        final key = '$id-member-${spellDigits('$i')}';
        await seed(store, key, vector: i == 0 ? vector : null);
        await store.addStorylineMember(id, 'email', key, addedBy: addedBy);
      }
    }

    /// Seven adds to `sl-a`, two to `sl-b` and one to `sl-c`: ten in the
    /// window over three storylines, so the threshold is twice a third and
    /// `sl-a`'s seven clears it.
    Future<void> seedShares({
      List<double>? aVector,
      List<double>? bVector,
      String addedBy = 'auto',
    }) async {
      await seedGroup('sl-a', adds: 7, vector: aVector, addedBy: addedBy);
      await seedGroup('sl-b', adds: 2, vector: bVector, addedBy: addedBy);
      await seedGroup('sl-c', adds: 1, vector: vectorAt(0), addedBy: addedBy);
    }

    test('the arithmetic is twice a fair share, never under three in ten', () {
      Set<String> of(Map<String, int> byStoryline) =>
          StorylineService.catchAllsOf(
            byStoryline: byStoryline,
            total: byStoryline.values.fold(0, (a, b) => a + b),
          );

      // Three storylines: a fair share is a third, so the bar is two thirds.
      expect(of({'a': 7, 'b': 2, 'c': 1}), {'a'});
      // Two storylines: the bar is the whole window, and the rule never
      // fires. There is nothing for a catch-all to be a catch-all OF.
      expect(of({'a': 6, 'b': 4}), isEmpty);
      // Five: the fair-share half is 40%, and half of ten beats it.
      expect(of({'a': 5, 'b': 2, 'c': 1, 'd': 1, 'e': 1}), {'a'});
      // Exactly 40% is not more than 40%.
      expect(of({'a': 4, 'b': 2, 'c': 2, 'd': 1, 'e': 1}), isEmpty);
      // Nine adds is not a pattern, whatever its shape.
      expect(of({'a': 8, 'b': 1}), isEmpty);
      // Ten storylines: twice a fair share is 20%, so the 30% floor is what
      // holds — 25% is not a catch-all and 31% is.
      expect(
          of({
            'a': 3,
            for (final id in ['b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'])
              id: 1,
          }),
          isEmpty);
      expect(
          of({
            'a': 4,
            for (final id in ['b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'])
              id: 1,
          }),
          {'a'});
      // No storyline received an add: there is nothing to be a catch-all of,
      // and nothing to divide a fair share by either.
      expect(
          StorylineService.catchAllsOf(byStoryline: const {}, total: 10),
          isEmpty);
      // One storyline, however much it took: the bar is twice the whole
      // window and can never be cleared.
      expect(of({'a': 12}), isEmpty);
    });

    test('a catch-all is skipped, the outcome says so, and one audit is queued',
        () async {
      await seedShares(aVector: vectorAt(1), bVector: vectorAt(0));
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(store, llm);

      expect(await service.assignConversation('email', 'c1'),
          AssignOutcome.catchAll);

      // Not filed, and never asked: a group that admits everything would
      // answer yes.
      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-a'), hasLength(7));
      expect((await store.nextPendingWork('storyline_audit'))?['entity_id'],
          'sl-a');

      await seed(store, 'c2', vector: vectorAt(0.9));
      expect(await service.assignConversation('email', 'c2'),
          AssignOutcome.catchAll);

      // A hundred threads arriving while the audit is pending queue one
      // audit: `requeueWork` revives only `done` and `error` rows.
      expect(await store.workCounts('storyline_audit'), {'pending': 1});
    });

    test('and the audit is not re-queued once it has run in this window',
        () async {
      // The audit runs at temperature 0 against an unchanged charter, so
      // asking it again this afternoon spends one confirm per automatic
      // member to be told what it was told this morning.
      await seedShares(aVector: vectorAt(1), bVector: vectorAt(0));
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');

      /// The audit drained, and last wrote its row at [updatedAt].
      Future<void> auditRan(String updatedAt) => db.customUpdate(
            "UPDATE work_items SET status = 'done', updated_at = ? "
            "WHERE task_kind = 'storyline_audit' AND entity_id = 'sl-a'",
            variables: [Variable(updatedAt)],
          );

      await auditRan(MessageStore.isoStamp(DateTime.now()));
      await seed(store, 'c2', vector: vectorAt(0.9));

      expect(await service.assignConversation('email', 'c2'),
          AssignOutcome.catchAll);
      expect(await store.workCounts('storyline_audit'), {'done': 1});

      // A touch older than the window is a pass whose answer may have gone
      // stale, and that one is worth asking again.
      await auditRan(MessageStore.isoStamp(DateTime.now().subtract(
          const Duration(days: StorylineTuning.catchAllWindowDays + 1))));
      await seed(store, 'c3', vector: vectorAt(0.9));

      expect(await service.assignConversation('email', 'c3'),
          AssignOutcome.catchAll);
      expect(await store.workCounts('storyline_audit'), {'pending': 1});
    });

    test('a catch-all that is not the only candidate is passed over',
        () async {
      // `sl-a` is the closer of the two and would have won the shortlist.
      await seedShares(aVector: vectorAt(0.9), bVector: vectorAt(0.7));
      await seed(store, 'c1', vector: vectorAt(1));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.assigned);

      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-a'), hasLength(7));
      expect((await store.membersOf('sl-b')).last.conversationKey, 'c1');
    });

    test('a catch-all under the gate is not the catch-all ending', () async {
      // The skip is checked AFTER the gate on purpose: a group this thread
      // would never have joined is not "the only qualifying candidate", and
      // saying so would queue an audit for every thread in the mailbox.
      await seedShares(aVector: vectorAt(0.1), bVector: vectorAt(0));
      await seed(store, 'c1', vector: vectorAt(1));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.noCandidate);
      expect(await store.nextPendingWork('storyline_audit'), isNull);
    });

    test("the owner's own filings do not make a catch-all", () async {
      // Hand-filing is not the assign pass's habit, and this rule measures
      // the pass's habit. With `sl-a`'s seven uncounted the window holds
      // nothing at all, so nothing is skipped.
      await seedShares(
          aVector: vectorAt(1), bVector: vectorAt(0), addedBy: 'user');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.assigned);
      expect((await store.membersOf('sl-a')).last.conversationKey, 'c1');
      expect(await store.nextPendingWork('storyline_audit'), isNull);
    });

    test('blocked and skipped together read as the catch-all', () async {
      // Both endings are true of this thread; the catch-all is the one worth
      // saying, because it is the one that queued a pass.
      await seedShares(aVector: vectorAt(1), bVector: vectorAt(0.95));
      await seed(store, 'c1', vector: vectorAt(0.9));
      await store.removeStorylineMember('sl-b', 'email', 'c1', block: true);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      expect(await StorylineService(store, llm).assignConversation('email', 'c1'),
          AssignOutcome.catchAll);
      expect((await store.nextPendingWork('storyline_audit'))?['entity_id'],
          'sl-a');
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

    String confirmMessageOf(ScriptedLlm llm) =>
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = hookedFakeLlm({
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      // Three linked threads, because a cosine pair is under
      // `proposeMinClusterSize` and never reaches the namer.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c4', vector: vectorAt(0));
      await seed(store, 'c5', vector: vectorAt(-0.9));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect((await store.loadStorylines()).single.charter,
          startsWith('The redesign of the Northline Studio website'));
    });

    test('a model that offered no charter leaves the column null', () async {
      // Three linked threads, because a cosine pair is under
      // `proposeMinClusterSize` and never reaches the namer.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c4', vector: vectorAt(0));
      await seed(store, 'c5', vector: vectorAt(-0.9));
      final llm = fakeLlm({
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
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.assignConversation('email', 'c1');
      await drainRefresh(service);

      // Clamped per card AND as a set: every card is whole under `cardCap`
      // rather than eighty characters of each, and the ten of them joined
      // still fit one prompt under `cardsCap` however long each summary ran.
      final naming = llm.userMessages[llm.schemas.indexOf('storyline_name')];
      expect(fenceBody(naming, 'threads').length,
          lessThanOrEqualTo(NameStorylineTask.cardsCap));
      for (final card in fenceBody(naming, 'threads').trim().split('\n---\n')) {
        expect(card.length, lessThanOrEqualTo(NameStorylineTask.cardCap));
      }
    });
  });

  group('sweep', () {
    /// Five unassigned threads: c1, c2 and c3 are a clique; c4 and c5 link to
    /// nothing, each other included.
    ///
    /// Three in the clique and not two, because a cosine cluster needs
    /// [StorylineTuning.proposeMinClusterSize] threads before the sweep will
    /// spend a naming call on it: a pair is a coincidence that would be asked
    /// to confirm itself against a charter written from the pair.
    Future<void> seedMailbox(MessageStore into) async {
      await seed(into, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c4',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c5',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
    }

    test('a lone unassigned thread is below the gate', () async {
      // One thread is nothing to pair, and a storyline of one is just a
      // thread — the sweep does not reach the model at all.
      await seed(store, 'c1', vector: vectorAt(1));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('a two-thread cosine pair is not proposed; a three-thread cluster is',
        () async {
      // Pins the gate at three. Two threads that merely embed alike are a
      // coincidence, and the confirms cannot rescue a pair: it would be
      // judged against a charter written from those same two threads, so the
      // coincidence describes itself and then agrees. A light mailbox still
      // forms its first storyline at three, which is where a pattern starts.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();

      // Not one call: the pair never reached the namer, so there is nothing
      // to tombstone either — it is back in the pool for a third thread.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);

      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');

      await service.sweep();

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');

      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(),
          {'c1', 'c2', 'c3'});
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 3);
    });

    test('a chain of four buys no naming call at all', () async {
      // The failure the join rule exists for, at the sweep's own level. Each
      // thread is 0.765 from its neighbour and 0.17 from the thread beyond it,
      // so single-link welded all four into one cluster and spent one naming
      // call describing whatever they had in common — which, in a one-team
      // mailbox, is the team. Two links and half the members leaves the chain
      // as the two pairs it actually is, and under
      // `proposeMinClusterSize` a pair is not a question: the chain now costs
      // nothing instead of one name for four threads or two for two pairs.
      // The threads stay in the pool, where a third neighbour would make one
      // of those pairs into a group worth asking about.
      //
      // Two dimensions is as far as this file's vectors go, which is why the
      // cap, the coherence floor and the split ladder are pinned in
      // `storyline_clustering_test.dart` instead: a group of four whose
      // members are pairwise close and whose mean is still low does not fit
      // on a circle.
      for (final (index, thread) in [
        ('c1', '2026-08-29T04:00:00Z'),
        ('c2', '2026-08-29T03:00:00Z'),
        ('c3', '2026-08-29T02:00:00Z'),
        ('c4', '2026-08-29T01:00:00Z'),
      ].indexed) {
        await seed(store, thread.$1,
            vector: vectorAt(math.cos(0.7 * index)),
            lastMessageAt: thread.$2);
      }
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
      // No tombstone either: nothing was asked, so there is no answer to
      // remember and no hash to recognise.
      expect(await store.assignedOrBlockedKeys('email'), isEmpty);
    });

    test('two tight triples are two proposals', () async {
      // The other half of the same rule: a group whose members all recognise
      // each other stays whole, and a second group nowhere near it is its own
      // proposal rather than threads the first one absorbed. Three a side,
      // because a pair is under `proposeMinClusterSize` — the far group used
      // to be two threads here, and two threads no longer buy a name.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T06:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T05:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c5',
          vector: vectorAt(-0.95), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c6',
          vector: vectorAt(-1), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [
          nameAnswer(title: 'The near triple'),
          nameAnswer(title: 'The far triple'),
        ],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final members = <String, Set<String>>{};
      for (final storyline in await store.loadStorylines()) {
        members[storyline.title] = {
          for (final m in await store.membersOf(storyline.id)) m.conversationKey,
        };
      }
      expect(members, {
        'The near triple': {'c1', 'c2', 'c3'},
        'The far triple': {'c4', 'c5', 'c6'},
      });
      expect(llm.callsFor('storyline_name'), 2);
      expect(llm.callsFor('storyline_membership'), 6);
    });

    test('a cluster stops at twelve, and the thirteenth is not a member',
        () async {
      // The cap, through the app's own wiring rather than through the module:
      // thirteen threads at the same point, so nothing but the cap decides the
      // shape. The twelve are coherent at every rung of the split ladder, so
      // they survive being re-clustered for being large; the thirteenth is a
      // cluster of one and never reaches the model.
      for (var i = 1; i <= 13; i++) {
        await seed(store, 'c$i',
            vector: vectorAt(1),
            lastMessageAt: '2026-08-${29 - i}T10:00:00Z');
      }
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      final members = {
        for (final m in await store.membersOf(storyline.id)) m.conversationKey,
      };
      expect(members, hasLength(StorylineTuning.maxClusterSize));
      expect(members, isNot(contains('c13')));
      // One name over twelve cards, and one confirm per card.
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'),
          StorylineTuning.maxClusterSize);
      final naming = llm.userMessages.first;
      expect(
        [
          for (var i = 1; i <= 13; i++)
            if (naming.contains('Subject for ${spellDigits('c$i')}')) 'c$i',
        ],
        hasLength(StorylineTuning.maxClusterSize),
      );
      // Nothing filed it and nothing blocked it, so it is back in the pool for
      // the next sweep.
      expect(await store.storylineIdsFor('email', 'c13'), isEmpty);
    });

    test('an all-gated thread is never proposed, embedding and all', () async {
      // The backstop, and what it pins is the STORE's pool: the thread is
      // excluded by `conversationsWithEmbeddings` before the sweep sees it.
      // The index probe's own guard — a neighbour whose key is not among the
      // candidate rows is dropped (`_indexedSimilarities`) — is not exercised here,
      // because `flutter test` has no sqlite-vec extension and the sweep runs
      // its brute-force path; that line is read, not run, in this file.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'gated',
          vector: vectorAt(0.99),
          lastMessageAt: '2026-08-29T05:00:00Z',
          keptInbound: false);
      await seedMessage(store, 'gated', 'g1',
          receivedAt: '2026-08-29T05:00:00Z',
          triageStatus: 'skipped',
          gateReason: 'no_reply');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(), confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2', 'c3'});
      // Three members, three confirmations — the gated thread was never even
      // put to the model, which is the cost this is really about.
      expect(llm.callsFor('storyline_membership'), 3);
      expect(await store.storylineIdsFor('email', 'gated'), isEmpty);
    });

    test('a cluster becomes one suggestion with its confirmed members',
        () async {
      await seedMailbox(store);
      // One answer per member, in the order the sweep reads the rows — newest
      // first, so c1, c2, then c3. Distinct sentences, because the point of
      // the stage is that each thread gets its own reason rather than the
      // cluster's.
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(evidence: 'c1 is the homepage copy review.'),
          confirmAnswer(evidence: 'c2 is the same review, continued.'),
          confirmAnswer(evidence: 'c3 is the launch date for it.'),
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
      expect(members.map((m) => m.conversationKey).toSet(),
          {'c1', 'c2', 'c3'});
      expect(members.every((m) => m.addedBy == 'auto'), isTrue);
      // Each member carries what the model said about IT — the blanket
      // "clustered together" was the pass claiming a justification nothing
      // had produced.
      expect(
        {for (final m in members) m.conversationKey: m.evidence},
        {
          'c1': 'c1 is the homepage copy review.',
          'c2': 'c2 is the same review, continued.',
          'c3': 'c3 is the launch date for it.',
        },
      );
      // Named once, then every member of the cluster judged against that name.
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 3);
      // Naming and confirming alike: an unchanged mailbox swept twice must
      // propose the same storyline out of the same threads.
      expect(llm.temperatures, [0, 0, 0, 0]);
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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

    test("the sweep's own members are held to high", () async {
      // The proposal the members are judged against is `suggested` by
      // construction, so the newborn storyline is built of `high` answers or
      // it is not built at all. Three medium yeses leave no survivors, which
      // is the same ending an outright rejection reaches.
      await seedMailbox(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'medium'),
        ],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.callsFor('storyline_membership'), 3);
      // Filed as possible rather than proposed: three medium yeses are not a
      // storyline the app may put in front of someone as a suggestion, but the
      // group is still the one the namer kept, so it is filed with those
      // members for the owner to judge.
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(await store.membersOf(possible.id), hasLength(3));
      final hashes = (await db
              .customSelect(
                'SELECT cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(possible.id)],
              )
              .getSingle())
          .data;
      expect(hashes['cluster_hash'], isNotNull);
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);
    });

    test('and three high ones build the storyline of three', () async {
      await seedMailbox(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(await store.membersOf(storyline.id), hasLength(3));
    });

    test('a cluster the model rejects outright is never proposed twice',
        () async {
      await seedMailbox(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(belongs: false)],
      });
      final service = StorylineService(store, llm);

      await service.sweep();

      // Filed as possible: named, hashed over the whole cluster, and carrying
      // the members. It exists so the identical cluster — whose members stay
      // in the unassigned pool — cannot be re-judged for ever.
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(possible.createdBy, 'auto');
      expect(possible.title, 'Website redesign');
      expect(await store.membersOf(possible.id), isNotEmpty);
      final hashes = (await db
              .customSelect(
                'SELECT member_hash, cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(possible.id)],
              )
              .getSingle())
          .data;
      // Both: `cluster_hash` names the question the sweep asked, `member_hash`
      // describes who is stored here.
      expect(hashes['cluster_hash'], isNotNull);
      expect(hashes['member_hash'], isNotNull);
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      final first = (await store.loadStorylines()).single;

      // The drift: the user files a fourth thread into the suggestion by hand,
      // which rewrites `member_hash` over the bigger set. `cluster_hash` is
      // untouched — it names the trio the sweep actually built and asked
      // about.
      await service.addThread(first.id, 'email', 'c4');
      final hashes = (await db
              .customSelect(
                'SELECT member_hash, cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(first.id)],
              )
              .getSingle())
          .data;
      expect(hashes['member_hash'], isNot(hashes['cluster_hash']));

      await service.dismissSuggestion(first.id);

      // c1, c2 and c3 are free again and still the only threads close enough
      // to link — c4 sits at cosine 0 — so the identical cluster re-forms.
      // Only the cluster arm can recognise it: the member hash now describes
      // four threads, and no cluster will ever hash to that.
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
      final llm = fakeLlm({
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
      // Two distinct clusters: A (a1, a2, a3) around vectorAt(1), B (b1, b2,
      // b3) around vectorAt(-0.9). Three a side, because a pair is under
      // `proposeMinClusterSize`. A's rows are newer, so the deterministic
      // pass builds A first and stable sorting keeps it ranked first.
      await seed(store, 'a1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T06:00:00Z');
      await seed(store, 'a2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T05:00:00Z');
      await seed(store, 'a3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'b1',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'b2',
          vector: vectorAt(-0.95), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'b3',
          vector: vectorAt(-1), lastMessageAt: '2026-08-29T01:00:00Z');
      // Two unrelated pending suggestions squeeze the room down to one slot.
      for (var i = 0; i < 2; i++) {
        await store.insertStoryline(
          id: 'sl-pending-$i',
          title: 'Pending $i',
          status: 'suggested',
          createdBy: 'auto',
        );
      }
      final llm = fakeLlm({
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
          {'a1', 'a2', 'a3'});
      await service.dismissSuggestion(proposedA.id);

      // Sweep #2: A is ranked first again and its hash is dismissed. That
      // must not eat the slot — B, which the user has never seen, gets it.
      await service.sweep();

      final proposedB = (await store.loadStorylines(statuses: const ['suggested']))
          .where((s) => s.id.startsWith('sl-') && !s.id.startsWith('sl-pending'))
          .single;
      expect((await store.membersOf(proposedB.id)).map((m) => m.conversationKey).toSet(),
          {'b1', 'b2', 'b3'});
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
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), hasLength(3));
    });

    test('a sweep files no more possible rows than there is room for',
        () async {
      /// One thread's vector: a dimension shared with the rest of its cluster
      /// and a dimension all its own. Five clusters of three, every pair
      /// inside a cluster far above [StorylineTuning.clusterLinkThreshold] and
      /// every pair across two of them at zero, which two dimensions cannot
      /// express — a half circle has room for three groups that far apart and
      /// no more.
      List<double> clusterVector(int cluster, int member) => [
            for (var i = 0; i < 5; i++) i == cluster ? 1.0 : 0.0,
            for (var i = 0; i < 15; i++)
              i == cluster * 3 + member ? 0.3 : 0.0,
          ];

      for (var cluster = 0; cluster < 5; cluster++) {
        for (var member = 0; member < 3; member++) {
          await seed(store, 'k$cluster$member',
              vector: clusterVector(cluster, member),
              lastMessageAt: '2026-08-2${9 - cluster}T0${3 - member}:00:00Z');
        }
      }
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();

      // Three, not five. A filed possible storyline is an unanswered question
      // sitting in the rail with two buttons on it, exactly as a proposal is,
      // so it spends a slot of the same budget. Before this, a pass whose
      // namer declined everything walked every cluster it had built and handed
      // the owner a fold reading `Possible · 5`.
      expect(
        await store.loadStorylines(statuses: const ['possible']),
        hasLength(3),
      );
      expect(llm.callsFor('storyline_name'), 3);

      // And nothing at all while the rail is full: the room count stops the
      // pass before it reads a vector.
      await service.sweep();

      expect(llm.callsFor('storyline_name'), 3);

      // The fourth and the fifth are not lost. Nothing wrote their hashes, so
      // the pass rebuilds them every time, and the moment one question is
      // answered the next is asked — one, because one slot came free.
      final answered =
          (await store.loadStorylines(statuses: const ['possible'])).first;
      await service.dismissSuggestion(answered.id);

      await service.sweep();

      expect(llm.callsFor('storyline_name'), 4);
      expect(
        await store.loadStorylines(statuses: const ['possible']),
        hasLength(3),
      );
    });

    test('clustering is deterministic — same mailbox, same groups', () async {
      Future<Set<String>> clusterOf(BondDatabase into) async {
        final target = MessageStore(into);
        await seedMailbox(target);
        // The same script on both sides, so the only thing that could differ
        // between the two runs is the clustering itself.
        await StorylineService(
          target,
          fakeLlm({
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
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(),
          {'c1', 't1', 'c2'});
      // Each member carries the source it arrived through, so every later
      // read of the storyline — the episode list, a membership re-check —
      // goes to the right connector for it.
      expect(
        {for (final m in members) m.conversationKey: m.source},
        {'c1': 'email', 't1': 'teams', 'c2': 'email'},
      );
    });

    test('chats alone can be the seed of a storyline', () async {
      await seed(store, 't1',
          source: 'teams',
          vector: vectorAt(1),
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 't2',
          source: 'teams',
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 't3',
          source: 'teams',
          vector: vectorAt(0.9),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(),
          {'t1', 't2', 't3'});
      expect(members.every((m) => m.source == 'teams'), isTrue);
    });

    /// A chat and its two mail partners, plus a second trio with nothing to do
    /// with them. Whatever happens to the chat, the second trio is still there
    /// to be proposed — which is what makes "the chat was left out" an
    /// assertion about the chat rather than about the sweep's floor. Trios,
    /// because a pair is under `proposeMinClusterSize` and a group that loses
    /// the chat has to stay above it.
    Future<void> seedMixedMailbox(MessageStore into) async {
      await seed(into, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T08:00:00Z');
      await seed(into, 't1',
          source: 'teams',
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-29T07:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T06:00:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c4',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c5',
          vector: vectorAt(-0.95), lastMessageAt: '2026-08-29T01:30:00Z');
      await seed(into, 'c6',
          vector: vectorAt(-1), lastMessageAt: '2026-08-29T01:00:00Z');
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
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // t1 is spoken for, so c1 and c2 are a pair and under the propose
      // floor. The unrelated trio is what gets proposed instead.
      final proposed = (await store.loadStorylines(
        statuses: const ['suggested'],
      )).single;
      expect((await store.membersOf(proposed.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c4', 'c5', 'c6'});
    });

    test('a chat the user pulled out of a storyline is not swept back in',
        () async {
      await seedMixedMailbox(store);
      // Blocking without a membership to delete is how a removal records the
      // user's "no" — and the sweep must honour it for a chat exactly as it
      // does for a mail thread.
      await store.removeStorylineMember('sl-existing', 'teams', 't1',
          block: true);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final proposed = (await store.loadStorylines(
        statuses: const ['suggested'],
      )).single;
      expect((await store.membersOf(proposed.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c4', 'c5', 'c6'});
    });

    /// One key on two connectors, plus two more threads to group with
    /// whichever of them is still free. Normal, and not a collision to be avoided: the mail
    /// and chat connectors mint their keys with no knowledge of each other.
    Future<void> seedSharedKeyMailbox(MessageStore into) async {
      await seed(into, 'shared',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'shared',
          source: 'teams',
          vector: vectorAt(0.97),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T01:00:00Z');
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
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // Read as a bare key, "shared is taken" swallowed the chat as well and
      // left the pool a pair — under the propose floor, so nothing was ever
      // proposed.
      final proposed =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(
        {
          for (final m in await store.membersOf(proposed.id))
            m.conversationKey: m.source,
        },
        {'shared': 'teams', 'c2': 'email', 'c3': 'email'},
      );
    });

    test('a thread taken by one source is still available in the other',
        () async {
      await seedSharedKeyMailbox(store);
      // The block arm of the same confusion. The user's "no" was about the
      // chat, and it says nothing about the mail thread under that key.
      await store.removeStorylineMember('sl-existing', 'teams', 'shared',
          block: true);
      final llm = fakeLlm({
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
        {'shared': 'email', 'c2': 'email', 'c3': 'email'},
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
        clusterHash: cardHash('c1\nc2\nc3'),
      );
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // The sweep rebuilds exactly that trio, and stops on a hash nothing in
      // the app writes any more — before a single model call.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });
  });

  /// The subject pre-pass and the namer's two outs, which between them decide
  /// what the sweep asks about before a single confirm is spent.
  group('the series pre-pass and the namer that can decline', () {
    /// Runs a sweep with [llm] and returns what it wrote to the activity log.
    ///
    /// Empty when the pass was quiet: the log suppresses an all-zero row as
    /// the genuine nothing it is, so an empty map here IS an assertion.
    Future<Map<String, Object?>> sweepAndRecord(ScriptedLlm llm) async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await StorylineService(store, llm, activityLog: log).sweep();
      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');
      final rows = await store.recentActivity();
      if (rows.isEmpty) return const {};
      return ActivityEvent.fromRow(rows.single).detail;
    }

    /// The naming call's fenced body, split back into the cards the service
    /// numbered — so a test can say which thread the model was shown as `[2]`
    /// rather than guessing at the centrality order.
    List<String> namingCards(ScriptedLlm llm) =>
        fenceBody(llm.userMessages[llm.schemas.indexOf('storyline_name')],
                'threads')
            .trim()
            .split('\n---\n');

    test('three issues of one series seed a cluster with no cosine link at all',
        () async {
      // The pre-pass's whole reason for existing. A weekly digest somebody
      // takes part in is one effort to its owner and three unrelated points
      // to an embedding, so the vectors are put as far apart as two dimensions
      // allow and the group forms anyway — off the subject alone. Somebody has
      // replied in the first of them, which is what makes it an effort rather
      // than a feed.
      await seed(store, 'w1',
          subject: 'Weekly ops digest 2026-09-15',
          vector: vectorAt(1),
          messageCount: 3,
          inboundCount: 2,
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'w2',
          subject: 'Re: Weekly ops digest 2026-09-08',
          vector: vectorAt(0),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'w3',
          subject: 'Weekly ops digest 2026-09-01',
          vector: vectorAt(-1),
          lastMessageAt: '2026-08-29T02:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(title: 'Weekly ops digest')],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      final storyline = (await store.loadStorylines()).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'w1', 'w2', 'w3'});
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 3);
      expect(detail['series'], 1);
      expect(detail['series_excluded'], 0);
    });

    test('a notification-shaped series leaves the pool and costs no call',
        () async {
      // The shape the registry's anti-storylines describe, recognised without
      // the registry: three issues of one subject, nobody in the mailbox has
      // ever replied in any of them, and one address sent all three. Naming it
      // would write a charter that admits every future issue forever.
      for (final (index, key) in ['n1', 'n2', 'n3'].indexed) {
        await seed(store, key,
            subject: 'Vendor status report 2026-09-0${index + 1}',
            vector: vectorAt(1 - index * 0.02),
            messageCount: 2,
            inboundCount: 2,
            fromAddress: 'alerts@example.com',
            lastMessageAt: '2026-08-2${9 - index}T10:00:00Z');
      }
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
      // Noted rather than tombstoned: nothing was asked of any model, so there
      // is no answer to remember — and the row is written even though the pass
      // attempted no cluster, because leaving the pool IS something the pass
      // did.
      expect(detail['series_excluded'], 3);
      expect(detail['series'], 0);
      expect(detail['proposed'], 0);
    });

    test('a never-counted row is stale, not unanswered', () async {
      // Both counters default to zero, and `0 - 0 == 0` would read as "nobody
      // replied" on a conversation nothing has recomputed — while the pool
      // query has already proved every one of these holds a kept inbound
      // message. So zero inbound is stale rather than true, and the rule needs
      // a positive count before it will call a series a feed.
      Future<void> seedFeed(MessageStore into, {int? counted}) async {
        for (final (index, key) in ['s1', 's2', 's3'].indexed) {
          await seed(into, key,
              subject: 'Vendor status report 2026-09-0${index + 1}',
              vector: vectorAt(1 - index * 0.02),
              messageCount: counted,
              inboundCount: counted,
              fromAddress: 'alerts@example.com',
              lastMessageAt: '2026-08-2${9 - index}T10:00:00Z');
        }
      }

      await seedFeed(store);
      final unset = fakeLlm({
        'storyline_name': [nameAnswer(title: 'Vendor status reports')],
        'storyline_membership': [confirmAnswer()],
      });

      final unsetDetail = await sweepAndRecord(unset);

      expect(unsetDetail['series_excluded'], 0);
      expect(unsetDetail['series'], 1);
      expect(unset.callsFor('storyline_name'), 1);

      // The same three threads with the counters actually written are the feed
      // the rule is for.
      final counted = testDb();
      final countedStore = MessageStore(counted);
      addTearDown(counted.close);
      await seedFeed(countedStore, counted: 1);
      final log = ActivityLog(countedStore);
      addTearDown(log.dispose);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(countedStore, llm, activityLog: log).sweep();
      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      expect(llm.schemas, isEmpty);
      final rows = await countedStore.recentActivity();
      expect(ActivityEvent.fromRow(rows.single).detail['series_excluded'], 3);
    });

    test('two senders make a series an effort rather than a feed', () async {
      // Half the rule on its own. Nobody has replied in any of these, but they
      // did not all come from one place, so they are people writing to each
      // other on a recurring subject and the sweep asks about them.
      await seed(store, 'm1',
          subject: 'Site walkthrough notes 2026-09-15',
          vector: vectorAt(1),
          fromAddress: 'dana@example.com',
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'm2',
          subject: 'Site walkthrough notes 2026-09-08',
          vector: vectorAt(0),
          fromAddress: 'priya@example.com',
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'm3',
          subject: 'Site walkthrough notes 2026-09-01',
          vector: vectorAt(-1),
          fromAddress: 'dana@example.com',
          lastMessageAt: '2026-08-29T02:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(title: 'Site walkthroughs')],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      expect((await store.membersOf((await store.loadStorylines()).single.id))
          .map((m) => m.conversationKey)
          .toSet(), {'m1', 'm2', 'm3'});
      expect(detail['series'], 1);
      expect(detail['series_excluded'], 0);
    });

    /// Three threads about one thing, far enough from everything else to be
    /// the only cluster, with subjects that share no folded key.
    Future<void> seedTrio(MessageStore into) async {
      await into.upsertConversation({
        'source': 'email',
        'conversation_key': 'unused',
        'subject': 'Unused',
        'state': 'waiting',
      });
      await seed(into, 'q1',
          subject: 'Roof replacement quote',
          vector: vectorAt(1),
          lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'q2',
          subject: 'Roof replacement schedule',
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'q3',
          subject: 'Roof replacement permit',
          vector: vectorAt(0.9),
          lastMessageAt: '2026-08-29T02:00:00Z');
    }

    /// [seedTrio] plus a fourth thread in the same cluster, so a test can drop
    /// one outlier and still have three threads left to propose.
    Future<void> seedQuad(MessageStore into) async {
      await seedTrio(into);
      await seed(into, 'q4',
          subject: 'Roof replacement gutters',
          vector: vectorAt(0.85),
          lastMessageAt: '2026-08-29T01:00:00Z');
    }

    test('coherent false naming no outlier at all files the cluster as possible',
        () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      // An EMPTY outlier list is what makes this a refusal rather than a
      // correction. The live model says false whenever any thread does not
      // belong and then names which ones, so a false that keeps a group is
      // proposed; a false that names no group to keep is the model declining,
      // and there is nothing here to confirm against a charter written from
      // this same pile.
      //
      // Not one membership call.
      expect(llm.callsFor('storyline_membership'), 0);
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);
      // Declined, not thrown away: the whole cluster is filed for the owner to
      // look at, with its members, because the model refusing is not the owner
      // refusing.
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(
        (await store.membersOf(possible.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {'q1', 'q2', 'q3'},
      );
      expect(detail['incoherent'], 1);
      expect(detail['proposed'], 0);

      // Both hashes: `member_hash` over what was filed, and `cluster_hash`
      // over the group the sweep built, so the same three threads cost nothing
      // at all next pass.
      final hashes = (await db
              .customSelect(
                  'SELECT member_hash, cluster_hash FROM storylines '
                  'WHERE id = ?',
                  variables: [Variable(possible.id)])
              .getSingle())
          .data;
      expect(hashes['cluster_hash'], memberHashOf(['q1', 'q2', 'q3']));
      expect(hashes['member_hash'], memberHashOf(['q1', 'q2', 'q3']));

      await StorylineService(store, llm).sweep();

      expect(llm.callsFor('storyline_name'), 1);
    });

    test('a possible storyline\'s threads stay in the pool', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // Filed, but not assigned: only `suggested` and `active` memberships
      // take a thread out of the sweep's pool, which is what leaves these
      // three free to be clustered into a group a person would recognise.
      expect(await store.assignedOrBlockedKeys('email'), isEmpty);

      // And the hash check is the only thing stopping a re-ask. The IDENTICAL
      // set is recognised; a set with one more thread in it is a different
      // question and IS asked.
      await seed(store, 'q4',
          subject: 'Roof replacement gutters',
          vector: vectorAt(0.85),
          lastMessageAt: '2026-08-29T01:00:00Z');
      await StorylineService(store, llm).sweep();

      expect(llm.callsFor('storyline_name'), 2);
    });

    test('keeping a possible storyline nobody touched activates it whole',
        () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);
      await service.sweep();
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;

      await service.keepSuggestion(possible.id);

      final kept =
          (await store.loadStorylines(statuses: const ['active'])).single;
      expect(kept.id, possible.id);
      expect(await store.membersOf(kept.id), hasLength(3));
      // The reconciliation the Keep runs found nothing to drop, so the hash
      // is the one the filing wrote.
      expect(kept.memberHash, memberHashOf(['q1', 'q2', 'q3']));
      // And now its threads are spoken for.
      expect(await store.assignedOrBlockedKeys('email'),
          {'q1', 'q2', 'q3'});
    });

    test(
        'keeping a possible storyline drops a thread a live storyline took '
        'meanwhile', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);
      await service.sweep();
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      // Exactly what the status is FOR: q1 never left the pool, so anything
      // may take it while this row waits for an answer. Here it is the owner
      // starting a storyline of their own around it.
      await service.createStoryline(
        'Roofing crew',
        source: 'email',
        conversationKey: 'q1',
      );

      await service.keepSuggestion(possible.id);

      // Kept, but never with a thread another live storyline already holds:
      // ONE THREAD, ONE LIVE STORYLINE.
      final kept = (await store.getStoryline(possible.id))!;
      expect(kept.status, 'active');
      expect(
        (await store.membersOf(possible.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {'q2', 'q3'},
      );
      // The hash describes what is STORED, so the next membership write and
      // the next sweep both read something true.
      expect(kept.memberHash, memberHashOf(['q2', 'q3']));
      expect(await store.storylineIdsFor('email', 'q1'), hasLength(1));
    });

    test(
        'keeping a possible storyline with one thread left dismisses it '
        'instead', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);
      await service.sweep();
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      await service.createStoryline(
        'Roofing crew',
        source: 'email',
        conversationKey: 'q1',
      );
      await service.createStoryline(
        'Permit office',
        source: 'email',
        conversationKey: 'q2',
      );

      await service.keepSuggestion(possible.id);

      // One thread is not a group. The group the owner said yes to is gone, so
      // the press lands as a tombstone rather than as a storyline of one — and
      // a tombstone keeps both hashes, so the sweep does not rebuild the
      // question it has already been asked.
      final kept = (await store.getStoryline(possible.id))!;
      expect(kept.status, 'dismissed');
      expect(
        (await store.membersOf(possible.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {'q3'},
      );
      expect(kept.memberHash, memberHashOf(['q3']));
      expect(
        await store.dismissedHashExistsAny([memberHashOf(['q1', 'q2', 'q3'])]),
        isTrue,
      );
    });

    test('dismissing a possible storyline leaves it restorable', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false)],
        'storyline_membership': [confirmAnswer()],
      });
      final service = StorylineService(store, llm);
      await service.sweep();
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;

      await service.dismissSuggestion(possible.id);

      // Members survive the dismissal, which is what puts the row in the
      // rail's Dismissed fold at all: that list shows rows with members only.
      expect(
        await store.loadStorylines(
          statuses: const ['dismissed'],
          withMembersOnly: true,
        ),
        hasLength(1),
      );
      expect(await store.membersOf(possible.id), hasLength(3));

      await service.restoreDismissed(possible.id);

      // Back as a SUGGESTION, not as a possible: the owner has been through it
      // by hand, so it is their question now rather than the model's refusal.
      expect(
        (await store.loadStorylines(statuses: const ['suggested'])).single.id,
        possible.id,
      );
    });

    test('an outlier is dropped and the rest are confirmed', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(outliers: [2])],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      // Which thread `[2]` was is the service's decision — the cards are
      // ordered by centrality — so the test reads the message it sent rather
      // than assuming an order.
      final second = namingCards(llm)[1];
      final outlier = ['q1', 'q2', 'q3'].singleWhere(
        (key) => second.contains(
          {
            'q1': 'Roof replacement quote',
            'q2': 'Roof replacement schedule',
            'q3': 'Roof replacement permit',
          }[key]!,
        ),
      );

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      final members = (await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet();
      expect(members, hasLength(2));
      expect(members, isNot(contains(outlier)));
      // Two confirms, not three: the outlier was never put to the confirm
      // stage at all.
      expect(llm.callsFor('storyline_membership'), 2);
      expect(detail['outliers'], 1);
      // Nothing was written for it and nothing blocks it, so it is back in the
      // pool for a group it does belong to.
      expect(await store.storylineIdsFor('email', outlier), isEmpty);
      expect(await store.assignedOrBlockedKeys('email'), isNot(contains(outlier)));
    });

    test('outliers that leave fewer than two threads read as a refusal',
        () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(outliers: [1, 2])],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      // The other way the model can name no group to keep: one thread left is
      // not a storyline, so the answer says the same thing the empty outlier
      // list said and costs the same nothing. Filed WHOLE, outliers included:
      // the namer declined the group it was shown, so the group it was shown
      // is what the owner gets to look at.
      expect(llm.callsFor('storyline_membership'), 0);
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(await store.membersOf(possible.id), hasLength(3));
      expect(detail['incoherent'], 1);
      expect(detail['outliers'], 0);
    });

    test('every thread an outlier is a refusal spelled as a list', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false, outliers: [1, 2, 3])],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      // Four of the eight golden clusters answered exactly this way. What it
      // keeps is nothing, so it is filed the same way the empty list is.
      expect(llm.callsFor('storyline_membership'), 0);
      expect((await store.loadStorylines(statuses: const ['possible'])),
          hasLength(1));
      expect(detail['incoherent'], 1);
      expect(detail['outliers'], 0);
    });

    test('coherent false that names outliers proposes what it kept', () async {
      // How the live 27B actually answers. Asked this prompt it says false
      // whenever ANY thread does not belong, lists those threads, and writes
      // its title and charter for the group that remains — which is what the
      // prompt tells it to do. Tombstoning on the boolean alone threw away
      // every cluster the sweep formed on the golden pool: eight of eight came
      // back false. So the kept group is proposed, and the per-member confirms
      // are the guard on it.
      await seedQuad(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(coherent: false, outliers: [4])],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      final fourth = namingCards(llm)[3];
      final outlier = ['q1', 'q2', 'q3', 'q4'].singleWhere(
        (key) => fourth.contains(
          {
            'q1': 'Roof replacement quote',
            'q2': 'Roof replacement schedule',
            'q3': 'Roof replacement permit',
            'q4': 'Roof replacement gutters',
          }[key]!,
        ),
      );

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      final members = (await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet();
      expect(members, hasLength(3));
      expect(members, isNot(contains(outlier)));
      expect(llm.callsFor('storyline_membership'), 3);
      expect(detail['outliers'], 1);
      expect(detail['incoherent'], 0);
      expect(detail['proposed'], 1);
    });

    test('a cluster the model could not name is filed as possible by the lint',
        () async {
      // `fallbackTitle` is 'Untitled storyline', and `untitled` is one of the
      // charter lint's placeholder words. That is not an accident to work
      // around: a proposal nobody could name is not one a person should be
      // asked about as a suggestion, so no confirm is spent on it. It is still
      // filed, with the rows the namer KEPT, because the group is real even
      // where the name is not.
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(title: '')],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 0);
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(
        (await store.membersOf(possible.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {'q1', 'q2', 'q3'},
      );
      // The members name it, not the task's fallback: a rail row reading
      // 'Untitled storyline' says nothing about what is in it, and these three
      // share no folded subject, so the newest one's wording wins.
      expect(possible.title, 'Roof replacement quote');
      expect(detail['lint'], 1);
      expect(detail['incoherent'], 0);
    });

    test('a placeholder charter is refused before the confirms', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [
          nameAnswer(
            title: 'Misc',
            charter: 'Various unrelated threads from this period.',
          ),
        ],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      // The confirm stage cannot refuse what the charter allows, so a charter
      // that allows everything has to be caught before it is asked about.
      expect(llm.callsFor('storyline_membership'), 0);
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      // The namer DID write a title here, so that is what the row is called.
      expect(possible.title, 'Misc');
      expect(detail['lint'], 1);
      expect(detail['incoherent'], 0);
    });

    test('a charter that is a class of message is refused too', () async {
      await seedTrio(store);
      final llm = fakeLlm({
        'storyline_name': [
          nameAnswer(
            title: 'Vendor mail',
            charter: 'All emails from the vendor.',
          ),
        ],
        'storyline_membership': [confirmAnswer()],
      });

      final detail = await sweepAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 0);
      expect(detail['lint'], 1);
    });

    test('the naming call reads twelve numbered whole cards', () async {
      // Fourteen threads at one point, so nothing but the cap and the card
      // budget decides what the model sees. The newest carries a 700-character
      // triage summary: the old prompt would have cut every card to eighty
      // characters to fit forty of them, and what this pins is the opposite —
      // whole cards, twelve of them, numbered so the outlier rule can point.
      for (var i = 1; i <= 14; i++) {
        final key = 'p$i';
        await seed(store, key,
            subject: 'Thread number ${spellDigits('$i')} about the roof',
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T${(24 - i).toString().padLeft(2, '0')}'
                ':00:00Z');
      }
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'long-p1',
        'conversation_key': 'p1',
        'direction': 'inbound',
        'received_at': '2026-08-29T23:30:00Z',
        'triage_status': 'triaged',
      });
      await db.customStatement(
        'UPDATE messages SET summary = ? WHERE source_message_id = ?',
        ['s' * 700, 'long-p1'],
      );
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final naming = llm.userMessages[llm.schemas.indexOf('storyline_name')];
      expect(naming, contains('[1] '));
      expect(naming, contains('[12] '));
      expect(naming, isNot(contains('[13] ')));
      final cards = namingCards(llm);
      expect(cards, hasLength(StorylineTuning.namingCards));
      // The long one is whole up to the per-card cap, number included, rather
      // than a slice of every card.
      expect(cards.first.length, NameStorylineTask.cardCap);
      expect(fenceBody(naming, 'threads').length,
          lessThanOrEqualTo(NameStorylineTask.cardsCap));
    });

    test('the same mailbox swept twice asks the same question', () async {
      // Determinism is a hard dependency of the tombstone scheme: a cluster
      // that formed differently on a re-run would be a new question and would
      // re-spend a naming call plus its confirms, for ever. The series seeds
      // and the centrality ordering are both new sources of order, so the
      // property is re-pinned over a mailbox that carries both.
      Future<({List<String> members, List<String> naming})> run() async {
        final d = testDb();
        final s = MessageStore(d);
        addTearDown(d.close);
        await seed(s, 'w1',
            subject: 'Weekly ops digest 2026-09-15',
            vector: vectorAt(1),
            messageCount: 3,
            inboundCount: 2,
            lastMessageAt: '2026-08-29T06:00:00Z');
        await seed(s, 'w2',
            subject: 'Weekly ops digest 2026-09-08',
            vector: vectorAt(0),
            messageCount: 3,
            inboundCount: 2,
            lastMessageAt: '2026-08-29T05:00:00Z');
        await seed(s, 'w3',
            subject: 'Weekly ops digest 2026-09-01',
            vector: vectorAt(-1),
            messageCount: 3,
            inboundCount: 2,
            lastMessageAt: '2026-08-29T04:00:00Z');
        await seedTrio(s);
        final llm = fakeLlm({
          'storyline_name': [
            nameAnswer(title: 'The digest'),
            nameAnswer(title: 'The roof'),
          ],
          'storyline_membership': [confirmAnswer()],
        });

        await StorylineService(s, llm).sweep();

        final members = <String>[];
        for (final storyline in await s.loadStorylines()) {
          final keys = [
            for (final m in await s.membersOf(storyline.id)) m.conversationKey,
          ]..sort();
          members.add('${storyline.title}: ${keys.join(',')}');
        }
        return (
          members: members..sort(),
          naming: [
            for (var i = 0; i < llm.schemas.length; i++)
              if (llm.schemas[i] == 'storyline_name') llm.userMessages[i],
          ],
        );
      }

      final first = await run();
      final second = await run();

      expect(first.members, second.members);
      expect(first.naming, second.naming);
      // Not only the same answer twice but the RIGHT one: the series is
      // proposed before the cosine cluster, which is the order `room` is
      // spent in, and the cosine cluster's members are the trio's keys mapped
      // back from the sub-pool the clustering saw. A wrong remap would file
      // the wrong threads identically on both runs and pass the two
      // comparisons above.
      expect(first.members, ['The digest: w1,w2,w3', 'The roof: q1,q2,q3']);
    });
  });

  group('sweep probe (join, not seed)', () {
    /// The same five unassigned threads the sweep group clusters: c1, c2 and
    /// c3 are a clique, c4 and c5 link to nothing.
    Future<void> seedMailbox(MessageStore into) async {
      await seed(into, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(into, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(into, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(into, 'c4',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(into, 'c5',
          vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
    }

    /// One finished thread, seeded `done` from the start — never marked done
    /// afterwards, which is the call an old test in the sweep group forgets to
    /// await.
    Future<void> seedDone(
      MessageStore into,
      String key, {
      required List<double> vector,
      String lastMessageAt = '2026-08-29T05:00:00Z',
    }) =>
        seed(into, key,
            vector: vector, state: 'done', lastMessageAt: lastMessageAt);

    test('a finished thread near a newborn storyline joins it', () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      // Three cluster members first, in the order the sweep reads the rows,
      // and then the one probe candidate.
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(evidence: 'c1 is the homepage copy review.'),
          confirmAnswer(evidence: 'c2 is the same review, continued.'),
          confirmAnswer(evidence: 'c3 is the launch date thread.'),
          confirmAnswer(evidence: 'd1 is where the redesign was agreed.'),
        ],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(),
          {'c1', 'c2', 'c3', 'd1'});
      final joinedMember = members.firstWhere((m) => m.conversationKey == 'd1');
      expect(joinedMember.addedBy, 'auto');
      // The model's own sentence about the finished thread, not the cluster's.
      expect(joinedMember.evidence, 'd1 is where the redesign was agreed.');
      // Three members plus the one candidate the probe put in front of it.
      expect(llm.callsFor('storyline_membership'), 4);
      // d1 is the newest thread in the group, so the activity stamp follows
      // it exactly as it follows any other member that joins.
      expect(storyline.lastActivityAt, '2026-08-29T05:00:00Z');
    });

    test('a finished thread far from the cluster is never offered', () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2', 'c3'});
      // Under the gate, so the model never hears about it at all — the
      // embedding is what decides what gets a call.
      expect(llm.callsFor('storyline_membership'), 3);
    });

    test('a yes the model is not confident about keeps the thread out',
        () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(confidence: 'low'),
        ],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2', 'c3'});
      // It WAS asked — the same `low is a no` rule every other membership path
      // applies, not a gate that kept it away.
      expect(llm.callsFor('storyline_membership'), 4);
    });

    test('a medium yes keeps the finished thread out too', () async {
      // The probe judges against the same unsaved `suggested` proposal the
      // cluster members were judged against, so it is held to the same bar.
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(confidence: 'medium'),
        ],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2', 'c3'});
      // Asked, and turned down on the answer.
      expect(llm.callsFor('storyline_membership'), 4);
    });

    test('a probe join burns no refresh and rewrites no cluster hash',
        () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      // Born described, and the probe must not undo that: both hashes are
      // recomputed over the final set of four, so the description written
      // seconds ago is not re-derived by a 27B call for nothing.
      expect(storyline.memberHash, memberHashOf(['c1', 'c2', 'c3', 'd1']));
      expect(storyline.refreshedMemberHash, storyline.memberHash);
      expect(storyline.refreshedMemberCount, 4);
      expect(await store.staleRefreshStorylineIds(), isEmpty);
      // The cluster is still the trio the sweep built and the user is being
      // asked about. The probe answered a different question.
      final clusterHash = (await db
              .customSelect(
                'SELECT cluster_hash FROM storylines WHERE id = ?',
                variables: [Variable(storyline.id)],
              )
              .getSingle())
          .data['cluster_hash'];
      expect(clusterHash, memberHashOf(['c1', 'c2', 'c3']));
    });

    test('a finished thread already spoken for is never offered', () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      // Active rather than suggested, so it consumes no room in the rail —
      // what it consumes is d1, which the taken-set check reads before the
      // done divert ever runs.
      await store.insertStoryline(
        id: 'sl-existing',
        title: 'Existing',
        status: 'active',
        createdBy: 'user',
      );
      await store.addStorylineMember('sl-existing', 'email', 'd1',
          addedBy: 'user');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect((await store.membersOf(storyline.id))
          .map((m) => m.conversationKey)
          .toSet(), {'c1', 'c2', 'c3'});
      expect(llm.callsFor('storyline_membership'), 3);
    });

    test('the probe stops at the recruit cap however many are near', () async {
      await seedMailbox(store);
      // Ten identical finished threads: same vector, so the same score, and
      // the tie is broken by the order the store hands them over — newest
      // first, which is d10 down to d01.
      for (var i = 1; i <= 10; i++) {
        await seedDone(
          store,
          'd${i.toString().padLeft(2, '0')}',
          vector: vectorAt(0.95),
          lastMessageAt: '2026-08-28T10:${i.toString().padLeft(2, '0')}:00Z',
        );
      }
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // Three cluster members and eight candidates — never all ten. A newborn
      // storyline is not an excuse to spend a confirmation on every finished
      // thread in the mailbox.
      expect(llm.callsFor('storyline_membership'),
          3 + StorylineTuning.recruitMaxCandidates);
      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(
        (await store.membersOf(storyline.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {
          'c1',
          'c2',
          'c3',
          'd10',
          'd09',
          'd08',
          'd07',
          'd06',
          'd05',
          'd04',
          'd03',
        },
      );
    });

    test('a cluster the model threw out probes nothing', () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(belongs: false)],
      });

      await StorylineService(store, llm).sweep();

      // Every member rejected, so the cluster is filed as possible. A group
      // nobody has vouched for must not go recruiting history to make itself
      // big enough to ship — d1 is never asked, and it is not among the
      // members either.
      expect(llm.callsFor('storyline_membership'), 3);
      final possible =
          (await store.loadStorylines(statuses: const ['possible'])).single;
      expect(
        (await store.membersOf(possible.id))
            .map((m) => m.conversationKey)
            .toSet(),
        isNot(contains('d1')),
      );
      expect(await store.loadStorylines(statuses: const ['suggested']),
          isEmpty);
    });

    test('a server that parks mid-probe leaves the hashes telling the truth',
        () async {
      await seedMailbox(store);
      // Two candidates over the gate, scored apart so the order is theirs:
      // d1 first, then the park lands on d2.
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      await seedDone(store, 'd2',
          vector: vectorAt(0.8), lastMessageAt: '2026-08-29T04:30:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(),
          const LlmUnavailableException('server off'),
        ],
      });

      await expectLater(
        StorylineService(store, llm).sweep(),
        throwsA(isA<LlmUnavailableException>()),
      );

      // The join that landed stays, exactly as recruit keeps what already
      // landed — and because the hash write shares its breath, the columns
      // describe the set of four that actually exists, not the seed trio.
      // Equal columns means no 27B refresh is spent on the interruption.
      final storyline =
          (await store.loadStorylines(statuses: const ['suggested'])).single;
      expect(
        (await store.membersOf(storyline.id))
            .map((m) => m.conversationKey)
            .toSet(),
        {'c1', 'c2', 'c3', 'd1'},
      );
      expect(storyline.memberHash, memberHashOf(['c1', 'c2', 'c3', 'd1']));
      expect(storyline.refreshedMemberHash, storyline.memberHash);
      expect(storyline.refreshedMemberCount, 4);
      expect(await store.staleRefreshStorylineIds(), isEmpty);
    });

    test('the first recap already reads the thread the probe joined', () async {
      await seedMailbox(store);
      await seedDone(store, 'd1', vector: vectorAt(0.95));
      await seedMessage(store, 'c1', 'm-c1',
          receivedAt: '2026-08-29T04:00:00Z');
      await seedMessage(store, 'c2', 'm-c2',
          receivedAt: '2026-08-29T03:00:00Z');
      await seedMessage(store, 'd1', 'm-d1',
          receivedAt: '2026-08-29T05:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
        'storyline_recap': [recapAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();
      expect(await drainRecap(service), isNotNull);

      // The probe runs before `_propose` returns, so the recap row the birth
      // queued — drained in this same pass — sees the joined thread. Deferring
      // the probe would have the storyline's very first recap describe a group
      // it is no longer.
      final recap = llm.userMessages[llm.schemas.indexOf('storyline_recap')];
      expect(recap, contains('Subject for d one'));
    });

    test('a finished thread joins at most one storyline per pass', () async {
      // Two clusters that do not link to each other — the b-trio sits about
      // 84° off the c-trio, well under `clusterLinkThreshold` — with one
      // finished thread parked between them, over the probe's gate against
      // both centroids. Three threads a side, because a cosine pair is under
      // `proposeMinClusterSize` and would never be named. The gap is wider
      // than it was: `clusterLinkThreshold` came down to 0.48 with the Qwen
      // vector, and at 70° apart the nearest cross pair sat at 0.58 and
      // welded the two trios into one.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T06:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.97), lastMessageAt: '2026-08-29T05:00:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'b1',
          vector: vectorAt(0.10), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'b2',
          vector: vectorAt(0.05), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed(store, 'b3',
          vector: vectorAt(0), lastMessageAt: '2026-08-29T01:00:00Z');
      await seedDone(store, 'd1', vector: vectorAt(0.73));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(), nameAnswer(title: 'Vendor invoices')],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final byMembers = {
        for (final storyline
            in await store.loadStorylines(statuses: const ['suggested']))
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(): storyline.id,
      };
      // The first proposal takes it; the second is never even offered it. The
      // sweep's own taken-set could not have known — that storyline did not
      // exist when the set was read — and no other automatic path lets one
      // thread sit in two storylines.
      expect(byMembers.keys, containsAll([
        {'c1', 'c2', 'c3', 'd1'},
        {'b1', 'b2', 'b3'},
      ]));
      // Three members each, plus the one probe candidate the first proposal
      // was offered. The second proposal's probe had nothing left to ask
      // about.
      expect(llm.callsFor('storyline_membership'), 7);
    });

    test('the probe never widens the pool a cluster is formed from', () async {
      // Two finished threads that sit right on top of each other and nothing
      // else. They would cluster happily if they were candidates — the whole
      // point is that they are not, so the pass has nothing to be born and
      // never reaches the model at all.
      await seedDone(store, 'd1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T05:00:00Z');
      await seedDone(store, 'd2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T04:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });
  });

  group('user actions', () {
    test('creating a storyline locks its title and files the thread', () async {
      await seed(store, 'c1', lastMessageAt: '2026-08-29T10:00:00Z');
      final service =
          StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

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

    test('restoring a dismissed storyline asks the question again', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        status: 'suggested',
        createdBy: 'auto',
        memberHash: 'h1',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      final service = StorylineService(store, fakeLlm(const {}));

      await service.dismissSuggestion('sl-1');
      await service.restoreDismissed('sl-1');

      final restored = (await store.getStoryline('sl-1'))!;
      expect(restored.status, 'suggested');
      expect(restored.summary, 'The studio is reviewing the homepage copy.');
      expect(await store.membersOf('sl-1'), hasLength(1));
      // The tombstone reads `status = 'dismissed'`, so a restore lifts the
      // block on ever proposing this member set again.
      expect(await store.dismissedHashExistsAny(['h1']), isFalse);
    });

    test('renaming locks the title', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Untitled storyline',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

      await service.removeThread('sl-1', 'email', 'c1');

      expect(await store.membersOf('sl-1'), isEmpty);
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test("a removal keeps the model's reason and queues the re-check",
        () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1',
          addedBy: 'auto', evidence: 'Both concern the website redesign.');
      final service = StorylineService(store, fakeLlm(const {}));

      await service.removeThread('sl-1', 'email', 'c1');

      // The owner's own "no", carrying what the model thought when it filed
      // the thread — which is what makes the negative example say something.
      final block = (await store.blocksOf('sl-1')).single;
      expect(block.blockedBy, 'user');
      expect(block.evidence, 'Both concern the website redesign.');
      // Both rows: the refresh may narrow the charter, and the audit re-judges
      // the rest of the group against whatever it narrowed to. The handler
      // order is what makes them run in that sequence.
      expect((await store.nextPendingWork('storyline_refresh'))?['entity_id'],
          'sl-1');
      expect((await store.nextPendingWork('storyline_audit'))?['entity_id'],
          'sl-1');
    });

    test('a hand-filed thread records that the owner filed it', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, fakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      // Not decoration: the confirm prompt reads this membership back as an
      // example, and a removal copies the evidence onto the block.
      final member = (await store.membersOf('sl-1')).single;
      expect(member.addedBy, 'user');
      expect(member.evidence, 'Filed by you');
    });

    test('unblocking lifts the veto and files nothing back', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'keep', addedBy: 'auto');
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service =
          StorylineService(store, fakeLlm(const {}), activityLog: log);

      await service.unblockThread('sl-1', 'email', 'c1');

      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      // NOT re-filed: the owner withdrew a veto, they did not make a
      // membership. Whether it belongs is the model's question again.
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['keep']);
      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.kind, 'storyline_unblock');
      expect(row.detail['storyline_id'], 'sl-1');
      // Nothing to re-describe and nothing new to recap: the storyline is
      // exactly as it was a moment ago.
      for (final kind in const [
        'storyline_refresh',
        'storyline_audit',
        'storyline_recap',
      ]) {
        expect(await store.nextPendingWork(kind), isNull, reason: kind);
      }
    });

    test("filing a thread back clears an audit's block too", () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.removeStorylineMember('sl-1', 'email', 'c1',
          block: true, blockedBy: 'audit', evidence: 'A different launch.');
      final service = StorylineService(store, fakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      // A block is a block whoever wrote it: the owner filing the thread by
      // hand is the last word, and leaving the row would have the next
      // assignment pass refuse a membership a person just asked for.
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      expect(await store.blocksOf('sl-1'), isEmpty);
      expect((await store.membersOf('sl-1')).single.addedBy, 'user');
    });

    test('adding a thread back un-blocks it', () async {
      await seed(store, 'c1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, fakeLlm(const {}));
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
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

      await service.addThread('sl-1', 'email', 'c1');

      expect((await store.getStoryline('sl-1'))!.status, 'active');
    });
  });

  /// What the owner's own corrections teach the model, and the pass that
  /// applies the lesson to the memberships already sitting in the storyline.
  ///
  /// Until this existed a removal taught nothing: the block kept the thread
  /// out of that one storyline and never reached a prompt, so the reasoning
  /// that filed it went on filing its siblings.
  group('the owner teaches the prompt', () {
    /// A storyline the owner has corrected once each way: one thread filed by
    /// hand, one taken out. Returns nothing — the fixture is the database.
    Future<StorylineService> taught(ScriptedLlm llm) async {
      await seedStoryline(store);
      await seed(store, 'k1');
      await seed(store, 'r1');
      final service = StorylineService(store, llm);
      await service.addThread('sl-1', 'email', 'k1');
      await service.addThread('sl-1', 'email', 'r1');
      await service.removeThread('sl-1', 'email', 'r1');
      return service;
    }

    test('an assignment is judged against what the owner filed and removed',
        () async {
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = await taught(llm);
      await seed(store, 'c1', vector: vectorAt(0.8));

      await service.assignConversation('email', 'c1');

      final user = llm.userMessages.single;
      expect(fenceBody(user.split('"removed_by_owner"').first, 'kept_by_owner'),
          contains('Subject for k one'));
      expect(
        fenceBody(user.split('"candidate_thread"').first, 'removed_by_owner'),
        contains('Subject for r one'),
      );
      // The candidate goes last, so the examples are a cacheable prefix.
      expect(user.indexOf('"removed_by_owner"'),
          lessThan(user.indexOf('"candidate_thread"')));
    });

    test('a proposal has nobody to learn from, and says so', () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.95));
      await seed(store, 'c3', vector: vectorAt(0.9));
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final confirms = [
        for (var i = 0; i < llm.schemas.length; i++)
          if (llm.schemas[i] == 'storyline_membership') llm.userMessages[i],
      ];
      expect(confirms, isNotEmpty);
      for (final user in confirms) {
        // The proposal is not in the database yet: it has no user members and
        // no blocks by construction, so both fences are honestly empty.
        expect(
          fenceBody(user.split('"removed_by_owner"').first, 'kept_by_owner'),
          contains('(none)'),
        );
        expect(
          fenceBody(user.split('"candidate_thread"').first, 'removed_by_owner'),
          contains('(none)'),
        );
      }
    });

    test('a recruit lap carries the same lesson to every candidate', () async {
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = await taught(llm);
      await seed(store, 'c1', vector: vectorAt(0.8));
      await seed(store, 'c2', vector: vectorAt(0.7));

      await service.recruit('sl-1');

      // Two candidates over the gate, and the examples on both prompts —
      // fetched once per lap, not once per candidate, but that is a cost the
      // prompt cannot show; what it can show is that neither call went out
      // without the owner's word on it.
      expect(llm.callsFor('storyline_membership'), 2);
      for (final user in llm.userMessages) {
        expect(
          fenceBody(user.split('"removed_by_owner"').first, 'kept_by_owner'),
          contains('Subject for k one'),
        );
        expect(
          fenceBody(user.split('"candidate_thread"').first, 'removed_by_owner'),
          contains('Subject for r one'),
        );
      }
    });

    test('a block whose thread is gone teaches nothing rather than a blank',
        () async {
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = await taught(llm);
      // The block outlives the conversation row it was written about; an
      // example nothing can be said about is left out, not rendered empty.
      await db.customStatement(
        "DELETE FROM conversations WHERE conversation_key = 'r1'",
      );
      await seed(store, 'c1', vector: vectorAt(0.8));

      await service.assignConversation('email', 'c1');

      final removed = fenceBody(
        llm.userMessages.single.split('"candidate_thread"').first,
        'removed_by_owner',
      );
      expect(removed, contains('(none)'));
      expect(removed, isNot(contains('r1')));
    });

    test('gone threads do not crowd out the lessons that remain', () async {
      // Three of the four removals are threads the app no longer stores, and
      // they are the newest three. Counting to three BEFORE the gone-thread
      // filter would spend the whole example budget on them and teach the
      // model nothing at all.
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = await taught(llm);
      for (final key in const ['r2', 'r3', 'r4']) {
        await seed(store, key);
        await service.addThread('sl-1', 'email', key);
        await service.removeThread('sl-1', 'email', key);
        await db.customUpdate(
          'UPDATE storyline_member_blocks SET blocked_at = ? '
          'WHERE storyline_id = ? AND conversation_key = ?',
          variables: [
            Variable('2026-09-0${key.substring(1)}T00:00:00Z'),
            Variable('sl-1'),
            Variable(key),
          ],
        );
        await db.customStatement(
          "DELETE FROM conversations WHERE conversation_key = '$key'",
        );
      }
      await db.customUpdate(
        'UPDATE storyline_member_blocks SET blocked_at = ? '
        "WHERE storyline_id = ? AND conversation_key = 'r1'",
        variables: [Variable('2026-09-01T00:00:00Z'), Variable('sl-1')],
      );
      await seed(store, 'c1', vector: vectorAt(0.8));

      await service.assignConversation('email', 'c1');

      final removed = fenceBody(
        llm.userMessages.single.split('"candidate_thread"').first,
        'removed_by_owner',
      );
      expect(removed, contains('Subject for r one'));
    });

    test('a removal is what lets the refresh narrow an unlocked charter',
        () async {
      const narrowed = 'The redesign of the Northline Studio website — the '
          'homepage copy, the new photography, and the launch date. Payroll '
          'and other back-office mail does not belong.';
      final llm = fakeLlm({
        'storyline_refresh': [refineAnswer(charter: narrowed)],
      });
      final service = await taught(llm);

      expect(await drainRefresh(service), 'sl-1');

      final user = llm.userMessages.single;
      expect(fenceBody(user.split('"new_threads"').first, 'removed_threads'),
          contains('Subject for r one'));
      // The charter is the model's own text, so the model may narrow it.
      expect((await store.getStoryline('sl-1'))!.charter, narrowed);
    });

    test('and a locked one only ever gets the offer', () async {
      const narrowed = 'The website redesign. Payroll mail does not belong.';
      final llm = fakeLlm({
        'storyline_refresh': [refineAnswer(charter: narrowed)],
      });
      final service = await taught(llm);
      await store.updateStoryline('sl-1', charterLocked: true);

      expect(await drainRefresh(service), 'sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charterSuggestion, narrowed);
      expect(storyline.charter, isNot(narrowed));
    });

    /// A storyline holding two automatic members and one the owner filed,
    /// with the membership order pinned so a positional script is reading the
    /// members it means.
    Future<void> seedMixed({String? memberHash}) async {
      await seedStoryline(store, memberKey: 'a1');
      await seed(store, 'a2', vector: vectorAt(0.9));
      await store.addStorylineMember('sl-1', 'email', 'a2',
          addedBy: 'auto', evidence: 'Both concern the website redesign.');
      await seed(store, 'u1');
      await store.addStorylineMember('sl-1', 'email', 'u1',
          addedBy: 'user', evidence: 'Filed by you');
      await memberAddedAt('sl-1', 'a1', '2026-08-01T00:00:00Z');
      await memberAddedAt('sl-1', 'a2', '2026-08-02T00:00:00Z');
      await memberAddedAt('sl-1', 'u1', '2026-08-03T00:00:00Z');
      await store.updateStoryline(
        'sl-1',
        memberHash: memberHash ?? memberHashOf(['a1', 'a2', 'u1']),
      );
    }

    test('the audit re-judges what the model filed and nothing the owner did',
        () async {
      await seedMixed();
      await seedMessage(store, 'a2', 'm-a2');
      await store.stampStorylineId('email', 'a2', storylineId: 'sl-1');
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(
            belongs: false,
            evidence: 'A different launch entirely.',
          ),
        ],
      });
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service =
          StorylineService(store, llm, activityLog: log);

      await service.audit('sl-1');
      // The audit notes onto the worker's row, as the recruit does; this is
      // the record the worker would write at the end of the item.
      await log.record('storyline_audit', source: 'email', entityId: 'sl-1');

      // Two calls, not three: the owner's own membership is the owner's word
      // and is never put to a model.
      expect(llm.callsFor('storyline_membership'), 2);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a1', 'u1']);
      // Blocked, and blocked as the audit's own doing — the recruit runs after
      // this handler and would file an unblocked removal straight back.
      final block = (await store.blocksOf('sl-1')).single;
      expect(block.conversationKey, 'a2');
      expect(block.blockedBy, 'audit');
      expect(block.evidence, 'A different launch entirely.');
      // The row a person reads, naming what went.
      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.kind, 'storyline_audit');
      expect(row.detail['checked'], 2);
      expect(
        (row.detail['removed'] as List).single,
        containsPair('subject', 'Subject for a two'),
      );
      // The hash follows the members, and the pointer follows the hash: a
      // removed thread must not still look filed on the home feed.
      expect((await store.getStoryline('sl-1'))!.memberHash,
          memberHashOf(['a1', 'u1']));
      expect(await pointerOf('m-a2'), isNull);
      // Both passes follow the members: the title, summary and charter
      // describe a group that just got smaller, and so does the recap.
      expect((await store.nextPendingWork('storyline_refresh'))?['entity_id'],
          'sl-1');
      expect((await store.nextPendingWork('storyline_recap'))?['entity_id'],
          'sl-1');
    });

    test('the audit keeps a medium member of a storyline the owner kept',
        () async {
      // `active` means the owner looked at this group and kept it, and a
      // medium yes has always been enough to stay in one.
      await seedMixed();
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'medium'),
        ],
      });

      await StorylineService(store, llm).audit('sl-1');

      expect(llm.callsFor('storyline_membership'), 2);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a1', 'a2', 'u1']);
      expect(await store.blocksOf('sl-1'), isEmpty);
    });

    test('and removes one from a group nobody has kept yet', () async {
      // The same two answers against a `suggested` row: the bar is `high`
      // there, so both automatic members go and both go blocked, as the
      // audit's removals always do.
      await seedMixed();
      await store.updateStoryline('sl-1', status: 'suggested');
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(confidence: 'medium'),
          confirmAnswer(confidence: 'medium'),
        ],
      });

      await StorylineService(store, llm).audit('sl-1');

      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['u1']);
      final blocks = await store.blocksOf('sl-1');
      expect(blocks.map((b) => b.conversationKey).toSet(), {'a1', 'a2'});
      expect(blocks.every((b) => b.blockedBy == 'audit'), isTrue);
    });

    test('an audit removal clears the recap too', () async {
      await seedMixed();
      await store.updateStoryline('sl-1',
          recapText: 'The a2 thread is where the launch date came from.',
          recapThrough: '2026-08-03T00:00:00Z');
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(belongs: false, evidence: 'no'),
        ],
      });

      await StorylineService(store, llm).audit('sl-1');

      // The re-check is a removal like the owner's own, and the recap it
      // queues has to be written from the members that are left: the stored
      // paragraph was derived from a2 as much as from anything else, and no
      // rewrite carrying it forward could tell which half to drop.
      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.recapText, isNull);
      expect(storyline.recapThrough, isNull);
    });

    test('and the recruit cannot put back what the audit took out', () async {
      await seedMixed();
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(belongs: false, evidence: 'A different launch.'),
        ],
      });
      final service = StorylineService(store, llm);
      await service.audit('sl-1');

      await service.recruit('sl-1');

      // a2 sits at cosine 0.9 against the centroid and would top the ranking,
      // so the block is the only thing keeping it out — and the model is never
      // asked a third question.
      expect(llm.callsFor('storyline_membership'), 2);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a1', 'u1']);
    });

    test('a low-confidence yes is a no here too', () async {
      await seedMixed();
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(confidence: 'low', evidence: 'Could be either.'),
        ],
      });

      await StorylineService(store, llm).audit('sl-1');

      // The identical rule every other membership path applies: a group the
      // user has to correct costs more than one it never got offered.
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a1', 'u1']);
      expect((await store.blocksOf('sl-1')).single.conversationKey, 'a2');
    });

    test('an audit that removes nothing still says it checked', () async {
      await seedMixed(memberHash: 'h-before');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(store, llm, activityLog: log).audit('sl-1');
      await log.record('storyline_audit', source: 'email', entityId: 'sl-1');

      expect(llm.callsFor('storyline_membership'), 2);
      expect(await store.membersOf('sl-1'), hasLength(3));
      // The model was consulted and said keep, which is an answer: the row
      // shows with what it checked, and nothing removed.
      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.detail['checked'], 2);
      // Absent rather than empty: every value on a quiet kind's note has to be
      // a numeric zero for the row to stay out of the panel, and an empty list
      // is not one.
      expect(row.detail.containsKey('removed'), isFalse);
      // Idempotent: nothing moved, so nothing was stamped and nothing queued.
      expect((await store.getStoryline('sl-1'))!.memberHash, 'h-before');
      expect(await store.nextPendingWork('storyline_refresh'), isNull);
      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('an audit that reached no model says nothing', () async {
      // Every automatic member's conversation row is gone, so there is no card
      // to judge and no call to make. `checked` is then zero, every value on
      // the note is a zero, and the quiet kind keeps the row out of the panel.
      await seedMixed();
      for (final key in const ['a1', 'a2']) {
        await db.customUpdate(
          'DELETE FROM conversations WHERE source = ? AND conversation_key = ?',
          variables: [Variable('email'), Variable(key)],
        );
      }
      final llm = fakeLlm({'storyline_membership': const []});
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(store, llm, activityLog: log).audit('sl-1');
      await log.record('storyline_audit', source: 'email', entityId: 'sl-1');

      expect(llm.callsFor('storyline_membership'), 0);
      expect(await store.recentActivity(), isEmpty);
    });

    test('an unavailable server parks the audit and keeps what already landed',
        () async {
      await seedMixed();
      await seedMessage(store, 'a1', 'm-a1');
      await store.stampStorylineId('email', 'a1', storylineId: 'sl-1');
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(belongs: false, evidence: 'no'),
          const LlmUnavailableException('server off'),
        ],
      });

      await expectLater(
        StorylineService(store, llm).audit('sl-1'),
        throwsA(isA<LlmUnavailableException>()),
      );

      // The first removal is whole: the member is gone with its block, the
      // storyline's hash describes what is left, and the thread no longer
      // looks filed on the home feed. A park must not leave the storyline
      // describing members that are not there.
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a2', 'u1']);
      expect((await store.blocksOf('sl-1')).single.blockedBy, 'audit');
      expect((await store.getStoryline('sl-1'))!.memberHash,
          isNot(memberHashOf(['a1', 'a2', 'u1'])));
      expect(await pointerOf('m-a1'), isNull);
    });

    test("an audit's own block never comes back as the owner's lesson",
        () async {
      await seedMixed();
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(belongs: false, evidence: 'A different launch.'),
          confirmAnswer(),
        ],
      });
      final service = StorylineService(store, llm);
      await service.audit('sl-1');
      await seed(store, 'c9', vector: vectorAt(0.8));

      await service.assignConversation('email', 'c9');

      // The fence carries the OWNER's removals only. An audit rejection fed
      // back as an example would be the model teaching itself.
      final user = llm.userMessages.last;
      final removed =
          fenceBody(user.split('"candidate_thread"').first, 'removed_by_owner');
      expect(removed, contains('(none)'));
      expect(removed, isNot(contains('Subject for a two')));
    });

    test('an audit skips a storyline the user dismissed while it waited',
        () async {
      await seedMixed();
      await store.updateStoryline('sl-1', status: 'dismissed');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).audit('sl-1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(3));
    });

    test('a storyline the owner built by hand is never audited at all',
        () async {
      await seed(store, 'u1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'user',
      );
      await store.addStorylineMember('sl-1', 'email', 'u1', addedBy: 'user');
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).audit('sl-1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('the handler hands its row to the audit', () async {
      await seedMixed();
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(belongs: false, evidence: 'A different launch.'),
        ],
      });
      final handler = StorylineAuditHandler(StorylineService(store, llm));

      expect(handler.kind, 'storyline_audit');
      await handler.run({'entity_id': 'sl-1', 'source': 'email'});

      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['a1', 'u1']);
      // An empty id is a row nothing can be done about, and reaches no model.
      await handler.run({'entity_id': '', 'source': 'email'});
      expect(llm.callsFor('storyline_membership'), 2);
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
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));
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
        fakeLlm(const {}),
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
        fakeLlm({'storyline_membership': [confirmAnswer()]}),
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
        fakeLlm({'storyline_membership': [confirmAnswer()]}),
        activityLog: log,
      ).assignConversation('email', 'c1');

      await log.record('storyline', source: 'email', entityId: 'c1');

      expect(await store.recentActivity(), isEmpty);
    });

    /// Runs a sweep with [llm] and returns the recorded activity detail.
    Future<Map<String, Object?>> sweepAndRecord(ScriptedLlm llm) async {
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
      await seed(store, 'c2', vector: vectorAt(0.95));
      await seed(store, 'c3', vector: vectorAt(0.9));
      await seed(store, 'c4', vector: vectorAt(0));
      await seed(store, 'c5', vector: vectorAt(-0.9));

      final detail = await sweepAndRecord(fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      }));

      expect(detail['proposed'], 1);
      // Threads, not clusters: the proposal held all three members of the one
      // cluster and the model turned nothing away.
      expect(detail['confirmed'], 3);
      expect(detail['rejected'], 0);
    });

    test('a sweep that proposed nothing still reports what it turned away',
        () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.95));
      await seed(store, 'c3', vector: vectorAt(0.9));
      await seed(store, 'c4', vector: vectorAt(0));
      await seed(store, 'c5', vector: vectorAt(-0.9));

      final detail = await sweepAndRecord(fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer(belongs: false)],
      }));

      // The recruit precedent: consulted and said no is an answer, and the
      // rejections are what keep the row out of the quiet-kind check.
      expect(detail['proposed'], 0);
      expect(detail['confirmed'], 0);
      expect(detail['rejected'], 3);
    });

    test('a sweep whose every cluster was already dismissed stays quiet',
        () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.95));
      await seed(store, 'c3', vector: vectorAt(0.9));
      await seed(store, 'c4', vector: vectorAt(0));
      await seed(store, 'c5', vector: vectorAt(-0.9));
      final llm = fakeLlm({
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

    test('a sweep counts what its probe joined, apart from what it confirmed',
        () async {
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.97), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed(store, 'd1',
          vector: vectorAt(0.95),
          state: 'done',
          lastMessageAt: '2026-08-29T05:00:00Z');

      final detail = await sweepAndRecord(fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      }));

      expect(detail['proposed'], 1);
      // Three, not four: `confirmed` is the cluster's own members being
      // judged, and the finished thread was never in the cluster.
      expect(detail['confirmed'], 3);
      expect(detail['rejected'], 0);
      expect(detail['joined'], 1);
      // A number, always — the log's quiet-kind check only understands those,
      // and a null or a string here would make every all-zero sweep loud.
      expect(detail['joined'], isA<int>());
    });

    test('a sweep with no finished thread to offer notes a numeric zero',
        () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.95));
      await seed(store, 'c3', vector: vectorAt(0.9));

      final detail = await sweepAndRecord(fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      }));

      expect(detail['joined'], 0);
    });

    test('a sweep with nothing to cluster writes no row at all', () async {
      // Under the unassigned floor, so no cluster ever reaches the model and
      // there is not even a tally to be zero about.
      await seed(store, 'c1', vector: vectorAt(1));

      final detail = await sweepAndRecord(fakeLlm({
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
      ScriptedLlm llm, {
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 1);
      final joined = (await store.membersOf('sl-1')).last;
      expect(joined.conversationKey, 't1');
      expect(joined.source, 'teams');
      expect(detail['recruited'], 1);
    });

    test('the gate is the LOWER one even with nobody in common', () async {
      await seedStoryline(store, memberParticipants: const ['Sarah Chen']);
      // 0.40 with disjoint people: assignment would demand 0.44 here. The
      // user's charter is what buys the look instead of a shared name.
      await seed(store, 'c1',
          vector: vectorAt(0.40), participants: const ['Ann Lu']);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await recruitAndRecord(llm);

      expect(llm.callsFor('storyline_membership'), 1);
      expect(await store.membersOf('sl-1'), hasLength(2));
    });

    test('a suggested storyline recruits on high only', () async {
      // The fifth confirm site, held to the bar the other four hold: a group
      // nobody has kept yet takes `high` and nothing weaker, even though the
      // user's own charter is what sent this pass looking.
      await seedStoryline(store, status: 'suggested', memberKey: 'new');
      await seed(store, 'c1', vector: vectorAt(0.8));

      final refused = await recruitAndRecord(fakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'medium')],
      }));

      // Asked, and turned down on the answer rather than kept from the model.
      expect(refused['considered'], 1);
      expect(refused['recruited'], 0);
      expect(await store.membersOf('sl-1'), hasLength(1));

      // A second pass over a fresh candidate, ranked ABOVE `c1` so the two
      // answers land in a known order: the high yes files and the medium one
      // is refused again. Recorded by hand rather than through
      // [recruitAndRecord], which reads the log's `single` row and the pass
      // above already wrote one.
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = fakeLlm({
        'storyline_membership': [
          confirmAnswer(confidence: 'high'),
          confirmAnswer(confidence: 'medium'),
        ],
      });
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await StorylineService(store, llm, activityLog: log).recruit('sl-1');
      await log.record('storyline_recruit', source: 'email', entityId: 'sl-1');

      // `recentActivity` is newest first, so this is the second pass's row.
      final filed =
          ActivityEvent.fromRow((await store.recentActivity()).first);
      expect(filed.detail['considered'], 2);
      expect(filed.detail['recruited'], 1);
      expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
          ['new', 'c2']);
    });

    test('under the gate never reaches the model', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.30));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
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
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      final detail = await recruitAndRecord(llm);

      expect(llm.schemas, isEmpty);
      expect(detail, isEmpty);
    });

    test('an unavailable server parks the pass and keeps what already landed',
        () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.9));
      await seed(store, 'c2', vector: vectorAt(0.8));
      final llm = fakeLlm({
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

    test('a charter saved while the hunt ran is hunted with', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      const second = 'The launch party for the Northline site, and the venue.';
      late final StorylineService service;
      var calls = 0;
      final llm = hookedFakeLlm(
        {
          'storyline_membership': [
            // The first lap turns the candidate away, so it is still a
            // candidate when the second lap asks about it against the new
            // charter.
            confirmAnswer(belongs: false),
            confirmAnswer(),
          ],
        },
        (schema) async {
          if (schema != 'storyline_membership' || calls++ > 0) return;
          // The save lands with the recruit row already `processing`, so its
          // own requeue is swallowed and no catch-up exists to find it. The
          // only thing that can notice is the pass itself.
          await service.setCharter('sl-1', second);
        },
      );
      service = StorylineService(store, llm);

      await service.recruit('sl-1');

      // Two laps, and the second one asked against the text the user saved
      // rather than the text the pass started with.
      expect(llm.callsFor('storyline_membership'), 2);
      expect(llm.userMessages.first, isNot(contains(second)));
      expect(llm.userMessages.last, contains(second));
      // And it stopped: the charter did not move under the second lap, so
      // there is no third.
      expect(
        (await store.membersOf('sl-1')).map((m) => m.conversationKey),
        ['member', 'c1'],
      );
    });
  });

  group('a storyline the user declares', () {
    /// A charter long enough to be a real one and fictional in every word.
    const charter = 'The move to the Harbour Lane office — the lease, the '
        'movers, the desk order and the day everyone is in the new room.';

    /// Seeds [count] embedded threads whose cosine against [vectorAt(1)]
    /// descends from 0.99 by a hundredth apiece, so the shortlist's order is
    /// the seeding order and every one of them clears the assignment gate.
    Future<void> seedPool(int count) async {
      for (var i = 0; i < count; i++) {
        await seed(store, 'p$i', vector: vectorAt(0.99 - i * 0.01));
      }
    }

    /// The declared storyline itself: active, memberless, both locks, and the
    /// charter the recruit will rank on.
    Future<StorylineService> declare(
      LlmClient llm, {
      EmbeddingsClient? embeddings,
      ActivityLog? log,
    }) async {
      final service = StorylineService(
        store,
        llm,
        embeddings: embeddings ?? FakeEmbeddings.at(1),
        activityLog: log,
      );
      await service.declareStoryline(title: 'Harbour Lane move', charter: charter);
      return service;
    }

    /// The id [declareStoryline] minted, read back off the one storyline row.
    Future<String> onlyStorylineId() async {
      final rows = await store.loadStorylines();
      return rows.single.id;
    }

    test('writes an active storyline of the user own, locked on both counts',
        () async {
      await declare(fakeLlm(const {}));

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.status, 'active');
      expect(storyline.createdBy, 'user');
      expect(storyline.title, 'Harbour Lane move');
      expect(storyline.charter, charter);
      expect(storyline.titleLocked, true);
      expect(storyline.charterLocked, true);
      expect(await store.membersOf(storyline.id), isEmpty);
    });

    test('queues one recruit and neither a refresh nor a recap', () async {
      await declare(fakeLlm(const {}));
      final id = await onlyStorylineId();

      final recruit = await store.nextPendingWork('storyline_recruit');
      expect(recruit?['entity_id'], id);
      expect(await pendingCount('storyline_recruit'), 1);
      // Nothing is in it yet, so there is nothing to describe and nothing to
      // catch up on.
      expect(await store.nextPendingWork('storyline_refresh'), null);
      expect(await store.nextPendingWork('storyline_recap'), null);
    });

    test('and the recruit it queues is the next one claimed', () async {
      // The drain claims `created_at DESC`, so a row queued for somebody
      // sitting in front of the pane has to be at the head of the order rather
      // than behind whatever the sweep left there.
      await store.requeueWork('storyline_recruit', 'email', 'older');
      await backdateWork('storyline_recruit', 'older');

      await declare(fakeLlm(const {}));
      final id = await onlyStorylineId();

      expect((await store.nextPendingWork('storyline_recruit'))?['entity_id'],
          id);
      expect(
        sortsAfter(
          await workCreatedAt('storyline_recruit', id),
          await workCreatedAt('storyline_recruit', 'older'),
        ),
        isTrue,
      );
    });

    test('the charter lap ranks on a clustering card of the title and charter',
        () async {
      await seedPool(1);
      final embeddings = FakeEmbeddings.at(1);
      final service = await declare(
        fakeLlm({'storyline_membership': [confirmAnswer()]}),
        embeddings: embeddings,
      );
      await service.recruit(await onlyStorylineId());

      // The shape a thread whose extraction found no topics already has: the
      // title in the subject slot, the charter in the summary slot, and the
      // two middle segments empty.
      expect(embeddings.texts.single, 'Harbour Lane move |  |  | $charter');
      expect(embeddings.prefixes.single, EmbeddingsClient.clusteringPrefix);
      // And it is the ONE recipe's bytes, not a second assembly that happens
      // to agree today: the charter card goes through `buildClusteringCard` at
      // the shipped variant, so it moves with every thread vector it is
      // measured against rather than drifting away from them.
      expect(
        embeddings.texts.single,
        buildClusteringCard(
          subject: 'Harbour Lane move',
          participants: const [],
          topics: const [],
          summary: charter,
          variant: shippedClusteringCard,
        ),
      );
    });

    test('a storyline WITH members and no vectors is not a declared hunt',
        () async {
      // Mid re-embed: the member exists and carries no comparable vector. That
      // is a storyline waiting for its vectors, not one that never held
      // anything, and ranking it on its charter would turn the re-embed window
      // into the widest hunt this pass can make.
      await seed(store, 'bare');
      await seedPool(20);
      final embeddings = FakeEmbeddings.at(1);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(store, llm, embeddings: embeddings);
      final id = await service.declareStoryline(
          title: 'Harbour Lane move', charter: charter);
      await store.addStorylineMember(id, 'email', 'bare', addedBy: 'user');

      await service.recruit(id);

      // The empty-pass ending it always took: no charter embedding asked for,
      // no candidate confirmed.
      expect(embeddings.texts, isEmpty);
      expect(llm.schemas, isEmpty);
      expect((await store.membersOf(id)).map((m) => m.conversationKey),
          ['bare']);
    });

    test('the charter lap shortlists sixteen and the next one eight', () async {
      await seedPool(20);
      // One yes, then no for the rest of the run: the first lap files a single
      // member, so the second ranks on a real centroid and takes eight.
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(), confirmAnswer(belongs: false)],
      });
      final service = await declare(llm);

      await service.recruit(await onlyStorylineId());

      expect(llm.callsFor('storyline_membership'),
          StorylineTuning.recruitMaxCandidatesDeclared +
              StorylineTuning.recruitMaxCandidates);
      expect(await store.membersOf(await onlyStorylineId()), hasLength(1));
    });

    test('and laps no more than three times however much it files', () async {
      await seedPool(40);
      // One yes at the top of each lap and no for the rest of it: every lap
      // files, so nothing but the bound stops the hunt.
      final yesAt = {
        0,
        StorylineTuning.recruitMaxCandidatesDeclared,
        StorylineTuning.recruitMaxCandidatesDeclared +
            StorylineTuning.recruitMaxCandidates,
      };
      final llm = fakeLlm({
        'storyline_membership': [
          for (var i = 0; i < 40; i++) confirmAnswer(belongs: yesAt.contains(i)),
        ],
      });
      final service = await declare(llm);

      await service.recruit(await onlyStorylineId());

      expect(
        llm.callsFor('storyline_membership'),
        StorylineTuning.recruitMaxCandidatesDeclared +
            StorylineTuning.recruitMaxCandidates * 2,
      );
      expect(await store.membersOf(await onlyStorylineId()),
          hasLength(StorylineTuning.recruitMaxLapsDeclared));
    });

    test('and stops on the first lap that files nothing', () async {
      await seedPool(20);
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });
      final service = await declare(llm);

      await service.recruit(await onlyStorylineId());

      // One lap of sixteen and no second: a lap that files nothing cannot
      // move a centroid, so another would ask the same questions.
      expect(llm.callsFor('storyline_membership'),
          StorylineTuning.recruitMaxCandidatesDeclared);
      expect(await store.membersOf(await onlyStorylineId()), isEmpty);
    });

    test('a medium yes is taken because a declared storyline is active',
        () async {
      await seedPool(1);
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(confidence: 'medium')],
      });
      final service = await declare(llm);

      await service.recruit(await onlyStorylineId());

      expect(
        (await store.membersOf(await onlyStorylineId()))
            .map((m) => m.conversationKey),
        ['p0'],
      );
    });

    test('an unavailable embedding server parks the hunt and files nothing',
        () async {
      await seedPool(2);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service = await declare(
        llm,
        embeddings: FakeEmbeddings.failing(EmbedOutcome.unavailable),
        log: log,
      );
      final id = await onlyStorylineId();

      await expectLater(
        service.recruit(id),
        throwsA(isA<LlmUnavailableException>()),
      );

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf(id), isEmpty);
      await log.record('storyline_recruit', source: 'email', entityId: id);
      final rows = await store.recentActivity();
      expect(ActivityEvent.fromRow(rows.single).detail['embed'], 'unavailable');
    });

    test('a rejected embedding ends the pass quietly', () async {
      await seedPool(2);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service = await declare(
        llm,
        embeddings: FakeEmbeddings.failing(EmbedOutcome.rejected),
        log: log,
      );
      final id = await onlyStorylineId();

      // No throw: the server answered, and it will answer the same thing on
      // the next drain, so parking would park forever.
      await service.recruit(id);

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf(id), isEmpty);
      await log.record('storyline_recruit', source: 'email', entityId: id);
      final detail = ActivityEvent.fromRow(
        (await store.recentActivity()).single,
      ).detail;
      expect(detail['embed'], 'rejected');
      expect(detail['recruited'], 0);
    });

    test('no embedding client at all is silent rather than parking', () async {
      await seedPool(2);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      final service = StorylineService(store, llm, activityLog: log);
      await service.declareStoryline(
          title: 'Harbour Lane move', charter: charter);
      final id = await onlyStorylineId();

      await service.recruit(id);

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf(id), isEmpty);
      // Nothing noted at all, so nothing recorded: the all-zero pass is the
      // genuine nothing a quiet kind suppresses, and no `embed` word rides
      // along to make it look like a failure. A user action without an
      // embedding client must not start parking queues or writing rows.
      await log.record('storyline_recruit', source: 'email', entityId: id);
      expect(await store.recentActivity(), isEmpty);
    });

    test('the first declared storyline to recruit takes the threads',
        () async {
      // Two charters that both describe the same pool. Whichever hunts first
      // files; the second is offered nothing it already holds, because the app
      // has one live storyline per thread and the second filing would be
      // invisible work over the first.
      await seedPool(4);
      final firstLlm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final first = StorylineService(
        store,
        firstLlm,
        embeddings: FakeEmbeddings.at(1),
      );
      final firstId = await first.declareStoryline(
          title: 'Harbour Lane move', charter: charter);

      final secondLlm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final second = StorylineService(
        store,
        secondLlm,
        embeddings: FakeEmbeddings.at(1),
      );
      final secondId = await second.declareStoryline(
        title: 'Harbour Lane desks',
        charter: 'The desk order for the Harbour Lane office and nothing else.',
      );

      await first.recruit(firstId);
      await second.recruit(secondId);

      expect((await store.membersOf(firstId)).map((m) => m.conversationKey),
          ['p0', 'p1', 'p2', 'p3']);
      expect(await store.membersOf(secondId), isEmpty);
      // Not even asked about: the exclusion is in the candidate walk, so the
      // second storyline spends no model time on threads it cannot have.
      expect(secondLlm.schemas, isEmpty);
    });

    test('and a thread in a suggested storyline is not recruited either',
        () async {
      await seedPool(2);
      await store.insertStoryline(
        id: 'sl-proposed',
        title: 'Proposed group',
        status: 'suggested',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-proposed', 'email', 'p0',
          addedBy: 'auto');

      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      // Declared directly rather than through the group's helper: there are two
      // storylines in the database here, so the id has to come from the call.
      final service = StorylineService(
        store,
        llm,
        embeddings: FakeEmbeddings.at(1),
      );
      final id = await service.declareStoryline(
          title: 'Harbour Lane move', charter: charter);

      await service.recruit(id);

      // `assignedOrBlockedKeys` counts `suggested` as live, because a proposal
      // on screen is a question the owner has not answered yet and filing its
      // thread elsewhere would answer it for them.
      expect((await store.membersOf(id)).map((m) => m.conversationKey), ['p1']);
    });

    test('a thread the owner removed from ANOTHER storyline is still on offer',
        () async {
      // The block is a statement about the storyline it was made in, not about
      // the thread. Read globally — which is what the sweep's taken set does,
      // rightly, for a pass PROPOSING new groups — one removal hid that thread
      // from every storyline the owner would ever declare, including the one
      // they removed it in order to file it into.
      await seedPool(2);
      await store.insertStoryline(
        id: 'sl-other',
        title: 'Another group',
        status: 'active',
        createdBy: 'auto',
      );
      // p0 was pulled OUT of sl-other and blocked there; p1 is still its
      // member.
      await store.addStorylineMember('sl-other', 'email', 'p0', addedBy: 'auto');
      await store.removeStorylineMember('sl-other', 'email', 'p0', block: true);
      await store.addStorylineMember('sl-other', 'email', 'p1', addedBy: 'auto');

      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = StorylineService(
        store,
        llm,
        embeddings: FakeEmbeddings.at(1),
      );
      final id = await service.declareStoryline(
          title: 'Harbour Lane move', charter: charter);

      await service.recruit(id);

      // p0 recruited, p1 left where it is: one thread, one live storyline
      // still holds, and it is memberships that decide it.
      expect((await store.membersOf(id)).map((m) => m.conversationKey), ['p0']);
      expect((await store.membersOf('sl-other')).map((m) => m.conversationKey),
          ['p1']);
    });

    test('the refresh backstop skips it until it holds a thread', () async {
      await seedPool(1);
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});
      final service = await declare(llm);
      final id = await onlyStorylineId();

      // Memberless: both hashes are null, and `refreshed_member_hash IS NOT
      // member_hash` is false between two nulls.
      expect(await store.staleRefreshStorylineIds(), isEmpty);

      await service.recruit(id);

      expect(await store.staleRefreshStorylineIds(), [id]);
    });
  });

  group('createStoryline', () {
    test('with a charter it locks the charter and sends the recruit out',
        () async {
      await seed(store, 'c1', vector: vectorAt(0.9));
      final service = StorylineService(store, fakeLlm(const {}));

      final id = await service.createStoryline(
        'Harbour Lane move',
        source: 'email',
        conversationKey: 'c1',
        charter: 'Everything about the move to the Harbour Lane office.',
      );

      final storyline = (await store.getStoryline(id))!;
      expect(storyline.charter,
          'Everything about the move to the Harbour Lane office.');
      expect(storyline.titleLocked, true);
      expect(storyline.charterLocked, true);
      expect((await store.membersOf(id)).map((m) => m.conversationKey), ['c1']);
      expect((await store.nextPendingWork('storyline_recruit'))?['entity_id'],
          id);
    });

    test('and that recruit is the next one claimed', () async {
      await seed(store, 'c1', vector: vectorAt(0.9));
      await store.requeueWork('storyline_recruit', 'email', 'older');
      await backdateWork('storyline_recruit', 'older');
      final service = StorylineService(store, fakeLlm(const {}));

      final id = await service.createStoryline(
        'Harbour Lane move',
        source: 'email',
        conversationKey: 'c1',
        charter: 'Everything about the move to the Harbour Lane office.',
      );

      expect((await store.nextPendingWork('storyline_recruit'))?['entity_id'],
          id);
      expect(
        sortsAfter(
          await workCreatedAt('storyline_recruit', id),
          await workCreatedAt('storyline_recruit', 'older'),
        ),
        isTrue,
      );
    });

    test('and without one it writes and queues exactly what it always did',
        () async {
      await seed(store, 'c1', vector: vectorAt(0.9));
      final service = StorylineService(store, fakeLlm(const {}));

      final id = await service.createStoryline(
        'Harbour Lane move',
        source: 'email',
        conversationKey: 'c1',
      );

      final storyline = (await store.getStoryline(id))!;
      expect(storyline.charter, null);
      expect(storyline.titleLocked, true);
      expect(storyline.charterLocked, false);
      // The add's own refresh, and no recruit: there is no charter to hunt
      // with, so a hunt would rank on nothing the user asked for.
      expect(await store.nextPendingWork('storyline_recruit'), null);
      expect((await store.nextPendingWork('storyline_refresh'))?['entity_id'],
          id);
    });
  });

  group('setCharter', () {
    test('a save trims, locks, and queues one recruit', () async {
      await seedStoryline(store);
      final llm = fakeLlm(const {});

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

      await StorylineService(store, fakeLlm(const {}))
          .setCharter('sl-1', '   ');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, null);
      expect(storyline.charterLocked, false);
      expect(await store.nextPendingWork('storyline_recruit'), null);
    });

    test('a second save revives a recruit the drain already finished',
        () async {
      await seedStoryline(store);
      final service = StorylineService(store, fakeLlm(const {}));

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
      final service = StorylineService(store, fakeLlm(const {}));

      await service.setCharter('sl-1', 'Only the homepage copy.');

      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('and clearing the charter clears it too', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1',
          charterSuggestion: 'Also the launch party.');
      final service = StorylineService(store, fakeLlm(const {}));

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

      await StorylineService(store, fakeLlm(const {}))
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
      final llm = fakeLlm({
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

    test('the refresh clears a parked offer it has just superseded', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c2', vector: vectorAt(0.9));
      // A directory brief can park an offer against an unlocked charter, and
      // this pass writes the sentence that offer was proposing to fill in.
      await store.updateStoryline(
        'sl-1',
        charterSuggestion: 'What the folder says the project is.',
      );
      final llm = fakeLlm({
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
      expect(storyline.charter, widened);
      expect(storyline.charterSuggestion, isNull);
    });

    test('runs at temperature zero — the same members must read the same twice',
        () async {
      await seedStoryline(store);
      final llm = fakeLlm({'storyline_refresh': [refineAnswer()]});

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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({'storyline_refresh': [refineAnswer(title: '')]});

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
      final llm = fakeLlm(const {});

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
      final llm = fakeLlm({'storyline_refresh': [refineAnswer()]});

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
      final llm = fakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      final newFence = llm.userMessages.single.split('"new_threads"').last;
      expect(newFence, contains('(none)'));
    });

    test('a thread added while the refresh was in flight leaves the hash stale',
        () async {
      await seedStoryline(store);
      await seed(store, 'c2', vector: vectorAt(0.9));
      final llm = hookedFakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({
        'storyline_refresh': [refineAnswer(charter: widened)],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final work = await store.nextPendingWork('storyline_recruit');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a dismissed storyline is not refreshed', () async {
      await seedStoryline(store, status: 'dismissed');
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.schemas, isEmpty);
    });

    test('a storyline emptied by removals is not refreshed', () async {
      await seedStoryline(store);
      await store.removeStorylineMember('sl-1', 'email', 'member',
          block: true);
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      // No cards, so nothing to describe it from and no reason to dial the
      // model. The stamp lands regardless: nothing to describe IS a
      // description of the empty set, and a thread joining later moves
      // `member_hash` and re-fires the pass.
      expect(llm.schemas, isEmpty);
      expect((await store.getStoryline('sl-1'))!.refreshedMemberHash,
          isNotNull);
    });

    test('a storyline emptied of everything readable converges', () async {
      await seedStoryline(store);
      await store.removeStorylineMember('sl-1', 'email', 'member',
          block: true);

      await StorylineService(store, fakeLlm(const {})).refresh('sl-1');

      // The whole point of the stamp. Without it the sweep's catch-up asks
      // this durable question on every sync forever and gets the same answer:
      // a live storyline whose description does not match its members. It
      // costs no model call, but it queues and drains a pass per sync for the
      // life of the database.
      expect(await store.staleRefreshStorylineIds(), isNot(contains('sl-1')));
    });

    test('a row that never had a member hash converges', () async {
      // `seedStoryline` writes members without touching `member_hash`, which
      // is every fixture and every storyline from before the column existed.
      await seedStoryline(store);
      expect((await store.getStoryline('sl-1'))!.memberHash, isNull);
      final llm = fakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      // The gate derives the hash from the member rows when the column is
      // NULL, but the catch-up asks SQL, and `NULL IS NOT <hash>` is true
      // however many times the pass runs. So the pass heals the column it
      // derived around — the two have to speak the same value or this row is
      // stale forever.
      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.memberHash, isNotNull);
      expect(storyline.memberHash, storyline.refreshedMemberHash);
      expect(await store.staleRefreshStorylineIds(), isNot(contains('sl-1')));
    });

    test('clearing a charter re-drafts one', () async {
      await seedStoryline(store);
      await store.updateStoryline('sl-1', charterLocked: true);
      final llm = fakeLlm({
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

    test('the first description ignores coherent and outliers by design',
        () async {
      // A person's own storyline is not the sweep's to split. The same task
      // answers both calls, and a model asked to find the odd thread out will
      // always find one — so on this branch the two fields are read and
      // discarded: the description is written and every member stays.
      await seedStoryline(store, charter: null);
      await seed(store, 'second', vector: vectorAt(0.95));
      await store.addStorylineMember('sl-1', 'email', 'second',
          addedBy: 'user');
      final llm = fakeLlm({
        'storyline_name': [
          nameAnswer(
            coherent: false,
            outliers: [1],
            charter: 'A charter the model drafted.',
          ),
        ],
      });

      await StorylineService(store, llm).refresh('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.title, 'Website redesign');
      expect(storyline.charter, 'A charter the model drafted.');
      expect(
        (await store.membersOf('sl-1')).map((m) => m.conversationKey).toSet(),
        {'member', 'second'},
      );
      // No tombstone, and nothing was blocked: the two fields cost nothing on
      // this branch.
      expect(await store.loadStorylines(statuses: const ['dismissed']),
          isEmpty);
    });

    test('the first description numbers its cards too', () async {
      // The prompt tells the model the threads are listed in [brackets], and
      // a prompt that says so over unnumbered cards is a prompt that lies.
      await seedStoryline(store, charter: null);
      final llm = fakeLlm({
        'storyline_name': [nameAnswer(charter: 'A charter the model drafted.')],
      });

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.userMessages[llm.schemas.indexOf('storyline_name')],
          contains('[1] '));
    });

    test('a recruit that filed threads refreshes the name', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).recruit('sl-1');

      final work = await store.nextPendingWork('storyline_refresh');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a recruit that filed nothing leaves the description alone', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(0.8));
      final llm = fakeLlm({
        'storyline_membership': [confirmAnswer(belongs: false)],
      });

      await StorylineService(store, llm).recruit('sl-1');

      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('one quiet thread does not wake the describer', () async {
      await seedStoryline(store);
      await markDescribed('sl-1', ['member']);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = fakeLlm({'storyline_membership': [confirmAnswer()]});

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
      final llm = fakeLlm({
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

      await StorylineService(store, fakeLlm(const {})).sweep();

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

      await StorylineService(store, fakeLlm(const {})).sweep();

      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('an unknown storyline is a quiet no-op, not a throw', () async {
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-nope');

      expect(llm.schemas, isEmpty);
    });
  });

  group('recap', () {
    /// A storyline of two threads with messages on both, interleaved in time.
    /// The recap's whole point is that it reads them as one chronology.
    Future<void> seedTwoThreads() async {
      await seedStoryline(store, keptInbound: false);
      await seed(store, 'c2', keptInbound: false);
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
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, ['storyline_recap']);
      // At the task's own measured ceiling, not runTask's generic 512.
      expect(llm.budgets['storyline_recap'], StorylineRecapTask.maxTokens);
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

    /// Gives one message a digested document, as the digest handler would.
    Future<void> seedDigested(
      String messageId,
      String attachmentId, {
      String name = 'Quote.pdf',
      String summary = 'The venue quote for the launch evening.',
      List<String> facts = const ['48,200 total', 'valid 30 days'],
      String? pinnedTo,
    }) async {
      await store.upsertAttachments('email', messageId, [
        {
          'attachment_id': attachmentId,
          'ordinal': 0,
          'kind': 'file',
          'name': name,
          'content_type': 'application/pdf',
          'size': 4096,
        },
      ]);
      await store.setAttachmentDigest(
        'email',
        messageId,
        attachmentId,
        status: 'done',
        digestJson: jsonEncode({
          'evidence': 'A quote sent for approval.',
          'kind': 'quote',
          'summary': summary,
          'facts': facts,
          'asks': const <String>[],
        }),
      );
      if (pinnedTo != null) {
        await store.setAttachmentPinned(
          'email',
          messageId,
          attachmentId,
          pinnedTo,
        );
      }
    }

    test('a digested attachment adds its facts to its message line', () async {
      await seedTwoThreads();
      await seedDigested('m2', 'a1');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      // The facts and not the summary: "the quote came in" is what the message
      // line already says, and the figures are what it cannot.
      expect(
        llm.userMessages.single,
        contains('the venue is booked ⟨attached Quote.pdf: 48,200 total; '
            'valid 30 days⟩'),
      );
    });

    test("the owner's own attachment is never filtered out", () async {
      await seedTwoThreads();
      // m3 is outbound, and it is in the window on purpose.
      await seedDigested('m3', 'a1', name: 'Signed.pdf',
          facts: const ['countersigned 1 August']);
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.userMessages.single,
          contains('⟨attached Signed.pdf: countersigned 1 August⟩'));
    });

    test('a document with no facts contributes no aside', () async {
      await seedTwoThreads();
      await seedDigested('m2', 'a1', facts: const []);
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      // The message line already says a file arrived.
      expect(llm.userMessages.single, isNot(contains('⟨attached')));
    });

    test('three documents cannot outgrow the window', () async {
      await seedTwoThreads();
      for (final id in ['m1', 'm2', 'm3']) {
        await seedDigested(id, 'a-$id',
            name: 'D-$id.pdf', facts: [for (var i = 0; i < 8; i++) 'F' * 90]);
      }
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      final user = llm.userMessages.single;
      final start = user.indexOf('source="messages"');
      final end = user.indexOf('</untrusted_data>', start);
      expect(end - start, lessThan(6200));
      // Each aside is clamped on its own, so no one document eats the window.
      for (final match in RegExp(r'⟨attached[^⟩]*⟩').allMatches(user)) {
        expect(match.group(0)!.length, lessThanOrEqualTo(162));
      }
    });

    test('a pinned document whose message aged out gets a line', () async {
      await seedTwoThreads();
      // A thread that is NOT a member, so its message is nowhere in the window.
      await seed(store, 'c9', keptInbound: false);
      await seedMessage(store, 'c9', 'old-1',
          receivedAt: '2026-07-01T09:00:00Z');
      await seedDigested('old-1', 'a9',
          name: 'Survey.pdf',
          summary: 'The site survey for the Riverside lot.',
          pinnedTo: 'sl-1');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      // The summary here rather than the facts: a pinned document is named for
      // what it IS.
      expect(
        llm.userMessages.single,
        contains('⟨pinned Survey.pdf: The site survey for the Riverside '
            'lot.⟩'),
      );
    });

    test('a pinned document still in the window is not said twice', () async {
      await seedTwoThreads();
      await seedDigested('m2', 'a1', pinnedTo: 'sl-1');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      // Its own message line already carries it.
      expect(llm.userMessages.single, contains('⟨attached Quote.pdf'));
      expect(llm.userMessages.single, isNot(contains('⟨pinned')));
    });

    /// A registered directory carrying a brief, linked to [scopeKey].
    Future<ContextStore> seedDirectory({
      String path = '/w/acme',
      String displayName = 'acme',
      String about = 'A rebrand of the Marrowfield stores, run out of one '
          'repository of notes and analyses.',
      String? linkedTo = 'sl-1',
    }) async {
      final context = ContextStore(db);
      final dirId = await context.registerDirectory(
        path: path,
        displayName: displayName,
      );
      if (about.isNotEmpty) {
        await context.setDirectoryBrief(
          dirId,
          briefJson: jsonEncode(ContextBrief(about: about).toJson()),
          briefHash: 'hash-1',
        );
      }
      if (linkedTo != null) {
        await context.link(dirId, ContextScopeKind.storyline, '', linkedTo);
      }
      return context;
    }

    test('a linked directory says what the project is, after the pins',
        () async {
      await seedTwoThreads();
      await seed(store, 'c9', keptInbound: false);
      await seedMessage(store, 'c9', 'old-1',
          receivedAt: '2026-07-01T09:00:00Z');
      await seedDigested('old-1', 'a9',
          name: 'Survey.pdf',
          summary: 'The site survey for the Riverside lot.',
          pinnedTo: 'sl-1');
      final context = await seedDirectory();
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm, contextStore: context).recap('sl-1');

      final user = llm.userMessages.single;
      expect(
        user,
        contains('⟨directory acme: A rebrand of the Marrowfield stores'),
      );
      // Last of the footers, because it is the broadest thing in the prompt:
      // the project the whole chronology sits inside.
      expect(user.indexOf('⟨pinned Survey.pdf'),
          lessThan(user.indexOf('⟨directory acme')));
    });

    test('a linked directory nothing has read yet adds nothing', () async {
      await seedTwoThreads();
      final context = await seedDirectory(about: '');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm, contextStore: context).recap('sl-1');

      // No brief means nothing has read the folder, and a bare name is a word
      // the model would have to guess at.
      expect(llm.userMessages.single, isNot(contains('⟨directory')));
    });

    test('a directory linked to another room adds nothing', () async {
      await seedTwoThreads();
      final context = await seedDirectory(linkedTo: 'sl-other');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm, contextStore: context).recap('sl-1');

      expect(llm.userMessages.single, isNot(contains('⟨directory')));
    });

    test('a pinned document nobody has read is still named', () async {
      await seedTwoThreads();
      await seed(store, 'c9', keptInbound: false);
      await seedMessage(store, 'c9', 'old-1',
          receivedAt: '2026-07-01T09:00:00Z');
      await store.upsertAttachments('email', 'old-1', const [
        {'attachment_id': 'a9', 'ordinal': 0, 'kind': 'file',
            'name': 'Survey.pdf'},
      ]);
      await store.setAttachmentPinned('email', 'old-1', 'a9', 'sl-1');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.userMessages.single, contains('⟨pinned Survey.pdf⟩'));
    });

    test('runs at temperature zero — the same window must read the same twice',
        () async {
      await seedTwoThreads();
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.temperatures, [0]);
    });

    test('a recap that has seen the newest message never reaches the model',
        () async {
      await seedTwoThreads();
      await store.updateStoryline('sl-1',
          recapThrough: '2026-08-01T11:00:00Z', recapText: 'Already said.');
      // An empty script: any call at all throws rather than answering.
      final llm = fakeLlm(const {});

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
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});
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
      await seedStoryline(store, status: 'dismissed', keptInbound: false);
      await seedMessage(store, 'member', 'm1');
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, isEmpty);
    });

    test('a storyline with nothing said in it is a quiet no-op', () async {
      await seedStoryline(store, keptInbound: false);
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.schemas, isEmpty);
      expect((await store.getStoryline('sl-1'))!.recapThrough, isNull);
    });

    test('open items and decisions survive the round trip', () async {
      await seedTwoThreads();
      final llm = fakeLlm({
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
      final llm = fakeLlm({
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
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

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
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});

      await StorylineService(store, llm).recap('sl-1');

      expect(llm.userMessages.single, contains('Title: Website redesign'));
      expect(llm.userMessages.single,
          contains('Charter: The redesign of the Northline Studio website'));
    });

    test('a message landing while the recap ran leaves the watermark behind it',
        () async {
      await seedTwoThreads();
      final llm = hookedFakeLlm({
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
      final second = fakeLlm({'storyline_recap': [recapAnswer()]});
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
      final llm = fakeLlm({'storyline_recap': [recapAnswer(recap: '   ')]});

      await StorylineService(store, llm).recap('sl-1');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(llm.callsFor('storyline_recap'), 1);
      // The text and the lists stand: a thin answer must never cost the user
      // the catch-up they had.
      expect(storyline.recapText, 'A recap worth keeping.');
      expect(storyline.recapOpenJson, '["something still open"]');
      // The watermark moves anyway, and it is recording that the model was
      // ASKED about this window rather than that the recap covers it. See the
      // test below for what leaving it behind would cost.
      expect(storyline.recapThrough, '2026-08-01T11:00:00Z');
    });

    test('a declined window is not re-asked every sync', () async {
      await seedTwoThreads();
      final llm = fakeLlm({'storyline_recap': [recapAnswer(recap: '   ')]});

      await StorylineService(store, llm).recap('sl-1');

      // The sweep's catch-up asks the durable question every single sync, so
      // an unstamped decline is a 27B call per sync, at temperature zero, over
      // the same window, for an answer that cannot come back different.
      expect(await store.staleRecapStorylineIds(), isNot(contains('sl-1')));

      // A new message is a different window, which is a different question —
      // and that is exactly when asking again is worth the call.
      await seedMessage(store, 'c2', 'm4',
          receivedAt: '2026-08-02T09:00:00Z', body: 'the photos are in');
      expect(await store.staleRecapStorylineIds(), contains('sl-1'));
    });

    test('a hand-filed old thread reaches the recap', () async {
      await seedStoryline(store, keptInbound: false);
      await seedMessage(store, 'member', 'm1',
          receivedAt: '2026-08-10T09:00:00Z', body: 'the copy looks good');
      // Recapped right up to the newest thing anyone has said.
      await store.updateStoryline('sl-1',
          recapText: 'The copy is approved.',
          recapThrough: '2026-08-10T09:00:00Z');
      // The thread a person went looking for, which is why every message on it
      // predates the mark.
      await seed(store, 'c2', keptInbound: false);
      await seedMessage(store, 'c2', 'm2',
          receivedAt: '2026-08-01T09:00:00Z', body: 'the venue is booked');
      final llm = fakeLlm({'storyline_recap': [recapAnswer()]});
      final service = StorylineService(store, llm);

      await service.addThread('sl-1', 'email', 'c2');
      expect(await drainRecap(service), 'sl-1');

      // The watermark was taken over a member set this thread was not in, so
      // it has no business gating a recap over the set it is in now. Without
      // the clear the pass returns at the gate having said nothing, and the
      // filing never reaches the block the storyline screen leads with — until
      // unrelated mail happens to land.
      expect(llm.callsFor('storyline_recap'), 1);
      expect(llm.userMessages.single, contains('the venue is booked'));
      expect(llm.userMessages.single, contains('the copy looks good'));
      // And a fresh mark: the window it just read is the whole window.
      expect((await store.getStoryline('sl-1'))!.recapThrough,
          '2026-08-10T09:00:00Z');
    });

    test('a removal re-recaps what remains', () async {
      await seedTwoThreads();
      await store.updateStoryline('sl-1',
          recapText: 'Dana has the venue booked.',
          recapThrough: '2026-08-01T11:00:00Z');
      final llm = fakeLlm({
        'storyline_refresh': [refineAnswer()],
        'storyline_recap': [recapAnswer(recap: 'The venue is somebody else.')],
      });
      final service = StorylineService(store, llm);

      // The one membership change that adds no message anywhere: nothing new
      // was said, so nothing but the clear can make the recap stale.
      await service.removeThread('sl-1', 'email', 'c2');

      // Blanked on the way out, before anything has run. The paragraph was
      // written about a member set this storyline no longer has, and there is
      // no rewrite that can tell which of its sentences the departed thread
      // paid for.
      expect((await store.getStoryline('sl-1'))!.recapText, isNull);

      expect(await drainRefresh(service), 'sl-1');
      expect(await drainRecap(service), 'sl-1');

      // Re-read and re-stamped, over the threads that are left — rather than
      // going on narrating a thread the user just pulled out.
      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.recapText, 'The venue is somebody else.');
      expect(storyline.recapThrough, '2026-08-01T11:00:00Z');
      expect(llm.userMessages.last, isNot(contains('the venue is booked')));
      // And the old recap was not handed to the model to carry forward: the
      // line renders as the bare label an absent previous recap always gets,
      // which is what keeps Dana's venue out of the next paragraph.
      expect(llm.userMessages.last,
          isNot(contains('Previous recap: Dana has the venue booked.')));
      expect(llm.userMessages.last,
          contains('Previous recap: \n</untrusted_data>'));
    });

    test('a hand-added thread recaps the storyline', () async {
      await seedStoryline(store, keptInbound: false);
      await seed(store, 'c2', keptInbound: false);
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).addThread('sl-1', 'email', 'c2');

      // A thread filed by hand brings its own messages, so where this
      // storyline stands changed the moment it landed.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a refresh queues a recap behind it', () async {
      await seedStoryline(store, keptInbound: false);
      final llm = fakeLlm({'storyline_refresh': [refineAnswer()]});

      await StorylineService(store, llm).refresh('sl-1');

      // Membership moved, so the story moved: the recap was written against a
      // set of threads that is no longer the whole story.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('a refresh that found nothing changed queues no recap', () async {
      await seedStoryline(store, keptInbound: false);
      await markDescribed('sl-1', ['member']);
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).refresh('sl-1');

      expect(llm.schemas, isEmpty);
      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('the sweep queues a recap for a storyline that never had one',
        () async {
      await seedStoryline(store, keptInbound: false);
      await seedMessage(store, 'member', 'm1');
      // Described and settled: its members match what was said about them, so
      // the refresh catch-up has nothing to say, and no mail has landed since,
      // so none of the recap's own triggers ever fires. Every storyline the
      // v10 backfill called described looks exactly like this, and none of
      // them has ever been recapped.
      await markDescribed('sl-1', ['member']);

      await StorylineService(store, fakeLlm(const {})).sweep();

      // Found on a sweep that returns early, which is the whole reason the
      // catch-up runs at the head of the pass.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('the sweep recaps a storyline the user replied into', () async {
      await seedStoryline(store, keptInbound: false);
      await seedMessage(store, 'member', 'm1',
          receivedAt: '2026-08-28T10:00:00Z');
      await markDescribed('sl-1', ['member']);
      await store.updateStoryline('sl-1',
          recapThrough: '2026-08-28T10:00:00Z');
      // The sent copy folding in from `sentitems`, gated exactly as the ingest
      // gates it. This is the whole mail reply path: no per-message trigger
      // wakes it, and none needs to — every sync ends by requeueing the sweep,
      // and the recap handler drains after the sweep's in the same pass.
      await seedMessage(store, 'member', 'm2',
          receivedAt: '2026-08-29T09:00:00Z',
          direction: 'outbound',
          fromName: 'Jordan',
          triageStatus: 'skipped',
          gateReason: 'outbound');

      await StorylineService(store, fakeLlm(const {})).sweep();

      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
    });

    test('the sweep leaves a fully-recapped storyline alone', () async {
      await seedStoryline(store, keptInbound: false);
      await seedMessage(store, 'member', 'm1');
      await markDescribed('sl-1', ['member']);
      await store.updateStoryline('sl-1',
          recapThrough: '2026-08-28T10:00:00Z');
      await store.writeWork('storyline_recap', 'email', 'sl-1',
          status: 'done');

      await StorylineService(store, fakeLlm(const {})).sweep();

      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('a storyline the sweep proposes is born described and recaps in its '
        'own drain', () async {
      await seed(store, 'c1', keptInbound: false,
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2', keptInbound: false,
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3', keptInbound: false,
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seedMessage(store, 'c1', 'm1');
      await seedMessage(store, 'c2', 'm2');
      await seedMessage(store, 'c3', 'm3');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [
          confirmAnswer(),
          confirmAnswer(),
          confirmAnswer(),
        ],
        'storyline_recap': [recapAnswer()],
      });
      final service = StorylineService(store, llm);

      await service.sweep();

      final storyline = (await store.loadStorylines()).single;
      // The proposal IS the description — `NameStorylineTask` wrote the title,
      // summary and charter from these three threads seconds ago — so the
      // refresh columns record that rather than leaving the next sweep to
      // spend a Refine call re-describing a set that never moved.
      expect(storyline.refreshedMemberHash, memberHashOf(['c1', 'c2', 'c3']));
      expect(storyline.refreshedMemberHash, storyline.memberHash);
      expect(storyline.refreshedMemberCount, 3);

      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], storyline.id);

      // And the recap handler drains after the sweep's, so the storyline the
      // user is first shown already says where it stands.
      expect(await drainRecap(service), storyline.id);
      expect((await store.getStoryline(storyline.id))!.recapText,
          contains('The homepage copy is approved'));
    });

    test('a newborn storyline does not wake the refresh pass', () async {
      // The one test in this group that SWEEPS, so its threads keep the
      // implied kept inbound message: the sweep pool is kept-inbound
      // conversations, not the embedding table.
      await seed(store, 'c1',
          vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed(store, 'c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed(store, 'c3',
          vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      final llm = fakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect(await store.staleRefreshStorylineIds(),
          isNot(contains(storyline.id)));
    });

    test('an unknown storyline is a quiet no-op, not a throw', () async {
      final llm = fakeLlm(const {});

      await StorylineService(store, llm).recap('sl-nope');

      expect(llm.schemas, isEmpty);
    });
  });

  group('offerDirectoryCharters', () {
    const about = 'A rebrand of the Marrowfield stores, run out of one '
        'repository of notes and analyses.';

    late ContextStore context;
    late String dirId;

    setUp(() async {
      context = ContextStore(db);
      dirId = await context.registerDirectory(
        path: '/w/acme',
        displayName: 'acme',
      );
    });

    Future<void> brief(String text) => context.setDirectoryBrief(
          dirId,
          briefJson: jsonEncode(ContextBrief(about: text).toJson()),
          briefHash: 'hash-1',
        );

    Future<int> offer() => StorylineService(
          store,
          fakeLlm(const {}),
          contextStore: context,
        ).offerDirectoryCharters(dirId);

    Future<void> link([String scopeKey = 'sl-1']) =>
        context.link(dirId, ContextScopeKind.storyline, '', scopeKey);

    test('an empty charter is offered one, and never written one', () async {
      await seedStoryline(store, charter: null);
      await brief(about);
      await link();

      expect(await offer(), 1);

      final storyline = (await store.getStoryline('sl-1'))!;
      // A charter is the membership criteria the recruit hunts on. A sentence
      // the person has never read must not start recruiting threads.
      expect(storyline.charter, isNull);
      expect(storyline.charterSuggestion, about);
    });

    test('a locked charter with nothing parked is offered one', () async {
      await seedStoryline(store, charter: 'Only the launch evening.');
      await store.updateStoryline('sl-1', charterLocked: true);
      await brief(about);
      await link();

      expect(await offer(), 1);
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, about);
    });

    test('a suggestion already parked is left where it is', () async {
      await seedStoryline(store, charter: 'Only the launch evening.');
      await store.updateStoryline(
        'sl-1',
        charterLocked: true,
        charterSuggestion: 'An older idea nobody has answered.',
      );
      await brief(about);
      await link();

      expect(await offer(), 0);
      expect(
        (await store.getStoryline('sl-1'))!.charterSuggestion,
        'An older idea nobody has answered.',
      );
    });

    test('an unlocked charter somebody wrote is the refresh pass\'s business',
        () async {
      await seedStoryline(store);
      await brief(about);
      await link();

      expect(await offer(), 0);
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('a brief that says what the charter already says offers nothing',
        () async {
      await seedStoryline(store, charter: null);
      await store.updateStoryline('sl-1', charter: '  A REBRAND of the\n'
          'Marrowfield stores, run out of one repository of notes and '
          'analyses. ');
      await store.updateStoryline('sl-1', charterLocked: true);
      await brief(about);
      await link();

      // Whitespace and case are not a change, on the refresh pass's own rule.
      expect(await offer(), 0);
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('a dismissed storyline is offered nothing', () async {
      await seedStoryline(store, status: 'dismissed', charter: null);
      await brief(about);
      await link();

      expect(await offer(), 0);
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('a thread link is not a storyline link', () async {
      await seedStoryline(store, charter: null);
      await brief(about);
      await context.link(dirId, ContextScopeKind.thread, 'email', 'member');

      expect(await offer(), 0);
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('a directory with no brief offers nothing', () async {
      await seedStoryline(store, charter: null);
      await link();

      expect(await offer(), 0);
    });

    test('a service with no library offers nothing', () async {
      await seedStoryline(store, charter: null);
      await brief(about);
      await link();

      expect(
        await StorylineService(store, fakeLlm(const {}))
            .offerDirectoryCharters(dirId),
        0,
      );
      expect((await store.getStoryline('sl-1'))!.charterSuggestion, isNull);
    });

    test('every linked storyline is counted', () async {
      await seedStoryline(store, charter: null);
      await store.insertStoryline(
        id: 'sl-2',
        title: 'Second',
        summary: null,
        charter: null,
        status: 'suggested',
        createdBy: 'auto',
      );
      await brief(about);
      await link();
      await link('sl-2');

      expect(await offer(), 2);
      expect((await store.getStoryline('sl-2'))!.charterSuggestion, about);
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
    /// Twelve threads in five orthogonal planes, so a group's geometry can be
    /// read off its own angles and nothing else. [ray]'s planes are mutually
    /// orthogonal, which puts every cross-group cosine at exactly 0 and leaves
    /// only the within-group angles to reason about.
    ///
    /// Three to a group wherever a group is meant to form, because
    /// `proposeMinClusterSize` turns a pair away before the namer sees it.
    ///
    ///  * `a1 a2 a3` — three rays 0.05 rad apart: a cluster of three.
    ///  * `b1 b2 b3` — the same, one plane over.
    ///  * `e1 e2 e3` — spread so the WIDEST pair is `acos(0.652)`, 0.002 ABOVE
    ///    the 0.65 link threshold: a cluster the gate only just admits.
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
      (key: 'b1', at: '2026-08-29T07:30:00Z', plane: 1, angle: 0.00),
      (key: 'b2', at: '2026-08-29T07:00:00Z', plane: 1, angle: 0.05),
      (key: 'b3', at: '2026-08-29T06:00:00Z', plane: 1, angle: 0.10),
      (key: 'e1', at: '2026-08-29T05:00:00Z', plane: 2, angle: 0.00),
      (
        key: 'e2',
        at: '2026-08-29T04:30:00Z',
        plane: 2,
        angle: math.acos(threshold + 0.002) / 2,
      ),
      (
        key: 'e3',
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

    /// The model this corpus is scripted against: three clusters of three
    /// reach it, tied on size and so ordered by their earliest member — `a`,
    /// then `b`, then `e` — and the last of them is thrown out whole, so the
    /// pass leaves a tombstone behind as well as two suggestions.
    ScriptedLlm scriptedLlm() => fakeLlm({
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
            confirmAnswer(evidence: 'b3'),
            confirmAnswer(belongs: false, evidence: 'e1 is not this'),
            confirmAnswer(belongs: false, evidence: 'e2 is not this'),
            confirmAnswer(belongs: false, evidence: 'e3 is not this'),
          ],
        });

    /// Everything the sweep decided, in a form two runs can be compared by:
    /// the status, the title, BOTH hashes, and the member set of every
    /// storyline the pass wrote — sorted, so nothing turns on the random ids.
    ///
    /// `cluster_hash` is in here on purpose. It is the identity a group
    /// already asked about is recognised by, and the reason the clustering
    /// function has to be a pure function of its input: if the two paths grouped the same
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
          // The rejected cluster KEEPS its members — it is filed as possible
          // for the owner to judge, not tombstoned — and `possible` sorts
          // ahead of `suggested`, which is what puts it first.
          'email/e1,email/e2,email/e3',
          'email/a1,email/a2,email/a3',
          'email/b1,email/b2,email/b3',
        ],
      );
      // The widest e pair sits 0.002 above the gate and the three were still
      // grouped — into the third cluster, the one the model threw out. f1 and
      // f2 sit 0.002 below it and never became a cluster at all, which is why
      // exactly three groups were named and not four.
      expect(indexed.where((d) => d.startsWith('possible')), hasLength(1));
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
      expect(members['The second group'], ['b1', 'b2', 'b3']);
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
      expect(members['The second group'], ['b1', 'b2', 'b3']);
      await db.close();
    });
  });

  /// A gate's removal, beside the owner's. The two do the same bookkeeping to
  /// the storyline — that is the property, and the reason this group reads as
  /// a comparison rather than a list of assertions — and differ in exactly
  /// three places: whose block it is, that no audit follows, and that a
  /// membership the owner made by hand survives it.
  group('evictGatedThread', () {
    Future<void> storylineWith(
      String id, {
      String key = 'c1',
      String addedBy = 'auto',
    }) async {
      await store.insertStoryline(
        id: id,
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
        memberHash: 'stale-hash',
      );
      await store.addStorylineMember(
        id,
        'email',
        key,
        addedBy: addedBy,
        evidence: 'Both concern the website redesign.',
      );
      await store.updateStoryline(
        id,
        recapText: 'The studio is reviewing the homepage copy.',
        recapThrough: '2026-08-28T10:00:00Z',
      );
    }

    test('it does everything a removal does, and blocks in its own name',
        () async {
      await seed(store, 'c1');
      await seedMessage(store, 'c1', 'm1');
      await storylineWith('sl-1');
      final service = StorylineService(store, fakeLlm(const {}));

      expect(await service.evictGatedThread('email', 'c1'), 1);

      expect(await store.membersOf('sl-1'), isEmpty);
      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.memberHash, memberHashOf(const []));
      expect(storyline.recapText, isNull);
      expect(storyline.recapThrough, isNull);
      expect(await pointerOf('m1'), isNull);
      expect((await store.nextPendingWork('storyline_refresh'))?['entity_id'],
          'sl-1');

      // The block is a gate's, with a sentence about the thread rather than
      // the model's own evidence — and no audit, because a gate says nothing
      // about whether the model got this group right.
      final block = (await store.blocksOf('sl-1')).single;
      expect(block.blockedBy, 'gate');
      expect(block.evidence, 'every inbound message in this thread was gated');
      expect(await store.nextPendingWork('storyline_audit'), isNull);
    });

    test('the same thread in two storylines leaves both', () async {
      await seed(store, 'c1');
      await storylineWith('sl-1');
      await storylineWith('sl-2');
      final service = StorylineService(store, fakeLlm(const {}));

      expect(await service.evictGatedThread('email', 'c1'), 2);

      expect(await store.membersOf('sl-1'), isEmpty);
      expect(await store.membersOf('sl-2'), isEmpty);
    });

    test('a thread the owner filed by hand is not a gate\'s to take', () async {
      await seed(store, 'c1');
      await storylineWith('sl-1', addedBy: 'user');
      final service = StorylineService(store, fakeLlm(const {}));

      expect(await service.evictGatedThread('email', 'c1'), 0);

      expect((await store.membersOf('sl-1')).single.addedBy, 'user');
      expect(await store.blocksOf('sl-1'), isEmpty);
      expect(await store.nextPendingWork('storyline_refresh'), isNull);
    });

    test('a thread in nothing is a no-op', () async {
      await seed(store, 'c1');
      final service = StorylineService(store, fakeLlm(const {}));

      expect(await service.evictGatedThread('email', 'c1'), 0);
    });
  });
  /// Phase 5's lifecycle: a sweep that waits for a settled mailbox, the
  /// suggestions that expire so its room keeps moving, and the pool rows that
  /// are one thread wearing three conversation keys.
  group('the sweep lifecycle', () {
    /// Runs a sweep with [llm] and returns what it wrote to the activity log.
    ///
    /// Empty when the pass was quiet: the log suppresses an all-zero row as
    /// the genuine nothing it is, so an empty map here IS an assertion.
    Future<Map<String, Object?>> sweepAndRecord(
      ScriptedLlm llm, {
      MessageStore? into,
    }) async {
      final target = into ?? store;
      final log = ActivityLog(target);
      addTearDown(log.dispose);
      await StorylineService(target, llm, activityLog: log).sweep();
      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');
      final rows = await target.recentActivity();
      if (rows.isEmpty) return const {};
      return ActivityEvent.fromRow(rows.single).detail;
    }

    /// Three threads close enough in two dimensions to be one cosine cluster,
    /// with [first] as the newest and so the first row the pool hands over.
    Future<void> seedTrio(
      MessageStore into, {
      String first = 'a',
      String second = 'b',
      String third = 'c',
    }) async {
      await seed(into, first,
          subject: 'Alpha launch review',
          vector: vectorAt(1),
          lastMessageAt: '2026-08-29T10:00:00Z');
      await seed(into, second,
          subject: 'Beta rollout plan',
          vector: vectorAt(0.98),
          lastMessageAt: '2026-08-28T10:00:00Z');
      await seed(into, third,
          subject: 'Gamma migration notes',
          vector: vectorAt(0.96),
          lastMessageAt: '2026-08-27T10:00:00Z');
    }

    /// A stamp [days] before now, in the shape the store compares against.
    /// Derived from the clock rather than written out: a literal date walks
    /// out of a rolling window at midnight and the test rots with no code
    /// change.
    String daysAgo(int days) => MessageStore.isoStamp(
          DateTime.now().subtract(Duration(days: days)),
        );

    Future<void> proposedAt(String id, int daysOld) => db.customUpdate(
          'UPDATE storylines SET created_at = ? WHERE id = ?',
          variables: [Variable(daysAgo(daysOld)), Variable(id)],
        );

    /// An unanswered automatic suggestion, with no members and a tombstone of
    /// its own — the shape the rail's three slots actually fill up with.
    Future<void> seedSuggestion(
      String id, {
      String status = 'suggested',
      String createdBy = 'auto',
      required int daysOld,
    }) async {
      await store.insertStoryline(
        id: id,
        title: 'Website redesign',
        summary: 'The studio is reviewing the homepage copy.',
        charter: 'The redesign of the Northline Studio website.',
        status: status,
        createdBy: createdBy,
        clusterHash: 'cluster-hash-of-$id',
      );
      await proposedAt(id, daysOld);
    }

    group('the sweep waits for a settled mailbox', () {
      test('extraction still running defers the pass', () async {
        await seedTrio(store);
        for (var i = 0; i < 11; i++) {
          await store.enqueueWork('extract', 'email', 'm$i');
        }
        // No scripts at all: this fake throws on its first call, which is how
        // "not one model was dialled" is proved rather than counted.
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(detail['deferred'], 'unsettled');
        expect(detail['extract'], 11);
        expect(detail['embed'], 0);
        expect(detail['triage'], 0);
        expect(llm.schemas, isEmpty);
        expect(await store.loadStorylines(), isEmpty);
      });

      test('embeddings still running defers the pass', () async {
        await seedTrio(store);
        for (var i = 0; i < 26; i++) {
          await store.enqueueWork('embed_message', 'email', 'm$i');
        }
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(detail['deferred'], 'unsettled');
        expect(detail['embed'], 26);
        expect(detail['extract'], 0);
        expect(llm.schemas, isEmpty);
      });

      test('a triage backlog defers the pass', () async {
        await seedTrio(store);
        // Triage has no work row — the queue claims the column on the message
        // itself — so this floor is counted off `messages.triage_status`.
        for (var i = 0; i < 21; i++) {
          await seedMessage(store, 'unjudged$i', 'u$i');
        }
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(detail['deferred'], 'unsettled');
        expect(detail['triage'], 21);
        expect(llm.schemas, isEmpty);
      });

      test('a backlog exactly at the floors is settled enough', () async {
        await seedTrio(store);
        for (var i = 0; i < 10; i++) {
          await store.enqueueWork('extract', 'email', 'm$i');
        }
        for (var i = 0; i < 25; i++) {
          await store.enqueueWork('embed_message', 'email', 'e$i');
        }
        for (var i = 0; i < 20; i++) {
          await seedMessage(store, 'unjudged$i', 'u$i');
        }
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        // Strictly greater than the floor defers, so sitting on all three of
        // them does not: the numbers name what is tolerable.
        expect(detail['deferred'], isNull);
        expect(detail['proposed'], 1);
      });

      test('an item at the server counts toward its floor', () async {
        await seedTrio(store);
        for (var i = 0; i < 11; i++) {
          await store.enqueueWork('extract', 'email', 'm$i');
        }
        // Ten pending and one claimed is eleven outstanding: an item a worker
        // is holding is work the pool is still waiting on.
        final claimed =
            await store.claimPendingWork('extract', sources: const ['email']);
        expect(claimed, isNotNull);

        final detail = await sweepAndRecord(fakeLlm(const {}));

        expect(detail['deferred'], 'unsettled');
        expect(detail['extract'], 11);
      });

      test('work queued under local counts too', () async {
        await seedTrio(store);
        // The floors read `AiWorker.sources`, which is what the worker
        // drains, and a context directory queues under `local`.
        for (var i = 0; i < 11; i++) {
          await store.enqueueWork('extract', 'local', 'f$i');
        }

        final detail = await sweepAndRecord(fakeLlm(const {}));

        expect(detail['deferred'], 'unsettled');
        expect(detail['extract'], 11);
      });

      test('a deferred pass still heals a refresh and still expires',
          () async {
        // The order inside the pass, read off one row. The catch-ups run
        // before everything because they heal wakeups that were LOST, and the
        // expiry runs before the deferral because a mailbox that never
        // settles would otherwise never break its own deadlock.
        await seedStoryline(store);
        await store.updateStoryline('sl-1',
            memberHash: memberHashOf(['member']));
        await store.writeWork('storyline_refresh', 'email', 'sl-1',
            status: 'done');
        await seedSuggestion('sl-stale', daysOld: 15);
        for (var i = 0; i < 11; i++) {
          await store.enqueueWork('extract', 'email', 'm$i');
        }

        final detail = await sweepAndRecord(fakeLlm(const {}));

        expect(detail['deferred'], 'unsettled');
        expect(detail['expired'], 1);
        expect((await store.getStoryline('sl-stale'))!.status, 'dismissed');
        final work = await store.nextPendingWork('storyline_refresh');
        expect(work?['entity_id'], 'sl-1');
      });
    });

    group('suggestions expire', () {
      test('a suggestion nobody answered for a fortnight is dismissed',
          () async {
        await seedSuggestion('sl-stale', daysOld: 15);
        await store.addStorylineMember('sl-stale', 'email', 'member',
            addedBy: 'auto', evidence: 'The same website redesign.');

        final detail = await sweepAndRecord(fakeLlm(const {}));

        expect(detail['expired'], 1);
        expect((await store.getStoryline('sl-stale'))!.status, 'dismissed');
        // Members stay exactly as a dismissal leaves them: they are the record
        // of what the owner was actually shown, and the pool counts only
        // suggested and active memberships, so the threads come back anyway.
        expect((await store.membersOf('sl-stale')).single.conversationKey,
            'member');
        // Born carrying its tombstone, so the identical cluster costs no model
        // call on the next sweep.
        expect(
          await store
              .dismissedHashExistsAny(const ['cluster-hash-of-sl-stale']),
          isTrue,
        );
      });

      test('a young one, a kept one and a person\'s own all stay', () async {
        await seedSuggestion('sl-young', daysOld: 13);
        await seedSuggestion('sl-kept', status: 'active', daysOld: 15);
        await seedSuggestion('sl-mine', createdBy: 'user', daysOld: 15);

        final detail = await sweepAndRecord(fakeLlm(const {}));

        expect(detail['expired'], isNull);
        expect((await store.getStoryline('sl-young'))!.status, 'suggested');
        expect((await store.getStoryline('sl-kept'))!.status, 'active');
        expect((await store.getStoryline('sl-mine'))!.status, 'suggested');
      });

      test('the same pass that empties the room proposes into it', () async {
        // The deadlock, and the thing that breaks it. Three unanswered
        // proposals is `maxPendingSuggestions`, and without an expiry the room
        // count is zero on every future pass for the life of the mailbox.
        for (final id in ['sl-1', 'sl-2', 'sl-3']) {
          await seedSuggestion(id, daysOld: 15);
        }
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['expired'], 3);
        expect(detail['proposed'], 1);
        expect(llm.callsFor('storyline_membership'), 3);
      });

      test('three suggestions inside the window still hold the room',
          () async {
        for (final id in ['sl-1', 'sl-2', 'sl-3']) {
          await seedSuggestion(id, daysOld: 13);
        }
        await seedTrio(store);
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(detail, isEmpty);
        expect(llm.schemas, isEmpty);
        expect(await store.loadStorylines(statuses: const ['suggested']),
            hasLength(3));
      });

      test('Restore lifts an expiry like any other dismissal', () async {
        await seedSuggestion('sl-stale', daysOld: 15);
        await sweepAndRecord(fakeLlm(const {}));
        expect((await store.getStoryline('sl-stale'))!.status, 'dismissed');

        await StorylineService(store, fakeLlm(const {}))
            .restoreDismissed('sl-stale');

        expect((await store.getStoryline('sl-stale'))!.status, 'suggested');
      });
    });

    /// Phase 6's seam. The store keeps no record of a cluster the namer
    /// declined beyond the `possible` row it files, so the golden sweep bench
    /// reads each cluster's gold purity BEFORE naming through an observer the
    /// app never passes. What these pin is what that observer will see.
    group('the clusters are observable', () {
      /// Sweeps with [llm] and returns every report the observer was handed.
      Future<List<SeenCluster>> sweepAndObserve(ScriptedLlm llm) async {
        final log = ActivityLog(store);
        addTearDown(log.dispose);
        final seen = <SeenCluster>[];
        await StorylineService(
          store,
          llm,
          activityLog: log,
          clusterObserver: (threads, outcome) =>
              seen.add((threads: threads, outcome: outcome)),
        ).sweep();
        return seen;
      }

      /// The conversation keys one report carried, in the order it carried
      /// them.
      List<String> keysOf(SeenCluster report) =>
          [for (final thread in report.threads) thread.key];

      /// A name the charter lint passes, about an invented effort.
      Map<String, dynamic> alphaName({
        bool coherent = true,
        List<int> outliers = const [],
      }) =>
          nameAnswer(
            title: 'Alpha launch',
            charter: 'The alpha launch review for the example.com rollout',
            coherent: coherent,
            outliers: outliers,
          );

      test('a formed storyline is reported once, as the cluster was formed',
          () async {
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [alphaName()],
          'storyline_membership': [confirmAnswer()],
        });

        final seen = await sweepAndObserve(llm);

        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'formed');
        expect(keysOf(seen.single), ['a', 'b', 'c']);
        expect(seen.single.threads.map((t) => t.source).toSet(), {'email'});
      });

      test(
          'a cluster the namer declines is reported as incoherent, with every '
          'thread it was formed from', () async {
        await seedTrio(store);
        // No membership script at all: this fake throws on a confirm, so the
        // count below is proof rather than bookkeeping.
        final llm = fakeLlm({
          'storyline_name': [alphaName(coherent: false)],
        });

        final seen = await sweepAndObserve(llm);

        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'incoherent');
        expect(keysOf(seen.single), ['a', 'b', 'c']);
        expect(llm.callsFor('storyline_membership'), 0);
      });

      test('an outlier narrows the confirms but not the report', () async {
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [alphaName(coherent: false, outliers: [3])],
          'storyline_membership': [confirmAnswer()],
        });

        final seen = await sweepAndObserve(llm);

        // The report is the cluster the sweep BUILT: what the namer then threw
        // out is the namer's answer, not the clustering's proposal.
        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'formed');
        expect(keysOf(seen.single), ['a', 'b', 'c']);
        expect(llm.callsFor('storyline_membership'), 2);
      });

      test('a hash that already answers is reported as answered and asks '
          'no model', () async {
        await seedTrio(store);
        final first = await sweepAndObserve(fakeLlm({
          'storyline_name': [alphaName(coherent: false)],
        }));
        expect(first.single.outcome, 'incoherent');
        // Filed as possible, which is the row whose hash answers next pass.
        expect(await store.loadStorylines(statuses: const ['possible']),
            hasLength(1));

        // The same three threads rebuild the same cluster next pass, and that
        // row answers it for nothing.
        final second = fakeLlm(const {});
        final seen = await sweepAndObserve(second);

        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'answered');
        expect(keysOf(seen.single), ['a', 'b', 'c']);
        expect(second.callsFor('storyline_name'), 0);
      });

      test('a lint hit is reported as lint', () async {
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [
            nameAnswer(title: 'Placeholder', charter: 'placeholder'),
          ],
        });

        final seen = await sweepAndObserve(llm);

        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'lint');
        expect(llm.callsFor('storyline_membership'), 0);
      });

      test('confirms that leave one survivor are reported as thin', () async {
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [alphaName()],
          'storyline_membership': [
            confirmAnswer(belongs: false),
            confirmAnswer(belongs: false),
            confirmAnswer(),
          ],
        });

        final seen = await sweepAndObserve(llm);

        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'thin');
        expect(await store.loadStorylines(statuses: const ['suggested']),
            isEmpty);
      });

      test('a fragment sibling rides its representative and is not in the '
          'report', () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.99),
            lastMessageAt: '2026-08-27T10:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [alphaName()],
          'storyline_membership': [confirmAnswer()],
        });

        final seen = await sweepAndObserve(llm);

        // Four threads filed, three reported: a sibling was never clustered,
        // never named and never confirmed, so it was never part of the
        // question the purity line is about.
        expect(seen, hasLength(1));
        expect(seen.single.outcome, 'formed');
        expect(keysOf(seen.single), ['a', 'b', 'c']);
        final storyline = (await store.loadStorylines(
          statuses: const ['suggested'],
        ))
            .single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'a', 'a2', 'b', 'c'},
        );
      });

      test('a service without an observer sweeps as before', () async {
        await seedTrio(store);
        final llm = fakeLlm({
          'storyline_name': [alphaName()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['proposed'], 1);
        expect(
          await store.loadStorylines(statuses: const ['suggested']),
          hasLength(1),
        );
      });
    });

    group('fragments ride together', () {
      /// The representative's two fragments: the SAME subject modulo the reply
      /// marker, the case and the spacing, the same people, both a few days
      /// behind it. Not the same subject modulo a date, which is what makes
      /// three issues of a weekly digest a series rather than one thread.
      Future<void> seedFragmentsOfA(
        MessageStore into, {
        List<String> participants = const ['Sarah Chen'],
      }) async {
        await seed(into, 'a2',
            subject: 'Re: Alpha launch review',
            participants: participants,
            vector: vectorAt(-1),
            lastMessageAt: '2026-08-27T10:00:00Z');
        await seed(into, 'a3',
            subject: 'RE:  alpha launch review',
            participants: participants,
            vector: vectorAt(-0.9),
            lastMessageAt: '2026-08-26T10:00:00Z');
      }

      /// How many cards the naming call was shown.
      int namingCardCount(ScriptedLlm llm) =>
          fenceBody(llm.userMessages[llm.schemas.indexOf('storyline_name')],
                  'threads')
              .trim()
              .split('\n---\n')
              .length;

      test('one thread wearing three keys is confirmed once and stored thrice',
          () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seedFragmentsOfA(store);
        await seed(store, 'b', participants: const ['Sarah Chen']);
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        // Three questions asked, five threads filed.
        expect(llm.callsFor('storyline_membership'), 3);
        expect(llm.callsFor('storyline_name'), 1);
        expect(detail['fragments'], 2);
        expect(detail['folded'], 2);
        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'a', 'a2', 'a3', 'b', 'c'},
        );
        // The two hashes answer two questions. `member_hash` is who is stored,
        // siblings included; `cluster_hash` is the set the model was asked
        // about, so an arriving fragment cannot turn a tombstoned question
        // into a new one.
        expect(storyline.memberHash,
            memberHashOf(['a', 'a2', 'a3', 'b', 'c']));
        // `cluster_hash` is not on the model, so it is read off the column.
        final clusterHash = (await db
                .customSelect(
                  'SELECT cluster_hash FROM storylines WHERE id = ?',
                  variables: [Variable(storyline.id)],
                )
                .getSingle())
            .data['cluster_hash'] as String?;
        expect(clusterHash, memberHashOf(['a', 'b', 'c']));
      });

      test('a possible storyline files its fragment siblings', () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seedFragmentsOfA(store);
        final llm = fakeLlm({
          'storyline_name': [nameAnswer(coherent: false)],
          'storyline_membership': [confirmAnswer()],
        });

        await StorylineService(store, llm).sweep();

        // The declined cluster is filed with the same member set a proposal
        // would have written: a fragment is not a second thread that agreed,
        // it is the same thread arriving three times, and a kept storyline
        // whose own forks sat outside it in the pool would not be the group
        // anybody was asked about.
        final possible =
            (await store.loadStorylines(statuses: const ['possible'])).single;
        expect(
          (await store.membersOf(possible.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'a', 'a2', 'a3', 'b', 'c'},
        );
        expect(llm.callsFor('storyline_membership'), 0);
        // The two hashes answer their two questions here as well: who is
        // stored, and which set the model was asked about.
        expect(possible.memberHash, memberHashOf(['a', 'a2', 'a3', 'b', 'c']));
        final clusterHash = (await db
                .customSelect(
                  'SELECT cluster_hash FROM storylines WHERE id = ?',
                  variables: [Variable(possible.id)],
                )
                .getSingle())
            .data['cluster_hash'] as String?;
        expect(clusterHash, memberHashOf(['a', 'b', 'c']));
      });

      test('the namer is shown the representatives and nothing else',
          () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seedFragmentsOfA(store);
        await seed(store, 'b', participants: const ['Sarah Chen']);
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        await sweepAndRecord(llm);

        // Three cards and not five: a fragment is the same thread arriving
        // twice, and numbering it again would have the model describe one
        // effort as three.
        expect(namingCardCount(llm), 3);
      });

      test('the same subject with different people is not one thread',
          () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Re: Alpha launch review',
            participants: const ['Dana Whitfield'],
            vector: vectorAt(0.97),
            lastMessageAt: '2026-08-27T10:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        // Who is on a thread is half the identity: two threads with one
        // subject and no one in common are two threads.
        expect(detail['fragments'], 0);
        expect(llm.callsFor('storyline_membership'), 4);
      });

      test('a fragment outside the window is a thread of its own', () async {
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Re: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.97),
            lastMessageAt: '2026-08-14T10:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        // Fifteen days apart, measured from the representative: past the
        // window a subject somebody re-used is a new conversation.
        expect(detail['fragments'], 0);
        expect(detail['folded'], 0);
        expect(llm.callsFor('storyline_membership'), 4);
      });

      test('a sibling of a rejected representative joins nothing', () async {
        // The representative is the newest row, so it is the first thread the
        // confirm loop asks about, and the script turns that one down.
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Re: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(-1),
            lastMessageAt: '2026-08-27T10:00:00Z');
        await seed(store, 'b',
            subject: 'Beta rollout plan',
            vector: vectorAt(0.98),
            lastMessageAt: '2026-08-28T10:00:00Z');
        await seed(store, 'c',
            subject: 'Gamma migration notes',
            vector: vectorAt(0.96),
            lastMessageAt: '2026-08-28T09:00:00Z');
        await seed(store, 'd',
            subject: 'Delta pricing sheet',
            vector: vectorAt(0.94),
            lastMessageAt: '2026-08-28T08:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [
            confirmAnswer(belongs: false),
            confirmAnswer(),
          ],
        });

        final detail = await sweepAndRecord(llm);

        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'b', 'c', 'd'},
        );
        expect(detail['fragments'], 0);
        // Turned away, not blocked: both rows go back to the pool, where a
        // later pass may cluster them with something they do belong to.
        expect(await store.assignedOrBlockedKeys('email'),
            isNot(contains('a2')));
        expect(await store.assignedOrBlockedKeys('email'),
            isNot(contains('a')));
      });

      test('a dated series among the same people is a series, not one thread',
          () async {
        // The two subject rules pulling apart. The fragment identity keys on
        // the RAW subject, so three dated issues are three identities and the
        // series pre-pass gets to see them for what they are; keying the fold
        // on the series subject instead would have folded a weekly digest
        // among fixed people into one thread that had arrived three times.
        await seed(store, 'w1',
            subject: 'Weekly ops digest 2026-09-15',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            messageCount: 3,
            inboundCount: 2,
            lastMessageAt: '2026-08-29T04:00:00Z');
        await seed(store, 'w2',
            subject: 'Weekly ops digest 2026-09-08',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0),
            lastMessageAt: '2026-08-29T03:00:00Z');
        await seed(store, 'w3',
            subject: 'Weekly ops digest 2026-09-01',
            participants: const ['Sarah Chen'],
            vector: vectorAt(-1),
            lastMessageAt: '2026-08-29T02:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer(title: 'Weekly ops digest')],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['series'], 1);
        expect(detail['folded'], 0);
        expect(llm.callsFor('storyline_name'), 1);
        expect(namingCardCount(llm), 3);
      });

      test('two threads each wearing two keys are not three to propose',
          () async {
        // Four rows, two threads. The floors count representatives, so this
        // pool holds a pair and a pair is not something to spend a naming call
        // on, however many keys the connectors minted for it.
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Re: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.99),
            lastMessageAt: '2026-08-28T10:00:00Z');
        await seed(store, 'b',
            subject: 'Beta rollout plan',
            participants: const ['Dana Whitfield'],
            vector: vectorAt(0.98),
            lastMessageAt: '2026-08-27T10:00:00Z');
        await seed(store, 'b2',
            subject: 'Re: Beta rollout plan',
            participants: const ['Dana Whitfield'],
            vector: vectorAt(0.97),
            lastMessageAt: '2026-08-26T10:00:00Z');
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(llm.schemas, isEmpty);
        expect(await store.loadStorylines(), isEmpty);
        // The folding still happened and the row still says so, even though
        // nothing it folded went on to ship.
        expect(detail['folded'], 2);
        expect(detail['proposed'], 0);
      });

      test('two unnamed threads with the same people are two threads',
          () async {
        // An empty key never groups, on the series pre-pass's rule: an unnamed
        // thread has nothing in common with another unnamed thread, whoever is
        // on both of them.
        await seed(store, 'e1',
            subject: '',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'e2',
            subject: '',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.98),
            lastMessageAt: '2026-08-28T10:00:00Z');
        await seed(store, 'c',
            subject: 'Gamma migration notes',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.96),
            lastMessageAt: '2026-08-27T10:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['folded'], 0);
        expect(llm.callsFor('storyline_membership'), 3);
        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'e1', 'e2', 'c'},
        );
      });

      test('two identical subjects with nobody named still fold', () async {
        // The other half of the same rule. An empty PARTICIPANT set does
        // group: two threads with one subject and nobody named on either are
        // the same thread as far as anything here can tell.
        await seed(store, 'u1',
            subject: 'Alpha launch review',
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'u2',
            subject: 'Re: Alpha launch review',
            vector: vectorAt(0.98),
            lastMessageAt: '2026-08-28T10:00:00Z');
        final llm = fakeLlm(const {});

        final detail = await sweepAndRecord(llm);

        expect(detail['folded'], 1);
        expect(llm.schemas, isEmpty);
      });

      test('a feed is still excluded rather than folded into one row',
          () async {
        // The reason the series pre-pass runs on the RAW rows. A feed is
        // fragment-shaped by construction, and folded first it would collapse
        // to one representative, never reach the series floor, and land in the
        // cosine pool beside work it has nothing to do with.
        await seedTrio(store);
        for (final (index, key) in ['n1', 'n2', 'n3'].indexed) {
          await seed(store, key,
              subject: 'Vendor status report 2026-09-0${index + 1}',
              vector: vectorAt(0.99),
              messageCount: 1,
              inboundCount: 1,
              fromAddress: 'alerts@example.com',
              lastMessageAt: '2026-08-2${6 - index}T10:00:00Z');
        }
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['series_excluded'], 3);
        expect(detail['fragments'], 0);
        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'a', 'b', 'c'},
        );
        expect(llm.callsFor('storyline_membership'), 3);
      });

      test('a series that folds to one row is not a series', () async {
        // Three issues of one cancelled meeting are one thread, not something
        // recurring, so the pre-pass's group loses its seed and its single
        // representative goes back to the cosine pool.
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seedFragmentsOfA(store);
        await seed(store, 'b',
            subject: 'Beta rollout plan',
            vector: vectorAt(0.98),
            lastMessageAt: '2026-08-28T10:00:00Z');
        await seed(store, 'c',
            subject: 'Gamma migration notes',
            vector: vectorAt(0.96),
            lastMessageAt: '2026-08-28T09:00:00Z');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['series'], 0);
        expect(detail['fragments'], 2);
        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          {'a', 'a2', 'a3', 'b', 'c'},
        );
      });

      test('a stamp that will not parse starts a new representative',
          () async {
        // Everything else about these two says one thread: one subject, one
        // person. Without a stamp on both there is no window to measure, and a
        // rule that folded anyway would be guessing.
        await seedTrio(store);
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'a2',
            subject: 'Re: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.97),
            lastMessageAt: 'not-a-date');
        final llm = fakeLlm({
          'storyline_name': [nameAnswer()],
          'storyline_membership': [confirmAnswer()],
        });

        final detail = await sweepAndRecord(llm);

        expect(detail['folded'], 0);
        // Both are representatives and both are asked about, alongside the
        // trio: four threads, four confirms.
        expect(llm.callsFor('storyline_membership'), 4);
        final storyline = (await store.loadStorylines()).single;
        expect(
          (await store.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet(),
          containsAll(<String>{'a', 'a2'}),
        );
      });

      test('the window is closed at exactly fourteen days', () async {
        // The boundary the rule is written at, both sides of it. Measured from
        // the representative, so both of these are read against `a`.
        await seed(store, 'a',
            subject: 'Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(1),
            lastMessageAt: '2026-08-29T10:00:00Z');
        await seed(store, 'on-the-day',
            subject: 'Re: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.97),
            lastMessageAt: '2026-08-15T10:00:00Z');
        await seed(store, 'an-hour-past',
            subject: 'RE: Alpha launch review',
            participants: const ['Sarah Chen'],
            vector: vectorAt(0.96),
            lastMessageAt: '2026-08-15T09:00:00Z');

        final rows = await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
        );
        final fragments = StorylineService.fragmentsOf(rows);

        // Exactly fourteen days folds; fourteen days and an hour does not,
        // and starts a representative of its own from there on.
        expect(
          [
            for (final i in fragments.representatives)
              rows[i]['conversation_key'],
          ],
          ['a', 'an-hour-past'],
        );
        expect(fragments.siblings.values.single, hasLength(1));
      });

      test('two identical mailboxes fold identically', () async {
        // The folding is a pure function of the rows' order and contents, with
        // no clock in it, which is what every tombstone in the scheme rests
        // on: a cluster that formed differently is a new question. The second
        // mailbox is seeded in the REVERSE order, because the pool's own
        // `last_message_at DESC, conversation_key ASC` is what decides the row
        // order the rule sees — insertion order is not allowed to matter.
        // Five distinct keys and no key written twice, so reversing the list
        // reverses the INSERTION order and nothing else.
        Future<Set<String>> membersAfterSweep(
          MessageStore into, {
          bool reversed = false,
        }) async {
          final seeds = <Future<void> Function()>[
            () => seed(into, 'a',
                subject: 'Alpha launch review',
                participants: const ['Sarah Chen'],
                vector: vectorAt(1),
                lastMessageAt: '2026-08-29T10:00:00Z'),
            () => seed(into, 'a2',
                subject: 'Re: Alpha launch review',
                participants: const ['Sarah Chen'],
                vector: vectorAt(-1),
                lastMessageAt: '2026-08-27T10:00:00Z'),
            () => seed(into, 'a3',
                subject: 'RE:  alpha launch review',
                participants: const ['Sarah Chen'],
                vector: vectorAt(-0.9),
                lastMessageAt: '2026-08-26T10:00:00Z'),
            () => seed(into, 'b',
                subject: 'Beta rollout plan',
                participants: const ['Sarah Chen'],
                vector: vectorAt(0.98),
                lastMessageAt: '2026-08-28T10:00:00Z'),
            () => seed(into, 'c',
                subject: 'Gamma migration notes',
                participants: const ['Sarah Chen'],
                vector: vectorAt(0.96),
                lastMessageAt: '2026-08-27T09:00:00Z'),
          ];
          for (final step in reversed ? seeds.reversed : seeds) {
            await step();
          }
          await StorylineService(
            into,
            fakeLlm({
              'storyline_name': [nameAnswer()],
              'storyline_membership': [confirmAnswer()],
            }),
          ).sweep();
          final storyline = (await into.loadStorylines()).single;
          return (await into.membersOf(storyline.id))
              .map((m) => m.conversationKey)
              .toSet();
        }

        final other = testDb();
        addTearDown(other.close);

        expect(
          await membersAfterSweep(store),
          await membersAfterSweep(MessageStore(other), reversed: true),
        );

        // And the rule asked directly, which a sweep agreeing with itself
        // cannot prove. The same list twice is the same answer; the same rows
        // in the other order is deliberately NOT, because the representative
        // is the newest row and reversing makes the oldest come first.
        final pool = await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
        );
        final once = StorylineService.fragmentsOf(pool);
        final twice = StorylineService.fragmentsOf(pool);
        expect(once.representatives, twice.representatives);
        expect(once.siblings, twice.siblings);
        // Read as KEYS, not as indexes: the two answers happen to name the same
        // positions, and what differs is which row each position holds.
        List<String> keysAt(
          List<Map<String, Object?>> rows,
          List<int> indexes,
        ) =>
            [for (final i in indexes) rows[i]['conversation_key'] as String];
        final backwardsPool = pool.reversed.toList();
        final backwards = StorylineService.fragmentsOf(backwardsPool);
        expect(keysAt(pool, once.representatives), ['a', 'b', 'c']);
        expect(
          keysAt(backwardsPool, backwards.representatives),
          isNot(keysAt(pool, once.representatives)),
        );
      });
    });
  });
}
