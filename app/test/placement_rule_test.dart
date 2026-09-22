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

/// The placement rule: the GPU box as a DEFAULT rather than as stored rows.
///
/// `llm_targets_test.dart` owns the notifier's box API. What this file holds
/// is the rule itself and the three things it touches on the way past: which
/// target a stage resolves to with nothing stored, what happens to a Round G
/// install that has the old rows, and the two preferences the rule made
/// necessary — the address it derives from, and the processing switch that
/// only starts on because the default server is now the measured one.
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
  // A fictional string, and the only "key" anywhere in this file.
  const key = 'sk-fixture-not-a-real-box-key';

  /// What a fresh install on a build with a compiled address holds: the
  /// placement default resolved to the box, and the address to dial.
  const onBox = AppPrefs(modelPlacement: ModelPlacement.box, boxUrl: url);

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

  group('a fresh install on a build that names a box', () {
    test('routes the fourteen stages by role and stores nothing', () {
      expect(onBox.hasBox, isTrue);
      expect(onBox.effectiveBoxUrl, url);
      expect(onBox.stageTargets, isEmpty);

      for (final id in smallModelStageIds) {
        expect(onBox.targetIdForStage(id), boxBulkId, reason: id);
      }
      for (final id in bigModelStageIds) {
        expect(onBox.targetIdForStage(id), boxProseId, reason: id);
      }
      // Seven and six, so the two lists have not quietly grown.
      expect(smallModelStageIds, hasLength(7));
      expect(bigModelStageIds, hasLength(7));

      // The two that are not routed at all.
      expect(onBox.targetIdForStage('embeddings'), isNull);
      expect(onBox.targetIdForStage('draft_improve'), isNull);
    });

    test('offers the derived pair in the picker, once each', () {
      final ids = [for (final spec in onBox.allTargets) spec.id];
      expect(ids, [builtInFastId, builtInProseId, boxBulkId, boxProseId]);
      // A duplicate id is what makes the stage picker assert on its value.
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('a build that names no box is on this Mac, with no pair at all', () {
      const fresh = AppPrefs();
      expect(fresh.modelPlacement, ModelPlacement.local);
      expect(fresh.hasBox, isFalse);
      expect([for (final spec in fresh.allTargets) spec.id],
          [builtInFastId, builtInProseId]);
      expect(fresh.targetIdForStage('storyline_membership'), builtInFastId);
      expect(fresh.targetIdForStage('draft_reply'), builtInProseId);
    });
  });

  group('an override outranks the rule', () {
    test('picking the small model for the confirm stores an entry, and the '
        'big one clears it', () async {
      final prefs = await notifier(initial: onBox);

      await prefs.setStageTarget('storyline_membership', boxBulkId);
      expect(prefs.state.stageTargets, {'storyline_membership': boxBulkId});
      expect(prefs.state.targetIdForStage('storyline_membership'), boxBulkId);

      await prefs.setStageTarget('storyline_membership', boxProseId);
      expect(prefs.state.stageTargets, isEmpty,
          reason: 'back on the rule, so the map holds non-defaults only');
      expect(prefs.state.targetIdForStage('storyline_membership'), boxProseId);
    });

    test('the same two picks on this Mac mean the other way round', () async {
      final prefs = await notifier();

      // Here the confirm's default is the fast built-in, so THAT is the pick
      // that stores nothing.
      await prefs.setStageTarget('storyline_membership', builtInProseId);
      expect(prefs.state.stageTargets,
          {'storyline_membership': builtInProseId});
      await prefs.setStageTarget('storyline_membership', builtInFastId);
      expect(prefs.state.stageTargets, isEmpty);
    });
  });

  group('the placement round trip', () {
    test('this Mac and back: routing follows the placement, a user pick '
        'survives both, and the tier entries do not come along', () async {
      const own = LlmTargetSpec(
        id: 't-1a2b3c4d',
        name: 'Studio box',
        url: 'http://localhost:18100/v1/chat/completions',
        model: 'qwen3-27b-fp8',
      );
      final made = await notifier(
        initial: const AppPrefs(
          modelPlacement: ModelPlacement.box,
          boxUrl: url,
          targets: [own],
        ),
      );
      await made.setStageTarget('triage', 't-1a2b3c4d');

      // To this Mac, on a small machine: the tier writes its six prose picks,
      // membership goes to the small model by rule, and the user pick stays.
      await made.usePlacement(ModelPlacement.local,
          hardwareTier: MachineTier.inbox);
      expect(made.state.modelPlacement, ModelPlacement.local);
      expect(made.state.targetIdForStage('draft_reply'), builtInFastId);
      expect(made.state.targetIdForStage('storyline_membership'),
          builtInFastId);
      expect(made.state.targetIdForStage('triage'), 't-1a2b3c4d');
      expect(made.state.draftPolicy, tierDraftPolicy(MachineTier.inbox));

      // And back: the tier's entries are dropped, the rule answers again, the
      // user pick is still the user's, and drafts are worth prefetching.
      await made.usePlacement(ModelPlacement.box,
          hardwareTier: MachineTier.inbox);
      expect(made.state.modelPlacement, ModelPlacement.box);
      expect(made.state.targetIdForStage('draft_reply'), boxProseId);
      expect(made.state.targetIdForStage('storyline_membership'), boxProseId);
      expect(made.state.targetIdForStage('triage'), 't-1a2b3c4d');
      expect(made.state.stageTargets.keys, ['triage']);
      expect(made.state.draftPolicy, DraftPolicy.needsYou);
    });
  });

  group('the draft lane', () {
    test('is four wide on the box and prose_parallel wide here', () async {
      expect(onBox.specForStage('draft_reply')!.parallel, 4);

      const here = AppPrefs(proseParallel: 2);
      expect(here.specForStage('draft_reply')!.parallel, 2);
    });

    test('a gated draft falls back to the box, not to a dead local port',
        () async {
      const bedrock = LlmTargetSpec(
        id: 'cloud-1',
        name: 'Cloud prose',
        url: 'https://bedrock-runtime.example.com',
        model: 'us.example.big-model',
        wire: LlmWire.bedrockConverse,
      );
      const gated = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxUrl: url,
        targets: [bedrock],
        stageTargets: {'draft_reply': 'cloud-1', 'draft_improve': 'cloud-1'},
      );

      // Without consent the third-party pick is refused, and what takes its
      // place has to be somewhere the work can actually run: before Round H
      // this was the local prose target, on a machine whose local servers are
      // not started.
      expect(gated.specForStage('draft_reply')!.id, boxProseId);
      expect(gated.draftFallbackSpec.id, boxProseId);
      // The optional stage still resolves to nothing, which is the feature
      // being off rather than being redirected.
      expect(gated.specForStage('draft_improve'), isNull);

      // On this Mac the fallback is what it always was.
      const local = AppPrefs(
        targets: [bedrock],
        stageTargets: {'draft_reply': 'cloud-1'},
      );
      expect(local.specForStage('draft_reply')!.id, builtInProseId);
    });
  });

  group('the bearer load-order window', () {
    test('a stage resolved before ready carries no key and says so', () async {
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$boxBulkId': key,
      });
      final prefs = AppPrefsNotifier(store, tokens: tokens, initial: onBox);
      addTearDown(prefs.dispose);

      // Inside the window: the prefetch is a keychain round trip and the
      // supervisor's first pump can beat it. What must not happen is a spec
      // that claims a key it does not hold, because that is one
      // unauthenticated request per stage.
      expect(prefs.state.boxKeyStored, isFalse);
      expect(prefs.state.specForStage('triage')!.hasBearer, isFalse);
      expect(prefs.targetForStage('triage').bearer, isNull);

      await prefs.ready;

      expect(prefs.state.boxKeyStored, isTrue);
      expect(prefs.state.specForStage('triage')!.hasBearer, isTrue);
      expect(prefs.targetForStage('triage').bearer, key);
      expect(prefs.targetForStage('draft_reply').bearer, key);
      // Still nowhere near a preference.
      final rows = await db.customSelect('SELECT value FROM app_prefs').get();
      for (final row in rows) {
        expect(row.read<String>('value'), isNot(contains(key)));
      }
    });
  });

  group('the Round G migration', () {
    /// An install that pressed Round G's Adopt button: two rows, the fifteen
    /// stage entries both presets wrote, and the placement.
    Future<void> seedRoundG({String base = url}) async {
      await store.setPref(
        llmTargetsKey,
        jsonEncode([
          {
            'id': boxProseId,
            'name': boxProseName,
            'url': '$base/prose/v1/chat/completions',
            'model': boxProseModel,
            'wire': 'openAi',
            'bearer': true,
            'parallel': 4,
            'streams': true,
          },
          {
            'id': boxBulkId,
            'name': boxBulkName,
            'url': '$base/bulk/v1/chat/completions',
            'model': boxBulkModel,
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
          for (final id in smallModelStageIds) id: boxBulkId,
          for (final id in bigModelStageIds) id: boxProseId,
          'draft_improve': 'gpu-1',
        }),
      );
      await store.setPref(modelPlacementKey, ModelPlacement.box.name);
    }

    test('lifts the address, drops the pair and drops the fifteen entries',
        () async {
      await seedRoundG();

      final prefs = await AppPrefsNotifier.read(store);

      expect(prefs.boxUrl, url);
      expect(prefs.hasBox, isTrue);
      expect(prefs.modelPlacement, ModelPlacement.box);
      // The pair is derived now, so the rows are gone and the ids appear once.
      expect([for (final spec in prefs.targets) spec.id], ['gpu-1']);
      expect(
        [for (final spec in prefs.allTargets) spec.id],
        [builtInFastId, builtInProseId, boxBulkId, boxProseId, 'gpu-1'],
      );
      // Every entry the presets wrote now equals what the rule answers, so
      // none of them is stored; the one the owner chose is untouched.
      expect(prefs.stageTargets, {'draft_improve': 'gpu-1'});
      // And routing is unchanged by all of it.
      expect(prefs.targetIdForStage('triage'), boxBulkId);
      expect(prefs.targetIdForStage('storyline_membership'), boxProseId);
      expect(prefs.targetIdForStage('draft_improve'), 'gpu-1');
    });

    test('leaves the keychain alone, so nobody types the key again', () async {
      await seedRoundG();
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$boxBulkId': key,
      });

      final prefs = await notifier(tokens: tokens);

      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(prefs.state.boxKeyStored, isTrue);
      expect(prefs.targetForStage('triage').bearer, key);
    });

    test('runs at most once, and a second read changes nothing', () async {
      await seedRoundG();
      await AppPrefsNotifier.read(store);
      expect(await store.getPref(boxTargetsDerivedKey), '1');

      // A pair written back by hand after the flag is set is left where it
      // is: the migration is one-shot, and `_targets` is what keeps it out of
      // `allTargets` from then on.
      final owner = await store.getPref(llmTargetsKey);
      await store.setPref(stageTargetsKey, jsonEncode({'triage': boxBulkId}));

      final again = await AppPrefsNotifier.read(store);

      expect(await store.getPref(llmTargetsKey), owner);
      expect(again.stageTargets, {'triage': boxBulkId},
          reason: 'the second read must not prune a map again');
    });

    test('a fresh install writes the flag and nothing else', () async {
      final prefs = await AppPrefsNotifier.read(store);

      expect(await store.getPref(boxTargetsDerivedKey), '1');
      expect(await store.getPref(boxUrlKey), isNull);
      expect(await store.getPref(llmTargetsKey), isNull);
      expect(prefs.boxUrl, isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.local);
    });

    test('a row with no recoverable origin leaves the address empty',
        () async {
      // The only way `boxBaseFromProseUrl` answers nothing is a row somebody
      // hand-edited. The rows still go, because a stored pair would shadow
      // the derived one; the address stays empty, which reads as "follow the
      // build", and with no build address there is no box.
      await store.setPref(
        llmTargetsKey,
        jsonEncode([
          {
            'id': boxProseId,
            'name': boxProseName,
            'url': 'https://box.example.com/somewhere/else',
            'model': boxProseModel,
          },
        ]),
      );

      final prefs = await AppPrefsNotifier.read(store);

      expect(prefs.boxUrl, isEmpty);
      expect(prefs.hasBox, isFalse);
      expect(prefs.targets, isEmpty);
    });

    test('the flag is a plain pref, not one of the derived one-shots',
        () async {
      // `derivedOneShotPrefs` is what `wipeAll` and `clearDerived` delete so a
      // walk runs again over a corpus they emptied. This flag guards no
      // corpus, and a wipe leaves no rows to migrate.
      expect(MessageStore.derivedOneShotPrefs, isNot(contains(
        boxTargetsDerivedKey,
      )));

      await seedRoundG();
      await AppPrefsNotifier.read(store);
      await store.wipeAll();

      expect(await store.getPref(boxTargetsDerivedKey), '1');
      expect(await store.getPref(boxUrlKey), url);
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
