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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect((await store.getStoryline('sl-1'))!.title, 'Brightsea launch');
    });

    test('a suggestion still collects members while it waits', () async {
      await seedStoryline(store, status: 'suggested');
      await seed(store, 'c1', vector: vectorAt(0.9));
      final llm = FakeLlm({'storyline_membership': [confirmAnswer()]});

      await StorylineService(store, llm).assignConversation('email', 'c1');

      expect(await store.membersOf('sl-1'), hasLength(2));
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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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

      await StorylineService(store, llm).assignConversation('email', 'c1');

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
      final hash = (await db
              .customSelect(
                'SELECT member_hash FROM storylines WHERE id = ?',
                variables: [Variable(tombstone.id)],
              )
              .getSingle())
          .data['member_hash'];
      expect(hash, isNotNull);
      expect(await store.dismissedMemberHashExists(hash! as String), isTrue);
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
      final llm = FakeLlm({
        'storyline_name': [nameAnswer()],
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, llm).sweep();

      // c1 is spoken for, which leaves three unassigned threads — under the
      // floor, so the sweep does not run.
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
  });
}
