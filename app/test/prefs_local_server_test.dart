import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The three preferences the managed server is configured by, and what each of
/// them means when it is absent or nonsense.
///
/// The subject is the DEFAULTS as much as the writes. Every existing install
/// arrives here with none of these keys stored, and what they read as decides
/// whether an update changes how the app talks to its servers: off, port 8080,
/// and "the app's own folder" is the only combination that leaves the
/// hand-started `make model | fast | embed` workflow untouched.
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

  test('a fresh install expects hand-started servers on 8080', () async {
    final ref = await container();
    final store = MessageStore(db);

    expect(await store.getPref(managedServerKey), isNull);
    expect(await store.getPref(routerPortKey), isNull);
    expect(await store.getPref(modelsFolderKey), isNull);

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.managedServer, isFalse);
    expect(prefs.routerPort, AppPrefs.defaultRouterPort);
    expect(prefs.modelsFolder, '');
  });

  test('the three setters land under their own keys', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);
    final store = MessageStore(db);

    await notifier.setManagedServer(true);
    await notifier.setRouterPort(9310);
    await notifier.setModelsFolder('/Volumes/Big/models');

    expect(await store.getPref(managedServerKey), 'true');
    expect(await store.getPref(routerPortKey), '9310');
    expect(await store.getPref(modelsFolderKey), '/Volumes/Big/models');

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.managedServer, isTrue);
    expect(prefs.routerPort, 9310);
    expect(prefs.modelsFolder, '/Volumes/Big/models');
  });

  test('turning the switch back off stores the off spelling', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setManagedServer(true);
    await notifier.setManagedServer(false);

    expect(await MessageStore(db).getPref(managedServerKey), 'false');
    expect(ref.read(appPrefsProvider).managedServer, isFalse);
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
  test('a sign-out wipe leaves all three standing', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);
    await notifier.setManagedServer(true);
    await notifier.setRouterPort(9310);
    await notifier.setModelsFolder('/Volumes/Big/models');

    final store = MessageStore(db);
    await store.wipeAll();

    expect(await store.getPref(managedServerKey), 'true');
    expect(await store.getPref(routerPortKey), '9310');
    expect(await store.getPref(modelsFolderKey), '/Volumes/Big/models');

    final after = await container();
    final prefs = after.read(appPrefsProvider);
    expect(prefs.managedServer, isTrue);
    expect(prefs.routerPort, 9310);
    expect(prefs.modelsFolder, '/Volumes/Big/models');
  });
}
