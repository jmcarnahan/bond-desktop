import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// The role targets as DATA: the three writers, the consent, and the secrets.
///
/// `placement_rule_test.dart` owns the rule (which spec a stage resolves to).
/// The claims this file holds are the ones a screen cannot: that each role's
/// writer validates before it writes and refuses a third party for a role
/// that reads every message; that a bearer token reaches the keychain under
/// its role's id and NEVER `app_prefs`, and rides only its own role's
/// requests; that the cloud-drafts consent is enforced where the target is
/// resolved; and that the routing keys are machine configuration a wipe
/// leaves alone.
/// A keychain whose writes wait on a gate the test opens, so a test can look
/// at what the prefs resolve WHILE a role write is inside the keychain.
class _GatedTokenStore extends MemoryTokenStore {
  Completer<void>? gate;

  @override
  Future<void> write(String key, String? value) async {
    final wait = gate;
    if (wait != null) await wait.future;
    await super.write(key, value);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// A notifier over the real store, with the keychain in a map.
  Future<AppPrefsNotifier> notifier([TokenStore? tokens]) async {
    final made = AppPrefsNotifier(store, tokens: tokens ?? MemoryTokenStore());
    addTearDown(made.dispose);
    await made.ready;
    return made;
  }

  const box = 'https://box.example.com';
  const generativeUrl = '$box/prose/v1/chat/completions';
  const decisionUrl = '$box/decide/v1/embeddings';
  const vendor = 'https://api.openai.com/v1/chat/completions';
  const bedrock = 'https://bedrock-runtime.us-east-2.amazonaws.com';
  // Fictional strings, and the only "keys" anywhere in this file.
  const key = 'sk-fixture-not-a-real-token';
  const decideKey = 'sk-fixture-not-a-real-decide-token';
  const cloudKey = 'sk-fixture-not-a-real-cloud-token';

  /// Every value in `app_prefs`, which is where a leaked secret would be.
  Future<List<String>> prefValues() async {
    final rows = await db.customSelect('SELECT value FROM app_prefs').get();
    return [for (final row in rows) row.read<String>('value')];
  }

  final generativeStages = [
    for (final stage in pipelineStages)
      if (stage.slot == ModelSlot.generative) stage.id,
  ];

  group('the generative writer', () {
    test('your server: the address, the model, the key and the placement',
        () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: '$generativeUrl/',
        model: 'qwen3.8-mlx',
        key: key,
        hardwareTier: MachineTier.full,
      );

      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.generativePlacement, ModelPlacement.box);
      // Normalised: the trailing slash is gone.
      expect(prefs.state.boxBigUrl, generativeUrl);
      expect(prefs.state.generativeUrl, generativeUrl);
      expect(prefs.state.boxBigModel, 'qwen3.8-mlx');
      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.state.draftPolicy, DraftPolicy.needsYou);
      expect(await store.getPref(modelPlacementKey), 'box');
      expect(await store.getPref(boxBigUrlKey), generativeUrl);
      expect(await store.getPref(boxBigModelKey), 'qwen3.8-mlx');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);

