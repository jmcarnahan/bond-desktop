import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// Which server each model job goes to.
///
/// The split is the whole of phase 3: labels under a tight schema — triage,
/// extraction, storyline membership — run on the small server, and prose —
/// drafts, storyline names — stays on the 27B. Nothing about a task's OUTPUT
/// says which server produced it, so the only way to hold the routing still is
/// to give the service two distinguishable clients and watch which one is
/// dialled.
///
/// The shared [ScriptedLlm], keyed on `schemaName` as `storyline_service_test`
/// keys it: assignment may go straight on to naming, and a positional script
/// would hand the naming task the confirmation's answer.
///
/// [label] names the client in its own failure message, which matters more
/// here than anywhere else: two clients that record identically are
/// indistinguishable in an `expect` diff, and an unscripted schema means a
/// call landed on the WRONG server, the defect these tests exist for.
ScriptedLlm routed(String label, Map<String, List<Object>> scripts) {
  final llm = ScriptedLlm(label: label);
  scripts.forEach(llm.scriptFor);
  return llm;
}

/// A unit vector whose cosine against `[1, 0]` is exactly [c].
List<double> vectorAt(double c) => [c, math.sqrt(1 - c * c)];

Map<String, dynamic> confirmAnswer() => {
      'evidence': 'Both concern the website redesign.',
      'belongs': true,
      'confidence': 'high',
    };

Map<String, dynamic> groupAnswer(List<int> threads) => {
      'groups': [
        {'threads': threads, 'why': 'All three are the homepage rebuild.'},
      ],
    };

Map<String, dynamic> nameAnswer() => {
      'evidence': 'shared deal',
      'title': 'Website redesign',
      'summary': 'The studio is reviewing the homepage copy.',
    };

/// The refresh pass's answer — the description coming back unchanged, which
/// is what it does most of the time. The same shape
/// `storyline_service_test.dart` uses; it is here rather than imported
/// because these two files script different passes for different reasons.
Map<String, dynamic> refineAnswer() => {
      'evidence': 'Every thread is still the website redesign.',
      'title': 'Website redesign',
      'summary': 'The studio is reviewing the homepage copy.',
      'charter': 'The redesign of the Northline Studio website.',
    };

