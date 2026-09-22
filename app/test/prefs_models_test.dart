import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Where a model slot's override lives, and what empty means there.
///
/// The subject of this file is one deliberate inconsistency: `mcp_server_url`
/// resolves its default when it is READ, and these four prefs do not. A model
/// default is a fact about this machine's `local.mk`, so resolving it on read
/// would freeze today's dart-define into the database and make a changed one
/// invisible. Empty is stored as empty, and only [AppPrefs.fastTarget] and
/// [AppPrefs.proseTarget] turn it into the build's baseline: the managed
/// router's target in every shipped build, and the compiled default only in a
/// build that says `BOND_DEV_HAND_SERVERS`. `slotBaseline` is that answer,
/// which is why the cases below compare against it rather than a constant.

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

  test('a fresh install follows the build', () async {
    final ref = await container();
    final store = MessageStore(db);

    expect(await store.getPref(fastLlmUrlKey), isNull);
    expect(await store.getPref(fastLlmModelKey), isNull);
    expect(await store.getPref(proseLlmUrlKey), isNull);
    expect(await store.getPref(proseLlmModelKey), isNull);

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.fastTarget, prefs.slotBaseline(ModelSlot.fast));
    expect(prefs.proseTarget, prefs.slotBaseline(ModelSlot.prose));
    expect(prefs.isSlotDefault(ModelSlot.fast), isTrue);
    expect(prefs.isSlotDefault(ModelSlot.prose), isTrue);
  });

  test('a set target round-trips', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setFastLlmTarget(
          url: 'http://h:9/v1/chat/completions',
          model: 'mlx-4b',
        );

    expect(
      ref.read(appPrefsProvider).fastTarget,
      const LlmTarget(
        baseUrl: 'http://h:9/v1/chat/completions',
        model: 'mlx-4b',
      ),
    );
    expect(ref.read(appPrefsProvider).isSlotDefault(ModelSlot.fast), isFalse);

    // The exact strings landed in the table, and a new container reads them
    // back — the state is a cache of the store, not the other way round.
    final store = MessageStore(db);
    expect(await store.getPref(fastLlmUrlKey), 'http://h:9/v1/chat/completions');
    expect(await store.getPref(fastLlmModelKey), 'mlx-4b');
    expect(
      (await container()).read(appPrefsProvider).fastTarget,
      const LlmTarget(
        baseUrl: 'http://h:9/v1/chat/completions',
        model: 'mlx-4b',
      ),
    );
  });

  test('the two slots are independent', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setFastLlmTarget(
          url: 'http://h:9/v1/chat/completions',
          model: 'mlx-4b',
        );

    expect(ref.read(appPrefsProvider).proseTarget,
        ref.read(appPrefsProvider).slotBaseline(ModelSlot.prose));
    expect(ref.read(appPrefsProvider).isSlotDefault(ModelSlot.prose), isTrue);
  });

  test('empty means the build default, and is stored as empty', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setFastLlmTarget(
      url: 'http://h:9/v1/chat/completions',
      model: 'mlx-4b',
    );
    await notifier.setFastLlmTarget(url: '', model: '');

    expect(ref.read(appPrefsProvider).fastTarget,
        ref.read(appPrefsProvider).slotBaseline(ModelSlot.fast));
    // The assertion that pins the difference from `mcpServerUrl`: what is
    // STORED is empty, not the resolved default string.
    final store = MessageStore(db);
    expect(await store.getPref(fastLlmUrlKey), '');
    expect(await store.getPref(fastLlmModelKey), '');
    expect(ref.read(appPrefsProvider).isSlotDefault(ModelSlot.fast), isTrue);
  });

  test('whitespace is empty', () async {
    final store = MessageStore(db);
    await store.setPref(fastLlmUrlKey, '   ');
    await store.setPref(fastLlmModelKey, '\n');

    final ref = await container();

    expect(ref.read(appPrefsProvider).fastTarget,
        ref.read(appPrefsProvider).slotBaseline(ModelSlot.fast));
    expect(ref.read(appPrefsProvider).isSlotDefault(ModelSlot.fast), isTrue);
  });

  test('half an override still resolves the other half', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setFastLlmTarget(
          url: 'http://h:9/v1/chat/completions',
          model: '',
        );

    final target = ref.read(appPrefsProvider).fastTarget;
    expect(target.baseUrl, 'http://h:9/v1/chat/completions');
    expect(target.model, fastModelDefault);
    expect(ref.read(appPrefsProvider).isSlotDefault(ModelSlot.fast), isFalse);
  });

  test('clearSlotTarget puts a slot back on the build', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setProseLlmTarget(
      url: 'http://h:9/v1/chat/completions',
      model: 'mlx-27b',
    );
    await notifier.clearSlotTarget(ModelSlot.prose);

    expect(ref.read(appPrefsProvider).proseTarget,
        ref.read(appPrefsProvider).slotBaseline(ModelSlot.prose));
    expect(await MessageStore(db).getPref(proseLlmUrlKey), '');
  });

  test('the embed slot is not switchable', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setFastLlmTarget(
      url: 'http://h:9/v1/chat/completions',
      model: 'mlx-4b',
    );
    await notifier.setProseLlmTarget(
      url: 'http://h:10/v1/chat/completions',
      model: 'mlx-27b',
    );
    // A no-op rather than an error: the screen may offer Reset for every row.
    await notifier.clearSlotTarget(ModelSlot.embed);

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.targetFor(ModelSlot.embed), prefs.slotBaseline(ModelSlot.embed));
    expect(prefs.isSlotDefault(ModelSlot.embed), isTrue);
    // And the other two still answer their own overrides.
    expect(prefs.targetFor(ModelSlot.fast), prefs.fastTarget);
    expect(prefs.targetFor(ModelSlot.prose), prefs.proseTarget);
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
