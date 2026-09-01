import 'dart:math' as math;

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Which server each model job goes to.
///
/// The split is the whole of phase 3: labels under a tight schema — triage,
/// extraction, storyline membership — run on the small server, and prose —
/// drafts, storyline names — stays on the 27B. Nothing about a task's OUTPUT
/// says which server produced it, so the only way to hold the routing still is
/// to give the service two distinguishable clients and watch which one is
/// dialled.
///
/// The same [FakeLlm] as `storyline_service_test.dart`, keyed on `schemaName`
/// for the same reason: assignment may go straight on to naming, and a
/// positional script would hand the naming task the confirmation's answer.
class FakeLlm extends LlmClient {
  /// Names this fake in a failure message. Two fakes that record identically
  /// are otherwise indistinguishable in an `expect` diff.
  final String label;

  final Map<String, List<Object>> scripts;

  final List<String> schemas = [];

  FakeLlm(this.label, this.scripts)
      : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    await Future<void>.delayed(const Duration(milliseconds: 1));

    final script = scripts[schemaName];
    if (script == null || script.isEmpty) {
      // Louder than a missing answer deserves on its own: reaching this means
      // a call landed on the WRONG server, which is the defect these tests
      // exist for.
      throw StateError('$label was asked for $schemaName and has no script');
    }
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// A unit vector whose cosine against `[1, 0]` is exactly [c].
List<double> vectorAt(double c) => [c, math.sqrt(1 - c * c)];

Map<String, dynamic> confirmAnswer() => {
      'evidence': 'Both concern the Willow Street appraisal.',
      'belongs': true,
      'confidence': 'high',
    };

Map<String, dynamic> nameAnswer() => {
      'evidence': 'shared deal',
      'title': 'Willow St purchase',
      'summary': 'Underwriting is reviewing the appraisal.',
    };

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seed(String key, {List<double>? vector, String? lastMessageAt}) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': 'Subject for $key',
      'state': 'waiting',
      'last_message_at': lastMessageAt ?? '2026-08-28T10:00:00Z',
      'participants_json': '[{"name":"Sarah Chen"}]',
    });
    if (vector == null) return;
    store.upsertConversationAi(
      'email',
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: 'h-$key',
      embedModel: EmbeddingsClient.modelTag,
    );
  }

  /// A storyline with one embedded member and NO summary, so an assignment
  /// that confirms goes straight on to name it — which is what puts both
  /// halves of the split in one flow.
  void seedUnnamedStoryline() {
    seed('member', vector: vectorAt(1));
    store.insertStoryline(
      id: 'sl-1',
      title: 'Willow St purchase',
      status: 'active',
      createdBy: 'auto',
    );
    store.addStorylineMember('sl-1', 'email', 'member', addedBy: 'auto');
  }

  group('StorylineService', () {
    test('membership goes to the confirm client, naming to the primary',
        () async {
      seedUnnamedStoryline();
      seed('c1', vector: vectorAt(0.9));
      final primary = FakeLlm('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = FakeLlm('fast', {
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, primary, confirmClient: fast)
          .assignConversation('email', 'c1');

      // One flow, two servers: the membership question never touched the 27B
      // and the naming never touched the small model.
      expect(fast.schemas, ['storyline_membership']);
      expect(primary.schemas, ['storyline_name']);
      // And it did the work, rather than routing tidily past a no-op.
      expect(store.membersOf('sl-1'), hasLength(2));
      expect(store.getStoryline('sl-1')!.summary,
          'Underwriting is reviewing the appraisal.');
    });

    test('the sweep names on the primary even with a confirm client', () async {
      // Four unassigned threads, two of which link — the sweep proposes one
      // storyline and names it. No membership is judged: a cluster IS the
      // claim, so nothing here belongs on the fast server.
      seed('c1', vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      seed('c2', vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      seed('c3', vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      seed('c4', vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final primary = FakeLlm('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = FakeLlm('fast', const {});

      await StorylineService(store, primary, confirmClient: fast).sweep();

      expect(primary.callsFor('storyline_name'), 1);
      expect(fast.schemas, isEmpty);
      expect(store.loadStorylines(), hasLength(1));
    });

    test('without a confirm client everything stays on the one it was given',
        () async {
      seedUnnamedStoryline();
      seed('c1', vector: vectorAt(0.9));
      final only = FakeLlm('only', {
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });

      await StorylineService(store, only).assignConversation('email', 'c1');

      // The pre-phase-3 behaviour, and what every other caller in the tests
      // still relies on: one client answers both jobs.
      expect(only.schemas, ['storyline_membership', 'storyline_name']);
    });
  });

  group('providers', () {
    test('the two clients point at different servers', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(llmClientProvider).baseUrl, LlmClient.defaultBaseUrl);
      expect(container.read(fastLlmClientProvider).baseUrl,
          LlmClient.fastBaseUrl);
      // Not the same server, and not the same object — two clients is the
      // point, and one provider accidentally delegating to the other would
      // route every label back onto the 27B.
      expect(LlmClient.fastBaseUrl, isNot(LlmClient.defaultBaseUrl));
      expect(identical(container.read(llmClientProvider),
          container.read(fastLlmClientProvider)), isFalse);
    });

    test('storylineServiceProvider wires the split', () async {
      seedUnnamedStoryline();
      seed('c1', vector: vectorAt(0.9));
      final primary = FakeLlm('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = FakeLlm('fast', {
        'storyline_membership': [confirmAnswer()],
      });
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          llmClientProvider.overrideWithValue(primary),
          fastLlmClientProvider.overrideWithValue(fast),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(storylineServiceProvider)
          .assignConversation('email', 'c1');

      // The service tests above prove the service honours a confirm client;
      // this one proves the wiring actually passes it.
      expect(fast.schemas, ['storyline_membership']);
      expect(primary.schemas, ['storyline_name']);
    });
  });
}
