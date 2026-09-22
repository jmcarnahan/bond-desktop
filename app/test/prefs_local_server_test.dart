import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart'
    show fastSlotDefault, managedServerDefault;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two preferences the managed server is configured by, the constant that
/// replaced the third, and what each of them means when it is absent or
/// nonsense.
///
/// The subject is the DEFAULTS as much as the writes. Every install arrives
/// with none of these keys stored, so what they read as is what the app does:
/// the app runs its own server, on port 8080, out of its own folder. Whether
/// it runs one at all stopped being a preference in Round H — the switch left
/// the Models page and `BOND_DEV_HAND_SERVERS` took its place, which is a fact
/// about the BUILD an engineer running `make model fast embed` sets once.
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

  test('a fresh install runs its own server on 8080', () async {
    final ref = await container();
    final store = MessageStore(db);

    expect(await store.getPref(routerPortKey), isNull);
    expect(await store.getPref(modelsFolderKey), isNull);

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.managedServer, managedServerDefault);
    expect(prefs.managedServer, isTrue,
        reason: 'the test suite passes no BOND_DEV_HAND_SERVERS define');
    expect(prefs.routerPort, AppPrefs.defaultRouterPort);
    expect(prefs.modelsFolder, '');
  });

  test('whether the app runs a server is a build define, not a row', () async {
    final ref = await container();
    final store = MessageStore(db);

    await ref.read(appPrefsProvider.notifier).setRouterPort(9310);
    await ref.read(appPrefsProvider.notifier).setModelsFolder('/m');

    // Nothing writes it, so nothing can read it back differently: the field
    // stays for a test that wants the compiled URLs, and there is no key.
    final rows = await db.customSelect('SELECT key FROM app_prefs').get();
    expect([for (final row in rows) row.read<String>('key')],
        isNot(contains('managed_server')));
    expect(await store.getPref(routerPortKey), '9310');
    expect(ref.read(appPrefsProvider).managedServer, isTrue);
    // And a build that hands the servers over reads the compiled targets.
    const handStarted = AppPrefs(managedServer: false);
    expect(handStarted.fastTarget.baseUrl, fastSlotDefault.baseUrl);
    expect(handStarted.embedRequestTarget.baseUrl,
        isNot(contains('${AppPrefs.defaultRouterPort}')));
  });

  test('the two setters land under their own keys', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);
    final store = MessageStore(db);

    await notifier.setRouterPort(9310);
    await notifier.setModelsFolder('/Volumes/Big/models');

    expect(await store.getPref(routerPortKey), '9310');
    expect(await store.getPref(modelsFolderKey), '/Volumes/Big/models');

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.routerPort, 9310);
    expect(prefs.modelsFolder, '/Volumes/Big/models');
  });

  test('a port below the range clamps up, and one above clamps down', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setRouterPort(80);
    expect(ref.read(appPrefsProvider).routerPort, 1024);
    expect(await MessageStore(db).getPref(routerPortKey), '1024');

    await notifier.setRouterPort(99999);
    expect(ref.read(appPrefsProvider).routerPort, 65535);
  });

  test('a stored port that is not a number reads as the default', () async {
    await MessageStore(db).setPref(routerPortKey, 'eight thousand');
    final ref = await container();
    expect(ref.read(appPrefsProvider).routerPort, AppPrefs.defaultRouterPort);
  });

  test('a stored port outside the range is clamped on the way in', () async {
    await MessageStore(db).setPref(routerPortKey, '22');
    final ref = await container();
    expect(ref.read(appPrefsProvider).routerPort, 1024);
  });

  test('the models folder is trimmed on the write and on the read', () async {
    final ref = await container();
    await ref.read(appPrefsProvider.notifier).setModelsFolder('  /m/odels \n');
    expect(ref.read(appPrefsProvider).modelsFolder, '/m/odels');
    expect(await MessageStore(db).getPref(modelsFolderKey), '/m/odels');

    await MessageStore(db).setPref(modelsFolderKey, '  /other  ');
    final second = await container();
    expect(second.read(appPrefsProvider).modelsFolder, '/other');
  });

  /// The point of the test, and the reason these keys are deliberately absent
  /// from `wipeAll`'s list: which server this machine runs is a fact about the
  /// machine, not about whoever was signed into it.
  test('a sign-out wipe leaves both standing', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);
    await notifier.setRouterPort(9310);
    await notifier.setModelsFolder('/Volumes/Big/models');

    final store = MessageStore(db);
    await store.wipeAll();

    expect(await store.getPref(routerPortKey), '9310');
    expect(await store.getPref(modelsFolderKey), '/Volumes/Big/models');

    final after = await container();
    final prefs = after.read(appPrefsProvider);
    expect(prefs.routerPort, 9310);
    expect(prefs.modelsFolder, '/Volumes/Big/models');
  });
}
