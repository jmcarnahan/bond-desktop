import 'dart:convert';
import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionUnavailableException;
import 'package:bond_inbox/services/storyline_judge.dart' show StorylineJudge;
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The sweep's grouping: cosine proposes the clusters, and the decision model
/// is asked only about what the namer wrote for them (`charter_specific`) and
/// each member (`member_of`).

/// A unit vector [degrees] around from `[1, 0]`, so the cosine of any two of
/// them is the cosine of the angle between them and a test can write the
/// geometry it means.
List<double> atDegrees(double degrees) {
  final radians = degrees * math.pi / 180;
  return [math.cos(radians), math.sin(radians)];
}

/// [key] with every digit spelled out, so the default subject gives each
/// thread its own series key — subjects differing by a digit run share one,
/// and would be a seeded series whatever the vectors said.
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
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subjectOf(key),
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
      'subject': subjectOf(key),
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': lastMessageAt,
      'body_text': 'body of kept-$key',
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

  /// [count] threads within a few degrees of each other, newest first: one
  /// cosine cluster.
  Future<void> seedNear(int count) async {
    final keys = [for (var i = 1; i <= count; i++) 'g$i'];
    final now = DateTime.utc(2026, 8, 29, 12);
    for (var i = 0; i < keys.length; i++) {
      await seed(
        keys[i],
        at: i * 0.5,
        lastMessageAt: now.subtract(Duration(minutes: i)).toIso8601String(),
      );
    }
  }

  /// A client whose storyline questions are scripted: every charter and
  /// member a yes over both bars.
  ScriptedLlm llmWith() => ScriptedLlm()
    ..answer('storyline_name', nameAnswer())
    ..answer('charter_specific', const {'p': 0.9})
    ..answer('member_of', const {'p': 0.9});

  test('a parked decision model asks nothing, fetches nothing and writes '
      'nothing', () async {
    await seedNear(4);
    final decision = FakeDecisionClient.storyline()
      ..askError = const DecisionUnavailableException('decide is down');
    var fetches = 0;
    final llm = llmWith();

    await expectLater(
      StorylineService(
        store,
        llm,
        judge: StorylineJudge(
          decision: decision,
          store: store,
          ensureBodies: (_, _, _) async => fetches++,
        ),
      ).sweep(),
      throwsA(isA<DecisionUnavailableException>()),
    );

    expect(decision.readyChecks, 1);
    expect(decision.asks, isEmpty);
    expect(llm.calls, isEmpty);
    expect(fetches, 0);
    expect(await store.loadStorylines(), isEmpty);
  });

  test('two identical mailboxes group identically', () async {
    Future<List<Set<String>>> run(MessageStore into) async {
      final llm = llmWith();
      await StorylineService(
        into,
        llm,
        judge: scriptedJudge(into, llm),
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

    expect(first, hasLength(1));
    expect(second, first);
  });

  test('the model charter check ships', () {
    expect(StorylineTuning.charterCheck, CharterCheck.model);
  });
}
