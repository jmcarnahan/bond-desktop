import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// The routing RULE: three roles, one target each, and nothing stored.
///
/// `llm_targets_test.dart` owns the notifier's writers. What this file holds
/// is the rule itself — which target a stage resolves to on each placement —
/// and two things it touches on the way past: what the older one-shot
/// migrations still do to a Round G install, and the processing switch that
/// only starts on because the default server is the measured one.
///
/// `boxUrlDefault` is empty under `flutter test`, so every case that wants the
/// box says so, by constructing an [AppPrefs] with an address or by writing
/// one to its store.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  const url = 'https://box.example.com';
  const bigUrl = '$url/prose/v1/chat/completions';
  // A fictional string, and the only "key" anywhere in this file.
  const key = 'sk-fixture-not-a-real-box-key';

  /// The generative model on the owner's server, at a stored address.
  const onBox = AppPrefs(
    modelPlacement: ModelPlacement.box,
    boxBigUrl: bigUrl,
  );

  Future<AppPrefsNotifier> notifier({
    MemoryTokenStore? tokens,
    AppPrefs? initial,
  }) async {
    final made = AppPrefsNotifier(
      store,
      tokens: tokens ?? MemoryTokenStore(),
      initial: initial,
    );
    addTearDown(made.dispose);
    await made.ready;
    return made;
  }

  /// Every stage that makes a text call: the generative role.
  final generativeStages = [
    for (final stage in pipelineStages)
      if (stage.slot == ModelSlot.generative) stage.id,
  ];

  group('every text stage is the one generative model', () {
    test('managed on the full tier: the 27B on the router', () {
      const prefs = AppPrefs(modelPlacement: ModelPlacement.local);
      for (final id in generativeStages) {
        final spec = prefs.specForStage(id)!;
        expect(spec.id, localGenerativeId, reason: id);
        expect(spec.name, 'This Mac · generative', reason: id);
        expect(spec.url, 'http://127.0.0.1:8080/v1/chat/completions');
        expect(spec.model, routerProseId, reason: id);
      }
      // Thirteen (triage and extraction became message_text, and the reply
      // decision became the decision model's), so the list has not quietly
      // shrunk.
      expect(generativeStages, hasLength(13));
    });

    test('managed on the inbox tier: the 4B', () {
      const prefs = AppPrefs(
        modelPlacement: ModelPlacement.local,
        machineTier: MachineTier.inbox,
      );
      for (final id in generativeStages) {
        expect(prefs.specForStage(id)!.model, routerBulkId, reason: id);
      }
    });

    test('your server with a stored address: box-prose, one at a time', () {
      for (final id in generativeStages) {
        final spec = onBox.specForStage(id)!;
        expect(spec.id, boxProseId, reason: id);
        expect(spec.name, 'Your server · generative', reason: id);
        expect(spec.url, bigUrl, reason: id);
        expect(spec.model, boxProseModel, reason: id);
        // A stored address is one request at a time: a one-slot llama-server
        // would queue the rest past the prose client's ceiling. (Four wide is
        // for an address that FOLLOWS the build, which `flutter test` cannot
        // construct: `boxUrlDefault` is empty here.)
        expect(spec.parallel, 1, reason: id);
      }
    });

    test('your server with no address to dial is this Mac', () {
      // No compiled address and none stored: the placement cannot be honoured,
      // and a target nothing can reach would park every lane.
      const prefs = AppPrefs(modelPlacement: ModelPlacement.box);
      expect(prefs.hasGenerativeServer, isFalse);
      for (final id in generativeStages) {
        expect(prefs.specForStage(id)!.id, localGenerativeId, reason: id);
      }
    });

    test('hand-started servers: the compiled prose server', () {
      const prefs = AppPrefs(managedServer: false);
      for (final id in generativeStages) {
        final spec = prefs.specForStage(id)!;
        expect(spec.id, localGenerativeId, reason: id);
        expect(spec.url, proseUrlDefault, reason: id);
        expect(spec.model, proseModelDefault, reason: id);
      }
    });

    test('the confirm is plain generative, on either placement', () {
      // It was the one stage whose role depended on the placement.
      expect(onBox.specForStage('storyline_membership')!.id, boxProseId);
      expect(const AppPrefs().specForStage('storyline_membership')!.id,
          localGenerativeId);
      expect(onBox.specForStage('storyline_membership'),
          onBox.specForStage('message_text'));
    });

    test('the discovered model name is asked for, and the wire read off the '
        'host', () {
      const named = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxBigUrl: bigUrl,
        boxBigModel: 'qwen3.8-mlx',
      );
      expect(named.generativeSpec.model, 'qwen3.8-mlx');
      expect(named.generativeSpec.wire, LlmWire.openAi);
    });

    test('a hand-edited third-party generative address is never dialled', () {
      // The writer refuses one and the migration moves one; this is the belt
      // at resolution, for a row somebody typed into the table.
      for (final url in [
        'https://api.openai.com/v1/chat/completions',
        'https://bedrock-runtime.us-east-2.amazonaws.com/openai/v1/chat/completions',
      ]) {
        final prefs =
            AppPrefs(modelPlacement: ModelPlacement.box, boxBigUrl: url);
        expect(prefs.generativeSpec.id, localGenerativeId, reason: url);
      }
    });

    test('the width is the drafts-in-flight setting here', () {
      expect(const AppPrefs(proseParallel: 2).specForStage('draft_reply')!
          .parallel, 2);
      expect(onBox.specForStage('draft_reply')!.parallel, 1);
    });
  });

  group('the decision stage is the decision model', () {
    test('this Mac by default, whatever the generative placement', () {
      for (final prefs in [const AppPrefs(), onBox]) {
        final spec = prefs.specForStage('decision')!;
        expect(spec.id, localDecisionId);
        expect(spec.name, 'This Mac · decision');
        expect(spec.url, 'http://127.0.0.1:8080/v1/embeddings');
        expect(spec.model, routerDecideId);
      }
    });

    test('your server when the decision placement says so and an address '
        'exists', () {
      const prefs = AppPrefs(
        decisionPlacement: ModelPlacement.box,
        decisionUrl: '$url/decide/v1/embeddings',
      );
      final spec = prefs.specForStage('decision')!;
      expect(spec.id, boxDecideId);
      expect(spec.name, 'Your server · decision');
      expect(spec.url, '$url/decide/v1/embeddings');
      expect(spec.model, boxDecideModel);
      // And the text stages are untouched by it.
      expect(prefs.specForStage('message_text')!.id, localGenerativeId);
    });

    test('your server with no address is this Mac', () {
      const prefs = AppPrefs(decisionPlacement: ModelPlacement.box);
      expect(prefs.hasDecisionServer, isFalse);
      expect(prefs.specForStage('decision')!.id, localDecisionId);
    });

    test('hand-started: the make decide server', () {
      const prefs = AppPrefs(managedServer: false);
      expect(prefs.specForStage('decision')!.url, decideUrlDefault);
      expect(prefs.specForStage('decision')!.model, decideModelDefault);
    });

    test('embeddings are not routed at all', () async {
      expect(const AppPrefs().specForStage('embeddings'), isNull);
      final prefs = await notifier();
      expect(prefs.targetForStage('embeddings'),
          prefs.state.embedRequestTarget);
    });
  });

  group('the draft stages and cloud drafts', () {
    const vendor = 'https://api.openai.com/v1/chat/completions';
    const own = 'https://drafts.example.com/v1/chat/completions';

    test('no cloud drafts: the drafts are generative like everything else', () {
      for (final id in draftStageIds) {
        expect(onBox.specForStage(id)!.id, boxProseId, reason: id);
      }
    });

    test('a third-party target without consent: drafts stay generative', () {
      const prefs = AppPrefs(cloudDraftsUrl: vendor, cloudDraftsModel: 'gpt');
      expect(prefs.cloudDraftsSpec!.isThirdParty, isTrue);
      for (final id in draftStageIds) {
        expect(prefs.specForStage(id)!.id, localGenerativeId, reason: id);
      }
    });

    test('with consent: the two draft stages and nothing else', () {
      const prefs = AppPrefs(
        cloudDraftsUrl: vendor,
        cloudDraftsModel: 'gpt',
        cloudDraftsConsent: true,
      );
      for (final id in draftStageIds) {
        final spec = prefs.specForStage(id)!;
        expect(spec.id, cloudDraftsId, reason: id);
        expect(spec.name, 'Cloud drafts');
        expect(spec.model, 'gpt');
      }
      for (final id in generativeStages) {
        if (draftStageIds.contains(id)) continue;
        expect(prefs.specForStage(id)!.id, localGenerativeId, reason: id);
      }
      expect(prefs.specForStage('decision')!.id, localDecisionId);
    });

    test('the owner\'s own host needs no consent', () {
      const prefs = AppPrefs(cloudDraftsUrl: own, cloudDraftsModel: 'mine');
      expect(prefs.cloudDraftsSpec!.isThirdParty, isFalse);
      expect(prefs.specForStage('draft_reply')!.id, cloudDraftsId);
    });

    test('a Bedrock target speaks Converse and is third party', () {
      const prefs = AppPrefs(
        cloudDraftsUrl: 'https://bedrock-runtime.us-east-2.amazonaws.com',
        cloudDraftsModel: 'us.example.big-model',
      );
      expect(prefs.cloudDraftsSpec!.wire, LlmWire.bedrockConverse);
      expect(prefs.specForStage('draft_reply')!.id, localGenerativeId);
    });
  });

  group('specById', () {
    test('answers the current fixed specs by id, and nothing else', () {
      const prefs = AppPrefs(
        cloudDraftsUrl: 'https://drafts.example.com/v1/chat/completions',
        cloudDraftsModel: 'mine',
      );
      expect(prefs.specById(localGenerativeId), prefs.generativeSpec);
      expect(prefs.specById(localDecisionId), prefs.decisionSpec);
      expect(prefs.specById(cloudDraftsId), prefs.cloudDraftsSpec);
      // Not the current generative target, so not answered.
      expect(prefs.specById(boxProseId), isNull);
      expect(onBox.specById(boxProseId)!.url, bigUrl);
      expect(prefs.specById('box-bulk'), isNull);
      expect(prefs.specById('nope'), isNull);
      expect(const AppPrefs().specById(cloudDraftsId), isNull);
    });
  });

  group('the bearer load-order window', () {
    test('a stage resolved before ready carries no key and says so', () async {
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
      });
      final prefs = AppPrefsNotifier(store, tokens: tokens, initial: onBox);
      addTearDown(prefs.dispose);

      // Inside the window: the prefetch is a keychain round trip and the
      // supervisor's first pump can beat it. What must not happen is a spec
      // that claims a key it does not hold, because that is one
      // unauthenticated request per stage.
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.state.specForStage('message_text')!.hasBearer, isFalse);
      expect(prefs.targetForStage('message_text').bearer, isNull);

      await prefs.ready;

      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.state.specForStage('message_text')!.hasBearer, isTrue);
      expect(prefs.targetForStage('message_text').bearer, key);
      expect(prefs.targetForStage('draft_reply').bearer, key);
      // The decision model runs here, so the generative key never rides it.
      expect(prefs.targetForStage('decision').bearer, isNull);
      // Still nowhere near a preference.
      final rows = await db.customSelect('SELECT value FROM app_prefs').get();
      for (final row in rows) {
        expect(row.read<String>('value'), isNot(contains(key)));
      }
    });
  });

  group('the Round G migration', () {
    /// Round H's small-model id, written here as the literal it was: the
    /// constant went with the small model.
    const boxBulk = 'box-bulk';

    /// An install that pressed Round G's Adopt button: two rows, the stage
    /// entries both presets wrote, and the placement.
    Future<void> seedRoundG({String base = url}) async {
      await store.setPref(
        llmTargetsKey,
        jsonEncode([
          {
            'id': boxProseId,
            'name': 'Your server · big model',
            'url': '$base/prose/v1/chat/completions',
            'model': boxProseModel,
            'wire': 'openAi',
            'bearer': true,
            'parallel': 4,
            'streams': true,
          },
          {
            'id': boxBulk,
            'name': 'Your server · small model',
            'url': '$base/bulk/v1/chat/completions',
            'model': 'qwen3-4b',
            'wire': 'openAi',
            'bearer': true,
            'parallel': 4,
            'streams': true,
          },
          {
            'id': 'gpu-1',
            'name': 'A server the owner added',
            'url': 'http://localhost:18100/v1/chat/completions',
            'model': 'qwen3.8',
          },
        ]),
      );
      await store.setPref(
        stageTargetsKey,
        jsonEncode({
          'triage': boxBulk,
          'draft_reply': boxProseId,
          'draft_improve': 'gpu-1',
        }),
      );
      await store.setPref(modelPlacementKey, ModelPlacement.box.name);
    }

    test('lifts the address into the generative remote, drops the rows and '
        'empties the map', () async {
      await seedRoundG();

      final prefs = await AppPrefsNotifier.read(store);

      // The origin is split in two by the migration that follows this one;
      // the big half IS the generative remote, and the small half is inert.
      expect(prefs.boxBigUrl, '$url/prose/v1/chat/completions');
      expect(await store.getPref(boxSmallUrlKey),
          '$url/bulk/v1/chat/completions');
      expect(await store.getPref(boxUrlKey), isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.box);
      // The box rows are gone, the owner's own row is left, inert.
      final rows = jsonDecode((await store.getPref(llmTargetsKey))!) as List;
      expect([for (final row in rows) (row as Map)['id']], ['gpu-1']);
      // And the map is EMPTY: nothing routes through it any more.
      expect(await store.getPref(stageTargetsKey), isEmpty);
      // Routing is the rule.
      expect(prefs.specForStage('message_text')!.id, boxProseId);
      expect(prefs.specForStage('draft_improve')!.id, boxProseId);
    });

    test('the four one-shots run in order, and each runs once', () async {
      await seedRoundG();

      await AppPrefsNotifier.read(store);

      expect(await store.getPref(boxTargetsDerivedKey), '1');
      expect(await store.getPref(boxServersDerivedKey), '1');
      expect(await store.getPref(stageTargetsClearedKey), '1');
      // An own-host big address is the one shape the role split leaves alone.
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);

      // A map written after the flags are set is left alone: no migration
      // comes back for it (and nothing reads it).
      await store.setPref(stageTargetsKey, jsonEncode({'triage': boxProseId}));
      await AppPrefsNotifier.read(store);
      expect(await store.getPref(stageTargetsKey),
          jsonEncode({'triage': boxProseId}));
    });

    test('the split is a no-op for an install that follows the build',
        () async {
      final prefs = await AppPrefsNotifier.read(store);

      expect(await store.getPref(boxServersDerivedKey), '1');
      expect(await store.getPref(boxBigUrlKey), isNull);
      expect(prefs.boxBigUrl, isEmpty);
    });

    test('leaves the keychain alone, so nobody types the key again', () async {
      await seedRoundG();
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$boxBulk': key,
      });

      final prefs = await notifier(tokens: tokens);

      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.targetForStage('message_text').bearer, key);
    });

    test('a fresh install writes the flags and nothing else', () async {
      final prefs = await AppPrefsNotifier.read(store);

      expect(await store.getPref(boxTargetsDerivedKey), '1');
      expect(await store.getPref(boxUrlKey), isNull);
      expect(await store.getPref(llmTargetsKey), isNull);
      expect(prefs.boxBigUrl, isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.local);
    });

    test('a row with no recoverable origin leaves the address empty',
        () async {
      await store.setPref(
        llmTargetsKey,
        jsonEncode([
          {
            'id': boxProseId,
            'name': 'Your server · big model',
            'url': 'https://box.example.com/somewhere/else',
            'model': boxProseModel,
          },
        ]),
      );

      final prefs = await AppPrefsNotifier.read(store);

      expect(prefs.boxBigUrl, isEmpty);
      expect(prefs.hasGenerativeServer, isFalse);
      expect(await store.getPref(llmTargetsKey), '[]');
    });

    test('the flags are plain prefs, not derived one-shots', () async {
      // `derivedOneShotPrefs` is what `wipeAll` and `clearDerived` delete so a
      // walk runs again over a corpus they emptied. These guard no corpus,
      // and a wipe leaves no rows to migrate.
      for (final key in [
        boxTargetsDerivedKey,
        boxServersDerivedKey,
        stageTargetsClearedKey,
        modelRolesDerivedKey,
      ]) {
        expect(MessageStore.derivedOneShotPrefs, isNot(contains(key)));
      }

      await seedRoundG();
      await AppPrefsNotifier.read(store);
      await store.wipeAll();

      expect(await store.getPref(boxTargetsDerivedKey), '1');
      expect(await store.getPref(boxServersDerivedKey), '1');
      expect(await store.getPref(stageTargetsClearedKey), '1');
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
      expect(await store.getPref(boxBigUrlKey),
          '$url/prose/v1/chat/completions');
    });
  });

  group('the processing preference', () {
    test('starts on, and only the one spelling reads as off', () async {
      expect(const AppPrefs().processingOn, isTrue);
      expect((await AppPrefsNotifier.read(store)).processingOn, isTrue);

      for (final raw in ['true', 'yes', '', 'nonsense']) {
        await store.setPref(processingOnKey, raw);
        expect((await AppPrefsNotifier.read(store)).processingOn, isTrue,
            reason: raw);
      }
      await store.setPref(processingOnKey, 'false');
      expect((await AppPrefsNotifier.read(store)).processingOn, isFalse);
    });

    test('the setter round-trips, and it survives a wipe', () async {
      final prefs = await notifier();

      await prefs.setProcessingOn(false);
      expect(prefs.state.processingOn, isFalse);
      expect(await store.getPref(processingOnKey), 'false');

      await store.wipeAll();
      // Machine configuration like the placement beside it: standing the
      // models down is a fact about this Mac, not about who is signed in.
      expect((await AppPrefsNotifier.read(store)).processingOn, isFalse);
    });

    test('it seeds the session switch, and a bare notifier is still off',
        () async {
      await store.setPref(processingOnKey, 'false');
      final off = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider
            .overrideWithValue(await AppPrefsNotifier.read(store)),
      ]);
      addTearDown(off.dispose);
      expect(off.read(processingProvider), isFalse);

      await store.setPref(processingOnKey, 'true');
      final on = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider
            .overrideWithValue(await AppPrefsNotifier.read(store)),
      ]);
      addTearDown(on.dispose);
      expect(on.read(processingProvider), isTrue);

      // The two test overrides that construct it bare mean OFF, whatever the
      // preferences hold, and the parameter stays positional for them.
      expect(ProcessingNotifier().state, isFalse);
      expect(ProcessingNotifier(true).state, isTrue);
    });
  });
}
