import 'dart:math' as math;

// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

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

/// A unit vector whose cosine against `[1, 0]` is exactly [c]. Two dimensions
/// is all these tests need — the gates are cosine thresholds, and a 768-wide
/// vector would only make the arithmetic harder to read.
List<double> vectorAt(double c) => [c, math.sqrt(1 - c * c)];

Map<String, dynamic> confirmAnswer({
  String evidence = 'Both concern the Willow Street appraisal.',
  bool belongs = true,
  String confidence = 'high',
}) =>
    {'evidence': evidence, 'belongs': belongs, 'confidence': confidence};

Map<String, dynamic> nameAnswer({
  String title = 'Willow St purchase',
  String summary = 'Underwriting is reviewing the appraisal.',
}) =>
    {'evidence': 'shared deal', 'title': title, 'summary': summary};

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
  }) async {
    await into.upsertConversation({
      'conversation_key': key,
      'subject': subject ?? 'Subject for $key',
      'state': state,
      'last_message_at': lastMessageAt,
      'participants_json':
          '[${participants.map((p) => '{"name":"$p"}').join(',')}]',
    });
    if (vector == null) return;
    await into.upsertConversationAi(
      'email',
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: 'h-$key',
      embedModel: embedModel,
    );
  }

  /// A storyline with one member, both already embedded.
  Future<void> seedStoryline(
    MessageStore into, {
    String id = 'sl-1',
    String status = 'active',
    String? summary = 'Underwriting is reviewing the appraisal.',
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
      title: 'Willow St purchase',
      summary: summary,
      status: status,
      createdBy: 'auto',
    );
    if (titleLocked) await into.updateStoryline(id, titleLocked: true);
    await into.addStorylineMember(id, 'email', memberKey, addedBy: 'auto');
  }

  group('assignConversation', () {
    test('a candidate over the gate is confirmed once and filed', () async {
      await seedStoryline(store);
      await seed(store, 'c1',
          vector: vectorAt(0.8), lastMessageAt: '2026-08-29T10:00:00Z');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.callsFor('storyline_membership'), 1);
      // The summary is already there, so nothing needs naming.
      expect(llm.callsFor('storyline_name'), 0);
      final members = await store.membersOf('sl-1');
      expect(members.map((m) => m.conversationKey), ['member', 'c1']);
      final added = members.last;
      expect(added.addedBy, 'auto');
      expect(added.evidence, 'Both concern the Willow Street appraisal.');
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

    test('a thread with no embedding returns silently', () async {
      await seedStoryline(store);
      await seed(store, 'c1');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
      expect(await store.membersOf('sl-1'), hasLength(1));
    });

    test('a vector from another embedding model is not comparable', () async {
      await seedStoryline(store);
      await seed(store, 'c1', vector: vectorAt(1), embedModel: 'some-other-model');
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(llm.schemas, isEmpty);
    });

    test('a storyline whose members have no vectors is skipped', () async {
      await seed(store, 'member');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Willow St purchase',
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

      await StorylineService(store, llm).assignConversation('email', 'c1');

      final storyline = (await store.getStoryline('sl-1'))!;
      // The user named it. No later pass takes that back.
      expect(storyline.title, 'Willow St purchase');
      // The summary describes where things stand, which no rename claimed.
      expect(storyline.summary, 'Underwriting is reviewing the appraisal.');
    });

    test('an unlocked title is replaced when the storyline is named',
        () async {
      await seedStoryline(store, summary: null);
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer(title: 'Chen refinance')],
      });

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect((await store.getStoryline('sl-1'))!.title, 'Chen refinance');
    });

    test('a suggestion still collects members while it waits', () async {
      await seedStoryline(store, status: 'suggested');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(await store.membersOf('sl-1'), hasLength(2));
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

    test('too little unassigned mail is a no-op', () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.95));
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), isEmpty);
    });

    test('a cluster becomes one suggestion with its members', () async {
      await seedMailbox(store);
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});

      await StorylineService(store, llm).sweep();

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');
      expect(storyline.title, 'Willow St purchase');
      expect(storyline.summary, 'Underwriting is reviewing the appraisal.');
      expect(storyline.id, startsWith('sl-'));
      expect(storyline.lastActivityAt, '2026-08-29T04:00:00Z');

      final members = await store.membersOf(storyline.id);
      expect(members.map((m) => m.conversationKey).toSet(), {'c1', 'c2'});
      expect(members.every((m) => m.addedBy == 'auto'), isTrue);
      expect(members.first.evidence, 'clustered together');
      // Named once, and never asked to confirm anything: a cluster IS the
      // claim, so there is no existing group to judge against.
      expect(llm.callsFor('storyline_name'), 1);
      expect(llm.callsFor('storyline_membership'), 0);
      expect(llm.temperatures, [0]);
    });

    test('a done thread is never the start of a story', () async {
      await seedMailbox(store);
      store.setConversationState('email', 'c2', ConversationState.done);
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});

      await StorylineService(store, llm).sweep();

      // c1's only partner is finished, so nothing clusters — and with c2 gone
      // there are only three threads left to look at anyway.
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
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});

      await StorylineService(store, llm).sweep();

      // c1 is spoken for, which leaves three unassigned threads — under the
      // floor, so the sweep does not run.
      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), hasLength(1));
    });

    test('a dismissed cluster is not proposed again', () async {
      await seedMailbox(store);
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});
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
      final llm = FakeLlm({'storyline_name': [nameAnswer()]});

      await StorylineService(store, llm).sweep();

      expect(llm.schemas, isEmpty);
      expect(await store.loadStorylines(), hasLength(3));
    });

    test('clustering is deterministic — same mailbox, same groups', () async {
      Future<Set<String>> clusterOf(BondDatabase into) async {
        final target = MessageStore(into);
        await seedMailbox(target);
        await StorylineService(
          target,
          FakeLlm({'storyline_name': [nameAnswer()]}),
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
  });

  group('user actions', () {
    test('creating a storyline locks its title and files the thread', () async {
      await seed(store, 'c1', lastMessageAt: '2026-08-29T10:00:00Z');
      final service =
          StorylineService(store, FakeLlm(const {}));

      final id = await service.createStoryline(
        'Chen refinance',
        source: 'email',
        conversationKey: 'c1',
      );

      final storyline = (await store.getStoryline(id))!;
      expect(storyline.title, 'Chen refinance');
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
        title: 'Willow St purchase',
        summary: 'Underwriting is reviewing the appraisal.',
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
      expect(dismissed.summary, 'Underwriting is reviewing the appraisal.');
      // The member rows are the record the hash was computed over. Deleting
      // them would leave the app unable to recognise the cluster again.
      expect(await store.membersOf('sl-1'), hasLength(1));
      expect(await store.dismissedMemberHashExists('h1'), isTrue);
    });

    test('renaming locks the title', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Untitled storyline',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));

      await service.rename('sl-1', 'Chen refinance');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.title, 'Chen refinance');
      expect(storyline.titleLocked, isTrue);
    });

    test('removing a thread always blocks it', () async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Willow St purchase',
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
        title: 'Willow St purchase',
        status: 'active',
        createdBy: 'auto',
      );
      final service = StorylineService(store, FakeLlm(const {}));
      await service.addThread('sl-1', 'email', 'c1');
      await service.removeThread('sl-1', 'email', 'c1');

      await service.addThread('sl-1', 'email', 'c1');

      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      expect(await store.membersOf('sl-1'), hasLength(1));
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
      expect(row.detail['assigned'], 'Willow St purchase');
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

    test('a sweep counts its proposals once, not once per cluster', () async {
      await seed(store, 'c1', vector: vectorAt(1));
      await seed(store, 'c2', vector: vectorAt(0.9));
      await seed(store, 'c3', vector: vectorAt(0));
      await seed(store, 'c4', vector: vectorAt(-0.9));
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await StorylineService(
        store,
        FakeLlm({'storyline_name': [nameAnswer()]}),
        activityLog: log,
      ).sweep();

      await log.record('storyline_sweep', source: 'email', entityId: 'sweep');

      final row = ActivityEvent.fromRow((await store.recentActivity()).single);
      expect(row.detail['proposed'], 1);
    });
  });
}