Map<String, dynamic> recapAnswer() => {
      'evidence': 'The studio moved the launch date.',
      'recap': 'The homepage copy is approved and the launch moved.',
      'open_items': <String>['Sarah owes the photo selects to Dana'],
      'decisions': <String>['The launch moved a week'],
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// [key] with every digit spelled out. The sweep's series pre-pass folds
  /// every digit run in a subject to one placeholder, so `Subject for c1` and
  /// `Subject for c2` would read as two issues of one recurring series — and
  /// a series nobody answered, sent from one address, leaves the pool before
  /// the clustering ever sees it.
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

  Future<void> seed(String key,
      {List<double>? vector, String? lastMessageAt}) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': 'Subject for ${spellDigits(key)}',
      'state': 'waiting',
      'last_message_at': lastMessageAt ?? '2026-08-28T10:00:00Z',
      'participants_json': '[{"name":"Sarah Chen"}]',
    });
    if (vector == null) return;
    // The message the vector implies. An embedding is written by extraction,
    // which does not run until triage has spoken, so a conversation with a
    // vector and nothing kept behind it is a shape the app cannot produce —
    // and one the assign pass now closes as `AssignOutcome.gated` before it
    // asks any client anything, which is not what these tests are about.
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'kept-$key',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Subject for ${spellDigits(key)}',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': lastMessageAt ?? '2026-08-28T10:00:00Z',
      'body_text': 'body of kept-$key',
      'triage_status': 'triaged',
    });
    await store.upsertConversationAi(
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
  Future<void> seedUnnamedStoryline() async {
    await seed('member', vector: vectorAt(1));
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'member', addedBy: 'auto');
  }

  group('StorylineService', () {
    test('membership goes to the confirm client, naming to the primary',
        () async {
      await seedUnnamedStoryline();
      await seed('c1', vector: vectorAt(0.9));
      final primary = routed('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = routed('fast', {
        'storyline_membership': [confirmAnswer()],
      });

      final service = StorylineService(store, primary, confirmClient: fast);
      await service.assignConversation('email', 'c1');
      // The description is queued rather than written inline, so the flow has
      // two halves now — the drain is where the naming call lives.
      await service.refresh('sl-1');

      // One flow, two servers: the membership question never touched the 27B
      // and the naming never touched the small model.
      expect(fast.schemas, ['storyline_membership']);
      expect(primary.schemas, ['storyline_name']);
      // And it did the work, rather than routing tidily past a no-op.
      expect(await store.membersOf('sl-1'), hasLength(2));
      expect((await store.getStoryline('sl-1'))!.summary,
          'The studio is reviewing the homepage copy.');
    });

    test('the sweep names on the primary and confirms on the fast client',
        () async {
      // Five unassigned threads, three of which link — the sweep proposes one
      // storyline and names it. Three and not two because a cosine cluster
      // under `proposeMinClusterSize` never reaches the namer at all. The
      // cluster is a shortlist, not a verdict, so each of its threads is then
      // confirmed against that name, and membership is a membership question
      // wherever it is asked from: it goes to the small server exactly as an
      // assignment's does.
      await seed('c1', vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed('c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed('c3', vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed('c4', vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      await seed('c5', vector: vectorAt(-0.9), lastMessageAt: '2026-08-29T01:00:00Z');
      final primary = routed('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = routed('fast', {
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(store, primary, confirmClient: fast).sweep();

      expect(primary.schemas, ['storyline_name']);
      expect(fast.schemas, [
        'storyline_membership',
        'storyline_membership',
        'storyline_membership',
      ]);
      expect(await store.loadStorylines(), hasLength(1));
    });

    test('the neighbourhood grouping goes to the naming client by default',
        () async {
      // The dark path, exercised with the test-only override rather than by
      // flipping the const the rest of the suite reads. Grouping is prose
      // work of the same kind naming is, so it lands on the 27B — and the
      // membership questions it produces still go to the small server.
      await seed('c1', vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed('c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed('c3', vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      await seed('c4', vector: vectorAt(0), lastMessageAt: '2026-08-29T02:00:00Z');
      final primary = routed('primary', {
        'storyline_group': [groupAnswer([1, 2, 3])],
        'storyline_name': [nameAnswer()],
      });
      final fast = routed('fast', {
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(
        store,
        primary,
        confirmClient: fast,
        groupingMode: GroupingMode.model,
      ).sweep();

      expect(primary.schemas, ['storyline_group', 'storyline_name']);
      expect(fast.schemas, [
        'storyline_membership',
        'storyline_membership',
        'storyline_membership',
      ]);
    });

    test('a group client takes the grouping off the naming client', () async {
      // The third handle Phase 3 points at a stage of its own. Naming stays
      // where it was, which is what makes this a split rather than a move.
      await seed('c1', vector: vectorAt(1), lastMessageAt: '2026-08-29T04:00:00Z');
      await seed('c2',
          vector: vectorAt(0.95), lastMessageAt: '2026-08-29T03:30:00Z');
      await seed('c3', vector: vectorAt(0.9), lastMessageAt: '2026-08-29T03:00:00Z');
      final primary = routed('primary', {
        'storyline_name': [nameAnswer()],
      });
      final grouper = routed('grouper', {
        'storyline_group': [groupAnswer([1, 2, 3])],
      });
      final fast = routed('fast', {
        'storyline_membership': [confirmAnswer()],
      });

      await StorylineService(
        store,
        primary,
        confirmClient: fast,
        groupClient: grouper,
        groupingMode: GroupingMode.model,
      ).sweep();

      expect(grouper.schemas, ['storyline_group']);
      expect(primary.schemas, ['storyline_name']);
    });

    test('without a confirm client everything stays on the one it was given',
        () async {
      await seedUnnamedStoryline();
      await seed('c1', vector: vectorAt(0.9));
      final only = routed('only', {
        'storyline_membership': [confirmAnswer()],
        'storyline_name': [nameAnswer()],
      });

      final service = StorylineService(store, only);
      await service.assignConversation('email', 'c1');
      await service.refresh('sl-1');

      // The pre-phase-3 behaviour, and what every other caller in the tests
      // still relies on: one client answers both jobs.
      expect(only.schemas, ['storyline_membership', 'storyline_name']);
    });
  });

  group('providers', () {
    test('a stage client defaults to its slot\'s server', () async {
      // The family watches the activity log, which watches the store — so
      // even this read-only test needs a real database under it.
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      // And reading `baseUrl` resolves the stage map, so the settings have to
      // be in before the assertion rather than landing on a database this
      // test's tearDown has already closed.
      await container.read(appPrefsProvider.notifier).ready;

      expect(container.read(stageLlmClientProvider('draft_reply')).baseUrl,
          LlmClient.defaultBaseUrl);
      expect(container.read(stageLlmClientProvider('triage')).baseUrl,
          LlmClient.fastBaseUrl);
      // Not the same server, and not the same object — two servers is the
      // point, and one stage accidentally aliasing the other would route
      // every label back onto the 27B.
      expect(LlmClient.fastBaseUrl, isNot(LlmClient.defaultBaseUrl));
      expect(
        identical(container.read(stageLlmClientProvider('draft_reply')),
            container.read(stageLlmClientProvider('triage'))),
        isFalse,
      );
      // One instance per stage id, cached exactly as the two clients were.
      expect(
        identical(container.read(stageLlmClientProvider('triage')),
            container.read(stageLlmClientProvider('triage'))),
        isTrue,
      );
    });

    test('storylineServiceProvider wires the split', () async {
      await seedUnnamedStoryline();
      await seed('c1', vector: vectorAt(0.9));
      final primary = routed('primary', {
        'storyline_name': [nameAnswer()],
      });
      final fast = routed('fast', {
        'storyline_membership': [confirmAnswer()],
      });
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          stageLlmClientProvider.overrideWith(
            (ref, id) => stageSlot(id) == ModelSlot.fast ? fast : primary,
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(storylineServiceProvider);
      await service.assignConversation('email', 'c1');
      await service.refresh('sl-1');

      // The service tests above prove the service honours a confirm client;
      // this one proves the wiring actually passes it.
      expect(fast.schemas, ['storyline_membership']);
      expect(primary.schemas, ['storyline_name']);
    });

    test('the storyline provider hands each pass its own stage client',
        () async {
      await seedUnnamedStoryline();
      await seed('c1', vector: vectorAt(0.9));
      // One fake per stage, so which client answered is the assertion — the
      // service defaults all four to the naming client, and a provider that
      // forgot one would be invisible with a single fake.
      final clients = {
        for (final id in [
          'storyline_membership',
          'storyline_name',
          'storyline_refresh',
          'storyline_recap',
        ])
          id: routed(id, {
            'storyline_membership': [confirmAnswer()],
            'storyline_name': [nameAnswer()],
            'storyline_refresh': [refineAnswer()],
            'storyline_recap': [recapAnswer()],
          }),
      };
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          stageLlmClientProvider.overrideWith(
            (ref, id) => clients[id] ?? routed(id, const {}),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(storylineServiceProvider);
      await service.assignConversation('email', 'c1');
      // The first refresh has nothing to evolve, so it BOOTSTRAPS — the
      // naming task.
      await service.refresh('sl-1');
      // A described storyline EVOLVES instead, which is the refine task, and
      // a moved member hash is what re-fires the pass at all.
      await store.updateStoryline(
        'sl-1',
        summary: 'The studio is reviewing the homepage copy.',
        charter: 'The redesign of the Northline Studio website.',
      );
      await seed('c2', vector: vectorAt(0.92));
      await service.assignConversation('email', 'c2');
      await service.refresh('sl-1');
      await service.recap('sl-1');

      expect(clients['storyline_membership']!.schemas,
          everyElement('storyline_membership'));
      expect(clients['storyline_name']!.schemas, ['storyline_name']);
      expect(clients['storyline_refresh']!.schemas, ['storyline_refresh']);
      expect(clients['storyline_recap']!.schemas, ['storyline_recap']);
    });

    test('a stored target moves the fast client without rebuilding it',
        () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      final client = container.read(stageLlmClientProvider('triage'));
      expect(client.baseUrl, LlmClient.fastBaseUrl);

      await container.read(appPrefsProvider.notifier).setFastLlmTarget(
            url: 'http://127.0.0.1:9/v1/chat/completions',
            model: 'mlx-4b',
          );

      // The SAME instance follows the setting — that is the whole design. A
      // rebuild here would abort a drain to change the next request's server.
      expect(identical(container.read(stageLlmClientProvider('triage')), client),
          isTrue);
      expect(client.baseUrl, 'http://127.0.0.1:9/v1/chat/completions');
      expect(client.model, 'mlx-4b');
    });

    test('the prose client reads its own slot', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      final prose = container.read(stageLlmClientProvider('draft_reply'));
      final fast = container.read(stageLlmClientProvider('triage'));

      await container.read(appPrefsProvider.notifier).setProseLlmTarget(
            url: 'http://127.0.0.1:9/v1/chat/completions',
            model: 'mlx-27b',
          );

      expect(
          identical(
              container.read(stageLlmClientProvider('draft_reply')), prose),
          isTrue);
      expect(prose.baseUrl, 'http://127.0.0.1:9/v1/chat/completions');
      expect(prose.model, 'mlx-27b');
      // Two slots, not one setting: moving prose must not move the bulk work.
      expect(fast.baseUrl, LlmClient.fastBaseUrl);
      expect(fast.model, LlmClient.fastModel);
      // And two ceilings. Prose runs one long call — a draft at every input
      // cap — so it gets the number sized to that; the bulk client's calls
      // answer in seconds, so its 120 costs nothing and stays.
      expect(prose.timeout, LlmClient.proseTimeout);
      expect(fast.timeout, const Duration(seconds: 120));
    });

    test('a stage map entry moves one stage and leaves the others', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final prefs = container.read(appPrefsProvider.notifier);
      await prefs.ready;

      final triage = container.read(stageLlmClientProvider('triage'));
      final extraction = container.read(stageLlmClientProvider('extraction'));
      expect(triage.baseUrl, LlmClient.fastBaseUrl);

      await prefs.upsertTarget(
        const LlmTargetSpec(
          id: 'gpu-1',
          name: 'GPU box',
          url: 'http://127.0.0.1:9/v1/chat/completions',
          model: 'qwen3-4b',
        ),
      );
      await prefs.setStageTarget('triage', 'gpu-1');

      // Per STAGE, which is what the map buys over the two slots: one stage
      // moves and its neighbour on the same slot does not.
      expect(triage.baseUrl, 'http://127.0.0.1:9/v1/chat/completions');
      expect(triage.model, 'qwen3-4b');
      expect(extraction.baseUrl, LlmClient.fastBaseUrl);
      // And still the same instances, for the reason above.
      expect(identical(container.read(stageLlmClientProvider('triage')), triage),
          isTrue);
      expect(
        identical(
            container.read(stageLlmClientProvider('extraction')), extraction),
        isTrue,
      );
    });

    test('pointing a stage elsewhere rebuilds no worker', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final prefs = container.read(appPrefsProvider.notifier);
      await prefs.ready;

      final triage = container.read(triageQueueProvider);
      final worker = container.read(aiWorkerProvider);
      final storyline = container.read(storylineWorkerProvider);
      final drafts = container.read(draftWorkerProvider);

      await prefs.upsertTarget(
        const LlmTargetSpec(
          id: 'gpu-1',
          name: 'GPU box',
          url: 'http://127.0.0.1:9/v1/chat/completions',
          model: 'qwen3.8',
        ),
      );
      await prefs.setStageTarget('draft_reply', 'gpu-1');

      // The same requirement as the slot test below, one level up: the stage
      // map is reached by `ref.read` of the NOTIFIER inside a resolver
      // closure, so a write creates no dependency edge. The day someone makes
      // it a `ref.watch`, every one of these becomes a new object and a drain
      // in flight is disposed to change where the NEXT request goes.
      expect(identical(container.read(triageQueueProvider), triage), isTrue);
      expect(identical(container.read(aiWorkerProvider), worker), isTrue);
      expect(identical(container.read(storylineWorkerProvider), storyline),
          isTrue);
      expect(identical(container.read(draftWorkerProvider), drafts), isTrue);
    });

    test('the queues keep the clients they were built with', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      final triage = container.read(triageQueueProvider);
      final worker = container.read(aiWorkerProvider);
      final storyline = container.read(storylineWorkerProvider);
      final drafts = container.read(draftWorkerProvider);
      final gate = container.read(fastDrainGateProvider);
      final activity = container.read(activityLogProvider);
      final progress = container.read(progressBusProvider);

      await container.read(appPrefsProvider.notifier).setFastLlmTarget(
            url: 'http://127.0.0.1:9/v1/chat/completions',
            model: 'mlx-4b',
          );

      // The no-rebuild requirement, which nothing else enforces: the resolver
      // is a `ref.read` inside a closure, and the day someone makes it a
      // `ref.watch` every one of these becomes a new object — a drain in
      // flight would be disposed to change where the NEXT request goes.
      expect(identical(container.read(triageQueueProvider), triage), isTrue);
      expect(identical(container.read(aiWorkerProvider), worker), isTrue);
      expect(identical(container.read(storylineWorkerProvider), storyline),
          isTrue);
      expect(identical(container.read(draftWorkerProvider), drafts), isTrue);
      expect(identical(container.read(fastDrainGateProvider), gate), isTrue);
      expect(identical(container.read(activityLogProvider), activity), isTrue);
      expect(identical(container.read(progressBusProvider), progress), isTrue);
    });

    test('each lane has its own gate, and each is a singleton', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      final fast = container.read(fastDrainGateProvider);
      final storyline = container.read(storylineDrainGateProvider);
      final draft = container.read(draftDrainGateProvider);

      // One instance each, or a gate would serialize nothing — see [DrainGate].
      expect(identical(container.read(fastDrainGateProvider), fast), isTrue);
      expect(
          identical(container.read(storylineDrainGateProvider), storyline),
          isTrue);
      expect(identical(container.read(draftDrainGateProvider), draft), isTrue);

      // And three DIFFERENT ones, which is the whole of the split: the fast
      // lane shares its gate with the triage drain and nothing else, so a
      // recap or a draft can never sit in front of a new message's triage.
      expect(identical(fast, storyline), isFalse);
      expect(identical(fast, draft), isFalse);
      expect(identical(storyline, draft), isFalse);
    });

    test('the fast lane requeues the sweep after a drain that did work',
        () async {
      // The real wiring, not a hand-built worker: `_lane`'s `beforeWaking`
      // hook is what re-arms the sweep, and nothing else in the suite reads
      // the provider that carries it. The two lanes it wakes are replaced by
      // idle workers so this test starts no drain that would dial a server.
      final idleStoryline =
          AiWorker(store, handlers: const [], gate: DrainGate());
      final idleDraft = AiWorker(store, handlers: const [], gate: DrainGate());
      addTearDown(idleStoryline.dispose);
      addTearDown(idleDraft.dispose);
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          storylineWorkerProvider.overrideWithValue(idleStoryline),
          draftWorkerProvider.overrideWithValue(idleDraft),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      // The switch, which every launch starts OFF: this test is about what a
      // drain that RAN does next, and an off lane never reaches the hook.
      container.read(processingProvider.notifier).set(true);

      // An extraction for a message that is not there: the handler closes it
      // `skipped` before it reads a card, so the drain processes an item
      // without dialling anything.
      await store.enqueueWork('extract', 'email', 'gone');
      await container.read(aiWorkerProvider).pump();
      // `onDrained` schedules its own body rather than blocking the drain, so
      // the requeue lands a turn later.
      await pumpEventQueue();

      expect(await store.workCounts('storyline_sweep'), {'pending': 1});
    });

    test('the fast lane leaves the sweep alone after a drain that did nothing',
        () async {
      // The other half of the `lastDrainCount > 0` guard, and the common case:
      // `onDrained` fires after an EMPTY drain too, so an ungated requeue
      // would run a whole sweep after every idle pump. Same wiring as the test
      // above, same two idle lanes, and nothing enqueued.
      final idleStoryline =
          AiWorker(store, handlers: const [], gate: DrainGate());
      final idleDraft = AiWorker(store, handlers: const [], gate: DrainGate());
      addTearDown(idleStoryline.dispose);
      addTearDown(idleDraft.dispose);
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          storylineWorkerProvider.overrideWithValue(idleStoryline),
          draftWorkerProvider.overrideWithValue(idleDraft),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;
      // ON, as in the test above: an off lane would leave the sweep alone for
      // a reason that has nothing to do with the guard this is about.
      container.read(processingProvider.notifier).set(true);

      await container.read(aiWorkerProvider).pump();
      await pumpEventQueue();

      // No row of that kind at all — `workCounts` groups by status over the
      // rows that exist, so a sweep that was never queued is an empty map.
      expect(await store.workCounts('storyline_sweep'), isEmpty);
    });

    test('each lane drains exactly the kinds it owns', () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      // Literals and IN ORDER, not a derivation: moving a kind between lanes
      // must force an edit here, and therefore an edit to
      // docs/pipeline/10-model-routing.md. Nothing at runtime can otherwise be
      // asked which lane a kind is on.
      expect(container.read(aiWorkerProvider).kinds, [
        'needs_you',
        'extract',
        'embed_message',
        'attachment_text',
        'attachment_digest',
        'context_reconcile',
        'context_digest',
        'context_brief',
      ]);
      expect(container.read(storylineWorkerProvider).kinds, [
        'storyline',
        'storyline_sweep',
        'storyline_refresh',
        'storyline_audit',
        'storyline_recruit',
        'storyline_recap',
      ]);
      expect(container.read(draftWorkerProvider).kinds, ['draft']);

      // Nothing on the fast lane dials the 27B, which is the property T1
      // rests on — and nothing appears on two lanes.
      final all = [
        ...container.read(aiWorkerProvider).kinds,
        ...container.read(storylineWorkerProvider).kinds,
        ...container.read(draftWorkerProvider).kinds,
      ];
      expect(all.toSet(), hasLength(all.length));
    });

    test('every lane and the triage queue carry the processing switch',
        () async {
      // The wiring nothing else can be asked about: a lane built without the
      // `enabled` closure would run the moment anything pumped it, and the
      // switch at the top of the rail would be a control over nothing. The
      // switch defaults OFF, so a drain that took work here is a lane that
      // was wired without it.
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      expect(container.read(processingProvider), isFalse,
          reason: 'every launch starts off');

      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Launch date',
        'from_name': 'Sarah',
        'from_address': 'sarah@example.com',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Any word on the launch?',
        'triage_status': 'pending',
      });
      for (final (kind, id) in [
        ('extract', 'm1'),
        ('storyline_sweep', 'sweep'),
        ('draft', 'm1'),
      ]) {
        await store.enqueueWork(kind, 'email', id);
      }

      await container.read(triageQueueProvider).pump();
      await container.read(aiWorkerProvider).pump();
      await container.read(storylineWorkerProvider).pump();
      await container.read(draftWorkerProvider).pump();
      await pumpEventQueue();

      expect((await store.getMessageRow('email', 'm1'))!['triage_status'],
          'pending');
      expect(await store.workCounts('extract'), {'pending': 1});
      expect(await store.workCounts('storyline_sweep'), {'pending': 1});
      expect(await store.workCounts('draft'), {'pending': 1});
    });
  });
}
