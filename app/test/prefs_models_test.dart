import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Where the model-routing preferences live, and what empty means there.
///
/// The subject of this file is one deliberate inconsistency: `mcp_server_url`
/// resolves its default when it is READ, and the model-routing prefs do not.
/// A model address is a fact about this build, so resolving it on read would
/// freeze today's define into the database and make a changed one invisible.
/// Empty is stored as empty, and only the role specs on [AppPrefs] turn it
/// into the build's answer.

void main() {
  late BondDatabase db;

  Future<ProviderContainer> container() async {
    final made = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(made.dispose);
    await made.read(appPrefsProvider.notifier).ready;
    return made;
  }

  setUp(() {
    db = testDb();
  });

  tearDown(() => db.close());

  test('a fresh install follows the build and stores nothing', () async {
    final ref = await container();
    final store = MessageStore(db);

    for (final key in [
      boxBigUrlKey,
      boxBigModelKey,
      generativeManagedModelKey,
      decisionPlacementKey,
      decisionUrlKey,
      decisionModelKey,
      cloudDraftsUrlKey,
      cloudDraftsModelKey,
    ]) {
      expect(await store.getPref(key), isNull, reason: key);
    }

    final prefs = ref.read(appPrefsProvider);
    // The generative model defaults to Your server, and with no address
    // compiled (`flutter test`) or stored it is that role, unavailable with
    // its sentence, never this Mac's router.
    expect(prefs.modelPlacement, ModelPlacement.box);
    expect(await store.getPref(modelPlacementKey), isNull);
    expect(prefs.generativeSpec.id, boxProseId);
    expect(prefs.generativeSpec.url, isEmpty);
    expect(prefs.unavailableFor(prefs.generativeSpec), generativeNoAddressText);
    expect(prefs.decisionSpec.id, localDecisionId);
    expect(prefs.decisionPlacement, ModelPlacement.local);
    expect(prefs.cloudDraftsSpec, isNull);
  });

  test('the managed generative choice round-trips', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).useGenerative(
          placement: ModelPlacement.local,
          managedModel: routerBulkId,
          hardwareTier: MachineTier.full,
        );

    expect(ref.read(appPrefsProvider).generativeSpec.model, routerBulkId);
    expect(await MessageStore(db).getPref(generativeManagedModelKey),
        routerBulkId);
    // A new container reads it back: the state is a cache of the store.
    expect(
      (await container()).read(appPrefsProvider).generativeManagedModel,
      routerBulkId,
    );
  });

  test('whitespace is empty, on every model-routing value', () async {
    final store = MessageStore(db);
    await store.setPref(boxBigUrlKey, '   ');
    await store.setPref(boxBigModelKey, '\n');
    await store.setPref(decisionUrlKey, ' ');
    await store.setPref(cloudDraftsUrlKey, '\t');

    final prefs = (await container()).read(appPrefsProvider);

    expect(prefs.boxBigUrl, isEmpty);
    expect(prefs.boxBigModel, isEmpty);
    expect(prefs.decisionUrl, isEmpty);
    expect(prefs.cloudDraftsUrl, isEmpty);
    expect(prefs.cloudDraftsSpec, isNull);
  });

  test('an unreadable placement reads as the default', () async {
    final store = MessageStore(db);
    await store.setPref(decisionPlacementKey, 'the-moon');
    await store.setPref(modelPlacementKey, 'the-moon');

    final prefs = (await container()).read(appPrefsProvider);

    expect(prefs.decisionPlacement, ModelPlacement.local);
    expect(prefs.modelPlacement, defaultModelPlacement);
  });

  group('the prose lane\'s width', () {
    test('one on a fresh install, and it round-trips', () async {
      final ref = await container();
      expect(ref.read(appPrefsProvider).proseParallel, 1);

      await ref.read(appPrefsProvider.notifier).setProseParallel(4);

      expect(ref.read(appPrefsProvider).proseParallel, 4);
      expect(await MessageStore(db).getPref(proseParallelKey), '4');
    });

    test('a stored width is read back, and a silly one is clamped', () async {
      final store = MessageStore(db);
      await store.setPref(proseParallelKey, '64');

      // Clamped on the READ as well as the write: a number nothing on screen
      // could produce must not be able to put sixty requests in front of a
      // one-slot server.
      expect((await container()).read(appPrefsProvider).proseParallel, 8);

      await store.setPref(proseParallelKey, 'wide');
      expect((await container()).read(appPrefsProvider).proseParallel, 1);
    });

    test('the setter clamps too', () async {
      final ref = await container();
      final notifier = ref.read(appPrefsProvider.notifier);

      await notifier.setProseParallel(0);
      expect(ref.read(appPrefsProvider).proseParallel, 1);

      await notifier.setProseParallel(99);
      expect(ref.read(appPrefsProvider).proseParallel, 8);
    });

    test('it survives a wipe, like the other machine settings', () async {
      final ref = await container();
      await ref.read(appPrefsProvider.notifier).setProseParallel(2);

      // `wipeAll` names the keys it clears, and this is not one of them: how
      // many slots this machine's prose server has is a fact about the
      // machine, not about whoever is signed in.
      await MessageStore(db).wipeAll();

      expect(await MessageStore(db).getPref(proseParallelKey), '2');
    });
  });
}