      // A relaunch reads the same install back.
      final again = await AppPrefsNotifier.read(store);
      expect(again.generativeSpec.id, boxProseId);
      expect(again.generativeSpec.model, 'qwen3.8-mlx');
    });

    test('the build\'s own model name is stored as empty', () async {
      final prefs = await notifier();
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        model: boxProseModel,
        hardwareTier: MachineTier.full,
      );
      expect(await store.getPref(boxBigModelKey), '');
      expect(prefs.state.effectiveGenerativeModel, boxProseModel);
    });

    test('refuses an address that cannot be dialled, and writes nothing',
        () async {
      final prefs = await notifier();
      for (final bad in ['box.example.com', 'ftp://box.example.com', '']) {
        await expectLater(
          prefs.useGenerative(
            placement: ModelPlacement.box,
            url: bad,
            hardwareTier: MachineTier.full,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(await store.getPref(boxBigUrlKey), isNull);
      expect(await store.getPref(modelPlacementKey), isNull);
    });

    test('refuses a third party and the Converse wire, with the sentence',
        () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsConsent(true);
      for (final bad in [vendor, bedrock]) {
        await expectLater(
          prefs.useGenerative(
            placement: ModelPlacement.box,
            url: bad,
            key: key,
            hardwareTier: MachineTier.full,
          ),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'the generative model reads every message; a third-party '
                'service can serve cloud drafts only',
          )),
          reason: bad,
        );
      }
      // Consent covers cloud drafts, never the role that reads every message,
      // and a refusal leaves the install exactly as it was.
      expect(await store.getPref(boxBigUrlKey), isNull);
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.state.modelPlacement, ModelPlacement.local);
    });

    test('this Mac: the managed model, the tier and the draft policy',
        () async {
      final prefs = await notifier();

      await prefs.useGenerative(
        placement: ModelPlacement.local,
        hardwareTier: MachineTier.inbox,
      );
      expect(prefs.state.machineTier, MachineTier.inbox);
      expect(prefs.state.generativeSpec.model, routerBulkId);
      // The 4B's drafts are the tier's policy: on demand on a small Mac.
      expect(prefs.state.draftPolicy, DraftPolicy.onDemand);

      await prefs.useGenerative(
        placement: ModelPlacement.local,
        hardwareTier: MachineTier.full,
      );
      expect(prefs.state.generativeSpec.model, routerProseId);
      expect(prefs.state.draftPolicy, DraftPolicy.needsYou);

      await prefs.useGenerative(
        placement: ModelPlacement.local,
        managedModel: routerBulkId,
        hardwareTier: MachineTier.full,
      );
      expect(prefs.state.generativeSpec.model, routerBulkId);
      expect(prefs.state.draftPolicy, tierDraftPolicy(MachineTier.full));
      expect(await store.getPref(generativeManagedModelKey), routerBulkId);
    });

    test('refuses a managed model that is not one of the two', () async {
      final prefs = await notifier();
      await expectLater(
        prefs.useGenerative(
          placement: ModelPlacement.local,
          managedModel: routerEmbedId,
          hardwareTier: MachineTier.full,
        ),
        throwsArgumentError,
      );
      expect(await store.getPref(generativeManagedModelKey), isNull);
    });

    test('moving back to this Mac keeps the address and the key', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );

      await prefs.useGenerative(
        placement: ModelPlacement.local,
        hardwareTier: MachineTier.full,
      );

      expect(prefs.state.generativeSpec.id, localGenerativeId);
      expect(prefs.state.boxBigUrl, generativeUrl);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
    });
  });

  group('the decision writer', () {
    test('your server: the address, the model, the key and the placement',
        () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);

      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        model: 'bond-decide-next',
        key: decideKey,
      );

      expect(prefs.state.decisionPlacement, ModelPlacement.box);
      expect(prefs.state.decisionSpec.id, boxDecideId);
      expect(prefs.state.decisionSpec.url, decisionUrl);
      expect(prefs.state.decisionSpec.model, 'bond-decide-next');
      expect(prefs.state.decisionKeyStored, isTrue);
      expect(await store.getPref(decisionPlacementKey), 'box');
      expect(await store.getPref(decisionUrlKey), decisionUrl);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxDecideId'],
          decideKey);
      // The generative placement is not the decision writer's to move.
      expect(prefs.state.modelPlacement, ModelPlacement.local);
    });

    test('refuses a third party, with its own sentence', () async {
      final prefs = await notifier();
      await expectLater(
        prefs.useDecision(placement: ModelPlacement.box, url: vendor),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'the decision model reads every message; it runs on this Mac or a '
              'server of your own',
        )),
      );
      expect(await store.getPref(decisionUrlKey), isNull);
      expect(await store.getPref(decisionPlacementKey), isNull);
    });

    test('this Mac takes the role back and keeps the address', () async {
      final prefs = await notifier();
      await prefs.useDecision(placement: ModelPlacement.box, url: decisionUrl);
      await prefs.useDecision(placement: ModelPlacement.local);

      expect(prefs.state.decisionSpec.id, localDecisionId);
      expect(prefs.state.decisionUrl, decisionUrl);
      expect(await store.getPref(decisionPlacementKey), 'local');
    });
  });

  group('cloud drafts', () {
    test('a third-party target needs the consent first', () async {
      final prefs = await notifier();

      await expectLater(
        prefs.useCloudDrafts(url: vendor, model: 'gpt'),
        throwsArgumentError,
      );
      expect(prefs.state.cloudDraftsSpec, isNull);
      expect(await store.getPref(cloudDraftsUrlKey), isNull);

      await prefs.setCloudDraftsConsent(true);
      await prefs.useCloudDrafts(url: vendor, model: 'gpt', key: cloudKey);

      expect(prefs.state.cloudDraftsSpec!.url, vendor);
      expect(prefs.specForDraft('draft_reply'), cloudDraftsId);
      expect(await store.getPref(cloudDraftsUrlKey), vendor);
      expect(await store.getPref(cloudDraftsModelKey), 'gpt');
    });

    test('the owner\'s own server needs none', () async {
      final prefs = await notifier();
      await prefs.useCloudDrafts(
        url: 'https://drafts.example.com/v1/chat/completions',
        model: 'mine',
      );
      expect(prefs.specForDraft('draft_reply'), cloudDraftsId);
      expect(prefs.specForDraft('draft_improve'), cloudDraftsId);
    });

    test('an address without a model is refused, and is not a target',
        () async {
      final prefs = await notifier();
      await expectLater(
        prefs.useCloudDrafts(
          url: 'https://drafts.example.com/v1/chat/completions',
          model: '  ',
        ),
        throwsArgumentError,
      );
      expect(await store.getPref(cloudDraftsUrlKey), isNull);
      expect(
        const AppPrefs(
          cloudDraftsUrl: 'https://drafts.example.com/v1/chat/completions',
        ).cloudDraftsSpec,
        isNull,
      );
    });

    test('an address that cannot be dialled is refused', () async {
      final prefs = await notifier();
      await expectLater(
        prefs.useCloudDrafts(url: 'not a url', model: 'x'),
        throwsArgumentError,
      );
    });

    test('withdrawing consent sends the drafts home at once', () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsConsent(true);
      await prefs.useCloudDrafts(url: vendor, model: 'gpt');

      await prefs.setCloudDraftsConsent(false);

      // The target is still set; the resolver is what refuses it.
      expect(prefs.state.cloudDraftsSpec, isNotNull);
      expect(prefs.specForDraft('draft_reply'), localGenerativeId);
      expect(prefs.specForDraft('draft_improve'), localGenerativeId);
    });

    test('clearing forgets the address, the model and the key', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.setCloudDraftsConsent(true);
      await prefs.useCloudDrafts(url: vendor, model: 'gpt', key: cloudKey);
      expect(prefs.state.cloudDraftsKeyStored, isTrue);

      await prefs.clearCloudDrafts();

      expect(prefs.state.cloudDraftsSpec, isNull);
      expect(prefs.state.cloudDraftsKeyStored, isFalse);
      expect(await store.getPref(cloudDraftsUrlKey), '');
      expect(tokens.values, isEmpty);
      expect(prefs.specForDraft('draft_reply'), localGenerativeId);
    });

    test('the consent round-trips', () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsConsent(true);
      expect((await AppPrefsNotifier.read(store)).cloudDraftsConsent, isTrue);
      await prefs.setCloudDraftsConsent(false);
      expect((await AppPrefsNotifier.read(store)).cloudDraftsConsent, isFalse);
    });
  });

  group('the bearer', () {
    test('goes to the keychain and never to app_prefs', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.setCloudDraftsConsent(true);

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );
      await prefs.useCloudDrafts(url: vendor, model: 'gpt', key: cloudKey);

      expect(tokens.values, {
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$boxDecideId': decideKey,
        '$llmTargetBearerKeyPrefix$cloudDraftsId': cloudKey,
      });
      for (final value in await prefValues()) {
        for (final secret in [key, decideKey, cloudKey]) {
          expect(value, isNot(contains(secret)));
        }
      }
    });

    test('each rides its own role\'s requests and nothing else', () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsConsent(true);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );
      await prefs.useCloudDrafts(url: vendor, model: 'gpt', key: cloudKey);

      for (final id in generativeStages) {
        final expected = draftStageIds.contains(id) ? cloudKey : key;
        expect(prefs.targetForStage(id).bearer, expected, reason: id);
      }
      expect(prefs.targetForStage('decision').bearer, decideKey);
      expect(prefs.targetForStage('embeddings').bearer, isNull);
      // Not in the string anything logs.
      expect(prefs.targetForStage('triage').toString(),
          isNot(contains('sk-fixture')));
    });

    test('a role on this Mac carries no key, even with one stored', () async {
      final prefs = await notifier(MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$boxDecideId': decideKey,
      }));
      expect(prefs.state.boxBigKeyStored, isTrue);
      // Local placements: the specs are this Mac's, which take no key.
      expect(prefs.targetForStage('triage').bearer, isNull);
      expect(prefs.targetForStage('decision').bearer, isNull);
    });

    test('is prefetched before ready completes, for exactly three ids',
        () async {
      final tokens = MemoryTokenStore({
        '$llmTargetBearerKeyPrefix$boxProseId': key,
        '$llmTargetBearerKeyPrefix$cloudDraftsId': cloudKey,
      });
      await store.setPref(modelPlacementKey, 'box');
      await store.setPref(boxBigUrlKey, generativeUrl);

      final prefs = await notifier(tokens);

      expect(tokens.reads.toSet(), {
        '$llmTargetBearerKeyPrefix$boxProseId',
        '$llmTargetBearerKeyPrefix$boxDecideId',
        '$llmTargetBearerKeyPrefix$cloudDraftsId',
      });
      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.state.decisionKeyStored, isFalse);
      expect(prefs.state.cloudDraftsKeyStored, isTrue);
      expect(prefs.targetForStage('triage').bearer, key);
    });

    test('a blank key keeps the stored one', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: '  ',
        hardwareTier: MachineTier.full,
      );

      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(prefs.targetForStage('triage').bearer, key);
    });

    test('a key no header can carry is refused by every writer, and the '
        'keychain is not touched', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      const bad = 'sk-fixture\nsplit';
      final writes = <Future<void> Function()>[
        () => prefs.useGenerative(
              placement: ModelPlacement.box,
              url: generativeUrl,
              key: bad,
              hardwareTier: MachineTier.full,
            ),
        () => prefs.useDecision(
              placement: ModelPlacement.box,
              url: 'https://box.example.com/decide/v1/embeddings',
              key: bad,
            ),
        () => prefs.useCloudDrafts(
              url: 'https://drafts.example.com/v1/chat/completions',
              model: 'm',
              key: bad,
            ),
      ];
      for (final write in writes) {
        await expectLater(
          write(),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message, 'message', accessKeyCharsText)
              .having((e) => '$e', 'never the key', isNot(contains('split')))),
        );
      }
      expect(tokens.values, isEmpty);
    });

    test('clearRoleKey forgets one role\'s key and nothing else', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );

      await prefs.clearRoleKey(boxProseId);

      expect(tokens.values.keys,
          ['$llmTargetBearerKeyPrefix$boxDecideId']);
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.targetForStage('triage').bearer, isNull);
      expect(prefs.targetForStage('decision').bearer, decideKey);

      await prefs.clearRoleKey(boxDecideId);
      expect(tokens.values, isEmpty);
      expect(prefs.state.decisionKeyStored, isFalse);
      expect(prefs.targetForStage('decision').bearer, isNull);
    });

    test('a new host with a blank key and clearKey forgets the generative '
        'key rather than keeping it', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: 'https://other.example.com/v1/chat/completions',
        key: '',
        clearKey: true,
        hardwareTier: MachineTier.full,
      );

      expect(tokens.values, isEmpty);
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.state.generativeSpec.hasBearer, isFalse);
      expect(prefs.targetForStage('triage').bearer, isNull);
    });

    test('clearKey with a typed key stores the typed key', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );

      const next = 'sk-fixture-not-a-real-next-token';
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: 'https://other.example.com/decide/v1/embeddings',
        key: next,
        clearKey: true,
      );

      expect(tokens.values['$llmTargetBearerKeyPrefix$boxDecideId'], next);
      expect(prefs.targetForStage('decision').bearer, next);
    });

    test('a role write never pairs the new host with the old key, or the '
        'old host with the new key', () async {
      final tokens = _GatedTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );
      const other = 'https://other.example.com/v1/chat/completions';
      const next = 'sk-fixture-not-a-real-next-token';

      Future<void> watch(Future<void> write, String? newBearer) async {
        // While the keychain is blocked, the resolved target is still the
        // old pair: old host, old key.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
          final target = prefs.targetForStage('triage');
          expect(target.baseUrl, generativeUrl);
          expect(target.bearer, key);
        }
        tokens.gate!.complete();
        await write;
        final after = prefs.targetForStage('triage');
        expect(after.baseUrl, other);
        expect(after.bearer, newBearer);
      }

      // A new host with a new key.
      tokens.gate = Completer<void>();
      await watch(
        prefs.useGenerative(
          placement: ModelPlacement.box,
          url: other,
          key: next,
          hardwareTier: MachineTier.full,
        ),
        next,
      );

      // Back, then a new host with the field blank: the key is cleared in
      // the same step the host moves.
      tokens.gate = null;
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );
      tokens.gate = Completer<void>();
      await watch(
        prefs.useGenerative(
          placement: ModelPlacement.box,
          url: other,
          clearKey: true,
          hardwareTier: MachineTier.full,
        ),
        null,
      );
    });

    test('the decision role clears its key before its host moves, too',
        () async {
      final tokens = _GatedTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );
      const other = 'https://other.example.com/decide/v1/embeddings';

      tokens.gate = Completer<void>();
      final write = prefs.useDecision(
        placement: ModelPlacement.box,
        url: other,
        clearKey: true,
      );
      await Future<void>.delayed(Duration.zero);
      final during = prefs.targetForStage('decision');
      expect(during.baseUrl, decisionUrl);
      expect(during.bearer, decideKey);
      tokens.gate!.complete();
      await write;
      final after = prefs.targetForStage('decision');
      expect(after.baseUrl, other);
      expect(after.bearer, isNull);
    });

    test('cloud drafts forgets its key on clearKey, and keeps it without',
        () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.setCloudDraftsConsent(true);
      await prefs.useCloudDrafts(url: vendor, model: 'gpt', key: cloudKey);
      expect(prefs.targetForStage('draft_reply').bearer, cloudKey);

      // Same target, blank field, no clear: the key stays.
      await prefs.useCloudDrafts(url: vendor, model: 'gpt');
      expect(tokens.values['$llmTargetBearerKeyPrefix$cloudDraftsId'],
          cloudKey);

      await prefs.useCloudDrafts(
        url: 'https://api.anthropic.com/v1/chat/completions',
        model: 'claude-x',
        clearKey: true,
      );
      expect(tokens.values, isEmpty);
      expect(prefs.state.cloudDraftsKeyStored, isFalse);
      expect(prefs.targetForStage('draft_reply').bearer, isNull);
      expect(prefs.targetForStage('draft_reply').model, 'claude-x');
    });

    test('the decision role forgets its key on clearKey too', () async {
      final tokens = MemoryTokenStore();
      final prefs = await notifier(tokens);
      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: decisionUrl,
        key: decideKey,
      );

      await prefs.useDecision(
        placement: ModelPlacement.box,
        url: 'https://other.example.com/decide/v1/embeddings',
        clearKey: true,
      );

      expect(tokens.values, isEmpty);
      expect(prefs.state.decisionKeyStored, isFalse);
      expect(prefs.targetForStage('decision').bearer, isNull);
    });

    test('a keychain that refuses costs the header, not the write', () async {
      final prefs = AppPrefsNotifier(store, tokens: RefusingTokenStore());
      addTearDown(prefs.dispose);
      await prefs.ready;

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        key: key,
        hardwareTier: MachineTier.full,
      );

      expect(await store.getPref(boxBigUrlKey), generativeUrl);
      expect(await store.getPref(modelPlacementKey), 'box');
    });

    test('a launch survives a keychain that refuses the prefetch', () async {
      await store.setPref(modelPlacementKey, 'box');
      await store.setPref(boxBigUrlKey, generativeUrl);

      final relaunched = AppPrefsNotifier(store, tokens: RefusingTokenStore());
      addTearDown(relaunched.dispose);

      await relaunched.ready;
      expect(relaunched.state.generativeSpec.id, boxProseId);
      expect(relaunched.state.boxBigKeyStored, isFalse);
      expect(relaunched.targetForStage('draft_reply').bearer, isNull);
    });
  });

  group('a managed model the router is not serving', () {
    test('marks the managed target unavailable, and only that one', () async {
      final prefs = await notifier();
      await prefs.useGenerative(
        placement: ModelPlacement.local,
        managedModel: routerBulkId,
        hardwareTier: MachineTier.full,
      );
      // Unknown until the supervisor has built a preset: served.
      expect(prefs.targetForStage('triage').unavailable, isNull);

      prefs.setServedManagedIds({routerEmbedId, routerDecideId});

      final triage = prefs.targetForStage('triage');
      expect(triage.model, routerBulkId);
      expect(
        triage.unavailable,
        'The Qwen3 4B is not downloaded on this Mac. Set up again to '
        'download it.',
      );
      expect(prefs.targetForStage('draft_reply').unavailable, isNotNull);
      // The decision model IS served.
      expect(prefs.targetForStage('decision').unavailable, isNull);

      prefs.setServedManagedIds({routerEmbedId, routerBulkId});
      expect(prefs.targetForStage('triage').unavailable, isNull);
      expect(
        prefs.targetForStage('decision').unavailable,
        'The decision model is not installed. Run: make decide-install',
      );
    });

    test('a target on the owner\'s server is never marked', () async {
      final prefs = await notifier();
      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: generativeUrl,
        hardwareTier: MachineTier.full,
      );
      prefs.setServedManagedIds({routerEmbedId});
      expect(prefs.targetForStage('triage').unavailable, isNull);
    });
  });

  test('the routing keys survive a wipe, like prose_parallel', () async {
    final prefs = await notifier();
    await prefs.setCloudDraftsConsent(true);
    await prefs.useGenerative(
      placement: ModelPlacement.box,
      url: generativeUrl,
      hardwareTier: MachineTier.full,
    );
    await prefs.useDecision(placement: ModelPlacement.box, url: decisionUrl);
    await prefs.useCloudDrafts(url: vendor, model: 'gpt');
    await prefs.setProseParallel(4);

    await store.wipeAll();

    // Machine configuration, not one account's data: which servers this
    // machine can reach has nothing to do with who is signed in.
    final after = await AppPrefsNotifier.read(store);
    expect(after.generativeSpec.url, generativeUrl);
    expect(after.decisionSpec.url, decisionUrl);
    expect(after.cloudDraftsSpec!.url, vendor);
    expect(after.cloudDraftsConsent, isTrue);
    expect(after.proseParallel, 4);
  });
}

/// Where a draft stage resolves, by id — the one question most cases here ask.
extension on AppPrefsNotifier {
  String? specForDraft(String stageId) => state.specForStage(stageId)?.id;
}
