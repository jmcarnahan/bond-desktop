import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// Targets as DATA: the list, the stage map, the consent, and the one secret.
///
/// Three prefs and a keychain prefix carry the whole of Round E's routing.
/// The claims this file exists to hold are the ones a screen cannot: that the
/// two built-in targets are DERIVED from the four slot prefs rather than
/// copied, so a fresh install resolves byte-identically to the two-slot app;
/// that a bearer token reaches the keychain and NEVER `app_prefs`; that a
/// malformed row costs itself and not the launch; and that the consent rule is
/// enforced where the target is resolved, not only where it is picked.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// A notifier over the real store, with the keychain in a map.
  Future<AppPrefsNotifier> notifier([MemoryTokenStore? tokens]) async {
    final made = AppPrefsNotifier(store, tokens: tokens ?? MemoryTokenStore());
    addTearDown(made.dispose);
    await made.ready;
    return made;
  }

  const box = LlmTargetSpec(
    id: 'gpu-1',
    name: 'GPU box',
    url: 'http://localhost:18100/v1/chat/completions',
    model: 'qwen3.8',
    parallel: 4,
  );

  const bedrock = LlmTargetSpec(
    id: 'cloud-1',
    name: 'Cloud prose',
    url: 'https://bedrock-runtime.example.com',
    model: 'us.example.big-model',
    wire: LlmWire.bedrockConverse,
  );

  /// The same third-party rule reached the other way: the OpenAI wire, on a
  /// host under one of the four domains.
  const cloudOnOpenAi = LlmTargetSpec(
    id: 'cloud-2',
    name: 'Cloud compatible',
    url: 'https://bedrock-runtime.us-east-2.amazonaws.com/openai/v1/'
        'chat/completions',
    model: 'us.example.big-model',
  );

  /// Every value in `app_prefs`, which is where a leaked secret would be.
  Future<List<String>> prefValues() async {
    final rows = await db.customSelect('SELECT value FROM app_prefs').get();
    return [for (final row in rows) row.read<String>('value')];
  }

  group('the target list', () {
    test('a spec round-trips through app_prefs', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      expect(prefs.state.targets, [box]);

      // Read back cold, the way a relaunch does.
      final fresh = await AppPrefsNotifier.read(store);
      expect(fresh.targets, [box]);
      expect(fresh.targets.single.parallel, 4);
      expect(fresh.targets.single.wire, LlmWire.openAi);
      expect(fresh.targets.single.streams, isTrue);
    });

    test('the built-ins are derived, not stored', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      // First, and in the same order every screen renders them.
      expect(
        prefs.state.allTargets.map((spec) => spec.id),
        [builtInFastId, builtInProseId, 'gpu-1'],
      );
      // And the table holds only the one the user added.
      final stored = jsonDecode((await store.getPref(llmTargetsKey))!) as List;
      expect(stored, hasLength(1));
      expect((stored.single as Map)['id'], 'gpu-1');
    });

    test('the built-ins follow the slot prefs they are made of', () async {
      final prefs = await notifier();
      expect(prefs.state.fastSpec.url, fastSlotDefault.baseUrl);
      expect(prefs.state.proseSpec.url, proseSlotDefault.baseUrl);

      await prefs.setFastLlmTarget(
        url: 'http://127.0.0.1:9/v1/chat/completions',
        model: 'mlx-4b',
      );

      // ONE source of truth: the editor writes the slot pref and the built-in
      // spec is a second view of it, not a copy that could drift.
      expect(prefs.state.fastSpec.url, 'http://127.0.0.1:9/v1/chat/completions');
      expect(prefs.state.fastSpec.model, 'mlx-4b');
      expect(prefs.state.fastSpec.id, builtInFastId);
    });

    test('the prose built-in carries the drafts-in-flight width', () async {
      final prefs = await notifier();
      expect(prefs.state.proseSpec.parallel, AppPrefs.defaultProseParallel);
      expect(prefs.state.specForStage('draft_reply')!.parallel, 1);

      await prefs.setProseParallel(4);

      expect(prefs.state.specForStage('draft_reply')!.parallel, 4);
    });

    test('a built-in id cannot be added or removed', () async {
      final prefs = await notifier();

      expect(
        () => prefs.upsertTarget(
          const LlmTargetSpec(
            id: builtInProseId,
            name: 'Impostor',
            url: 'http://example.com/v1',
            model: 'm',
          ),
        ),
        throwsArgumentError,
      );

      await prefs.removeTarget(builtInFastId);
      await prefs.removeTarget(builtInProseId);
      expect(prefs.state.allTargets.map((spec) => spec.id),
          [builtInFastId, builtInProseId]);
    });

    test('an upsert replaces by id rather than appending', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.upsertTarget(box.copyWith(name: 'The box', model: 'qwen3-4b'));

      expect(prefs.state.targets, hasLength(1));
      expect(prefs.state.targets.single.name, 'The box');
      expect(prefs.state.targets.single.model, 'qwen3-4b');
    });

    test('a width outside the range is clamped on the way in', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(
        const LlmTargetSpec(
          id: 'wide',
          name: 'Wide',
          url: 'http://example.com/v1/chat/completions',
          model: 'm',
          parallel: 64,
        ),
      );

      expect(prefs.state.targets.single.parallel, 8);
    });

    test('removing a target takes its stage entries with it', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.setStageTarget('triage', 'gpu-1');
      await prefs.setStageTarget('draft_reply', 'gpu-1');
      expect(prefs.state.stageTargets, hasLength(2));

      await prefs.removeTarget('gpu-1');

      // Not left to resolve as a default: a stale entry would silently
      // re-point those stages the day an id came back.
      expect(prefs.state.stageTargets, isEmpty);
      expect(await store.getPref(stageTargetsKey), '{}');
      expect(prefs.state.targets, isEmpty);
      expect(prefs.targetForStage('triage'), prefs.state.fastTarget);
    });
  });

  group('the bearer', () {
    test('goes to the keychain and never to app_prefs', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);

      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      expect(tokens.values['${llmTargetBearerKeyPrefix}gpu-1'],
          'sk-fixture-not-a-real-token');
      for (final value in await prefValues()) {
        expect(value, isNot(contains('sk-fixture-not-a-real-token')));
      }
      // What the table DOES carry is the presence flag.
      expect(prefs.state.targets.single.hasBearer, isTrue);
      final stored = jsonDecode((await store.getPref(llmTargetsKey))!) as List;
      expect((stored.single as Map)['bearer'], isTrue);
    });

    test('rides the resolved target, and nothing else does', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');
      await prefs.setStageTarget('draft_reply', 'gpu-1');

      final target = prefs.targetForStage('draft_reply');
      expect(target.bearer, 'sk-fixture-not-a-real-token');
      // Not in the string anything logs.
      expect(target.toString(), isNot(contains('sk-fixture')));
      // And a stage pointed at a target with no token carries none.
      expect(prefs.targetForStage('triage').bearer, isNull);
    });

    test('is prefetched before ready completes', () async {
      final tokens = MemoryTokenStore();
      await (await notifier(tokens))
          .upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      // A fresh notifier over the same store, the way a relaunch builds one.
      final relaunched = AppPrefsNotifier(store, tokens: tokens);
      addTearDown(relaunched.dispose);
      await relaunched.ready;

      // Synchronous by the time anything resolves a target: the resolver runs
      // on a drain's hot path and the keychain is not synchronous.
      await relaunched.setStageTarget('draft_reply', 'gpu-1');
      expect(relaunched.targetForStage('draft_reply').bearer,
          'sk-fixture-not-a-real-token');
      expect(tokens.reads, ['${llmTargetBearerKeyPrefix}gpu-1']);
    });

    test('nothing is read when no target claims one', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.upsertTarget(box);

      final relaunched = AppPrefsNotifier(store, tokens: tokens);
      addTearDown(relaunched.dispose);
      await relaunched.ready;

      // Every fresh install, and every existing one: the keychain is not
      // touched at all.
      expect(tokens.reads, isEmpty);
    });

    test('an edit that sends no token keeps the stored one', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      // What the edit screen sends back: the spec as it stands, with
      // `hasBearer` true and no secret, because it can show "set" and cannot
      // show the value.
      await prefs.upsertTarget(
        prefs.state.targets.single.copyWith(name: 'Renamed'),
      );

      expect(tokens.values['${llmTargetBearerKeyPrefix}gpu-1'],
          'sk-fixture-not-a-real-token');
      expect(prefs.state.targets.single.hasBearer, isTrue);
      expect(prefs.targetForStage('draft_reply'), isNotNull);
    });

    test('clearing the flag deletes it', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      await prefs.upsertTarget(box.copyWith(hasBearer: false));

      expect(tokens.values, isEmpty);
      expect(prefs.state.targets.single.hasBearer, isFalse);
    });

    test('a removed target loses its keychain entry', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      await prefs.removeTarget('gpu-1');

      expect(tokens.values, isEmpty);
    });

    test('a keychain that refuses costs the header, not the write', () async {
      final prefs = AppPrefsNotifier(store, tokens: RefusingTokenStore());
      addTearDown(prefs.dispose);
      await prefs.ready;

      await prefs.upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      // The spec landed, so the target is in the list and the user can see
      // which half did not stick.
      expect(prefs.state.targets, hasLength(1));
      expect(await store.getPref(llmTargetsKey), isNotNull);
    });

    test('a launch survives a keychain that refuses the prefetch', () async {
      await (await notifier())
          .upsertTarget(box, bearer: 'sk-fixture-not-a-real-token');

      final relaunched = AppPrefsNotifier(store, tokens: RefusingTokenStore());
      addTearDown(relaunched.dispose);

      await relaunched.ready;
      expect(relaunched.state.targets, hasLength(1));
      expect(relaunched.targetForStage('draft_reply').bearer, isNull);
    });
  });

  group('the stage map', () {
    test('an unset stage resolves exactly as it did before targets', () async {
      final prefs = await notifier();

      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.targetForStage('triage'), prefs.state.fastTarget);
      expect(prefs.targetForStage('draft_reply'), prefs.state.proseTarget);
      expect(prefs.state.targetIdForStage('triage'), builtInFastId);
      expect(prefs.state.targetIdForStage('storyline_name'), builtInProseId);

      await prefs.setFastLlmTarget(
        url: 'http://127.0.0.1:9/v1/chat/completions',
        model: 'mlx-4b',
      );

      // And still, after the slot moved: the default IS the slot.
      expect(prefs.targetForStage('triage'), prefs.state.fastTarget);
      expect(prefs.targetForStage('triage').baseUrl,
          'http://127.0.0.1:9/v1/chat/completions');
      expect(prefs.targetForStage('draft_reply'), prefs.state.proseTarget);
    });

    test('an entry round-trips and moves only its own stage', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.setStageTarget('triage', 'gpu-1');

      expect(await store.getPref(stageTargetsKey), '{"triage":"gpu-1"}');
      expect(prefs.targetForStage('triage').baseUrl, box.url);
      expect(prefs.targetForStage('extraction'), prefs.state.fastTarget);

      final fresh = await AppPrefsNotifier.read(store);
      expect(fresh.stageTargets, {'triage': 'gpu-1'});
    });

    test('an entry naming a target that is gone falls back', () async {
      await store.setPref(stageTargetsKey, '{"triage":"vanished"}');
      final prefs = await notifier();

      expect(prefs.state.stageTargets, {'triage': 'vanished'});
      // Kept in the map and ignored by the resolver, so putting the target
      // back restores where it pointed.
      expect(prefs.state.targetIdForStage('triage'), builtInFastId);
      expect(prefs.targetForStage('triage'), prefs.state.fastTarget);
    });

    test('writing a stage its own default stores nothing', () async {
      final prefs = await notifier();

      await prefs.setStageTarget('triage', builtInFastId);
      await prefs.setStageTarget('draft_reply', builtInProseId);

      expect(prefs.state.stageTargets, isEmpty);
    });

    test('and clearing an entry puts it back on the default', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.setStageTarget('storyline_name', 'gpu-1');
      expect(prefs.state.stageTargets, hasLength(1));

      await prefs.setStageTarget('storyline_name', builtInProseId);

      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.targetForStage('storyline_name'), prefs.state.proseTarget);
    });

    test('embeddings and an unknown target id are no-ops', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      await prefs.setStageTarget('embeddings', 'gpu-1');
      await prefs.setStageTarget('triage', 'nothing-by-that-name');

      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.targetIdForStage('embeddings'), isNull);
    });

    test('an optional stage has no target until one is picked', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      expect(prefs.state.targetIdForStage('draft_improve'), isNull);
      expect(prefs.state.specForStage('draft_improve'), isNull);

      await prefs.setStageTarget('draft_improve', 'gpu-1');

      expect(prefs.state.specForStage('draft_improve')!.id, 'gpu-1');
      expect(prefs.targetForStage('draft_improve').baseUrl, box.url);

      await prefs.clearStageTarget('draft_improve');
      expect(prefs.state.specForStage('draft_improve'), isNull);
    });

    test('an optional stage stores even its slot default', () async {
      final prefs = await notifier();

      // The entry IS the feature being turned on, so the non-defaults-only
      // rule does not apply to it.
      await prefs.setStageTarget('draft_improve', builtInProseId);

      expect(prefs.state.stageTargets, {'draft_improve': builtInProseId});
    });
  });

  group('the presets', () {
    test('each writes exactly its documented stages', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      await prefs.applyPreset(targetId: 'gpu-1', prose: true);
      expect(prefs.state.stageTargets.keys.toSet(), proseStageIds.toSet());

      await prefs.clearAll();
      await prefs.applyPreset(targetId: 'gpu-1', confirm: true);
      expect(prefs.state.stageTargets.keys.toSet(), confirmStageIds.toSet());

      await prefs.clearAll();
      await prefs.applyPreset(targetId: 'gpu-1', bulk: true);
      expect(prefs.state.stageTargets.keys.toSet(), bulkStageIds.toSet());

      for (final id in prefs.state.stageTargets.values) {
        expect(id, 'gpu-1');
      }
    });

    test('none of them touches draft_improve or embeddings', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      await prefs.applyPreset(
        targetId: 'gpu-1',
        prose: true,
        confirm: true,
        bulk: true,
      );

      expect(prefs.state.stageTargets.keys, isNot(contains('draft_improve')));
      expect(prefs.state.stageTargets.keys, isNot(contains('embeddings')));
      expect(prefs.state.specForStage('draft_improve'), isNull);
    });

    test('a preset onto a built-in clears rather than stores', () async {
      final prefs = await notifier();

      await prefs.applyPreset(targetId: builtInProseId, prose: true);

      expect(prefs.state.stageTargets, isEmpty);
    });

    test('an unknown target id writes nothing', () async {
      final prefs = await notifier();
      await prefs.applyPreset(targetId: 'nothing-by-that-name', bulk: true);
      expect(prefs.state.stageTargets, isEmpty);
    });

    // Both ways a target can be third party: the Converse wire, and a host
    // under one of the four domains on the OpenAI wire. One test each, so
    // each gets a fresh store rather than the previous one's consent.
    for (final target in [bedrock, cloudOnOpenAi]) {
      test(
          'a preset skips draft_reply on ${target.name} without consent, '
          'and writes it with consent', () async {
        final prefs = await notifier();
        await prefs.upsertTarget(target);

        await prefs.applyPreset(targetId: target.id, prose: true);

        // The other five prose stages are written either way: what the
        // consent is about is what leaves the machine in a DRAFT.
        expect(
          prefs.state.stageTargets.keys.toSet(),
          proseStageIds.where((id) => id != 'draft_reply').toSet(),
        );
        expect(prefs.state.stageTargets.containsKey('draft_improve'), isFalse);

        await prefs.setCloudDraftsConsent(true);
        await prefs.applyPreset(targetId: target.id, prose: true);

        expect(prefs.state.stageTargets.keys.toSet(), proseStageIds.toSet());
        expect(prefs.state.specForStage('draft_reply')!.id, target.id);
      });
    }

    test('and it leaves a draft stage the user pointed somewhere alone',
        () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.upsertTarget(bedrock);
      await prefs.setStageTarget('draft_reply', 'gpu-1');

      await prefs.applyPreset(targetId: 'cloud-1', prose: true);

      // Skipped means untouched, not cleared: a hand-made choice is theirs.
      expect(prefs.state.stageTargets['draft_reply'], 'gpu-1');
      expect(prefs.state.stageTargets['storyline_recap'], 'cloud-1');
    });

    test('a local preset still writes the draft stage', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);

      await prefs.applyPreset(targetId: 'gpu-1', prose: true);

      // The box is on a loopback tunnel and is nobody else's machine, so the
      // consent has nothing to say about it.
      expect(prefs.state.stageTargets.keys.toSet(), proseStageIds.toSet());
      expect(prefs.state.specForStage('draft_reply')!.id, 'gpu-1');
    });
  });

  group('the consent rule', () {
    test('a Converse target on a draft needs it', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(bedrock);
      await prefs.setStageTarget('draft_reply', 'cloud-1');

      // Picked, stored, and NOT dialled: the rule is enforced where the
      // target is resolved, so a stage map restored from a backup cannot send
      // a draft off this machine on its own.
      expect(prefs.state.targetIdForStage('draft_reply'), 'cloud-1');
      expect(prefs.state.specForStage('draft_reply')!.id, builtInProseId);
      expect(prefs.targetForStage('draft_reply'), prefs.state.proseTarget);

      await prefs.setCloudDraftsConsent(true);

      expect(prefs.state.specForStage('draft_reply')!.id, 'cloud-1');
      expect(prefs.targetForStage('draft_reply').baseUrl, bedrock.url);
      expect(prefs.targetForStage('draft_reply').wire,
          LlmWire.bedrockConverse);
    });

    test('so does one reached over the OpenAI wire', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(cloudOnOpenAi);
      await prefs.setStageTarget('draft_reply', 'cloud-2');

      expect(prefs.state.specForStage('draft_reply')!.id, builtInProseId);

      await prefs.setCloudDraftsConsent(true);
      expect(prefs.state.specForStage('draft_reply')!.id, 'cloud-2');
    });

    test('draft_improve resolves to nothing instead of falling back',
        () async {
      final prefs = await notifier();
      await prefs.upsertTarget(bedrock);
      await prefs.setStageTarget('draft_improve', 'cloud-1');

      // The button is hidden rather than quietly pointed at the local model:
      // "Improve with Cloud prose" that ran locally would be a lie.
      expect(prefs.state.specForStage('draft_improve'), isNull);

      await prefs.setCloudDraftsConsent(true);
      expect(prefs.state.specForStage('draft_improve')!.id, 'cloud-1');
    });

    test('it gates the two draft stages and nothing else', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(bedrock);
      await prefs.setStageTarget('storyline_recap', 'cloud-1');
      await prefs.setStageTarget('triage', 'cloud-1');

      // What leaves the machine for a recap or a triage is the same kind of
      // text, and the owner's decision is about drafts — the plan's rule, not
      // a gap. Any target may serve any other stage.
      expect(prefs.state.specForStage('storyline_recap')!.id, 'cloud-1');
      expect(prefs.state.specForStage('triage')!.id, 'cloud-1');
    });

    test('a loopback tunnel is not a third party', () async {
      final prefs = await notifier();
      await prefs.upsertTarget(box);
      await prefs.setStageTarget('draft_reply', 'gpu-1');

      // The GPU box arrives on an `ssh` tunnel at localhost:18100, and asking
      // for consent to reach it would train the user to click through.
      expect(prefs.state.cloudDraftsConsent, isFalse);
      expect(prefs.state.specForStage('draft_reply')!.id, 'gpu-1');
      expect(prefs.state.specForStage('draft_reply')!.parallel, 4);
    });

    test('the consent round-trips', () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsConsent(true);

      expect(await store.getPref(cloudDraftsConsentKey), 'true');
      expect((await AppPrefsNotifier.read(store)).cloudDraftsConsent, isTrue);

      await prefs.setCloudDraftsConsent(false);
      expect((await AppPrefsNotifier.read(store)).cloudDraftsConsent, isFalse);
    });
  });

  group('what a bad row costs', () {
    test('nothing that is not JSON, or not the right shape', () async {
      await store.setPref(llmTargetsKey, 'not json at all');
      await store.setPref(stageTargetsKey, '[1, 2, 3]');
      await store.setPref(cloudDraftsConsentKey, 'yes');

      final prefs = await notifier();

      expect(prefs.state.targets, isEmpty);
      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.cloudDraftsConsent, isFalse);
      // And the defaults still resolve, which is the point of not throwing.
      expect(prefs.targetForStage('triage'), prefs.state.fastTarget);
    });

    test('one bad row, and the good ones beside it survive', () async {
      await store.setPref(
        llmTargetsKey,
        jsonEncode([
          {'name': 'no id', 'url': 'http://example.com/v1', 'model': 'm'},
          box.toJson(),
          'a string where an object goes',
          // A stored copy of a built-in would shadow the live slot prefs.
          {
            'id': builtInProseId,
            'name': 'Impostor',
            'url': 'http://example.com/v1',
            'model': 'm',
          },
          // A duplicate id keeps the FIRST: one stage entry cannot choose
          // between two rows.
          {...box.toJson(), 'name': 'Second GPU box'},
        ]),
      );
      await store.setPref(
        stageTargetsKey,
        jsonEncode({'triage': 'gpu-1', 'extraction': 7}),
      );

      final prefs = await AppPrefsNotifier.read(store);

      expect(prefs.targets, hasLength(1));
      expect(prefs.targets.single.name, 'GPU box');
      expect(prefs.stageTargets, {'triage': 'gpu-1'});
      expect(prefs.allTargets.where((s) => s.id == builtInProseId), hasLength(1));
      expect(prefs.specById(builtInProseId)!.name, builtInProseName);
    });
  });

  test('the three keys survive a wipe, like prose_parallel', () async {
    final prefs = await notifier();
    await prefs.upsertTarget(box);
    await prefs.setStageTarget('triage', 'gpu-1');
    await prefs.setCloudDraftsConsent(true);
    await prefs.setProseParallel(4);

    await store.wipeAll();

    // Machine configuration, not one account's data: which servers this
    // machine can reach has nothing to do with who is signed in.
    final after = await AppPrefsNotifier.read(store);
    expect(after.targets, [box]);
    expect(after.stageTargets, {'triage': 'gpu-1'});
    expect(after.cloudDraftsConsent, isTrue);
    expect(after.proseParallel, 4);
  });
}

/// Empties the stage map between two preset assertions, without asserting
/// anything about how — the presets are the subject, not the clear.
extension on AppPrefsNotifier {
  Future<void> clearAll() async {
    for (final stageId in state.stageTargets.keys.toList()) {
      await clearStageTarget(stageId);
    }
  }
}
