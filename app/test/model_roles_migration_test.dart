import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// A keychain that reads and writes but refuses every DELETE, the way a
/// keychain item another process holds refuses to go.
class _NoDeleteTokenStore extends MemoryTokenStore {
  _NoDeleteTokenStore([super.initial]);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) throw StateError('no delete');
    return super.write(key, value);
  }
}

/// A keychain that reads but refuses every write.
class _ReadOnlyTokenStore extends MemoryTokenStore {
  _ReadOnlyTokenStore([super.initial]);

  @override
  Future<void> write(String key, String? value) async =>
      throw StateError('read only');
}

/// The decision-model round's one-shot, `model_roles_derived`: Round H's
/// big/small pair into the three roles.
///
/// The keys were reused, so every shape but one is a no-op. The one that is
/// not is a THIRD-PARTY big address (Round H's way of doing cloud drafts),
/// which may not serve the generative role because that role reads every
/// message. It becomes the cloud-drafts target only when the owner was using
/// it and had agreed to it; otherwise it is dropped with its key. Its key
/// never reaches the owner's own server: the moves are verified, and while
/// any is owed no `box-prose` token is attached.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    // The three Round G/H one-shots have run: this file is about the fourth.
    await store.setPref(boxTargetsDerivedKey, '1');
    await store.setPref(boxServersDerivedKey, '1');
    await store.setPref(stageTargetsClearedKey, '1');
  });

  tearDown(() => db.close());

  const vendor = 'https://api.openai.com/v1/chat/completions';
  const own = 'https://box.example.com/bulk/v1/chat/completions';
  // What `own` becomes as the one generative server: the box's 27B slot
  // beside its 4B one.
  const ownProse = 'https://box.example.com/prose/v1/chat/completions';
  // Fictional strings, and the only "keys" anywhere in this file.
  const vendorKey = 'sk-fixture-not-a-real-vendor-token';
  const smallKey = 'sk-fixture-not-a-real-small-token';

  String bearer(String id) => '$llmTargetBearerKeyPrefix$id';

  /// A Round H install whose big address is a vendor.
  Future<void> seed({
    String? placement = 'box',
    bool consent = true,
    String bigModel = 'gpt-big',
    String? small,
  }) async {
    if (placement != null) await store.setPref(modelPlacementKey, placement);
    if (consent) await store.setPref(cloudDraftsConsentKey, 'true');
    await store.setPref(boxBigUrlKey, vendor);
    await store.setPref(boxBigModelKey, bigModel);
    if (small != null) {
      await store.setPref(boxSmallUrlKey, small);
      await store.setPref(boxSmallModelKey, 'qwen3-4b');
    }
  }

  MemoryTokenStore bothKeys() => MemoryTokenStore({
        bearer(boxProseId): vendorKey,
        bearer(legacyBoxBulkId): smallKey,
      });

  Future<AppPrefsNotifier> launch(MemoryTokenStore tokens) async {
    final prefs = AppPrefsNotifier(store, tokens: tokens);
    addTearDown(prefs.dispose);
    await prefs.ready;
    return prefs;
  }

  group('adopting the vendor address as cloud drafts', () {
    test('in use, consented and named: adopted, the vendor key moves with '
        "it, and the own small server's prose slot is the generative remote",
        () async {
      await seed(small: own);
      final tokens = bothKeys();

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsUrl, vendor);
      expect(prefs.cloudDraftsModel, 'gpt-big');
      expect(prefs.boxBigUrl, ownProse);
      // The 4B's name stays with the 4B: the prose slot is asked for the
      // build's constant until a Connect discovers its own.
      expect(prefs.boxBigModel, isEmpty);
      expect(prefs.effectiveGenerativeModel, boxProseModel);
      expect(prefs.modelPlacement, ModelPlacement.box);
      expect(prefs.generativeSpec.url, ownProse);
      expect(tokens.values, {
        bearer(cloudDraftsId): vendorKey,
        bearer(boxProseId): smallKey,
      });
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
    });

    test('an address the owner had walked away from (placement local) is '
        'dropped, and its key deleted', () async {
      await seed(placement: 'local', small: own);
      final tokens = bothKeys();

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsUrl, isEmpty);
      expect(prefs.cloudDraftsSpec, isNull);
      expect(prefs.modelPlacement, ModelPlacement.local);
      expect(tokens.values[bearer(cloudDraftsId)], isNull);
      // The vendor key is gone; `box-prose` holds the owner's own key now.
      expect(tokens.values[bearer(boxProseId)], smallKey);
    });

    test('no stored placement reads as the build default (this Mac here)',
        () async {
      await seed(placement: null);
      final tokens = MemoryTokenStore({bearer(boxProseId): vendorKey});

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsSpec, isNull);
      expect(tokens.values, isEmpty);
    });

    test('without consent it is dropped, and its key deleted', () async {
      await seed(consent: false);
      final tokens = MemoryTokenStore({bearer(boxProseId): vendorKey});

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsSpec, isNull);
      expect(prefs.boxBigUrl, isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.local);
      expect(tokens.values, isEmpty);
    });

    test('without a discovered model name it is dropped', () async {
      await seed(bigModel: '');
      final tokens = MemoryTokenStore({bearer(boxProseId): vendorKey});

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsUrl, isEmpty);
      expect(tokens.values, isEmpty);
    });

    test('adopted with no small server: the generative model comes home',
        () async {
      await seed();
      final tokens = MemoryTokenStore({bearer(boxProseId): vendorKey});

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.cloudDraftsUrl, vendor);
      expect(prefs.boxBigUrl, isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.local);
      expect(prefs.generativeSpec.id, localGenerativeId);
      expect(tokens.values, {bearer(cloudDraftsId): vendorKey});
    });
  });

  group('the generative role after a vendor big address', () {
    test('a third-party SMALL address is not adopted', () async {
      await seed(small: 'https://bedrock-runtime.us-east-2.amazonaws.com');
      final prefs =
          await AppPrefsNotifier.read(store, tokens: MemoryTokenStore());
      expect(prefs.modelPlacement, ModelPlacement.local);
      expect(prefs.boxBigUrl, isEmpty);
    });

    test('a Converse big address counts as third party', () async {
      await store.setPref(modelPlacementKey, 'box');
      await store.setPref(
        boxBigUrlKey,
        'https://bedrock-runtime.us-east-2.amazonaws.com',
      );
      final prefs =
          await AppPrefsNotifier.read(store, tokens: MemoryTokenStore());
      expect(prefs.modelPlacement, ModelPlacement.local);
      expect(prefs.boxBigUrl, isEmpty);
    });

    // `boxUrlDefault` is empty under `flutter test`, so the follow-the-build
    // branch is pinned on the pure decision.
    group('planModelRoles', () {
      ModelRolesPlan? plan({
        String small = '',
        String compiled = '',
        ModelPlacement placement = ModelPlacement.box,
        bool consent = true,
        String model = 'gpt-big',
        String big = vendor,
      }) =>
          planModelRoles(
            bigUrl: big,
            bigModel: model,
            smallUrl: small,
            placement: placement,
            consent: consent,
            compiledBase: compiled,
          );

      test('a small server that followed the build: follow it, keep the '
          'placement, move the small key', () {
        final p = plan(compiled: 'https://box.example.com')!;
        expect(p.generative, GenerativeAfterVendor.followBuild);
        expect(p.adoptCloud, isTrue);
        expect(p.moves,
            [modelRolesMoveProseToCloud, modelRolesMoveBulkToProse]);
      });

      test('an own stored small server wins over the build', () {
        final p = plan(small: own, compiled: 'https://box.example.com')!;
        expect(p.generative, GenerativeAfterVendor.small);
      });

      test("a box's /bulk slot hands the role to its /prose sibling; any "
          'other small address is kept as it is', () {
        expect(plan(small: own)!.generativeUrl, ownProse);
        const other = 'https://gpu.example.com/v1/chat/completions';
        expect(plan(small: other)!.generativeUrl, other);
        expect(plan(compiled: 'https://box.example.com')!.generativeUrl,
            isEmpty);
        expect(plan()!.generativeUrl, isEmpty);
      });

      test('nothing of the owner\'s to dial: home, and no small key to move',
          () {
        final p = plan()!;
        expect(p.generative, GenerativeAfterVendor.local);
        expect(p.moves, [modelRolesMoveProseToCloud]);
      });

      test('not adopted: the vendor key is dropped rather than moved', () {
        expect(plan(consent: false)!.moves, [modelRolesDropProse]);
        expect(plan(placement: ModelPlacement.local)!.adoptCloud, isFalse);
        expect(plan(model: '')!.adoptCloud, isFalse);
      });

      test('an own big address, or none, is no plan at all', () {
        expect(plan(big: 'https://box.example.com/prose/v1/chat/completions'),
            isNull);
        expect(plan(big: ''), isNull);
      });
    });
  });

  group('the no-op shapes', () {
    test('the owner\'s own big address is left exactly where it is',
        () async {
      await store.setPref(modelPlacementKey, 'box');
      await store.setPref(boxBigUrlKey,
          'https://box.example.com/prose/v1/chat/completions');
      await store.setPref(boxSmallUrlKey, own);
      final tokens = bothKeys();

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(prefs.boxBigUrl,
          'https://box.example.com/prose/v1/chat/completions');
      expect(prefs.cloudDraftsUrl, isEmpty);
      expect(prefs.modelPlacement, ModelPlacement.box);
      expect(tokens.values.length, 2);
      expect(tokens.reads, isEmpty);
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
    });

    test('a fresh install writes the flag and nothing else', () async {
      await AppPrefsNotifier.read(store, tokens: MemoryTokenStore());

      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
      for (final key in [
        cloudDraftsUrlKey,
        cloudDraftsModelKey,
        boxBigUrlKey,
        modelPlacementKey,
      ]) {
        expect(await store.getPref(key), isNull, reason: key);
      }
    });

    test('a second read is a no-op', () async {
      await seed(small: own);
      final tokens = bothKeys();
      await AppPrefsNotifier.read(store, tokens: tokens);

      // A vendor address written back by hand after the flag is set is left
      // alone: the migration is one-shot (and the resolver refuses it).
      await store.setPref(boxBigUrlKey, vendor);
      await store.setPref(cloudDraftsUrlKey, '');
      final again = await AppPrefsNotifier.read(store, tokens: tokens);

      expect(again.boxBigUrl, vendor);
      expect(again.cloudDraftsUrl, isEmpty);
      expect(again.generativeSpec.id, localGenerativeId);
    });

    test('the flag is a plain pref, not a derived one-shot', () {
      expect(MessageStore.derivedOneShotPrefs,
          isNot(contains(modelRolesDerivedKey)));
    });
  });

  group('the keychain half', () {
    test('the pending flag is written before the prefs move, so a crash '
        'between them re-runs only the keychain moves', () async {
      // The state such a crash leaves: flag pending, prefs not moved yet.
      await seed(small: own);
      await store.setPref(
        modelRolesDerivedKey,
        '$modelRolesPendingPrefix$modelRolesDropProse',
      );
      final tokens = MemoryTokenStore({bearer(boxProseId): vendorKey});

      final prefs = await AppPrefsNotifier.read(store, tokens: tokens);

      // The prefs are not moved a second time (the resolver refuses the
      // vendor address as a generative remote regardless) ...
      expect(prefs.boxBigUrl, vendor);
      expect(prefs.generativeSpec.id, localGenerativeId);
      // ... and the owed move ran.
      expect(tokens.values, isEmpty);
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
    });

    test('a keychain that refuses writes: the prefs migrate, the flag stays '
        'pending, and no box-prose token is attached', () async {
      await seed(small: own);
      final refusing = _ReadOnlyTokenStore({
        bearer(boxProseId): vendorKey,
        bearer(legacyBoxBulkId): smallKey,
      });

      final prefs = await launch(refusing);

      expect(prefs.state.boxBigUrl, ownProse);
      expect(prefs.state.cloudDraftsUrl, vendor);
      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);
      // The vendor key is still readable under box-prose, and it is NOT sent
      // to the owner's server: the generative remote goes keyless.
      expect(prefs.state.boxBigKeyStored, isFalse);
      expect(prefs.targetForStage('triage').bearer, isNull);
    });

    test('a keychain that refuses only deletes: pending, not attached',
        () async {
      await seed(small: own);
      final noDelete = _NoDeleteTokenStore({
        bearer(boxProseId): vendorKey,
        bearer(legacyBoxBulkId): smallKey,
      });

      final prefs = await launch(noDelete);

      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);
      expect(prefs.targetForStage('triage').bearer, isNull);
      expect(prefs.targetForStage('triage').toString(),
          isNot(contains('sk-fixture')));
    });

    test('a later launch with a working keychain finishes it', () async {
      await seed(small: own);
      final values = {
        bearer(boxProseId): vendorKey,
        bearer(legacyBoxBulkId): smallKey,
      };
      await launch(_ReadOnlyTokenStore(values));
      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);

      final working = MemoryTokenStore(values);
      final prefs = await launch(working);

      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
      expect(working.values, {
        bearer(cloudDraftsId): vendorKey,
        bearer(boxProseId): smallKey,
      });
      expect(prefs.targetForStage('triage').bearer, smallKey);
      expect(prefs.targetForStage('draft_reply').bearer, vendorKey);
    });

    test('a read with no keychain (main()\'s preload) leaves the moves owed, '
        'and the notifier pays them before its prefetch', () async {
      await seed(small: own);
      final tokens = bothKeys();

      final preload = await AppPrefsNotifier.read(store);

      expect(preload.cloudDraftsUrl, vendor);
      expect(preload.boxBigUrl, ownProse);
      expect(
        await store.getPref(modelRolesDerivedKey),
        '$modelRolesPendingPrefix'
        '$modelRolesMoveProseToCloud,$modelRolesMoveBulkToProse',
      );
      expect(tokens.values[bearer(boxProseId)], vendorKey);

      final prefs = AppPrefsNotifier(store, initial: preload, tokens: tokens);
      addTearDown(prefs.dispose);
      await prefs.ready;

      expect(tokens.values, {
        bearer(cloudDraftsId): vendorKey,
        bearer(boxProseId): smallKey,
      });
      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
      expect(prefs.state.boxBigKeyStored, isTrue);
      expect(prefs.targetForStage('triage').bearer, smallKey);
    });

    test('a typed generative key that the keychain REFUSED settles nothing, '
        'and the next launch attaches no key', () async {
      await seed(small: own);
      final readOnly = _ReadOnlyTokenStore({bearer(boxProseId): vendorKey});
      final prefs = await launch(readOnly);
      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: own,
        key: 'sk-fixture-not-a-real-new-token',
        hardwareTier: MachineTier.full,
      );

      // The typed key works for this session, from the cache...
      expect(prefs.targetForStage('triage').bearer,
          'sk-fixture-not-a-real-new-token');
      // ...but the keychain still holds the vendor key, so nothing settles.
      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);

      // A relaunch on the same keychain attaches no key at all: never the
      // vendor's, which is still under `box-prose`.
      final again = await launch(readOnly);
      expect(again.targetForStage('triage').bearer, isNull);
    });

    test('a typed generative key the keychain KEPT settles a pending flag',
        () async {
      await seed(small: own);
      final noDelete = _NoDeleteTokenStore({bearer(boxProseId): vendorKey});
      final prefs = await launch(noDelete);
      expect(modelRolesPending(await store.getPref(modelRolesDerivedKey)),
          isTrue);

      await prefs.useGenerative(
        placement: ModelPlacement.box,
        url: own,
        key: 'sk-fixture-not-a-real-new-token',
        hardwareTier: MachineTier.full,
      );

      expect(await store.getPref(modelRolesDerivedKey), modelRolesDoneValue);
      final again = await launch(noDelete);
      expect(again.targetForStage('triage').bearer,
          'sk-fixture-not-a-real-new-token');
    });
  });
}
